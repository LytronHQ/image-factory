#!/usr/bin/env bash
# Fail if a build-arg that names an image is not an immutable digest reference.
#
# assert-pinned-digests.sh checks ARG defaults in the Dockerfile. A build-arg
# replaces that default at build time, so it gets the same rule before the
# build starts:
#
#   keys *_IMAGE, *_BASE, IMAGE, BASE
#     value must be <name>@sha256:<64 lowercase hex>, and not the all-zero
#     placeholder digest
#
# Other keys are not image references and are ignored. An empty BUILD_ARGS is a
# valid input (most images take no build-args) and passes. An unset BUILD_ARGS
# or a line that is not KEY=VALUE is a wiring mistake and fails with 64.
#
# Usage: BUILD_ARGS=$'KEY=VALUE\nKEY=VALUE' assert-build-args.sh

set -Eeuo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

begin_audit "assert-build-args"

[ -n "${BUILD_ARGS+set}" ] \
  || die "$EX_USAGE" "BUILD_ARGS is not set (newline-separated KEY=VALUE, or an empty string for none)"

REF_RE='^[^[:space:]@]+@sha256:[0-9a-f]{64}$'
ZERO_RE='@sha256:0{64}$'

CHECKED=0
VIOLATIONS=0
n=0

violation() { # violation <key> <message>
  printf 'FAIL  %-24s %s\n' "$1" "$2"
  [ -z "${GITHUB_ACTIONS:-}" ] || printf '::error::build-arg %s %s\n' "$1" "$2"
  VIOLATIONS=$((VIOLATIONS + 1))
}

while IFS= read -r line || [ -n "$line" ]; do
  n=$((n + 1))
  line=${line%$'\r'}
  [ -n "$(trim "$line")" ] || continue
  [[ $line == *=* ]] || die "$EX_USAGE" "build-args line $n is not KEY=VALUE: '$line'"
  key=${line%%=*}
  val=${line#*=}
  case $key in
    *_IMAGE|*_BASE|IMAGE|BASE) ;;
    *) continue ;;
  esac
  CHECKED=$((CHECKED + 1))
  if [[ $val =~ $ZERO_RE ]]; then
    violation "$key" "is the all-zero placeholder digest: $val"
  elif [[ $val =~ $REF_RE ]]; then
    printf 'ok    %-24s %s\n' "$key" "$val"
  else
    violation "$key" "is not a digest reference (<name>@sha256:<64 lowercase hex>): $val"
  fi
done <<< "$BUILD_ARGS"

log "image build-args checked: $CHECKED  violations: $VIOLATIONS"

if [ "$VIOLATIONS" -gt 0 ]; then
  die "$EX_POLICY" "$VIOLATIONS build-arg(s) name an image without an immutable digest"
fi

end_audit
