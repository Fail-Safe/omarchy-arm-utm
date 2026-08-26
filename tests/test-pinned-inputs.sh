#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
BUILDER="$ROOT/build-omarchy-arm.sh"
MANIFEST="$ROOT/checksums/base-images.sha256"

assignment() {
  sed -nE "s#^: \"\\\$\{${1}:=([^}]*)\}\"#\\1#p" "$BUILDER" | head -1
}

manifest_digest() {
  awk -v name="$1" '$2 == name { print $1 }' "$MANIFEST"
}

alpine_name=$(assignment ALPINE_ISO)
alpine_sha=$(assignment ALPINE_SHA256)
alarm_sha=$(assignment ALARM_SHA256)

[[ $alpine_sha =~ ^[0-9a-f]{64}$ ]]
[[ $alarm_sha =~ ^[0-9a-f]{64}$ ]]
[[ $(manifest_digest "$alpine_name") == "$alpine_sha" ]]
[[ $(manifest_digest ArchLinuxARM-aarch64-latest.tar.gz) == "$alarm_sha" ]]

for variable in ALPINE_URL ALARM_URL ALARM_MIRROR_PRIMARY ALARM_MIRROR_SECONDARY; do
  value=$(assignment "$variable")
  [[ $value == https://* ]] || { echo "$variable is not HTTPS: $value" >&2; exit 1; }
done

if rg -n "http://[^[:space:]\"']*archlinuxarm" \
    "$BUILDER" "$ROOT/provision/src/stage2.sh" >/dev/null; then
  echo "active build paths still contain plaintext Arch Linux ARM URLs" >&2
  exit 1
fi

python3 "$ROOT/scripts/sync-payloads.py" --check >/dev/null
echo "pinned input consistency tests: pass"
