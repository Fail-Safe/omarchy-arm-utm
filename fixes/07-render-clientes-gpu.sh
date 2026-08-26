#!/bin/bash
# GPU client windows (alacritty, chromium...) are mapped but not
# rendered under virtio-gpu/virgl: only clients using shared memory
# buffers (foot) render. Confirmed that the following do NOT fix it:
#   - AQ_NO_MODIFIERS=1            (already active)
#   - render:explicit_sync         (eliminado en Hyprland 0.56)
#   - render:cm_enabled = false    (probado, sigue igual)
# What does work: LIBGL_ALWAYS_SOFTWARE=1, which makes Mesa use llvmpipe and
# clients deliver wl_shm buffers. GL acceleration inside the
# VM is lost, but the desktop is usable. To revert it when Mesa/Hyprland
# fix it, simply delete the line from /etc/environment.d/90-vm-graphics.conf
set -uo pipefail
log() { echo ""; echo "==> $*"; }

log "LIBGL_ALWAYS_SOFTWARE en el entorno de la sesion"
sudo tee /etc/environment.d/90-vm-graphics.conf >/dev/null <<'EOF'
# virtio-gpu (virgl) bajo UTM/QEMU
WLR_NO_HARDWARE_CURSORS=1
AQ_NO_MODIFIERS=1
WLR_RENDERER_ALLOW_SOFTWARE=1
# GPU clients do not deliver composable buffers under virgl: their windows remain
# black. With llvmpipe they use wl_shm and render correctly.
LIBGL_ALWAYS_SOFTWARE=1
EOF
cat /etc/environment.d/90-vm-graphics.conf

log "looknfeel: sin blur (caro con renderizado por software)"
cat > ~/.config/hypr/looknfeel.lua <<'LUA'
-- VM settings: rendering is done via llvmpipe (see 90-vm-graphics.conf),
-- so blur is expensive. Without it, the desktop runs smoothly.
hl.config({
  decoration = {
    blur = { enabled = false },
    shadow = { enabled = false },
  },
})
LUA

log "reiniciando para que todo el arbol de la sesion herede el entorno"
sync
sudo systemctl reboot
