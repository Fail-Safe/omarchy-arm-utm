#!/bin/bash
# Stage 2 — inside the Arch Linux ARM chroot, as root.
# Base system, kernel, UEFI boot, Omarchy stack packages, and login.
set -euo pipefail
. /root/prov/config.env
. /root/prov/fsinfo.env
export LANG=C LC_ALL=C

ui_text() { if [[ ${OMARCHY_LANG:-en} == es ]]; then printf '%s' "${2:-$1}"; else printf '%s' "$1"; fi; }
log()  { local text; text=$(ui_text "$1" "${2:-$1}"); echo ""; echo "==> [stage2] $text"; }
warn() { local text; text=$(ui_text "$1" "${2:-$1}"); echo "!!  [stage2] $text"; }

trap 'warn "failed at line $LINENO" "fallo en la linea $LINENO"; exit 1' ERR

# ---------------------------------------------------------------- pacman
SNAPSHOT_DIR=/root/prov/alarm-repositories
SNAPSHOT_MANIFEST="$SNAPSHOT_DIR/manifest.tsv"
SNAPSHOT_REPOSITORIES=(core extra alarm aur)

validate_repository_snapshot() {
  local repository line tag name digest size extra actual_size count
  local primary_url secondary_url snapshot_records="" computed_snapshot_id
  [[ -s $SNAPSHOT_MANIFEST ]] || { warn "the repository snapshot manifest is missing" "falta el manifiesto de la captura de repositorios"; return 1; }
  [[ $(find "$SNAPSHOT_DIR" -maxdepth 1 -type f -name '*.db' | wc -l) -eq 4 ]] \
    || { warn "the repository snapshot must contain exactly four databases" "la captura de repositorios debe contener exactamente cuatro bases"; return 1; }
  [[ $(awk -F '\t' '$1 == "format" && $2 == "alarm-repository-snapshot-v1" && NF == 2 { count++ } END { print count + 0 }' "$SNAPSHOT_MANIFEST") -eq 1 ]]
  [[ $(awk -F '\t' '$1 == "architecture" && $2 == "aarch64" && NF == 2 { count++ } END { print count + 0 }' "$SNAPSHOT_MANIFEST") -eq 1 ]]
  [[ $(awk -F '\t' '$1 == "primary-url" && $2 ~ /^https:\/\// && NF == 2 { count++ } END { print count + 0 }' "$SNAPSHOT_MANIFEST") -eq 1 ]]
  [[ $(awk -F '\t' '$1 == "secondary-url" && $2 ~ /^https:\/\// && NF == 2 { count++ } END { print count + 0 }' "$SNAPSHOT_MANIFEST") -eq 1 ]]
  primary_url=$(awk -F '\t' '$1 == "primary-url" { print $2 }' "$SNAPSHOT_MANIFEST")
  secondary_url=$(awk -F '\t' '$1 == "secondary-url" { print $2 }' "$SNAPSHOT_MANIFEST")
  [[ $primary_url != "$secondary_url" ]]
  [[ $(awk -F '\t' '$1 == "sync-marker" && $2 ~ /^[0-9]+$/ && NF == 2 { count++ } END { print count + 0 }' "$SNAPSHOT_MANIFEST") -eq 1 ]]
  [[ $(awk -F '\t' '$1 == "captured-at" && NF == 2 { count++ } END { print count + 0 }' "$SNAPSHOT_MANIFEST") -eq 1 ]]
  [[ $(awk 'NF && $1 !~ /^#/ { count++ } END { print count + 0 }' "$SNAPSHOT_MANIFEST") -eq 11 ]]
  SNAPSHOT_ID=$(awk -F '\t' '$1 == "snapshot-id" && NF == 2 { print $2 }' "$SNAPSHOT_MANIFEST")
  [[ $SNAPSHOT_ID =~ ^[0-9a-f]{64}$ ]] || { warn "the repository snapshot ID is invalid" "el identificador de la captura de repositorios no es valido"; return 1; }
  [[ $(awk -F '\t' '$1 == "repo" { count++ } END { print count + 0 }' "$SNAPSHOT_MANIFEST") -eq 4 ]]

  for repository in "${SNAPSHOT_REPOSITORIES[@]}"; do
    count=$(awk -F '\t' -v repository="$repository" '$1 == "repo" && $2 == repository { count++ } END { print count + 0 }' "$SNAPSHOT_MANIFEST")
    [[ $count -eq 1 ]] || { warn "missing or duplicate snapshot record for $repository" "falta o esta duplicado el registro de la captura para $repository"; return 1; }
    line=$(awk -F '\t' -v repository="$repository" '$1 == "repo" && $2 == repository { print; exit }' "$SNAPSHOT_MANIFEST")
    snapshot_records+="$line"$'\n'
    IFS=$'\t' read -r tag name digest size extra <<< "$line"
    [[ $tag == repo && $name == "$repository" && -z ${extra:-} && $digest =~ ^[0-9a-f]{64}$ && $size =~ ^[0-9]+$ ]]
    actual_size=$(stat -c '%s' "$SNAPSHOT_DIR/$repository.db")
    [[ $actual_size == "$size" ]] || { warn "$repository.db size does not match its manifest" "el tamano de $repository.db no coincide con su manifiesto"; return 1; }
    printf '%s  %s\n' "$digest" "$SNAPSHOT_DIR/$repository.db" | sha256sum -c - >/dev/null \
      || { warn "$repository.db SHA-256 does not match its manifest" "el sha256 de $repository.db no coincide con su manifiesto"; return 1; }
    tar -tzf "$SNAPSHOT_DIR/$repository.db" >/dev/null \
      || { warn "$repository.db is not a usable pacman database" "$repository.db no es una base utilizable de pacman"; return 1; }
  done
  computed_snapshot_id=$(printf '%s' "$snapshot_records" | sha256sum | awk '{ print $1 }')
  [[ $computed_snapshot_id == "$SNAPSHOT_ID" ]] \
    || { warn "the repository snapshot ID does not match its records" "el identificador de la captura no coincide con sus registros"; return 1; }
}

