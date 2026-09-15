#!/usr/bin/env bash
# verify.sh guardrails. These do not need a registry: they test the ways
# verify.sh must refuse to run, which are the ways it could otherwise have
# reported a meaningless pass.

set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
V="$ROOT/verify.sh"
DIG="sha256:1111111111111111111111111111111111111111111111111111111111111111"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
for t in cosign syft; do printf '#!/bin/sh\nexit 1\n' > "$TMP/bin/$t"; chmod +x "$TMP/bin/$t"; done

PASS=0; FAIL=0
expect() { # expect <code> <label> <PATH> <args...>
  local want=$1 label=$2 path=$3; shift 3
  local got=0
  PATH="$path" "$V" "$@" >/dev/null 2>&1 || got=$?
  if [ "$got" -eq "$want" ]; then
    printf 'PASS  %-46s exit %s\n' "$label" "$got"; PASS=$((PASS+1))
  else
    printf 'FAIL  %-46s want %s got %s\n' "$label" "$want" "$got"; FAIL=$((FAIL+1))
  fi
}

BARE="/usr/bin:/bin"                 # no cosign, no syft
FULL="$TMP/bin:/usr/bin:/bin"        # stubs present, jq present

expect 70 "missing cosign/syft"                "$BARE" --image "ghcr.io/x/y@$DIG" --repo o/r
expect 64 "no --image"                         "$FULL" --repo o/r
expect 64 "tag instead of digest"              "$FULL" --image "ghcr.io/x/y:latest" --repo o/r
expect 64 "short digest"                       "$FULL" --image "ghcr.io/x/y@sha256:abc" --repo o/r
expect 64 "no identity and no repo"            "$FULL" --image "ghcr.io/x/y@$DIG"
expect 64 "unknown flag"                       "$FULL" --image "ghcr.io/x/y@$DIG" --repo o/r --yolo

# A permissive identity regexp must be reported as a failed check, not accepted.
out=$(PATH="$FULL" "$V" --image "ghcr.io/x/y@$DIG" --identity-regexp '.*' 2>&1 || true)
if printf '%s' "$out" | grep -q "FAIL  signer_identity_is_specific"; then
  printf 'PASS  %-46s\n' "permissive identity regexp rejected"; PASS=$((PASS+1))
else
  printf 'FAIL  %-46s\n' "permissive identity regexp rejected"; FAIL=$((FAIL+1))
fi

# With every cosign call failing, verify.sh must exit 74, never 0.
got=0
PATH="$FULL" "$V" --image "ghcr.io/x/y@$DIG" --repo o/r >/dev/null 2>&1 || got=$?
if [ "$got" -eq 74 ]; then
  printf 'PASS  %-46s exit 74\n' "all checks failing exits 74"; PASS=$((PASS+1))
else
  printf 'FAIL  %-46s want 74 got %s\n' "all checks failing exits 74" "$got"; FAIL=$((FAIL+1))
fi

echo ""
echo "verify guardrails: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
[ "$PASS" -eq 8 ] || { echo "expected 8 cases, ran $PASS" >&2; exit 71; }
echo "OK"
