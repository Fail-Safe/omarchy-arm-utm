#!/bin/bash
# Hace que "Update System" funcione de verdad y de forma segura en ARM.
#
#  1. snapper: sin el, omarchy-snapshot devuelve 127 y cada actualizacion se
#     hace SIN red de seguridad. Con el, hay instantanea previa y rollback.
#  2. hook post-update: omarchy-update-dev solo hace git pull cuando
#     OMARCHY_PATH != /usr/share/omarchy, y aqui apunta justo ahi, asi que el
#     arbol de Omarchy no se actualizaria nunca.
set -uo pipefail
log() { echo ""; echo "==> $*"; }

log "1/3 snapper: instantanea antes de cada actualizacion"
sudo pacman -S --noconfirm --needed snapper >/dev/null 2>&1 || { echo "  no se pudo instalar snapper"; }
if command -v snapper >/dev/null; then
  sudo bash -euo pipefail /usr/share/omarchy/install/config/snapper.sh 2>&1 | sed 's/^/  /'
  echo "  configs: $(sudo snapper --csvout list-configs 2>/dev/null | awk -F, 'NR>1{print $1}' | tr '\n' ' ')"
else
  echo "  snapper no disponible"
fi

log "2/3 hook post-update que actualiza el arbol de Omarchy"
install -Dm755 /root/prov/10-arm-sync "$HOME/.config/omarchy/hooks/post-update.d/10-arm-sync" 2>/dev/null \
  || install -Dm755 /tmp/10-arm-sync "$HOME/.config/omarchy/hooks/post-update.d/10-arm-sync"
ls -l "$HOME/.config/omarchy/hooks/post-update.d/"

log "3/3 comprobacion: ejecutar el hook ahora"
"$HOME/.config/omarchy/hooks/post-update.d/10-arm-sync"

log "estado"
echo "  commit del arbol: $(git -C /usr/share/omarchy log -1 --format='%h %ci' 2>/dev/null)"
echo "  snapshots:        $(sudo snapper -c root list 2>/dev/null | wc -l) lineas"
echo "  binarios:         $(ls /usr/local/bin | wc -l)"
echo "  enlaces rotos:    $(find /usr/local/bin -xtype l | wc -l)"
echo ""
echo "==> FIX14_OK"
