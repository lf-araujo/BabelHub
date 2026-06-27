## Access gate for the API: a shared-token auth check and a per-client rate
## limiter. This is the safety gate that makes server execution exposable —
## without a token configured everything stays open (local/dev behaviour);
## with BABELHUB_TOKEN set, protected endpoints require it.
##
## A single shared token is deliberately the minimal gate ("trusted users with
## the token"). Per-user identity (GitHub OAuth) is the next step for real
## multi-user deployments.

import std/[os, strutils, tables, times]

let
  cfgToken  = getEnv("BABELHUB_TOKEN", "")
  cfgRate   = parseInt(getEnv("BABELHUB_RATE", "30"))
  cfgWindow = parseInt(getEnv("BABELHUB_RATE_WINDOW", "60"))

proc authRequired*(): bool {.gcsafe.} =
  {.cast(gcsafe).}: cfgToken.len > 0

proc constTimeEq(a, b: string): bool =
  ## Length-independent only in content comparison; length may differ.
  if a.len != b.len: return false
  var diff = 0
  for i in 0 ..< a.len:
    diff = diff or (ord(a[i]) xor ord(b[i]))
  diff == 0

proc checkAuth*(authHeader: string): bool {.gcsafe.} =
  ## Accept "Bearer <token>" matching BABELHUB_TOKEN. No token set ⇒ open.
  {.cast(gcsafe).}:
    if cfgToken.len == 0: return true
    const prefix = "Bearer "
    if not authHeader.startsWith(prefix): return false
    constTimeEq(authHeader[prefix.len .. ^1].strip(), cfgToken)

type Bucket = object
  count: int
  windowStart: float

var buckets = initTable[string, Bucket]()

proc rateAllow*(key: string): bool {.gcsafe.} =
  ## Fixed-window limiter: cfgRate requests per cfgWindow seconds, per key.
  {.cast(gcsafe).}:
    let now = epochTime()
    var b = buckets.getOrDefault(key, Bucket(count: 0, windowStart: now))
    if now - b.windowStart >= cfgWindow.float:
      b = Bucket(count: 0, windowStart: now)
    if b.count >= cfgRate:
      buckets[key] = b
      return false
    inc b.count
    buckets[key] = b
    true

proc rateWindow*(): int {.gcsafe.} =
  {.cast(gcsafe).}: cfgWindow
