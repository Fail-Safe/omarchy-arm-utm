#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
COMPAT="$ROOT/provision/src/omarchy-arm-menu-compat"
MENU="$ROOT/provision/src/omarchy-arm-menu.jsonc"
STAGE3="$ROOT/provision/src/stage3.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/omarchy-arm-menu-compat.XXXXXX")
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

bash -n "$COMPAT"
python3 - "$MENU" <<'PY'
import json, pathlib, sys

path = pathlib.Path(sys.argv[1])
text = "\n".join(line for line in path.read_text().splitlines()
                 if not line.lstrip().startswith("//"))
items = json.loads(text)

hidden = {
    "update.channel", "update.channel.stable", "update.channel.rc",
    "update.channel.edge", "update.channel.dev", "install.windows",
    "install.preinstalls", "install.browser.edge", "install.browser.brave",
    "install.browser.brave-origin", "install.browser.zen",
    "install.service.dropbox", "install.service.nordvpn", "install.service.once",
    "install.service.bitwarden", "install.editor.vscode", "install.editor.cursor",
    "install.editor.sublime", "install.editor.emacs", "install.terminal.ghostty",
    "install.ai.chatgpt", "install.ai.dictation", "install.ai.grok-bot",
    "install.ai.lm-studio", "install.ai.ollama", "install.ai.t3-code",
    "install.gaming.steam", "install.gaming.retroarch", "install.gaming.minecraft",
    "install.gaming.geforce-now", "install.gaming.xbox-controllers",
    "install.gaming.battlenet", "install.gaming.lutris", "install.gaming.heroic",
    "install.gaming.retro-launcher", "install.development.php.symfony",
}
for key in hidden:
    assert items[key]["when"] == "false", key

assert items["install.service.spotify"]["label"] == "Spotify (Web)"
assert "1password" in items["install.service.1password"]["disabled"]
assert "zed.app" in items["install.editor.zed"]["disabled"]
assert "google-chrome-stable" in items["install.browser.chrome"]["disabled"]
for key in ["install.browser.chrome", "install.service.1password",
            "install.service.spotify", "install.editor.zed"]:
    assert items[key]["label"], key
    assert items[key]["icon"], key
    assert items[key]["action"], key
PY

mkdir -p "$TMP/bin" "$TMP/real"
cp "$COMPAT" "$TMP/bin/menu-compat"
chmod +x "$TMP/bin/menu-compat"
for command in omarchy-channel-set omarchy-install-browser omarchy-install-and-launch \
  omarchy-install-app omarchy-install-terminal omarchy-install-editor-vscode \
  omarchy-install-gaming-steam; do
  ln -s menu-compat "$TMP/bin/$command"
done

status=0
OMARCHY_LANG=en "$TMP/bin/omarchy-channel-set" stable >"$TMP/channel.out" 2>&1 || status=$?
[[ $status == 1 ]]
grep -q 'cannot be selected on this ARM image' "$TMP/channel.out"

status=0
OMARCHY_LANG=en "$TMP/bin/omarchy-install-editor-vscode" >"$TMP/vscode.out" 2>&1 || status=$?
[[ $status == 1 ]]
grep -q 'not supported by this ARM image' "$TMP/vscode.out"

status=0
OMARCHY_LANG=en "$TMP/bin/omarchy-install-browser" edge >"$TMP/edge.out" 2>&1 || status=$?
[[ $status == 1 ]]
grep -q 'Microsoft Edge is not supported' "$TMP/edge.out"

cat >"$TMP/real/omarchy-install-browser" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >"$CALL_LOG"
MOCK
chmod +x "$TMP/real/omarchy-install-browser"
CALL_LOG="$TMP/firefox.log" OMARCHY_ARM_REAL_BIN="$TMP/real" \
  "$TMP/bin/omarchy-install-browser" firefox
grep -qx firefox "$TMP/firefox.log"

awk '
  /<<\047WRAP\047$/ { copying = 1; next }
  $0 == "WRAP" { exit }
  copying { print }
' "$STAGE3" >"$TMP/pkg-add"
chmod +x "$TMP/pkg-add"
cat >"$TMP/bin/pacman" <<'MOCK'
#!/usr/bin/env bash
[[ ${2:-} == available ]]
MOCK
cat >"$TMP/real-pkg-add" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >"$CALL_LOG"
MOCK
chmod +x "$TMP/bin/pacman" "$TMP/real-pkg-add"

status=0
PATH="$TMP/bin:$PATH" OMARCHY_ARM_STRICT_PACKAGES=1 \
  OMARCHY_ARM_REAL_PKG_ADD="$TMP/real-pkg-add" CALL_LOG="$TMP/strict.log" \
  "$TMP/pkg-add" available missing >"$TMP/strict.out" 2>&1 || status=$?
[[ $status == 1 && ! -e $TMP/strict.log ]]
grep -q 'aborted before making changes' "$TMP/strict.out"

PATH="$TMP/bin:$PATH" OMARCHY_ARM_REAL_PKG_ADD="$TMP/real-pkg-add" \
  CALL_LOG="$TMP/tolerant.log" "$TMP/pkg-add" available missing
grep -qx available "$TMP/tolerant.log"

rg -q 'status == 0.*omarchy-show-done' "$COMPAT"
rg -q 'OMARCHY_ARM_STRICT_PACKAGES=1' "$COMPAT" "$STAGE3"
rg -q 'omarchy-arm-extras chrome spotify-web' "$COMPAT"
rg -q 'chown -R root:root /opt/1Password' "$ROOT/provision/src/omarchy-arm-extras"
rg -q '1Password after-install setup failed' "$ROOT/provision/src/omarchy-arm-extras"
rg -q '1password --ozone-platform=x11' "$COMPAT"
rg -q 'desktop entry was not installed' "$ROOT/provision/src/omarchy-arm-extras"
rg -q 'Exec=/opt/1Password/1password --ozone-platform=x11' "$ROOT/provision/src/omarchy-arm-extras"
rg -q 'hyprctl clients -j' "$COMPAT"
rg -q 'grep -Fqx.*extension_json' "$COMPAT"
rg -q 'failed to launch.*1password-launch.log' "$COMPAT"
rg -q "Spotify web requires Google Chrome's ARM64 Widevine" \
  "$ROOT/provision/src/omarchy-arm-extras"
rg -q 'could not create the Spotify web launcher' \
  "$ROOT/provision/src/omarchy-arm-extras"
rg -q 'local/zed.app/bin/zed.*local/bin/zeditor' "$ROOT/provision/src/omarchy-arm-extras"
rg -q 'Exec=env ZED_ALLOW_EMULATED_GPU=1.*local/zed.app/bin/zed' \
  "$ROOT/provision/src/omarchy-arm-extras"
rg -q 'failed to launch.*zed-launch.log' "$COMPAT"
rg -q 'OMARCHY_ARM_MANAGED_MENU_V1' "$MENU" "$ROOT/provision/src/hooks/10-arm-sync"
rg -q 'Existing custom Omarchy menu extension preserved' \
  "$STAGE3" "$ROOT/provision/src/sanitize.sh"

echo "ARM menu compatibility tests: pass"
