## BabelHub server.
##
## Serves the built frontend (Vite's `dist/`) as a single static binary: the
## assets are embedded at compile time, so deployment is one `scp` of this
## binary — no `dist/` directory to ship alongside, no Node on the server.
##
## webR needs a cross-origin-isolated page to use its fast SharedArrayBuffer
## channel, so every response carries the COOP/COEP headers. A TLS terminator
## (Caddy) sits in front; this process speaks plain HTTP on $PORT.

import std/[asynchttpserver, asyncdispatch, os, strutils, tables, json]
import storage, exec, session, gate

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

const jsonType = "application/json"

proc header(req: Request, name: string): string =
  if req.headers.hasKey(name): $req.headers[name] else: ""

proc clientKey(req: Request): string =
  ## Rate-limit key: the real client IP (X-Forwarded-For behind Caddy) or peer.
  let xff = header(req, "X-Forwarded-For")
  if xff.len > 0: xff.split(",")[0].strip() else: req.hostname

proc handleApi(req: Request, route: string) {.async, gcsafe.} =
  # Public capability probe, so the frontend can learn auth/exec state up front.
  if route == "/api/exec" and req.reqMethod == HttpGet:
    let caps = %*{
      "enabled": execEnabled(),
      "authRequired": authRequired(),
      "languages": ephemeralLanguages(),
      "sessionLanguages": sessionLanguages(),
    }
    await req.respond(Http200, $caps, baseHeaders(jsonType))
    return

  # Everything else requires the shared token when one is configured.
  if authRequired() and not checkAuth(header(req, "Authorization")):
    await req.respond(Http401, """{"error":"unauthorized"}""", baseHeaders(jsonType))
    return

  if route == "/api/docs" and req.reqMethod == HttpGet:
    await req.respond(Http200, listDocsJson(), baseHeaders(jsonType))
    return

  if route == "/api/exec" and req.reqMethod == HttpPost:
    if not execEnabled():
      await req.respond(Http403, """{"error":"server execution disabled"}""",
                        baseHeaders(jsonType))
      return
    if not rateAllow(clientKey(req)):
      var h = baseHeaders(jsonType)
      h["Retry-After"] = $rateWindow()
      await req.respond(Http429, """{"error":"rate limited, slow down"}""", h)
      return
    var lang, code, sess: string
    try:
      let body = parseJson(req.body)
      lang = body{"lang"}.getStr
      code = body{"code"}.getStr
      sess = body{"session"}.getStr
    except CatchableError:
      await req.respond(Http400, """{"error":"bad request body"}""", baseHeaders(jsonType))
      return
    if sess.len > 0 and lang in sessionLanguages():
      # Persistent session: shared state across blocks (one interpreter).
      # Driver payload is JSON {output, images, tables}; just stamp ok onto it.
      let (ok, payload) = sessionExec(sess, lang, code)
      var node = parseJson(payload)
      node["ok"] = %ok
      await req.respond(Http200, $node, baseHeaders(jsonType))
    else:
      # Ephemeral: throwaway container per block (text only).
      let (ok, output) = await runBlock(lang, code)
      let node = %*{"ok": ok, "output": output,
                    "images": newSeq[string](), "tables": newSeq[string]()}
      await req.respond(Http200, $node, baseHeaders(jsonType))
    return

  if route == "/api/exec":
    await req.respond(Http405, """{"error":"method not allowed"}""", baseHeaders(jsonType))
    return
  if route.startsWith("/api/docs/"):
    let slug = route["/api/docs/".len .. ^1]
    if not validSlug(slug):
      await req.respond(Http400, """{"error":"invalid name"}""", baseHeaders(jsonType))
      return
    case req.reqMethod
    of HttpGet:
      let (found, body) = readDoc(slug)
      if found:
        await req.respond(Http200, body, baseHeaders("text/plain; charset=utf-8"))
      else:
        await req.respond(Http404, """{"error":"not found"}""", baseHeaders(jsonType))
    of HttpPut:
      writeDoc(slug, req.body)
      await req.respond(Http200, """{"ok":true}""", baseHeaders(jsonType))
    else:
      await req.respond(Http405, """{"error":"method not allowed"}""", baseHeaders(jsonType))
    return
  await req.respond(Http404, """{"error":"not found"}""", baseHeaders(jsonType))

proc handle(req: Request) {.async, gcsafe.} =
  var route = req.url.path
  if route.startsWith("/api/"):
    await handleApi(req, route)
    return
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
  initStore()
  asyncCheck reaper() # close idle persistent sessions
  let port = Port(parseInt(getEnv("PORT", "8080")))
  let server = newAsyncHttpServer()
  echo "BabelHub serving ", embedded.len, " embedded assets on :", $port.uint16
  waitFor server.serve(port, handle)
