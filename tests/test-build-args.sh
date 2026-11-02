#!/usr/bin/env bash
# Prove the build-arg gate fails. A build-arg overrides the Dockerfile's pinned
# ARG default, so a gate that lets a tag or a malformed digest through here
# undoes the pinning gate entirely.
#
# Each case asserts an exact exit code, not merely "non-zero".

set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
GATE="$ROOT/scripts/assert-build-args.sh"
D="sha256:aaaaaaaabbbbbbbbccccccccdddddddd00000000111111112222222233333333"
Z="sha256:0000000000000000000000000000000000000000000000000000000000000000"
U="sha256:AAAAAAAABBBBBBBBCCCCCCCCDDDDDDDD00000000111111112222222233333333"

PASS=0
FAIL=0

expect() { # expect <expected-code> <label> <build-args> [dockerfile...]
  local want=$1 label=$2 args=$3 got=0 out
  shift 3
  out=$(BUILD_ARGS="$args" "$GATE" "$@" 2>&1) || got=$?
  if [ "$got" -eq "$want" ]; then
    printf 'PASS  %-46s exit %s\n' "$label" "$got"
    PASS=$((PASS + 1))
  else
    printf 'FAIL  %-46s want %s got %s\n' "$label" "$want" "$got"
    printf '%s\n' "$out" | sed 's/^/        /'
    FAIL=$((FAIL + 1))
  fi
}

expect 0  "no build-args at all"                        ""
expect 0  "image build-arg pinned by digest"            "BASE_IMAGE=ghcr.io/o/base@$D"
expect 0  "non-image build-arg is ignored"              "VERSION=1.2.3"
expect 1  "image build-arg with a tag"                  "BASE_IMAGE=ghcr.io/o/base:latest"
expect 1  "short digest"                                "BASE_IMAGE=ghcr.io/o/base@sha256:abc"
expect 1  "all-zero placeholder digest"                 "BASE_IMAGE=ghcr.io/o/base@$Z"
expect 1  "uppercase hex digest"                        "BASE_IMAGE=ghcr.io/o/base@$U"
expect 1  "digest followed by trailing text"            "BASE_IMAGE=ghcr.io/o/base@$D-x"
expect 1  "*_BASE build-arg with a tag"                 "RUNTIME_BASE=debian:12-slim"
expect 1  "one good build-arg and one bad"              "BASE_IMAGE=ghcr.io/o/base@$D"$'\n'"OTHER_IMAGE=alpine:3"
expect 64 "line that is not KEY=VALUE"                  "BASE_IMAGE"
expect 1  "lowercase image key with a tag"              "base_image=debian:12-slim"

# With the Dockerfile, any build-arg that overrides an ARG used in an image
# position is an image build-arg, whatever its name (audit 2026-11-02: SRC=tag
# passed both gates).
DF="$ROOT/tests/fixtures/good/Dockerfile.image-arg-other-name"
expect 1  "override of an image ARG not named *_IMAGE"  "SRC=docker.io/library/debian:latest" "$DF"
expect 0  "same override pinned by digest"              "SRC=docker.io/library/debian@$D" "$DF"
expect 0  "non-image build-arg with a Dockerfile"       "VERSION=1.2.3" "$DF"
expect 71 "Dockerfile that does not exist"              "VERSION=1.2.3" "$ROOT/tests/fixtures/bad/does-not-exist"

# An unset BUILD_ARGS is a wiring mistake, not "no build-args".
got=0
env -u BUILD_ARGS "$GATE" >/dev/null 2>&1 || got=$?
if [ "$got" -eq 64 ]; then
  printf 'PASS  %-46s exit 64\n' "BUILD_ARGS unset"
  PASS=$((PASS + 1))
else
  printf 'FAIL  %-46s want 64 got %s\n' "BUILD_ARGS unset" "$got"
  FAIL=$((FAIL + 1))
fi

echo ""
echo "build-arg gate self-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
[ "$PASS" -eq 17 ] || { echo "expected 17 cases, ran $PASS" >&2; exit 71; }
echo "OK"
