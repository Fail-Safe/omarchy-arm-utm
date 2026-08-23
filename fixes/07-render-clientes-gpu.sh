#!/bin/bash
# Las ventanas de clientes GPU (alacritty, chromium...) se mapean pero no se
# pintan bajo virtio-gpu/virgl: solo renderizan los clientes que usan buffers
# de memoria compartida (foot). Comprobado que NO lo arreglan:
#   - AQ_NO_MODIFIERS=1            (ya estaba activo)
#   - render:explicit_sync         (eliminado en Hyprland 0.56)
#   - render:cm_enabled = false    (probado, sigue igual)
# Lo que si funciona: LIBGL_ALWAYS_SOFTWARE=1, que hace que Mesa use llvmpipe y
# los clientes entreguen buffers wl_shm. Se pierde la aceleracion GL dentro de
# la VM, pero el escritorio es utilizable. Para revertirlo cuando Mesa/Hyprland
# lo arreglen, basta con borrar la linea de /etc/environment.d/90-vm-graphics.conf
set -uo pipefail
log() { echo ""; echo "==> $*"; }

log "LIBGL_ALWAYS_SOFTWARE en el entorno de la sesion"
sudo tee /etc/environment.d/90-vm-graphics.conf >/dev/null <<'EOF'
# virtio-gpu (virgl) bajo UTM/QEMU
WLR_NO_HARDWARE_CURSORS=1
AQ_NO_MODIFIERS=1
WLR_RENDERER_ALLOW_SOFTWARE=1
# Los clientes GPU no entregan buffers componibles bajo virgl: sus ventanas se
# quedan en negro. Con llvmpipe usan wl_shm y se pintan correctamente.
LIBGL_ALWAYS_SOFTWARE=1
EOF
cat /etc/environment.d/90-vm-graphics.conf

log "looknfeel: sin blur (caro con renderizado por software)"
cat > ~/.config/hypr/looknfeel.lua <<'LUA'
-- Ajustes para VM: el renderizado va por llvmpipe (ver 90-vm-graphics.conf),
-- asi que el blur sale caro. Sin el, el escritorio va fluido.
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
