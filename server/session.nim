## Persistent session execution — one long-lived interpreter per (document,
## language), so blocks share state like a Jupyter kernel (and like webR/Pyodide
## and org-babel's `:session`). Each interpreter runs a small driver speaking a
## length-framed protocol over stdin/stdout: "<byte-len>\n" + bytes. The reply
## payload is JSON: {"output": text, "images": [b64 png...], "tables": [{...}]}.
##
## Two runners (BABELHUB_EXEC_RUNNER):
##   - docker (default): the interpreter runs in a locked-down container.
##   - local: the interpreter runs directly on the host (no isolation) — handy
##     for a single trusted user, and what the test suite exercises.
##
## SECURITY mirrors exec.nim: only on with BABELHUB_EXEC=1, and a public
## deployment still needs auth/rate-limiting before enabling either runner.

import std/[osproc, os, strutils, tables, asyncdispatch, streams, times,
            selectors, posix, json]
import sandbox

# --- drivers (each block: text output, captured plots, and tabular results) --
const pyDriver = """
import sys, io, ast, json, base64, traceback, os
os.environ.setdefault("MPLBACKEND", "AGG")
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
def write_frame(b):
    real_out.write(str(len(b)).encode() + b"\n"); real_out.write(b); real_out.flush()
def figures():
    imgs = []
    plt = sys.modules.get("matplotlib.pyplot")
    if plt is not None:
        for n in plt.get_fignums():
            buf = io.BytesIO(); plt.figure(n).savefig(buf, format="png", bbox_inches="tight")
            imgs.append(base64.b64encode(buf.getvalue()).decode())
        plt.close("all")
    return imgs
def as_table(val):
    if val.__class__.__name__ == "DataFrame" and hasattr(val, "columns") and hasattr(val, "values"):
        cols = [str(c) for c in list(val.columns)]
        rows = [["" if c is None else str(c) for c in row] for row in val.values.tolist()[:200]]
        return {"columns": cols, "rows": rows}
    return None
while True:
    code = read_frame()
    if code is None: break
    buf = io.StringIO(); old = (sys.stdout, sys.stderr); sys.stdout = sys.stderr = buf
    table = None
    try:
        tree = ast.parse(code, "<block>", "exec")
        last = tree.body.pop() if tree.body and isinstance(tree.body[-1], ast.Expr) else None
        exec(compile(tree, "<block>", "exec"), G)
        if last is not None:
            val = eval(compile(ast.Expression(last.value), "<block>", "eval"), G)
            table = as_table(val)
            if table is None and val is not None:
                print(repr(val))
    except Exception:
        tb = traceback.TracebackException(*sys.exc_info())
        tb.stack = traceback.StackSummary.from_list([f for f in tb.stack if f.filename == "<block>"])
        print("".join(tb.format()), end="")
    finally:
        sys.stdout, sys.stderr = old
    payload = json.dumps({"output": buf.getvalue(), "images": figures(),
                          "tables": [] if table is None else [table]})
    write_frame(payload.encode("utf-8"))
"""

