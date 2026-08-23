#!/bin/bash
# omarchy-update fallaba porque el build no sello las migraciones existentes.
# Un instalador normal de Omarchy las marca todas como aplicadas al terminar
# (el sistema ya nace con el estado final); aqui solo habia 8 de 83 selladas,
# asi que omarchy-update intento reproducir 75 migraciones historicas y murio
# en la que sustituye `dust` por `tensaku`, paquete propio de Omarchy que no
# existe en Arch Linux ARM. De paso dejo el sistema sin `dust`.
set -uo pipefail
log() { echo ""; echo "==> $*"; }
STATE="$HOME/.local/state/omarchy/migrations"
MIGR=/usr/share/omarchy/migrations

log "1/5 sellando las migraciones existentes (como un install limpio)"
mkdir -p "$STATE"
n=0
for f in "$MIGR"/*.sh; do
  b=$(basename "$f")
  [ -e "$STATE/$b" ] || { : > "$STATE/$b"; n=$((n+1)); }
done
echo "  selladas $n nuevas; total $(ls -1 "$STATE" | wc -l) de $(ls -1 "$MIGR"/*.sh | wc -l)"
echo "  pendientes ahora: $(omarchy-migrate --pending 2>/dev/null | wc -l)"

log "2/5 recuperando dust (lo quito la migracion fallida)"
sudo pacman -S --noconfirm --needed dust 2>&1 | tail -3
pacman -Q dust 2>&1

log "3/5 blindando omarchy-pkg-add frente a paquetes que no existen en ARM"
sudo tee /usr/local/bin/omarchy-pkg-add >/dev/null <<'WRAP'
#!/bin/bash
# Envoltorio para Arch Linux ARM.
#
# Los paquetes propios de Omarchy (tensaku, omarchy-nvim, ttfx...) y varias apps
# propietarias solo existen para x86_64. El omarchy-pkg-add original aborta con
# error si alguno falta, lo que hace fallar omarchy-update entero y deja las
# migraciones a medias. Este envoltorio omite los que no estan en ningun repo,
# avisa de cuales, e instala el resto con el script original.
REAL=/usr/share/omarchy/bin/omarchy-pkg-add
avail=(); skip=()
for p in "$@"; do
  if pacman -Q "$p" &>/dev/null || pacman -Si "$p" &>/dev/null; then
    avail+=("$p")
  else
    skip+=("$p")
  fi
done
if ((${#skip[@]})); then
  printf '\033[33mOmitido, no existe en Arch Linux ARM: %s\033[0m\n' "${skip[*]}" >&2
fi
((${#avail[@]})) || exit 0
exec "$REAL" "${avail[@]}"
WRAP
sudo chmod +x /usr/local/bin/omarchy-pkg-add
echo "  probando el envoltorio:"
omarchy-pkg-add tensaku jq 2>&1 | tail -3

log "4/5 limpiando huerfanos de las compilaciones AUR"
orph=$(pacman -Qdtq 2>/dev/null)
[ -n "$orph" ] && sudo pacman -Rns --noconfirm $orph 2>&1 | tail -3 || echo "  (ninguno)"

log "5/5 re-ejecutando omarchy-update"
OMARCHY_UPDATE_NONINTERACTIVE=1 omarchy-update 2>&1 | tail -25
echo "  codigo de salida: $?"

log "estado"
echo "  pendientes: $(omarchy-migrate --pending 2>/dev/null | wc -l)"
echo "  dust:       $(pacman -Q dust 2>/dev/null || echo NO)"
echo ""
echo "==> FIX9_OK"
