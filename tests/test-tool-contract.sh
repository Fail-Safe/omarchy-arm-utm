#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/omarchy-tool-contract.XXXXXX")
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

awk '
  /<<'\''TOOL_CONTRACT'\''$/ { copying = 1; next }
  /^TOOL_CONTRACT$/ { exit }
  copying { print }
' "$ROOT/provision/src/stage3.sh" > "$TMP/verify-tools"
chmod +x "$TMP/verify-tools"

mkdir -p "$TMP/bin"
cat > "$TMP/bin/pacman" <<'MOCK'
#!/usr/bin/env bash
[[ $1 == -Q ]]
[[ ${MISSING_PACKAGE:-} != "$2" ]]
MOCK
cat > "$TMP/bin/ttfx" <<'NATIVE'
#!/usr/bin/env bash
printf 'ttfx test\n'
NATIVE
chmod +x "$TMP/bin/pacman" "$TMP/bin/ttfx"

PATH="$TMP/bin:$PATH" "$TMP/verify-tools" si > "$TMP/full.out"
grep -q '^TOOLS_OK mode=full verified=18/18$' "$TMP/full.out"

if MISSING_PACKAGE=tensaku PATH="$TMP/bin:$PATH" "$TMP/verify-tools" si > "$TMP/missing.out" 2>&1; then
  echo "full contract accepted a missing required package" >&2
  exit 1
fi
grep -q 'TOOLS_KO mode=full missing=tensaku' "$TMP/missing.out"

if MISSING_PACKAGE=herdr PATH="$TMP/bin:$PATH" "$TMP/verify-tools" si > "$TMP/herdr.out" 2>&1; then
  echo "full contract accepted missing herdr" >&2
  exit 1
fi
grep -q 'TOOLS_KO mode=full missing=herdr' "$TMP/herdr.out"

awk '
  /<<'\''TTFX_FALLBACK'\''$/ { copying = 1; next }
  /^TTFX_FALLBACK$/ { exit }
  copying { print }
' "$ROOT/provision/src/stage3.sh" > "$TMP/bin/ttfx"
chmod +x "$TMP/bin/ttfx"
if PATH="$TMP/bin:$PATH" "$TMP/verify-tools" si > "$TMP/fallback-full.out" 2>&1; then
  echo "full contract accepted the static ttfx fallback" >&2
  exit 1
fi
grep -q 'missing=ttfx-native' "$TMP/fallback-full.out"
PATH="$TMP/bin:$PATH" "$TMP/verify-tools" no > "$TMP/lightweight.out"
grep -q '^TOOLS_OK mode=lightweight verified=1/1$' "$TMP/lightweight.out"

if PATH="$TMP/bin:$PATH" "$TMP/verify-tools" maybe > "$TMP/invalid.out" 2>&1; then
  echo "tool contract accepted an invalid mode" >&2
  exit 1
fi
grep -q 'TOOLS_KO invalid-mode=maybe' "$TMP/invalid.out"

grep -Fq '/usr/local/bin/omarchy-arm-verify-tools "${HACER_TOOLS:-si}" || exit 1' \
  "$ROOT/provision/src/stage3.sh"
rg -q 'omarchy-arm-verify-tools.*HACER_TOOLS' "$ROOT/provision/src/sanitize.sh"
grep -Fq 'echo TOOL\"S_OK\"' "$ROOT/build-omarchy-arm.sh"
grep -Fq 'echo BROWSER_\"POLICY_OK\"' "$ROOT/build-omarchy-arm.sh"
grep -Fq 'GTOOLS="$HACER_TOOLS" GREBOOT="$HACER_DIST"' "$ROOT/build-omarchy-arm.sh"
grep -Fq 'echo REBO\"OT_OK\"' "$ROOT/build-omarchy-arm.sh"
grep -Fq 'grep -qa "^REBOOT_OK"' "$ROOT/build-omarchy-arm.sh"
grep -Fq 'send "sudo systemctl reboot\r"' "$ROOT/build-omarchy-arm.sh"
! grep -Fq 'sudo -n systemctl reboot' "$ROOT/build-omarchy-arm.sh"
grep -Fq 'install/config/browser-policy.sh' "$ROOT/provision/src/stage3.sh"
grep -Fq "stat -c '%U:%G:%a'" "$ROOT/provision/src/sanitize.sh"

echo "tool contract tests: pass"
