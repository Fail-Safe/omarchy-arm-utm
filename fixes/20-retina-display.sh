#!/bin/bash
# 20 · Pantalla Retina nítida en UTM
#
# Ejecutar DENTRO de la VM:
#   curl -fsSL https://raw.githubusercontent.com/ggalancs/omarchy-arm-utm/main/fixes/20-retina-display.sh | bash
#
# REQUISITO
#   Apaga la VM, abre sus ajustes en UTM -> Display y activa "Retina Mode".
#   Arráncala, ejecuta este script dentro de la VM y vuelve a reiniciarla.
#
# No se recarga Hyprland aquí: cambiar el modo en caliente bajo virtio-gpu
# deja el escritorio en blanco hasta el siguiente arranque.
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
-- IMPORTANTE: cambiar el modo en caliente rompe el renderizado bajo virgl.
-- Si modificas este archivo, reinicia la VM en vez de recargar Hyprland.
hl.env("GDK_SCALE", "2")
hl.monitor({ output = "Virtual-1", mode = "3840x2160@120", position = "auto", scale = 2 })
LUA

echo "Configuración Retina escrita en $config"
echo "Reinicia la VM para aplicarla; no ejecutes hyprctl reload."
