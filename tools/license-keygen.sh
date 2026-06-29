#!/usr/bin/env sh
# Generate the issuer Ed25519 keypair (run ONCE).
#   - babelhub-license.key  : PRIVATE key — keep secret, never commit.
#   - prints the PUBLIC key  : paste into server/license.nim (publicKeyB64).
set -eu

out="${1:-babelhub-license.key}"
if [ -e "$out" ]; then
  echo "refusing to overwrite existing $out" >&2
  exit 1
fi
openssl genpkey -algorithm ed25519 -out "$out"
chmod 600 "$out"
echo "private key -> $out  (KEEP SECRET — never commit)"
echo "public key (embed in server/license.nim as publicKeyB64):"
openssl pkey -in "$out" -pubout -outform DER | tail -c 32 | base64 -w0
echo
