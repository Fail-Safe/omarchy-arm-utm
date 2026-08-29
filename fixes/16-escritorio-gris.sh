#!/bin/bash
# 16 · The gray desktop
#
# Symptom: the already sanitized image started with a plain gray background and
# notifications as gray boxes without styling. No errors in journalctl.
#
# Two independent causes, none visible with the checks I performed:
#
#  a) `grep -rl gabriel` returned 0 matches because grep reads CONTENT, and the
#     target of a symlink is not content. 439 links remained pointing to the old home
#     directory, including the 431 omarchy-* commands in /usr/local/bin and the
#     active background (~/.local/state/omarchy/current/background).
#
#  b) I had mako, swayosd, walker, and elephant installed. Omarchy 4 retires them
#     (bin/omarchy-upgrade-to-quattro uninstalls them) because quickshell handles
#     that work. mako activates via D-Bus and steals its name
#     org.freedesktop.Notifications from the shell.
#
# Fixed at the source: provision/src/sanitize.sh rewrites the symlinks and
# verifies that the background resolves; stage3.sh no longer installs those four packages.
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
