#!/usr/bin/env bash
# verify.sh - verify a published image digest end to end, from the outside.
#
# Requires: cosign, syft, jq. Nothing else. No account, no credentials for a
# public image, no trust in the pipeline that produced it.
#
# This is the same script the pipeline runs against its own output, so a
# passing build means this exact code path passed.
#
#   ./verify.sh --image ghcr.io/OWNER/base@sha256:abc... --repo OWNER/image-factory
#
# Exit codes: see scripts/lib.sh. 0 only if every required check ran and passed.

set -Eeuo pipefail

# Subset of the exit-code contract in scripts/lib.sh that this script can emit.
# See the table in README.md.
EX_USAGE=64
EX_MISSING_TOOL=70
EX_VERIFY=74
EX_INCOMPLETE=75

IMAGE=""
REPO=""
FACTORY=""
SOURCE_REF="refs/heads/main"
ID_RE=""
ISSUER="https://token.actions.githubusercontent.com"
PROV_ID_RE='^https://github\.com/slsa-framework/slsa-github-generator/\.github/workflows/generator_container_slsa3\.yml@refs/tags/v[0-9]+\.[0-9]+\.[0-9]+$'
PROV_ISSUER="https://token.actions.githubusercontent.com"
PROV_TYPE="slsaprovenance"
EXPECT_PACKAGES=""
TOLERANCE_PCT=5
STRICT=0
SKIP_PROVENANCE=0
RECEIPT=""

usage() {
  sed -n '2,20p' "$0"
  cat <<'USAGE'

Options:
  --image REF@sha256:...        required, must be a digest reference
  --repo OWNER/NAME             the repository whose workflow run built the image;
                                the signature and every attestation must come from
                                a run in it (case-insensitive)
  --factory OWNER/NAME          the repository build-image.yml lives in; the signer
                                must be its build-image.yml at main, a tag or a
                                commit SHA (default: --repo)
  --source-ref REF              the ref that run was on (default refs/heads/main)
  --identity-regexp RE          expected signer identity, replacing the one derived
                                from --factory (--repo still binds the run)
  --issuer URL                  OIDC issuer (default GitHub Actions)
  --expect-packages N           assert the attested SBOM lists exactly N packages
  --tolerance PCT               allowed drift between attested and live catalogue (default 5)
  --strict                      tolerance 0; attested and live counts must match exactly
  --provenance-identity-regexp RE
  --provenance-type TYPE        cosign predicate type (default slsaprovenance)
  --skip-provenance             record provenance checks as SKIPPED (partial verification)
  --receipt FILE                write a JSON receipt of every check
USAGE
}

while [ "$#" -gt 0 ]; do
  case $1 in
    --image) IMAGE=$2; shift 2 ;;
    --repo) REPO=$2; shift 2 ;;
    --factory) FACTORY=$2; shift 2 ;;
    --source-ref) SOURCE_REF=$2; shift 2 ;;
    --identity-regexp) ID_RE=$2; shift 2 ;;
    --issuer) ISSUER=$2; shift 2 ;;
    --expect-packages) EXPECT_PACKAGES=$2; shift 2 ;;
    --tolerance) TOLERANCE_PCT=$2; shift 2 ;;
    --strict) STRICT=1; shift ;;
    --provenance-identity-regexp) PROV_ID_RE=$2; shift 2 ;;
    --provenance-type) PROV_TYPE=$2; shift 2 ;;
    --skip-provenance) SKIP_PROVENANCE=1; shift ;;
    --receipt) RECEIPT=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR unknown argument: $1" >&2; usage >&2; exit "$EX_USAGE" ;;
  esac
done

COMPLETE=0
# shellcheck disable=SC2317,SC2329  # invoked via trap
on_exit() {
  rc=$?
  [ -n "${CLEANUP_DIR:-}" ] && rm -rf "$CLEANUP_DIR"
  if [ "$rc" -eq 0 ] && [ "$COMPLETE" -ne 1 ]; then
    echo "ERROR verify.sh exited 0 without finishing. Treating as incomplete." >&2
    exit "$EX_INCOMPLETE"
  fi
  exit "$rc"
}
trap on_exit EXIT

fail() { echo "ERROR $*" >&2; exit "${FAIL_CODE:-$EX_VERIFY}"; }

