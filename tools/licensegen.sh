#!/usr/bin/env sh
# Issue a signed BabelHub license token.
#   licensegen.sh <private-key> <subject> <tier> <exp-unix|0> [feat,feat,...]
# exp 0 = perpetual. Empty features = all features.
# Run this on payment (e.g. from your Stripe fulfillment step) and send the
# printed token to the customer; they set it as BABELHUB_LICENSE.
set -eu

priv="$1"; sub="$2"; tier="$3"; exp="$4"; feats="${5:-}"

if [ -n "$feats" ]; then
  fjson=$(printf '%s' "$feats" | awk -F, '{o="";for(i=1;i<=NF;i++)o=o (i>1?",":"") "\"" $i "\"";print o}')
  features=",\"features\":[$fjson]"
else
  features=""
fi

payload=$(printf '{"sub":"%s","tier":"%s","exp":%s,"iat":%s,"id":"%s"%s}' \
  "$sub" "$tier" "$exp" "$(date +%s)" "$(openssl rand -hex 8)" "$features")

msg=$(printf '%s' "$payload" | base64 -w0)
# Ed25519 one-shot signing needs a seekable input file, not a pipe.
tmp=$(mktemp)
printf '%s' "$msg" > "$tmp"
sig=$(openssl pkeyutl -sign -inkey "$priv" -rawin -in "$tmp" | base64 -w0)
rm -f "$tmp"
printf '%s.%s\n' "$msg" "$sig"
