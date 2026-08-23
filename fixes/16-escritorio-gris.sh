#!/bin/bash
# 16 · El escritorio gris
#
# Sintoma: la imagen ya sanitizada arrancaba con el fondo en gris liso y las
# notificaciones como cajas grises sin estilo. Ningun error en journalctl.
#
# Dos causas independientes, ninguna visible con las comprobaciones que hacia:
#
#  a) `grep -rl gabriel` daba 0 coincidencias porque grep lee CONTENIDO, y el
#     destino de un symlink no lo es. Quedaban 439 enlaces apuntando al home
#     antiguo, incluidos los 431 comandos omarchy-* de /usr/local/bin y el
#     fondo activo (~/.local/state/omarchy/current/background).
#
#  b) Tenia instalados mako, swayosd, walker y elephant. Omarchy 4 los jubila
#     (bin/omarchy-upgrade-to-quattro los desinstala) porque quickshell hace
#     ese trabajo. mako se activa por D-Bus y le roba el nombre
#     org.freedesktop.Notifications al shell.
#
# Corregido en origen: provision/src/sanitize.sh reescribe los symlinks y
# verifica que el fondo resuelve; stage3.sh ya no instala esos cuatro paquetes.
set -uo pipefail
NEW=omarchy; OLD=gabriel

echo "==> a) symlinks que apuntan al home antiguo"
mapfile -t BAD < <(find /home/$NEW /etc /usr/local /opt -xdev -type l -lname "*/home/$OLD/*" 2>/dev/null)
echo "  encontrados: ${#BAD[@]}"
for l in "${BAD[@]:-}"; do
  [ -n "$l" ] || continue
  t=$(readlink "$l"); ln -sfn "${t//\/home\/$OLD\//\/home\/$NEW\/}" "$l"
done
echo "  quedan: $(find /home/$NEW /etc /usr/local /opt -xdev -type l -lname "*/home/$OLD/*" 2>/dev/null | wc -l)"
echo "  fondo: $(readlink -f /home/$NEW/.local/state/omarchy/current/background)"

echo "==> b) paquetes que Omarchy 4 jubila"
pacman -Rns --noconfirm mako swayosd walker elephant 2>&1 | tail -3
rm -rf /home/$NEW/.config/mako /home/$NEW/.config/walker /home/$NEW/.config/swayosd
rm -f  /usr/local/bin/walker
O=$(pacman -Qtdq 2>/dev/null | tr '\n' ' '); [ -n "${O// /}" ] && pacman -Rns --noconfirm $O >/dev/null 2>&1

echo "==> verificacion"
echo "  enlaces rotos: $(find /home/$NEW /usr/local/bin -xdev -type l ! -exec test -e {} \; -print 2>/dev/null | wc -l)"
echo "  jubilados presentes: $(for p in mako swayosd walker elephant; do pacman -Q $p >/dev/null 2>&1 && echo -n "$p "; done; echo -n ninguno)"
sync
