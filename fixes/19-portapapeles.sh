#!/bin/bash
#
# 19 · Portapapeles compartido con el anfitrión
#
# Ejecutar DENTRO de la VM:
#   curl -fsSL https://raw.githubusercontent.com/ggalancs/omarchy-arm-utm/main/fixes/19-portapapeles.sh | bash
#
# EL PROBLEMA
#   El portapapeles de SPICE va en tres saltos:
#     cliente SPICE (UTM) <-virtio-> spice-vdagentd <-socket unix-> agente
#   El demonio habla con el anfitrión; el agente de sesión solo habla con el
#   demonio. El agente OFICIAL entrega el portapapeles a X11 (vdagent.c:421) y
#   bajo Hyprland muere con "cannot open display", así que el demonio se queda
#   sin nadie a quien entregar.
#
# LA SOLUCIÓN
#   Sustituir el AGENTE, no el demonio: omarchy-arm-vdagent habla el mismo
#   protocolo con vdagentd y usa wl-copy/wl-paste. Y arrancar el demonio con
#   -X, porque su comprobación de "sesión activa de seat0" falla con Hyprland
#   lanzado por SDDM y descarta el portapapeles en silencio.
#
# REQUISITO
#   En UTM: Ajustes de la VM → Compartir → "Compartir portapapeles" activado,
#   y la VM abierta como ventana (no solo arrancada con utmctl: sin cliente
#   SPICE conectado el canal existe pero no transporta).
#
set -uo pipefail
RAW=https://raw.githubusercontent.com/ggalancs/omarchy-arm-utm/main/provision/src/omarchy-arm-vdagent
SOCK=/run/spice-vdagentd/spice-vdagent-sock

echo "==> requisitos"
fallo=0
for c in python3 wl-copy wl-paste; do
  command -v "$c" >/dev/null 2>&1 && echo "  ✓ $c" || { echo "  ✗ falta $c"; fallo=1; }
done
if [ ! -e /dev/virtio-ports/com.redhat.spice.0 ]; then
  echo "  ✗ no existe /dev/virtio-ports/com.redhat.spice.0"
  echo "    Activa 'Compartir portapapeles' en UTM y apaga/enciende la VM."
  fallo=1
else
  echo "  ✓ canal SPICE presente"
fi
pacman -Q spice-vdagent >/dev/null 2>&1 && echo "  ✓ spice-vdagent instalado" \
  || { echo "  ✗ falta spice-vdagent: sudo pacman -S spice-vdagent"; fallo=1; }
[ "$fallo" -ne 0 ] && { echo; echo "Corrige lo anterior y repite."; exit 1; }

echo
echo "==> agente"
if [ -f /usr/share/omarchy-arm-vdagent ]; then
  sudo install -Dm755 /usr/share/omarchy-arm-vdagent /usr/local/bin/omarchy-arm-vdagent
else
  tmp=$(mktemp)
  curl -fsSL "$RAW" -o "$tmp" || { echo "  ✗ no pude descargarlo"; rm -f "$tmp"; exit 1; }
  python3 -c "import ast,sys;ast.parse(open(sys.argv[1]).read())" "$tmp" \
    || { echo "  ✗ lo descargado no es Python válido"; rm -f "$tmp"; exit 1; }
  sudo install -Dm755 "$tmp" /usr/local/bin/omarchy-arm-vdagent; rm -f "$tmp"
fi
echo "  /usr/local/bin/omarchy-arm-vdagent"

echo
echo "==> demonio con -X"
# Sin -X, vdagentd no encuentra "la sesión activa de seat0" bajo Hyprland y
# descarta el portapapeles sin dar ningún error.
sudo mkdir -p /etc/systemd/system/spice-vdagentd.service.d
printf '[Service]\nExecStart=\nExecStart=/usr/bin/spice-vdagentd -X -x -f\n' \
  | sudo tee /etc/systemd/system/spice-vdagentd.service.d/override.conf >/dev/null
sudo systemctl daemon-reload

echo
echo "==> un solo agente"
# vdagentd desconecta a los dos si ve dos agentes en la misma sesión.
sudo systemctl --global mask spice-vdagent.service 2>/dev/null || true
pkill -x spice-vdagent 2>/dev/null || true
pkill -f omarchy-arm-vdagent 2>/dev/null || true
sleep 1
sudo systemctl restart spice-vdagentd
sleep 3
echo "  spice-vdagentd: $(systemctl is-active spice-vdagentd)"
[ -S "$SOCK" ] && echo "  socket listo" || { echo "  ✗ no hay socket en $SOCK"; exit 1; }

echo
echo "==> servicio de usuario"
mkdir -p ~/.config/systemd/user
cat > ~/.config/systemd/user/omarchy-arm-vdagent.service <<'UNIT'
[Unit]
Description=Portapapeles compartido con el anfitrion (SPICE sobre Wayland)
After=graphical-session.target
PartOf=graphical-session.target
ConditionEnvironment=WAYLAND_DISPLAY

[Service]
Type=simple
ExecStartPre=/bin/sh -c 'for i in 1 2 3 4 5 6 7 8 9 10; do [ -S /run/spice-vdagentd/spice-vdagent-sock ] && exit 0; sleep 2; done; exit 1'
ExecStart=/usr/local/bin/omarchy-arm-vdagent
Restart=on-failure
RestartSec=5

[Install]
WantedBy=graphical-session.target
UNIT
systemctl --user daemon-reload
systemctl --user enable --now omarchy-arm-vdagent.service
sleep 3

echo
if systemctl --user is-active --quiet omarchy-arm-vdagent; then
  echo "  ✓ el portapapeles ya debería funcionar en ambos sentidos."
  echo "    Copia algo en el Mac y pega aquí, o al revés. Solo texto."
else
  echo "  ✗ el agente no arrancó:"
  echo "      systemctl --user status omarchy-arm-vdagent"
  echo "      VDAGENT_DEBUG=1 /usr/local/bin/omarchy-arm-vdagent"
fi
