#!/bin/bash
# La VM se construyo con la lista de paquetes de la rama master (3.8.5, que usa
# waybar). La rama quattro (4.x) que corre en la VM usa su propio shell basado
# en quickshell y pide paquetes adicionales. Aqui se instala ese delta.
set -uo pipefail
log() { echo ""; echo "==> $*"; }

log "paquetes que faltan de la lista de quattro"
# quickshell-git no existe en Arch Linux ARM; quickshell 0.3.1 lo sustituye
PKGS=(quickshell bluez-tools bluez-utils ddcutil dua-cli foot inotify-tools
      libvips lua51 mpv-mpris qrencode qt6-imageformats udiskie wtype yt-dlp
      zbar cava)
sudo pacman -S --noconfirm --needed "${PKGS[@]}" 2>&1 | tail -12 || {
  echo "!! bloque fallido, uno a uno"
  for p in "${PKGS[@]}"; do sudo pacman -S --noconfirm --needed "$p" >/dev/null 2>&1 || echo "   falla: $p"; done
}

log "comprobacion"
for b in quickshell udiskie wtype ddcutil; do printf "  %-14s %s\n" "$b" "$(command -v $b || echo NO)"; done

log "ajustes de VM en los ficheros .lua correctos"
# quattro usa configuracion Lua: los .conf que escribi en la build (monitors.conf,
# autostart.conf) no los lee nadie. Los ajustes van en monitors.lua.
cat > ~/.config/hypr/monitors.lua <<'LUA'
-- Ajustado para VM (UTM/QEMU virtio-gpu).
-- Omarchy asume pantallas retina 2x; en la VM eso deja todo gigante.
-- Ver resoluciones disponibles:  hyprctl monitors
o.env("GDK_SCALE", "1")
o.monitor("", { mode = "preferred", position = "auto", scale = 1 })
LUA
rm -f ~/.config/hypr/monitors.conf ~/.config/hypr/autostart.conf
echo "  monitors.lua escrito; .conf huerfanos eliminados"
ls ~/.config/hypr/

log "arrancando el shell de Omarchy en la sesion viva"
export XDG_RUNTIME_DIR=/run/user/1000
export HYPRLAND_INSTANCE_SIGNATURE=$(ls /run/user/1000/hypr 2>/dev/null | head -1)
export WAYLAND_DISPLAY=$(ls /run/user/1000 | grep -m1 '^wayland-[0-9]')
export OMARCHY_PATH=/usr/share/omarchy
echo "  WAYLAND_DISPLAY=$WAYLAND_DISPLAY  HIS=${HYPRLAND_INSTANCE_SIGNATURE:0:20}..."
hyprctl reload 2>&1 | head -3
setsid omarchy-launch-shell >/tmp/shell.log 2>&1 &
sleep 8
echo "  procesos:"; pgrep -a quickshell | head -3; pgrep -a elephant | head -2
echo "  log del shell:"; tail -15 /tmp/shell.log 2>/dev/null

log "estado final"
pgrep -a Hyprland | head -1
hyprctl configerrors 2>&1 | head -5
echo ""
echo "==> FIX2_OK"
