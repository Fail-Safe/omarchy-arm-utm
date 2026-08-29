#!/bin/bash
#
# omarchy-arm-extras — installs on Arch Linux ARM apps that are not included in the image
#  ───────────────────────────────────────────────────────────────────────────
# Proprietary software is intentionally NOT distributed: packaging it in a
# distributable .zip would redistribute third-party binaries. This script
# downloads each app from its OFFICIAL source, on your machine, at your discretion.
#
# Almost all have an official arm64 build. Those already included in the image
# (free software) are marked as [already installed] and skipped.
#
#  Usage:
#   omarchy-arm-extras                     interactive menu
#   omarchy-arm-extras --list             view what can be installed
#   omarchy-arm-extras 1password obsidian  install specific items
#   omarchy-arm-extras --all              everything that is missing
#   omarchy-arm-extras --force <key>      reinstall even if already installed
#
set -uo pipefail
[ -r /etc/omarchy-arm.conf ] && . /etc/omarchy-arm.conf
: "${OMARCHY_LANG:=en}"

c_ok=$'\033[32m'; c_warn=$'\033[33m'; c_err=$'\033[31m'; c_hi=$'\033[1;36m'; c_dim=$'\033[2m'; c_off=$'\033[0m'
ui_text() { if [[ $OMARCHY_LANG == es ]]; then printf '%s' "${2:-$1}"; else printf '%s' "$1"; fi; }
title() { local text; text=$(ui_text "$1" "${2:-$1}"); echo; echo "${c_hi}━━━ $text ━━━${c_off}"; }
info()  { local text; text=$(ui_text "$1" "${2:-$1}"); echo "  $text"; }
ok()    { local text; text=$(ui_text "$1" "${2:-$1}"); echo "  ${c_ok}✓${c_off} $text"; }
warn()  { local text; text=$(ui_text "$1" "${2:-$1}"); echo "  ${c_warn}!${c_off} $text" >&2; }
fail()  { local text; text=$(ui_text "$1" "${2:-$1}"); echo "  ${c_err}✗${c_off} $text" >&2; }
usage() {
  if [[ $OMARCHY_LANG == es ]]; then
    cat <<'EOF'
omarchy-arm-extras instala en Arch Linux ARM apps que no vienen en la imagen.

Uso:
  omarchy-arm-extras                     menu interactivo
  omarchy-arm-extras --list              ver que se puede instalar
  omarchy-arm-extras 1password obsidian  instalar elementos concretos
  omarchy-arm-extras --all               instalar todo lo que falta
  omarchy-arm-extras --force <clave>     reinstalar aunque ya este instalado
EOF
  else
    cat <<'EOF'
omarchy-arm-extras installs apps not included in the Arch Linux ARM image.

Usage:
  omarchy-arm-extras                     interactive menu
  omarchy-arm-extras --list              show available apps
  omarchy-arm-extras 1password obsidian  install specific items
  omarchy-arm-extras --all               install everything missing
  omarchy-arm-extras --force <key>       reinstall an installed app
EOF
  fi
}

# /tmp is tmpfs and limited by RAM: compiling .NET or OBS there will run
# out of space halfway. Work is done on real disk.
WORK="${XDG_CACHE_HOME:-$HOME/.cache}/omarchy-arm-extras"
OK_LIST=(); KO_LIST=()

# ── catalog ────────────────────────────────────────────────────────────────
#  key|title|English description|Spanish description
CATALOG=(
  "1password|1Password|Password manager. Official AgileBits arm64 tarball|Gestor de contrasenas. Tarball arm64 oficial de AgileBits"
  "1password-cli|1Password CLI|The op command. Official static arm64 binary|El comando op. Binario estatico arm64 oficial"
  "obsidian|Obsidian|Markdown notes. Official arm64 tarball|Notas en markdown. Tarball arm64 oficial"
  "typora|Typora|WYSIWYG Markdown editor. Official arm64 package through AUR|Editor markdown WYSIWYG. Paquete arm64 oficial via AUR"
  "localsend|LocalSend|Send files between devices. Official arm64 build|Enviar ficheros entre dispositivos. Build arm64 oficial"
  "chrome|Google Chrome|Includes Widevine for arm64: enables Spotify and Netflix web|Trae Widevine para arm64: habilita Spotify y Netflix web"
  "zed|Zed Editor|Official Linux arm64 release with Omarchy theme integration|Build oficial Linux arm64 con integracion del tema de Omarchy"
  "spotify-web|Spotify (web app)|open.spotify.com launcher + reassigns SUPER+SHIFT+M|Lanzador de open.spotify.com + reasigna SUPER+SHIFT+M"
  "pinta|Pinta|Image editor. Built with Microsoft's arm64 .NET|Editor de imagenes. Compilado con el .NET arm64 de Microsoft"
  "obs|OBS Studio|Recording and streaming. Built without the browser plugin|Captura y streaming. Compilado sin el plugin de navegador"
)

catalog_keys()  { printf '%s\n' "${CATALOG[@]}" | cut -d'|' -f1; }
catalog_title() { printf '%s\n' "${CATALOG[@]}" | awk -F'|' -v k="$1" '$1==k{print $2}'; }
catalog_desc()  { local field=3; [[ $OMARCHY_LANG == es ]] && field=4; printf '%s\n' "${CATALOG[@]}" | awk -F'|' -v k="$1" -v f="$field" '$1==k{print $f}'; }

