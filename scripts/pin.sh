#!/usr/bin/env bash
# Resolve image references to digests and rewrite them in place.
#
#   scripts/pin.sh images/base/Dockerfile
#       pins every reference that is not pinned yet: a tag with no digest, or a
#       tag carrying the all-zero placeholder digest. A reference that already
#       has a real digest is left alone; moving it is the explicit form below.
#
#   scripts/pin.sh Dockerfile ghcr.io/me/base:sha-<commit>
#   scripts/pin.sh Dockerfile ghcr.io/me/base@sha256:<digest>
#       resolves that one reference and rewrites every reference to the same
#       repository, whether or not it is already pinned.
#
# Reads the lines that pull an image: "# syntax=", FROM, and ARG defaults whose
# name ends in IMAGE or BASE. Repositories are compared exactly as written, so
# "debian" and "docker.io/library/debian" are different here.
#
# Resolves with crane if it is installed, otherwise docker buildx imagetools.
# Both return the top-level digest (the index, for a multi-platform image).
#
# Run this, read the diff, commit it. Pinning is a deliberate act with a
# reviewable result; it is not something the pipeline does for you. Nothing is
# written unless every reference that needed resolving resolved.

set -Eeuo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

begin_audit "pin"

ZERO_DIGEST="sha256:0000000000000000000000000000000000000000000000000000000000000000"
USAGE="usage: pin.sh <Dockerfile> [image-ref-to-resolve]"

[ "$#" -ge 1 ] && [ "$#" -le 2 ] || die "$EX_USAGE" "$USAGE"
FILE=$1
ONLY=${2:-}
[ -n "$FILE" ] || die "$EX_USAGE" "$USAGE"
[ -f "$FILE" ] || die "$EX_NO_INPUT" "no such file: $FILE"

if command -v crane >/dev/null 2>&1; then
  RESOLVER=crane
elif command -v docker >/dev/null 2>&1; then
  RESOLVER=docker
else
  die "$EX_MISSING_TOOL" "required tool not found: crane, or docker with buildx"
fi

# resolve <ref> -> prints sha256:<64 hex>. Call it only as a plain assignment
# (d=$(resolve x)) so that a failure stops the script.
resolve() {
  local ref=$1 digest=""
  case $RESOLVER in
    crane)  digest=$(crane digest "$ref" 2>/dev/null) ;;
    docker) digest=$(docker buildx imagetools inspect "$ref" --format '{{ .Manifest.Digest }}' 2>/dev/null) ;;
  esac || die "$EX_UNRESOLVABLE" "could not resolve $ref with $RESOLVER (is it public, are you logged in?)"
  if ! [[ $digest =~ ^sha256:[0-9a-f]{64}$ ]] || [ "$digest" = "$ZERO_DIGEST" ]; then
    die "$EX_UNRESOLVABLE" "$RESOLVER returned an unusable digest for $ref: '$digest'"
  fi
  printf '%s' "$digest"
}

name_of() { printf '%s' "${1%%@*}"; }   # reference without its digest

repo_of() {                            # reference without its digest or tag
  local r=${1%%@*}
  case ${r##*/} in *:*) r=${r%:*} ;; esac
  printf '%s' "$r"
}

if [ -n "$ONLY" ]; then
  case $ONLY in
    *'$'*|*[[:space:]]*) die "$EX_USAGE" "not an image reference: '$ONLY'" ;;
  esac
  [[ $ONLY == *[:/@]* ]] || die "$EX_USAGE" "name the repository to pin, e.g. ghcr.io/me/base:tag (got '$ONLY')"
  ONLY_REPO=$(repo_of "$ONLY")
  ONLY_NAME=$(name_of "$ONLY")
  ONLY_DIGEST=$(resolve "$ONLY")
  log "resolved $ONLY -> $ONLY_DIGEST"
fi

# decide <ref> -> sets NEW to the replacement, or leaves it empty to skip.
# Runs in this shell, not a subshell, so a failed resolve stops the script.
NEW=""
decide() {
  local ref=$1 name repo digest="" d
  NEW=""
  case $ref in ''|scratch|*'$'*) return 0 ;; esac
  [[ $ref == *[:/@]* ]] || return 0         # a bare word is a stage name
  name=$(name_of "$ref")
  repo=$(repo_of "$ref")
  if [[ $ref == *@* ]]; then digest=${ref#*@}; fi

  if [ -n "$ONLY" ]; then
    [ "$repo" = "$ONLY_REPO" ] || return 0
    if [ "$name" = "$repo" ]; then           # the file uses no tag: keep none
      NEW="$repo@$ONLY_DIGEST"
    elif [ "$ONLY_NAME" != "$ONLY_REPO" ]; then # both tagged: take the new tag
      NEW="$ONLY_NAME@$ONLY_DIGEST"
    else                                      # keep the file's tag
      NEW="$name@$ONLY_DIGEST"
    fi
    return 0
  fi

  if [ -z "$digest" ]; then
    d=$(resolve "$name")
    NEW="$name@$d"
  elif [ "$digest" = "$ZERO_DIGEST" ]; then
    if [ "$name" = "$repo" ]; then
      die "$EX_UNRESOLVABLE" "$ref is a placeholder with no tag to resolve; name it: pin.sh $FILE $repo:<tag>"
    fi
    d=$(resolve "$name")
    NEW="$name@$d"
  fi
  return 0
}

mapfile -t LINES < "$FILE"
[ "${#LINES[@]}" -gt 0 ] || die "$EX_NO_INPUT" "$FILE is empty"

SYNTAX_RE='^[[:space:]]*#[[:space:]]*syntax[[:space:]]*=[[:space:]]*([^[:space:]]+)'
ARG_RE='^[[:space:]]*[Aa][Rr][Gg][[:space:]]+[A-Za-z_][A-Za-z0-9_]*([Ii][Mm][Aa][Gg][Ee]|[Bb][Aa][Ss][Ee])="?([^"[:space:]]+)'
FROM_RE='^[[:space:]]*[Ff][Rr][Oo][Mm][[:space:]]+(.*)$'

changed=0
matched=0
for i in "${!LINES[@]}"; do
  line=${LINES[$i]}
  ref=""
  if [[ $line =~ $SYNTAX_RE ]]; then
    ref=${BASH_REMATCH[1]}
  elif [[ $line =~ $ARG_RE ]]; then
    ref=${BASH_REMATCH[2]}
  elif [[ $line =~ $FROM_RE ]]; then
    read -ra toks <<< "${BASH_REMATCH[1]}"
    for t in ${toks[@]+"${toks[@]}"}; do
      if [[ $t != --* ]]; then ref=$t; break; fi
    done
  fi
  [ -n "$ref" ] || continue

  decide "$ref"
  [ -n "$NEW" ] || continue
  matched=$((matched + 1))
  if [ "$NEW" = "$ref" ]; then
    log "already pinned $ref"
    continue
  fi
  LINES[i]=${line/"$ref"/"$NEW"}
  log "pin $ref -> $NEW"
  changed=$((changed + 1))
done

if [ -n "$ONLY" ] && [ "$matched" -eq 0 ]; then
  die "$EX_NO_INPUT" "no reference to $ONLY_REPO in $FILE (repositories are compared exactly as written)"
fi

if [ "$changed" -gt 0 ]; then
  printf '%s\n' "${LINES[@]}" > "$FILE"
  log "rewrote $changed reference(s) in $FILE - review the diff before committing"
else
  log "nothing to pin in $FILE"
fi
end_audit
