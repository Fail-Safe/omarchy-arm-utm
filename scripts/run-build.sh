#!/bin/bash
set -e
# The root is inferred from the script's own location: thus the repo can be
# cloned anywhere without editing anything.
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"
: "${OMARCHY_BUILD_WORK:=${W:-$HOME/omarchy-arm-build}}"
: "${OMARCHY_LANG:=$(bash "$ROOT/build-omarchy-arm.sh" --print-language)}"
export OMARCHY_LANG
ui_text() { if [[ $OMARCHY_LANG == es ]]; then printf '%s' "${2:-$1}"; else printf '%s' "$1"; fi; }

echo "=== $(ui_text 'preparing provisioning ISO' 'preparando ISO de aprovisionamiento') ==="
SNAPSHOT_DIR="$OMARCHY_BUILD_WORK/provision/alarm-repositories"
[[ -s "$SNAPSHOT_DIR/manifest.tsv" ]] || {
  echo "$(ui_text "Missing repository snapshot; run: W='$OMARCHY_BUILD_WORK' ./build-omarchy-arm.sh --only prepare" "Falta la captura de repositorios; ejecuta: W='$OMARCHY_BUILD_WORK' ./build-omarchy-arm.sh --only prepare")" >&2
  exit 1
}
for package_list in packages-core.txt packages-extra.txt; do
  [[ -s "$OMARCHY_BUILD_WORK/provision/$package_list" ]] || {
    echo "$(ui_text "Missing prepared $package_list; run the prepare phase first" "Falta $package_list preparado; ejecuta primero la fase prepare")" >&2
    exit 1
  }
done
python3 provision/src/alarm-repository-snapshot.py validate \
  "$SNAPSHOT_DIR" "$SNAPSHOT_DIR/manifest.tsv"
rm -rf provision/iso && mkdir -p provision/iso
cp provision/src/stage1.sh provision/src/stage2.sh provision/src/stage3.sh \
   provision/src/alarm-repository-snapshot.py \
   provision/src/config.env checksums/core-git-sources.tsv checksums/free-app-artifacts.tsv \
   provision/iso/
cp "$OMARCHY_BUILD_WORK/provision"/{packages-core.txt,packages-extra.txt} provision/iso/
cp -R "$SNAPSHOT_DIR" provision/iso/alarm-repositories
# short name to avoid dependency on ISO9660 extensions
ln dl/ArchLinuxARM-aarch64-latest.tar.gz provision/iso/alarm-rootfs.tgz 2>/dev/null \
  || cp dl/ArchLinuxARM-aarch64-latest.tar.gz provision/iso/alarm-rootfs.tgz
rm -f provision/provision.iso
hdiutil makehybrid -iso -joliet -default-volume-name PROVISION \
  -o provision/provision.iso provision/iso/ >/dev/null
ls -lh provision/provision.iso

echo "=== $(ui_text 'clean target disk' 'disco destino limpio') ==="
rm -f vm/omarchy-arm.qcow2 vm/efi-vars.fd
qemu-img create -f qcow2 vm/omarchy-arm.qcow2 80G >/dev/null
dd if=/dev/zero of=vm/efi-vars.fd bs=1m count=64 status=none

echo "=== $(date '+%F %T') $(ui_text 'building Arch Linux ARM + Hyprland + Omarchy' 'construyendo Arch Linux ARM + Hyprland + Omarchy') ==="
exec expect -f scripts/build.exp
