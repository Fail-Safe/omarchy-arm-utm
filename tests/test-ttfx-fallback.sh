#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/omarchy-ttfx-test.XXXXXX")
fallback_pid=""
cleanup() {
  [[ -n $fallback_pid ]] && kill "$fallback_pid" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT

awk '
  /<<'\''TTFX_FALLBACK'\''$/ { copying = 1; next }
  /^TTFX_FALLBACK$/ { exit }
  copying { print }
' "$ROOT/provision/src/stage3.sh" > "$TMP/ttfx"
chmod +x "$TMP/ttfx"

grep -q '^# OMARCHY_TTFX_FALLBACK=1$' "$TMP/ttfx"
printf 'OMARCHY TTFX FALLBACK TEST\n' > "$TMP/logo.txt"

HOME="$TMP" TERM=xterm "$TMP/ttfx" -i "$TMP/logo.txt" > "$TMP/output" 2>&1 &
fallback_pid=$!
for _ in {1..20}; do
  grep -q 'OMARCHY TTFX FALLBACK TEST' "$TMP/output" 2>/dev/null && break
  sleep 0.05
done
kill -0 "$fallback_pid"
grep -q 'OMARCHY TTFX FALLBACK TEST' "$TMP/output"

grep -Fq 'TTFX=\$T' "$ROOT/build-omarchy-arm.sh"
grep -Fq '\[ \$T -eq 1 ]' "$ROOT/build-omarchy-arm.sh"

echo "ttfx fallback tests: pass"