# ---------------------------------------------------------------- preflight
for t in cosign syft jq; do
  command -v "$t" >/dev/null 2>&1 || { FAIL_CODE=$EX_MISSING_TOOL fail "required tool not found: $t"; }
done

[ -n "$IMAGE" ] || { FAIL_CODE=$EX_USAGE fail "--image is required"; }
case $IMAGE in
  *@sha256:*) : ;;
  *) FAIL_CODE=$EX_USAGE fail "--image must be a digest reference (got '$IMAGE')" ;;
esac
DIGEST=${IMAGE##*@}
DIGEST_HEX=${DIGEST#sha256:}
case $DIGEST_HEX in
  ????????????????????????????????????????????????????????????????) : ;;
  *) FAIL_CODE=$EX_USAGE fail "digest is not 64 characters: $DIGEST" ;;
esac

REPO_FORMAT='^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9._-]+$'
if [ -n "$REPO" ] && ! [[ $REPO =~ $REPO_FORMAT ]]; then
  FAIL_CODE=$EX_USAGE fail "--repo must be OWNER/NAME (got '$REPO')"
fi
if [ -n "$FACTORY" ] && ! [[ $FACTORY =~ $REPO_FORMAT ]]; then
  FAIL_CODE=$EX_USAGE fail "--factory must be OWNER/NAME (got '$FACTORY')"
fi
case $SOURCE_REF in
  refs/heads/?*|refs/tags/?*) : ;;
  *) FAIL_CODE=$EX_USAGE fail "--source-ref must be refs/heads/<branch> or refs/tags/<tag> (got '$SOURCE_REF')" ;;
esac

if [ -z "$ID_RE" ]; then
  [ -n "$REPO" ] || { FAIL_CODE=$EX_USAGE fail "pass --repo OWNER/NAME or --identity-regexp. Verifying without an expected identity proves only that somebody signed it."; }
  # The signer is the reusable workflow itself, at a release point of the
  # factory: main, a tag, or a full commit SHA. Any other workflow file, or
  # build-image.yml on any other branch, is not accepted. GitHub owner and
  # repository names are case-insensitive, so that part of the match is too.
  esc_factory=$(printf '%s' "${FACTORY:-$REPO}" | sed 's/[.[\*^$\/]/\\&/g')
  ID_RE="^https://github\.com/(?i:${esc_factory})/\.github/workflows/build-image\.yml@(refs/heads/main|refs/tags/[^/]+|[0-9a-f]{40})\$"
fi

[ "$STRICT" -eq 1 ] && TOLERANCE_PCT=0

WORK=$(mktemp -d)
CLEANUP_DIR=$WORK

b64d() {
  if printf '%s' "$1" | base64 --decode 2>/dev/null; then return 0; fi
  printf '%s' "$1" | base64 -D
}

# ------------------------------------------------------------- check ledger
CHECK_NAMES=""
CHECK_RESULTS=""
CHECK_DETAILS=""
PASSED=0
FAILED=0
SKIPPED=0

record() { # record <name> <PASS|FAIL|SKIP> <detail>
  CHECK_NAMES="${CHECK_NAMES}${1}"$'\n'
  CHECK_RESULTS="${CHECK_RESULTS}${2}"$'\n'
  CHECK_DETAILS="${CHECK_DETAILS}${3}"$'\n'
  case $2 in
    PASS) PASSED=$((PASSED + 1)); printf 'PASS  %-34s %s\n' "$1" "$3" ;;
    SKIP) SKIPPED=$((SKIPPED + 1)); printf 'SKIP  %-34s %s\n' "$1" "$3" ;;
    *)    FAILED=$((FAILED + 1)); printf 'FAIL  %-34s %s\n' "$1" "$3" ;;
  esac
}

# The required set is fixed up front so that a check which silently never ran
# cannot be mistaken for a check that passed.
REQUIRED="image_pullable
signer_identity_is_specific
signature_valid
attestation_spdx
attestation_cyclonedx
sbom_non_empty
sbom_formats_agree
sbom_matches_live_catalogue
provenance_attestation
provenance_builder_expected
provenance_subject_matches_digest"
[ -n "$EXPECT_PACKAGES" ] && REQUIRED="${REQUIRED}
sbom_package_count_expected"
REQUIRED_N=$(printf '%s\n' "$REQUIRED" | grep -c . || true)

