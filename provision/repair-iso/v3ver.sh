#!/bin/bash
set -uo pipefail
U=omarchy
echo "══ LA PRUEBA: ¿se cierra el bucle en un build de cero? ══"
echo "  first-run marcado: $(test -e /home/$U/.local/state/omarchy/done/first-run-user && echo SÍ || echo NO)"
grep -c "Failed:" /home/$U/.local/state/omarchy/first-run.log 2>/dev/null | sed 's/^/  pasos fallidos en el log: /'
tail -3 /home/$U/.local/state/omarchy/first-run.log 2>/dev/null | sed 's/^/    /'
echo
echo "══ unidades habilitadas ══"
find /home/$U/.config/systemd/user -name '*.service' 2>/dev/null | wc -l | sed 's/^/  /'
echo
echo "══ comandos y enlaces ══"
echo "  omarchy-* en /usr/bin:     $(ls /usr/bin | grep -c '^omarchy-')"
echo "  destino: $(readlink /usr/bin/omarchy-shell)"
echo "  enlaces rotos:             $(find /usr/bin -xtype l 2>/dev/null | wc -l)"
echo
echo "══ envoltorio del kernel ══"
echo "  $(test -x /usr/local/bin/omarchy-update-restart && echo instalado || echo FALTA)"
V=$(ls /usr/lib/modules/ | head -1)
echo "  $V → $(pacman -Qoq /usr/lib/modules/$V/modules.builtin 2>&1 | head -1)"
echo
echo "══ contenido ══"
for p in hyprland quickshell obs-studio pinta; do printf "  %-12s %s\n" "$p" "$(pacman -Q $p 2>/dev/null | cut -d' ' -f2 || echo NO)"; done
echo "  ocupación: $(df -h / | awk 'NR==2{print $3}') · paquetes: $(pacman -Q|wc -l)"
echo "══ FIN3 ══"