log "verifying the build-scoped repository snapshot" "verificando la captura de repositorios de esta construccion"
validate_repository_snapshot
install -d -m 0755 /var/lib/pacman/sync /usr/share/omarchy-arm/alarm-repositories
for repository in "${SNAPSHOT_REPOSITORIES[@]}"; do
  install -m 0644 "$SNAPSHOT_DIR/$repository.db" "/var/lib/pacman/sync/$repository.db"
  install -m 0644 "$SNAPSHOT_DIR/$repository.db" "/usr/share/omarchy-arm/alarm-repositories/$repository.db"
done
install -m 0644 "$SNAPSHOT_MANIFEST" /usr/share/omarchy-arm/alarm-repositories/manifest.tsv
install -m 0755 /root/prov/alarm-repository-snapshot.py /usr/share/omarchy-arm/alarm-repository-snapshot.py
echo "  $(ui_text 'snapshot' 'captura'): ${SNAPSHOT_ID:0:12}"

log "initializing the Arch Linux and Arch Linux ARM keyrings" "inicializando los llaveros de Arch Linux y Arch Linux ARM"
pacman-key --init
pacman-key --populate archlinux archlinuxarm

# The mirrors included in the tarball use HTTP. Although pacman verifies the signature of
# each package, TLS also protects the index, version selection, and
# availability. Two official mirrors with valid certificates are set.
: "${ALARM_MIRROR_PRIMARY:=https://ca.us.mirror.archlinuxarm.org}"
: "${ALARM_MIRROR_SECONDARY:=https://fl.us.mirror.archlinuxarm.org}"
case "$ALARM_MIRROR_PRIMARY" in https://*) ;; *) warn "the primary mirror must use HTTPS" "el mirror primario debe usar HTTPS"; exit 1 ;; esac
case "$ALARM_MIRROR_SECONDARY" in https://*) ;; *) warn "the secondary mirror must use HTTPS" "el mirror secundario debe usar HTTPS"; exit 1 ;; esac
{
  printf 'Server = %s/$arch/$repo\n' "$ALARM_MIRROR_PRIMARY"
  printf 'Server = %s/$arch/$repo\n' "$ALARM_MIRROR_SECONDARY"
} > /etc/pacman.d/mirrorlist
# A one-hour build cannot fail because a mirror hangs for ten
# seconds. DisableDownloadTimeout keeps retries useful and pacman
# maintains cryptographic verification for each package.
# DisableDownloadTimeout in pacman.conf, not as a standalone flag: this way it is inherited by
# ALL invocations, including the one makepkg -s performs internally to
# resolve build dependencies.
grep -q '^DisableDownloadTimeout' /etc/pacman.conf \
  || sed -i 's/^\[options\]/[options]\nDisableDownloadTimeout\nParallelDownloads = 5/' /etc/pacman.conf

