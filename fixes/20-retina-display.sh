#!/bin/bash
# 20 · Pantalla Retina nítida en UTM
#
# Ejecutar DENTRO de la VM:
#   curl -fsSL https://raw.githubusercontent.com/ggalancs/omarchy-arm-utm/main/fixes/20-retina-display.sh | bash
#
# REQUISITO
#   Apaga la VM, abre sus ajustes en UTM -> Display y activa "Retina Mode".
#   Arráncala y ejecuta este script dentro de la VM.
#
# Al escribir monitors.lua, Hyprland recarga la configuración automáticamente;
# no hace falta reiniciar la VM ni ejecutar hyprctl reload a mano.
set -euo pipefail

config="$HOME/.config/hypr/monitors.lua"
mkdir -p "$(dirname "$config")"

if [ -f "$config" ]; then
  backup="$config.bak.$(date +%Y%m%d%H%M%S)"
  cp -a "$config" "$backup"
  echo "Copia de seguridad: $backup"
fi

cat > "$config" <<'LUA'
-- See https://wiki.hypr.land/Configuring/Basics/Monitors/
-- Modos disponibles: hyprctl monitors all
--
-- UTM/QEMU con virtio-gpu y "Retina Mode" activado. El framebuffer 4K con
-- escala 2 da un escritorio logico de 1920x1080 y texto nitido en macOS.
-- Se fija el modo porque "preferred" negocia 1280x800 y reduce la ventana UTM.
--
-- Hyprland aplica los cambios al guardar este archivo. Comprobado con UTM
-- 5.0.4 beta: no hace falta reiniciar la VM ni ejecutar hyprctl reload a mano.
-- 3840x2160@120 tambien funciono con un panel de 120 Hz, pero 60 Hz es el
-- valor compatible y de menor coste que se aplica por defecto.
hl.env("GDK_SCALE", "2")
hl.monitor({ output = "Virtual-1", mode = "3840x2160@60", position = "auto", scale = 2 })
LUA

echo "Configuración Retina escrita en $config"
echo "Hyprland debería aplicarla inmediatamente."
