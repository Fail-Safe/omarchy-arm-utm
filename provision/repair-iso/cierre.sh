#!/bin/bash
set -uo pipefail
U=omarchy
echo "══ dejar la imagen como recién salida de fábrica ══"
# El arranque de prueba dejó estado: se limpia para que el destinatario
# reciba una imagen virgen, con su propio first-run y su propio machine-id.
rm -f /home/$U/.local/state/omarchy/first-run.log
rm -f /home/$U/.local/state/omarchy/done/first-run-user
rm -rf /home/$U/.local/state/omarchy/notifications/*
rm -rf /home/$U/.config/systemd/user/*.target.wants
rm -rf /home/$U/.cache /home/$U/.bash_history
: > /etc/machine-id
rm -f /var/lib/systemd/random-seed /var/lib/systemd/credential.secret
rm -f /etc/ssh/ssh_host_* 2>/dev/null
journalctl --vacuum-time=1s >/dev/null 2>&1 || true
: > /var/log/wtmp 2>/dev/null || true
: > /var/log/btmp 2>/dev/null || true
echo "══ estado final ══"
printf "  %-26s %s\n" "usuario" "$(getent passwd $U | cut -d: -f1,6)"
printf "  %-26s %s\n" "machine-id" "$(wc -c </etc/machine-id) bytes"
printf "  %-26s %s\n" "claves ssh" "$(ls /etc/ssh/ssh_host_* 2>/dev/null | wc -l)"
printf "  %-26s %s\n" "first-run" "$(test -e /home/$U/.local/state/omarchy/done/first-run-user && echo marcado || echo virgen)"
printf "  %-26s %s\n" "unidades disponibles" "$(ls /usr/lib/systemd/user/*.service 2>/dev/null | wc -l)"
printf "  %-26s %s\n" "comandos en /usr/bin" "$(ls /usr/bin | grep -c '^omarchy-')"
printf "  %-26s %s\n" "enlaces rotos" "$(find /usr/bin -xtype l 2>/dev/null | wc -l)"
printf "  %-26s %s\n" "envoltorio del kernel" "$(test -x /usr/local/bin/omarchy-update-restart && echo sí || echo NO)"
printf "  %-26s %s\n" "ocupación" "$(df -h / | awk 'NR==2{print $3}')"
fstrim / >/dev/null 2>&1 || true
sync
echo "══ FINC ══"
