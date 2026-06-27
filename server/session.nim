## Persistent session execution — one long-lived interpreter per (document,
## language), so blocks share state like a Jupyter kernel (and like webR/Pyodide
## and org-babel's `:session`). Each interpreter runs a small driver speaking a
## length-framed protocol over stdin/stdout: "<byte-len>\n" + bytes.
##
## Two runners (BABELHUB_EXEC_RUNNER):
##   - docker (default): the interpreter runs in a locked-down container.
##   - local: the interpreter runs directly on the host (no isolation) — handy
##     for a single trusted user, and what the test suite exercises.
##
## SECURITY mirrors exec.nim: only on with BABELHUB_EXEC=1, and a public
## deployment still needs auth/rate-limiting before enabling either runner.

import std/[osproc, os, strutils, tables, asyncdispatch, streams, times,
            selectors, posix]

# --- drivers (validated standalone before embedding) ----------------------
const pyDriver = """
import sys, io, ast, traceback
G = {"__name__": "__main__"}
real_in = sys.stdin.buffer
real_out = sys.stdout.buffer
def read_frame():
    header = b""
    while not header.endswith(b"\n"):
        ch = real_in.read(1)
        if not ch: return None
        header += ch
    n = int(header); data = b""
    while len(data) < n:
        chunk = real_in.read(n - len(data))
        if not chunk: return None
        data += chunk
    return data.decode("utf-8")
def write_frame(s):
    b = s.encode("utf-8")
    real_out.write(str(len(b)).encode() + b"\n"); real_out.write(b); real_out.flush()
while True:
    code = read_frame()
    if code is None: break
    buf = io.StringIO(); old = (sys.stdout, sys.stderr); sys.stdout = sys.stderr = buf
    try:
        tree = ast.parse(code, "<block>", "exec")
        last = tree.body.pop() if tree.body and isinstance(tree.body[-1], ast.Expr) else None
        exec(compile(tree, "<block>", "exec"), G)
        if last is not None:
            val = eval(compile(ast.Expression(last.value), "<block>", "eval"), G)
            if val is not None: print(repr(val))
    except Exception:
        tb = traceback.TracebackException(*sys.exc_info())
        tb.stack = traceback.StackSummary.from_list([f for f in tb.stack if f.filename == "<block>"])
        print("".join(tb.format()), end="")
    finally:
        sys.stdout, sys.stderr = old
    write_frame(buf.getvalue())
"""

const rDriver = """
con_in <- file("/dev/stdin", open = "rb", raw = TRUE)
con_out <- file("/dev/stdout", open = "wb", raw = TRUE)
read_frame <- function() {
  header <- raw(0)
  repeat {
    b <- readBin(con_in, "raw", 1L)
    if (length(b) == 0L) return(NULL)
    if (b == as.raw(10L)) break
    header <- c(header, b)
  }
  n <- as.integer(rawToChar(header)); if (is.na(n)) return(NULL)
  data <- raw(0)
  while (length(data) < n) {
    chunk <- readBin(con_in, "raw", n - length(data))
    if (length(chunk) == 0L) return(NULL)
    data <- c(data, chunk)
  }
  txt <- rawToChar(data); Encoding(txt) <- "UTF-8"; txt
}
write_frame <- function(s) {
  payload <- charToRaw(enc2utf8(s))
  writeBin(charToRaw(paste0(length(payload), "\n")), con_out)
  writeBin(payload, con_out); flush(con_out)
}
repeat {
  code <- read_frame(); if (is.null(code)) break
  out <- capture.output(tryCatch(
    source(textConnection(code), local = globalenv(), echo = FALSE, print.eval = TRUE),
    error = function(e) cat("Error:", conditionMessage(e), "\n")))
  write_frame(paste(out, collapse = "\n"))
}
"""

type DriverSpec = object
  image: string         # docker image for the docker runner
  argv: seq[string]     # interpreter invocation (runs the driver)

let drivers = {
  "python": DriverSpec(image: "python:3.12-slim", argv: @["python3", "-u", "-c", pyDriver]),
  "py":     DriverSpec(image: "python:3.12-slim", argv: @["python3", "-u", "-c", pyDriver]),
  "r":      DriverSpec(image: "r-base:latest",    argv: @["Rscript", "-e", rDriver]),
  "ess-r":  DriverSpec(image: "r-base:latest",    argv: @["Rscript", "-e", rDriver]),
}.toTable

