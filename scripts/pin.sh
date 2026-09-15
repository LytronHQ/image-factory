#!/usr/bin/env bash
# Resolve a mutable tag to a digest and rewrite it in place.
#
#   scripts/pin.sh images/base/Dockerfile
#       rewrites every unpinned FROM in the file by resolving its tag now.
#
#   scripts/pin.sh images/python/Dockerfile ghcr.io/me/base:sha-abc123
#       resolves one reference and rewrites any FROM/ARG line that names it.
#
# Run this, read the diff, commit it. Pinning is a deliberate act with a
# reviewable result; it is not something the pipeline does for you.

set -Eeuo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

begin_audit "pin"
need_tool docker sed

FILE=${1:-}
ONLY=${2:-}
[ -n "$FILE" ] || die "$EX_USAGE" "usage: pin.sh <Dockerfile> [image-ref-to-resolve]"
[ -f "$FILE" ] || die "$EX_NO_INPUT" "no such file: $FILE"

resolve() {
  local ref=$1 digest
  digest=$(docker buildx imagetools inspect "$ref" --format '{{ .Manifest.Digest }}' 2>/dev/null) \
    || die "$EX_UNRESOLVABLE" "could not resolve $ref (is it public, are you logged in?)"
  case $digest in
    sha256:*) printf '%s' "$digest" ;;
    *) die "$EX_UNRESOLVABLE" "unexpected digest for $ref: '$digest'" ;;
  esac
}

mapfile -t LINES < "$FILE"
[ "${#LINES[@]}" -gt 0 ] || die "$EX_NO_INPUT" "$FILE is empty"

changed=0
for line in "${LINES[@]}"; do
  [[ $line =~ ^[[:space:]]*(FROM|from|ARG[[:space:]]+[A-Z_]*IMAGE=|arg[[:space:]]+[a-z_]*image=) ]] || continue
  for tok in $line; do
    case $tok in
      --*|FROM|from|AS|as|ARG|arg) continue ;;
    esac
    ref=${tok#*=}
    case $ref in
      *@sha256:*|scratch|'') continue ;;
      *[:/]*) : ;;
      *) continue ;;
    esac
    [ -z "$ONLY" ] || [ "$ref" = "$ONLY" ] || continue
    digest=$(resolve "$ref")
    base=${ref%@*}
    log "pin $ref -> ${base}@${digest}"
    sed -i.bak "s|${ref}\([[:space:]]\|$\)|${base}@${digest}\1|g" "$FILE"
    rm -f "$FILE.bak"
    changed=$((changed + 1))
  done
done

if [ "$changed" -eq 0 ]; then
  log "nothing to pin in $FILE"
else
  log "rewrote $changed reference(s) in $FILE - review the diff before committing"
fi
end_audit
