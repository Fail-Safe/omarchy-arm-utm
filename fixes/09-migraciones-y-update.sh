#!/bin/bash
# omarchy-update failed because the build did not mark existing migrations as applied.
# A standard Omarchy installer marks all of them as applied upon completion
# (the system starts with the final state); here only 8 of 83 were marked,
# so omarchy-update attempted to reproduce 75 historical migrations and crashed
# on the one that replaces `dust` with `tensaku`, an Omarchy-specific package that does
# not exist in Arch Linux ARM. As a side effect, the system is left without `dust`.
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
# Wrapper for Arch Linux ARM.
#
# Omarchy-specific packages (tensaku, omarchy-nvim, ttfx...) and several proprietary apps
# are only available for x86_64. The original omarchy-pkg-add aborts with
# an error if any are missing, which causes the entire omarchy-update to fail and leaves
# migrations incomplete. This wrapper skips those not present in any repository,
# notifies which ones, and installs the rest using the original script.
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
