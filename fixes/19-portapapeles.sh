#!/bin/bash
#
# 19 · Portapapeles compartido con el Mac
#
# Ejecutar DENTRO de la VM:
#   curl -fsSL https://raw.githubusercontent.com/ggalancs/omarchy-arm-utm/main/fixes/19-portapapeles.sh | bash
#
# EL PROBLEMA
#   UTM expone el canal correcto (/dev/virtio-ports/com.redhat.spice.0) y la
#   imagen trae spice-vdagent, pero su portapapeles es X11 puro: vdagent.c:421
#   llama a vdagent_clipboards_new(vdagent_display_get_x11(...)) y en todo su
#   repositorio no hay una sola referencia a wlr-data-control. Bajo Hyprland no
#   tiene con quién hablar, por mucho que el servicio arranque.
#
# LA SOLUCIÓN
#   Un agente que habla el MISMO protocolo por el MISMO puerto, pero al otro
#   lado usa wl-copy/wl-paste. Solo texto.
#
# REQUISITO PREVIO
#   En UTM: Ajustes de la VM → Compartir → "Compartir portapapeles" activado.
#   Si lo acabas de activar, apaga y enciende la VM (no vale reiniciar).
#
set -uo pipefail

RAW=https://raw.githubusercontent.com/ggalancs/omarchy-arm-utm/main/provision/src/omarchy-arm-vdagent
PUERTO=/dev/virtio-ports/com.redhat.spice.0

echo "==> comprobando requisitos"
fallo=0
if [ ! -e "$PUERTO" ]; then
  echo "  ✗ no existe $PUERTO"
  echo "    En UTM: Ajustes de la VM → Compartir → activa 'Compartir portapapeles',"
  echo "    y APAGA Y ENCIENDE la VM (reiniciar desde dentro no basta)."
  fallo=1
else
  echo "  ✓ el puerto del agente existe"
fi
for c in python3 wl-copy wl-paste; do
  if command -v "$c" >/dev/null 2>&1; then echo "  ✓ $c"
  else echo "  ✗ falta $c"; fallo=1; fi
done
[ "$fallo" -ne 0 ] && { echo; echo "Corrige lo anterior y vuelve a ejecutar."; exit 1; }

echo
echo "==> instalando el agente"
if [ -f /usr/share/omarchy-arm-vdagent ]; then
  sudo install -Dm755 /usr/share/omarchy-arm-vdagent /usr/local/bin/omarchy-arm-vdagent
else
  tmp=$(mktemp)
  curl -fsSL "$RAW" -o "$tmp" || { echo "  ✗ no pude descargarlo"; rm -f "$tmp"; exit 1; }
  python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$tmp" \
    || { echo "  ✗ lo descargado no es Python válido"; rm -f "$tmp"; exit 1; }
  sudo install -Dm755 "$tmp" /usr/local/bin/omarchy-arm-vdagent
  rm -f "$tmp"
fi
echo "  /usr/local/bin/omarchy-arm-vdagent"

echo
echo "==> permisos del puerto"
# Pertenece a root:root 0600, así que un servicio de usuario no puede abrirlo.
sudo install -Dm644 /dev/stdin /etc/udev/rules.d/70-omarchy-vdagent.rules <<'UDEV'
SUBSYSTEM=="virtio-ports", ATTR{name}=="com.redhat.spice.0", TAG+="uaccess", MODE="0660"
UDEV
sudo udevadm control --reload-rules 2>/dev/null || true
sudo udevadm trigger --subsystem-match=virtio-ports 2>/dev/null || true
sleep 1
ls -l "$PUERTO" | sed 's/^/  /'

echo
echo "==> spice-vdagentd deja de competir por el puerto"
sudo systemctl disable --now spice-vdagentd.socket  2>/dev/null || true
sudo systemctl disable --now spice-vdagentd.service 2>/dev/null || true
pkill -x spice-vdagent 2>/dev/null || true
echo "  hecho (sigue instalado; solo deja de arrancar solo)"

echo
echo "==> servicio de usuario"
mkdir -p ~/.config/systemd/user
cat > ~/.config/systemd/user/omarchy-arm-vdagent.service <<'UNIT'
[Unit]
Description=Portapapeles compartido con el anfitrion (SPICE vdagent sobre Wayland)
After=graphical-session.target
PartOf=graphical-session.target
ConditionEnvironment=WAYLAND_DISPLAY
ConditionPathExists=/dev/virtio-ports/com.redhat.spice.0

[Service]
Type=simple
ExecStart=/usr/local/bin/omarchy-arm-vdagent
Restart=on-failure
RestartSec=5

[Install]
WantedBy=graphical-session.target
UNIT
systemctl --user daemon-reload
systemctl --user enable --now omarchy-arm-vdagent.service

echo
echo "==> estado"
sleep 2
if systemctl --user is-active --quiet omarchy-arm-vdagent.service; then
  echo "  ✓ el agente está corriendo"
  echo
  echo "  Pruébalo: copia algo en el Mac y pega aquí con ⌥+V, o al revés."
  echo "  Solo texto: ni imágenes ni ficheros."
else
  echo "  ✗ no arrancó. Para ver por qué:"
  echo "      systemctl --user status omarchy-arm-vdagent"
  echo "      VDAGENT_DEBUG=1 /usr/local/bin/omarchy-arm-vdagent"
fi
