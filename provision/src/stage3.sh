#!/bin/bash
# Stage 3 — as a normal user inside the chroot.
# Omarchy dotfiles, theme, and the components that exist only in the AUR.
set -uo pipefail   # no -e: this stage is best-effort in sections
# shellcheck disable=SC1090 # Generated per-build configuration in the guest home.
. ~/config.env

ui_text() { if [[ ${OMARCHY_LANG:-en} == es ]]; then printf '%s' "${2:-$1}"; else printf '%s' "$1"; fi; }
log()  { local text; text=$(ui_text "$1" "${2:-$1}"); echo ""; echo "==> [stage3] $text"; }
warn() { local text; text=$(ui_text "$1" "${2:-$1}"); echo "!!  [stage3] $text"; }

SOURCE_LOCK=/usr/share/omarchy-arm/core-git-sources.tsv
CORE_SOURCE_KEYS=(omarchy omarchy-pkgs ttfx yay xdg-terminal-exec yaru-icon-theme
                  ttf-ia-writer tzupdate ufw-docker mise-bin aether cliamp
                  dotnet-runtime-bin obs-studio-pkgbuild obs-studio-source
                  obs-libdshowcapture obs-browser obs-websocket)

# CORE_SOURCE_LOCK_HELPERS_BEGIN
source_lock_record() {
  awk -v key="$1" '$1 == key { print; exit }' "$SOURCE_LOCK"
}