# ── utilities ──────────────────────────────────────────────────────────────
have() { command -v "$1" >/dev/null 2>&1; }
: "${CORE_SOURCE_LOCK:=/usr/share/omarchy-arm/core-git-sources.tsv}"
: "${FREE_APP_ARTIFACT_LOCK:=/usr/share/omarchy-arm/free-app-artifacts.tsv}"
: "${OPTIONAL_APP_ARTIFACT_LOCK:=/usr/share/omarchy-arm/optional-app-artifacts.tsv}"

# REVIEWED_FREE_APP_HELPERS_BEGIN
source_lock_record() {
  awk -v key="$1" '$1 == key { print; exit }' "$CORE_SOURCE_LOCK"
}

require_source_pin() { # require_source_pin <key> <exact-url>
  local wanted="$1" expected_url="$2" key url ref commit extra
  read -r key url ref commit extra <<< "$(source_lock_record "$wanted")"
  [[ -z ${extra:-} && $key == "$wanted" && $url == "$expected_url" \
      && $ref =~ ^(HEAD|PINNED|refs/heads/[A-Za-z0-9._/-]+|refs/tags/[A-Za-z0-9._/+:-]+\^\{\})$ \
      && $commit =~ ^[0-9a-f]{40}$ ]] \
    || { fail "missing or invalid reviewed source pin: $wanted" "falta o no es valido el pin revisado: $wanted"; return 1; }
}

artifact_lock_record() {
  awk -v key="$1" '$1 == key { print; exit }' "$FREE_APP_ARTIFACT_LOCK"
}

optional_artifact_lock_record() {
  awk -v key="$1" '$1 == key { print; exit }' "$OPTIONAL_APP_ARTIFACT_LOCK"
}

require_optional_artifact() {
  local wanted="$1" key url digest signer extra
  read -r key url digest signer extra <<< "$(optional_artifact_lock_record "$wanted")"
  [[ -z ${extra:-} && $key == "$wanted" && $digest =~ ^[0-9a-f]{64}$ ]] \
    || { fail "missing or invalid reviewed optional-app artifact: $wanted" "falta o no es valido el artefacto opcional revisado: $wanted"; return 1; }
  case "$wanted" in
    1password-package)
      [[ $url =~ ^https://downloads.1password.com/linux/tar/stable/aarch64/1password-[0-9]+\.[0-9]+\.[0-9]+\.arm64\.tar\.gz$ \
          && $signer == 3FEF9748469ADBE15DA7CA80AC2D62742012EA22 ]] ;;
    obsidian-package)
      [[ $url =~ ^https://github.com/obsidianmd/obsidian-releases/releases/download/v[0-9]+\.[0-9]+\.[0-9]+/obsidian-[0-9]+\.[0-9]+\.[0-9]+-arm64\.tar\.gz$ \
          && $signer == - ]] ;;
    zed-package)
      [[ $url =~ ^https://github.com/zed-industries/zed/releases/download/v[0-9]+\.[0-9]+\.[0-9]+/zed-linux-aarch64\.tar\.gz$ \
          && $signer == - ]] ;;
    *) return 1 ;;
  esac \
    || { fail "missing or invalid reviewed optional-app artifact: $wanted" "falta o no es valido el artefacto opcional revisado: $wanted"; return 1; }
}

require_pinta_artifact() {
  local key url digest signer extra
  read -r key url digest signer extra <<< "$(artifact_lock_record pinta-package)"
  [[ -z ${extra:-} && $key == pinta-package \
      && $url =~ ^https://geo\.mirror\.pkgbuild\.com/extra/os/x86_64/pinta-[0-9][A-Za-z0-9._+-]*-any\.pkg\.tar\.zst$ \
      && $digest =~ ^[0-9a-f]{64}$ && $signer =~ ^[0-9A-F]{40}$ ]] \
    || { fail "missing or invalid reviewed Pinta artifact" "falta o no es valido el artefacto revisado de Pinta"; return 1; }
}

validate_free_app_locks() {
  local item
  (($#)) || return 0
  [[ -r $CORE_SOURCE_LOCK ]] || { fail "missing reviewed Git source lock" "falta el bloqueo revisado de fuentes Git"; return 1; }
  for item in "$@"; do
    case "$item" in
      pinta)
        require_source_pin dotnet-runtime-bin https://aur.archlinux.org/dotnet-core-bin.git || return 1
        [[ -r $FREE_APP_ARTIFACT_LOCK ]] || { fail "missing reviewed artifact lock" "falta el bloqueo revisado de artefactos"; return 1; }
        require_pinta_artifact || return 1 ;;
      obs)
        require_source_pin obs-studio-pkgbuild https://gitlab.archlinux.org/archlinux/packaging/packages/obs-studio.git || return 1
        require_source_pin obs-studio-source https://github.com/obsproject/obs-studio.git || return 1
        require_source_pin obs-libdshowcapture https://github.com/obsproject/libdshowcapture.git || return 1
        require_source_pin obs-browser https://github.com/obsproject/obs-browser.git || return 1
        require_source_pin obs-websocket https://github.com/obsproject/obs-websocket.git || return 1 ;;
    esac
  done
}

