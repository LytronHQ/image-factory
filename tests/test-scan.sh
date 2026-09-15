#!/usr/bin/env bash
# Offline test of the scan policy. trivy is stubbed so the report content is
# controlled exactly; what is under test is the verdict logic, including the
# cases that must NOT be green.

set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SCAN="$ROOT/scripts/scan.sh"
IMG="ghcr.io/example/x@sha256:1111111111111111111111111111111111111111111111111111111111111111"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
cat > "$TMP/bin/trivy" <<'STUB'
#!/usr/bin/env bash
out=""
while [ "$#" -gt 0 ]; do
  case $1 in --output) out=$2; shift 2 ;; *) shift ;; esac
done
[ -n "$out" ] || exit 9
cp "$TRIVY_STUB_REPORT" "$out"
STUB
chmod +x "$TMP/bin/trivy"
export PATH="$TMP/bin:$PATH"

mkreport() { # mkreport <file> <packages-json> <vulns-json>
  jq -n --argjson pkgs "$2" --argjson vulns "$3" \
    '{Results: [ {Target: "debian", Class: "os-pkgs", Packages: $pkgs, Vulnerabilities: $vulns} ]}' > "$1"
}

PKGS='[{"Name":"libc6"},{"Name":"bash"},{"Name":"zlib1g"}]'
FIXABLE='[{"VulnerabilityID":"CVE-2026-1","PkgName":"zlib1g","InstalledVersion":"1.0","FixedVersion":"1.1","Severity":"HIGH"}]'
UNFIXABLE='[{"VulnerabilityID":"CVE-2026-2","PkgName":"libc6","InstalledVersion":"2.0","Severity":"CRITICAL"}]'
LOWONLY='[{"VulnerabilityID":"CVE-2026-3","PkgName":"bash","InstalledVersion":"5.0","FixedVersion":"5.1","Severity":"LOW"}]'

PASS=0; FAIL=0
run() { # run <expected-code> <label> <report> <exceptions-or-->
  local want=$1 label=$2 report=$3 exc=$4 got=0 out
  local args=(--image "$IMG" --out "$TMP/out")
  [ "$exc" = "-" ] || args+=(--exceptions "$exc")
  rm -rf "$TMP/out"
  export TRIVY_STUB_REPORT="$report"
  out=$("$SCAN" "${args[@]}" 2>&1) || got=$?
  if [ "$got" -eq "$want" ]; then
    printf 'PASS  %-42s exit %s\n' "$label" "$got"; PASS=$((PASS+1))
  else
    printf 'FAIL  %-42s want %s got %s\n' "$label" "$want" "$got"
    printf '%s\n' "$out" | sed 's/^/        /'; FAIL=$((FAIL+1))
  fi
}

mkreport "$TMP/r-fixable.json"   "$PKGS" "$FIXABLE"
mkreport "$TMP/r-unfixable.json" "$PKGS" "$UNFIXABLE"
mkreport "$TMP/r-low.json"       "$PKGS" "$LOWONLY"
mkreport "$TMP/r-empty.json"     '[]'    '[]'

future=$(date -u -d '+90 days' +%Y-%m-%d)
past=$(date -u -d '-1 day' +%Y-%m-%d)
jq -n --arg e "$future" '{exceptions:[{id:"CVE-2026-1",package:"zlib1g",reason:"no upstream fix in base yet",expires:$e,owner:"maintainer"}]}' > "$TMP/exc-live.json"
jq -n --arg e "$past"   '{exceptions:[{id:"CVE-2026-1",package:"zlib1g",reason:"stale",expires:$e,owner:"maintainer"}]}' > "$TMP/exc-expired.json"
jq -n '{exceptions:[{id:"CVE-2026-1",package:"zlib1g",expires:"2099-01-01"}]}' > "$TMP/exc-noreason.json"

run 1  "fixable HIGH blocks"                 "$TMP/r-fixable.json"   -
run 0  "fixable HIGH with live exception"    "$TMP/r-fixable.json"   "$TMP/exc-live.json"
run 73 "expired exception fails loudly"      "$TMP/r-fixable.json"   "$TMP/exc-expired.json"
run 64 "exception without a reason"          "$TMP/r-fixable.json"   "$TMP/exc-noreason.json"
run 0  "unfixable CRITICAL is recorded"      "$TMP/r-unfixable.json" -
run 0  "LOW findings do not block"           "$TMP/r-low.json"       -
run 71 "zero packages is not a clean scan"   "$TMP/r-empty.json"     -

# The unfixable case must have actually recorded something, not just passed.
rm -rf "$TMP/out"
TRIVY_STUB_REPORT="$TMP/r-unfixable.json" "$SCAN" --image "$IMG" --out "$TMP/out" >/dev/null 2>&1
n=$(jq 'length' "$TMP/out/unfixable.json")
if [ "$n" -eq 1 ]; then
  printf 'PASS  %-42s %s recorded\n' "unfixable finding written to report" "$n"; PASS=$((PASS+1))
else
  printf 'FAIL  %-42s recorded %s, want 1\n' "unfixable finding written to report" "$n"; FAIL=$((FAIL+1))
fi

echo ""
echo "scan policy self-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
[ "$PASS" -eq 8 ] || { echo "expected 8 cases, ran $PASS" >&2; exit 71; }
echo "OK"
