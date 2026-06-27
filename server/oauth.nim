## GitHub OAuth — per-user identity beyond the shared token.
##
## Off unless BABELHUB_GH_CLIENT_ID and BABELHUB_GH_CLIENT_SECRET are set (and
## BABELHUB_BASE_URL should be the public origin for the callback). When on, the
## login flow is the standard authorization-code dance with a CSRF `state`:
##
##   /auth/login    -> set a short-lived state cookie, redirect to GitHub
##   /auth/callback -> verify state, exchange code for a token, fetch the user,
##                     create a server session, set an httpOnly session cookie
##   /auth/logout   -> drop the session
##
## Sessions are in-memory (login keyed by an opaque id); a restart logs everyone
## out, which is fine for this stage.

import std/[os, strutils, tables, json, httpclient, uri, sysrand, times]

let
  ghClientId     = getEnv("BABELHUB_GH_CLIENT_ID", "")
  ghClientSecret = getEnv("BABELHUB_GH_CLIENT_SECRET", "")
  baseUrl        = getEnv("BABELHUB_BASE_URL", "http://localhost:8080").strip(
                     leading = false, chars = {'/'})

proc oauthEnabled*(): bool {.gcsafe.} =
  {.cast(gcsafe).}: ghClientId.len > 0 and ghClientSecret.len > 0

proc secureCookies*(): bool {.gcsafe.} =
  ## Mark cookies Secure when the public origin is https (e.g. behind Caddy).
  {.cast(gcsafe).}: baseUrl.startsWith("https")

proc randToken(n: int): string =
  for b in urandom(n): result.add b.toHex(2).toLowerAscii

var sessions = initTable[string, string]() # sessionId -> github login
var states = initTable[string, float]()    # csrf state -> created-at

proc beginLogin*(): (string, string) {.gcsafe.} =
  ## Returns (github authorize URL, state to store in a cookie).
  {.cast(gcsafe).}:
    let state = randToken(16)
    states[state] = epochTime()
    let url = "https://github.com/login/oauth/authorize" &
      "?client_id=" & encodeUrl(ghClientId) &
      "&redirect_uri=" & encodeUrl(baseUrl & "/auth/callback") &
      "&scope=" & encodeUrl("read:user") &
      "&state=" & encodeUrl(state)
    result = (url, state)

proc completeLogin*(code, state, cookieState: string): (bool, string) {.gcsafe.} =
  ## Verify the CSRF state, exchange the code, fetch the user. Returns
  ## (ok, sessionId) — set sessionId as the session cookie on success.
  {.cast(gcsafe).}:
    if code.len == 0 or state.len == 0 or state != cookieState or not states.hasKey(state):
      return (false, "")
    states.del(state)

    var client = newHttpClient(timeout = 10_000)
    defer: client.close()
    var token, login: string
    try:
      client.headers = newHttpHeaders({
        "Accept": "application/json",
        "Content-Type": "application/x-www-form-urlencoded",
        "User-Agent": "BabelHub",
      })
      let body = "client_id=" & encodeUrl(ghClientId) &
                 "&client_secret=" & encodeUrl(ghClientSecret) &
                 "&code=" & encodeUrl(code) &
                 "&redirect_uri=" & encodeUrl(baseUrl & "/auth/callback")
      token = parseJson(client.postContent(
        "https://github.com/login/oauth/access_token", body)){"access_token"}.getStr
      if token.len == 0: return (false, "")

      client.headers = newHttpHeaders({
        "Authorization": "Bearer " & token,
        "Accept": "application/vnd.github+json",
        "User-Agent": "BabelHub",
      })
      login = parseJson(client.getContent("https://api.github.com/user")){"login"}.getStr
    except CatchableError:
      return (false, "")
    if login.len == 0: return (false, "")

    let sid = randToken(24)
    sessions[sid] = login
    result = (true, sid)

proc userForSession*(sid: string): string {.gcsafe.} =
  {.cast(gcsafe).}:
    if sid.len == 0: "" else: sessions.getOrDefault(sid, "")

proc endSession*(sid: string) {.gcsafe.} =
  {.cast(gcsafe).}: sessions.del(sid)
