#!/bin/bash
set -uo pipefail
echo "==> ocupacion total"
df -h / | tail -1
echo
echo "==> los 25 paquetes mas grandes"
expac -H M '%m\t%n' 2>/dev/null | sort -rh | head -25 | sed 's/^/  /'
echo
echo "==> suma por grupos"
tot() { local s=0 p; for p in "$@"; do s=$((s + $(expac '%m' "$p" 2>/dev/null || echo 0))); done; echo $((s/1024/1024)); }
printf "  %-28s %s MiB\n" "OBS Studio + deps"   "$(tot obs-studio ffmpeg x264 x265 svt-av1 libvpx qt6-multimedia qt6-svg luajit)"
printf "  %-28s %s MiB\n" "Pinta + .NET runtime" "$(tot pinta dotnet-runtime-bin dotnet-host)"
printf "  %-28s %s MiB\n" "fuentes Noto CJK"     "$(tot noto-fonts-cjk)"
printf "  %-28s %s MiB\n" "resto de fuentes"     "$(tot noto-fonts noto-fonts-emoji ttf-jetbrains-mono-nerd ttf-ia-writer terminus-font woff2-font-awesome)"
printf "  %-28s %s MiB\n" "kernel + firmware"    "$(tot linux-aarch64 linux-firmware)"
printf "  %-28s %s MiB\n" "cadena de compilacion" "$(tot base-devel gcc go rust nodejs npm cmake ninja meson clang llvm)"
printf "  %-28s %s MiB\n" "chromium"             "$(tot chromium)"
printf "  %-28s %s MiB\n" "neovim + lazyvim"     "$(tot neovim)"
printf "  %-28s %s MiB\n" "docker"               "$(tot docker docker-buildx docker-compose)"
echo
echo "==> directorios mas pesados"
du -shx /usr /var /home /opt 2>/dev/null | sort -rh | sed 's/^/  /'
du -shx /usr/lib /usr/share /usr/bin /usr/include 2>/dev/null | sort -rh | head -5 | sed 's/^/  /'
echo
echo "==> candidatos a recorte"
printf "  %-34s %s\n" "/usr/share/doc" "$(du -shx /usr/share/doc 2>/dev/null | cut -f1)"
printf "  %-34s %s\n" "/usr/share/man" "$(du -shx /usr/share/man 2>/dev/null | cut -f1)"
printf "  %-34s %s\n" "/usr/share/locale" "$(du -shx /usr/share/locale 2>/dev/null | cut -f1)"
printf "  %-34s %s\n" "/usr/include (cabeceras)" "$(du -shx /usr/include 2>/dev/null | cut -f1)"
printf "  %-34s %s\n" "/usr/lib/*.a (estaticas)" "$(find /usr/lib -name '*.a' -exec du -ch {} + 2>/dev/null | tail -1 | cut -f1)"
printf "  %-34s %s\n" "/usr/share/omarchy (.git)" "$(du -shx /usr/share/omarchy/.git 2>/dev/null | cut -f1)"
printf "  %-34s %s\n" "paquetes instalados" "$(pacman -Q | wc -l)"
echo "==> PESO_OK"