# Retry package downloads without refreshing the build-scoped databases.
pac() {
  local intento
  for intento in 1 2 3; do
    if pacman -S --noconfirm --needed --disable-download-timeout "$@"; then return 0; fi
    warn "pacman failed (attempt $intento/3); retrying in ${intento}0 seconds" "pacman fallo (intento $intento/3); reintentando en ${intento}0 s"
    sleep "${intento}0"
  done
  return 1
}

log "updating the system from the captured repository snapshot" "actualizando el sistema desde la captura de repositorios"
pacman -Su --noconfirm --needed --disable-download-timeout \
  || pacman -Su --noconfirm --needed --disable-download-timeout

log "base system" "sistema base"
# linux-firmware is intentionally omitted: ~800 MB useless in a VM
pac base base-devel linux-aarch64 \
  sudo git vim networkmanager openssh which man-db man-pages less \
  btrfs-progs dosfstools e2fsprogs efibootmgr \
  rsync wget curl unzip zip

# ---------------------------------------------------------------- localization
log "timezone, locales, keyboard, and hostname" "zona horaria, locales, teclado, hostname"
ln -sf "/usr/share/zoneinfo/$VM_TIMEZONE" /etc/localtime
sed -i "s/^#\(${VM_LOCALE} \)/\1/; s/^#\(${VM_LOCALE_EXTRA} \)/\1/" /etc/locale.gen
grep -q "^${VM_LOCALE} " /etc/locale.gen || echo "${VM_LOCALE} UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=$VM_LOCALE" > /etc/locale.conf
# Hyprland reads XKBLAYOUT from here (default/hypr/input.lua); KEYMAP only
# covers the text console.
printf 'KEYMAP=%s\nXKBLAYOUT=%s\n' "$VM_KEYMAP" "$VM_XKB" > /etc/vconsole.conf
printf "OMARCHY_LANG='%s'\n" "${OMARCHY_LANG:-en}" > /etc/omarchy-arm.conf
echo "$VM_HOSTNAME" > /etc/hostname
cat > /etc/hosts <<EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   $VM_HOSTNAME.localdomain $VM_HOSTNAME
EOF
systemd-machine-id-setup || true

# ---------------------------------------------------------------- fstab
log "fstab"
if [ "$ROOTFS" = btrfs ]; then
cat > /etc/fstab <<EOF
LABEL=OMROOT  /      btrfs  rw,noatime,compress=zstd:3,subvol=@         0 0
LABEL=OMROOT  /home  btrfs  rw,noatime,compress=zstd:3,subvol=@home     0 0
LABEL=OMBOOT  /boot  vfat   rw,noatime,fmask=0137,dmask=0027,utf8=true  0 2
EOF
KERNEL_ROOTFLAGS="rootflags=subvol=@"
else
cat > /etc/fstab <<EOF
LABEL=OMROOT  /      ext4   rw,noatime                                  0 1
LABEL=OMBOOT  /boot  vfat   rw,noatime,fmask=0137,dmask=0027,utf8=true  0 2
EOF
KERNEL_ROOTFLAGS=""
fi
cat /etc/fstab