let
  cfgRunnerDocker = getEnv("BABELHUB_EXEC_RUNNER", "docker") != "local"
  cfgTimeout      = parseInt(getEnv("BABELHUB_EXEC_TIMEOUT", "30"))
  cfgMem          = getEnv("BABELHUB_EXEC_MEM", "256m")
  cfgCpus         = getEnv("BABELHUB_EXEC_CPUS", "1.0")
  cfgMaxSessions  = parseInt(getEnv("BABELHUB_SESSION_MAX", "16"))
  cfgIdleSecs     = parseInt(getEnv("BABELHUB_SESSION_IDLE", "900"))

type Session = ref object
  p: Process
  lang: string
  lastUsed: float

var sessions = initTable[string, Session]()
var nameSeq = 0

proc sessionLanguages*(): seq[string] {.gcsafe.} =
  {.cast(gcsafe).}:
    for k in drivers.keys: result.add k

proc spawn(spec: DriverSpec): Process =
  if cfgRunnerDocker:
    inc nameSeq
    let name = "bh-sess-" & $int(epochTime()) & "-" & $nameSeq
    let flags = @[
      "run", "-i", "--rm", "--name", name,
      "--network", "none",
      "--memory", cfgMem, "--memory-swap", cfgMem,
      "--cpus", cfgCpus,
      "--pids-limit", "256",
      "--read-only", "--tmpfs", "/tmp:size=64m", "--tmpfs", "/home:size=16m",
      "-e", "HOME=/tmp",
      "--cap-drop", "ALL", "--security-opt", "no-new-privileges",
    ]
    startProcess("docker", args = flags & @[spec.image] & spec.argv,
                 options = {poUsePath})
  else:
    startProcess(spec.argv[0], args = spec.argv[1 .. ^1], options = {poUsePath})

proc closeSession(key: string, s: Session) =
  try:
    if s.p.running: s.p.terminate()
  except CatchableError: discard
  try: s.p.close()
  except CatchableError: discard
  sessions.del(key)

# Read one length-framed message from `fd`, bounded by a wall-clock `deadline`.
# Raises IOError on timeout or EOF so the caller can recycle the session.
proc readFrame(fd: cint, deadline: float): string =
  var sel = newSelector[int]()
  sel.registerHandle(fd.int, {Event.Read}, 0)
  defer: sel.close()

  proc fill(n: int): string =
    result = ""
    var chunk = newString(4096)
    while result.len < n:
      let remain = deadline - epochTime()
      if remain <= 0: raise newException(IOError, "timeout")
      if sel.select(int(remain * 1000)).len == 0:
        raise newException(IOError, "timeout")
      let want = min(n - result.len, chunk.len)
      let got = posix.read(fd, addr chunk[0], want.cint)
      if got <= 0: raise newException(IOError, "eof")
      result.add chunk[0 ..< got]

  var header = ""
  while not header.endsWith("\n"):
    header.add fill(1)
  result = fill(parseInt(header.strip()))

proc sessionExec*(sessionId, lang, code: string): (bool, string) {.gcsafe.} =
  ## Run `code` in the session for (sessionId, lang), creating it on first use.
  ## Blocking (bounded by the timeout); fine for the single-process MVP.
  {.cast(gcsafe).}:
    if not drivers.hasKey(lang):
      return (false, "no session driver for language: " & lang)
    let key = sessionId & "\x00" & lang
    var s = sessions.getOrDefault(key, nil)
    if s == nil or not s.p.running:
      if s != nil: closeSession(key, s)
      if sessions.len >= cfgMaxSessions:
        return (false, "too many live sessions (limit " & $cfgMaxSessions & ")")
      try:
        s = Session(p: spawn(drivers[lang]), lang: lang, lastUsed: epochTime())
      except CatchableError:
        return (false, "could not start session: " & getCurrentExceptionMsg())
      sessions[key] = s

    try:
      s.p.inputStream.write($code.len & "\n")
      s.p.inputStream.write(code)
      s.p.inputStream.flush()
    except CatchableError:
      closeSession(key, s)
      return (false, "session write failed: " & getCurrentExceptionMsg())

    try:
      let output = readFrame(s.p.outputHandle, epochTime() + cfgTimeout.float)
      s.lastUsed = epochTime()
      return (true, output.strip(leading = false))
    except IOError:
      closeSession(key, s)
      return (false, "session timed out or crashed after " & $cfgTimeout & "s")

proc reaper*() {.async.} =
  ## Periodically close idle sessions so containers don't pile up.
  while true:
    await sleepAsync(30_000)
    {.cast(gcsafe).}:
      let now = epochTime()
      var dead: seq[string]
      for k, s in sessions:
        if now - s.lastUsed > cfgIdleSecs.float or not s.p.running:
          dead.add k
      for k in dead:
        closeSession(k, sessions[k])