const rDriver = """
local({
con_in <- file("/dev/stdin", open = "rb", raw = TRUE)
con_out <- file("/dev/stdout", open = "wb", raw = TRUE)
b64 <- function(bytes) {
  tbl <- c(LETTERS, letters, as.character(0:9), "+", "/")
  b <- as.integer(bytes); n <- length(b)
  ch <- character(ceiling(n / 3) * 4); ci <- 1L; i <- 1L
  while (i <= n) {
    b0 <- b[i]; b1 <- if (i+1L<=n) b[i+1L] else 0L; b2 <- if (i+2L<=n) b[i+2L] else 0L
    ch[ci]    <- tbl[bitwShiftR(b0,2L)+1L]
    ch[ci+1L] <- tbl[bitwOr(bitwShiftL(bitwAnd(b0,3L),4L), bitwShiftR(b1,4L))+1L]
    ch[ci+2L] <- if (i+1L<=n) tbl[bitwOr(bitwShiftL(bitwAnd(b1,15L),2L), bitwShiftR(b2,6L))+1L] else "="
    ch[ci+3L] <- if (i+2L<=n) tbl[bitwAnd(b2,63L)+1L] else "="
    ci <- ci+4L; i <- i+3L
  }
  paste(ch, collapse = "")
}
jesc <- function(s) {
  s <- gsub("\\", "\\\\", s, fixed = TRUE); s <- gsub('"', '\\"', s, fixed = TRUE)
  s <- gsub("\n", "\\n", s, fixed = TRUE); s <- gsub("\r", "\\r", s, fixed = TRUE)
  gsub("\t", "\\t", s, fixed = TRUE)
}
jstr <- function(s) paste0('"', jesc(s), '"')
jarr <- function(v) if (length(v) == 0) "[]" else paste0('[', paste(vapply(v, jstr, character(1)), collapse = ","), ']')
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
table_json <- function(df) {
  df <- as.data.frame(df, stringsAsFactors = FALSE)
  cols <- colnames(df); if (is.null(cols)) cols <- paste0("V", seq_len(ncol(df)))
  nshow <- min(nrow(df), 200L); rj <- character(nshow)
  if (nshow > 0) for (i in seq_len(nshow)) {
    cells <- vapply(seq_len(ncol(df)), function(j) jstr(trimws(format(df[i, j]))), character(1))
    rj[i] <- paste0('[', paste(cells, collapse = ","), ']')
  }
  rows <- if (nshow == 0) "" else paste(rj, collapse = ",")
  paste0('{"columns":', jarr(cols), ',"rows":[', rows, ']}')
}
repeat {
  code <- read_frame(); if (is.null(code)) break
  plotdir <- tempfile(); dir.create(plotdir)
  grDevices::png(file.path(plotdir, "p%03d.png"), width = 720, height = 540, res = 96)
  tbl <- NULL
  out <- capture.output(withCallingHandlers(
    tryCatch({
      exprs <- parse(text = code); n <- length(exprs)
      if (n > 0) for (i in seq_len(n)) {
        rv <- withVisible(eval(exprs[[i]], globalenv()))
        if (i == n && rv$visible && (is.data.frame(rv$value) || is.matrix(rv$value))) tbl <- rv$value
        else if (rv$visible) print(rv$value)
      }
    }, error = function(e) cat("Error:", conditionMessage(e), "\n")),
    # surface messages/warnings/startup messages (they go to stderr otherwise)
    message = function(m) { cat(conditionMessage(m)); invokeRestart("muffleMessage") },
    warning = function(w) { cat("Warning: ", conditionMessage(w), "\n", sep = ""); invokeRestart("muffleWarning") }
  ))
  tryCatch(grDevices::dev.off(), error = function(e) NULL)
  files <- sort(list.files(plotdir, pattern = "\\.png$", full.names = TRUE))
  sz <- file.info(files)$size; files <- files[!is.na(sz) & sz > 0]
  imgs <- vapply(files, function(f) b64(readBin(f, "raw", file.info(f)$size)), character(1), USE.NAMES = FALSE)
  unlink(plotdir, recursive = TRUE)
  imgs_json <- if (length(imgs) == 0) "" else paste0('"', imgs, '"', collapse = ",")
  tables_json <- if (is.null(tbl)) "" else table_json(tbl)
  write_frame(paste0('{"output":', jstr(paste(out, collapse = "\n")),
                     ',"images":[', imgs_json, '],"tables":[', tables_json, ']}'))
}
})
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

proc errorJson(msg: string): string =
  $(%*{"output": msg, "images": newSeq[string](), "tables": newSeq[string]()})

proc spawn(spec: DriverSpec, session: string): Process =
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
    ] & mountFlags(session) # allowlisted mounts + the /work scratch dir
    startProcess("docker", args = flags & @[spec.image] & spec.argv,
                 options = {poUsePath})
  else:
    # Local runner: the work dir is the cwd, so relative file IO is shared
    # across this document's blocks (same as /work under docker).
    startProcess(spec.argv[0], args = spec.argv[1 .. ^1],
                 workingDir = workDir(session), options = {poUsePath})

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
  ## Run `code` in the session for (sessionId, lang); returns (ok, jsonPayload).
  ## The payload is always valid JSON {output, images, tables}.
  {.cast(gcsafe).}:
    if not drivers.hasKey(lang):
      return (false, errorJson("no session driver for language: " & lang))
    let key = sessionId & "\x00" & lang
    var s = sessions.getOrDefault(key, nil)
    if s == nil or not s.p.running:
      if s != nil: closeSession(key, s)
      if sessions.len >= cfgMaxSessions:
        return (false, errorJson("too many live sessions (limit " & $cfgMaxSessions & ")"))
      try:
        s = Session(p: spawn(drivers[lang], sessionId), lang: lang, lastUsed: epochTime())
      except CatchableError:
        return (false, errorJson("could not start session: " & getCurrentExceptionMsg()))
      sessions[key] = s

    try:
      s.p.inputStream.write($code.len & "\n")
      s.p.inputStream.write(code)
      s.p.inputStream.flush()
    except CatchableError:
      closeSession(key, s)
      return (false, errorJson("session write failed: " & getCurrentExceptionMsg()))

    try:
      let frame = readFrame(s.p.outputHandle, epochTime() + cfgTimeout.float)
      s.lastUsed = epochTime()
      discard parseJson(frame) # validate the driver's payload
      return (true, frame)
    except IOError:
      closeSession(key, s)
      return (false, errorJson("session timed out or crashed after " & $cfgTimeout & "s"))
    except JsonParsingError:
      closeSession(key, s)
      return (false, errorJson("session produced malformed output"))

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