# ---------------------------------------------------------------- user
log "user $VM_USER" "usuario $VM_USER"
userdel -r alarm 2>/dev/null || true
if ! id -u "$VM_USER" >/dev/null 2>&1; then
  useradd -m -G wheel,video,audio,input,storage,network,lp -s /bin/bash -c "$VM_FULLNAME" "$VM_USER"
fi
echo "$VM_USER:$VM_PASSWORD" | chpasswd
echo "root:$VM_PASSWORD"     | chpasswd
install -m 0440 /dev/stdin /etc/sudoers.d/10-wheel <<<'%wheel ALL=(ALL:ALL) ALL'
# no password only during installation; removed at the end
install -m 0440 /dev/stdin /etc/sudoers.d/99-install <<<"$VM_USER ALL=(ALL:ALL) NOPASSWD: ALL"

# ---------------------------------------------------------------- initramfs
log "mkinitcpio (virtio + btrfs modules)" "mkinitcpio (modulos virtio + btrfs)"
sed -i 's/^MODULES=.*/MODULES=(virtio virtio_pci virtio_blk virtio_scsi virtio_net virtio_gpu 9p 9pnet 9pnet_virtio btrfs ext4)/' /etc/mkinitcpio.conf
grep -q '^MODULES=' /etc/mkinitcpio.conf || echo 'MODULES=(virtio virtio_pci virtio_blk virtio_gpu 9p 9pnet_virtio btrfs)' >> /etc/mkinitcpio.conf
mkinitcpio -P
echo "  /boot:"; ls -la /boot

# ---------------------------------------------------------------- UEFI boot
log "systemd-boot on the ESP" "systemd-boot en la ESP"
# --no-variables: we do not write to NVRAM; UTM boots via the fallback path
# \EFI\BOOT\BOOTAA64.EFI, which bootctl installs as well.
bootctl --esp-path=/boot --no-variables install

# The ESP is mounted empty AFTER extracting the rootfs, so /boot has no kernel.
# "pacman -S --needed" does not reinstall it if the installed version already matches
# the one in the repository, so the package reinstall is forced.
if [ ! -f /boot/Image ] && [ ! -f /boot/vmlinuz-linux-aarch64 ]; then
  echo "  $(ui_text '/boot is empty: reinstalling linux-aarch64 to populate it' '/boot vacio: reinstalando linux-aarch64 para repoblarlo')"
  pacman -S --noconfirm --disable-download-timeout linux-aarch64 || warn "could not reinstall the kernel" "no se pudo reinstalar el kernel"
  mkinitcpio -P || warn "mkinitcpio failed after reinstalling" "mkinitcpio fallo tras reinstalar"
fi

KERNEL_IMG=""
for c in /boot/Image /boot/vmlinuz-linux-aarch64 /boot/Image.gz; do
  [ -f "$c" ] && { KERNEL_IMG="/$(basename "$c")"; break; }
done
[ -n "$KERNEL_IMG" ] || { warn "kernel image not found in /boot" "no encuentro la imagen del kernel en /boot"; ls -la /boot; exit 1; }

INITRD=""
for c in /boot/initramfs-linux-aarch64.img /boot/initramfs-linux.img; do
  [ -f "$c" ] && { INITRD="/$(basename "$c")"; break; }
done
[ -n "$INITRD" ] || { warn "initramfs not found" "no encuentro el initramfs"; ls -la /boot; exit 1; }

