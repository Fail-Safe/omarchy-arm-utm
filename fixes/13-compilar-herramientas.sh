#!/bin/bash
# Compila para aarch64 las herramientas de Omarchy que no se publican para ARM.
# Casi ninguna es incompatible: la mayoria son Rust, Go o Qt/C++ y solo les falta
# que alguien las construya. Varias declaran arch=(x86_64) por omision.
set -uo pipefail
export PATH=/usr/local/bin:$PATH
export MAKEFLAGS="-j$(nproc)"
WORK=/tmp/omabuild
OK=(); KO=()
log()  { echo ""; echo "==> $*"; }
note() { echo "    $*"; }

build() {                      # build <origen> <paquete>
  # Un unico `local` expande todo antes de asignar: $pkg no existiria aun.
  local src="$1" pkg="$2"
  local dir="$WORK/$pkg"
  log "$pkg  ($src)"
  rm -rf "$dir"; mkdir -p "$dir"

  case "$src" in
    aur)
      # Las URL de clonado de AUR usan el PackageBase, que no siempre coincide con
      # el nombre del paquete (yaru-icon-theme vive en el repo "yaru").
      local base
      base=$(curl -fsSL --max-time 20 "https://aur.archlinux.org/rpc/v5/info?arg[]=$pkg" \
             | sed -n 's/.*"PackageBase":"\([^"]*\)".*/\1/p' | head -1)
      [ -n "$base" ] || base="$pkg"
      git clone -q "https://aur.archlinux.org/$base.git" "$dir" 2>/dev/null
      [ -f "$dir/PKGBUILD" ] || { KO+=("$pkg:clon vacio"); note "FALLO: el clon de AUR ($base) no trae PKGBUILD"; return 1; } ;;
    omapkgs)
      # Solo el subdirectorio del paquete, con sparse checkout
      git clone --depth 1 --filter=blob:none --sparse -q \
        https://github.com/omacom-io/omarchy-pkgs.git "$dir/repo" || { KO+=("$pkg:clone"); return 1; }
      ( cd "$dir/repo" && git sparse-checkout set "pkgbuilds/$pkg" >/dev/null 2>&1 )
      cp -a "$dir/repo/pkgbuilds/$pkg/." "$dir/" 2>/dev/null || { KO+=("$pkg:sparse"); return 1; }
      rm -rf "$dir/repo" ;;
  esac
  [ -f "$dir/PKGBUILD" ] || { KO+=("$pkg:sin PKGBUILD"); note "FALLO: no hay PKGBUILD"; return 1; }

  # Muchos PKGBUILD listan solo x86_64 porque nadie los ha compilado para ARM.
  # Si el codigo es portable (Rust/Go/C++), basta con declarar la arquitectura.
  # 'any' puede venir sin comillas; mezclarlo con arquitecturas concretas es un
  # error de makepkg, asi que solo se parchea cuando NO es 'any' y NO trae ya aarch64.
  if ! grep -qE "^arch=\(.*\b(aarch64|any)\b" "$dir/PKGBUILD"; then
    sed -i "s/^arch=(\(.*\))/arch=(\1 'aarch64')/" "$dir/PKGBUILD"
    note "arch= parcheado para incluir aarch64"
  fi
  note "$(grep -m1 '^pkgver=' "$dir/PKGBUILD")  $(grep -m1 '^arch=' "$dir/PKGBUILD")"

  if ( cd "$dir" && makepkg -si --noconfirm --needed --noprogressbar ) >"$dir/build.log" 2>&1; then
    OK+=("$pkg"); note "OK  $(pacman -Q "$pkg" 2>/dev/null || echo instalado)"
  else
    KO+=("$pkg:makepkg")
    note "FALLO — ultimas lineas:"; tail -6 "$dir/build.log" | sed 's/^/      /'
  fi
}

rm -f /tmp/tools.done
mkdir -p "$WORK"

log "########## 1. datos y scripts (rapidos) ##########"
build aur     yaru-icon-theme
build aur     ttf-ia-writer
build aur     tzupdate
build aur     ufw-docker
build omapkgs omarchy-nvim
build omapkgs tobi-try
build aur     mise-bin

log "########## 2. Go ##########"
build aur aether
build aur cliamp

log "########## 3. Qt / C++ ##########"
build omapkgs omacalc
build omapkgs omacut
build omapkgs omawrite

log "########## 4. Rust (lento) ##########"
build aur herdr
build omapkgs tensaku
build omapkgs hyprland-preview-share-picker

log "RESUMEN"
echo "  compilados (${#OK[@]}): ${OK[*]:-ninguno}"
echo "  fallidos   (${#KO[@]}): ${KO[*]:-ninguno}"
echo ""
echo "  binarios disponibles ahora:"
for b in omacalc omacut omawrite aether cliamp herdr tensaku ttfx tzupdate mise try; do
  printf "    %-12s %s\n" "$b" "$(command -v $b 2>/dev/null || echo '-')"
done
rm -rf "$WORK"
echo ""
echo "==> BUILD_TOOLS_DONE"
touch /tmp/tools.done
