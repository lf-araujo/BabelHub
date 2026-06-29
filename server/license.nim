## Offline license verification (open-core commercial gate).
##
## A license is an Ed25519-signed token "<payloadB64>.<sigB64>", where payload is
## JSON {sub, tier, exp, iat, id, features?}. The binary embeds the issuer's
## *public* key and verifies signatures offline — no license server, no network.
## The matching *private* key lives only in the issuer's key-generator tool.
##
## Server-side execution (the paid tier) requires a valid license; without one,
## BabelHub runs community mode (client-side webR/Pyodide only). The code is
## AGPL and visible — the license is the supported, paid path, not DRM.
##
## Set BABELHUB_LICENSE to the token, or BABELHUB_LICENSE_FILE to a file holding it.

import std/[os, strutils, base64, json, times]

# Issuer public key (raw 32-byte Ed25519, base64). REPLACE for a production build
# with your own key; keep the private key secret (never in this repo). The value
# below is a throwaway test key.
const publicKeyB64 = "gCKB+W+cOrmr8hqyOymvK6ORcfdZsB8HRZxBG10d3m0="

# --- OpenSSL Ed25519 verify (libcrypto is already linked via -d:ssl) ----------
when defined(windows):
  const cryptoDll = "(libcrypto-3-x64|libcrypto-1_1-x64|libeay32).dll"
elif defined(macosx):
  const cryptoDll = "(libcrypto.3|libcrypto.1.1|libcrypto).dylib"
else:
  const cryptoDll = "libcrypto.so(.3|.1.1|)"

type
  EVP_PKEY = pointer
  EVP_MD_CTX = pointer

const NID_ED25519 = 1087.cint

proc EVP_PKEY_new_raw_public_key(typ: cint, e: pointer, key: ptr byte,
  keylen: csize_t): EVP_PKEY {.cdecl, importc, dynlib: cryptoDll.}
proc EVP_PKEY_free(p: EVP_PKEY) {.cdecl, importc, dynlib: cryptoDll.}
proc EVP_MD_CTX_new(): EVP_MD_CTX {.cdecl, importc, dynlib: cryptoDll.}
proc EVP_MD_CTX_free(ctx: EVP_MD_CTX) {.cdecl, importc, dynlib: cryptoDll.}
proc EVP_DigestVerifyInit(ctx: EVP_MD_CTX, pctx: pointer, typ: pointer,
  e: pointer, pkey: EVP_PKEY): cint {.cdecl, importc, dynlib: cryptoDll.}
proc EVP_DigestVerify(ctx: EVP_MD_CTX, sig: ptr byte, siglen: csize_t,
  tbs: ptr byte, tbslen: csize_t): cint {.cdecl, importc, dynlib: cryptoDll.}

proc ed25519Verify(pub, msg, sig: string): bool =
  if pub.len != 32 or msg.len == 0 or sig.len == 0: return false
  let pkey = EVP_PKEY_new_raw_public_key(NID_ED25519, nil,
    cast[ptr byte](unsafeAddr pub[0]), 32.csize_t)
  if pkey.isNil: return false
  defer: EVP_PKEY_free(pkey)
  let ctx = EVP_MD_CTX_new()
  if ctx.isNil: return false
  defer: EVP_MD_CTX_free(ctx)
  if EVP_DigestVerifyInit(ctx, nil, nil, nil, pkey) != 1: return false
  result = EVP_DigestVerify(ctx,
    cast[ptr byte](unsafeAddr sig[0]), sig.len.csize_t,
    cast[ptr byte](unsafeAddr msg[0]), msg.len.csize_t) == 1

# --- license parsing ----------------------------------------------------------
type License = object
  valid: bool
  sub, tier: string
  exp: int64
  features: seq[string]

proc parse(token: string): License =
  let parts = token.strip().split('.')
  if parts.len != 2: return
  var sig: string
  try: sig = base64.decode(parts[1])
  except CatchableError: return
  if not ed25519Verify(base64.decode(publicKeyB64), parts[0], sig): return
  var payload: JsonNode
  try: payload = parseJson(base64.decode(parts[0]))
  except CatchableError: return
  let exp = payload{"exp"}.getBiggestInt(0)
  if exp != 0 and epochTime().int64 > exp: return # expired
  result.sub = payload{"sub"}.getStr
  result.tier = payload{"tier"}.getStr
  result.exp = exp
  if payload.hasKey("features"):
    for f in payload["features"]: result.features.add f.getStr
  result.valid = true

let current = block:
  let env = getEnv("BABELHUB_LICENSE", "")
  let file = getEnv("BABELHUB_LICENSE_FILE", "")
  let token =
    if env.len > 0: env
    elif file.len > 0 and fileExists(file): readFile(file)
    else: ""
  if token.len > 0: parse(token) else: License(valid: false)

proc licensed*(): bool {.gcsafe.} =
  {.cast(gcsafe).}: current.valid

proc licenseAllows*(feature: string): bool {.gcsafe.} =
  ## Valid license with the feature (empty features list = all features).
  {.cast(gcsafe).}:
    current.valid and (current.features.len == 0 or feature in current.features)

proc licenseJson*(): string {.gcsafe.} =
  {.cast(gcsafe).}:
    if not current.valid: return """{"licensed":false}"""
    $(%*{"licensed": true, "sub": current.sub, "tier": current.tier, "exp": current.exp})
