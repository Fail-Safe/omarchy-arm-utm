#!/bin/bash
# Sanitization for distribution: removes all system-identifying information and leaves
# a generic user. It runs as ROOT inside the chroot.
set -uo pipefail
# config.env places stage1 inside the guest: it is the only way the
# host can communicate the build user. Without this, changing
# VM_USER would cause sanitization to rename to a non-existent user.
[ -f /root/prov/config.env ] && . /root/prov/config.env
OLD="${DIST_OLD_USER:-${VM_USER:-}}"
NEW="${DIST_NEW_USER:-omarchy}"
ui_text() { if [[ ${OMARCHY_LANG:-en} == es ]]; then printf '%s' "${2:-$1}"; else printf '%s' "$1"; fi; }
[ -n "$OLD" ] || { echo "$(ui_text 'sanitize: no source user was provided' 'sanitize: no se de que usuario partir')" >&2; exit 1; }
getent passwd "$OLD" >/dev/null || { echo "$(ui_text "sanitize: user '$OLD' does not exist" "sanitize: el usuario '$OLD' no existe")" >&2; exit 1; }
log()  { local text; text=$(ui_text "$1" "${2:-$1}"); echo ""; echo "==> $text"; }
warn() { local text; text=$(ui_text "$1" "${2:-$1}"); echo "!!  $text" >&2; }

log "1/10 detaching /usr/share/omarchy from the user's home" "1/10 desanclando /usr/share/omarchy del home del usuario"
# It was a symlink to /home/<user>/.local/share/omarchy, which ties the system to
# that user. It is converted into a real directory (as pacman would do) and
# the home directory now points there.
if [ -L /usr/share/omarchy ]; then
  TARGET=$(readlink -f /usr/share/omarchy)
  rm -f /usr/share/omarchy
  # Without set -e, a partial cp (typically due to a full disk: we have just
  # duplicated the tree) did not prevent the rm -rf below. The original was deleted and
  # left an incomplete /usr/share/omarchy: desktop without themes and without
  # commands, with the phase reporting OK. Now the original is only deleted if the
  # copy is complete.
  # The rollback must leave the system EXACTLY as it was, or the
  # next attempt finds /usr/share/omarchy converted into a partially created
  # directory, skips this entire block (the guard is [ -L ... ]) and reports
  # the image as good. That is why the partial copy is deleted before recreating the
  # link: 'ln -sfn' on a real directory creates the link INSIDE it.
  volver_atras() {
    warn "$1"
    rm -rf /usr/share/omarchy
    ln -sfn "$TARGET" /usr/share/omarchy
    exit 1
  }
  cp -a "$TARGET" /usr/share/omarchy \
    || volver_atras "$(ui_text "could not copy $TARGET to /usr/share/omarchy" "no pude copiar $TARGET a /usr/share/omarchy")"
  chown -R root:root /usr/share/omarchy
  N_ORIG=$(find "$TARGET" -mindepth 1 | wc -l)
  N_COPIA=$(find /usr/share/omarchy -mindepth 1 | wc -l)
  [ "$N_COPIA" -ge "$N_ORIG" ] \
    || volver_atras "$(ui_text "the copy is incomplete ($N_COPIA of $N_ORIG entries)" "la copia quedo incompleta ($N_COPIA de $N_ORIG entradas)")"
  rm -rf "$TARGET"
  echo "  $(ui_text "/usr/share/omarchy is now a real directory ($(du -sh /usr/share/omarchy | cut -f1), $N_COPIA entries)" "/usr/share/omarchy ahora es un directorio real ($(du -sh /usr/share/omarchy | cut -f1), $N_COPIA entradas)")"
fi

log "2/10 renaming user $OLD -> $NEW" "2/10 renombrando el usuario $OLD -> $NEW"
if id -u "$OLD" >/dev/null 2>&1; then
  pkill -u "$OLD" 2>/dev/null || true
  usermod -l "$NEW" -d "/home/$NEW" -m "$OLD"
  groupmod -n "$NEW" "$OLD" 2>/dev/null || true
  echo "$NEW:$NEW" | chpasswd
  echo "root:$NEW"  | chpasswd
fi
id "$NEW"
# the user's home points to the system tree
install -d -o "$NEW" -g "$NEW" "/home/$NEW/.local/share"
rm -rf "/home/$NEW/.local/share/omarchy"
ln -sfn /usr/share/omarchy "/home/$NEW/.local/share/omarchy"
chown -h "$NEW:$NEW" "/home/$NEW/.local/share/omarchy"

