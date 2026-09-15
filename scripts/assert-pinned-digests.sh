#!/usr/bin/env bash
# Fail if any image reference in any Dockerfile is mutable.
#
# Covers, because all of these pull content at build time:
#   FROM <ref>
#   COPY --from=<ref>
#   RUN --mount=...,from=<ref>
#   # syntax=<ref>          (BuildKit frontend)
#
# Accepted as immutable:
#   anything ending in @sha256:<64 hex>, except the all-zero digest, which is
#   the placeholder these Dockerfiles ship with and names no real image
#   scratch
#   a stage name declared earlier in the same file (FROM x AS name)
#   a stage index used by COPY --from=0
#
# ARG-substituted refs are resolved from ARG defaults in the same file. If a
# ref cannot be resolved, that is a failure (72), not a pass.
#
# Usage: assert-pinned-digests.sh [file...]      (default: discover from CWD)
#
# Discovery skips ./tests/fixtures, which deliberately contains bad input used
# to prove this script fails when it should. Pass those paths explicitly.

set -Eeuo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

begin_audit "assert-pinned-digests"

if [ "${BASH_VERSINFO[0]}" -lt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -lt 3 ]; }; then
  die "$EX_MISSING_TOOL" "bash >= 4.3 required (found ${BASH_VERSION})"
fi

DIGEST_SUFFIX='@sha256:[0-9a-f]{64}$'
ZERO_DIGEST_SUFFIX='@sha256:0{64}$'

VIOLATIONS=0
REFS_CHECKED=0

report_violation() {
  printf 'FAIL  %-44s %s\n' "$1" "$2"
  VIOLATIONS=$((VIOLATIONS + 1))
}

report_ok() {
  printf 'ok    %-44s %s\n' "$1" "$2"
}

# Join backslash continuations so that flags split across lines are seen.
read_logical_lines() {
  local f=$1 acc="" line
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    if [[ $line =~ \\[[:space:]]*$ ]]; then
      acc+="${line%%\\*} "
      continue
    fi
    printf '%s\n' "$acc$line"
    acc=""
  done < "$f"
  [ -z "$acc" ] || printf '%s\n' "$acc"
}

# Parser state. Global on purpose: bash namerefs collide with same-named
# locals, and a silently-wrong nameref would make this gate pass by accident.
declare -A ARGMAP=()
declare -A STAGEMAP=()

