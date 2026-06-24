## Git-backed document storage.
##
## Each document is an `.org` file inside a data directory that is itself a git
## repository, so every save is a commit — version history for free, matching
## the mental model org-mode users already have. The data dir is $BABELHUB_DATA
## (default ./data); the embedded frontend stays in the binary, only documents
## live here.

import std/[os, osproc, strutils, json, algorithm, streams]

let storeDir = absolutePath(getEnv("BABELHUB_DATA", "data"))

proc runGit(args: seq[string]): string {.discardable.} =
  ## Run git in the store with explicit args (no shell), merging stderr.
  let p = startProcess("git", workingDir = storeDir, args = args,
                       options = {poUsePath, poStdErrToStdOut})
  defer: p.close()
  result = p.outputStream.readAll()
  discard p.waitForExit()

proc initStore*() =
  ## Ensure the data dir exists and is a git repo with a commit identity.
  createDir(storeDir)
  if not dirExists(storeDir / ".git"):
    runGit(@["init", "-q"])
    runGit(@["config", "user.name", "BabelHub"])
    runGit(@["config", "user.email", "babelhub@localhost"])
  echo "BabelHub document store: ", storeDir

proc validSlug*(slug: string): bool =
  ## Documents are addressed by a slug; keep it filesystem- and shell-safe.
  ## (Rejecting '/' here is also what blocks path traversal.)
  if slug.len == 0 or slug.len > 64: return false
  for c in slug:
    if c notin {'a'..'z', 'A'..'Z', '0'..'9', '_', '-'}: return false
  true

proc listDocsJson*(): string {.gcsafe.} =
  ## JSON {"docs": [...]} of available slugs, sorted. Slugs are validated on
  ## write, so they need no escaping.
  {.cast(gcsafe).}:
    var slugs: seq[string]
    for kind, path in walkDir(storeDir):
      if kind == pcFile and path.endsWith(".org"):
        slugs.add splitFile(path).name
    sort(slugs)
    result = $(%*{"docs": slugs})

proc readDoc*(slug: string): (bool, string) {.gcsafe.} =
  {.cast(gcsafe).}:
    let p = storeDir / (slug & ".org")
    if fileExists(p): result = (true, readFile(p))
    else: result = (false, "")

proc writeDoc*(slug, content: string) {.gcsafe.} =
  ## Persist and commit. A no-op save (git finds nothing changed) is fine — the
  ## file is written regardless; the commit is the bonus history layer.
  {.cast(gcsafe).}:
    writeFile(storeDir / (slug & ".org"), content)
    runGit(@["add", "--", slug & ".org"])
    discard runGit(@["commit", "-q", "-m", "Update " & slug, "--", slug & ".org"])