validate_optional_app_locks() {
  local item
  (($#)) || return 0
  [[ -r $CORE_SOURCE_LOCK ]] || { fail "missing reviewed Git source lock" "falta el bloqueo revisado de fuentes Git"; return 1; }
  for item in "$@"; do
    case "$item" in
      1password)
        [[ -r $OPTIONAL_APP_ARTIFACT_LOCK ]] || { fail "missing reviewed optional-app artifact lock" "falta el bloqueo revisado de artefactos opcionales"; return 1; }
        require_optional_artifact 1password-package || return 1 ;;
      obsidian)
        [[ -r $OPTIONAL_APP_ARTIFACT_LOCK ]] || { fail "missing reviewed optional-app artifact lock" "falta el bloqueo revisado de artefactos opcionales"; return 1; }
        require_optional_artifact obsidian-package || return 1 ;;
      1password-cli)
        require_source_pin 1password-cli https://aur.archlinux.org/1password-cli.git || return 1 ;;
      typora)
        require_source_pin typora https://aur.archlinux.org/typora.git || return 1 ;;
      localsend)
        require_source_pin localsend-bin https://aur.archlinux.org/localsend-bin.git || return 1 ;;
      chrome)
        require_source_pin google-chrome https://aur.archlinux.org/google-chrome.git || return 1 ;;
      zed)
        [[ -r $OPTIONAL_APP_ARTIFACT_LOCK ]] || { fail "missing reviewed optional-app artifact lock" "falta el bloqueo revisado de artefactos opcionales"; return 1; }
        require_optional_artifact zed-package || return 1
        require_source_pin omazed https://aur.archlinux.org/omazed.git || return 1 ;;
    esac
  done
}

clone_reviewed_source() { # clone_reviewed_source <lock-key> <destination>
  local wanted="$1" dir="$2" key url commit actual
  read -r key url _ commit <<< "$(source_lock_record "$wanted")"
  [[ $key == "$wanted" && $commit =~ ^[0-9a-f]{40}$ ]] || return 1
  rm -rf "$dir"; mkdir -p "$dir"
  git -C "$dir" init -q || return 1
  git -C "$dir" remote add origin "$url" || return 1
  git -C "$dir" -c protocol.version=2 fetch -q --filter=blob:none --depth 1 origin "$commit" \
    || git -C "$dir" fetch -q --depth 1 origin "$commit" \
    || return 1
  git -C "$dir" checkout -q --detach FETCH_HEAD || return 1
  actual=$(git -C "$dir" rev-parse HEAD 2>/dev/null)
  [[ $actual == "$commit" ]] || return 1
  echo "  $(ui_text 'reviewed source' 'fuente revisada'): $wanted ${commit:0:12}"
}

verify_reviewed_artifact() { # verify_reviewed_artifact <package> <signature> <sha256> <signer>
  local package_file="$1" signature_file="$2" digest="$3" signer="$4" signature_status actual_signer
  printf '%s  %s\n' "$digest" "$package_file" | sha256sum -c - >/dev/null \
    || { fail "artifact SHA-256 mismatch" "SHA-256 del artefacto no coincide"; return 1; }
  signature_status=$(gpg --homedir /etc/pacman.d/gnupg --batch --status-fd 1 \
    --verify "$signature_file" "$package_file" 2>/dev/null) \
    || { fail "artifact signature is invalid" "la firma del artefacto no es valida"; return 1; }
  actual_signer=$(printf '%s\n' "$signature_status" | awk '$2 == "VALIDSIG" { print $3; exit }')
  [[ $actual_signer == "$signer" ]] \
    || { fail "artifact signer does not match the reviewed fingerprint" "el firmante no coincide con la huella revisada"; return 1; }
}

verify_reviewed_sha256() { # verify_reviewed_sha256 <file> <sha256>
  printf '%s  %s\n' "$2" "$1" | sha256sum -c - >/dev/null \
    || { fail "artifact SHA-256 mismatch" "SHA-256 del artefacto no coincide"; return 1; }
}

verify_1password_artifact() { # verify_1password_artifact <archive> <signature> <key> <sha256> <fingerprint>
  local archive="$1" signature="$2" key_file="$3" digest="$4" signer="$5"
  local keyring actual_key signature_status actual_signer
  verify_reviewed_sha256 "$archive" "$digest" || return 1
  keyring="$WORK/1password-keyring"
  rm -rf "$keyring"; mkdir -m 0700 "$keyring"
  gpg --homedir "$keyring" --batch --import "$key_file" >/dev/null 2>&1 \
    || { fail "could not import the 1Password signing key" "no se pudo importar la clave de firma de 1Password"; return 1; }
  actual_key=$(gpg --homedir "$keyring" --batch --with-colons --fingerprint \
    | awk -F: '$1 == "fpr" { print $10; exit }')
  [[ $actual_key == "$signer" ]] \
    || { fail "1Password signing-key fingerprint mismatch" "la huella de la clave de 1Password no coincide"; return 1; }
  signature_status=$(gpg --homedir "$keyring" --batch --status-fd 1 \
    --verify "$signature" "$archive" 2>/dev/null) \
    || { fail "1Password artifact signature is invalid" "la firma del artefacto de 1Password no es valida"; return 1; }
  actual_signer=$(printf '%s\n' "$signature_status" | awk '$2 == "VALIDSIG" { print $3; exit }')
  [[ $actual_signer == "$signer" ]] \
    || { fail "1Password signer does not match the reviewed fingerprint" "el firmante de 1Password no coincide con la huella revisada"; return 1; }
}
# REVIEWED_FREE_APP_HELPERS_END