mkdir -p /boot/loader/entries
cat > /boot/loader/loader.conf <<EOF
default  omarchy.conf
timeout  1
console-mode keep
editor   no
EOF
cat > /boot/loader/entries/omarchy.conf <<EOF
title    Arch Linux ARM — Omarchy
linux    $KERNEL_IMG
initrd   $INITRD
options  root=LABEL=OMROOT $KERNEL_ROOTFLAGS rw quiet loglevel=3
EOF
cat > /boot/loader/entries/omarchy-verbose.conf <<EOF
title    Arch Linux ARM — Omarchy ($(ui_text 'verbose' 'verboso'))
linux    $KERNEL_IMG
initrd   $INITRD
options  root=LABEL=OMROOT $KERNEL_ROOTFLAGS rw
EOF
echo "  kernel=$KERNEL_IMG initrd=$INITRD"
echo "  ESP:"; find /boot/EFI /boot/loader -maxdepth 3 | sort

# ---------------------------------------------------------------- networking
log "network: NetworkManager (disabling systemd-networkd from the tarball)" "red: NetworkManager (se desactiva systemd-networkd del tarball)"
systemctl disable systemd-networkd.service systemd-networkd.socket 2>/dev/null || true
systemctl disable systemd-resolved.service 2>/dev/null || true
rm -f /etc/systemd/network/*.network 2>/dev/null || true
systemctl enable NetworkManager.service
systemctl enable systemd-timesyncd.service 2>/dev/null || true

# ---------------------------------------------------------------- desktop
log "installing the desktop stack (Hyprland + Omarchy tools)" "instalando el stack de escritorio (Hyprland + herramientas de Omarchy)"
install_list() {
  local file="$1" label="$2" fatal="$3"
  mapfile -t PKGS < <(grep -vE '^\s*#|^\s*$' "$file")
  echo "  $label: ${#PKGS[@]} $(ui_text 'packages' 'paquetes')"
  if pac "${PKGS[@]}"; then return 0; fi
  warn "$label: bulk installation failed after 3 attempts; trying packages individually" "$label: instalacion en bloque fallida tras 3 intentos; probando uno a uno"
  local FAILED=()
  for p in "${PKGS[@]}"; do
    pacman -S --noconfirm --needed --disable-download-timeout "$p" >/dev/null 2>&1 && continue
    # Retry failed packages: the mirror, not the package, is usually at fault.
    sleep 3
    pacman -S --noconfirm --needed --disable-download-timeout "$p" >/dev/null 2>&1 || FAILED+=("$p")
  done
  if [ ${#FAILED[@]} -gt 0 ]; then
    warn "$label not installed: ${FAILED[*]}" "$label no instalados: ${FAILED[*]}"
    printf '%s\n' "${FAILED[@]}" >> /root/failed-packages.txt
    [ "$fatal" = fatal ] && return 1
  fi
  return 0
}
install_list /root/prov/packages-core.txt  "$(ui_text 'core' 'nucleo')" fatal
set +e
install_list /root/prov/packages-extra.txt "extras" soft
set -e

log "system services" "servicios de sistema"
systemctl enable sddm.service 2>/dev/null || warn "sddm is unavailable" "sddm no disponible"
# UTM integration: utmctl ip-address/exec/file require the guest agent
systemctl enable qemu-guest-agent.service 2>/dev/null || true
# The Arch Linux ARM rootfs comes with sshd started, and here we install
# openssh and set the same trivial password for the user and root. A personal VM
# (without the sanitize phase, which is where the only disable was) would
# remain listening with omarchy/omarchy. It is stopped by default; if you want it:
#   sudo systemctl enable --now sshd
systemctl disable sshd.service 2>/dev/null || true
systemctl disable sshd.socket  2>/dev/null || true
# The SPICE clipboard has THREE components, not two:
#   SPICE client (UTM) <-virtio port-> spice-vdagentd <-unix socket-> agent
# The daemon is what communicates with the host; the session agent only talks
# to the daemon. That is why you must keep spice-vdagentd alive even though its official
# agent (X11) is incompatible with Hyprland: replace the agent, not the
# daemon.
#
# And -X is needed: the "active seat0 session" check
# (vdagentd.c:746, systemd-login.c:272) fails with Hyprland launched by SDDM, and
# then the daemon silently discards the clipboard.
mkdir -p /etc/systemd/system/spice-vdagentd.service.d
cat > /etc/systemd/system/spice-vdagentd.service.d/override.conf <<'OVR'
[Service]
# -X: without logind integration. Without this, the daemon cannot find the "active
# seat0 session" under Hyprland and discards the clipboard without warning.
ExecStart=
ExecStart=/usr/bin/spice-vdagentd -X -x -f
OVR
systemctl enable spice-vdagentd.service 2>/dev/null || true
systemctl enable spice-vdagentd.socket 2>/dev/null || true
echo "  $(ui_text 'spice-vdagentd with -X (required under Hyprland)' 'spice-vdagentd con -X (necesario bajo Hyprland)')"

# No udev rule is installed for /dev/virtio-ports/com.redhat.spice.0.
# There was one, and it was wrong in two ways: omarchy-arm-vdagent never opens that
# port —it communicates via the unix socket /run/spice-vdagentd/spice-vdagent-sock,
# as stage3 itself explains—, and the port is exclusively opened by the daemon.
# Granting the seat user an ACL with TAG+="uaccess" only allows another process
# to take the port from the daemon and leave it without a channel ("Device or resource
# busy"), which is precisely the first dead end of this problem.
# MODE="0660" additionally did nothing: without GROUP=, the group remains root.

# UTM's shared folder has TWO modes, and the user chooses which one:
#   VirtFS → 9p device with mount_tag "share"
#   SPICE WebDAV → virtio port org.spice-space.webdav.0, served by
#     spice-webdavd (phodav package) at http://localhost:9843/
# Both are prepared: each activates only if its device exists.
systemctl enable spice-webdavd.service 2>/dev/null || true
echo "  $(ui_text 'spice-webdavd enabled (UTM SPICE WebDAV mode)' 'spice-webdavd habilitado (modo SPICE WebDAV de UTM)')"

# UTM shared folder. The bundle declares DirectoryShareMode=VirtFS, but
# this only exposes the device: the guest must mount it. The tag is
# "share" (UTM, Configuration/UTMQemuConfiguration+Arguments.swift:1234).
# nofail so that a boot without a configured shared folder does not drop to emergency,
# and x-systemd.automount to avoid the cost of mounting if it is not used.
mkdir -p /mnt/share
# The fstab entry is only valid for VirtFS, and the user may have chosen
# SPICE WebDAV. Instead of fixing a mode, omarchy-arm-share is installed, which
# detects which one is active. The fstab entry is left with nofail:
# if the 9p device exists, it is mounted only at boot.
if ! grep -q '^share ' /etc/fstab; then
  cat >> /etc/fstab <<'FSTAB'

# Shared folder of UTM in VirtFS mode. If you chose SPICE WebDAV, this
# line does nothing (nofail) and mounts omarchy-arm-share.
share  /mnt/share  9p  trans=virtio,version=9p2000.L,rw,nofail,x-systemd.automount,_netdev,msize=512000  0  0
FSTAB
fi
echo "  $(ui_text '/mnt/share prepared (VirtFS through fstab, WebDAV through omarchy-arm-share)' '/mnt/share preparado (VirtFS por fstab, WebDAV con omarchy-arm-share)')"
systemctl enable bluetooth.service 2>/dev/null || true
systemctl enable docker.service 2>/dev/null || true
usermod -aG docker "$VM_USER" 2>/dev/null || true

# ---------------------------------------------------------------- dotfiles
log "stage 3: Omarchy dotfiles as $VM_USER" "etapa 3: dotfiles de Omarchy como $VM_USER"
chmod +x /root/prov/stage3.sh
install -Dm644 /root/prov/core-git-sources.tsv /usr/share/omarchy-arm/core-git-sources.tsv
install -Dm644 /root/prov/free-app-artifacts.tsv /usr/share/omarchy-arm/free-app-artifacts.tsv
install -d -o "$VM_USER" -g "$VM_USER" "/home/$VM_USER"
# stage3 runs as a normal user and /root is 0750: any test you perform on
# /root/prov returns false without error. A readable copy is left in their home.
PROVDIR="/home/$VM_USER/.omarchy-arm-prov"
mkdir -p "$PROVDIR"
for f in omarchy-arm-extras 10-arm-sync omarchy-arm-clipboard omarchy-arm-vdagent omarchy-arm-share; do
  [ -f "/root/prov/$f" ] && install -m 0644 "/root/prov/$f" "$PROVDIR/$f"
done
cp /root/prov/stage3.sh /root/prov/config.env "/home/$VM_USER/"
chown -R "$VM_USER:$VM_USER" "$PROVDIR"
chown "$VM_USER:$VM_USER" "/home/$VM_USER/stage3.sh" "/home/$VM_USER/config.env"
echo "  $(ui_text 'available to stage3' 'disponible para stage3'): $(ls "$PROVDIR" | tr '\n' ' ')"
# The result of stage3 must reach the host: previously it degraded to a
# warn and stage2 emitted its success token anyway, so a completely failed stage3
# produced a disk with not a single Omarchy dotfile declared OK.
# NOTE: with `set -e` + trap ERR, writing `su ...; RC=$?` does NOT work: if su
# returns != 0 the trap triggers and the stage dies BEFORE the assignment, so
# TOK_STAGE3_<rc> was emitted only when rc=0, and the host never
# saw the specific failure of stage3. With `|| RC=$?` the command is
# in a tested context, so set -e does not trigger.
STAGE3_RC=0
su - "$VM_USER" -c "bash ~/stage3.sh" || STAGE3_RC=$?
[ $STAGE3_RC -eq 0 ] || warn "stage3 finished with errors (rc=$STAGE3_RC)" "stage3 termino con errores (rc=$STAGE3_RC)"
echo "TOK_STAGE3_$STAGE3_RC"
rm -f "/home/$VM_USER/stage3.sh" "/home/$VM_USER/config.env"
rm -rf "$PROVDIR"

log "recording installed-package provenance" "registrando la procedencia de los paquetes instalados"
python3 /usr/share/omarchy-arm/alarm-repository-snapshot.py validate \
  /usr/share/omarchy-arm/alarm-repositories \
  /usr/share/omarchy-arm/alarm-repositories/manifest.tsv
python3 /usr/share/omarchy-arm/alarm-repository-snapshot.py provenance \
  /usr/share/omarchy-arm/alarm-repositories \
  /usr/share/omarchy-arm/alarm-repositories/manifest.tsv \
  /usr/share/omarchy-arm/alarm-package-provenance.tsv
python3 /usr/share/omarchy-arm/alarm-repository-snapshot.py validate-provenance \
  /usr/share/omarchy-arm/alarm-repositories \
  /usr/share/omarchy-arm/alarm-repositories/manifest.tsv \
  /usr/share/omarchy-arm/alarm-package-provenance.tsv
echo "  $(ui_text 'repository packages verified from cached bytes' 'paquetes de repositorios verificados desde bytes en cache'): $(awk -F '\t' 'NR > 1 && $2 == "repository-cache+mtree" { count++ } END { print count + 0 }' /usr/share/omarchy-arm/alarm-package-provenance.tsv)"
echo "  $(ui_text 'snapshot metadata matches without cached bytes' 'coincidencias con la captura sin bytes en cache'): $(awk -F '\t' 'NR > 1 && $2 == "snapshot-metadata-only" { count++ } END { print count + 0 }' /usr/share/omarchy-arm/alarm-package-provenance.tsv)"
echo "  $(ui_text 'local, unknown, or ambiguous packages' 'paquetes locales, desconocidos o ambiguos'): $(awk -F '\t' 'NR > 1 && $2 != "repository-cache+mtree" && $2 != "snapshot-metadata-only" { count++ } END { print count + 0 }' /usr/share/omarchy-arm/alarm-package-provenance.tsv)"

# ---------------------------------------------------------------- login SDDM
log "SDDM: Omarchy session with autologin" "SDDM: sesion Omarchy con autologin"
OM="/home/$VM_USER/.local/share/omarchy"
mkdir -p /usr/local/share/wayland-sessions /etc/sddm.conf.d /usr/share/sddm
if [ -f "$OM/default/wayland-sessions/omarchy.desktop" ]; then
  cp "$OM/default/wayland-sessions/omarchy.desktop" /usr/local/share/wayland-sessions/omarchy.desktop
  SESSION=omarchy
else
  SESSION=hyprland-uwsm
fi
[ -f "$OM/default/sddm/hyprland.conf" ] && cp "$OM/default/sddm/hyprland.conf" /usr/share/sddm/hyprland.conf
cat > /etc/sddm.conf.d/10-wayland.conf <<EOF
[General]
DisplayServer=wayland
EOF
cat > /etc/sddm.conf.d/autologin.conf <<EOF
[Autologin]
User=$VM_USER
Session=$SESSION
EOF
sed -i '/-auth.*pam_gnome_keyring\.so/d;/-password.*pam_gnome_keyring\.so/d' /etc/pam.d/sddm 2>/dev/null || true
echo "  $(ui_text 'session' 'sesion')=$SESSION"
ls /usr/local/share/wayland-sessions /usr/share/wayland-sessions 2>/dev/null

# ---------------------------------------------------------------- VM settings
log "virtual-machine-specific settings" "ajustes propios de maquina virtual"
# The hardware cursor and DRM modifiers cause issues over virtio-gpu
mkdir -p /etc/environment.d
cat > /etc/environment.d/90-vm-graphics.conf <<'EOF'
# virtio-gpu (virgl) bajo UTM/QEMU
WLR_NO_HARDWARE_CURSORS=1
AQ_NO_MODIFIERS=1
WLR_RENDERER_ALLOW_SOFTWARE=1
# Without this, GPU client windows (alacritty, chromium) are mapped but
# NOT painted: virgl does not deliver buffers that Hyprland can compose. Only
# clients using wl_shm render (foot). With llvmpipe all work.
# Verified that these do NOT fix it: AQ_NO_MODIFIERS, render:cm_enabled=false,
# render:explicit_sync (eliminado en Hyprland 0.56).
LIBGL_ALWAYS_SOFTWARE=1
EOF
# serial console useful for debugging from the host
systemctl enable serial-getty@ttyAMA0.service 2>/dev/null || true

log "cleanup" "limpieza"
rm -f /etc/sudoers.d/99-install
paccache -rk1 2>/dev/null || true
rm -rf /var/cache/pacman/pkg/* 2>/dev/null || true

log "summary" "resumen"
echo "  kernel:    $(pacman -Q linux-aarch64 2>/dev/null || echo '?')"
echo "  hyprland:  $(pacman -Q hyprland 2>/dev/null || echo 'NO INSTALADO')"
echo "  sddm:      $(pacman -Q sddm 2>/dev/null || echo 'NO INSTALADO')"
echo "  mesa:      $(pacman -Q mesa 2>/dev/null || echo '?')"
echo "  $(ui_text 'user' 'usuario'):   $(id "$VM_USER")"
echo "  dotfiles:  $(ls -d /home/$VM_USER/.config/hypr 2>/dev/null || ui_text 'MISSING' 'FALTAN')"
sync
touch /root/STAGE2_OK
echo ""
echo "==> [stage2] $(ui_text 'COMPLETED' 'COMPLETADO')"