log "3/10 SDDM: autologin for the generic user" "3/10 SDDM: autologin al usuario generico"
cat > /etc/sddm.conf.d/20-autologin.conf <<EOF
[Autologin]
User=$NEW
Session=omarchy
EOF
grep -rl "$OLD" /etc/sddm.conf.d/ 2>/dev/null | while read -r f; do sed -i "s/\b$OLD\b/$NEW/g" "$f"; done
cat /etc/sddm.conf.d/20-autologin.conf

log "4/10 credentials and keys" "4/10 credenciales y claves"
rm -rf "/home/$NEW/.ssh"
rm -f /etc/ssh/ssh_host_*        # regenerated automatically on first boot
systemctl disable sshd.service 2>/dev/null || true
rm -f /etc/systemd/system/multi-user.target.wants/sshd.service
rm -f /etc/sudoers.d/99-fix /etc/sudoers.d/99-install
rm -rf "/home/$NEW/.gnupg" "/home/$NEW/.local/share/keyrings" "/home/$NEW/.password-store"
echo "  sshd: $(systemctl is-enabled sshd 2>&1)"

log "5/10 machine identity" "5/10 identidad de la maquina"
: > /etc/machine-id
rm -f /var/lib/dbus/machine-id
ln -sf /etc/machine-id /var/lib/dbus/machine-id
rm -f /etc/hostname; echo omarchy > /etc/hostname
cat > /etc/hosts <<'EOF'
127.0.0.1   localhost
::1         localhost
127.0.1.1   omarchy.localdomain omarchy
EOF