# Pinta and OBS Studio are free software and come within the image; the rest
# do not. Without this check, `--all` would recompile OBS entirely (half an hour) to
# reinstall what is already present.
is_installed() {
  case "$1" in
    1password)     pacman -Q 1password        >/dev/null 2>&1 || [ -d /opt/1Password ] ;;
    1password-cli) have op ;;
    obsidian)      [ -d /opt/obsidian ] ;;
    typora)        pacman -Q typora           >/dev/null 2>&1 ;;
    localsend)     pacman -Q localsend-bin    >/dev/null 2>&1 ;;
    chrome)        pacman -Q google-chrome    >/dev/null 2>&1 || have google-chrome-stable ;;
    zed)           [ -x "$HOME/.local/zed.app/bin/zed" ] ;;
    spotify-web)   grep -q "open.spotify.com" "$HOME/.config/hypr/bindings.lua" 2>/dev/null ;;
    pinta)         pacman -Q pinta            >/dev/null 2>&1 ;;
    obs)           pacman -Q obs-studio       >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

need_sudo() {
  sudo -n true 2>/dev/null && return 0
  info "sudo is required to install packages." "Se necesita sudo para instalar paquetes."
  sudo -v || { fail "no privileges" "sin privilegios"; return 1; }
}

# Builds an AUR package by resolving common pitfalls on ARM:
#  · the clone URL uses the PackageBase, which is not always the name
#  · many PKGBUILDs declare arch=(x86_64) by default, not due to incompatibility
#  · a PKGBUILD can generate multiple subpackages, and only one may have the broken dependency
# REVIEWED_AUR_BUILD_BEGIN
aur_build() {
  # A single `local` expands ALL values before assigning any, so
  # $pkg would not exist when building $dir, and with set -u the script aborts.
  local pkg="$1" want="${2:-$1}" lock_key="${3:-}"
  local dir="$WORK/$pkg" base
  if [[ ${FORCE:-0} != 1 ]] && pacman -Q "$want" >/dev/null 2>&1; then
    ok "$want is already installed" "$want ya instalado"
    return 0
  fi

  [[ -n $lock_key ]] \
    || { fail "AUR build requires a reviewed source pin: $pkg" "la compilacion AUR necesita un pin revisado: $pkg"; return 1; }
  base=$lock_key
  clone_reviewed_source "$lock_key" "$dir" \
    || { fail "could not fetch reviewed source: $lock_key" "no se pudo obtener la fuente revisada: $lock_key"; return 1; }
  [ -f "$dir/PKGBUILD" ] || { fail "could not clone $pkg (base: $base)" "no se pudo clonar $pkg (base: $base)"; return 1; }

  # Several PKGBUILDs verify the upstream signature in check(). If the key is
  # not in the keyring, makepkg aborts. Those declared by the PKGBUILD itself
  # are imported, instead of skipping the verification.
  local keys k
  keys=$(sed -n '/^validpgpkeys=(/,/)/p' "$dir/PKGBUILD" | grep -oE '[0-9A-Fa-f]{40}')
  for k in $keys; do
    [ ${#k} -ge 16 ] || continue
    gpg --list-keys "$k" >/dev/null 2>&1 && continue
    info "importing GPG key ${k: -8}" "importando clave GPG ${k: -8}"
    gpg --keyserver keyserver.ubuntu.com --recv-keys "$k" >/dev/null 2>&1 \
      || gpg --keyserver keys.openpgp.org --recv-keys "$k" >/dev/null 2>&1 \
      || warn "could not import ${k: -8}: signature verification will fail" "no pude importar ${k: -8}: la verificación de firma fallará"
  done

  if ! grep -qE "^arch=\(.*\b(aarch64|any)\b" "$dir/PKGBUILD"; then
    sed -i "s/^arch=(\(.*\))/arch=(\1 'aarch64')/" "$dir/PKGBUILD"
    info "patched arch= to include aarch64" "arch= parcheado para incluir aarch64"
  fi

  if [[ ${FORCE:-0} == 1 ]]; then
    ( cd "$dir" && makepkg -si --noconfirm --noprogressbar ) >"$dir/build.log" 2>&1 && return 0
  else
    ( cd "$dir" && makepkg -si --noconfirm --needed --noprogressbar ) >"$dir/build.log" 2>&1 && return 0
  fi
  fail "$pkg build failed — log: $dir/build.log" "falló la compilación de $pkg — log: $dir/build.log"
  tail -5 "$dir/build.log" | sed 's/^/      /'
  return 1
}
# REVIEWED_AUR_BUILD_END

# ── installers ────────────────────────────────────────────────────────────

do_1password() {
  title "1Password"
  info "AgileBits publishes arm64 ONLY as a tarball; there is no .deb or .rpm for this architecture." "AgileBits publica arm64 SOLO como tarball: no hay .deb ni .rpm para esta arquitectura."
  local key url digest signer archive signature key_file
  read -r key url digest signer <<< "$(optional_artifact_lock_record 1password-package)"
  mkdir -p "$WORK"; rm -rf "$WORK/1p"; mkdir -p "$WORK/1p"
  archive="$WORK/1p/1p.tar.gz"; signature="$archive.sig"; key_file="$WORK/1p/1password.asc"
  curl -fL --progress-bar "$url" -o "$archive" || { fail "download failed" "descarga fallida"; return 1; }
  curl -fsSL --max-time 30 "$url.sig" -o "$signature" \
    || { fail "1Password signature download failed" "fallo la descarga de la firma de 1Password"; return 1; }
  curl -fsSL --max-time 30 https://downloads.1password.com/linux/keys/1password.asc -o "$key_file" \
    || { fail "1Password signing-key download failed" "fallo la descarga de la clave de firma de 1Password"; return 1; }
  verify_1password_artifact "$archive" "$signature" "$key_file" "$digest" "$signer" || return 1
  ok "1Password SHA-256 and GPG signature verified" "SHA-256 y firma GPG de 1Password verificados"
  tar -xzf "$archive" -C "$WORK/1p" || { fail "could not extract the archive" "no se pudo extraer"; return 1; }
  local src; src=$(find "$WORK/1p" -maxdepth 1 -type d -name '1password-*' | head -1)
  [ -n "$src" ] || { fail "the tarball has an unexpected layout" "el tarball no tiene la forma esperada"; return 1; }
  sudo mkdir -p /opt/1Password
  sudo cp -a "$src"/. /opt/1Password/
  ( cd /opt/1Password && sudo ./after-install.sh ) >/dev/null 2>&1 || warn "after-install.sh reported errors (usually harmless)" "after-install.sh dio errores (suele ser inocuo)"
  have 1password && ok "$(1password --version 2>/dev/null | head -1 || ui_text installed instalado)" || { fail "it was not added to PATH" "no quedó en el PATH"; return 1; }
  info "${c_dim}Under Hyprland, launch it with --ozone-platform=wayland${c_off}" "${c_dim}En Hyprland conviene lanzarlo con --ozone-platform=wayland${c_off}"
}

do_1password_cli() { title "1Password CLI"; aur_build 1password-cli 1password-cli 1password-cli && ok "$(op --version 2>/dev/null)"; }

do_obsidian() {
  title "Obsidian"
  info "Official arm64 AppImage and tarball builds exist. The tarball avoids a fuse2 dependency." "Hay AppImage y tarball arm64 oficiales. Se usa el tarball: no depende de fuse2."
  local key url digest signer
  read -r key url digest signer <<< "$(optional_artifact_lock_record obsidian-package)"
  info "$(basename "$url")"
  mkdir -p "$WORK"; curl -fL --progress-bar "$url" -o "$WORK/obsidian.tar.gz" || { fail "download failed" "descarga fallida"; return 1; }
  verify_reviewed_sha256 "$WORK/obsidian.tar.gz" "$digest" || return 1
  sudo rm -rf /opt/obsidian; sudo mkdir -p /opt/obsidian
  sudo tar -xzf "$WORK/obsidian.tar.gz" -C /opt/obsidian --strip-components=1 || { fail "could not extract the archive" "no se pudo extraer"; return 1; }
  sudo ln -sfn /opt/obsidian/obsidian /usr/local/bin/obsidian
  sudo install -Dm644 /dev/stdin /usr/local/share/applications/obsidian.desktop <<'DESK'
[Desktop Entry]
Name=Obsidian
Exec=obsidian --ozone-platform-hint=auto %u
Icon=obsidian
Type=Application
Categories=Office;
MimeType=x-scheme-handler/obsidian;
DESK
  [ -f /opt/obsidian/resources/app.asar ] && sudo find /opt/obsidian -name 'icon.png' -exec \
    sudo install -Dm644 {} /usr/local/share/icons/hicolor/512x512/apps/obsidian.png \; 2>/dev/null
  ok "Obsidian installed at /opt/obsidian ($(basename "$url"))" "Obsidian instalado en /opt/obsidian ($(basename "$url"))"
}

do_typora() {
  title "Typora"
  info "The AUR 'typora' package downloads the official arm64 .deb. Do not use typora-electron; electron42 is unavailable on ARM." "El paquete AUR 'typora' baja el .deb arm64 oficial. No uses typora-electron: pide electron42, que no existe en ARM."
  aur_build typora typora typora && ok "$(pacman -Q typora)"
}

do_localsend() { title "LocalSend"; aur_build localsend-bin localsend-bin localsend-bin && ok "$(pacman -Q localsend-bin)"; }

do_chrome() {
  title "Google Chrome"
  info "Chrome arm64 includes Widevine (required by Spotify and Netflix web)." "Chrome arm64 incluye Widevine (el DRM que exigen Spotify y Netflix web)."
  info "Repository Chromium does NOT include it, and chromium-widevine is x86_64-only." "Chromium de los repos NO lo trae, y el paquete chromium-widevine es solo x86_64."
  aur_build google-chrome google-chrome google-chrome || return 1
  ok "$(pacman -Q google-chrome)"
  info "${c_dim}Check DRM at chrome://components → 'Widevine Content Decryption Module'${c_off}" "${c_dim}Comprueba el DRM en chrome://components → 'Widevine Content Decryption Module'${c_off}"
}

do_zed() {
  title "Zed Editor"
  info "Installing Zed's official Linux arm64 release." "Instalando el build oficial Linux arm64 de Zed."
  local key url digest signer dir archive src desktop_source desktop_target candidate
  read -r key url digest signer <<< "$(optional_artifact_lock_record zed-package)"
  dir="$WORK/zed"
  archive="$dir/zed-linux-aarch64.tar.gz"
  rm -rf "$dir"; mkdir -p "$dir/unpack"
  curl -fL --progress-bar "$url" -o "$archive" || { fail "download failed" "descarga fallida"; return 1; }
  verify_reviewed_sha256 "$archive" "$digest" || return 1
  tar -xzf "$archive" -C "$dir/unpack" || { fail "could not extract the archive" "no se pudo extraer"; return 1; }
  src="$dir/unpack/zed.app"
  [[ -x $src/bin/zed ]] || { fail "the tarball has an unexpected layout" "el tarball no tiene la forma esperada"; return 1; }

  mkdir -p "$HOME/.local/bin" "$HOME/.local/share/applications"
  rm -rf "$HOME/.local/zed.app"
  cp -a "$src" "$HOME/.local/zed.app"
  ln -sfn "$HOME/.local/zed.app/bin/zed" "$HOME/.local/bin/zed"
  ln -sfn "$HOME/.local/zed.app/bin/zed" "$HOME/.local/bin/zeditor"

  desktop_source=""
  for candidate in dev.zed.Zed.desktop zed.desktop; do
    [[ -f $HOME/.local/zed.app/share/applications/$candidate ]] || continue
    desktop_source="$HOME/.local/zed.app/share/applications/$candidate"
    break
  done
  [[ -n $desktop_source ]] || { fail "the Zed desktop entry is missing" "falta la entrada de escritorio de Zed"; return 1; }
  desktop_target="$HOME/.local/share/applications/dev.zed.Zed.desktop"
  sed \
    -e "s|Icon=zed|Icon=$HOME/.local/zed.app/share/icons/hicolor/512x512/apps/zed.png|g" \
    -e "s|Exec=zed|Exec=$HOME/.local/zed.app/bin/zed|g" \
    "$desktop_source" >"$desktop_target" \
    || { fail "could not install the Zed desktop entry" "no se pudo instalar la entrada de escritorio de Zed"; return 1; }
  chmod 644 "$desktop_target"

  if aur_build omazed omazed omazed; then
    omazed setup || warn "Zed installed, but Omarchy theme setup reported an error" "Zed se instalo, pero fallo la configuracion del tema de Omarchy"
  else
    warn "Zed installed, but the optional Omarchy theme helper failed" "Zed se instalo, pero fallo el ayudante opcional del tema de Omarchy"
  fi
  ok "Zed installed from $(basename "$url")" "Zed instalado desde $(basename "$url")"
}

do_spotify_web() {
  title "Spotify (webapp)"
  # Omarchy treats Spotify as a native package, not as a webapp — and that package is
  # x86_64. On ARM, the working method is the web version, which requires Widevine.
  if ! have google-chrome-stable; then
    warn "Spotify web will not play without Google Chrome; install 'chrome' first" "sin Google Chrome la web de Spotify no reproducirá: instala antes 'chrome'"
  fi
  if have omarchy-webapp-install; then
    omarchy-webapp-install "Spotify" "https://open.spotify.com" \
      "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/png/spotify.png" \
      "$(have google-chrome-stable && echo 'google-chrome-stable --app=https://open.spotify.com')" \
      >/dev/null 2>&1 && ok "launcher created in the application menu" "lanzador creado en el menú de aplicaciones"
  else
    warn "omarchy-webapp-install is unavailable" "omarchy-webapp-install no está disponible"
  fi
  # Reassign SUPER+SHIFT+M, which in Omarchy points to the native binary
  local f="$HOME/.config/hypr/bindings.lua"
  if [ -f "$f" ] && ! grep -q "open.spotify.com" "$f"; then
    cat >> "$f" <<'LUA'

-- Spotify has no native aarch64 client: SUPER+SHIFT+M opens the web app.
-- Requires Google Chrome, which provides Widevine on arm64.
o.bind("SUPER + SHIFT + M", "Spotify", o.launch("google-chrome-stable --app=https://open.spotify.com"))
LUA
    ok "SUPER+SHIFT+M reassigned (restart the session to apply it)" "SUPER+SHIFT+M reasignado (reinicia la sesión para aplicarlo)"
  fi
  info "${c_dim}Already-installed terminal alternative: spotify-player${c_off}" "${c_dim}Alternativa en terminal, ya instalada: spotify-player${c_off}"
}

do_pinta() {
  title "Pinta"
  info "Microsoft publishes .NET for linux-arm64; Arch only packages it for x86_64." "Microsoft sí publica .NET para linux-arm64; Arch solo lo empaqueta para x86_64."
  info "The runtime is installed from the official tarball, followed by Pinta's arch=any package." "Se instala el runtime desde el tarball oficial y luego el paquete de Pinta, que es arch=any."
  aur_build dotnet-runtime-bin dotnet-runtime-bin dotnet-runtime-bin || { fail "cannot continue without the .NET runtime" "sin runtime .NET no se puede seguir"; return 1; }
  local key url digest signer file package_file signature_file
  read -r key url digest signer <<< "$(artifact_lock_record pinta-package)"
  file=${url##*/}
  info "$file  ${c_dim}(the path says x86_64, but the package is arch=any)${c_off}" "$file  ${c_dim}(la ruta dice x86_64 pero el paquete es arch=any)${c_off}"
  mkdir -p "$WORK"
  package_file="$WORK/$file"; signature_file="$package_file.sig"
  curl -fL --progress-bar "$url" -o "$package_file" || return 1
  curl -fsSL --max-time 30 "$url.sig" -o "$signature_file" || { fail "Pinta signature download failed" "fallo la descarga de la firma de Pinta"; return 1; }
  verify_reviewed_artifact "$package_file" "$signature_file" "$digest" "$signer" || return 1
  sudo pacman -U --noconfirm "$package_file" >/dev/null 2>&1 && ok "$(pacman -Q pinta)" || { fail "pacman -U failed" "pacman -U falló"; return 1; }
  warn "this is outside the update manager; repeat manually for each version" "queda fuera del gestor de actualizaciones: cada versión hay que repetirla a mano"
}

do_obs() {
  title "OBS Studio"
  info "OBS builds on aarch64. The only Arch Linux ARM blocker is the browser" "OBS compila bien en aarch64. Lo único que lo bloquea en Arch Linux ARM es el"
  info "subpackage, whose 'cef' dependency is x86_64-only. It will be disabled." "subpaquete del navegador, cuyo 'cef' solo existe para x86_64. Se desactiva."
  warn "building Qt6 + OBS inside the VM takes a while" "compilar Qt6 + OBS dentro de la VM lleva un buen rato"
  local dir="$WORK/obs-studio"
  rm -rf "$dir"; mkdir -p "$WORK"
  clone_reviewed_source obs-studio-pkgbuild "$dir" \
    || { fail "could not clone Arch's PKGBUILD" "no pude clonar el PKGBUILD de Arch"; return 1; }
  cd "$dir" || return 1
  local obs_commit dshow_commit browser_commit websocket_commit
  obs_commit=$(source_lock_record obs-studio-source | awk '{ print $4 }')
  dshow_commit=$(source_lock_record obs-libdshowcapture | awk '{ print $4 }')
  browser_commit=$(source_lock_record obs-browser | awk '{ print $4 }')
  websocket_commit=$(source_lock_record obs-websocket | awk '{ print $4 }')
  sed -i 's|#tag=$pkgver|#commit='"$obs_commit"'|' PKGBUILD
  sed -i 's|libdshowcapture.git"|libdshowcapture.git#commit='"$dshow_commit"'"|' PKGBUILD
  sed -i 's|obs-browser.git"|obs-browser.git#commit='"$browser_commit"'"|' PKGBUILD
  sed -i 's|obs-websocket.git"|obs-websocket.git#commit='"$websocket_commit"'"|' PKGBUILD
  sed -i "s/^arch=(\(.*\))/arch=(\1 'aarch64')/" PKGBUILD
  # NOTE: 'cef' goes on the SAME line as makedepends=, not on its own, so
  # it must be removed as a token and not as a complete line.
  sed -i "s/'cef'[[:space:]]*//g" PKGBUILD
  sed -i "/cef_api_versions\.h/d; /-DCEF_API_VERSION/d; /_cef_api_version/d" PKGBUILD
  sed -i 's/-DENABLE_BROWSER=ON/-DENABLE_BROWSER=OFF/' PKGBUILD
  # package_obs-studio() separates the browser plugin files for the
  # separate subpackage. Without browser those files do not exist and the `mv` aborts the
  # packaging AFTER everything has been compiled: those two lines must be removed.
  sed -i '/mv \$pkgdir\/usr\/lib\/obs-plugins\/{obs-browser-page,obs-browser.so}/d' PKGBUILD
  sed -i '/mv \$pkgdir\/usr\/share\/obs\/obs-plugins\/obs-browser /d' PKGBUILD
  # and the plugin patches, which are no longer applied to anything
  sed -i '/patch -d plugins\/obs-browser/d' PKGBUILD
  # DO NOT touch source=() nor sha256sums=(): deleting an entry without the other
  # causes makepkg to abort with "Integrity checks differ in size from the source
  # array". Downloading extra obs-browser is just wasted bandwidth.
  sed -i '/INSTALL_RPATH.*cef/d' PKGBUILD
  # The browser subpackage is no longer generated
  sed -i '/^package_obs-studio-plugin-browser()/,/^}/d' PKGBUILD
  sed -i "s/^pkgname=(.*)/pkgname=('obs-studio')/" PKGBUILD
  if grep -E '^  ".*::git\+https://' PKGBUILD | grep -Evq '#commit=[0-9a-f]{40}"$'; then
    fail "OBS PKGBUILD still contains an unpinned Git source" "el PKGBUILD de OBS aun contiene una fuente Git sin fijar"
    return 1
  fi
  info "PKGBUILD patched: aarch64, no CEF, no browser plugin" "PKGBUILD parcheado: aarch64, sin CEF, sin plugin de navegador"
  if makepkg -si --noconfirm --needed --noprogressbar >"$dir/build.log" 2>&1; then
    ok "$(pacman -Q obs-studio)"
    info "${c_dim}No hardware acceleration in the VM: encoding will use CPU x264${c_off}" "${c_dim}Sin aceleración por hardware en la VM: codificará con x264 por CPU${c_off}"
  else
    fail "build failed — log: $dir/build.log" "falló la compilación — log: $dir/build.log"
    tail -6 "$dir/build.log" | sed 's/^/      /'
    return 1
  fi
}

run_item() {
  local k="$1"
  if [ "${FORCE:-0}" != "1" ] && is_installed "$k"; then
    title "$(catalog_title "$k")"
    ok "already included in this image (use --force to reinstall)" "ya viene instalada en esta imagen (--force para reinstalar)"
    return 0
  fi
  case "$k" in
    1password)     do_1password ;;
    1password-cli) do_1password_cli ;;
    obsidian)      do_obsidian ;;
    typora)        do_typora ;;
    localsend)     do_localsend ;;
    chrome)        do_chrome ;;
    zed)           do_zed ;;
    spotify-web)   do_spotify_web ;;
    pinta)         do_pinta ;;
    obs)           do_obs ;;
    *) fail "unknown key '$k'" "no conozco '$k'"; return 1 ;;
  esac
}

