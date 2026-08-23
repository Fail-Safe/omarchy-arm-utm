#!/bin/bash
# Replica en las rutas fijas del sistema lo que hace el paquete pacman
# `omarchy` (que solo existe para x86_64). La rama quattro espera el arbol en
# /usr/share/omarchy y los binarios en el PATH del sistema; sin eso
# OMARCHY_PATH queda vacio, el bashrc falla y Hyprland cae en modo emergencia
# por no encontrar /usr/share/omarchy/default/hypr/bootstrap.lua
#
# Se ejecuta como ROOT dentro del chroot (sin sudo).
set -uo pipefail
USR=gabriel
OM=/home/$USR/.local/share/omarchy
log() { echo ""; echo "==> $*"; }

[ -d "$OM" ] || { echo "!! no existe $OM"; exit 1; }

log "1/8 arbol en /usr/share/omarchy"
ln -sfn "$OM" /usr/share/omarchy
ls -ld /usr/share/omarchy
ls /usr/share/omarchy/default/hypr/ | head

log "2/8 binarios de Omarchy en el PATH del sistema"
# El paquete los publica como /usr/bin/omarchy-*; usamos /usr/local/bin para no
# invadir territorio de pacman. Va antes que /usr/bin y esta en el secure_path
# de sudo, asi que tambien lo ven SDDM y systemd.
mkdir -p /usr/local/bin
n=0
for f in "$OM"/bin/*; do
  [ -f "$f" ] || continue
  chmod +x "$f"
  ln -sfn "$f" "/usr/local/bin/$(basename "$f")" && n=$((n+1))
done
echo "  $n binarios enlazados"
ls -l /usr/local/bin/start-hyprland /usr/local/bin/omarchy-theme-set 2>&1 | head -3

log "3/8 hooks de shell y de sesion uwsm"
install -Dm644 "$OM/etc/profile.d/omarchy.sh" /etc/profile.d/omarchy.sh
install -Dm644 "$OM/default/uwsm/env.d/10-omarchy" /usr/share/uwsm/env.d/10-omarchy
cat /etc/profile.d/omarchy.sh

log "4/8 configuracion de sistema del repo (lo aplicable a una VM)"
cp -a "$OM/etc/sysctl.d/."  /etc/sysctl.d/  2>/dev/null || true
cp -a "$OM/etc/security/."  /etc/security/  2>/dev/null || true
for d in system.conf.d user.conf.d logind.conf.d oomd.conf.d; do
  [ -d "$OM/etc/systemd/$d" ] && cp -a "$OM/etc/systemd/$d" /etc/systemd/ 2>/dev/null || true
done
[ -d "$OM/etc/fastfetch" ] && cp -a "$OM/etc/fastfetch" /etc/ 2>/dev/null || true
[ -d "$OM/etc/gnupg" ] && cp -a "$OM/etc/gnupg/." /etc/gnupg/ 2>/dev/null || true

log "5/8 SDDM: tema Omarchy, compositor y autologin"
mkdir -p /usr/share/sddm/themes /usr/local/share/wayland-sessions /etc/sddm.conf.d
cp -a "$OM/default/sddm/omarchy" /usr/share/sddm/themes/ 2>/dev/null || true
[ -f "$OM/default/sddm/hyprland.lua" ] && cp -a "$OM/default/sddm/hyprland.lua" /usr/share/sddm/hyprland.lua
install -Dm644 "$OM/etc/sddm.conf.d/10-theme.conf"   /etc/sddm.conf.d/10-theme.conf
install -Dm644 "$OM/etc/sddm.conf.d/10-wayland.conf" /etc/sddm.conf.d/10-wayland.conf
install -Dm644 "$OM/default/wayland-sessions/omarchy.desktop" /usr/local/share/wayland-sessions/omarchy.desktop
cat > /etc/sddm.conf.d/20-autologin.conf <<EOF
[Autologin]
User=$USR
Session=omarchy
EOF
for p in /etc/pam.d/sddm /etc/pam.d/sddm-autologin /etc/pam.d/sddm-greeter; do
  [ -f "$p" ] && sed -i '/-auth.*pam_gnome_keyring\.so/d;/-password.*pam_gnome_keyring\.so/d' "$p"
done
ls /usr/share/sddm/themes/ /etc/sddm.conf.d/

log "6/8 theme-system.sh de Omarchy"
bash "$OM/install/config/theme-system.sh" 2>&1 | tail -3 || true

log "7/8 servicios y acceso"
systemctl enable systemd-oomd.service 2>/dev/null || true
systemctl enable sshd.service 2>/dev/null || true
systemctl mask NetworkManager-wait-online.service 2>/dev/null || true
# clave SSH del host para poder verificar sin tocar la consola serie
install -d -m700 -o $USR -g $USR /home/$USR/.ssh
cp /root/prov/omkey.pub /home/$USR/.ssh/authorized_keys
chown $USR:$USR /home/$USR/.ssh/authorized_keys
chmod 600 /home/$USR/.ssh/authorized_keys

log "8/8 tema como usuario, ya con el entorno correcto"
su - $USR -c 'export OMARCHY_PATH=/usr/share/omarchy; export PATH=/usr/local/bin:$PATH; mkdir -p ~/.config/omarchy/themes; omarchy-theme-set "Tokyo Night" 2>&1 | tail -5' || echo "  (theme-set fallo)"
su - $USR -c 'ls -l ~/.config/omarchy/current/ 2>/dev/null; echo "OMARCHY_PATH=[$OMARCHY_PATH]"; command -v omarchy-menu start-hyprland' || true

log "comprobacion"
echo "  bootstrap.lua: $(ls /usr/share/omarchy/default/hypr/bootstrap.lua 2>&1)"
echo "  bashrc:        $(su - $USR -c 'bash -ic true' 2>&1 | tail -1)"
echo ""
echo "==> FIX_OK"
