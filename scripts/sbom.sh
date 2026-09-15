#!/usr/bin/env bash
# Generate SPDX and CycloneDX SBOMs from the PUSHED image, by digest, pulled
# from the registry. Never from the local build context.
#
# Asserts:
#   - both documents parse
#   - package count > 0 and >= --min-packages
#   - the two formats agree on the package count (they are the same catalogue;
#     a divergence means syft changed its representation and the downstream
#     count assertions are no longer comparing like with like)
#
# Usage: sbom.sh --image ghcr.io/o/n@sha256:... --out DIR [--min-packages N]

set -Eeuo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

begin_audit "sbom"

IMAGE=""; OUT=""; MIN_PKGS=1
while [ "$#" -gt 0 ]; do
  case $1 in
    --image)        IMAGE=$2; shift 2 ;;
    --out)          OUT=$2; shift 2 ;;
    --min-packages) MIN_PKGS=$2; shift 2 ;;
    *) die "$EX_USAGE" "unknown argument: $1" ;;
  esac
done

[ -n "$IMAGE" ] || die "$EX_USAGE" "--image is required"
[ -n "$OUT" ]   || die "$EX_USAGE" "--out is required"
case $IMAGE in
  *@sha256:*) : ;;
  *) die "$EX_USAGE" "--image must be a digest reference, got '$IMAGE'" ;;
esac

need_tool syft jq sha256sum
mkdir -p "$OUT"

log "cataloguing registry:$IMAGE"
syft "registry:$IMAGE" \
  -o "spdx-json=$OUT/sbom.spdx.json" \
  -o "cyclonedx-json=$OUT/sbom.cdx.json" \
  || die "$EX_INCOMPLETE" "syft did not complete against $IMAGE"

for f in "$OUT/sbom.spdx.json" "$OUT/sbom.cdx.json"; do
  [ -s "$f" ] || die "$EX_INCOMPLETE" "$f is empty"
  jq -e . "$f" >/dev/null 2>&1 || die "$EX_INCOMPLETE" "$f is not valid JSON"
done

SPDX_N=$(jq '[ (.packages // [])[] | select(.SPDXID != "SPDXRef-DOCUMENT") ] | length' "$OUT/sbom.spdx.json")
CDX_N=$(jq '(.components // []) | length' "$OUT/sbom.cdx.json")

require_nonempty "$SPDX_N" "packages in the SPDX document"
require_nonempty "$CDX_N"  "components in the CycloneDX document"

if [ "$SPDX_N" -ne "$CDX_N" ]; then
  die "$EX_UNRESOLVABLE" "SPDX reports $SPDX_N packages, CycloneDX reports $CDX_N. Same catalogue, different counts: syft's output shape changed and scripts/sbom.sh must be updated before these counts can be trusted."
fi

if [ "$SPDX_N" -lt "$MIN_PKGS" ]; then
  die "$EX_NO_INPUT" "SBOM lists $SPDX_N packages, below the floor of $MIN_PKGS"
fi

SYFT_VER=$(syft version -o json 2>/dev/null | jq -r '.version // "unknown"' || echo unknown)

jq -n \
  --arg image "$IMAGE" \
  --arg syft "$SYFT_VER" \
  --argjson packages "$SPDX_N" \
  --arg spdx_sha "$(sha256sum "$OUT/sbom.spdx.json" | cut -d' ' -f1)" \
  --arg cdx_sha "$(sha256sum "$OUT/sbom.cdx.json" | cut -d' ' -f1)" \
  '{image:$image, syft_version:$syft, packages:$packages, spdx_sha256:$spdx_sha, cyclonedx_sha256:$cdx_sha}' \
  > "$OUT/sbom-metadata.json"

{
  echo "### SBOM"
  echo ""
  echo "| metric | value |"
  echo "|---|---|"
  echo "| packages | $SPDX_N |"
  echo "| syft | $SYFT_VER |"
  echo "| formats | SPDX 2.3 JSON, CycloneDX JSON |"
} > "$OUT/sbom-summary.md"
step_summary "$OUT/sbom-summary.md"

log "packages: $SPDX_N (both formats agree)"
end_audit
