#!/usr/bin/env bash
# Offline test of pin.sh. crane is stubbed with a fixed table of reference ->
# digest, so what is under test is which references get rewritten, to what,
# and that nothing is written when any resolution fails.
#
# Each case asserts an exact exit code and the exact file content afterwards.

set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
PIN="$ROOT/scripts/pin.sh"
D1="sha256:1111111111111111111111111111111111111111111111111111111111111111"
D2="sha256:2222222222222222222222222222222222222222222222222222222222222222"
D3="sha256:3333333333333333333333333333333333333333333333333333333333333333"
Z="sha256:0000000000000000000000000000000000000000000000000000000000000000"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/nobin"
cat > "$TMP/bin/crane" <<'STUB'
#!/usr/bin/env bash
[ "$1" = digest ] || exit 9
while read -r ref digest; do
  if [ "$ref" = "$2" ]; then printf '%s\n' "$digest"; exit 0; fi
done < "$CRANE_STUB_TABLE"
echo "MANIFEST_UNKNOWN: $2" >&2
exit 1
STUB
chmod +x "$TMP/bin/crane"
ln -s "$(command -v dirname)" "$TMP/nobin/dirname"

cat > "$TMP/table" <<TABLE
docker/dockerfile:1.10.0 $D1
debian:12-slim $D2
ghcr.io/o/base:sha-abc $D3
ghcr.io/o/base@$D3 $D3
broken:tag $Z
TABLE
export CRANE_STUB_TABLE="$TMP/table"

PASS=0; FAIL=0
report() { # report <ok?> <label> <detail> <output>
  if [ "$1" -eq 1 ]; then
    printf 'PASS  %-50s %s\n' "$2" "$3"; PASS=$((PASS + 1))
  else
    printf 'FAIL  %-50s %s\n' "$2" "$3"; printf '%s\n' "$4" | sed 's/^/        /'; FAIL=$((FAIL + 1))
  fi
}

# run <expected-code> <label> <dockerfile> <expected-dockerfile|SAME> [ref]
run() {
  local want=$1 label=$2 content=$3 expected=$4; shift 4
  local f="$TMP/Dockerfile" got=0 out ok=0
  printf '%s\n' "$content" > "$f"
  out=$(PATH="$TMP/bin:$PATH" "$PIN" "$f" "$@" 2>&1) || got=$?
  [ "$expected" != SAME ] || expected=$content
  if [ "$got" -eq "$want" ] && [ "$(cat "$f")" = "$expected" ]; then ok=1; fi
  report "$ok" "$label" "exit $got" "$out"$'\n'"--- file now:"$'\n'"$(cat "$f")"
}

run 0  "tag without a digest is pinned" \
  $'FROM debian:12-slim\nRUN true' \
  $'FROM debian:12-slim@'"$D2"$'\nRUN true'

run 0  "all-zero placeholders are resolved from their tag" \
  $'# syntax=docker/dockerfile:1.10.0@'"$Z"$'\nFROM debian:12-slim@'"$Z" \
  $'# syntax=docker/dockerfile:1.10.0@'"$D1"$'\nFROM debian:12-slim@'"$D2"

run 0  "quoted ARG default is pinned inside the quotes" \
  'ARG BASE_IMAGE="debian:12-slim"' \
  'ARG BASE_IMAGE="debian:12-slim@'"$D2"'"'

run 0  "a real digest is left alone" \
  "FROM debian:12-slim@$D3" SAME

run 0  "explicit tag moves an already-pinned base" \
  $'ARG BASE_IMAGE=ghcr.io/o/base@'"$D1"$'\nFROM ${BASE_IMAGE}' \
  $'ARG BASE_IMAGE=ghcr.io/o/base@'"$D3"$'\nFROM ${BASE_IMAGE}' \
  ghcr.io/o/base:sha-abc

run 0  "explicit digest moves an already-pinned base" \
  "FROM ghcr.io/o/base@$D1" "FROM ghcr.io/o/base@$D3" \
  "ghcr.io/o/base@$D3"

run 0  "explicit ref leaves other repositories alone" \
  $'FROM debian:12-slim@'"$D1"$' AS build\nFROM ghcr.io/o/base@'"$D1" \
  $'FROM debian:12-slim@'"$D1"$' AS build\nFROM ghcr.io/o/base@'"$D3" \
  ghcr.io/o/base:sha-abc

run 71 "explicit ref that is not in the file" \
  "FROM debian:12-slim@$D2" SAME ghcr.io/o/base:sha-abc

run 72 "one unresolvable tag writes nothing" \
  $'FROM debian:12-slim\nFROM nope:missing' SAME

run 72 "placeholder with no tag is not guessed" \
  "FROM ghcr.io/o/base@$Z" SAME

run 72 "resolver returning the all-zero digest is refused" \
  "FROM broken:tag" SAME

# No resolver at all must stop before touching anything.
f="$TMP/Dockerfile"; printf 'FROM debian:12-slim\n' > "$f"; got=0
out=$(PATH="$TMP/nobin" "$BASH" "$PIN" "$f" 2>&1) || got=$?
ok=0; if [ "$got" -eq 70 ] && [ "$(cat "$f")" = "FROM debian:12-slim" ]; then ok=1; fi
report "$ok" "neither crane nor docker available" "exit $got" "$out"

got=0
out=$(PATH="$TMP/bin:$PATH" "$PIN" 2>&1) || got=$?
ok=0; if [ "$got" -eq 64 ]; then ok=1; fi
report "$ok" "no Dockerfile argument" "exit $got" "$out"

echo ""
echo "pin.sh self-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
[ "$PASS" -eq 13 ] || { echo "expected 13 cases, ran $PASS" >&2; exit 71; }
echo "OK"
