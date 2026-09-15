#!/usr/bin/env bash
# Scan the PUSHED image (pulled from the registry by digest, not the local
# build cache) and apply policy:
#
#   fixable HIGH/CRITICAL          -> fail, unless a live exception covers it
#   unfixable HIGH/CRITICAL        -> recorded in unfixable.json, does not fail
#   expired exception              -> fail (73). Thresholds are never lowered.
#   scanner found zero packages    -> fail (71). A clean scan of nothing is not clean.
#
# Usage:
#   scan.sh --image ghcr.io/o/n@sha256:... --out DIR [--exceptions FILE] [--min-packages N]

set -Eeuo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

begin_audit "vulnerability-scan"

IMAGE=""; OUT=""; EXC=""; MIN_PKGS=1
while [ "$#" -gt 0 ]; do
  case $1 in
    --image)         IMAGE=$2; shift 2 ;;
    --out)           OUT=$2; shift 2 ;;
    --exceptions)    EXC=$2; shift 2 ;;
    --min-packages)  MIN_PKGS=$2; shift 2 ;;
    *) die "$EX_USAGE" "unknown argument: $1" ;;
  esac
done

[ -n "$IMAGE" ] || die "$EX_USAGE" "--image is required"
[ -n "$OUT" ]   || die "$EX_USAGE" "--out is required"
case $IMAGE in
  *@sha256:*) : ;;
  *) die "$EX_USAGE" "--image must be a digest reference, got '$IMAGE'" ;;
esac

need_tool trivy jq date
mkdir -p "$OUT"

# ---------------------------------------------------------------- exceptions
LIVE_EXC='[]'
if [ -n "$EXC" ] && [ -f "$EXC" ]; then
  jq -e 'type == "object" and (.exceptions | type == "array")' "$EXC" >/dev/null 2>&1 \
    || die "$EX_USAGE" "$EXC is not {\"exceptions\": [...]}"

  now=$(date -u +%s)
  expired=()
  live_json_lines=""
  while IFS=$'\t' read -r id pkg reason expires; do
    [ -n "$id" ]      || die "$EX_USAGE" "$EXC: an exception has no 'id'"
    [ -n "$reason" ]  || die "$EX_USAGE" "$EXC: exception $id has no 'reason'"
    [ -n "$expires" ] || die "$EX_USAGE" "$EXC: exception $id has no 'expires'"
    exp=$(date -u -d "$expires" +%s 2>/dev/null) \
      || die "$EX_USAGE" "$EXC: exception $id has an unparseable expiry '$expires'"
    if [ "$exp" -lt "$now" ]; then
      expired+=("$id expired $expires")
    else
      live_json_lines+=$(jq -cn --arg id "$id" --arg pkg "$pkg" '{id:$id,package:$pkg}')$'\n'
    fi
  done < <(jq -r '.exceptions[] | [.id, (.package // "*"), (.reason // ""), (.expires // "")] | @tsv' "$EXC")

  if [ "${#expired[@]}" -gt 0 ]; then
    printf 'EXPIRED EXCEPTION  %s\n' "${expired[@]}" >&2
    die "$EX_EXPIRED" "${#expired[@]} exception(s) past expiry. Re-justify with a new expiry or fix the finding."
  fi
  LIVE_EXC=$(printf '%s' "$live_json_lines" | jq -s '.')
fi
log "live exceptions: $(printf '%s' "$LIVE_EXC" | jq 'length')"

# ---------------------------------------------------------------------- scan
log "scanning $IMAGE from the registry"
trivy image \
  --image-src remote \
  --quiet \
  --scanners vuln \
  --format json \
  --list-all-pkgs \
  --output "$OUT/trivy.json" \
  "$IMAGE" || die "$EX_INCOMPLETE" "trivy did not complete against $IMAGE"

[ -s "$OUT/trivy.json" ] || die "$EX_INCOMPLETE" "trivy produced an empty report"

PKG_COUNT=$(jq '[.Results[]? | (.Packages // []) | length] | add // 0' "$OUT/trivy.json")
require_nonempty "$PKG_COUNT" "packages catalogued by trivy in $IMAGE"
if [ "$PKG_COUNT" -lt "$MIN_PKGS" ]; then
  die "$EX_NO_INPUT" "trivy catalogued $PKG_COUNT packages, below the floor of $MIN_PKGS - the scan is not trustworthy"
fi
log "packages catalogued: $PKG_COUNT"

jq '[ .Results[]? as $r | ($r.Vulnerabilities // [])[]
      | select(.Severity == "HIGH" or .Severity == "CRITICAL")
      | { id: .VulnerabilityID,
          pkg: .PkgName,
          installed: .InstalledVersion,
          fixed: (.FixedVersion // ""),
          severity: .Severity,
          target: $r.Target } ]' "$OUT/trivy.json" > "$OUT/high-critical.json"

jq --argjson exc "$LIVE_EXC" '
  def excepted($v): any($exc[]; .id == $v.id and (.package == "*" or .package == $v.pkg));
  { blocking:  [ .[] | select(.fixed != "")  | select(excepted(.) | not) ],
    accepted:  [ .[] | select(.fixed != "")  | select(excepted(.)) ],
    unfixable: [ .[] | select(.fixed == "") ] }
' "$OUT/high-critical.json" > "$OUT/verdict.json"

jq '.blocking'  "$OUT/verdict.json" > "$OUT/blocking.json"
jq '.accepted'  "$OUT/verdict.json" > "$OUT/accepted.json"
jq '.unfixable' "$OUT/verdict.json" > "$OUT/unfixable.json"

N_BLOCK=$(jq 'length' "$OUT/blocking.json")
N_ACCEPT=$(jq 'length' "$OUT/accepted.json")
N_UNFIX=$(jq 'length' "$OUT/unfixable.json")

jq -n --arg image "$IMAGE" --argjson packages "$PKG_COUNT" \
      --argjson blocking "$N_BLOCK" --argjson accepted "$N_ACCEPT" --argjson unfixable "$N_UNFIX" \
      '{image:$image, packages:$packages, blocking:$blocking, accepted_by_exception:$accepted, unfixable_recorded:$unfixable}' \
      > "$OUT/scan-summary.json"

{
  echo "### Vulnerability scan"
  echo ""
  echo "| metric | value |"
  echo "|---|---|"
  echo "| image | \`$IMAGE\` |"
  echo "| packages | $PKG_COUNT |"
  echo "| blocking (fixable HIGH/CRITICAL) | $N_BLOCK |"
  echo "| accepted by exception | $N_ACCEPT |"
  echo "| unfixable, recorded | $N_UNFIX |"
  if [ "$N_UNFIX" -gt 0 ]; then
    echo ""
    echo "Unfixable findings carried by this image:"
    echo ""
    echo '```'
    jq -r '.[] | "\(.severity)\t\(.id)\t\(.pkg) \(.installed)"' "$OUT/unfixable.json"
    echo '```'
  fi
} > "$OUT/scan-summary.md"
step_summary "$OUT/scan-summary.md"

log "blocking=$N_BLOCK accepted=$N_ACCEPT unfixable=$N_UNFIX"

if [ "$N_BLOCK" -gt 0 ]; then
  jq -r '.[] | "  \(.severity) \(.id) \(.pkg) \(.installed) -> \(.fixed)"' "$OUT/blocking.json" >&2
  die "$EX_POLICY" "$N_BLOCK fixable HIGH/CRITICAL finding(s). Rebuild on a patched base, or file a dated exception."
fi

end_audit
