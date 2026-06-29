## Sandbox provisioning + audit for server execution.
##
## - Per-session scratch dir mounted at /work (and used as the working dir), so
##   results pass between block runs — and across languages, since it's keyed by
##   the document, not the interpreter.
## - Operator-allowlisted read-only mounts (datasets, shared package libraries)
##   via BABELHUB_MOUNTS="host:container[:ro|:rw];...".
## - An append-only audit log (BABELHUB_AUDIT_LOG, JSONL) of every `#@require`
##   directive, so IT can see what users have asked for and provision it.

import std/[os, strutils, json, times]

type Mount = object
  host, container: string
  rw: bool

proc parseMounts(): seq[Mount] =
  for spec in getEnv("BABELHUB_MOUNTS", "").split(';'):
    let s = spec.strip()
    if s.len == 0: continue
    let parts = s.split(':')
    if parts.len < 2: continue
    result.add Mount(host: parts[0], container: parts[1],
                     rw: parts.len >= 3 and parts[2] == "rw")

let
  cfgMounts   = parseMounts()
  cfgWorkBase = absolutePath(getEnv("BABELHUB_WORK",
                  getEnv("BABELHUB_DATA", "data") / "work"))
  cfgAudit    = absolutePath(getEnv("BABELHUB_AUDIT_LOG",
                  getEnv("BABELHUB_DATA", "data") / "audit.log"))

proc safeName(s: string): string =
  for c in s:
    if c in {'a'..'z', 'A'..'Z', '0'..'9', '_', '-'}: result.add c
  if result.len == 0: result = "default"

proc workDir*(session: string): string {.gcsafe.} =
  {.cast(gcsafe).}:
    result = cfgWorkBase / safeName(session)
    createDir(result)

proc mountFlags*(session: string): seq[string] {.gcsafe.} =
  ## docker flags: allowlisted mounts (ro unless rw) + the session work dir
  ## (rw at /work, set as the workdir, exposed as $BH_WORK).
  {.cast(gcsafe).}:
    for m in cfgMounts:
      result.add "-v"
      result.add m.host & ":" & m.container & (if m.rw: ":rw" else: ":ro")
    result.add ["-v", workDir(session) & ":/work:rw",
                "--workdir", "/work", "-e", "BH_WORK=/work"]

proc parseRequires*(code: string): seq[string] =
  ## Collect `#@require <resource>` directives (works in #-comment languages).
  for line in code.splitLines():
    let s = line.strip()
    if s.startsWith("#@require"):
      let rest = s["#@require".len .. ^1].strip()
      if rest.len > 0: result.add rest

proc resourceStatus(resource: string): string {.gcsafe.} =
  ## "available" if a path under a configured mount, else "pending" (IT must
  ## provision: add the mount, or install the requested package).
  {.cast(gcsafe).}:
    if resource.startsWith("/"):
      for m in cfgMounts:
        if resource == m.container or resource.startsWith(m.container & "/"):
          return "available"
    "pending"

proc audit*(user, session, lang, code: string) {.gcsafe.} =
  ## Append one JSONL record per `#@require`, so IT can audit + provision.
  {.cast(gcsafe).}:
    let reqs = parseRequires(code)
    if reqs.len == 0: return
    try:
      createDir(cfgAudit.parentDir)
      let f = open(cfgAudit, fmAppend)
      defer: f.close()
      for r in reqs:
        f.writeLine($(%*{
          "ts": now().format("yyyy-MM-dd'T'HH:mm:ss"),
          "user": (if user.len > 0: user else: "anonymous"),
          "session": session,
          "lang": lang,
          "resource": r,
          "status": resourceStatus(r),
        }))
    except CatchableError: discard