show_list() {
  echo
  echo "${c_hi}$(ui_text 'Apps installed from their official source' 'Apps que se instalan desde su fuente oficial')${c_off}"
  echo "${c_dim}$(ui_text 'Proprietary apps are intentionally excluded: redistributing their binaries' 'Las propietarias no vienen dentro a proposito: redistribuir sus binarios')"
  echo "$(ui_text 'inside a shared image would be problematic. This tool downloads them' 'en una imagen que se reparte seria problematico. Aqui se descargan en tu')"
  echo "$(ui_text 'to your machine directly from the vendor.' 'maquina, del sitio del fabricante.')${c_off}"
  echo
  local k
  while read -r k; do
    if is_installed "$k"; then
      printf "  ${c_hi}%-15s${c_off} %s ${c_dim}[%s]${c_off}\n" "$k" "$(catalog_desc "$k")" "$(ui_text 'already installed' 'ya instalada')"
    else
      printf "  ${c_hi}%-15s${c_off} %s\n" "$k" "$(catalog_desc "$k")"
    fi
  done < <(catalog_keys)
  echo
  echo "${c_dim}$(ui_text 'Usage: omarchy-arm-extras <key> [key...]   ·   --all for everything' 'Uso: omarchy-arm-extras <clave> [clave...]   ·   --all para todo')${c_off}"
  echo
}

