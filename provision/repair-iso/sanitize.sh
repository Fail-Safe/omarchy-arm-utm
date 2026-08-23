#!/bin/bash
# Sanitizado para distribucion: quita todo lo identificativo del sistema y deja
# un usuario generico. Se ejecuta como ROOT dentro del chroot.
set -uo pipefail
OLD="${DIST_OLD_USER:-gabriel}"
NEW="${DIST_NEW_USER:-omarchy}"
log()  { echo ""; echo "==> $*"; }
warn() { echo "!!  $*" >&2; }

log "1/10 desanclando /usr/share/omarchy del home del usuario"
# Era un symlink a /home/gabriel/.local/share/omarchy, lo que ata el sistema a
# ese usuario. Se convierte en directorio real (como haria el paquete pacman) y
# el home pasa a apuntar ahi.
if [ -L /usr/share/omarchy ]; then
  TARGET=$(readlink -f /usr/share/omarchy)
  rm -f /usr/share/omarchy
  cp -a "$TARGET" /usr/share/omarchy
  chown -R root:root /usr/share/omarchy
  rm -rf "$TARGET"
  echo "  /usr/share/omarchy ahora es un directorio real ($(du -sh /usr/share/omarchy | cut -f1))"
fi

log "2/10 renombrando el usuario $OLD -> $NEW"
if id -u "$OLD" >/dev/null 2>&1; then
  pkill -u "$OLD" 2>/dev/null || true
  usermod -l "$NEW" -d "/home/$NEW" -m "$OLD"
  groupmod -n "$NEW" "$OLD" 2>/dev/null || true
  echo "$NEW:$NEW" | chpasswd
  echo "root:$NEW"  | chpasswd
fi
id "$NEW"
# el home del usuario apunta al arbol del sistema
install -d -o "$NEW" -g "$NEW" "/home/$NEW/.local/share"
rm -rf "/home/$NEW/.local/share/omarchy"
ln -sfn /usr/share/omarchy "/home/$NEW/.local/share/omarchy"
chown -h "$NEW:$NEW" "/home/$NEW/.local/share/omarchy"

log "3/10 SDDM: autologin al usuario generico"
cat > /etc/sddm.conf.d/20-autologin.conf <<EOF
[Autologin]
User=$NEW
Session=omarchy
EOF
grep -rl "$OLD" /etc/sddm.conf.d/ 2>/dev/null | while read -r f; do sed -i "s/\b$OLD\b/$NEW/g" "$f"; done
cat /etc/sddm.conf.d/20-autologin.conf

log "4/10 credenciales y claves"
rm -rf "/home/$NEW/.ssh"
rm -f /etc/ssh/ssh_host_*        # se regeneran solas en el primer arranque
systemctl disable sshd.service 2>/dev/null || true
rm -f /etc/systemd/system/multi-user.target.wants/sshd.service
rm -f /etc/sudoers.d/99-fix /etc/sudoers.d/99-install
rm -rf "/home/$NEW/.gnupg" "/home/$NEW/.local/share/keyrings" "/home/$NEW/.password-store"
echo "  sshd: $(systemctl is-enabled sshd 2>&1)"

log "5/10 identidad de la maquina"
: > /etc/machine-id
rm -f /var/lib/dbus/machine-id
ln -sf /etc/machine-id /var/lib/dbus/machine-id
rm -f /etc/hostname; echo omarchy > /etc/hostname
cat > /etc/hosts <<'EOF'
127.0.0.1   localhost
::1         localhost
127.0.1.1   omarchy.localdomain omarchy
EOF

