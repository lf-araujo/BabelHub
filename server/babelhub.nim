## BabelHub server.
##
## Serves the built frontend (Vite's `dist/`) as a single static binary: the
## assets are embedded at compile time, so deployment is one `scp` of this
## binary — no `dist/` directory to ship alongside, no Node on the server.
##
## webR needs a cross-origin-isolated page to use its fast SharedArrayBuffer
## channel, so every response carries the COOP/COEP headers. A TLS terminator
## (Caddy) sits in front; this process speaks plain HTTP on $PORT.

import std/[asynchttpserver, asyncdispatch, os, strutils, tables]

const distDir = normalizedPath(currentSourcePath().parentDir / ".." / "dist")

proc loadAssets(): seq[(string, string)] {.compileTime.} =
  ## Walk dist/ at compile time and embed every file, keyed by its URL path.
  let listing = staticExec("find '" & distDir & "' -type f")
  for path in listing.splitLines():
    if path.len == 0: continue
    var route = path
    route.removePrefix(distDir) # -> "/assets/index-xxxx.js", "/index.html", ...
    result.add (route, staticRead(path))

const embedded = loadAssets()

const mimeByExt = {
  ".html": "text/html; charset=utf-8",
  ".js":   "text/javascript; charset=utf-8",
  ".mjs":  "text/javascript; charset=utf-8",
  ".css":  "text/css; charset=utf-8",
  ".json": "application/json",
  ".map":  "application/json",
  ".svg":  "image/svg+xml",
  ".ico":  "image/x-icon",
  ".png":  "image/png",
  ".woff2": "font/woff2",
  ".wasm": "application/wasm",
  ".org":  "text/plain; charset=utf-8",
}.toTable

proc contentType(route: string): string =
  mimeByExt.getOrDefault(splitFile(route).ext.toLowerAscii, "application/octet-stream")

proc assetBody(route: string): (bool, string) =
  ## Look an asset up by URL path. `embedded` is a compile-time const, so this
  ## stays gc-safe; a handful of files makes the linear scan a non-issue.
  for (r, body) in embedded:
    if r == route:
      return (true, body)
  (false, "")

proc baseHeaders(ctype: string): HttpHeaders =
  newHttpHeaders({
    "Content-Type": ctype,
    # Cross-origin isolation — required for webR's SharedArrayBuffer channel.
    "Cross-Origin-Opener-Policy": "same-origin",
    "Cross-Origin-Embedder-Policy": "require-corp",
  })

proc handle(req: Request) {.async, gcsafe.} =
  var route = req.url.path
  if route.len == 0 or route == "/":
    route = "/index.html"
  let (found, body) = assetBody(route)
  if found:
    await req.respond(Http200, body, baseHeaders(contentType(route)))
  else:
    await req.respond(Http404, "Not found\n", baseHeaders("text/plain"))

when isMainModule:
  if embedded.len == 0:
    stderr.writeLine "No embedded assets — run `npm run build` before compiling."
    quit 1
  let port = Port(parseInt(getEnv("PORT", "8080")))
  let server = newAsyncHttpServer()
  echo "BabelHub serving ", embedded.len, " embedded assets on :", $port.uint16
  waitFor server.serve(port, handle)