# ── main ────────────────────────────────────────────────────────────────────
SELECTED=()
FORCE=0
if [ "${1:-}" = "--force" ] || [ "${1:-}" = "-f" ]; then FORCE=1; shift; fi
case "${1:-}" in
  --list|-l) show_list; exit 0 ;;
  --all|-a)  mapfile -t SELECTED < <(catalog_keys) ;;
  -h|--help) usage; exit 0 ;;
  "")
    if have gum; then
      show_list
      mapfile -t SELECTED < <(
        while read -r k; do printf '%s — %s\n' "$k" "$(catalog_title "$k")"; done < <(catalog_keys) \
        | gum choose --no-limit --header "$(ui_text 'Select what to install (space selects, Enter confirms)' 'Selecciona qué instalar (espacio marca, enter confirma)')" \
        | cut -d' ' -f1
      )
    else
      show_list; exit 0
    fi ;;
  *) SELECTED=("$@") ;;
esac

[ ${#SELECTED[@]} -gt 0 ] || { info "nothing selected" "nada seleccionado"; exit 0; }

LOCKED_SELECTED=()
OPTIONAL_LOCKED_SELECTED=()
for k in "${SELECTED[@]}"; do
  case "$k" in
    pinta|obs)
      if [ "$FORCE" = 1 ] || ! is_installed "$k"; then LOCKED_SELECTED+=("$k"); fi ;;
    1password|1password-cli|obsidian|typora|localsend|chrome|zed)
      if [ "$FORCE" = 1 ] || ! is_installed "$k"; then OPTIONAL_LOCKED_SELECTED+=("$k"); fi ;;
    spotify-web) ;;
    *) fail "unknown key '$k'" "no conozco '$k'"; exit 1 ;;
  esac
done
if [ ${#LOCKED_SELECTED[@]} -gt 0 ]; then
  validate_free_app_locks "${LOCKED_SELECTED[@]}" || exit 1
fi
if [ ${#OPTIONAL_LOCKED_SELECTED[@]} -gt 0 ]; then
  validate_optional_app_locks "${OPTIONAL_LOCKED_SELECTED[@]}" || exit 1
fi

need_sudo || exit 1
mkdir -p "$WORK"

for k in "${SELECTED[@]}"; do
  [ -z "$k" ] && continue
  if run_item "$k"; then OK_LIST+=("$k"); else KO_LIST+=("$k"); fi
done

title "Summary" "Resumen"
[ ${#OK_LIST[@]} -gt 0 ] && ok "installed: ${OK_LIST[*]}" "instalado: ${OK_LIST[*]}"
if [ ${#KO_LIST[@]} -gt 0 ]; then
  fail "failed: ${KO_LIST[*]}" "falló: ${KO_LIST[*]}"
  # The working directory is not deleted: inside are the build.log files, which are
  # The only thing it allows us to determine is why it failed.
  info "logs at $WORK/<package>/build.log" "logs en $WORK/<paquete>/build.log"
  exit 1
else
  rm -rf "$WORK"
fi
echo
