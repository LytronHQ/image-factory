#!/usr/bin/env bash
# Prove the pinning gate actually fails. A gate that has only ever been seen
# to pass is indistinguishable from a gate that always passes.
#
# Each case asserts an exact exit code, not merely "non-zero", so that a
# script crashing for an unrelated reason cannot be read as a policy failure.

set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
GATE="$ROOT/scripts/assert-pinned-digests.sh"
FIX="$ROOT/tests/fixtures"

PASS=0
FAIL=0

expect() { # expect <expected-code> <label> <file...>
  local want=$1 label=$2; shift 2
  local got=0 out
  out=$("$GATE" "$@" 2>&1) || got=$?
  if [ "$got" -eq "$want" ]; then
    printf 'PASS  %-46s exit %s\n' "$label" "$got"
    PASS=$((PASS + 1))
  else
    printf 'FAIL  %-46s want %s got %s\n' "$label" "$want" "$got"
    printf '%s\n' "$out" | sed 's/^/        /'
    FAIL=$((FAIL + 1))
  fi
}

expect 0  "pinned multi-stage with ARG and COPY --from" "$FIX/good/Dockerfile.multistage"
expect 1  "mutable FROM tag"                            "$FIX/bad/Dockerfile.mutable-tag"
expect 1  "COPY --from with a tag"                      "$FIX/bad/Dockerfile.copy-from-tag"
expect 1  "RUN --mount=from with a tag"                 "$FIX/bad/Dockerfile.mount-from-tag"
expect 1  "unresolvable ARG in FROM"                    "$FIX/bad/Dockerfile.unresolvable"
expect 1  "unpinned BuildKit syntax directive"          "$FIX/bad/Dockerfile.mutable-syntax"

# The all-zero digest is the shipped placeholder. It is well formed, so it must
# be rejected by value, wherever it appears.
expect 1  "all-zero placeholder digest in FROM"         "$FIX/bad/Dockerfile.zero-digest"
expect 1  "all-zero placeholder digest behind an ARG"   "$FIX/bad/Dockerfile.zero-digest-arg"
expect 1  "all-zero placeholder syntax directive"       "$FIX/bad/Dockerfile.zero-digest-syntax"
expect 71 "file with no FROM at all"                    "$FIX/bad/Dockerfile.no-from"
expect 71 "missing file"                                "$FIX/bad/does-not-exist"

# One bad file among good ones must still fail: the gate is not "most files ok".
expect 1  "one bad file mixed with good"                "$FIX/good/Dockerfile.multistage" "$FIX/bad/Dockerfile.mutable-tag"

# An empty directory must not report success.
EMPTY=$(mktemp -d)
trap 'rm -rf "$EMPTY"' EXIT
( cd "$EMPTY" && "$GATE" >/dev/null 2>&1 ) && rc=0 || rc=$?
if [ "${rc:-0}" -eq 71 ]; then
  printf 'PASS  %-46s exit 71\n' "empty tree is not a pass"
  PASS=$((PASS + 1))
else
  printf 'FAIL  %-46s want 71 got %s\n' "empty tree is not a pass" "${rc:-0}"
  FAIL=$((FAIL + 1))
fi

echo ""
echo "policy gate self-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
[ "$PASS" -eq 13 ] || { echo "expected 13 cases, ran $PASS" >&2; exit 71; }
echo "OK"
