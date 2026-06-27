## Git-backed document storage.
##
## Each document is an `.org` file inside a data directory that is itself a git
## repository, so every save is a commit — version history for free. The data
## dir is $BABELHUB_DATA (default ./data).
##
## Documents live in a *namespace*: the empty namespace ("") is the shared store
## (the default when there's no logged-in user); with GitHub OAuth, each user's
## login is their namespace (a subdirectory with its own git repo), giving every
## user a private document space.

import std/[os, osproc, strutils, json, algorithm, streams]

let storeDir = absolutePath(getEnv("BABELHUB_DATA", "data"))

proc validNamespace*(ns: string): bool =
  ## "" is the shared store; otherwise a GitHub-login-shaped name.
  if ns.len == 0: return true
  if ns.len > 39: return false
  for c in ns:
    if c notin {'a'..'z', 'A'..'Z', '0'..'9', '-'}: return false
  true

proc nsDir(ns: string): string =
  if ns.len == 0: storeDir else: storeDir / ns

proc runGit(dir: string, args: seq[string]): string {.discardable.} =
  let p = startProcess("git", workingDir = dir, args = args,
                       options = {poUsePath, poStdErrToStdOut})
  defer: p.close()
  result = p.outputStream.readAll()
  discard p.waitForExit()

proc ensureRepo(dir: string) =
  ## Create the namespace dir and make it a git repo with a commit identity.
  createDir(dir)
  if not dirExists(dir / ".git"):
    runGit(dir, @["init", "-q"])
    runGit(dir, @["config", "user.name", "BabelHub"])
    runGit(dir, @["config", "user.email", "babelhub@localhost"])

proc initStore*() =
  ensureRepo(storeDir)
  echo "BabelHub document store: ", storeDir

proc validSlug*(slug: string): bool =
  ## Documents are addressed by a slug; keep it filesystem- and shell-safe.
  ## (Rejecting '/' here is also what blocks path traversal.)
  if slug.len == 0 or slug.len > 64: return false
  for c in slug:
    if c notin {'a'..'z', 'A'..'Z', '0'..'9', '_', '-'}: return false
  true

proc listDocsJson*(ns: string): string {.gcsafe.} =
  ## JSON {"docs": [...]} of slugs in the namespace, sorted.
  {.cast(gcsafe).}:
    let dir = nsDir(ns)
    var slugs: seq[string]
    if dirExists(dir):
      for kind, path in walkDir(dir):
        if kind == pcFile and path.endsWith(".org"):
          slugs.add splitFile(path).name
    sort(slugs)
    result = $(%*{"docs": slugs})

proc readDoc*(ns, slug: string): (bool, string) {.gcsafe.} =
  {.cast(gcsafe).}:
    let p = nsDir(ns) / (slug & ".org")
    if fileExists(p): result = (true, readFile(p))
    else: result = (false, "")

proc writeDoc*(ns, slug, content: string) {.gcsafe.} =
  ## Persist and commit in the namespace (creating its repo on first write).
  {.cast(gcsafe).}:
    let dir = nsDir(ns)
    ensureRepo(dir)
    writeFile(dir / (slug & ".org"), content)
    runGit(dir, @["add", "--", slug & ".org"])
    discard runGit(dir, @["commit", "-q", "-m", "Update " & slug, "--", slug & ".org"])