validate_core_source_lock() {
  local line key url ref commit extra expected seen=" "
  [[ -s $SOURCE_LOCK ]] || { warn "missing core Git source lock: $SOURCE_LOCK"; return 1; }
  while IFS= read -r line || [[ -n $line ]]; do
    [[ -z $line || $line == \#* ]] && continue
    read -r key url ref commit extra <<< "$line"
    [[ -z ${extra:-} && $key =~ ^[a-z0-9][a-z0-9._+-]*$ && $url == https://* \
        && $ref =~ ^(HEAD|PINNED|refs/heads/[A-Za-z0-9._/-]+|refs/tags/[A-Za-z0-9._/+:-]+\^\{\})$ \
        && $commit =~ ^[0-9a-f]{40}$ ]] \
      || { warn "invalid core Git source-lock record: $line"; return 1; }
    [[ $seen != *" $key "* ]] || { warn "duplicate core Git source-lock key: $key"; return 1; }
    seen="$seen$key "
  done < "$SOURCE_LOCK"
  for expected in "${CORE_SOURCE_KEYS[@]}"; do
    [[ $seen == *" $expected "* ]] || { warn "missing core Git source-lock key: $expected"; return 1; }
  done
  read -r key url ref commit <<< "$(source_lock_record omarchy)"
  [[ $url == https://github.com/basecamp/omarchy.git && $ref == "refs/heads/${OMARCHY_REF:-quattro}" ]] \
    || { warn "the Omarchy source lock is incompatible with OMARCHY_REF='${OMARCHY_REF:-quattro}'"; return 1; }
}

clone_pinned() { # clone_pinned <lock-key> <destination> [sparse-path]
  local key="$1" dir="$2" sparse="${3:-}" record url ref commit actual
  record=$(source_lock_record "$key") || return 1
  read -r key url ref commit <<< "$record"
  [[ -n $commit ]] || { warn "missing source pin: $1"; return 1; }
  rm -rf "$dir"
  mkdir -p "$dir"
  git -C "$dir" init -q || return 1
  git -C "$dir" remote add origin "$url" || return 1
  if [[ -n $sparse ]]; then
    git -C "$dir" sparse-checkout init --cone >/dev/null 2>&1 || return 1
    git -C "$dir" sparse-checkout set "$sparse" >/dev/null 2>&1 || return 1
  fi
  git -C "$dir" -c protocol.version=2 fetch -q --filter=blob:none --depth 1 origin "$commit" \
    || git -C "$dir" fetch -q --depth 1 origin "$commit" \
    || { warn "could not fetch pinned $key commit $commit"; return 1; }
  git -C "$dir" checkout -q --detach FETCH_HEAD || return 1
  actual=$(git -C "$dir" rev-parse HEAD 2>/dev/null)
  [[ $actual == "$commit" ]] || { warn "$key checked out $actual instead of $commit"; return 1; }
  echo "  pinned $key ${commit:0:12}"
}

track_locked_branch() { # preserve Omarchy's normal post-install fast-forward updates
  local key="$1" dir="$2" record url ref commit branch
  record=$(source_lock_record "$key") || return 1
  read -r key url ref commit <<< "$record"
  [[ $ref == refs/heads/* ]] || return 1
  branch=${ref#refs/heads/}
  git -C "$dir" fetch -q origin "$ref:refs/remotes/origin/$branch" || return 1
  git -C "$dir" merge-base --is-ancestor "$commit" "refs/remotes/origin/$branch" \
    || { warn "$key commit $commit is not on $ref"; return 1; }
  git -C "$dir" checkout -q -B "$branch" "$commit" || return 1
  git -C "$dir" config "branch.$branch.remote" origin
  git -C "$dir" config "branch.$branch.merge" "$ref"
}
# CORE_SOURCE_LOCK_HELPERS_END

# Fail the whole stage before any source is fetched, built, or installed. Optional
# builds may still fail independently later, but they never fall back to a moving ref.
validate_core_source_lock || exit 1

export OMARCHY_PATH="$HOME/.local/share/omarchy"
export OMARCHY_INSTALL="$OMARCHY_PATH/install"
export PATH="$OMARCHY_PATH/bin:$PATH:$HOME/.local/bin"
export OMARCHY_CHROOT_INSTALL=1

# ------------------------------------------------------------ Omarchy repository
log "fetching reviewed Omarchy source (${OMARCHY_REF:-quattro} compatibility line)" "obteniendo fuente revisada de Omarchy (linea compatible ${OMARCHY_REF:-quattro})"
mkdir -p "$(dirname "$OMARCHY_PATH")"
clone_pinned omarchy "$OMARCHY_PATH" || { warn "Omarchy pinned clone failed" "fallo el clone fijado de Omarchy"; exit 1; }
track_locked_branch omarchy "$OMARCHY_PATH" || { warn "could not configure Omarchy update branch" "no se pudo configurar la rama de actualizacion de Omarchy"; exit 1; }
# core.fileMode=false BEFORE chmod: otherwise, permission changes leave the
# checkout dirty and `git pull --ff-only` refuses to update it afterwards.
git -C "$OMARCHY_PATH" config core.fileMode false
find "$OMARCHY_PATH/bin" -type f -exec chmod +x {} \; 2>/dev/null
echo "  version: $(cat "$OMARCHY_PATH/version" 2>/dev/null)"

# ------------------------------------------------------------ dotfiles
# Equivalente a install/config/config.sh
log "copying dotfiles to ~/.config" "copiando dotfiles a ~/.config"
mkdir -p ~/.config
cp -R "$OMARCHY_PATH"/config/* ~/.config/
cp "$OMARCHY_PATH/default/bashrc" ~/.bashrc
ls ~/.config | tr '\n' ' '; echo

# ------------------------------------------------------------ AUR
log "AUR: Omarchy components missing from Arch Linux ARM repositories" "AUR: piezas de Omarchy que no están en los repos de Arch Linux ARM"
mkdir -p /tmp/aur
aur_install() {
  local p="$1"
  echo "  --- $p"
  rm -rf "/tmp/aur/$p"
  clone_pinned "$p" "/tmp/aur/$p" || { warn "clone $p"; return 1; }
  ( cd "/tmp/aur/$p" && makepkg -si --noconfirm --needed --noprogressbar ) >"/tmp/aur/$p.log" 2>&1 \
    || { warn "makepkg $p failed (log: /tmp/aur/$p.log)" "makepkg $p falló (log: /tmp/aur/$p.log)"; tail -15 "/tmp/aur/$p.log"; return 1; }
  echo "  ok: $p"
}

AUR_OK=(); AUR_KO=()
# xdg-terminal-exec resolves $TERMINAL. walker and elephant are NOT installed:
# quattro retires them (see bin/omarchy-upgrade-to-quattro), the launcher and the
# menu are quickshell panels (`omarchy-shell shell toggle omarchy.menu`).
for p in yay xdg-terminal-exec; do
  if aur_install "$p"; then AUR_OK+=("$p"); else AUR_KO+=("$p"); fi
done
echo "  AUR ok:     ${AUR_OK[*]:-$(ui_text 'none' 'ninguno')}"
echo "  $(ui_text 'AUR failed' 'AUR falló'): ${AUR_KO[*]:-$(ui_text 'none' 'ninguno')}"

# Fallback if xdg-terminal-exec failed to compile: Omarchy uses $TERMINAL=xdg-terminal-exec
if ! command -v xdg-terminal-exec >/dev/null 2>&1; then
  warn "xdg-terminal-exec is missing: installing a terminal wrapper" "xdg-terminal-exec ausente: instalando un envoltorio sobre alacritty"
  sudo install -m 0755 /dev/stdin /usr/local/bin/xdg-terminal-exec <<'EOF'
#!/bin/sh
# Minimal wrapper: Omarchy exports TERMINAL=xdg-terminal-exec.
# The fallback is foot, which is included in quattro's omarchy-base.packages
# (alacritty is not: pointing there left $TERMINAL broken).
T=$(command -v foot || command -v alacritty || command -v xterm) || exit 127
if [ "$#" -eq 0 ]; then exec "$T"; fi
exec "$T" -e "$@"
EOF
fi

# Default terminal: Omarchy prefers ghostty, which does not exist for aarch64.
# The fallback is foot, which IS included in quattro's omarchy-base.packages (and
# alacritty is NOT: it is not in that list nor in the infrastructure list. Naming
# Alacritty.desktop here pointed to a .desktop file that does not exist in the image, and
# xdg-terminal-exec ended up choosing a fallback. Entries are listed by preference
# and only those that are actually installed.
: > ~/.config/xdg-terminals.list
# Literal names, without ${t^}: that is bash 4 and although bash 5 is present here,
# it is not worth leaving a bash-4-ism in a payload that is also read in a
# Mac with bash 3.2.
for f in com.mitchellh.ghostty.desktop ghostty.desktop \
         foot.desktop Alacritty.desktop alacritty.desktop xterm.desktop; do
  for d in /usr/share/applications /usr/local/share/applications "$HOME/.local/share/applications"; do
    [ -f "$d/$f" ] && { echo "$f" >> ~/.config/xdg-terminals.list; break; }
  done
done
[ -s ~/.config/xdg-terminals.list ] || printf 'foot.desktop\n' > ~/.config/xdg-terminals.list
echo "  $(ui_text 'preferred terminal' 'terminal preferido'): $(head -1 ~/.config/xdg-terminals.list)"

# ------------------------------------------------ system integration
# Omarchy 4 is distributed as a pacman package that places the tree in
# /usr/share/omarchy, binaries in the system PATH, and hooks in
# /etc/profile.d and /usr/share/uwsm/env.d. This package only exists for x86_64,
# so it is manually replicated here. Without this, OMARCHY_PATH remains empty and Hyprland
# starts in emergency mode because it cannot find default/hypr/bootstrap.lua.
log "integrating Omarchy into system paths (replaces the pacman package)" "integrando Omarchy en las rutas de sistema (sustituye al paquete pacman)"
sudo ln -sfn "$OMARCHY_PATH" /usr/share/omarchy
# Commands go to /usr/bin, which is where the upstream package() places them.
# Placing them in /usr/local/bin seemed cleaner (does not conflict with pacman) but
# breaks things: the tree has 13 hardcoded /usr/bin/omarchy-* paths, five of
# which are in .service files. enable-user-units.sh failed because of this, and since
# first-run is only marked as done if NO step fails, it repeated on every login
# perpetually showing the "Update System" notification.
# Verified: none of the 433 names collide with any ALARM package.
sudo mkdir -p /usr/bin
# The symlinks point to /usr/share/omarchy, NOT to $OMARCHY_PATH. Here they are the
# same thing (the first is a symlink to the second), but the sanitizer
# converts /usr/share/omarchy into a real directory and renames it for the user: a
# symlink to /home/<builder>/... becomes dangling and takes the 433
# commands with it. /usr/share/omarchy is the only stable path of the two.
n=0
for f in "$OMARCHY_PATH"/bin/*; do
  [ -f "$f" ] || continue
  chmod +x "$f"
  sudo ln -sfn "/usr/share/omarchy/bin/$(basename "$f")" "/usr/bin/$(basename "$f")" && n=$((n+1))
done
echo "  $n $(ui_text 'binaries' 'binarios') in /usr/bin -> /usr/share/omarchy/bin"
# User units go to /usr/lib/systemd/user/, which is where systemd looks for them.
# The omarchy-settings package installs them upstream, but it does not exist for ARM.
# Without this, install/user/first-run/enable-user-units.sh fails on every login, and
# since omarchy-provision-first-run is only marked as done if NO step fails, the
# first-run repeats indefinitely, resending the "Update System" notification.
# Source: docs/file-layout.md, "systemd/user/*.service → /usr/lib/systemd/user/".
if [ -d "$OMARCHY_PATH/default/systemd/user" ]; then
  sudo install -d /usr/lib/systemd/user
  sudo cp -a "$OMARCHY_PATH/default/systemd/user/." /usr/lib/systemd/user/
  echo "  $(ls "$OMARCHY_PATH/default/systemd/user"/*.service 2>/dev/null | wc -l) $(ui_text 'user units' 'unidades de usuario') in /usr/lib/systemd/user"
fi
for d in system-sleep zram-generator.conf.d; do
  [ -d "$OMARCHY_PATH/default/systemd/$d" ] && \
    sudo cp -a "$OMARCHY_PATH/default/systemd/$d" /usr/lib/systemd/ 2>/dev/null || true
done
sudo install -Dm644 "$OMARCHY_PATH/etc/profile.d/omarchy.sh" /etc/profile.d/omarchy.sh
sudo install -Dm644 "$OMARCHY_PATH/default/uwsm/env.d/10-omarchy" /usr/share/uwsm/env.d/10-omarchy
sudo cp -a "$OMARCHY_PATH/etc/sysctl.d/." /etc/sysctl.d/ 2>/dev/null || true
sudo cp -a "$OMARCHY_PATH/etc/security/." /etc/security/ 2>/dev/null || true
for d in system.conf.d user.conf.d logind.conf.d oomd.conf.d; do
  [ -d "$OMARCHY_PATH/etc/systemd/$d" ] && sudo cp -a "$OMARCHY_PATH/etc/systemd/$d" /etc/systemd/ 2>/dev/null || true
done
[ -d "$OMARCHY_PATH/etc/fastfetch" ] && sudo cp -a "$OMARCHY_PATH/etc/fastfetch" /etc/ 2>/dev/null || true
[ -d "$OMARCHY_PATH/etc/gnupg" ] && sudo cp -a "$OMARCHY_PATH/etc/gnupg/." /etc/gnupg/ 2>/dev/null || true
# systemd-oomd is configured in etc/systemd/oomd.conf.d but it must be
# enabled; NetworkManager-wait-online delays boot without providing any
# benefit in a VM with user-mode networking.
sudo systemctl enable systemd-oomd.service 2>/dev/null || true
sudo systemctl mask NetworkManager-wait-online.service 2>/dev/null || true
# gnome-keyring in SDDM's PAM configuration blocks autologin without a configured keyring
for pf in /etc/pam.d/sddm /etc/pam.d/sddm-autologin /etc/pam.d/sddm-greeter; do
  [ -f "$pf" ] && sudo sed -i '/-auth.*pam_gnome_keyring\.so/d;/-password.*pam_gnome_keyring\.so/d' "$pf"
done

log "SDDM: Omarchy theme and session" "SDDM: tema Omarchy y sesion"
sudo mkdir -p /usr/share/sddm/themes /usr/local/share/wayland-sessions
sudo cp -a "$OMARCHY_PATH/default/sddm/omarchy" /usr/share/sddm/themes/ 2>/dev/null || true
[ -f "$OMARCHY_PATH/default/sddm/hyprland.lua" ] && sudo cp -a "$OMARCHY_PATH/default/sddm/hyprland.lua" /usr/share/sddm/hyprland.lua
sudo install -Dm644 "$OMARCHY_PATH/etc/sddm.conf.d/10-theme.conf"   /etc/sddm.conf.d/10-theme.conf
sudo install -Dm644 "$OMARCHY_PATH/etc/sddm.conf.d/10-wayland.conf" /etc/sddm.conf.d/10-wayland.conf
sudo install -Dm644 "$OMARCHY_PATH/default/wayland-sessions/omarchy.desktop" /usr/local/share/wayland-sessions/omarchy.desktop
sudo bash "$OMARCHY_PATH/install/config/theme-system.sh" 2>&1 | tail -2 || true

# Omarchy 4 keeps Chromium policy-directory hardening separate from its theme
# setup. This project runs selected upstream setup scripts instead of config/all.sh,
# so the policy step must be invoked explicitly when the reviewed source pin
# contains it. Treat absence or an unsafe result as a build failure: a writable
# managed-policy directory would let a desktop user alter browser policy.
log "hardening Chromium's managed-policy directory" "protegiendo el directorio de politicas administradas de Chromium"
BROWSER_POLICY_SCRIPT="$OMARCHY_PATH/install/config/browser-policy.sh"
BROWSER_POLICY_DIR=/etc/chromium/policies/managed
[ -f "$BROWSER_POLICY_SCRIPT" ] \
  || { warn "the reviewed Omarchy source is missing browser-policy.sh" "la fuente revisada de Omarchy no contiene browser-policy.sh"; exit 1; }
bash "$BROWSER_POLICY_SCRIPT" \
  || { warn "browser policy hardening failed" "fallo la proteccion de politicas del navegador"; exit 1; }
[ -d "$BROWSER_POLICY_DIR" ] && [ ! -L "$BROWSER_POLICY_DIR" ] \
  && [ "$(stat -c '%U:%G:%a' "$BROWSER_POLICY_DIR")" = root:root:755 ] \
  || { warn "unsafe Chromium policy directory: $BROWSER_POLICY_DIR" "directorio inseguro de politicas de Chromium: $BROWSER_POLICY_DIR"; exit 1; }

export OMARCHY_PATH=/usr/share/omarchy
export PATH="/usr/local/bin:$PATH"

# ------------------------------------------------------------ tema
log "applying the Tokyo Night theme" "aplicando el tema Tokyo Night"
mkdir -p ~/.config/omarchy/themes
if command -v omarchy-theme-set >/dev/null 2>&1; then
  omarchy-theme-set "Tokyo Night" || warn "omarchy-theme-set falló; enlazando a mano"
fi
if [ ! -e ~/.config/omarchy/current/theme ]; then
  mkdir -p ~/.config/omarchy/current
  ln -snf "$OMARCHY_PATH/themes/tokyo-night" ~/.config/omarchy/current/theme
fi
# Per-app theme links. In quattro, the active theme resides in
# ~/.local/state/omarchy/current/theme (bin/omarchy-theme-set:12), not in
# ~/.config/omarchy/current, which is the Omarchy 3 path and does not exist here.
# There is no mako link: quattro has no external notification daemon.
mkdir -p ~/.config/btop/themes
ln -snf ~/.local/state/omarchy/current/theme/btop.theme ~/.config/btop/themes/current.theme
ls -l ~/.local/state/omarchy/current/ 2>/dev/null

# ------------------------------------------------------------ VM adjustments
log "virtual machine settings" "ajustes para máquina virtual"
# quattro uses Lua configuration: writing monitors.conf would be useless.
cat > ~/.config/hypr/monitors.lua <<'LUA'
-- See https://wiki.hypr.land/Configuring/Basics/Monitors/
-- Available modes: hyprctl monitors all
--
-- VM in UTM/QEMU with virtio-gpu. Two adjustments compared to Omarchy's values:
--
--  1. Scale 1 (Omarchy assumes 2x retina screens; in the VM, everything would be huge).
--  2. Fixed resolution 1920x1200 instead of "preferred", which yields 1280x800.
--
-- IMPORTANT: changing the mode at runtime (hyprctl / config reload) breaks
-- rendering under virgl: the desktop remains blank until reboot.
-- Applying at boot works fine. If you modify this, restart the VM.
--
-- To make the resolution follow the UTM window size:
--  hl.monitor({ output = "", mode = "preferred", position = "auto", scale = 1 })
hl.env("GDK_SCALE", "1")
hl.monitor({ output = "Virtual-1", mode = "1920x1200@60", position = "0x0", scale = 1 })
LUA
rm -f ~/.config/hypr/monitors.conf ~/.config/hypr/autostart.conf

# Shared clipboard with the UTM host
cat > ~/.config/hypr/autostart.lua <<'LUA'
-- Extra processes launched at session start.
hl.on("hyprland.start", function()
  -- spice-vdagent is NOT launched: its clipboard is X11-only and under Hyprland it fails
  -- with "cannot open display". Worse, if it starts, vdagentd detects two agents
  -- in the same session and disconnects both ("multiple agents in one
  -- session"). The clipboard is handled by omarchy-arm-vdagent, as a user
  -- service.
end)
LUA

# --- seal migrations: a clean install starts with the final state -------
# Without this, omarchy-update attempts to replay ~80 historical migrations and dies
# on the first one that installs an Omarchy-specific package (x86_64 only).
mkdir -p ~/.local/state/omarchy/migrations
for f in "$OMARCHY_PATH"/migrations/*.sh; do
  [ -f "$f" ] && : > ~/.local/state/omarchy/migrations/"$(basename "$f")"
done
echo "  $(ui_text 'sealed migrations' 'migraciones selladas'): $(ls -1 ~/.local/state/omarchy/migrations | wc -l)"

# --- branding (about + screensaver) --------------------------------------
mkdir -p ~/.config/omarchy/branding
cp "$OMARCHY_PATH/icon.txt" ~/.config/omarchy/branding/about.txt 2>/dev/null || true
cp "$OMARCHY_PATH/logo.txt" ~/.config/omarchy/branding/screensaver.txt 2>/dev/null || true

# --- omarchy-pkg-add tolerant of what does not exist on ARM ---------------
# CRITICAL: /usr/local/bin/omarchy-pkg-add is a symlink to the tree. Writing with
# `tee` would follow and replace the ORIGINAL Omarchy script with this
# wrapper, whose REAL target would then point to itself: infinite loop. You must
# delete the symlink and create a real file.
sudo rm -f /usr/local/bin/omarchy-pkg-add
sudo install -Dm755 /dev/stdin /usr/local/bin/omarchy-pkg-add <<'WRAP'
#!/bin/bash
# Wrapper for Arch Linux ARM: Omarchy's own packages (tensaku,
# omarchy-nvim, ttfx...) and several proprietary apps only exist for x86_64.
# The original aborts if any are missing, which crashes omarchy-update entirely and leaves
# migrations incomplete. Here they are skipped with a warning and the rest are installed.
REAL=${OMARCHY_ARM_REAL_PKG_ADD:-/usr/share/omarchy/bin/omarchy-pkg-add}
avail=(); skip=()
for p in "$@"; do
  if pacman -Q "$p" &>/dev/null || pacman -Si "$p" &>/dev/null; then
    avail+=("$p")
  else
    skip+=("$p")
  fi
done
((${#skip[@]})) && printf '\033[33mOmitido, no existe en Arch Linux ARM: %s\033[0m\n' "${skip[*]}" >&2
if ((${#skip[@]})) && [[ ${OMARCHY_ARM_STRICT_PACKAGES:-0} == 1 ]]; then
  printf '\033[31mARM install aborted before making changes: unavailable package(s): %s\033[0m\n' "${skip[*]}" >&2
  exit 1
fi
((${#avail[@]})) || exit 0
exec "$REAL" "${avail[@]}"
WRAP

# --- Omarchy tools not published for aarch64 -------------
# Almost none are incompatible: they are Rust, Go, or Qt/C++ and only lack
# someone to build them. Several declare arch=(x86_64) by default, not because
# the code is not portable; in those cases, simply add the architecture.
# They are compiled in order of increasing cost, and none is fatal if it fails.
build_omarchy_tool() {                 # build_omarchy_tool <aur|omapkgs> <pkg>
  # A single `local` expands all values before assigning any,
  # so $pkg does not yet exist when building $dir. They must be separated.
  local src="$1" pkg="$2"
  # En el disco, no en /tmp: /tmp es tmpfs (RAM/2 = 4 GB con los 8 GB de la VM
  # de construccion) y un solo proyecto Rust grande se acerca a ese limite.
  # ~/.cache lo borra el sanitizado, asi que no deja rastro en la imagen.
  local dir="$HOME/.cache/omabuild/$pkg"
  pacman -Q "$pkg" >/dev/null 2>&1 && return 0
  rm -rf "$dir"; mkdir -p "$dir"
  case "$src" in
    aur)
      # The lock maps package names to their reviewed PackageBase repository;
      # for example, yaru-icon-theme deliberately resolves to the yaru repo.
      clone_pinned "$pkg" "$dir" || return 1 ;;
    omapkgs)
      clone_pinned omarchy-pkgs "$dir/repo" "pkgbuilds/$pkg" || return 1
      cp -a "$dir/repo/pkgbuilds/$pkg/." "$dir/" 2>/dev/null || return 1
      rm -rf "$dir/repo" ;;
  esac
  [ -f "$dir/PKGBUILD" ] || return 1
  # 'any' may come without quotes; mixing it with specific architectures is a
  # makepkg error, so it is only patched when it is not 'any' and does not include aarch64.
  grep -qE "^arch=\(.*\b(aarch64|any)\b" "$dir/PKGBUILD" || \
    sed -i "s/^arch=(\(.*\))/arch=(\1 'aarch64')/" "$dir/PKGBUILD"
  # A PKGBUILD can generate several subpackages, with only one of them having
  # a missing dependency on ARM (yaru-gtk-theme needs gtk-engine-murrine).
  # Build without installing, then install only the requested subpackage.
  # -s installs build dependencies. Without it, most of these
  # PKGBUILDs fail at the first step due to missing makedepends. -i is not used
  # because installation is done afterwards, subpackage by subpackage.
  # If it fails, the log is the only explanation. Keep it in the failure
  # directory before removing this package's build tree.
  # The speed limit is removed by DisableDownloadTimeout in /etc/pacman.conf
  # (set in stage2), so makepkg's dependency installation inherits it.
  if ( cd "$dir" && makepkg -s --noconfirm --needed --noprogressbar --nocheck ) >"$dir/build.log" 2>&1; then
    local built
    built=$(ls "$dir/$pkg"-*.pkg.tar.* 2>/dev/null | head -1)
    [ -n "$built" ] || built=$(ls "$dir"/*.pkg.tar.* 2>/dev/null | head -1)
    # theme-system.sh already created symlinks inside /usr/share/icons/Yaru because the
    # theme was missing: the real package conflicts with them. --overwrite resolves this.
    # shellcheck disable=SC2024 # The log is user-owned; only pacman needs sudo.
    [ -n "$built" ] && sudo pacman -U --noconfirm --needed \
      --overwrite '/usr/share/icons/*' "$built" >>"$dir/build.log" 2>&1
    # Se libera YA, no al final del bucle. /tmp/omabuild acumulaba el arbol de
    # compilacion de las 18 herramientas a la vez; en /tmp, que es tmpfs y por
    # tanto RAM, eso son varios GB. Al entrar herdr se lleno y la siguiente
    # murio con "No space left on device", sin que el fallo tuviera nada que
    # ver con ella.
    rm -rf "$dir"
  else
    mkdir -p "$HOME/.omarchy-arm-prov/fallos"
    cp "$dir/build.log" "$HOME/.omarchy-arm-prov/fallos/$pkg.log" 2>/dev/null || true
    echo "  --- $pkg $(ui_text 'failed; last makepkg lines' 'fallo; ultimas lineas de makepkg') ---"
    tail -20 "$dir/build.log" 2>/dev/null | sed 's/^/      /'
    echo "  --- ($(ui_text 'full log at' 'log completo en') ~/.omarchy-arm-prov/fallos/$pkg.log) ---"
    rm -rf "$dir"
    return 1
  fi
}

# Aqui se enlazaba /opt/zig0.15 al zig del sistema, para el PKGBUILD de herdr
# en AUR, que lo invoca por esa ruta fija. No podia funcionar nunca:
# libghostty-vt exige 0.15.2 EXACTO -compara major, minor y patch- y los repos
# empaquetan 0.16. Ademas instalaba ~180 MB de zig en la imagen para nada.
# herdr se compila ahora desde omarchy-pkgs, que se trae su propio Zig.

if [ "${HACER_TOOLS:-si}" != "si" ]; then
  warn "tool compilation disabled: ttfx will use the static screensaver fallback;" "compilacion de herramientas desactivada: ttfx usara el salvapantallas estatico;"
  warn "tensaku, omacalc, omacut, omawrite, aether, cliamp, and omarchy-nvim" "faltaran tensaku, omacalc, omacut, omawrite, aether, cliamp y omarchy-nvim"
  warn "will be missing (they can be added later" "(se pueden anadir despues"
  warn "with: yay -S <package>)" "con: yay -S <paquete>)"
else
log "building Omarchy tools unavailable on aarch64" "compilando las herramientas de Omarchy ausentes en aarch64"
TOOLS_OK=(); TOOLS_KO=()
for spec in \
  "aur:yaru-icon-theme" "aur:ttf-ia-writer" "aur:tzupdate" "aur:ufw-docker" \
  "omapkgs:omarchy-nvim" "omapkgs:tobi-try" "aur:mise-bin" \
  "aur:aether" "aur:cliamp" \
  "omapkgs:omacalc" "omapkgs:omacut" "omapkgs:omawrite" \
  "omapkgs:herdr" "omapkgs:tensaku" "omapkgs:hyprland-preview-share-picker"; do
  src=${spec%%:*}; pkg=${spec#*:}
  if build_omarchy_tool "$src" "$pkg"; then TOOLS_OK+=("$pkg"); else TOOLS_KO+=("$pkg"); fi
done
echo "  $(ui_text 'built' 'compiladas'): ${TOOLS_OK[*]:-$(ui_text 'none' 'ninguna')}"
[ ${#TOOLS_KO[@]} -gt 0 ] && warn "no compilaron: ${TOOLS_KO[*]}"
rm -rf "$HOME/.cache/omabuild"
fi
# Omarchy intentionally replaces two Yaru icons with Adwaita ones; if Yaru
# has just been installed, it needs to be reapplied.
sudo bash "$OMARCHY_PATH/install/config/theme-system.sh" >/dev/null 2>&1 || true

# herdr se compila desde omarchy-pkgs y NO desde AUR. El PKGBUILD de AUR invoca
# /opt/zig0.15/zig y depende de un paquete zig0.15 que en ARM no existe (el de
# AUR es arch=(x86_64) y compila LLVM desde fuente). El de Omarchy declara
# arch=('x86_64' 'aarch64') y se descarga el tarball oficial
# zig-aarch64-linux-0.15.2.tar.xz de ziglang.org -sha256 958ed7d1e00d0ea7...-,
# que es la unica version que libghostty-vt acepta.

# --- The kernel restart warning, which on ARM never shuts down -------
# omarchy-update-restart decides whether the kernel changed by looking for a vmlinuz inside
# /usr/lib/modules/<version>/ that belongs to a package. On x86_64 Arch the
# linux package installs it there; on Arch Linux ARM, linux-aarch64 leaves the image
# in /boot/Image and DOES NOT create that vmlinuz. The loop finds nothing, the variable
# remains "true" and requests a restart on every update, forever.
# This wrapper compares what actually matters: uname -r against the directory
# of modules owned by the kernel package. /usr/local/bin comes before
# /usr/bin in the PATH, so it replaces the original without touching the tree.
log "omarchy-update-restart wrapper (kernel notice on ALARM)" "envoltorio de omarchy-update-restart (aviso de kernel en ALARM)"
sudo install -Dm755 /dev/stdin /usr/local/bin/omarchy-update-restart <<'KRN'
#!/bin/bash
# On Arch Linux ARM the kernel does not leave a vmlinuz in /usr/lib/modules/<ver>/, which is
# what the original looks for: without it, it always requests a restart. It compares uname -r
# with the module directory belonging to the kernel package.
if [ -z "${OMARCHY_SKIP_KERNEL_CHECK:-}" ]; then
  # modules.dep is generated by depmod and does not belong to any package. modules.builtin
  # is provided by linux-aarch64, so it serves to determine whether the directory of
  # modules for the running kernel is the one from the installed package.
  pkg=$(pacman -Qoq /usr/lib/modules/"$(uname -r)"/modules.builtin 2>/dev/null \
        || pacman -Qoq /usr/lib/modules/"$(uname -r)"/modules.order 2>/dev/null || true)
  if [ -n "$pkg" ]; then
    # The module directory for the running kernel belongs to the installed
    # package: there is no new kernel waiting for a restart.
    export OMARCHY_KERNEL_CURRENT=1
  fi
fi
REAL=/usr/bin/omarchy-update-restart
[ -x "$REAL" ] || exit 0
if [ -n "${OMARCHY_KERNEL_CURRENT:-}" ]; then
  # Only the kernel block is omitted; the rest (Hyprland, services, shell)
  # is left intact by running the original with that check already resolved.
  sed 's#^kernel_updated=true$#kernel_updated=false#' "$REAL" | bash -s -- "$@"
else
  exec "$REAL" "$@"
fi
KRN
echo "  /usr/local/bin/omarchy-update-restart"

# --- ttfx: screensaver text effects (Rust, ~12 min) ----------------------
if ! command -v ttfx >/dev/null 2>&1 && command -v cargo >/dev/null 2>&1; then
  log "building ttfx from source (unavailable for aarch64)" "compilando ttfx desde fuente (no existe para aarch64)"
  rm -rf /tmp/ttfx-src
  # Rust embeds the source path in panic messages (.rodata), beyond strip's
  # reach. Compiling from $HOME would reveal who built the distributed image.
  # Build in /tmp, keep CARGO_HOME there so dependency paths avoid the home
  # directory, and use --remap-path-prefix in case any paths still slip through.
  if clone_pinned ttfx /tmp/ttfx-src \
     && ( cd /tmp/ttfx-src \
          && CARGO_HOME=/tmp/cargo-ttfx \
             RUSTFLAGS="--remap-path-prefix=/tmp/ttfx-src=ttfx --remap-path-prefix=/tmp/cargo-ttfx=cargo --remap-path-prefix=$HOME=." \
             cargo build --release --locked -q ); then
    sudo install -Dm755 /tmp/ttfx-src/target/release/ttfx /usr/local/bin/ttfx
    echo "  ttfx $(ttfx --version 2>/dev/null | head -1)"
  else
    warn "ttfx did not build; the screensaver will show the logo without effects" "ttfx no compilo; el salvapantallas mostrara el logo sin efectos"
  fi
  rm -rf /tmp/ttfx-src /tmp/cargo-ttfx
fi

# Upstream omarchy-screensaver unconditionally starts ttfx inside an infinite
# loop. If ttfx is absent, the loop becomes a busy error loop that floods the
# fullscreen terminal. Lightweight builds intentionally skip the Rust toolchain,
# so provide a compatible static-logo process. The parent screensaver continues
# to handle keyboard/mouse exit and kills this process by its ttfx command name.
if ! command -v ttfx >/dev/null 2>&1; then
  log "installing the static ttfx screensaver fallback" "instalando la alternativa estatica para ttfx"
  sudo install -Dm755 /dev/stdin /usr/local/bin/ttfx <<'TTFX_FALLBACK'
#!/bin/bash
# OMARCHY_TTFX_FALLBACK=1
set -uo pipefail

input="$HOME/.config/omarchy/branding/screensaver.txt"
while (($#)); do
  case "$1" in
    -i) input="${2:-$input}"; shift 2 ;;
    *) shift ;;
  esac
done

printf '\033[2J\033[H'
if [[ -r $input ]]; then
  logo=()
  while IFS= read -r line || [[ -n $line ]]; do
    logo[${#logo[@]}]=$line
  done < "$input"
  rows=$(tput lines 2>/dev/null || printf '24')
  cols=$(tput cols 2>/dev/null || printf '80')
  top=$(( (rows - ${#logo[@]}) / 2 ))
  (( top > 0 )) && printf '%*s' "$top" '' | tr ' ' '\n'
  for line in "${logo[@]}"; do
    left=$(( (cols - ${#line}) / 2 ))
    (( left < 0 )) && left=0
    printf '%*s%s\n' "$left" '' "$line"
  done
fi

child=""
stop() { [[ -n $child ]] && kill "$child" 2>/dev/null || true; exit 0; }
trap stop INT TERM HUP QUIT
while :; do
  sleep 3600 & child=$!
  wait "$child" || true
done
TTFX_FALLBACK
  echo "  /usr/local/bin/ttfx ($(ui_text 'static fallback' 'alternativa estatica'))"
fi

# The reconciled full build promises eighteen ARM tools, including herdr from
# the pinned omarchy-pkgs tree. Require every package plus the native ttfx
# binary when tool compilation is enabled.
sudo install -Dm755 /dev/stdin /usr/local/bin/omarchy-arm-verify-tools <<'TOOL_CONTRACT'
#!/bin/bash
set -uo pipefail

mode="${1:-si}"
full_packages=(
  yay xdg-terminal-exec yaru-icon-theme ttf-ia-writer tzupdate ufw-docker
  omarchy-nvim tobi-try mise-bin aether cliamp omacalc omacut omawrite herdr tensaku
  hyprland-preview-share-picker
)

case "$mode" in
  si)
    missing=()
    for package in "${full_packages[@]}"; do
      pacman -Q "$package" >/dev/null 2>&1 || missing+=("$package")
    done
    ttfx_path=$(command -v ttfx 2>/dev/null || true)
    if [[ -z $ttfx_path ]] || grep -aq '^# OMARCHY_TTFX_FALLBACK=1$' "$ttfx_path" 2>/dev/null; then
      missing+=(ttfx-native)
    fi
    if ((${#missing[@]})); then
      printf 'TOOLS_KO mode=full missing=%s\n' "${missing[*]}" >&2
      exit 1
    fi
    printf 'TOOLS_OK mode=full verified=18/18\n'
    ;;
  no)
    command -v ttfx >/dev/null 2>&1 \
      || { printf 'TOOLS_KO mode=lightweight missing=ttfx-fallback\n' >&2; exit 1; }
    printf 'TOOLS_OK mode=lightweight verified=1/1\n'
    ;;
  *)
    printf 'TOOLS_KO invalid-mode=%s\n' "$mode" >&2
    exit 2
    ;;
esac
TOOL_CONTRACT

log "verifying the selected tool contract" "verificando el contrato de herramientas elegido"
/usr/local/bin/omarchy-arm-verify-tools "${HACER_TOOLS:-si}" || exit 1

# --- keyboard: layout is y and Super usable from macOS -------------------
# macOS intercepts Cmd before UTM sees it (Cmd+Space opens Spotlight), making
# Omarchy's SUPER shortcuts unreachable. altwin:swap_lalt_lwin swaps Alt and
# Super, so the Mac's Option (⌥) key acts as SUPER.
cat > ~/.config/hypr/input.lua <<LUA
hl.config({
  input = {
    kb_layout  = "$VM_XKB",
    kb_options = "compose:caps,shift:both_capslock_cancel,altwin:swap_lalt_lwin",
  },
})
LUA

# --- no blur: rendering goes through llvmpipe (see 90-vm-graphics.conf) --------
cat > ~/.config/hypr/looknfeel.lua <<'LUA'
hl.config({
  decoration = {
    blur   = { enabled = false },
    shadow = { enabled = false },
  },
})
LUA

# --- reinforcement of the environment for apps launched by uwsm --------------------
mkdir -p ~/.config/uwsm/env.d
cat > ~/.config/uwsm/env.d/20-vm-graphics <<'ENVEOF'
export LIBGL_ALWAYS_SOFTWARE=1
ENVEOF

# User directories
xdg-user-dirs-update 2>/dev/null || true
mkdir -p ~/Pictures/Screenshots ~/Videos ~/Desktop ~/Documents ~/Downloads

# ------------------------------------------------------------ git
# --- optional installer for apps not included in the image ---------------
# Several apps (1Password, Obsidian, Typora, LocalSend) DO have official arm64
# builds, but they are proprietary. Including them in a distributed image would
# redistribute third-party binaries, so the installer is left for manual use.
if [ -f "$HOME/.omarchy-arm-prov/omarchy-arm-extras" ]; then
  log "optional app installer (omarchy-arm-extras)" "instalador de apps opcionales (omarchy-arm-extras)"
  sudo install -Dm755 "$HOME/.omarchy-arm-prov/omarchy-arm-extras" /usr/local/bin/omarchy-arm-extras
  if [ -f "$HOME/.omarchy-arm-prov/omarchy-arm-menu-compat" ]; then
    sudo install -Dm755 "$HOME/.omarchy-arm-prov/omarchy-arm-menu-compat" /usr/local/lib/omarchy-arm/menu-compat
    for command in \
      omarchy-arm-menu-compat omarchy-arm-show-failed \
      omarchy-launch-floating-terminal-with-presentation omarchy-channel-set \
      omarchy-install-browser omarchy-install-service-1password omarchy-install-service-spotify \
      omarchy-install-service-dropbox omarchy-install-service-nordvpn omarchy-install-service-once \
      omarchy-install-editor-zed omarchy-install-editor-vscode omarchy-install-editor-emacs \
      omarchy-install-terminal omarchy-install-and-launch omarchy-install-app \
      omarchy-install-ai-chatgpt omarchy-voxtype-install omarchy-install-preinstalls \
      omarchy-install-gaming-steam omarchy-install-gaming-retroarch \
      omarchy-install-gaming-geforce-now omarchy-install-gaming-xbox-controllers \
      omarchy-install-gaming-battlenet omarchy-install-gaming-lutris \
      omarchy-install-gaming-heroic omarchy-games-retro-install; do
      sudo ln -sfn /usr/local/lib/omarchy-arm/menu-compat "/usr/local/bin/$command"
    done
  else
    warn "ARM menu compatibility dispatcher is missing" "falta el dispatcher de compatibilidad del menu ARM"
  fi
  if [ -f "$HOME/.omarchy-arm-prov/omarchy-arm-menu.jsonc" ]; then
    sudo install -Dm644 "$HOME/.omarchy-arm-prov/omarchy-arm-menu.jsonc" /usr/share/omarchy-arm/omarchy-menu.jsonc
    ARM_MENU_TARGET="$HOME/.config/omarchy/extensions/omarchy-menu.jsonc"
    if [ ! -e "$ARM_MENU_TARGET" ] \
        || grep -q 'OMARCHY_ARM_MANAGED_MENU_V1' "$ARM_MENU_TARGET" 2>/dev/null \
        || ! grep -Eq '^[[:space:]]*"[^"]+"[[:space:]]*:' "$ARM_MENU_TARGET" 2>/dev/null; then
      install -Dm644 "$HOME/.omarchy-arm-prov/omarchy-arm-menu.jsonc" "$ARM_MENU_TARGET"
    else
      warn "Existing custom Omarchy menu extension preserved; unsupported ARM actions remain blocked when invoked" "Se conservo la extension personalizada del menu de Omarchy; las acciones ARM no compatibles siguen bloqueadas al invocarlas"
    fi
  else
    warn "ARM menu overlay is missing" "falta el overlay del menu ARM"
  fi
  EXTRAS_DESKTOP_NAME=$(ui_text 'Install missing apps (ARM)' 'Instalar apps que faltan (ARM)')
  sudo install -Dm644 /dev/stdin /usr/local/share/applications/omarchy-arm-extras.desktop <<DESK
[Desktop Entry]
Name=$EXTRAS_DESKTOP_NAME
Comment=1Password, Obsidian, Typora, LocalSend, Google Chrome, Zed
Exec=xdg-terminal-exec omarchy-arm-extras
Icon=system-software-install
Terminal=false
Type=Application
Categories=System;PackageManager;
DESK
  echo "  $(ui_text 'available as a command and in the application menu' 'disponible como comando y en el menu de aplicaciones')"
fi

# --- shared clipboard with the host ---------------------------
# The SPICE clipboard goes through three hops:
#   SPICE client (UTM) <-virtio-> spice-vdagentd <-unix socket-> agent
# The daemon communicates with the host; the session agent only communicates with the
# daemon. The OFFICIAL agent hands off the clipboard to X11 (vdagent.c:421 ->
# vdagent_clipboards_new(vdagent_display_get_x11(...)), cero referencias a
# wlr-data-control) and under Hyprland it dies with "cannot open display".
#
# omarchy-arm-vdagent fills that gap: same udscs protocol with the daemon,
# but on the other side wl-copy/wl-paste. The daemon remains as is (with -X,
# see stage2): we replace the agent, NOT the daemon. Attempting to communicate via the
# virtio port directly leaves the daemon without a channel ("Device or resource
# busy") and the host ignores everything.
if [ -f "$HOME/.omarchy-arm-prov/omarchy-arm-vdagent" ]; then
  log "clipboard agent for Wayland" "agente de portapapeles para Wayland"
  sudo install -Dm755 "$HOME/.omarchy-arm-prov/omarchy-arm-vdagent" /usr/local/bin/omarchy-arm-vdagent
  # The official agent must not start: vdagentd disconnects both if it sees
  # two agents in the same session ("multiple agents in one session").
  sudo systemctl --global mask spice-vdagent.service 2>/dev/null || true
  mkdir -p ~/.config/systemd/user
  VDAGENT_DESCRIPTION=$(ui_text 'Clipboard shared with the host (SPICE over Wayland)' 'Portapapeles compartido con el anfitrion (SPICE sobre Wayland)')
  cat > ~/.config/systemd/user/omarchy-arm-vdagent.service <<UNIT
[Unit]
Description=$VDAGENT_DESCRIPTION
After=graphical-session.target
PartOf=graphical-session.target
ConditionEnvironment=WAYLAND_DISPLAY

[Service]
Type=simple
# The socket is created by spice-vdagentd at startup; if it is not yet present, it retries.
ExecStartPre=/bin/sh -c 'for i in 1 2 3 4 5 6 7 8 9 10; do [ -S /run/spice-vdagentd/spice-vdagent-sock ] && exit 0; sleep 2; done; exit 1'
ExecStart=/usr/local/bin/omarchy-arm-vdagent
Restart=on-failure
RestartSec=5

[Install]
WantedBy=graphical-session.target
UNIT
  systemctl --user daemon-reload 2>/dev/null || true
  systemctl --user enable omarchy-arm-vdagent.service 2>/dev/null || true
  echo "  /usr/local/bin/omarchy-arm-vdagent + $(ui_text 'user service' 'servicio de usuario')"
fi
# Shared folder bridge, as an alternative if the SPICE channel is not
# available (for example with Apple's virtualization backend).
if [ -f "$HOME/.omarchy-arm-prov/omarchy-arm-clipboard" ]; then
  sudo install -Dm755 "$HOME/.omarchy-arm-prov/omarchy-arm-clipboard" /usr/local/bin/omarchy-arm-clipboard
  echo "  /usr/local/bin/omarchy-arm-clipboard ($(ui_text 'shared-folder fallback' 'alternativa por carpeta compartida'))"
fi
if [ -f "$HOME/.omarchy-arm-prov/omarchy-arm-share" ]; then
  sudo install -Dm755 "$HOME/.omarchy-arm-prov/omarchy-arm-share" /usr/local/bin/omarchy-arm-share
  echo "  /usr/local/bin/omarchy-arm-share ($(ui_text 'mounts either a VirtFS or WebDAV share' 'monta la carpeta, sea VirtFS o WebDAV'))"

  # OBS Studio and Pinta are free software: they can be included in the image, and
  # that is how they are distributed. They are installed with the same installer to avoid
  # duplicating their logic (OBS needs to remove the browser plugin, whose CEF is
  # x86-only; Pinta needs Microsoft's .NET arm64, which Arch does not package).
  # New builds use INCLUDE_LIBRE_APPS=yes|no. Accept the former Spanish setting
  # when repairing or resuming an older provisioning image.
  if [[ -z ${INCLUDE_LIBRE_APPS:-} && -n ${HACER_LIBRES:-} ]]; then
    case "$HACER_LIBRES" in
      si) INCLUDE_LIBRE_APPS=yes ;;
      no) INCLUDE_LIBRE_APPS=no ;;
      *) warn "invalid legacy HACER_LIBRES='$HACER_LIBRES'" "HACER_LIBRES antiguo no valido: '$HACER_LIBRES'"; exit 1 ;;
    esac
  fi
  : "${INCLUDE_LIBRE_APPS:=yes}"
  case "$INCLUDE_LIBRE_APPS" in
    yes|no) ;;
    *) warn "invalid INCLUDE_LIBRE_APPS='$INCLUDE_LIBRE_APPS'" "INCLUDE_LIBRE_APPS no valido: '$INCLUDE_LIBRE_APPS'"; exit 1 ;;
  esac
  # This is the most expensive part of the build: ~45 min. INCLUDE_LIBRE_APPS=no skips it.
  if [ "$INCLUDE_LIBRE_APPS" = yes ]; then
    log "OBS Studio and Pinta (free software included in the image; ~45 min)" "OBS Studio y Pinta (software libre, van dentro de la imagen; ~45 min)"
    if /usr/local/bin/omarchy-arm-extras pinta obs; then
      echo "  pinta: $(pacman -Q pinta 2>/dev/null || ui_text MISSING FALTA)"
      echo "  obs:   $(pacman -Q obs-studio 2>/dev/null || ui_text MISSING FALTA)"
      pacman -Q pinta obs-studio >/dev/null 2>&1 \
        || { warn "OBS or Pinta did not remain installed" "OBS o Pinta no quedaron instalados"; exit 1; }
    else
      warn "OBS or Pinta failed the reviewed-source installation" "OBS o Pinta fallaron la instalacion desde fuentes revisadas"
      exit 1
    fi
  else
    echo "  $(ui_text 'OBS and Pinta skipped' 'OBS y Pinta omitidos') (INCLUDE_LIBRE_APPS=no)"
  fi
fi

# --- updates: ensure "Update System" works and is reversible --------
# a) snapper: without it, omarchy-snapshot returns 127 and each update becomes
#    without a previous snapshot, i.e., without the ability to go back.
# b) post-update hook: omarchy-update-dev only performs `git pull` when
#    OMARCHY_PATH points OUTSIDE of /usr/share/omarchy, and here it points exactly there.
#    Without the hook, the system receives packages but the Omarchy tree (scripts,
#    themes, configuration) remains frozen at the cloned version.
log "updates: snapper + post-update hook" "actualizaciones: snapper + hook post-update"
sudo pacman -S --noconfirm --needed --disable-download-timeout snapper >/dev/null 2>&1 || warn "snapper no disponible"
if command -v snapper >/dev/null 2>&1; then
  sudo bash -euo pipefail "$OMARCHY_PATH/install/config/snapper.sh" >/dev/null 2>&1 \
    && echo "  snapper configurado: instantanea antes de cada actualizacion" \
    || warn "no se pudo configurar snapper"
fi
if [ -f "$HOME/.omarchy-arm-prov/10-arm-sync" ]; then
  install -Dm755 "$HOME/.omarchy-arm-prov/10-arm-sync" ~/.config/omarchy/hooks/post-update.d/10-arm-sync
  echo "  $(ui_text 'post-update hook installed' 'hook post-update instalado')"
fi

log "git"
git config --global user.name  "$VM_FULLNAME"
git config --global user.email "$VM_EMAIL"
git config --global init.defaultBranch master

# ------------------------------------------------------------ resumen
log "summary" "resumen"
echo "  omarchy:   $(ls -d "$OMARCHY_PATH" 2>/dev/null || ui_text MISSING FALTA)"
echo "  ~/.config: $(ls ~/.config | wc -l) $(ui_text 'entries' 'entradas')"
echo "  $(ui_text 'theme' 'tema'):      $(readlink -f ~/.config/omarchy/current/theme 2>/dev/null || ui_text 'not linked' 'sin enlazar')"
echo "  hyprland:  $(command -v Hyprland || command -v hyprland || echo 'NO')"
echo "  omarchy-shell: $(command -v omarchy-shell || echo 'NO')"
echo "  terminal:  $(command -v xdg-terminal-exec || echo 'NO')"
echo ""
echo "==> [stage3] $(ui_text 'COMPLETED' 'COMPLETADO')"
