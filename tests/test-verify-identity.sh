#!/usr/bin/env bash
# verify.sh signer binding. No registry: cosign is stubbed to return a fixed,
# already-"verified" signature payload and to record every call, so what is
# under test is which identity verify.sh demands and whether it holds the
# signature and the attestations to the right repository and ref.

set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
V="$ROOT/verify.sh"
IMG="ghcr.io/x/y@sha256:1111111111111111111111111111111111111111111111111111111111111111"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
printf '#!/bin/sh\nexit 1\n' > "$TMP/bin/syft"
cat > "$TMP/bin/cosign" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$COSIGN_LOG"
if [ "$1" = verify ] && [ -n "${COSIGN_SIG_JSON:-}" ]; then cat "$COSIGN_SIG_JSON"; exit 0; fi
exit 1
STUB
chmod +x "$TMP/bin/syft" "$TMP/bin/cosign"
export PATH="$TMP/bin:$PATH"
export COSIGN_LOG="$TMP/cosign.log"

cat > "$TMP/sig.json" <<'JSON'
[{"critical": {}, "optional": {
  "Issuer": "https://token.actions.githubusercontent.com",
  "Subject": "https://github.com/LytronHQ/image-factory/.github/workflows/build-image.yml@refs/tags/v1",
  "githubWorkflowRepository": "Owner/Repo",
  "githubWorkflowRef": "refs/heads/main"}}]
JSON

PASS=0; FAIL=0
check() { # check <label> <ok 0|1> [output-on-failure]
  if [ "$2" -eq 1 ]; then
    printf 'PASS  %-58s\n' "$1"; PASS=$((PASS + 1))
  else
    printf 'FAIL  %-58s\n' "$1"; printf '%s\n' "${3:-}" | sed 's/^/        /'; FAIL=$((FAIL + 1))
  fi
}
has() { printf '%s' "$1" | grep -qF -- "$2"; }

# run <args...> -> sets OUT (all output) and RC; fresh cosign log each time
run() { : > "$COSIGN_LOG"; RC=0; OUT=$("$V" --image "$IMG" "$@" 2>&1) || RC=$?; }

run --repo Owner/Repo
ok=0; has "$OUT" 'identity: ^https://github\.com/(?i:Owner\/Repo)/\.github/workflows/build-image\.yml@(refs/heads/main|refs/tags/[^/]+|[0-9a-f]{40})$' && ok=1
check "identity is build-image.yml on main, a tag or a SHA" "$ok" "$OUT"

run --repo Owner/Repo --factory LytronHQ/image-factory
ok=0; has "$OUT" 'identity: ^https://github\.com/(?i:LytronHQ\/image-factory)/\.github/workflows/build-image\.yml@' && ok=1
check "--factory names the repository build-image.yml lives in" "$ok" "$OUT"

export COSIGN_SIG_JSON="$TMP/sig.json"

run --repo owner/repo --factory LytronHQ/image-factory
ok=0; has "$OUT" "PASS  signature_valid" && ok=1
check "signature from a run of --repo on main passes, any case" "$ok" "$OUT"

LOG=$(cat "$COSIGN_LOG")
ok=0
if printf '%s\n' "$LOG" | grep -F -- '--type spdxjson' | grep -qF -- '--certificate-github-workflow-repository Owner/Repo --certificate-github-workflow-ref refs/heads/main' \
&& printf '%s\n' "$LOG" | grep -F -- '--type cyclonedx' | grep -qF -- '--certificate-github-workflow-repository Owner/Repo --certificate-github-workflow-ref refs/heads/main' \
&& printf '%s\n' "$LOG" | grep -F -- '--type slsaprovenance' | grep -qF -- '--certificate-github-workflow-repository Owner/Repo --certificate-github-workflow-ref refs/heads/main'; then ok=1; fi
check "every attestation is bound to the same repository and ref" "$ok" "$LOG"

ok=0; printf '%s\n' "$LOG" | grep -F -- '--type slsaprovenance' | grep -qF -- 'generator_container_slsa3\.yml@refs/tags/v[0-9]+\.[0-9]+\.[0-9]+$' && ok=1
check "provenance identity is the generator workflow at a release" "$ok" "$LOG"

run --repo other/repo --factory LytronHQ/image-factory
ok=0; has "$OUT" "FAIL  signature_valid" && [ "$RC" -eq 74 ] && ok=1
check "signature from a run of another repository fails" "$ok" "$OUT"

run --repo Owner/Repo --factory LytronHQ/image-factory --source-ref refs/heads/dev
ok=0; has "$OUT" "FAIL  signature_valid" && [ "$RC" -eq 74 ] && ok=1
check "signature from a run on another ref fails" "$ok" "$OUT"

run --repo not-a-repo
ok=0; [ "$RC" -eq 64 ] && ok=1
check "malformed --repo is refused (64)" "$ok" "$OUT"

run --repo Owner/Repo --factory 'Owner/Repo/.github'
ok=0; [ "$RC" -eq 64 ] && ok=1
check "malformed --factory is refused (64)" "$ok" "$OUT"

run --repo Owner/Repo --source-ref main
ok=0; [ "$RC" -eq 64 ] && ok=1
check "--source-ref that is not refs/heads or refs/tags (64)" "$ok" "$OUT"

echo ""
echo "verify identity binding: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
[ "$PASS" -eq 10 ] || { echo "expected 10 cases, ran $PASS" >&2; exit 71; }
echo "OK"
