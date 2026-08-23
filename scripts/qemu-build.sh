#!/bin/bash
# VM de construcción: aarch64 NATIVO con HVF (sin emulación) sobre Apple Silicon.
# Live de Alpine por consola serie + ISO de aprovisionamiento con el rootfs de ALARM.
set -e
# La raiz se deduce de la ubicacion del propio script: asi el repo se puede
# clonar en cualquier sitio sin editar nada.
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"
: "${VM_SMP:=8}"
: "${VM_MEM:=8192}"
FW=$(brew --prefix qemu)/share/qemu/edk2-aarch64-code.fd
: "${PROV_ISO:=provision/provision.iso}"
: "${DISK_IMG:=vm/omarchy-arm.qcow2}"

[ -f vm/efi-vars.fd ] || dd if=/dev/zero of=vm/efi-vars.fd bs=1m count=64 status=none

exec qemu-system-aarch64 \
  -accel hvf -cpu host -smp "$VM_SMP" -m "$VM_MEM" \
  -M virt,highmem=on,gic-version=3 \
  -drive if=pflash,format=raw,unit=0,readonly=on,file="$FW" \
  -drive if=pflash,format=raw,unit=1,file=vm/efi-vars.fd \
  -drive if=none,id=hd,file="$DISK_IMG",format=qcow2,cache=writeback,discard=unmap \
  -device virtio-blk-pci,drive=hd \
  -drive if=none,id=live,file=dl/alpine-virt-aarch64.iso,format=raw,media=cdrom,readonly=on \
  -device virtio-blk-pci,drive=live,bootindex=0 \
  -drive if=none,id=prov,file="$PROV_ISO",format=raw,media=cdrom,readonly=on \
  -device virtio-blk-pci,drive=prov \
  -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
  -device virtio-rng-pci \
  -nographic