log "6/10 identidad personal (git, historiales, cache)"
rm -f "/home/$NEW/.gitconfig" "/home/$NEW/.config/git/config"
rm -f "/home/$NEW/.bash_history" "/home/$NEW/.zsh_history" "/home/$NEW/.local/share/fish/fish_history"
rm -rf "/home/$NEW/.cache" "/home/$NEW/.local/state/omarchy/first-run.log"
rm -rf "/home/$NEW/.local/share/omarchy-"* 2>/dev/null || true
rm -rf "/home/$NEW/shots" "/home/$NEW"/*.sh "/home/$NEW/config.env" 2>/dev/null || true
# NetworkManager: quita redes wifi guardadas
rm -f /etc/NetworkManager/system-connections/* 2>/dev/null || true

log "7b/10 apps propietarias fuera de la imagen distribuible"
# Estas se instalan con omarchy-arm-extras en la maquina del usuario final.
# Empaquetarlas en un .zip que se reparte seria redistribuir binarios de
# terceros, asi que se retiran aunque estuvieran en la VM de origen.
for pkg in 1password 1password-cli typora localsend-bin google-chrome obsidian-bin; do
  pacman -Q "$pkg" >/dev/null 2>&1 && { pacman -Rns --noconfirm "$pkg" >/dev/null 2>&1 && echo "  retirado $pkg"; }
done
for d in /opt/1Password /opt/obsidian /opt/typora; do
  [ -e "$d" ] && { rm -rf "$d"; echo "  retirado $d"; }
done
rm -f /usr/local/bin/obsidian /usr/local/share/applications/obsidian.desktop 2>/dev/null || true
# Los rastros que dejan al instalarse: si se retira Chrome hay que retirar
# tambien el atajo y el lanzador de la webapp de Spotify, que lo invocan. Si no,
# la imagen sale con un SUPER+SHIFT+M que apunta a un binario inexistente.
BIND="/home/$NEW/.config/hypr/bindings.lua"
if [ -f "$BIND" ] && grep -q "open.spotify.com" "$BIND"; then
  sed -i '/^-- Spotify no tiene cliente nativo/,/^o.bind("SUPER + SHIFT + M", "Spotify"/d' "$BIND"
  sed -i '/open\.spotify\.com/d' "$BIND"
  echo "  retirado el atajo SUPER+SHIFT+M de la webapp de Spotify"
fi
rm -f "/home/$NEW/.local/share/applications/Spotify.desktop" \
      "/home/$NEW/.local/share/applications/spotify.desktop" 2>/dev/null || true
rm -rf "/home/$NEW/.local/share/omarchy/webapps" 2>/dev/null || true
echo "  (se reinstalan con: omarchy-arm-extras)"

log "7/10 logs y caches del sistema"
rm -rf /var/log/journal/* /var/log/omarchy* /var/log/pacman.log
find /var/log -type f -name "*.log" -delete 2>/dev/null || true
rm -rf /var/cache/pacman/pkg/* /var/tmp/* /tmp/* 2>/dev/null || true
rm -rf /root/prov /root/.bash_history /root/.cache 2>/dev/null || true

log "8/10 aviso al destinatario"
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
install -d -o "$NEW" -g "$NEW" "/home/$NEW/Desktop"
cp /etc/motd "/home/$NEW/Desktop/LEEME.txt"
chown "$NEW:$NEW" "/home/$NEW/Desktop/LEEME.txt"

log "8a/10 hook de actualizacion para ARM"
# omarchy-update-dev no actualiza el arbol cuando OMARCHY_PATH es
# /usr/share/omarchy, que es nuestro caso: sin este hook Omarchy se congela.
if [ -f /root/prov/10-arm-sync ]; then
  install -Dm755 /root/prov/10-arm-sync "/home/$NEW/.config/omarchy/hooks/post-update.d/10-arm-sync"
  chown -R "$NEW:$NEW" "/home/$NEW/.config/omarchy/hooks" 2>/dev/null || true
  echo "  post-update.d/10-arm-sync"
fi
# El checkout no debe ensuciarse por cambios de permisos, o el pull fallara
git -C /usr/share/omarchy config core.fileMode false 2>/dev/null || true
git -C /usr/share/omarchy checkout -- . 2>/dev/null || true
echo "  checkout limpio: $(git -C /usr/share/omarchy status --porcelain 2>/dev/null | wc -l) ficheros"

log "8b/10 instalador de apps opcionales"
# repair.sh copia extras.sh como omarchy-arm-extras, pero si esa copia no
# ocurriera el bloque entero se saltaba en silencio y la imagen salia sin la
# entrada de menu. Se aceptan los dos nombres y se avisa si falta.
EXTRAS_SRC=""
for c in /root/prov/omarchy-arm-extras /root/prov/extras.sh; do
  [ -f "$c" ] && { EXTRAS_SRC="$c"; break; }
done
if [ -n "$EXTRAS_SRC" ]; then
  install -Dm755 "$EXTRAS_SRC" /usr/local/bin/omarchy-arm-extras
  install -Dm644 /dev/stdin /usr/local/share/applications/omarchy-arm-extras.desktop <<'DESK'
[Desktop Entry]
Name=Instalar apps que faltan (ARM)
Comment=1Password, Obsidian, Typora, LocalSend, Chrome, OBS, Pinta
Exec=xdg-terminal-exec omarchy-arm-extras
Icon=system-software-install
Terminal=false
Type=Application
Categories=System;PackageManager;
DESK
  chown "$NEW:$NEW" /usr/local/share/applications/omarchy-arm-extras.desktop 2>/dev/null || true
  echo "  /usr/local/bin/omarchy-arm-extras + entrada en el menu"
else
  warn "el instalador de apps opcionales no venia en el ISO: la imagen saldra sin el"
fi

log "9/10 comprobando que nada quedo atado a $OLD"
echo "  referencias en /etc:"; grep -rl "\b$OLD\b" /etc 2>/dev/null | head -5 || echo "    ninguna"
echo "  home:"; ls -ld "/home/$NEW"; ls /home/
echo "  propietario de ficheros sueltos:"; find /home/$NEW -maxdepth 2 ! -user "$NEW" 2>/dev/null | head -3 || echo "    todo correcto"

log "10/10 liberando espacio no usado (para que comprima mejor)"
sync
fstrim -av 2>&1 | head -3 || true
echo ""
log "ficheros de respaldo de usermod (contienen el usuario y el hash antiguos)"
rm -f /etc/passwd- /etc/shadow- /etc/group- /etc/gshadow-
log "subuid/subgid"
sed -i "s/^$OLD:/$NEW:/" /etc/subuid /etc/subgid 2>/dev/null || true
cat /etc/subuid /etc/subgid 2>/dev/null

log "barrido final de referencias a $OLD"
echo "  /etc:"; grep -rl "\b$OLD\b" /etc 2>/dev/null || echo "    ninguna"
echo "  /home:"; grep -rl "\b$OLD\b" /home/$NEW/.config /home/$NEW/.bashrc 2>/dev/null | head -5 || echo "    ninguna"
echo "  /usr/local/bin:"; grep -rl "\b$OLD\b" /usr/local/bin 2>/dev/null | head -5 || echo "    ninguna"
echo "  /usr/share/omarchy (no debe apuntar a /home):"; ls -ld /usr/share/omarchy

log "coherencia del sistema"
echo "  passwd: $(getent passwd $NEW)"
echo "  home:   $(ls -ld /home/$NEW | awk '{print $3, $4, $9}')"
echo "  symlink omarchy: $(readlink /home/$NEW/.local/share/omarchy)"
echo "  autologin: $(grep -h User= /etc/sddm.conf.d/*.conf 2>/dev/null | tr '\n' ' ')"
echo "  binarios omarchy: $(ls /usr/local/bin | wc -l)"
echo "  ttfx: $(command -v ttfx || echo NO)"
echo "  migraciones selladas: $(ls -1 /home/$NEW/.local/state/omarchy/migrations 2>/dev/null | wc -l)"
sync
echo ""
log "marcadores de Nautilus/GTK apuntando al home antiguo"
for f in /home/$NEW/.config/gtk-3.0/bookmarks /home/$NEW/.config/gtk-4.0/bookmarks; do
  [ -f "$f" ] && { sed -i "s#/home/$OLD#/home/$NEW#g" "$f"; echo "  $f:"; cat "$f"; }
done

log "nombre real en passwd (aparece en el greeter)"
chfn -f "Omarchy" "$NEW" 2>/dev/null || usermod -c "Omarchy" "$NEW"
getent passwd "$NEW"

log "user-dirs con rutas absolutas"
for f in /home/$NEW/.config/user-dirs.dirs; do
  [ -f "$f" ] && sed -i "s#/home/$OLD#/home/$NEW#g" "$f"
done

log "symlinks que apuntan al home antiguo"
# grep -rl solo mira el CONTENIDO de los ficheros: el destino de un enlace
# simbolico no es contenido, asi que el barrido de texto los da por limpios.
# Omarchy guarda el tema y el fondo activos como enlaces
# (~/.local/state/omarchy/current/{theme,background}), de modo que un enlace
# colgado deja el escritorio en gris y sin estilo, sin ningun error visible.
mapfile -t BADLINKS < <(find /home/$NEW /etc /usr/local /opt -xdev -type l \
  -lname "*/home/$OLD/*" 2>/dev/null)
echo "  encontrados: ${#BADLINKS[@]}"
for l in "${BADLINKS[@]:-}"; do
  [ -n "$l" ] || continue
  tgt=$(readlink "$l")
  ln -sfn "${tgt//\/home\/$OLD\//\/home\/$NEW\/}" "$l"
  echo "  $l -> $(readlink "$l")"
done
chown -h $NEW:$NEW "${BADLINKS[@]:-/home/$NEW}" 2>/dev/null || true

log "barrido final"
echo "  /etc:   $(grep -rl "\b$OLD\b" /etc 2>/dev/null | wc -l) coincidencias"
echo "  /home:  $(grep -rl "\b$OLD\b" /home/$NEW/.config /home/$NEW/.bashrc /home/$NEW/.bash_profile 2>/dev/null | wc -l) coincidencias"
echo "  enlaces a /home/$OLD: $(find /home/$NEW /etc /usr/local /opt -xdev -type l -lname "*/home/$OLD/*" 2>/dev/null | wc -l)"
echo "  enlaces rotos en el home: $(find /home/$NEW -xdev -type l ! -exec test -e {} \; -print 2>/dev/null | wc -l)"
echo "  fondo activo: $(readlink -f /home/$NEW/.local/state/omarchy/current/background 2>/dev/null || echo NINGUNO)"
test -e "/home/$NEW/.local/state/omarchy/current/background" \
  && echo "  fondo resuelve: OK" || echo "  fondo resuelve: ROTO"
echo "  (nota: /usr/local/bin/ttfx contiene la ruta de compilacion en su info de"
echo "   depuracion; es inocuo y no expone nada util)"

log "estado final para distribuir"
echo "  usuario:    $(getent passwd $NEW | cut -d: -f1,5,6)"
echo "  autologin:  $(grep -h User= /etc/sddm.conf.d/*.conf 2>/dev/null | sort -u | tr '\n' ' ')"
echo "  sshd:       $(systemctl is-enabled sshd 2>&1)"
echo "  instalador opcional: $(test -x /usr/local/bin/omarchy-arm-extras && echo si || echo FALTA)"
echo "  entrada de menu:     $(test -f /usr/local/share/applications/omarchy-arm-extras.desktop && echo si || echo FALTA)"
echo "  machine-id: $(wc -c < /etc/machine-id) bytes (vacio = se regenera)"
echo ""
echo "  AVISO: a partir de aqui la imagen no debe volver a arrancarse. El primer"
echo "  arranque regenera machine-id, semilla de aleatoriedad y logs, y esos"
echo "  quedarian identicos en todas las copias distribuidas. Si hay que"
echo "  arrancarla para verificar algo, repite esta fase despues."
echo "  claves ssh host: $(ls /etc/ssh/ssh_host_* 2>/dev/null | wc -l) (0 = se regeneran)"
echo "  hostname:   $(cat /etc/hostname)"
sync
fstrim -av 2>&1 | head -2 || true
echo ""
echo ""
echo "==> SANITIZE_OK"
