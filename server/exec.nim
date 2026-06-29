## Container-per-block execution — the Tier-3 paid-backend prototype.
##
## Runs an org src block in an ephemeral, locked-down `docker run --rm`
## container and returns its output. This is the path for code webR/Pyodide
## can't handle: other languages, compiled deps, heavier jobs.
##
## SECURITY: this executes (untrusted) code. It is OFF unless BABELHUB_EXEC=1,
## and every container runs with no network, dropped capabilities, a read-only
## rootfs, memory/cpu/pid caps, no-new-privileges, and a hard timeout. Even so,
## a *public* deployment MUST add authentication, rate limiting, and abuse
## monitoring before enabling this — an open code-execution endpoint is a
## crypto-mining magnet. Treat BABELHUB_EXEC=1 as "trusted users only" for now.
##
## Images are NOT pulled at run time (there is no network in the sandbox), so
## the host must have them pre-pulled — see `nimble images`.

import std/[osproc, os, strutils, tables, asyncdispatch, streams, json, times]
import sandbox

type LangSpec = object
  image: string
  argv: seq[string] # interpreter invocation; the block's code arrives on stdin

let registry = {
  "sh":         LangSpec(image: "alpine:3",     argv: @["sh", "-s"]),
  "shell":      LangSpec(image: "alpine:3",     argv: @["sh", "-s"]),
  "bash":       LangSpec(image: "bash:5",       argv: @["bash", "-s"]),
  "julia":      LangSpec(image: "julia:1",      argv: @["julia", "/dev/stdin"]),
  "js":         LangSpec(image: "node:20-slim", argv: @["node", "/dev/stdin"]),
  "javascript": LangSpec(image: "node:20-slim", argv: @["node", "/dev/stdin"]),
}.toTable

let
  cfgEnabled = getEnv("BABELHUB_EXEC", "") == "1"
  cfgTimeout = parseInt(getEnv("BABELHUB_EXEC_TIMEOUT", "30"))
  cfgMem     = getEnv("BABELHUB_EXEC_MEM", "256m")
  cfgCpus    = getEnv("BABELHUB_EXEC_CPUS", "1.0")
  cfgMax     = parseInt(getEnv("BABELHUB_EXEC_MAX", "4"))

const maxCode = 100_000
const maxOutput = 100_000

var inFlight = 0
var nameSeq = 0

proc execEnabled*(): bool {.gcsafe.} =
  {.cast(gcsafe).}: cfgEnabled

proc ephemeralLanguages*(): seq[string] {.gcsafe.} =
  ## Languages run per-block in a throwaway container (no shared state).
  {.cast(gcsafe).}:
    for k in registry.keys: result.add k

proc runBlock*(session, lang, code: string): Future[tuple[ok: bool, output: string]] {.async, gcsafe.} =
  {.cast(gcsafe).}:
    if not registry.hasKey(lang):
      return (false, "unsupported language: " & lang)
    if code.len > maxCode:
      return (false, "code too large (limit " & $maxCode & " bytes)")
    if inFlight >= cfgMax:
      return (false, "server busy — too many concurrent runs, try again")

    let spec = registry[lang]
    inc nameSeq
    let name = "bh-exec-" & $int(epochTime()) & "-" & $nameSeq
    let dockerArgs = @[
      "run", "--rm", "-i", "--name", name,
      "--network", "none",                       # no exfiltration / mining
      "--memory", cfgMem, "--memory-swap", cfgMem, # cap RAM, disable swap
      "--cpus", cfgCpus,
      "--pids-limit", "128",                     # fork-bomb guard
      "--read-only", "--tmpfs", "/tmp:size=64m", # immutable rootfs + scratch
      "--cap-drop", "ALL",
      "--security-opt", "no-new-privileges",
    ] & mountFlags(session) & @[  # allowlisted mounts + /work scratch dir
      spec.image,
    ] & spec.argv

    inc inFlight
    try:
      var p: Process
      try:
        p = startProcess("docker", args = dockerArgs,
                          options = {poUsePath, poStdErrToStdOut})
      except OSError:
        return (false, "could not start docker: " & getCurrentExceptionMsg())

      p.inputStream.write(code)
      p.inputStream.close()

      let deadline = epochTime() + cfgTimeout.float
      var timedOut = false
      while p.peekExitCode() == -1:
        if epochTime() > deadline:
          timedOut = true
          break
        await sleepAsync(50)

      if timedOut:
        discard execCmd("docker kill " & name & " > /dev/null 2>&1")

      var output = p.outputStream.readAll()
      discard p.waitForExit()
      p.close()

      if output.len > maxOutput:
        output = output[0 ..< maxOutput] & "\n…(output truncated)"
      if timedOut:
        output = output.strip() & "\n…(killed after " & $cfgTimeout & "s)"
      return (true, output.strip())
    finally:
      dec inFlight