# expand_args <ref> -> prints the expanded ref; returns 2 if a variable has no
# ARG default in this file, which is a failure, never a pass.
expand_args() {
  local s=$1 name val
  for _ in 1 2 3 4 5 6 7 8; do
    [[ $s == *'$'* ]] || break
    if   [[ $s =~ \$\{([A-Za-z_][A-Za-z0-9_]*)\} ]]; then name=${BASH_REMATCH[1]}
    elif [[ $s =~ \$([A-Za-z_][A-Za-z0-9_]*)      ]]; then name=${BASH_REMATCH[1]}
    else break
    fi
    if [[ -n ${ARGMAP[$name]+set} ]]; then
      val=${ARGMAP[$name]}
      s=${s//\$\{$name\}/$val}
      s=${s//\$$name/$val}
    else
      printf '%s' "$s"
      return 2
    fi
  done
  printf '%s' "$s"
}

# check_ref <where> <raw-ref>
check_ref() {
  local where=$1 raw=$2 ref lower rc=0

  if [ -z "$raw" ]; then
    report_violation "$where" "empty image reference"
    return 1
  fi

  REFS_CHECKED=$((REFS_CHECKED + 1))

  ref=$(expand_args "$raw") || rc=$?
  if [ "$rc" -eq 2 ]; then
    report_violation "$where" "unresolvable reference '$raw' (no ARG default in this file)"
    return 1
  fi

  lower=${ref,,}

  if [ "$lower" = "scratch" ]; then
    report_ok "$where" "scratch"
    return 0
  fi
  if [[ -n ${STAGEMAP[$lower]+set} ]]; then
    report_ok "$where" "stage '$ref'"
    return 0
  fi
  if [[ $ref =~ ^[0-9]+$ ]]; then
    report_ok "$where" "stage index $ref"
    return 0
  fi
  if [[ $ref =~ $ZERO_DIGEST_SUFFIX ]]; then
    report_violation "$where" "all-zero placeholder digest '$ref' (resolve it with 'make pin')"
    return 1
  fi
  if [[ $ref =~ $DIGEST_SUFFIX ]]; then
    report_ok "$where" "$ref"
    return 0
  fi
  report_violation "$where" "mutable reference '$ref' (must end in @sha256:<64 hex>)"
  return 1
}

check_file() {
  local f=$1
  [ -r "$f" ] || die "$EX_NO_INPUT" "cannot read $f"

  ARGMAP=()
  STAGEMAP=()
  local n=0 froms=0
  local lline kw rest tok t sref part
  local -a toks mparts

  while IFS= read -r lline; do
    n=$((n + 1))

    if [[ $lline =~ ^[[:space:]]*#[[:space:]]*syntax[[:space:]]*= ]]; then
      sref=$(trim "${lline#*=}")
      REFS_CHECKED=$((REFS_CHECKED + 1))
      if [[ $sref =~ $ZERO_DIGEST_SUFFIX ]]; then
        report_violation "$f:$n (syntax)" "all-zero placeholder digest '$sref' (resolve it with 'make pin')"
      elif [[ $sref =~ $DIGEST_SUFFIX ]]; then
        report_ok "$f:$n (syntax)" "$sref"
      else
        report_violation "$f:$n (syntax)" "mutable BuildKit frontend '$sref'"
      fi
      continue
    fi

    [[ $lline =~ ^[[:space:]]*# ]] && continue
    [[ -z ${lline//[[:space:]]/} ]] && continue

    kw=""; rest=""
    read -r kw rest <<<"$lline" || true
    [ -n "$kw" ] || continue

    case ${kw,,} in
      arg)
        for tok in $rest; do
          [[ $tok == *=* ]] && ARGMAP[${tok%%=*}]=${tok#*=}
        done
        ;;
      from)
        froms=$((froms + 1))
        toks=()
        for t in $rest; do
          [[ $t == --* ]] && continue
          toks+=("$t")
        done
        if [ ${#toks[@]} -lt 1 ]; then
          report_violation "$f:$n" "FROM with no image reference"
          continue
        fi
        if [ ${#toks[@]} -ge 3 ] && [ "${toks[1],,}" = "as" ]; then
          STAGEMAP[${toks[2],,}]=1
        fi
        check_ref "$f:$n" "${toks[0]}" || true
        ;;
      copy|run|add)
        for t in $rest; do
          case $t in
            --from=*)
              check_ref "$f:$n (--from)" "${t#--from=}" || true
              ;;
            --mount=*)
              mparts=()
              IFS=',' read -ra mparts <<<"${t#--mount=}"
              for part in "${mparts[@]}"; do
                if [[ $part == from=* ]]; then
                  check_ref "$f:$n (--mount from)" "${part#from=}" || true
                fi
              done
              ;;
          esac
        done
        ;;
    esac
  done < <(read_logical_lines "$f")

  if [ "$froms" -eq 0 ]; then
    die "$EX_NO_INPUT" "$f contains no FROM instruction - refusing to report it as pinned"
  fi
}

FILES=()
if [ "$#" -gt 0 ]; then
  FILES=("$@")
else
  while IFS= read -r -d '' f; do FILES+=("$f"); done < <(
    find . -path ./.git -prune -o -path './tests/fixtures' -prune -o -type f \
      \( -name 'Dockerfile' -o -name 'Dockerfile.*' -o -name '*.Dockerfile' -o -name 'Containerfile' \) \
      -print0
  )
fi

require_nonempty "${#FILES[@]}" "Dockerfiles to audit under $PWD"

log "auditing ${#FILES[@]} file(s)"
for f in "${FILES[@]}"; do
  check_file "$f"
done

require_nonempty "$REFS_CHECKED" "image references found across ${#FILES[@]} file(s)"

log ""
log "files: ${#FILES[@]}  references checked: $REFS_CHECKED  violations: $VIOLATIONS"

if [ "$VIOLATIONS" -gt 0 ]; then
  die "$EX_POLICY" "$VIOLATIONS mutable image reference(s). Pin them with 'make pin' or scripts/pin.sh."
fi

end_audit
