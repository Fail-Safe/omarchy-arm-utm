#!/bin/bash
# Boots an installed disk with a virtio GPU and captures the screen through the
# QEMU monitor, avoiding UTM bundle registration just to inspect the display.
#
set -e
# The root is inferred from the script's own location: this way the repo can be cloned anywhere without editing anything.
#
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"
: "${OMARCHY_LANG:=$(bash "$ROOT/build-omarchy-arm.sh" --print-language)}"
ui_text() { if [[ $OMARCHY_LANG == es ]]; then printf '%s' "${2:-$1}"; else printf '%s' "$1"; fi; }
[[ -n ${DISK_IMG:-} ]] || { echo "$(ui_text 'DISK_IMG is required' 'falta DISK_IMG')" >&2; exit 1; }
: "${OUT:=shots/qemu-shot.png}"
: "${WAIT:=150}"
FW=$(brew --prefix qemu)/share/qemu/edk2-aarch64-code.fd
: "${OMARCHY_SHOT_TMP:=${TMPDIR:-/tmp}/omarchy-qemu-shot}"
SCRATCH="$OMARCHY_SHOT_TMP"
mkdir -p "$SCRATCH"
VARS="$SCRATCH/shotvars.fd"
MON="/tmp/omshot.sock"
rm -f "$VARS" "$MON"
dd if=/dev/zero of="$VARS" bs=1m count=64 status=none

qemu-system-aarch64 \
  -snapshot \
  -accel hvf -cpu host -smp 8 -m 8192 \
  -M virt,highmem=on,gic-version=3 \
  -drive if=pflash,format=raw,unit=0,readonly=on,file="$FW" \
  -drive if=pflash,format=raw,unit=1,file="$VARS" \
  -drive if=none,id=hd,file="$DISK_IMG",format=qcow2,cache=writeback,discard=unmap \
  -device virtio-blk-pci,drive=hd,bootindex=0 \
  -device virtio-gpu-pci,xres=1920,yres=1200 \
  -device qemu-xhci -device usb-kbd -device usb-tablet \
  -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
  -device virtio-rng-pci \
  -display none -monitor unix:"$MON",server,nowait &
QPID=$!
trap 'kill -TERM $QPID 2>/dev/null; rm -f "$VARS"' EXIT

for _ in $(seq 1 30); do [ -S "$MON" ] && break; sleep 1; done
echo "$(ui_text 'booting; waiting' 'arrancando, esperando') ${WAIT}s $(ui_text 'for the desktop...' 'al escritorio...')"
sleep "$WAIT"

# Wakes up the session: after ~2 minutes, hypridle triggers the screensaver and the
# capture would come out black.
printf 'sendkey esc\n' | nc -U "$MON" >/dev/null
sleep 8
PPM="$SCRATCH/shot.ppm"
printf 'screendump %s\nquit\n' "$PPM" | nc -U "$MON" >/dev/null
sleep 3
sips -s format png "$PPM" --out "$OUT" >/dev/null
rm -f "$PPM"
echo "$(ui_text 'capture' 'captura'): $OUT"