echo "image:    $IMAGE"
echo "identity: $ID_RE"
if [ -n "$REPO" ]; then echo "run:      $REPO on $SOURCE_REF"; else echo "run:      not bound (no --repo)"; fi
echo "issuer:   $ISSUER"
echo "checks:   $REQUIRED_N required"
echo ""

# --------------------------------------------------------- 1 image pullable
if syft "registry:$IMAGE" -o "spdx-json=$WORK/live.spdx.json" -q >/dev/null 2>"$WORK/syft.err"; then
  record image_pullable PASS "pulled and catalogued from the registry"
else
  record image_pullable FAIL "$(tail -n 2 "$WORK/syft.err" | tr '\n' ' ')"
fi

# ---------------------------------------------- 2 identity is not permissive
case $ID_RE in
  ''|'.*'|'.+'|'^.*$'|'^.+$'|'^.*'|'.*$')
    record signer_identity_is_specific FAIL "identity regexp '$ID_RE' matches any signer" ;;
  *)
    record signer_identity_is_specific PASS "$ID_RE" ;;
esac

# ------------------------------------------------------------- 3 signature
# The certificate subject is the reusable workflow that signed. The run it
# signed in is recorded separately, as GitHub Workflow Repository and Ref
# (Fulcio OIDs 1.3.6.1.4.1.57264.1.5 and .6); for a consumer of the factory
# those name the consumer's repository, not the factory. Both must match. The
# repository is compared case-insensitively here, and the spelling the
# certificate uses is then required exactly of every attestation below.
BIND_ARGS=()
CANON_REPO=$REPO
if cosign verify \
      --certificate-oidc-issuer "$ISSUER" \
      --certificate-identity-regexp "$ID_RE" \
      "$IMAGE" > "$WORK/sig.json" 2>"$WORK/sig.err"; then
  signer=$(jq -r '.[0].optional.Subject // .[0].optional.Issuer // "unknown"' "$WORK/sig.json" 2>/dev/null || echo unknown)
  if [ -z "$REPO" ]; then
    record signature_valid PASS "keyless signature bound to $signer (run not bound: no --repo)"
  else
    found=$(jq -r --arg r "$REPO" --arg ref "$SOURCE_REF" '
        first(.[] | (.optional // {})
              | select(((.githubWorkflowRepository // "") | ascii_downcase) == ($r | ascii_downcase)
                       and .githubWorkflowRef == $ref)
              | .githubWorkflowRepository) // empty' "$WORK/sig.json" 2>/dev/null || true)
    if [ -n "$found" ]; then
      CANON_REPO=$found
      record signature_valid PASS "keyless signature bound to $signer, in a run of $CANON_REPO on $SOURCE_REF"
    else
      seen=$(jq -r '[.[] | (.optional // {}) | "\(.githubWorkflowRepository // "?") on \(.githubWorkflowRef // "?")"] | unique | join(", ")' "$WORK/sig.json" 2>/dev/null || echo unknown)
      record signature_valid FAIL "signed by $signer, but not in a run of $REPO on $SOURCE_REF (certificate names: $seen)"
    fi
  fi
else
  record signature_valid FAIL "$(tail -n 3 "$WORK/sig.err" | tr '\n' ' ')"
fi
if [ -n "$REPO" ]; then
  BIND_ARGS=(--certificate-github-workflow-repository "$CANON_REPO" --certificate-github-workflow-ref "$SOURCE_REF")
fi

# --------------------------------------------------------- attestation helper
# verify_attestation <cosign-type> <identity-re> <issuer> <out-prefix>
verify_attestation() {
  _type=$1; _idre=$2; _iss=$3; _pfx=$4
  if ! cosign verify-attestation \
        --type "$_type" \
        --certificate-oidc-issuer "$_iss" \
        --certificate-identity-regexp "$_idre" \
        ${BIND_ARGS[@]+"${BIND_ARGS[@]}"} \
        "$IMAGE" > "$WORK/$_pfx.dsse" 2>"$WORK/$_pfx.err"; then
    return 1
  fi
  [ -s "$WORK/$_pfx.dsse" ] || return 1
  # DSSE envelopes -> in-toto statements
  : > "$WORK/$_pfx.stmts.raw"
  jq -s -r 'flatten | .[] | .payload // empty' "$WORK/$_pfx.dsse" > "$WORK/$_pfx.payloads" 2>/dev/null || return 1
  [ -s "$WORK/$_pfx.payloads" ] || return 1
  while IFS= read -r p; do
    b64d "$p" >> "$WORK/$_pfx.stmts.raw"
    printf '\n' >> "$WORK/$_pfx.stmts.raw"
  done < "$WORK/$_pfx.payloads"
  jq -s '.' "$WORK/$_pfx.stmts.raw" > "$WORK/$_pfx.stmts.json" 2>/dev/null || return 1
  n=$(jq 'length' "$WORK/$_pfx.stmts.json")
  [ "$n" -gt 0 ] || return 1
  jq '.[0]' "$WORK/$_pfx.stmts.json" > "$WORK/$_pfx.stmt.json"
  return 0
}

subject_matches() { # <statement file>
  jq -e --arg d "$DIGEST_HEX" 'any(.subject[]?; .digest.sha256 == $d)' "$1" >/dev/null 2>&1
}

# ---------------------------------------------------------- 4 SPDX attestation
SPDX_N=""
if verify_attestation spdxjson "$ID_RE" "$ISSUER" spdx; then
  if subject_matches "$WORK/spdx.stmt.json"; then
    SPDX_N=$(jq '[ (.predicate.packages // [])[] | select(.SPDXID != "SPDXRef-DOCUMENT") | select(.SPDXID | startswith("SPDXRef-DocumentRoot-") | not) ] | length' "$WORK/spdx.stmt.json")
    record attestation_spdx PASS "signed SPDX attestation, subject matches digest"
  else
    record attestation_spdx FAIL "SPDX attestation subject does not contain $DIGEST"
  fi
else
  record attestation_spdx FAIL "$(tail -n 3 "$WORK/spdx.err" 2>/dev/null | tr '\n' ' ')"
fi

# ----------------------------------------------------- 5 CycloneDX attestation
CDX_N=""
if verify_attestation cyclonedx "$ID_RE" "$ISSUER" cdx; then
  if subject_matches "$WORK/cdx.stmt.json"; then
    CDX_N=$(jq '[ (.predicate.components // [])[] | select(.type != "file" and .type != "operating-system") ] | length' "$WORK/cdx.stmt.json")
    record attestation_cyclonedx PASS "signed CycloneDX attestation, subject matches digest"
  else
    record attestation_cyclonedx FAIL "CycloneDX attestation subject does not contain $DIGEST"
  fi
else
  record attestation_cyclonedx FAIL "$(tail -n 3 "$WORK/cdx.err" 2>/dev/null | tr '\n' ' ')"
fi

# ------------------------------------------------------------ 6 SBOM non-empty
if [ -n "$SPDX_N" ] && [ "$SPDX_N" -gt 0 ] 2>/dev/null; then
  record sbom_non_empty PASS "$SPDX_N packages in the attested SPDX document"
else
  record sbom_non_empty FAIL "attested SPDX document lists ${SPDX_N:-no} packages"
fi

# --------------------------------------------------------- 7 formats agree
if [ -n "$SPDX_N" ] && [ -n "$CDX_N" ]; then
  if [ "$SPDX_N" -eq "$CDX_N" ]; then
    record sbom_formats_agree PASS "SPDX $SPDX_N == CycloneDX $CDX_N"
  else
    record sbom_formats_agree FAIL "SPDX $SPDX_N != CycloneDX $CDX_N"
  fi
else
  record sbom_formats_agree FAIL "one or both attested SBOMs unavailable"
fi

# ----------------------------------------- 8 attested SBOM vs live catalogue
if [ -s "$WORK/live.spdx.json" ] && [ -n "$SPDX_N" ]; then
  LIVE_N=$(jq '[ (.packages // [])[] | select(.SPDXID != "SPDXRef-DOCUMENT") | select(.SPDXID | startswith("SPDXRef-DocumentRoot-") | not) ] | length' "$WORK/live.spdx.json")
  if [ "$LIVE_N" -eq 0 ]; then
    record sbom_matches_live_catalogue FAIL "live catalogue of the registry image is empty"
  else
    diff=$(( SPDX_N - LIVE_N )); [ "$diff" -lt 0 ] && diff=$(( -diff ))
    allowed=$(( LIVE_N * TOLERANCE_PCT / 100 ))
    if [ "$diff" -le "$allowed" ]; then
      record sbom_matches_live_catalogue PASS "attested $SPDX_N vs live $LIVE_N (tolerance ${TOLERANCE_PCT}%)"
    else
      record sbom_matches_live_catalogue FAIL "attested $SPDX_N vs live $LIVE_N exceeds ${TOLERANCE_PCT}% tolerance"
    fi
  fi
else
  record sbom_matches_live_catalogue FAIL "could not compare: live catalogue or attested SBOM missing"
fi

# ------------------------------------------------------------- 9-11 provenance
if [ "$SKIP_PROVENANCE" -eq 1 ]; then
  record provenance_attestation SKIP "--skip-provenance"
  record provenance_builder_expected SKIP "--skip-provenance"
  record provenance_subject_matches_digest SKIP "--skip-provenance"
elif verify_attestation "$PROV_TYPE" "$PROV_ID_RE" "$PROV_ISSUER" prov; then
  record provenance_attestation PASS "signed $PROV_TYPE attestation from $PROV_ID_RE"

  BUILDER=$(jq -r '.predicate.runDetails.builder.id // .predicate.builder.id // ""' "$WORK/prov.stmt.json")
  case $BUILDER in
    *slsa-github-generator*) record provenance_builder_expected PASS "$BUILDER" ;;
    "")  record provenance_builder_expected FAIL "provenance predicate has no builder id" ;;
    *)   record provenance_builder_expected FAIL "unexpected builder id: $BUILDER" ;;
  esac

  if subject_matches "$WORK/prov.stmt.json"; then
    record provenance_subject_matches_digest PASS "$DIGEST"
  else
    record provenance_subject_matches_digest FAIL "provenance subject does not contain $DIGEST"
  fi
else
  record provenance_attestation FAIL "$(tail -n 3 "$WORK/prov.err" 2>/dev/null | tr '\n' ' ')"
  record provenance_builder_expected FAIL "no verified provenance to inspect"
  record provenance_subject_matches_digest FAIL "no verified provenance to inspect"
fi

# ------------------------------------------------------- 12 expected count
if [ -n "$EXPECT_PACKAGES" ]; then
  if [ -n "$SPDX_N" ] && [ "$SPDX_N" -eq "$EXPECT_PACKAGES" ] 2>/dev/null; then
    record sbom_package_count_expected PASS "$SPDX_N == $EXPECT_PACKAGES"
  else
    record sbom_package_count_expected FAIL "attested ${SPDX_N:-none} != expected $EXPECT_PACKAGES"
  fi
fi

# --------------------------------------------------------------------- ledger
RAN=$(printf '%s\n' "$CHECK_NAMES" | grep -c . || true)
echo ""
echo "checks required: $REQUIRED_N   ran: $RAN   pass: $PASSED   fail: $FAILED   skip: $SKIPPED"

if [ -n "$RECEIPT" ]; then
  paste -d'\t' \
      <(printf '%s' "$CHECK_NAMES") \
      <(printf '%s' "$CHECK_RESULTS") \
      <(printf '%s' "$CHECK_DETAILS") \
    | jq -R -s --arg image "$IMAGE" --argjson required "$REQUIRED_N" \
        --argjson ran "$RAN" --argjson passed "$PASSED" \
        --argjson failed "$FAILED" --argjson skipped "$SKIPPED" '
      { image: $image,
        required: $required, ran: $ran, passed: $passed, failed: $failed, skipped: $skipped,
        complete: ($ran == $required and $failed == 0 and $skipped == 0),
        checks: [ split("\n")[] | select(length > 0) | split("\t")
                  | {name: .[0], result: .[1], detail: (.[2] // "")} ] }' \
    > "$RECEIPT"
  echo "receipt: $RECEIPT"
fi

if [ "$RAN" -ne "$REQUIRED_N" ]; then
  echo "ERROR $RAN checks ran but $REQUIRED_N were required. Verification is incomplete." >&2
  COMPLETE=1
  exit "$EX_INCOMPLETE"
fi
if [ "$FAILED" -gt 0 ]; then
  echo "ERROR VERIFICATION FAILED: $FAILED check(s) failed." >&2
  COMPLETE=1
  exit "$EX_VERIFY"
fi
if [ "$SKIPPED" -gt 0 ]; then
  echo "PARTIAL VERIFICATION: $SKIPPED check(s) skipped by request. This is not a full verification."
  COMPLETE=1
  exit 0
fi

echo "VERIFIED: all $REQUIRED_N checks passed for $IMAGE"
COMPLETE=1
exit 0