log "6/10 personal identity (Git, histories, cache)" "6/10 identidad personal (git, historiales, cache)"
rm -f "/home/$NEW/.gitconfig" "/home/$NEW/.config/git/config"
rm -f "/home/$NEW/.bash_history" "/home/$NEW/.zsh_history" "/home/$NEW/.local/share/fish/fish_history"
rm -rf "/home/$NEW/.cache" "/home/$NEW/.local/state/omarchy/first-run.log"
rm -rf "/home/$NEW/.local/share/omarchy-"* 2>/dev/null || true
rm -rf "/home/$NEW/shots" "/home/$NEW"/*.sh "/home/$NEW/config.env" 2>/dev/null || true
# NetworkManager: quita redes wifi guardadas
rm -f /etc/NetworkManager/system-connections/* 2>/dev/null || true

log "7b/10 removing proprietary apps from the distributable image" "7b/10 apps propietarias fuera de la imagen distribuible"
# These are installed with omarchy-arm-extras on the end-user's machine.
# Packaging them in a .zip that is distributed would constitute redistributing third-party binaries,
# so they are removed even if they were in the source VM.
for pkg in 1password 1password-cli typora localsend-bin google-chrome obsidian-bin; do
  pacman -Q "$pkg" >/dev/null 2>&1 && { pacman -Rns --noconfirm "$pkg" >/dev/null 2>&1 && echo "  $(ui_text 'removed' 'retirado') $pkg"; }
done
for d in /opt/1Password /opt/obsidian /opt/typora; do
  [ -e "$d" ] && { rm -rf "$d"; echo "  $(ui_text 'removed' 'retirado') $d"; }
done
rm -f /usr/local/bin/obsidian /usr/local/share/applications/obsidian.desktop 2>/dev/null || true
# Removing /opt/1Password leaves its /usr/bin links pointing to nothing. It's the
# same old oversight: a text sweep doesn't see the target of a link.
while IFS= read -r l; do
  case "$(readlink "$l")" in
    /opt/1Password/*|/opt/obsidian/*|/opt/typora/*)
      rm -f "$l"; echo "  $(ui_text 'removed dangling link' 'enlace colgado retirado'): $l" ;;
  esac
done < <(find /usr/bin /usr/local/bin -maxdepth 1 -xtype l 2>/dev/null)
# The traces left upon installation: if Chrome is removed, you must also remove
# the shortcut and the webapp launcher for Spotify, which invoke it. Otherwise,
# the image ends up with a SUPER+SHIFT+M pointing to a non-existent binary.
BIND="/home/$NEW/.config/hypr/bindings.lua"
if [ -f "$BIND" ] && grep -q "open.spotify.com" "$BIND"; then
  sed -i '/^-- Spotify no tiene cliente nativo/,/^o.bind("SUPER + SHIFT + M", "Spotify"/d' "$BIND"
  sed -i '/open\.spotify\.com/d' "$BIND"
  echo "  $(ui_text 'removed the SUPER+SHIFT+M shortcut for the Spotify web app' 'retirado el atajo SUPER+SHIFT+M de la webapp de Spotify')"
fi
rm -f "/home/$NEW/.local/share/applications/Spotify.desktop" \
      "/home/$NEW/.local/share/applications/spotify.desktop" 2>/dev/null || true
rm -rf "/home/$NEW/.local/share/omarchy/webapps" 2>/dev/null || true
echo "  ($(ui_text 'reinstall with' 'se reinstalan con'): omarchy-arm-extras)"

log "7c/10 slimming: build-only dependencies" "7c/10 adelgazando: lo que solo hacia falta para compilar"
# Compiling the tools leaves behind entire build chains (the .NET
# SDK is 425 MiB) and Rust and Go toolchains in the home directory. None of this is
# needed to use the image, and it takes up ~2 GB of the zip.
for p in dotnet-sdk-bin dotnet-targeting-pack-bin aspnet-targeting-pack-bin; do
  pacman -Q "$p" >/dev/null 2>&1 && { pacman -Rns --noconfirm "$p" >/dev/null 2>&1 && echo "  $(ui_text 'removed' 'quitado') $p"; }
done
# Omarchy 4 retires these four: quickshell is the bar, the menu, the OSD, and the
# notification daemon. mako also hijacks org.freedesktop.Notifications by
# D-Bus activation and leaves notifications unthemed. They shouldn't be
# installed, but if a future version of the list reintroduces them, remove them.
for p in mako swayosd walker elephant; do
  pacman -Q "$p" >/dev/null 2>&1 && { pacman -Rns --noconfirm "$p" >/dev/null 2>&1 && echo "  $(ui_text 'retired' 'jubilado') $p"; }
done
rm -rf "/home/$NEW/.config/mako" "/home/$NEW/.config/walker" "/home/$NEW/.config/swayosd"
rm -f  /usr/local/bin/walker
orph=$(pacman -Qdtq 2>/dev/null | tr '\n' ' ')
[ -n "${orph// /}" ] && { echo "  $(ui_text 'orphans' 'huerfanos'): $orph"; pacman -Rns --noconfirm $orph >/dev/null 2>&1; }
rm -rf "/home/$NEW/.cargo" "/home/$NEW/go" "/home/$NEW/.rustup" "/home/$NEW/.npm" 2>/dev/null
echo "  $(ui_text 'required packages that must remain' 'imprescindibles que deben seguir'): $(for p in hyprland quickshell sddm; do printf '%s ' "$(pacman -Q $p 2>/dev/null || echo "$(ui_text MISSING FALTA)-$p")"; done)"

log "7d/10 slimming: hardware support a VM cannot need" "7d/10 adelgazando: lo que no puede hacer falta en una VM"
# Measured on a real image: 675 MiB of firmware for hardware that in a QEMU
# VM with virtio devices cannot exist. linux-firmware is not installed on
# purpose, but the vendor splits come in as dependencies.
FW=$(pacman -Qq 2>/dev/null | grep -E '^linux-firmware-(intel|nvidia|amdgpu|atheros|broadcom|realtek|mediatek|marvell|qcom|qlogic|liquidio|bnx2x|mellanox|nfp|other)$' | tr '\n' ' ')
if [ -n "${FW// /}" ]; then
  echo "  $(ui_text 'firmware for absent hardware' 'firmware de hardware ausente'): $FW"
  # -Rdd: the linux-firmware metapackage claims the splits, which are also
  # unnecessary. If anything opposes it, leave it as is and don't break anything.
  pacman -Rdd --noconfirm $FW linux-firmware >/dev/null 2>&1 \
    && echo "  $(ui_text 'removed' 'retirados')" || echo "  ($(ui_text 'could not remove; retaining them' 'no se pudieron retirar; se dejan'))"
fi
# Documentation and manuals: 469 MiB. This is an image to test a desktop,
# not on a server where you are going to read man pages. The .md files in Omarchy are NOT touched.
for d in /usr/share/doc /usr/share/man /usr/share/info /usr/share/gtk-doc; do
  [ -d "$d" ] && { echo "  $d: $(du -shx "$d" 2>/dev/null | cut -f1)"; rm -rf "$d"; }
done
mkdir -p /usr/share/man /usr/share/doc
echo "  $(ui_text 'usage after trimming' 'ocupacion tras el recorte'): $(df -h / | awk 'NR==2{print $3}')"

log "7/10 system logs and caches" "7/10 logs y caches del sistema"
rm -rf /var/log/journal/* /var/log/omarchy* /var/log/pacman.log
find /var/log -type f -name "*.log" -delete 2>/dev/null || true
rm -rf /var/cache/pacman/pkg/* /var/tmp/* /tmp/* 2>/dev/null || true
# NOTE: /root/prov is NOT deleted here. Steps 8a and 8b read from there the update hook and the
# optional app installer; deleting it before would leave the
# image without either of them, silently. repair.sh removes it upon exiting the
# chroot, which is where it belongs.
rm -rf /root/.bash_history /root/.cache 2>/dev/null || true
rm -f /root/STAGE2_OK 2>/dev/null || true
# stage2 writes it when a package fails to install. In a distributed image, it informs the recipient that the builder failed.
# The verify phase starts the VM before sanitizing, and that startup leaves a seed
rm -f /root/failed-packages.txt 2>/dev/null || true
# of randomness and credential secrets: identical across all copies.
# omarchy-update-dev does not update the tree when OMARCHY_PATH is
rm -f /var/lib/systemd/random-seed /var/lib/systemd/credential.secret 2>/dev/null || true
: > /var/log/wtmp 2>/dev/null || true
: > /var/log/btmp 2>/dev/null || true
: > /var/log/lastlog 2>/dev/null || true

log "8/10 recipient notice" "8/10 aviso al destinatario"
if [[ ${OMARCHY_LANG:-en} == es ]]; then
cat > /etc/motd <<'EOF'

  Omarchy sobre Arch Linux ARM (aarch64) — imagen para UTM en Apple Silicon

  Usuario: omarchy   Contrasena: omarchy   (tambien para root)

  >> CAMBIA LA CONTRASENA AHORA:  passwd

  Teclas: la tecla Option (⌥) del Mac actua como SUPER.
          ⌥+Space  menu de Omarchy      ⌥+Return  terminal

  ¿Echas en falta 1Password, Obsidian, Typora, Spotify o LocalSend?
  No vienen dentro por licencia, pero todas tienen build ARM64 oficial:

      omarchy-arm-extras --list     ver que puede instalar
      omarchy-arm-extras            menu interactivo

EOF
else
cat > /etc/motd <<'EOF'

  Omarchy on Arch Linux ARM (aarch64) — UTM image for Apple Silicon

  User: omarchy   Password: omarchy   (also for root)

  >> CHANGE THE PASSWORD NOW:  passwd

  Keys: the Mac Option (⌥) key acts as SUPER.
        ⌥+Space  Omarchy menu      ⌥+Return  terminal

  Missing 1Password, Obsidian, Typora, Spotify, or LocalSend?
  They are excluded for licensing reasons, but all have official ARM64 builds:

      omarchy-arm-extras --list     show available installers
      omarchy-arm-extras            interactive menu

EOF
fi
install -d -o "$NEW" -g "$NEW" "/home/$NEW/Desktop"
cp /etc/motd "/home/$NEW/Desktop/LEEME.txt"
chown "$NEW:$NEW" "/home/$NEW/Desktop/LEEME.txt"

log "8a/10 ARM update hook" "8a/10 hook de actualizacion para ARM"
# /usr/share/omarchy, which is our case: without this hook, Omarchy freezes.
# The checkout must not be polluted by permission changes, or the pull will fail
if [ -f /root/prov/10-arm-sync ]; then
  install -Dm755 /root/prov/10-arm-sync "/home/$NEW/.config/omarchy/hooks/post-update.d/10-arm-sync"
  chown -R "$NEW:$NEW" "/home/$NEW/.config/omarchy/hooks" 2>/dev/null || true
  echo "  post-update.d/10-arm-sync"
fi
# repair.sh copies extras.sh as omarchy-arm-extras, but if that copy does not
git -C /usr/share/omarchy config core.fileMode false 2>/dev/null || true
git -C /usr/share/omarchy checkout -- . 2>/dev/null || true
echo "  $(ui_text 'clean checkout' 'checkout limpio'): $(git -C /usr/share/omarchy status --porcelain 2>/dev/null | wc -l) $(ui_text 'files' 'ficheros')"

log "8b/10 optional app installer" "8b/10 instalador de apps opcionales"
# occur, the entire block would be skipped silently and the image would end up without the
# menu entry. Both names are accepted, and a warning is issued if one is missing.
# grep -rl only checks the CONTENT of the files: the target of a symbolic
EXTRAS_SRC=""
for c in /root/prov/omarchy-arm-extras /root/prov/extras.sh; do
  [ -f "$c" ] && { EXTRAS_SRC="$c"; break; }
done
if [ -n "$EXTRAS_SRC" ]; then
  for lock in core-git-sources.tsv free-app-artifacts.tsv; do
    [ -f "/root/prov/$lock" ] \
      || { warn "the reviewed source lock $lock was missing" "faltaba el bloqueo revisado de fuentes $lock"; exit 1; }
    install -Dm644 "/root/prov/$lock" "/usr/share/omarchy-arm/$lock"
  done
  install -Dm755 "$EXTRAS_SRC" /usr/local/bin/omarchy-arm-extras
  DESKTOP_NAME=$(ui_text 'Install missing apps (ARM)' 'Instalar apps que faltan (ARM)')
  install -Dm644 /dev/stdin /usr/local/share/applications/omarchy-arm-extras.desktop <<DESK
[Desktop Entry]
Name=$DESKTOP_NAME
Comment=1Password, Obsidian, Typora, LocalSend, Chrome, OBS, Pinta
Exec=xdg-terminal-exec omarchy-arm-extras
Icon=system-software-install
Terminal=false
Type=Application
Categories=System;PackageManager;
DESK
  chown "$NEW:$NEW" /usr/local/share/applications/omarchy-arm-extras.desktop 2>/dev/null || true
  echo "  /usr/local/bin/omarchy-arm-extras + $(ui_text 'menu entry' 'entrada en el menu')"
else
  warn "the optional app installer was missing from the ISO: the image will not include it" "el instalador de apps opcionales no venia en el ISO: la imagen saldra sin el"
fi

log "9/10 checking that nothing remains tied to $OLD" "9/10 comprobando que nada quedo atado a $OLD"
echo "  $(ui_text 'references in /etc' 'referencias en /etc'):"; grep -rl "\b$OLD\b" /etc 2>/dev/null | head -5 || echo "    $(ui_text 'none' 'ninguna')"
echo "  home:"; ls -ld "/home/$NEW"; ls /home/
echo "  $(ui_text 'owner of stray files' 'propietario de ficheros sueltos'):"; find /home/$NEW -maxdepth 2 ! -user "$NEW" 2>/dev/null | head -3 || echo "    $(ui_text 'all correct' 'todo correcto')"

log "10/10 freeing unused space (for better compression)" "10/10 liberando espacio no usado (para que comprima mejor)"
sync
fstrim -av 2>&1 | head -3 || true
echo ""
log "usermod backup files (contain the old user and password hash)" "ficheros de respaldo de usermod (contienen el usuario y el hash antiguos)"
rm -f /etc/passwd- /etc/shadow- /etc/group- /etc/gshadow-
log "subuid/subgid"
sed -i "s/^$OLD:/$NEW:/" /etc/subuid /etc/subgid 2>/dev/null || true
cat /etc/subuid /etc/subgid 2>/dev/null

log "final sweep for references to $OLD" "barrido final de referencias a $OLD"
echo "  /etc:"; grep -rl "\b$OLD\b" /etc 2>/dev/null || echo "    $(ui_text 'none' 'ninguna')"
echo "  /home:"; grep -rl "\b$OLD\b" /home/$NEW/.config /home/$NEW/.bashrc 2>/dev/null | head -5 || echo "    $(ui_text 'none' 'ninguna')"
echo "  /usr/local/bin:"; grep -rl "\b$OLD\b" /usr/local/bin 2>/dev/null | head -5 || echo "    $(ui_text 'none' 'ninguna')"
echo "  $(ui_text 'broken links in /usr/bin' 'enlaces rotos en /usr/bin'): $(find /usr/bin -xtype l 2>/dev/null | wc -l)"
echo "  /usr/share/omarchy ($(ui_text 'must not point to /home' 'no debe apuntar a /home')):"; ls -ld /usr/share/omarchy

log "system consistency" "coherencia del sistema"
echo "  passwd: $(getent passwd $NEW)"
echo "  home:   $(ls -ld /home/$NEW | awk '{print $3, $4, $9}')"
echo "  symlink omarchy: $(readlink /home/$NEW/.local/share/omarchy)"
echo "  autologin: $(grep -h User= /etc/sddm.conf.d/*.conf 2>/dev/null | tr '\n' ' ')"
echo "  $(ui_text 'Omarchy binaries' 'binarios omarchy'): $(find /usr/bin -maxdepth 1 -name 'omarchy-*' | wc -l) in /usr/bin"
echo "  ttfx: $(command -v ttfx || echo NO)"
echo "  $(ui_text 'sealed migrations' 'migraciones selladas'): $(ls -1 /home/$NEW/.local/state/omarchy/migrations 2>/dev/null | wc -l)"
sync
echo ""
log "Nautilus/GTK bookmarks pointing to the old home" "marcadores de Nautilus/GTK apuntando al home antiguo"
for f in /home/$NEW/.config/gtk-3.0/bookmarks /home/$NEW/.config/gtk-4.0/bookmarks; do
  [ -f "$f" ] && { sed -i "s#/home/$OLD#/home/$NEW#g" "$f"; echo "  $f:"; cat "$f"; }
done

log "full name in passwd (shown in the greeter)" "nombre real en passwd (aparece en el greeter)"
chfn -f "Omarchy" "$NEW" 2>/dev/null || usermod -c "Omarchy" "$NEW"
getent passwd "$NEW"

log "user-dirs with absolute paths" "user-dirs con rutas absolutas"
for f in /home/$NEW/.config/user-dirs.dirs; do
  [ -f "$f" ] && sed -i "s#/home/$OLD#/home/$NEW#g" "$f"
done

log "symlinks pointing to the old home" "symlinks que apuntan al home antiguo"
# link is not content, so the text scan considers them clean.
# Omarchy stores the active theme and background as symbolic
# links (~/.local/state/omarchy/current/{theme,background}), so that a broken
# link leaves the desktop gray and unstyled, with no visible error.
#
mapfile -t BADLINKS < <(find /home/$NEW /etc /usr/bin /usr/local /opt -xdev -type l \
  -lname "*/home/$OLD/*" 2>/dev/null)
echo "  $(ui_text 'found' 'encontrados'): ${#BADLINKS[@]}"
for l in "${BADLINKS[@]:-}"; do
  [ -n "$l" ] || continue
  tgt=$(readlink "$l")
  ln -sfn "${tgt//\/home\/$OLD\//\/home\/$NEW\/}" "$l"
  echo "  $l -> $(readlink "$l")"
done
chown -h $NEW:$NEW "${BADLINKS[@]:-/home/$NEW}" 2>/dev/null || true

log "final sweep" "barrido final"
echo "  /etc:   $(grep -rl "\b$OLD\b" /etc 2>/dev/null | wc -l) $(ui_text 'matches' 'coincidencias')"
echo "  /home:  $(grep -rl "\b$OLD\b" /home/$NEW/.config /home/$NEW/.bashrc /home/$NEW/.bash_profile 2>/dev/null | wc -l) $(ui_text 'matches' 'coincidencias')"
echo "  $(ui_text 'links to' 'enlaces a') /home/$OLD: $(find /home/$NEW /etc /usr/bin /usr/local /opt -xdev -type l -lname "*/home/$OLD/*" 2>/dev/null | wc -l)"
echo "  $(ui_text 'broken links in the home directory' 'enlaces rotos en el home'): $(find /home/$NEW -xdev -type l ! -exec test -e {} \; -print 2>/dev/null | wc -l)"
echo "  $(ui_text 'broken links in /usr/bin' 'enlaces rotos en /usr/bin'): $(find /usr/bin -xtype l 2>/dev/null | wc -l)"
echo "  $(ui_text 'active background' 'fondo activo'): $(readlink -f /home/$NEW/.local/state/omarchy/current/background 2>/dev/null || ui_text NONE NINGUNO)"
test -e "/home/$NEW/.local/state/omarchy/current/background" \
  && echo "  $(ui_text 'background resolves' 'fondo resuelve'): OK" || echo "  $(ui_text 'background resolves' 'fondo resuelve'): $(ui_text BROKEN ROTO)"
# ttfx is compiled from source inside the VM, and the binary retains the
# build path in its debug info: /home/<builder>/... This is
# exactly what this phase exists to remove, so symbols are stripped
# instead of declaring it harmless, which is what it used to do.
for b in /usr/local/bin/ttfx /usr/local/bin/omarchy-arm-vdagent; do
  [ -f "$b" ] || continue
  case "$(file -b "$b" 2>/dev/null)" in
    *ELF*) strip --strip-unneeded "$b" 2>/dev/null || true ;;
  esac
done
if strings /usr/local/bin/ttfx 2>/dev/null | grep -q "$OLD"; then
  echo "  ttfx: $(ui_text "STILL mentions '$OLD' after stripping" "AUN menciona a '$OLD' tras el strip")"
else
  echo "  ttfx: $(ui_text 'no trace of the builder' 'sin rastro del constructor')"
fi

log "final distribution state" "estado final para distribuir"
echo "  $(ui_text 'user' 'usuario'):    $(getent passwd $NEW | cut -d: -f1,5,6)"
echo "  autologin:  $(grep -h User= /etc/sddm.conf.d/*.conf 2>/dev/null | sort -u | tr '\n' ' ')"
echo "  sshd:       $(systemctl is-enabled sshd 2>&1)"
echo "  $(ui_text 'optional installer' 'instalador opcional'): $(test -x /usr/local/bin/omarchy-arm-extras && ui_text yes si || ui_text MISSING FALTA)"
echo "  $(ui_text 'menu entry' 'entrada de menu'):     $(test -f /usr/local/share/applications/omarchy-arm-extras.desktop && ui_text yes si || ui_text MISSING FALTA)"
echo "  machine-id: $(wc -c < /etc/machine-id) bytes ($(ui_text 'empty = regenerated' 'vacio = se regenera'))"
echo ""
echo "  $(ui_text 'WARNING: from this point onward, the image must not be booted again. The first' 'AVISO: a partir de aqui la imagen no debe volver a arrancarse. El primer')"
echo "  $(ui_text 'boot regenerates machine-id, the random seed, and logs; otherwise those values' 'arranque regenera machine-id, semilla de aleatoriedad y logs, y esos')"
echo "  $(ui_text 'would be identical in every distributed copy. If you must boot it for' 'quedarian identicos en todas las copias distribuidas. Si hay que')"
echo "  $(ui_text 'verification, run this phase again afterward.' 'arrancarla para verificar algo, repite esta fase despues.')"
echo "  $(ui_text 'SSH host keys' 'claves ssh host'): $(ls /etc/ssh/ssh_host_* 2>/dev/null | wc -l) (0 = $(ui_text 'regenerated' 'se regeneran'))"
echo "  hostname:   $(cat /etc/hostname)"
sync
fstrim -av 2>&1 | head -2 || true

# ─────────────────────── invariants: this CAN fail ──────────────────
# Up to this point, everything was `echo`: the script runs without -e and always ends with an
# echo, so its exit code is 0 no matter what. repair.sh collects that 0, the
# host sees TOK_REPAIR_0 and marks the image as clean. If usermod fails,
# an image with the builder's username and password is distributed.
log "distributable image invariants" "invariantes de la imagen distribuible"
FALLOS=0
mal() { echo "  ✗ $(ui_text "$1" "${2:-$1}")"; FALLOS=$((FALLOS+1)); }
bien() { echo "  ✓ $(ui_text "$1" "${2:-$1}")"; }

getent passwd "$NEW" >/dev/null && bien "user $NEW exists" "existe el usuario $NEW" || mal "user $NEW does not exist" "no existe el usuario $NEW"
if [ "$OLD" != "$NEW" ]; then
  getent passwd "$OLD" >/dev/null && mal "the builder user ($OLD) still exists" "el usuario del constructor ($OLD) sigue existiendo" \
                                  || bien "the builder user no longer exists" "el usuario del constructor ya no existe"
fi
[ -d /usr/share/omarchy ] && [ ! -L /usr/share/omarchy ] \
  && bien "/usr/share/omarchy is a real directory" "/usr/share/omarchy es un directorio real" \
  || mal "/usr/share/omarchy is not a real directory" "/usr/share/omarchy no es un directorio real"

N_CMD=$(find /usr/bin -maxdepth 1 -name 'omarchy-*' | wc -l)
[ "$N_CMD" -ge 400 ] && bien "$N_CMD omarchy-* commands" "$N_CMD comandos omarchy-*" || mal "only $N_CMD omarchy-* commands (expected >=400)" "solo $N_CMD comandos omarchy-* (esperaba >=400)"

N_ROTO=$(find /usr/bin /usr/local/bin /home/"$NEW" -xdev -xtype l 2>/dev/null | wc -l)
[ "$N_ROTO" -le 5 ] && bien "$N_ROTO dangling links" "$N_ROTO enlaces colgando" || mal "$N_ROTO dangling links" "$N_ROTO enlaces colgando"

# Filenames, not just content: the scan above uses grep -rl, which
# looks inside files. A file that HAS the builder's name in
# its own path (mise saves one per trusted directory) would pass
# clean and travel inside the image.
if [ "$OLD" != "$NEW" ]; then
  # NOTE: as a WORD, never as a substring. With "*$OLD*" and VM_USER=dev, this
  # would match /etc/udev and the rm -rf would leave the image without a single udev rule;
  # with VM_USER=arch it would match the entire /home/omarchy. The build user's
  # name is environment-dependent, so the pattern must require
  # that $OLD appears delimited by something non-alphanumeric.
  RX_OLD=".*/([^/]*[^[:alnum:]])?$OLD([^[:alnum:]][^/]*)?"
  mapfile -t PORNOMBRE < <(find /home/"$NEW" /etc /usr/local /opt -xdev -mindepth 1 \
      -regextype posix-extended -regex "$RX_OLD" 2>/dev/null)
  if [ "${#PORNOMBRE[@]}" -gt 0 ] && [ -n "${PORNOMBRE[0]:-}" ]; then
    echo "  $(ui_text "removing ${#PORNOMBRE[@]} file(s) whose NAME contains '$OLD'" "quitando ${#PORNOMBRE[@]} fichero(s) cuyo NOMBRE lleva '$OLD'"):"
    for f in "${PORNOMBRE[@]}"; do echo "    $f"; rm -rf "$f"; done
  fi
  RESTAN=$(find /home/"$NEW" /etc /usr/local /opt -xdev -mindepth 1 \
      -regextype posix-extended -regex "$RX_OLD" 2>/dev/null | wc -l)
  [ "$RESTAN" -eq 0 ] && bien "no filename mentions $OLD" "ningun nombre de fichero menciona a $OLD" || mal "$RESTAN names still mention $OLD" "$RESTAN nombres siguen mencionando a $OLD"
fi

# The clipboard: the five components that can break it.
[ -x /usr/local/bin/omarchy-arm-vdagent ] && bien "clipboard agent installed" "agente del portapapeles instalado" || mal "/usr/local/bin/omarchy-arm-vdagent is missing" "falta /usr/local/bin/omarchy-arm-vdagent"
grep -qs -- ' -X ' /etc/systemd/system/spice-vdagentd.service.d/override.conf \
  && bien "spice-vdagentd uses -X" "spice-vdagentd con -X" || mal "spice-vdagentd lacks -X: clipboard will not work" "spice-vdagentd sin -X: el portapapeles no funcionara"
[ -e "/home/$NEW/.config/systemd/user/graphical-session.target.wants/omarchy-arm-vdagent.service" ] \
  && bien "agent enabled in the graphical session" "agente habilitado en la sesion grafica" \
  || mal "the agent was not enabled for $NEW" "el agente no quedo habilitado para $NEW"
if grep -vs -- '^[[:space:]]*--' "/home/$NEW/.config/hypr/autostart.lua" 2>/dev/null | grep -qs spice-vdagent; then
  mal "autostart.lua launches the official agent: vdagentd will disconnect both" "autostart.lua lanza el agente oficial: vdagentd desconectara a los dos"
else
  bien "autostart.lua does not launch the official agent" "autostart.lua no lanza el agente oficial"
fi

[ "$(ls /etc/ssh/ssh_host_* 2>/dev/null | wc -l)" -eq 0 ] && bien "no SSH host keys" "sin claves ssh de host" || mal "SSH host keys remain" "quedan claves ssh de host"

# Binaries compiled inside the VM: the build path remains in their
# Debug info. grep -rl doesn't find them because it looks for text, not symbols.
if [ "$OLD" != "$NEW" ]; then
  # strings may not be available (it comes with binutils); if it's missing, report it and don't
  # invent a verdict.
  if ! command -v strings >/dev/null 2>&1; then
    echo "  ? $(ui_text "binaries in /usr/local/bin: cannot check without 'strings'" "binarios de /usr/local/bin: sin 'strings' no se puede comprobar")"
  else
    SUCIOS=""
    for b in /usr/local/bin/*; do
      [ -f "$b" ] || continue
      strings "$b" 2>/dev/null | grep -q "/home/$OLD" && SUCIOS="$SUCIOS $b"
    done
    [ -z "$SUCIOS" ] && bien "no binary in /usr/local/bin mentions the builder" "ningun binario de /usr/local/bin menciona al constructor" \
                     || mal "binaries contain the builder path:$SUCIOS (see RUSTFLAGS/CARGO_HOME in stage3)" "binarios con la ruta del constructor dentro:$SUCIOS (ver RUSTFLAGS/CARGO_HOME en stage3)"
  fi
fi
[ -f /root/failed-packages.txt ] && mal "/root/failed-packages.txt remains" "queda /root/failed-packages.txt" \
                                 || bien "no builder residue in /root" "sin residuos del constructor en /root"

echo ""
if [ "$FALLOS" -ne 0 ]; then
  echo "==> SANITIZE_FALLO: $(ui_text "$FALLOS broken invariant(s); this image MUST NOT be distributed" "$FALLOS invariante(s) rotos; esta imagen NO se puede distribuir")"
  exit 1
fi
echo ""
echo "==> SANITIZE_OK"
