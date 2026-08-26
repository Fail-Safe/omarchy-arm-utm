#!/usr/bin/env bash
#
#  build-omarchy-arm.sh
#  ────────────────────────────────────────────────────────────────────────────
# Autonomously build, without intervention, a UTM virtual machine with
#  Arch Linux ARM (native aarch64, accelerated with HVF) + Hyprland + the
#  Omarchy 4 configuration, and package it for distribution.
#
#  Omarchy 4 cannot be installed on ARM64, but not for the reasons usually stated.
#  The guard for uname -m lives in install/preflight/guard.sh, which exists in master
#  (3.x) and NOT in quattro, where uname -m does not appear at all. And its package
#  pacman is arch=('any'): what is x86_64-only is the repo where it is published.
#  What is missing is the mirror: stable-mirror.omarchy.org/core/os/aarch64/ returns 404
#  while x86_64 returns 200, and post-install/pacman.sh points pacman there. This
#  rebuilds the equivalent on Arch Linux ARM and applies the actual content
#  of the Omarchy repository.
#
#  Usage:
#    ./build-omarchy-arm.sh                  # all phases
#    ./build-omarchy-arm.sh --from build     # resume from a phase
#    ./build-omarchy-arm.sh --only package   # run only one phase
#    ./build-omarchy-arm.sh --list           # list phases
#
# Phases:
#    deps      check host dependencies
#    fetch     download Alpine ISO + ALARM rootfs (pinned SHA-256 hashes)
#    prepare   calculate the package list from the live Omarchy branch
#    build     build the disk (headless, QEMU + HVF, three stages in chroot)
#    utm       create the .utm bundle and register it in UTM
#    verify    boot and verify via serial console
#    sanitize  clean a copy for distribution
#    package   compact, compress, and sign with SHA-256
#
#  Requirements: macOS on Apple Silicon, Homebrew, UTM 4.7+, Command Line Tools
#  (git, python3) and ~40 GB free. No sudo required.
#  ────────────────────────────────────────────────────────────────────────────
set -uo pipefail

# ───────────────────────────────── parameters ──────────────────────────────
# What variables are already in the environment, BEFORE the ':=' below fill them.
# Without this, there is no way to distinguish "the user passed it" from "it is the default
# value", and detect_from_host was overwriting what the user had set:
# `UTM_MEM=16384 ./build-omarchy-arm.sh --yes` was building with a different value.
FIJADO_POR_ENTORNO=""
for _v in VM_TIMEZONE VM_KEYMAP VM_XKB UTM_CPUS UTM_MEM; do
  [ -n "${!_v:-}" ] && FIJADO_POR_ENTORNO="$FIJADO_POR_ENTORNO $_v"
done
unset _v
del_entorno() { case " $FIJADO_POR_ENTORNO " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

: "${W:=$HOME/omarchy-arm-build}"        # working directory
: "${VM_NAME:=Omarchy ARM}"              # VM name in UTM
: "${VM_USER:=builder}"                  # user during the build
: "${VM_PASSWORD:=builder}"              # prompted; the distributable image renames it
: "${VM_FULLNAME:=Omarchy ARM}"
: "${VM_EMAIL:=usuario@ejemplo.com}"
: "${VM_HOSTNAME:=omarchy}"
: "${VM_TIMEZONE:=Europe/Madrid}"
: "${VM_KEYMAP:=es}"                     # text console
: "${VM_XKB:=es}"                        # Hyprland/Wayland
: "${VM_LOCALE:=en_US.UTF-8}"
: "${VM_LOCALE_EXTRA:=es_ES.UTF-8}"
: "${DISK_SIZE:=80G}"
: "${BUILD_SMP:=8}"                      # vCPUs during the build
: "${BUILD_MEM:=8192}"                   # MiB during the build
: "${UTM_CPUS:=6}"                       # vCPUs in the final VM
: "${UTM_MEM:=6144}"                     # MiB in the final VM
: "${OMARCHY_REF:=quattro}"              # Omarchy branch (NOT master!)
: "${DIST_NEW_USER:=omarchy}"            # user in the distributable image
: "${ALPINE_VER:=v3.24}"
: "${ALPINE_ISO:=alpine-virt-3.24.1-aarch64.iso}"
: "${ALPINE_URL:=https://dl-cdn.alpinelinux.org/alpine/$ALPINE_VER/releases/aarch64/$ALPINE_ISO}"
: "${ALPINE_SHA256:=c81699152db11d2a6dbb7d75348d632fcf5811eff414d7e71876a8bb6d48bc02}"
: "${ALARM_URL:=https://ca.us.mirror.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz}"
: "${ALARM_SHA256:=42a4eeaa038994ffd31fa173256ef2f0ef511358eeb41b9ea1f8626391b9b319}"
: "${ALARM_MIRROR_PRIMARY:=https://ca.us.mirror.archlinuxarm.org}"
: "${ALARM_MIRROR_SECONDARY:=https://fl.us.mirror.archlinuxarm.org}"

UTMCTL=/Applications/UTM.app/Contents/MacOS/utmctl
DOCS="$HOME/Library/Containers/com.utmapp.UTM/Data/Documents"
PHASES=(deps fetch prepare build utm verify sanitize package)

# ─────────────────────────────────── output ────────────────────────────────
c_ok=$'\033[32m'; c_warn=$'\033[33m'; c_err=$'\033[31m'; c_hi=$'\033[1;36m'; c_off=$'\033[0m'
phase() { echo; echo "${c_hi}━━━ $* ━━━${c_off}"; }
info()  { echo "  $*"; }
ok()    { echo "  ${c_ok}✓${c_off} $*"; }
warn()  { echo "  ${c_warn}!${c_off} $*" >&2; }
die()   { echo "  ${c_err}✗ $*${c_off}" >&2; exit 1; }

# ── interaction ─────────────────────────────────────────────────────────────
# The script was born to run unattended and must continue to do so: without a terminal, or with
# --yes, nothing is asked and default values are accepted. With a terminal,
# it asks only what is truly a decision, and nothing else.
INTERACTIVO=0
[[ -t 0 && -t 1 ]] && INTERACTIVO=1
[[ -n ${ASSUME_YES:-} ]] && INTERACTIVO=0

# The questionnaire answers are saved in $W/respuestas.env so that
# --from and --only do not discard them. Previously, resuming would regenerate config.env with the
# default values: the VM would end up with the 'builder' user and its password
# even if the user had typed others, without any warning.
RESPUESTAS_VARS=(VM_NAME VM_USER VM_PASSWORD VM_FULLNAME VM_EMAIL VM_HOSTNAME
                 VM_TIMEZONE VM_KEYMAP VM_XKB VM_LOCALE VM_LOCALE_EXTRA
                 OMARCHY_REF DIST_NEW_USER DISK_SIZE UTM_CPUS UTM_MEM
                 HACER_TOOLS HACER_LIBRES HACER_DIST)

shq() { printf "%s" "${1-}" | sed "s/'/'\\\\''/g"; }

guardar_respuestas() {
  mkdir -p "$W" 2>/dev/null || return 0
  local v
  for v in "${RESPUESTAS_VARS[@]}"; do
    printf "%s='%s'\n" "$v" "$(shq "${!v-}")"
  done > "$W/respuestas.env"
}

cargar_respuestas() {
  [[ -f "$W/respuestas.env" ]] || return 0
  # What is saved MUST NOT overwrite what the user just set in the environment:
  # `UTM_MEM=16384 ./build-omarchy-arm.sh --from utm` must respect the
  # 16384. It is loaded in a subshell, values are read and only those
  # that did not come from the environment are assigned.
  local v val
  for v in "${RESPUESTAS_VARS[@]}"; do
    del_entorno "$v" && continue
    val=$(. "$W/respuestas.env" >/dev/null 2>&1; printf '%s' "${!v-}")
    printf -v "$v" '%s' "$val"
  done
  # NOTE: PHASES are NOT touched here. Trimming it at this point broke four things
  # the time -- the worst, that phase name validation runs BEFORE, so
  # `--from sanitize` (exactly the escape suggested by the ph_verify die) is
  # validated and then executes nothing, exiting with rc=0. The trimming is decided
  # at the end of main, with the final answer already known.
  return 0
}

ask() {  # ask <variable> <question> [default value]
  local var="$1" q="$2" def="${3:-}" cur ans
  cur="${!var:-$def}"
  if (( ! INTERACTIVO )); then printf -v "$var" '%s' "$cur"; return; fi
  read -r -p "  $q [${cur}]: " ans </dev/tty || ans=""
  printf -v "$var" '%s' "${ans:-$cur}"
}

confirm() {  # confirm <question> <yes|no default>
  local q="$1" def="${2:-si}" ans
  if (( ! INTERACTIVO )); then [[ $def == si ]]; return; fi
  read -r -p "  $q [$([[ $def == si ]] && echo 'S/n' || echo 's/N')]: " ans </dev/tty || ans=""
  ans="${ans:-$def}"
  # ${var,,} is bash 4 and macOS ships bash 3.2: there it is an expansion error
  # that aborts the entire function, and confirm returned "yes" by accident.
  ans=$(printf '%s' "$ans" | tr '[:upper:]' '[:lower:]')
  case "$ans" in s|si|sí|y|yes) return 0 ;; *) return 1 ;; esac
}

# Default values taken from Mac itself: so most questions are
# answered with Enter instead of forcing the search for a timezone name.
# The Mac-detected value is a BETTER DEFAULT VALUE, not a command: if the
# user has fixed the variable in the environment, it sends theirs. Before it was assigned without
# condition and, since the `return` in unattended mode comes AFTER this call,
# `UTM_MEM=16384 ./build-omarchy-arm.sh --yes` ended up building with 8192.
detectar_del_anfitrion() {
  local tz kb ncpu ram
  if ! del_entorno VM_TIMEZONE; then
    tz=$(readlink /etc/localtime 2>/dev/null | sed 's#.*/zoneinfo/##')
    [[ -n $tz ]] && VM_TIMEZONE="$tz"
  fi
  # The two are independent: setting only VM_XKB must not leave VM_KEYMAP in the
  # 'es' wired at the beginning.
  if ! del_entorno VM_KEYMAP || ! del_entorno VM_XKB; then
    kb=$(defaults read ~/Library/Preferences/com.apple.HIToolbox.plist AppleSelectedInputSources 2>/dev/null \
         | sed -n 's/.*"KeyboardLayout Name" = "\([^"]*\)".*/\1/p' | head -1)
    local km="" xk=""
    case "$kb" in
      Spanish*)  km=es; xk=es ;;
      U.S.*|ABC*|US*) km=us; xk=us ;;
      British*)  km=uk; xk=gb ;;
      German*)   km=de; xk=de ;;
      French*)   km=fr; xk=fr ;;
      Portuguese*) km=pt; xk=pt ;;
      Italian*)  km=it; xk=it ;;
    esac
    [[ -n $km ]] && ! del_entorno VM_KEYMAP && VM_KEYMAP="$km"
    [[ -n $xk ]] && ! del_entorno VM_XKB    && VM_XKB="$xk"
  fi
  ncpu=$(sysctl -n hw.perflevel0.logicalcpu 2>/dev/null || sysctl -n hw.ncpu)
  ram=$(( $(sysctl -n hw.memsize) / 1024 / 1024 ))
  del_entorno UTM_CPUS || { (( ncpu > 2 )) && UTM_CPUS=$(( ncpu / 2 )); }
  if ! del_entorno UTM_MEM; then
    (( ram >= 16384 )) && UTM_MEM=8192
    (( ram >= 32768 )) && UTM_MEM=12288
  fi
  # BUILD_SMP and BUILD_MEM are not in the list: they belong to the build VM,
  # not the result, and there the interest is to squeeze the Mac.
  BUILD_SMP=$(( ncpu > 8 ? 8 : ncpu ))
  (( ram >= 16384 )) && BUILD_MEM=8192
  return 0
}

# ─────────────────────────────── phase: deps ────────────────────────────────
ph_deps() {
  phase "deps · dependencias del anfitrion"
  [[ $(uname -s) == Darwin ]] || die "esto solo corre en macOS"
  [[ $(uname -m) == arm64  ]] || die "hace falta Apple Silicon (HVF para aarch64)"
  command -v brew >/dev/null || die "falta Homebrew: https://brew.sh"
  for f in qemu expect aria2; do
    brew list --formula "$f" >/dev/null 2>&1 || { info "instalando $f..."; brew install "$f" >/dev/null; }
  done
  command -v qemu-system-aarch64 >/dev/null || die "falta qemu-system-aarch64"
  command -v expect >/dev/null || die "falta expect"
  # git and python3 come from the Command Line Tools, which on a freshly
  # set up Mac are not present. They are used in 'prepare' and in branch checking.
  for c in git python3 zip shasum curl hdiutil; do
    command -v "$c" >/dev/null || die "falta '$c' (¿ejecutaste 'xcode-select --install'?)"
  done
  [[ -x $UTMCTL ]] || die "falta UTM: brew install --cask utm"
  # Measured in a real build: the disk reaches 9.5 GB, the copy for
  # sanitizing to another 6.5 and the zip to 4. With APFS clones the peak is around 30.
  local free; free=$(df -g "$HOME" | tail -1 | awk '{print $4}')
  (( free > 40 )) || die "hacen falta ~40 GB libres (hay ${free} GB)"
  ok "qemu $(qemu-system-aarch64 --version | head -1 | awk '{print $4}'), UTM $(defaults read /Applications/UTM.app/Contents/Info.plist CFBundleShortVersionString), ${free} GB libres"
}

# Any phase can be run standalone with --only/--from, so the directories
# they cannot depend on deps having been passed.
ensure_dirs() { mkdir -p "$W"/{dl,vm,provision,scripts,logs,dist,shots}; }

# ─────────────────────────────── phase: fetch ───────────────────────────────
sha256_file() { shasum -a 256 "$1" | awk '{print $1}'; }

validate_sha256() {
  local digest="$1" label="$2"
  [[ $digest =~ ^[0-9a-fA-F]{64}$ ]] \
    || die "sha256 no valido para $label: se esperaban 64 digitos hexadecimales"
}

validate_fetch_url() {
  case "$1" in
    https://*|file://*) ;;
    *) die "URL no segura para $2: solo se permiten https:// y file://" ;;
  esac
}

verify_sha256() {
  local file="$1" expected="$2" label="$3" got
  validate_sha256 "$expected" "$label"
  expected=$(printf '%s' "$expected" | tr 'A-F' 'a-f')
  got=$(sha256_file "$file") || { warn "no se pudo calcular el sha256 de $label"; return 1; }
  if [[ $got != "$expected" ]]; then
    warn "$label no cuadra con el sha256 fijado (esperado $expected, obtenido $got)"
    return 1
  fi
}

fetch_verified() {
  local url="$1" expected="$2" dest="$3" label="$4"
  local partial="$dest.partial"
  validate_fetch_url "$url" "$label"
  validate_sha256 "$expected" "$label"

  if [[ -s $dest ]]; then
    verify_sha256 "$dest" "$expected" "$label" \
      || die "$label en cache no supera la verificacion; se conserva en $dest para inspeccion"
    ok "$label en cache, sha256 verificado ($(du -h "$dest" | cut -f1))"
    return 0
  fi

  info "$label"
  if ! aria2c -x8 -s8 -c --file-allocation=none -q \
      -d "$(dirname "$partial")" -o "$(basename "$partial")" "$url"; then
    die "no se pudo descargar $label ($url); la descarga parcial se conserva para reanudar"
  fi
  if ! verify_sha256 "$partial" "$expected" "$label"; then
    rm -f "$partial" "$partial.aria2"
    die "se rechazo la descarga de $label"
  fi
  mv "$partial" "$dest"
  rm -f "$partial.aria2"
  ok "$label descargado, sha256 verificado ($(du -h "$dest" | cut -f1))"
}

ph_fetch() {
  phase "fetch · imagenes base"
  local iso="$W/dl/alpine-virt-aarch64.iso"
  local tgz="$W/dl/alarm-rootfs.tgz"

  fetch_verified "$ALPINE_URL" "$ALPINE_SHA256" "$iso" \
    "Alpine $ALPINE_ISO (entorno live para el bootstrap)"
  fetch_verified "$ALARM_URL" "$ALARM_SHA256" "$tgz" \
    "rootfs de Arch Linux ARM"
}

# ────────────────────────────── phase: prepare ──────────────────────────────
ph_prepare() {
  phase "prepare · lista de paquetes"
  # quattro is a pre-release branch: when it is merged or deleted, everything that
  # follows fails without stating why. It is checked beforehand and falls back to the
  # repository's default branch, with a warning.
  if ! git ls-remote --exit-code --heads https://github.com/basecamp/omarchy.git "$OMARCHY_REF" >/dev/null 2>&1; then
    local defref
    defref=$(git ls-remote --symref https://github.com/basecamp/omarchy.git HEAD 2>/dev/null \
             | sed -n 's#^ref: refs/heads/\([^\t ]*\).*#\1#p' | head -1)
    [[ -n $defref ]] || die "la rama '$OMARCHY_REF' no existe y no pude leer la rama por defecto de Omarchy"
    warn "la rama '$OMARCHY_REF' ya no existe en Omarchy; se usa '$defref'"
    warn "revisa que la estructura no haya cambiado: este build asume Omarchy 4"
    OMARCHY_REF="$defref"
  fi
  # The list is computed against the VIVA branch of Omarchy intersected with what
  # exists in Arch Linux ARM. Doing it here, rather than with a fixed list, prevents the
  # build from breaking when Omarchy changes packages.
  local base=/tmp/om-base.$$ core=/tmp/alarm-core.$$ extra=/tmp/alarm-extra.$$
  curl -fsSL --max-time 60 \
    "https://raw.githubusercontent.com/basecamp/omarchy/$OMARCHY_REF/install/omarchy-base.packages" \
    -o "$base" || die "no se pudo leer la lista de paquetes de Omarchy"
  validate_fetch_url "$ALARM_MIRROR_PRIMARY" "mirror primario de Arch Linux ARM"
  validate_fetch_url "$ALARM_MIRROR_SECONDARY" "mirror secundario de Arch Linux ARM"
  curl -fsSL --max-time 120 "$ALARM_MIRROR_PRIMARY/aarch64/core/core.db" -o "$core" \
    || curl -fsSL --max-time 120 "$ALARM_MIRROR_SECONDARY/aarch64/core/core.db" -o "$core" \
    || die "los mirrors HTTPS de ALARM no responden para core.db"
  curl -fsSL --max-time 180 "$ALARM_MIRROR_PRIMARY/aarch64/extra/extra.db" -o "$extra" \
    || curl -fsSL --max-time 180 "$ALARM_MIRROR_SECONDARY/aarch64/extra/extra.db" -o "$extra" \
    || die "los mirrors HTTPS de ALARM no responden para extra.db"

  local d=/tmp/alarmdb.$$; rm -rf "$d"; mkdir -p "$d"; ( cd "$d" && tar -xzf "$core"; tar -xzf "$extra" )
  ls -1 "$d" | sed -E 's/-[^-]+-[^-]+$//' | sort -u > /tmp/alarm-pkgs.$$

  # quickshell-git does not exist in ALARM; quickshell 0.3.x replaces it.
  # nvim and ttf-jetbrains-mono-nerd-basic are proper names from Omarchy.
  python3 - "$base" /tmp/alarm-pkgs.$$ "$W/provision" <<'PYEOF'
import sys, pathlib
base, alarm_f, out = sys.argv[1], sys.argv[2], pathlib.Path(sys.argv[3])
alarm = set(open(alarm_f).read().split())
subs = {'quickshell-git':'quickshell','ttf-jetbrains-mono-nerd-basic':'ttf-jetbrains-mono-nerd','nvim':'neovim'}
pkgs = [l.strip() for l in open(base) if l.strip() and not l.startswith('#')]
infra = """mesa vulkan-swrast vulkan-icd-loader xorg-xwayland qt6-wayland qt5-wayland
pipewire pipewire-pulse pipewire-alsa pipewire-jack wireplumber xdg-user-dirs xdg-utils polkit
sddm uwsm hypridle hyprlock hyprpaper hyprshot swaybg wl-clipboard slurp satty
noto-fonts noto-fonts-cjk noto-fonts-emoji terminus-font woff2-font-awesome
go nodejs npm python openssh htop wget curl unzip zip rsync mesa-utils wayland-utils pacman-contrib
phodav davfs2
networkmanager btrfs-progs efibootmgr spice-vdagent qemu-guest-agent""".split()
heavy = set("""libreoffice-fresh kdenlive signal-desktop obs-studio moonlight-qt tesseract
tesseract-data-eng gpu-screen-recorder xournalpp evince system-config-printer cups cups-browsed
cups-filters cups-pdf docker docker-buildx docker-compose rust ruby clang llvm luarocks
mariadb-libs postgresql-libs python-poetry-core tree-sitter-cli usage ufw fcitx5 fcitx5-gtk
fcitx5-qt bolt kernel-modules-hook ffmpegthumbnailer lazydocker firefox dotnet-runtime""".split())
core, ext, miss = [], [], []
for p in pkgs + infra:
    p = subs.get(p, p)
    if p not in alarm: miss.append(p); continue
    (ext if p in heavy else core).append(p)
def dd(xs):
    s=set(); o=[]
    for x in xs:
        if x not in s: s.add(x); o.append(x)
    return o
core, ext = dd(core), dd(ext)
(out/'packages-core.txt').write_text("# nucleo\n"+"\n".join(core)+"\n")
(out/'packages-extra.txt').write_text("# extras best-effort\n"+"\n".join(ext)+"\n")
print(f"  nucleo={len(core)}  extras={len(ext)}  sin equivalente en ARM={len(set(miss))}")
print("  no disponibles:", " ".join(sorted(set(miss))))
PYEOF
  rm -rf "$d" "$base" "$core" "$extra" /tmp/alarm-pkgs.$$
  # Without this, a write error would go unnoticed and the build would die later,
  # far from the cause.
  [ -s "$W/provision/packages-core.txt" ] || die "no se pudieron escribir las listas de paquetes"
  ok "listas generadas contra la rama '$OMARCHY_REF': $(grep -cvE '^#|^$' "$W/provision/packages-core.txt") en el nucleo, $(grep -cvE '^#|^$' "$W/provision/packages-extra.txt") extras"
}

# ─────────────────────────── payloads (written to $W) ──────────────────
write_payloads() {
  # Provision files and expect harnesses are materialized here so that
  # this script is self-contained: a single file reproduces the entire process.
mkdir -p "$W/provision"
cat > "$W/provision/stage1.sh" <<'__PAYLOAD_PROVISION_STAGE1_SH__'
#!/bin/sh
# Stage 1 — runs on the Alpine live environment (busybox ash).
# Partitions the disk, deploys the Arch Linux ARM rootfs, and enters chroot.
set -eu
PROV=/media/prov
log()  { echo ""; echo "==> [stage1] $*"; }
warn() { echo "!!  [stage1] $*"; }

# Reliable exit marker: a pipe to tee masks the return code,
# so the script itself emits the token.
trap 'rc=$?; [ "$rc" -ne 0 ] && echo "TOK_BUILD_$rc"' EXIT

log "red"
ip link set eth0 up 2>/dev/null || true
udhcpc -i eth0 -q -n -t 15 >/dev/null 2>&1 || true
ip -4 addr show eth0 | grep -o 'inet [0-9.]*' || echo "  (sin IPv4)"

log "repositorios y herramientas de Alpine"
V=$(cut -d. -f1,2 < /etc/alpine-release)
cat > /etc/apk/repositories <<EOF
https://dl-cdn.alpinelinux.org/alpine/v$V/main
https://dl-cdn.alpinelinux.org/alpine/v$V/community
EOF
apk update >/dev/null
apk add --no-cache parted dosfstools btrfs-progs libarchive-tools e2fsprogs >/dev/null
echo "  ok: $(parted --version | head -1)"

log "cargando modulos de sistema de ficheros del kernel del live"
for m in btrfs vfat fat nls_cp437 nls_iso8859-1 nls_utf8 crc32c-generic xxhash_generic; do
  modprobe "$m" 2>/dev/null || true
done
if grep -qw btrfs /proc/filesystems; then
  ROOTFS=btrfs
else
  warn "btrfs no disponible en el kernel del live -> se usara ext4 para la raiz"
  ROOTFS=ext4
fi
grep -qw vfat /proc/filesystems || warn "vfat no listado en /proc/filesystems"
echo "  raiz: $ROOTFS   filesystems: $(tr '\n' ' ' < /proc/filesystems | tr -s ' ')"

log "particionando $DISK (GPT: ESP 1GiB + raiz $ROOTFS)"
umount -R /mnt 2>/dev/null || true
wipefs -a "$DISK" >/dev/null 2>&1 || true
parted -s "$DISK" mklabel gpt
parted -s "$DISK" mkpart OMBOOT fat32 1MiB 1025MiB
parted -s "$DISK" set 1 esp on
parted -s "$DISK" mkpart OMROOT "$ROOTFS" 1025MiB 100%
sync; sleep 1
mkfs.vfat -F32 -n OMBOOT "${DISK}1" >/dev/null
if [ "$ROOTFS" = btrfs ]; then
  mkfs.btrfs -f -L OMROOT "${DISK}2" >/dev/null
else
  mkfs.ext4 -qF -L OMROOT "${DISK}2"
fi
sync
parted -s "$DISK" print

MOPT_ROOT=""
if [ "$ROOTFS" = btrfs ]; then
  log "subvolumenes btrfs @ y @home"
  mount -t btrfs "${DISK}2" /mnt
  btrfs subvolume create /mnt/@     >/dev/null
  btrfs subvolume create /mnt/@home >/dev/null
  umount /mnt
  MOPT="rw,noatime,compress=zstd:3"
  mount -t btrfs -o "$MOPT,subvol=@" "${DISK}2" /mnt
  mkdir -p /mnt/home
  mount -t btrfs -o "$MOPT,subvol=@home" "${DISK}2" /mnt/home
  MOPT_ROOT="$MOPT,subvol=@"
else
  mount -t ext4 "${DISK}2" /mnt
  mkdir -p /mnt/home
  MOPT_ROOT="rw,noatime"
fi
df -h /mnt

log "desplegando rootfs de Arch Linux ARM (bsdtar -xpf, preserva xattr/ACL)"
# The ESP is mounted AFTER: vfat does not support the symlinks included in /boot in the
# tarball. The kernel is repopulated by pacman in stage2 on the already-mounted ESP.
bsdtar -xpf "$PROV/alarm-rootfs.tgz" -C /mnt
echo "  contenido: $(ls /mnt | tr '\n' ' ')"
[ -d /mnt/etc ] && [ -d /mnt/usr ] || { warn "rootfs incompleto"; exit 1; }

log "montando la ESP en /boot"
rm -rf /mnt/boot
mkdir -p /mnt/boot
mount -t vfat "${DISK}1" /mnt/boot
df -h /mnt /mnt/boot

log "montajes del chroot"
for d in proc sys dev run tmp; do mkdir -p "/mnt/$d"; done
mount -t proc  none /mnt/proc
mount -t sysfs none /mnt/sys
mount --rbind /dev /mnt/dev
mount --make-rslave /mnt/dev
mount -t tmpfs none /mnt/run
mount -t tmpfs -o size=4G none /mnt/tmp
mkdir -p /mnt/dev/pts && mount -t devpts none /mnt/dev/pts 2>/dev/null || true

log "DNS dentro del chroot"
rm -f /mnt/etc/resolv.conf
printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > /mnt/etc/resolv.conf

log "copiando payload"
mkdir -p /mnt/root/prov
cp "$PROV/stage2.sh" "$PROV/stage3.sh" "$PROV/config.env" \
   "$PROV/packages-core.txt" "$PROV/packages-extra.txt" /mnt/root/prov/
[ -f "$PROV/extras.sh" ] && cp "$PROV/extras.sh" /mnt/root/prov/omarchy-arm-extras
[ -f "$PROV/armsync.sh" ] && cp "$PROV/armsync.sh" /mnt/root/prov/10-arm-sync
[ -f "$PROV/clipbrd.sh" ] && cp "$PROV/clipbrd.sh" /mnt/root/prov/omarchy-arm-clipboard
[ -f "$PROV/vdagent.py" ] && cp "$PROV/vdagent.py" /mnt/root/prov/omarchy-arm-vdagent
[ -f "$PROV/share.sh" ] && cp "$PROV/share.sh" /mnt/root/prov/omarchy-arm-share
cat > /mnt/root/prov/fsinfo.env <<EOF
ROOTFS=$ROOTFS
ROOT_MOUNT_OPTS=$MOPT_ROOT
EOF
chmod +x /mnt/root/prov/stage2.sh /mnt/root/prov/stage3.sh

log "entrando en chroot -> stage2"
set +e
chroot /mnt /bin/bash /root/prov/stage2.sh
rc=$?
set -e

log "desmontando"
sync
umount -R /mnt/tmp /mnt/run /mnt/dev /mnt/sys /mnt/proc 2>/dev/null || true
umount -R /mnt/boot 2>/dev/null || true
umount -R /mnt 2>/dev/null || umount -l /mnt
sync
echo "==> [stage1] terminado rc=$rc"
echo "TOK_BUILD_$rc"
trap - EXIT
exit $rc
__PAYLOAD_PROVISION_STAGE1_SH__
chmod +x "$W/provision/stage1.sh"

mkdir -p "$W/provision"
cat > "$W/provision/stage2.sh" <<'__PAYLOAD_PROVISION_STAGE2_SH__'
#!/bin/bash
# Stage 2 — inside the Arch Linux ARM chroot, as root.
# Base system, kernel, UEFI boot, Omarchy stack packages, and login.
set -euo pipefail
. /root/prov/config.env
. /root/prov/fsinfo.env
export LANG=C LC_ALL=C

log()  { echo ""; echo "==> [stage2] $*"; }
warn() { echo "!!  [stage2] $*"; }

trap 'warn "fallo en la linea $LINENO"; exit 1' ERR

# ---------------------------------------------------------------- pacman
log "inicializando el llavero de Arch Linux ARM"
pacman-key --init
pacman-key --populate archlinuxarm

# The mirrors included in the tarball use HTTP. Although pacman verifies the signature of
# each package, TLS also protects the index, version selection, and
# availability. Two official mirrors with valid certificates are set.
: "${ALARM_MIRROR_PRIMARY:=https://ca.us.mirror.archlinuxarm.org}"
: "${ALARM_MIRROR_SECONDARY:=https://fl.us.mirror.archlinuxarm.org}"
case "$ALARM_MIRROR_PRIMARY" in https://*) ;; *) warn "el mirror primario debe usar HTTPS"; exit 1 ;; esac
case "$ALARM_MIRROR_SECONDARY" in https://*) ;; *) warn "el mirror secundario debe usar HTTPS"; exit 1 ;; esac
{
  printf 'Server = %s/$arch/$repo\n' "$ALARM_MIRROR_PRIMARY"
  printf 'Server = %s/$arch/$repo\n' "$ALARM_MIRROR_SECONDARY"
} > /etc/pacman.d/mirrorlist
# A one-hour build cannot fail because a mirror hangs for ten
# seconds. DisableDownloadTimeout keeps retries useful and pacman
# maintains cryptographic verification for each package.
# DisableDownloadTimeout in pacman.conf, not as a standalone flag: this way it is inherited by
# ALL invocations, including the one makepkg -s performs internally to
# resolve build dependencies.
grep -q '^DisableDownloadTimeout' /etc/pacman.conf \
  || sed -i 's/^\[options\]/[options]\nDisableDownloadTimeout\nParallelDownloads = 5/' /etc/pacman.conf

# Retry wrapper: the mirror fails in bursts, not consistently.
pac() {
  local intento
  for intento in 1 2 3; do
    if pacman -S --noconfirm --needed --disable-download-timeout "$@"; then return 0; fi
    warn "pacman fallo (intento $intento/3); reintentando en ${intento}0 s"
    sleep "${intento}0"
    pacman -Sy --noconfirm --disable-download-timeout >/dev/null 2>&1 || true
  done
  return 1
}

log "actualizando el sistema (el tarball es de agosto, los repos van al dia)"
pacman -Syu --noconfirm --needed --disable-download-timeout \
  || pacman -Syu --noconfirm --needed --disable-download-timeout

log "sistema base"
# linux-firmware is intentionally omitted: ~800 MB useless in a VM
pac base base-devel linux-aarch64 \
  sudo git vim networkmanager openssh which man-db man-pages less \
  btrfs-progs dosfstools e2fsprogs efibootmgr \
  rsync wget curl unzip zip

# ---------------------------------------------------------------- localization
log "zona horaria, locales, teclado, hostname"
ln -sf "/usr/share/zoneinfo/$VM_TIMEZONE" /etc/localtime
sed -i "s/^#\(${VM_LOCALE} \)/\1/; s/^#\(${VM_LOCALE_EXTRA} \)/\1/" /etc/locale.gen
grep -q "^${VM_LOCALE} " /etc/locale.gen || echo "${VM_LOCALE} UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=$VM_LOCALE" > /etc/locale.conf
# Hyprland reads XKBLAYOUT from here (default/hypr/input.lua); KEYMAP only
# covers the text console.
printf 'KEYMAP=%s\nXKBLAYOUT=%s\n' "$VM_KEYMAP" "$VM_XKB" > /etc/vconsole.conf
echo "$VM_HOSTNAME" > /etc/hostname
cat > /etc/hosts <<EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   $VM_HOSTNAME.localdomain $VM_HOSTNAME
EOF
systemd-machine-id-setup || true

# ---------------------------------------------------------------- fstab
log "fstab"
if [ "$ROOTFS" = btrfs ]; then
cat > /etc/fstab <<EOF
LABEL=OMROOT  /      btrfs  rw,noatime,compress=zstd:3,subvol=@         0 0
LABEL=OMROOT  /home  btrfs  rw,noatime,compress=zstd:3,subvol=@home     0 0
LABEL=OMBOOT  /boot  vfat   rw,noatime,fmask=0137,dmask=0027,utf8=true  0 2
EOF
KERNEL_ROOTFLAGS="rootflags=subvol=@"
else
cat > /etc/fstab <<EOF
LABEL=OMROOT  /      ext4   rw,noatime                                  0 1
LABEL=OMBOOT  /boot  vfat   rw,noatime,fmask=0137,dmask=0027,utf8=true  0 2
EOF
KERNEL_ROOTFLAGS=""
fi
cat /etc/fstab

# ---------------------------------------------------------------- user
log "usuario $VM_USER"
userdel -r alarm 2>/dev/null || true
if ! id -u "$VM_USER" >/dev/null 2>&1; then
  useradd -m -G wheel,video,audio,input,storage,network,lp -s /bin/bash -c "$VM_FULLNAME" "$VM_USER"
fi
echo "$VM_USER:$VM_PASSWORD" | chpasswd
echo "root:$VM_PASSWORD"     | chpasswd
install -m 0440 /dev/stdin /etc/sudoers.d/10-wheel <<<'%wheel ALL=(ALL:ALL) ALL'
# no password only during installation; removed at the end
install -m 0440 /dev/stdin /etc/sudoers.d/99-install <<<"$VM_USER ALL=(ALL:ALL) NOPASSWD: ALL"

# ---------------------------------------------------------------- initramfs
log "mkinitcpio (modulos virtio + btrfs)"
sed -i 's/^MODULES=.*/MODULES=(virtio virtio_pci virtio_blk virtio_scsi virtio_net virtio_gpu 9p 9pnet 9pnet_virtio btrfs ext4)/' /etc/mkinitcpio.conf
grep -q '^MODULES=' /etc/mkinitcpio.conf || echo 'MODULES=(virtio virtio_pci virtio_blk virtio_gpu 9p 9pnet_virtio btrfs)' >> /etc/mkinitcpio.conf
mkinitcpio -P
echo "  /boot:"; ls -la /boot

# ---------------------------------------------------------------- UEFI boot
log "systemd-boot en la ESP"
# --no-variables: we do not write to NVRAM; UTM boots via the fallback path
# \EFI\BOOT\BOOTAA64.EFI, which bootctl installs as well.
bootctl --esp-path=/boot --no-variables install

# The ESP is mounted empty AFTER extracting the rootfs, so /boot has no kernel.
# "pacman -S --needed" does not reinstall it if the installed version already matches
# the one in the repository, so the package reinstall is forced.
if [ ! -f /boot/Image ] && [ ! -f /boot/vmlinuz-linux-aarch64 ]; then
  echo "  /boot vacio: reinstalando linux-aarch64 para repoblarlo"
  pacman -S --noconfirm --disable-download-timeout linux-aarch64 || warn "no se pudo reinstalar el kernel"
  mkinitcpio -P || warn "mkinitcpio fallo tras reinstalar"
fi

KERNEL_IMG=""
for c in /boot/Image /boot/vmlinuz-linux-aarch64 /boot/Image.gz; do
  [ -f "$c" ] && { KERNEL_IMG="/$(basename "$c")"; break; }
done
[ -n "$KERNEL_IMG" ] || { warn "no encuentro la imagen del kernel en /boot"; ls -la /boot; exit 1; }

INITRD=""
for c in /boot/initramfs-linux-aarch64.img /boot/initramfs-linux.img; do
  [ -f "$c" ] && { INITRD="/$(basename "$c")"; break; }
done
[ -n "$INITRD" ] || { warn "no encuentro el initramfs"; ls -la /boot; exit 1; }

mkdir -p /boot/loader/entries
cat > /boot/loader/loader.conf <<EOF
default  omarchy.conf
timeout  1
console-mode keep
editor   no
EOF
cat > /boot/loader/entries/omarchy.conf <<EOF
title    Arch Linux ARM — Omarchy
linux    $KERNEL_IMG
initrd   $INITRD
options  root=LABEL=OMROOT $KERNEL_ROOTFLAGS rw quiet loglevel=3
EOF
cat > /boot/loader/entries/omarchy-verbose.conf <<EOF
title    Arch Linux ARM — Omarchy (verboso)
linux    $KERNEL_IMG
initrd   $INITRD
options  root=LABEL=OMROOT $KERNEL_ROOTFLAGS rw
EOF
echo "  kernel=$KERNEL_IMG initrd=$INITRD"
echo "  ESP:"; find /boot/EFI /boot/loader -maxdepth 3 | sort

# ---------------------------------------------------------------- networking
log "red: NetworkManager (se desactiva systemd-networkd del tarball)"
systemctl disable systemd-networkd.service systemd-networkd.socket 2>/dev/null || true
systemctl disable systemd-resolved.service 2>/dev/null || true
rm -f /etc/systemd/network/*.network 2>/dev/null || true
systemctl enable NetworkManager.service
systemctl enable systemd-timesyncd.service 2>/dev/null || true

# ---------------------------------------------------------------- desktop
log "instalando el stack de escritorio (Hyprland + herramientas de Omarchy)"
install_list() {
  local file="$1" label="$2" fatal="$3"
  mapfile -t PKGS < <(grep -vE '^\s*#|^\s*$' "$file")
  echo "  $label: ${#PKGS[@]} paquetes"
  if pac "${PKGS[@]}"; then return 0; fi
  warn "$label: instalacion en bloque fallida tras 3 intentos; probando uno a uno"
  local FAILED=()
  for p in "${PKGS[@]}"; do
    pacman -S --noconfirm --needed --disable-download-timeout "$p" >/dev/null 2>&1 && continue
    # Retry failed packages: the mirror, not the package, is usually at fault.
    sleep 3
    pacman -S --noconfirm --needed --disable-download-timeout "$p" >/dev/null 2>&1 || FAILED+=("$p")
  done
  if [ ${#FAILED[@]} -gt 0 ]; then
    warn "$label no instalados: ${FAILED[*]}"
    printf '%s\n' "${FAILED[@]}" >> /root/failed-packages.txt
    [ "$fatal" = fatal ] && return 1
  fi
  return 0
}
install_list /root/prov/packages-core.txt  "nucleo" fatal
set +e
install_list /root/prov/packages-extra.txt "extras" soft
set -e

log "servicios de sistema"
systemctl enable sddm.service 2>/dev/null || warn "sddm no disponible"
# UTM integration: utmctl ip-address/exec/file require the guest agent
systemctl enable qemu-guest-agent.service 2>/dev/null || true
# The Arch Linux ARM rootfs comes with sshd started, and here we install
# openssh and set the same trivial password for the user and root. A personal VM
# (without the sanitize phase, which is where the only disable was) would
# remain listening with omarchy/omarchy. It is stopped by default; if you want it:
#   sudo systemctl enable --now sshd
systemctl disable sshd.service 2>/dev/null || true
systemctl disable sshd.socket  2>/dev/null || true
# The SPICE clipboard has THREE components, not two:
#   SPICE client (UTM) <-virtio port-> spice-vdagentd <-unix socket-> agent
# The daemon is what communicates with the host; the session agent only talks
# to the daemon. That is why you must keep spice-vdagentd alive even though its official
# agent (X11) is incompatible with Hyprland: replace the agent, not the
# daemon.
#
# And -X is needed: the "active seat0 session" check
# (vdagentd.c:746, systemd-login.c:272) fails with Hyprland launched by SDDM, and
# then the daemon silently discards the clipboard.
mkdir -p /etc/systemd/system/spice-vdagentd.service.d
cat > /etc/systemd/system/spice-vdagentd.service.d/override.conf <<'OVR'
[Service]
# -X: without logind integration. Without this, the daemon cannot find the "active
# seat0 session" under Hyprland and discards the clipboard without warning.
ExecStart=
ExecStart=/usr/bin/spice-vdagentd -X -x -f
OVR
systemctl enable spice-vdagentd.service 2>/dev/null || true
systemctl enable spice-vdagentd.socket 2>/dev/null || true
echo "  spice-vdagentd con -X (necesario bajo Hyprland)"

# No udev rule is installed for /dev/virtio-ports/com.redhat.spice.0.
# There was one, and it was wrong in two ways: omarchy-arm-vdagent never opens that
# port —it communicates via the unix socket /run/spice-vdagentd/spice-vdagent-sock,
# as stage3 itself explains—, and the port is exclusively opened by the daemon.
# Granting the seat user an ACL with TAG+="uaccess" only allows another process
# to take the port from the daemon and leave it without a channel ("Device or resource
# busy"), which is precisely the first dead end of this problem.
# MODE="0660" additionally did nothing: without GROUP=, the group remains root.

# UTM's shared folder has TWO modes, and the user chooses which one:
#   VirtFS → 9p device with mount_tag "share"
#   SPICE WebDAV → virtio port org.spice-space.webdav.0, served by
#     spice-webdavd (phodav package) at http://localhost:9843/
# Both are prepared: each activates only if its device exists.
systemctl enable spice-webdavd.service 2>/dev/null || true
echo "  spice-webdavd habilitado (modo SPICE WebDAV de UTM)"

# UTM shared folder. The bundle declares DirectoryShareMode=VirtFS, but
# this only exposes the device: the guest must mount it. The tag is
# "share" (UTM, Configuration/UTMQemuConfiguration+Arguments.swift:1234).
# nofail so that a boot without a configured shared folder does not drop to emergency,
# and x-systemd.automount to avoid the cost of mounting if it is not used.
mkdir -p /mnt/share
# The fstab entry is only valid for VirtFS, and the user may have chosen
# SPICE WebDAV. Instead of fixing a mode, omarchy-arm-share is installed, which
# detects which one is active. The fstab entry is left with nofail:
# if the 9p device exists, it is mounted only at boot.
if ! grep -q '^share ' /etc/fstab; then
  cat >> /etc/fstab <<'FSTAB'

# Shared folder of UTM in VirtFS mode. If you chose SPICE WebDAV, this
# line does nothing (nofail) and mounts omarchy-arm-share.
share  /mnt/share  9p  trans=virtio,version=9p2000.L,rw,nofail,x-systemd.automount,_netdev,msize=512000  0  0
FSTAB
fi
echo "  /mnt/share preparado (VirtFS por fstab, WebDAV con omarchy-arm-share)"
systemctl enable bluetooth.service 2>/dev/null || true
systemctl enable docker.service 2>/dev/null || true
usermod -aG docker "$VM_USER" 2>/dev/null || true

# ---------------------------------------------------------------- dotfiles
log "etapa 3: dotfiles de Omarchy como $VM_USER"
chmod +x /root/prov/stage3.sh
install -d -o "$VM_USER" -g "$VM_USER" "/home/$VM_USER"
# stage3 runs as a normal user and /root is 0750: any test you perform on
# /root/prov returns false without error. A readable copy is left in their home.
PROVDIR="/home/$VM_USER/.omarchy-arm-prov"
mkdir -p "$PROVDIR"
for f in omarchy-arm-extras 10-arm-sync omarchy-arm-clipboard omarchy-arm-vdagent omarchy-arm-share; do
  [ -f "/root/prov/$f" ] && install -m 0644 "/root/prov/$f" "$PROVDIR/$f"
done
cp /root/prov/stage3.sh /root/prov/config.env "/home/$VM_USER/"
chown -R "$VM_USER:$VM_USER" "$PROVDIR"
chown "$VM_USER:$VM_USER" "/home/$VM_USER/stage3.sh" "/home/$VM_USER/config.env"
echo "  disponible para stage3: $(ls "$PROVDIR" | tr '\n' ' ')"
# The result of stage3 must reach the host: previously it degraded to a
# warn and stage2 emitted its success token anyway, so a completely failed stage3
# produced a disk with not a single Omarchy dotfile declared OK.
# NOTE: with `set -e` + trap ERR, writing `su ...; RC=$?` does NOT work: if su
# returns != 0 the trap triggers and the stage dies BEFORE the assignment, so
# TOK_STAGE3_<rc> was emitted only when rc=0, and the host never
# saw the specific failure of stage3. With `|| RC=$?` the command is
# in a tested context, so set -e does not trigger.
STAGE3_RC=0
su - "$VM_USER" -c "bash ~/stage3.sh" || STAGE3_RC=$?
[ $STAGE3_RC -eq 0 ] || warn "stage3 termino con errores (rc=$STAGE3_RC)"
echo "TOK_STAGE3_$STAGE3_RC"
rm -f "/home/$VM_USER/stage3.sh" "/home/$VM_USER/config.env"
rm -rf "$PROVDIR"

# ---------------------------------------------------------------- login SDDM
log "SDDM: sesion Omarchy con autologin"
OM="/home/$VM_USER/.local/share/omarchy"
mkdir -p /usr/local/share/wayland-sessions /etc/sddm.conf.d /usr/share/sddm
if [ -f "$OM/default/wayland-sessions/omarchy.desktop" ]; then
  cp "$OM/default/wayland-sessions/omarchy.desktop" /usr/local/share/wayland-sessions/omarchy.desktop
  SESSION=omarchy
else
  SESSION=hyprland-uwsm
fi
[ -f "$OM/default/sddm/hyprland.conf" ] && cp "$OM/default/sddm/hyprland.conf" /usr/share/sddm/hyprland.conf
cat > /etc/sddm.conf.d/10-wayland.conf <<EOF
[General]
DisplayServer=wayland
EOF
cat > /etc/sddm.conf.d/autologin.conf <<EOF
[Autologin]
User=$VM_USER
Session=$SESSION
EOF
sed -i '/-auth.*pam_gnome_keyring\.so/d;/-password.*pam_gnome_keyring\.so/d' /etc/pam.d/sddm 2>/dev/null || true
echo "  sesion=$SESSION"
ls /usr/local/share/wayland-sessions /usr/share/wayland-sessions 2>/dev/null

# ---------------------------------------------------------------- VM settings
log "ajustes propios de maquina virtual"
# The hardware cursor and DRM modifiers cause issues over virtio-gpu
mkdir -p /etc/environment.d
cat > /etc/environment.d/90-vm-graphics.conf <<'EOF'
# virtio-gpu (virgl) bajo UTM/QEMU
WLR_NO_HARDWARE_CURSORS=1
AQ_NO_MODIFIERS=1
WLR_RENDERER_ALLOW_SOFTWARE=1
# Without this, GPU client windows (alacritty, chromium) are mapped but
# NOT painted: virgl does not deliver buffers that Hyprland can compose. Only
# clients using wl_shm render (foot). With llvmpipe all work.
# Verified that these do NOT fix it: AQ_NO_MODIFIERS, render:cm_enabled=false,
# render:explicit_sync (eliminado en Hyprland 0.56).
LIBGL_ALWAYS_SOFTWARE=1
EOF
# serial console useful for debugging from the host
systemctl enable serial-getty@ttyAMA0.service 2>/dev/null || true

log "limpieza"
rm -f /etc/sudoers.d/99-install
paccache -rk1 2>/dev/null || true
rm -rf /var/cache/pacman/pkg/* 2>/dev/null || true

log "resumen"
echo "  kernel:    $(pacman -Q linux-aarch64 2>/dev/null || echo '?')"
echo "  hyprland:  $(pacman -Q hyprland 2>/dev/null || echo 'NO INSTALADO')"
echo "  sddm:      $(pacman -Q sddm 2>/dev/null || echo 'NO INSTALADO')"
echo "  mesa:      $(pacman -Q mesa 2>/dev/null || echo '?')"
echo "  usuario:   $(id "$VM_USER")"
echo "  dotfiles:  $(ls -d /home/$VM_USER/.config/hypr 2>/dev/null || echo 'FALTAN')"
sync
touch /root/STAGE2_OK
echo ""
echo "==> [stage2] COMPLETADO"
__PAYLOAD_PROVISION_STAGE2_SH__
chmod +x "$W/provision/stage2.sh"

mkdir -p "$W/provision"
cat > "$W/provision/stage3.sh" <<'__PAYLOAD_PROVISION_STAGE3_SH__'
#!/bin/bash
# Stage 3 — as a normal user inside the chroot.
# Omarchy dotfiles, theme, and the components that exist only in the AUR.
set -uo pipefail   # no -e: this stage is best-effort in sections
. ~/config.env

log()  { echo ""; echo "==> [stage3] $*"; }
warn() { echo "!!  [stage3] $*"; }

export OMARCHY_PATH="$HOME/.local/share/omarchy"
export OMARCHY_INSTALL="$OMARCHY_PATH/install"
export PATH="$OMARCHY_PATH/bin:$PATH:$HOME/.local/bin"
export OMARCHY_CHROOT_INSTALL=1

# ------------------------------------------------------------ Omarchy repository
log "clonando basecamp/omarchy (rama ${OMARCHY_REF:-quattro} = Omarchy 4; master es 3.8.5)"
rm -rf "$OMARCHY_PATH"
mkdir -p "$(dirname "$OMARCHY_PATH")"
git clone --depth 1 --branch "${OMARCHY_REF:-quattro}" https://github.com/basecamp/omarchy.git "$OMARCHY_PATH" || { warn "clone fallido"; exit 1; }
# core.fileMode=false BEFORE chmod: otherwise, permission changes leave the
# checkout dirty and `git pull --ff-only` refuses to update it afterwards.
git -C "$OMARCHY_PATH" config core.fileMode false
find "$OMARCHY_PATH/bin" -type f -exec chmod +x {} \; 2>/dev/null
echo "  version: $(cat "$OMARCHY_PATH/version" 2>/dev/null)"

# ------------------------------------------------------------ dotfiles
# Equivalente a install/config/config.sh
log "copiando dotfiles a ~/.config"
mkdir -p ~/.config
cp -R "$OMARCHY_PATH"/config/* ~/.config/
cp "$OMARCHY_PATH/default/bashrc" ~/.bashrc
ls ~/.config | tr '\n' ' '; echo

# ------------------------------------------------------------ AUR
log "AUR: piezas de Omarchy que no están en los repos de Arch Linux ARM"
mkdir -p /tmp/aur
aur_install() {
  local p="$1"
  echo "  --- $p"
  rm -rf "/tmp/aur/$p"
  git clone --depth 1 -q "https://aur.archlinux.org/$p.git" "/tmp/aur/$p" || { warn "clone $p"; return 1; }
  ( cd "/tmp/aur/$p" && makepkg -si --noconfirm --needed --noprogressbar ) >"/tmp/aur/$p.log" 2>&1 \
    || { warn "makepkg $p falló (log: /tmp/aur/$p.log)"; tail -15 "/tmp/aur/$p.log"; return 1; }
  echo "  ok: $p"
}

AUR_OK=(); AUR_KO=()
# xdg-terminal-exec resolves $TERMINAL. walker and elephant are NOT installed:
# quattro retires them (see bin/omarchy-upgrade-to-quattro), the launcher and the
# menu are quickshell panels (`omarchy-shell shell toggle omarchy.menu`).
for p in yay xdg-terminal-exec; do
  if aur_install "$p"; then AUR_OK+=("$p"); else AUR_KO+=("$p"); fi
done
echo "  AUR ok:    ${AUR_OK[*]:-ninguno}"
echo "  AUR falló: ${AUR_KO[*]:-ninguno}"

# Fallback if xdg-terminal-exec failed to compile: Omarchy uses $TERMINAL=xdg-terminal-exec
if ! command -v xdg-terminal-exec >/dev/null 2>&1; then
  warn "xdg-terminal-exec ausente: instalando un envoltorio sobre alacritty"
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
echo "  terminal preferido: $(head -1 ~/.config/xdg-terminals.list)"

# ------------------------------------------------ system integration
# Omarchy 4 is distributed as a pacman package that places the tree in
# /usr/share/omarchy, binaries in the system PATH, and hooks in
# /etc/profile.d and /usr/share/uwsm/env.d. This package only exists for x86_64,
# so it is manually replicated here. Without this, OMARCHY_PATH remains empty and Hyprland
# starts in emergency mode because it cannot find default/hypr/bootstrap.lua.
log "integrando Omarchy en las rutas de sistema (sustituye al paquete pacman)"
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
echo "  $n binarios en /usr/bin -> /usr/share/omarchy/bin"
# User units go to /usr/lib/systemd/user/, which is where systemd looks for them.
# The omarchy-settings package installs them upstream, but it does not exist for ARM.
# Without this, install/user/first-run/enable-user-units.sh fails on every login, and
# since omarchy-provision-first-run is only marked as done if NO step fails, the
# first-run repeats indefinitely, resending the "Update System" notification.
# Source: docs/file-layout.md, "systemd/user/*.service → /usr/lib/systemd/user/".
if [ -d "$OMARCHY_PATH/default/systemd/user" ]; then
  sudo install -d /usr/lib/systemd/user
  sudo cp -a "$OMARCHY_PATH/default/systemd/user/." /usr/lib/systemd/user/
  echo "  $(ls "$OMARCHY_PATH/default/systemd/user"/*.service 2>/dev/null | wc -l) unidades de usuario en /usr/lib/systemd/user"
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

log "SDDM: tema Omarchy y sesion"
sudo mkdir -p /usr/share/sddm/themes /usr/local/share/wayland-sessions
sudo cp -a "$OMARCHY_PATH/default/sddm/omarchy" /usr/share/sddm/themes/ 2>/dev/null || true
[ -f "$OMARCHY_PATH/default/sddm/hyprland.lua" ] && sudo cp -a "$OMARCHY_PATH/default/sddm/hyprland.lua" /usr/share/sddm/hyprland.lua
sudo install -Dm644 "$OMARCHY_PATH/etc/sddm.conf.d/10-theme.conf"   /etc/sddm.conf.d/10-theme.conf
sudo install -Dm644 "$OMARCHY_PATH/etc/sddm.conf.d/10-wayland.conf" /etc/sddm.conf.d/10-wayland.conf
sudo install -Dm644 "$OMARCHY_PATH/default/wayland-sessions/omarchy.desktop" /usr/local/share/wayland-sessions/omarchy.desktop
sudo bash "$OMARCHY_PATH/install/config/theme-system.sh" 2>&1 | tail -2 || true

export OMARCHY_PATH=/usr/share/omarchy
export PATH="/usr/local/bin:$PATH"

# ------------------------------------------------------------ tema
log "aplicando el tema Tokyo Night"
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
log "ajustes para máquina virtual"
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
echo "  migraciones selladas: $(ls -1 ~/.local/state/omarchy/migrations | wc -l)"

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
REAL=/usr/share/omarchy/bin/omarchy-pkg-add
avail=(); skip=()
for p in "$@"; do
  if pacman -Q "$p" &>/dev/null || pacman -Si "$p" &>/dev/null; then
    avail+=("$p")
  else
    skip+=("$p")
  fi
done
((${#skip[@]})) && printf '\033[33mOmitido, no existe en Arch Linux ARM: %s\033[0m\n' "${skip[*]}" >&2
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
  local dir="/tmp/omabuild/$pkg"
  pacman -Q "$pkg" >/dev/null 2>&1 && return 0
  rm -rf "$dir"; mkdir -p "$dir"
  case "$src" in
    aur)
      # AUR URLs use the PackageBase, which is not always the name of the
      # package (yaru-icon-theme lives in the "yaru" repo).
      local base
      base=$(curl -fsSL --max-time 20 "https://aur.archlinux.org/rpc/v5/info?arg[]=$pkg" \
             | sed -n 's/.*"PackageBase":"\([^"]*\)".*/\1/p' | head -1)
      [ -n "$base" ] || base="$pkg"
      git clone -q "https://aur.archlinux.org/$base.git" "$dir" 2>/dev/null || return 1 ;;
    omapkgs)
      git clone --depth 1 --filter=blob:none --sparse -q \
        https://github.com/omacom-io/omarchy-pkgs.git "$dir/repo" || return 1
      ( cd "$dir/repo" && git sparse-checkout set "pkgbuilds/$pkg" >/dev/null 2>&1 )
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
  # It is compiled without installing, and then only the requested subpackage is installed.
  # -s installs build dependencies. Without it, most of these
  # PKGBUILDs fail at the first step due to missing makedepends. -i is not used
  # because installation is done afterwards, subpackage by subpackage.
  # If it fails, the log is the only thing that explains why, and until now it was lost
  # with the `rm -rf /tmp/omabuild` two lines below: the build
  # said "did not compile: X" and there was no way to find out anything else.
  # The speed limit is removed by DisableDownloadTimeout in /etc/pacman.conf
  # (it is set in stage2): so it is also inherited by the pacman that runs makepkg -s for
  # its dependencies. Passing it via the PACMAN variable does not work, because makepkg invokes it
  # quoted, and a string with arguments is searched as if it were the
  # executable name.
  if ( cd "$dir" && makepkg -s --noconfirm --needed --noprogressbar --nocheck ) >"$dir/build.log" 2>&1; then
    local built
    built=$(ls "$dir/$pkg"-*.pkg.tar.* 2>/dev/null | head -1)
    [ -n "$built" ] || built=$(ls "$dir"/*.pkg.tar.* 2>/dev/null | head -1)
    # theme-system.sh already created symlinks inside /usr/share/icons/Yaru because the
    # theme was missing: the real package conflicts with them. --overwrite resolves this.
    [ -n "$built" ] && sudo pacman -U --noconfirm --needed \
      --overwrite '/usr/share/icons/*' "$built" >>"$dir/build.log" 2>&1
  else
    mkdir -p "$HOME/.omarchy-arm-prov/fallos"
    cp "$dir/build.log" "$HOME/.omarchy-arm-prov/fallos/$pkg.log" 2>/dev/null || true
    echo "  --- $pkg fallo; ultimas lineas de makepkg ---"
    tail -20 "$dir/build.log" 2>/dev/null | sed 's/^/      /'
    echo "  --- (log completo en ~/.omarchy-arm-prov/fallos/$pkg.log) ---"
    return 1
  fi
}

# Some PKGBUILDs invoke zig via a fixed, versioned path (/opt/zig0.15/zig).
# On ARM there is only one zig version, so link it at the path these builds expect.
if pacman -Si zig >/dev/null 2>&1; then
  sudo pacman -S --noconfirm --needed --disable-download-timeout zig >/dev/null 2>&1 || true
  for v in zig0.15 zig0.14; do
    sudo mkdir -p "/opt/$v" && sudo ln -sfn "$(command -v zig)" "/opt/$v/zig" 2>/dev/null || true
  done
fi

if [ "${HACER_TOOLS:-si}" != "si" ]; then
  warn "compilacion de herramientas desactivada: faltaran ttfx, tensaku, omacalc,"
  warn "omacut, omawrite, aether, cliamp y omarchy-nvim (se pueden anadir despues"
  warn "con: yay -S <paquete>)"
else
log "compilando las herramientas de Omarchy ausentes en aarch64"
TOOLS_OK=(); TOOLS_KO=()
for spec in \
  "aur:yaru-icon-theme" "aur:ttf-ia-writer" "aur:tzupdate" "aur:ufw-docker" \
  "omapkgs:omarchy-nvim" "omapkgs:tobi-try" "aur:mise-bin" \
  "aur:aether" "aur:cliamp" \
  "omapkgs:omacalc" "omapkgs:omacut" "omapkgs:omawrite" \
  "aur:herdr" "omapkgs:tensaku" "omapkgs:hyprland-preview-share-picker"; do
  src=${spec%%:*}; pkg=${spec#*:}
  if build_omarchy_tool "$src" "$pkg"; then TOOLS_OK+=("$pkg"); else TOOLS_KO+=("$pkg"); fi
done
echo "  compiladas: ${TOOLS_OK[*]:-ninguna}"
[ ${#TOOLS_KO[@]} -gt 0 ] && warn "no compilaron: ${TOOLS_KO[*]}"
rm -rf /tmp/omabuild
fi
# Omarchy intentionally replaces two Yaru icons with Adwaita ones; if Yaru
# has just been installed, it needs to be reapplied.
sudo bash "$OMARCHY_PATH/install/config/theme-system.sh" >/dev/null 2>&1 || true

# herdr is left out: its PKGBUILD uses `zig fetch` with Zig 0.15 semantics and
# Arch Linux ARM only packages 0.16 ("no build.zig file found"). Building
# Building zig 0.15 from source takes hours, and it is a development tool rather than a
# desktop runtime dependency.

# --- The kernel restart warning, which on ARM never shuts down -------
# omarchy-update-restart decides whether the kernel changed by looking for a vmlinuz inside
# /usr/lib/modules/<version>/ that belongs to a package. On x86_64 Arch the
# linux package installs it there; on Arch Linux ARM, linux-aarch64 leaves the image
# in /boot/Image and DOES NOT create that vmlinuz. The loop finds nothing, the variable
# remains "true" and requests a restart on every update, forever.
# This wrapper compares what actually matters: uname -r against the directory
# of modules owned by the kernel package. /usr/local/bin comes before
# /usr/bin in the PATH, so it replaces the original without touching the tree.
log "envoltorio de omarchy-update-restart (aviso de kernel en ALARM)"
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
  log "compilando ttfx desde fuente (no existe para aarch64)"
  rm -rf /tmp/ttfx-src
  # Rust embeds the source path in panic messages (.rodata), beyond strip's
  # reach. Compiling from $HOME would reveal who built the distributed image.
  # Build in /tmp, keep CARGO_HOME there so dependency paths avoid the home
  # directory, and use --remap-path-prefix in case any paths still slip through.
  if git clone --depth 1 -q https://github.com/omacom-io/ttfx.git /tmp/ttfx-src \
     && ( cd /tmp/ttfx-src \
          && CARGO_HOME=/tmp/cargo-ttfx \
             RUSTFLAGS="--remap-path-prefix=/tmp/ttfx-src=ttfx --remap-path-prefix=/tmp/cargo-ttfx=cargo --remap-path-prefix=$HOME=." \
             cargo build --release -q ); then
    sudo install -Dm755 /tmp/ttfx-src/target/release/ttfx /usr/local/bin/ttfx
    echo "  ttfx $(ttfx --version 2>/dev/null | head -1)"
  else
    warn "ttfx no compilo; el salvapantallas mostrara el logo sin efectos"
  fi
  rm -rf /tmp/ttfx-src /tmp/cargo-ttfx
fi

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
  log "instalador de apps opcionales (omarchy-arm-extras)"
  sudo install -Dm755 "$HOME/.omarchy-arm-prov/omarchy-arm-extras" /usr/local/bin/omarchy-arm-extras
  sudo install -Dm644 /dev/stdin /usr/local/share/applications/omarchy-arm-extras.desktop <<'DESK'
[Desktop Entry]
Name=Instalar apps que faltan (ARM)
Comment=1Password, Obsidian, Typora, LocalSend, Google Chrome
Exec=xdg-terminal-exec omarchy-arm-extras
Icon=system-software-install
Terminal=false
Type=Application
Categories=System;PackageManager;
DESK
  echo "  disponible como comando y en el menu de aplicaciones"
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
  log "agente de portapapeles para Wayland"
  sudo install -Dm755 "$HOME/.omarchy-arm-prov/omarchy-arm-vdagent" /usr/local/bin/omarchy-arm-vdagent
  # The official agent must not start: vdagentd disconnects both if it sees
  # two agents in the same session ("multiple agents in one session").
  sudo systemctl --global mask spice-vdagent.service 2>/dev/null || true
  mkdir -p ~/.config/systemd/user
  cat > ~/.config/systemd/user/omarchy-arm-vdagent.service <<'UNIT'
[Unit]
Description=Portapapeles compartido con el anfitrion (SPICE sobre Wayland)
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
  echo "  /usr/local/bin/omarchy-arm-vdagent + servicio de usuario"
fi
# Shared folder bridge, as an alternative if the SPICE channel is not
# available (for example with Apple's virtualization backend).
if [ -f "$HOME/.omarchy-arm-prov/omarchy-arm-clipboard" ]; then
  sudo install -Dm755 "$HOME/.omarchy-arm-prov/omarchy-arm-clipboard" /usr/local/bin/omarchy-arm-clipboard
  echo "  /usr/local/bin/omarchy-arm-clipboard (alternativa por carpeta compartida)"
fi
if [ -f "$HOME/.omarchy-arm-prov/omarchy-arm-share" ]; then
  sudo install -Dm755 "$HOME/.omarchy-arm-prov/omarchy-arm-share" /usr/local/bin/omarchy-arm-share
  echo "  /usr/local/bin/omarchy-arm-share (monta la carpeta, sea VirtFS o WebDAV)"

  # OBS Studio and Pinta are free software: they can be included in the image, and
  # that is how they are distributed. They are installed with the same installer to avoid
  # duplicating their logic (OBS needs to remove the browser plugin, whose CEF is
  # x86-only; Pinta needs Microsoft's .NET arm64, which Arch does not package).
  # This is the most expensive part of the build: ~45 min. HACER_LIBRES=no skips it.
  if [ "${HACER_LIBRES:-si}" = "si" ]; then
    log "OBS Studio y Pinta (software libre, van dentro de la imagen; ~45 min)"
    if /usr/local/bin/omarchy-arm-extras pinta obs; then
      echo "  pinta: $(pacman -Q pinta 2>/dev/null || echo FALTA)"
      echo "  obs:   $(pacman -Q obs-studio 2>/dev/null || echo FALTA)"
    else
      warn "OBS o Pinta no se instalaron; se pueden anadir despues con:"
      warn "  omarchy-arm-extras pinta obs"
    fi
  else
    echo "  OBS y Pinta omitidos (HACER_LIBRES=no)"
  fi
fi

# --- updates: ensure "Update System" works and is reversible --------
# a) snapper: without it, omarchy-snapshot returns 127 and each update becomes
#    without a previous snapshot, i.e., without the ability to go back.
# b) post-update hook: omarchy-update-dev only performs `git pull` when
#    OMARCHY_PATH points OUTSIDE of /usr/share/omarchy, and here it points exactly there.
#    Without the hook, the system receives packages but the Omarchy tree (scripts,
#    themes, configuration) remains frozen at the cloned version.
log "actualizaciones: snapper + hook post-update"
sudo pacman -S --noconfirm --needed --disable-download-timeout snapper >/dev/null 2>&1 || warn "snapper no disponible"
if command -v snapper >/dev/null 2>&1; then
  sudo bash -euo pipefail "$OMARCHY_PATH/install/config/snapper.sh" >/dev/null 2>&1 \
    && echo "  snapper configurado: instantanea antes de cada actualizacion" \
    || warn "no se pudo configurar snapper"
fi
if [ -f "$HOME/.omarchy-arm-prov/10-arm-sync" ]; then
  install -Dm755 "$HOME/.omarchy-arm-prov/10-arm-sync" ~/.config/omarchy/hooks/post-update.d/10-arm-sync
  echo "  hook post-update instalado"
fi

log "git"
git config --global user.name  "$VM_FULLNAME"
git config --global user.email "$VM_EMAIL"
git config --global init.defaultBranch master

# ------------------------------------------------------------ resumen
log "resumen"
echo "  omarchy:   $(ls -d "$OMARCHY_PATH" 2>/dev/null || echo FALTA)"
echo "  ~/.config: $(ls ~/.config | wc -l) entradas"
echo "  tema:      $(readlink -f ~/.config/omarchy/current/theme 2>/dev/null || echo 'sin enlazar')"
echo "  hyprland:  $(command -v Hyprland || command -v hyprland || echo 'NO')"
echo "  omarchy-shell: $(command -v omarchy-shell || echo 'NO')"
echo "  terminal:  $(command -v xdg-terminal-exec || echo 'NO')"
echo ""
echo "==> [stage3] COMPLETADO"
__PAYLOAD_PROVISION_STAGE3_SH__
chmod +x "$W/provision/stage3.sh"

mkdir -p "$W/provision"
cat > "$W/provision/repair.sh" <<'__PAYLOAD_PROVISION_REPAIR_SH__'
#!/bin/sh
# Re-mount the already installed system on /dev/vda and run a script inside the chroot,
# without re-partitioning or downloading anything. To iterate after a specific failure.
set -eu
PROV=/media/prov
log() { echo ""; echo "==> [repair] $*"; }
trap 'rc=$?; [ "$rc" -ne 0 ] && echo "TOK_REPAIR_$rc"' EXIT

log "modulos del kernel"
# Mounting btrfs/vfat only requires the kernel module, not the user-space utilities:
# this stage does NOT depend on having network access.
for m in btrfs vfat fat nls_cp437 nls_iso8859-1 nls_utf8 crc32c-generic xxhash_generic; do
  modprobe "$m" 2>/dev/null || true
done
grep -qw btrfs /proc/filesystems || { echo "!! el kernel del live no soporta btrfs"; exit 1; }
echo "  filesystems: $(tr '\n' ' ' < /proc/filesystems | tr -s ' ')"

log "red (best-effort, solo por comodidad)"
ip link set eth0 up 2>/dev/null || true
udhcpc -i eth0 -q -n -t 8 >/dev/null 2>&1 || true
ip -4 addr show eth0 2>/dev/null | grep -o 'inet [0-9.]*' || echo "  (sin red; se continua igualmente)"

log "montando el sistema instalado"
umount -R /mnt 2>/dev/null || true
if mount -t btrfs -o rw,noatime,compress=zstd:3,subvol=@ /dev/vda2 /mnt 2>/dev/null; then
  mount -t btrfs -o rw,noatime,compress=zstd:3,subvol=@home /dev/vda2 /mnt/home
else
  mount -t ext4 /dev/vda2 /mnt
fi
mount -t vfat /dev/vda1 /mnt/boot
for d in proc sys dev run tmp; do mkdir -p "/mnt/$d"; done
mount -t proc none /mnt/proc
mount -t sysfs none /mnt/sys
mount --rbind /dev /mnt/dev
mount --make-rslave /mnt/dev
mount -t tmpfs none /mnt/run
mount -t tmpfs -o size=4G none /mnt/tmp
mkdir -p /mnt/dev/pts && mount -t devpts none /mnt/dev/pts 2>/dev/null || true
rm -f /mnt/etc/resolv.conf
printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > /mnt/etc/resolv.conf
df -h /mnt /mnt/boot

log "ejecutando $FIXSCRIPT dentro del chroot"
mkdir -p /mnt/root/prov
cp "$PROV/$FIXSCRIPT" /mnt/root/prov/
[ -f "$PROV/config.env" ] && cp "$PROV/config.env" /mnt/root/prov/
[ -f "$PROV/extras.sh" ] && cp "$PROV/extras.sh" /mnt/root/prov/omarchy-arm-extras
[ -f "$PROV/armsync.sh" ] && cp "$PROV/armsync.sh" /mnt/root/prov/10-arm-sync
[ -f "$PROV/clipbrd.sh" ] && cp "$PROV/clipbrd.sh" /mnt/root/prov/omarchy-arm-clipboard
[ -f "$PROV/vdagent.py" ] && cp "$PROV/vdagent.py" /mnt/root/prov/omarchy-arm-vdagent
[ -f "$PROV/share.sh" ] && cp "$PROV/share.sh" /mnt/root/prov/omarchy-arm-share
[ -f "$PROV/fsinfo.env" ] && cp "$PROV/fsinfo.env" /mnt/root/prov/
[ -f "$PROV/stage3.sh" ] && cp "$PROV/stage3.sh" /mnt/root/prov/
[ -f "$PROV/packages-core.txt" ] && cp "$PROV/packages-core.txt" /mnt/root/prov/
[ -f "$PROV/packages-extra.txt" ] && cp "$PROV/packages-extra.txt" /mnt/root/prov/
chmod +x /mnt/root/prov/*.sh
set +e
chroot /mnt /bin/bash "/root/prov/$FIXSCRIPT"
rc=$?
set -e

# The working directory must not be left inside the system: all repair scripts from
# previous runs accumulate there.
log "retirando /root/prov del sistema instalado"
ls /mnt/root/prov 2>/dev/null | tr '\n' ' '; echo
rm -rf /mnt/root/prov

log "desmontando"
sync
umount -R /mnt/tmp /mnt/run /mnt/dev /mnt/sys /mnt/proc 2>/dev/null || true
umount -R /mnt/boot 2>/dev/null || true
umount -R /mnt 2>/dev/null || umount -l /mnt
sync
echo "TOK_REPAIR_$rc"
trap - EXIT
exit $rc
__PAYLOAD_PROVISION_REPAIR_SH__
chmod +x "$W/provision/repair.sh"

mkdir -p "$W/provision"
cat > "$W/provision/sanitize.sh" <<'__PAYLOAD_PROVISION_SANITIZE_SH__'
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
[ -n "$OLD" ] || { echo "sanitize: no se de que usuario partir" >&2; exit 1; }
getent passwd "$OLD" >/dev/null || { echo "sanitize: el usuario '$OLD' no existe" >&2; exit 1; }
log()  { echo ""; echo "==> $*"; }
warn() { echo "!!  $*" >&2; }

log "1/10 desanclando /usr/share/omarchy del home del usuario"
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
    || volver_atras "no pude copiar $TARGET a /usr/share/omarchy"
  chown -R root:root /usr/share/omarchy
  N_ORIG=$(find "$TARGET" -mindepth 1 | wc -l)
  N_COPIA=$(find /usr/share/omarchy -mindepth 1 | wc -l)
  [ "$N_COPIA" -ge "$N_ORIG" ] \
    || volver_atras "la copia quedo incompleta ($N_COPIA de $N_ORIG entradas)"
  rm -rf "$TARGET"
  echo "  /usr/share/omarchy ahora es un directorio real ($(du -sh /usr/share/omarchy | cut -f1), $N_COPIA entradas)"
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
# the user's home points to the system tree
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
rm -f /etc/ssh/ssh_host_*        # regenerated automatically on first boot
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
# These are installed with omarchy-arm-extras on the end-user's machine.
# Packaging them in a .zip that is distributed would constitute redistributing third-party binaries,
# so they are removed even if they were in the source VM.
for pkg in 1password 1password-cli typora localsend-bin google-chrome obsidian-bin; do
  pacman -Q "$pkg" >/dev/null 2>&1 && { pacman -Rns --noconfirm "$pkg" >/dev/null 2>&1 && echo "  retirado $pkg"; }
done
for d in /opt/1Password /opt/obsidian /opt/typora; do
  [ -e "$d" ] && { rm -rf "$d"; echo "  retirado $d"; }
done
rm -f /usr/local/bin/obsidian /usr/local/share/applications/obsidian.desktop 2>/dev/null || true
# Removing /opt/1Password leaves its /usr/bin links pointing to nothing. It's the
# same old oversight: a text sweep doesn't see the target of a link.
for l in $(find /usr/bin /usr/local/bin -maxdepth 1 -xtype l 2>/dev/null); do
  case "$(readlink "$l")" in
    /opt/1Password/*|/opt/obsidian/*|/opt/typora/*)
      rm -f "$l"; echo "  enlace colgado retirado: $l" ;;
  esac
done
# The traces left upon installation: if Chrome is removed, you must also remove
# the shortcut and the webapp launcher for Spotify, which invoke it. Otherwise,
# the image ends up with a SUPER+SHIFT+M pointing to a non-existent binary.
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

log "7c/10 adelgazando: lo que solo hacia falta para compilar"
# Compiling the tools leaves behind entire build chains (the .NET
# SDK is 425 MiB) and Rust and Go toolchains in the home directory. None of this is
# needed to use the image, and it takes up ~2 GB of the zip.
for p in dotnet-sdk-bin dotnet-targeting-pack-bin aspnet-targeting-pack-bin; do
  pacman -Q "$p" >/dev/null 2>&1 && { pacman -Rns --noconfirm "$p" >/dev/null 2>&1 && echo "  quitado $p"; }
done
# Omarchy 4 retires these four: quickshell is the bar, the menu, the OSD, and the
# notification daemon. mako also hijacks org.freedesktop.Notifications by
# D-Bus activation and leaves notifications unthemed. They shouldn't be
# installed, but if a future version of the list reintroduces them, remove them.
for p in mako swayosd walker elephant; do
  pacman -Q "$p" >/dev/null 2>&1 && { pacman -Rns --noconfirm "$p" >/dev/null 2>&1 && echo "  jubilado $p"; }
done
rm -rf "/home/$NEW/.config/mako" "/home/$NEW/.config/walker" "/home/$NEW/.config/swayosd"
rm -f  /usr/local/bin/walker
orph=$(pacman -Qdtq 2>/dev/null | tr '\n' ' ')
[ -n "${orph// /}" ] && { echo "  huerfanos: $orph"; pacman -Rns --noconfirm $orph >/dev/null 2>&1; }
rm -rf "/home/$NEW/.cargo" "/home/$NEW/go" "/home/$NEW/.rustup" "/home/$NEW/.npm" 2>/dev/null
echo "  imprescindibles que deben seguir: $(for p in hyprland quickshell sddm; do printf '%s ' "$(pacman -Q $p 2>/dev/null || echo FALTA-$p)"; done)"

log "7d/10 adelgazando: lo que no puede hacer falta en una VM"
# Measured on a real image: 675 MiB of firmware for hardware that in a QEMU
# VM with virtio devices cannot exist. linux-firmware is not installed on
# purpose, but the vendor splits come in as dependencies.
FW=$(pacman -Qq 2>/dev/null | grep -E '^linux-firmware-(intel|nvidia|amdgpu|atheros|broadcom|realtek|mediatek|marvell|qcom|qlogic|liquidio|bnx2x|mellanox|nfp|other)$' | tr '\n' ' ')
if [ -n "${FW// /}" ]; then
  echo "  firmware de hardware ausente: $FW"
  # -Rdd: the linux-firmware metapackage claims the splits, which are also
  # unnecessary. If anything opposes it, leave it as is and don't break anything.
  pacman -Rdd --noconfirm $FW linux-firmware >/dev/null 2>&1 \
    && echo "  retirados" || echo "  (no se pudieron retirar; se dejan)"
fi
# Documentation and manuals: 469 MiB. This is an image to test a desktop,
# not on a server where you are going to read man pages. The .md files in Omarchy are NOT touched.
for d in /usr/share/doc /usr/share/man /usr/share/info /usr/share/gtk-doc; do
  [ -d "$d" ] && { echo "  $d: $(du -shx "$d" 2>/dev/null | cut -f1)"; rm -rf "$d"; }
done
mkdir -p /usr/share/man /usr/share/doc
echo "  ocupacion tras el recorte: $(df -h / | awk 'NR==2{print $3}')"

log "7/10 logs y caches del sistema"
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
echo "  checkout limpio: $(git -C /usr/share/omarchy status --porcelain 2>/dev/null | wc -l) ficheros"

log "8b/10 instalador de apps opcionales"
# occur, the entire block would be skipped silently and the image would end up without the
# menu entry. Both names are accepted, and a warning is issued if one is missing.
# grep -rl only checks the CONTENT of the files: the target of a symbolic
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
echo "  enlaces rotos en /usr/bin: $(find /usr/bin -xtype l 2>/dev/null | wc -l)"
echo "  /usr/share/omarchy (no debe apuntar a /home):"; ls -ld /usr/share/omarchy

log "coherencia del sistema"
echo "  passwd: $(getent passwd $NEW)"
echo "  home:   $(ls -ld /home/$NEW | awk '{print $3, $4, $9}')"
echo "  symlink omarchy: $(readlink /home/$NEW/.local/share/omarchy)"
echo "  autologin: $(grep -h User= /etc/sddm.conf.d/*.conf 2>/dev/null | tr '\n' ' ')"
echo "  binarios omarchy: $(find /usr/bin -maxdepth 1 -name 'omarchy-*' | wc -l) en /usr/bin"
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
# link is not content, so the text scan considers them clean.
# Omarchy stores the active theme and background as symbolic
# links (~/.local/state/omarchy/current/{theme,background}), so that a broken
# link leaves the desktop gray and unstyled, with no visible error.
#
mapfile -t BADLINKS < <(find /home/$NEW /etc /usr/bin /usr/local /opt -xdev -type l \
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
echo "  enlaces a /home/$OLD: $(find /home/$NEW /etc /usr/bin /usr/local /opt -xdev -type l -lname "*/home/$OLD/*" 2>/dev/null | wc -l)"
echo "  enlaces rotos en el home: $(find /home/$NEW -xdev -type l ! -exec test -e {} \; -print 2>/dev/null | wc -l)"
echo "  enlaces rotos en /usr/bin: $(find /usr/bin -xtype l 2>/dev/null | wc -l)"
echo "  fondo activo: $(readlink -f /home/$NEW/.local/state/omarchy/current/background 2>/dev/null || echo NINGUNO)"
test -e "/home/$NEW/.local/state/omarchy/current/background" \
  && echo "  fondo resuelve: OK" || echo "  fondo resuelve: ROTO"
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
  echo "  ttfx: AUN menciona a '$OLD' tras el strip"
else
  echo "  ttfx: sin rastro del constructor"
fi

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

# ─────────────────────── invariants: this CAN fail ──────────────────
# Up to this point, everything was `echo`: the script runs without -e and always ends with an
# echo, so its exit code is 0 no matter what. repair.sh collects that 0, the
# host sees TOK_REPAIR_0 and marks the image as clean. If usermod fails,
# an image with the builder's username and password is distributed.
log "invariantes de la imagen distribuible"
FALLOS=0
mal() { echo "  ✗ $*"; FALLOS=$((FALLOS+1)); }
bien() { echo "  ✓ $*"; }

getent passwd "$NEW" >/dev/null && bien "existe el usuario $NEW" || mal "no existe el usuario $NEW"
if [ "$OLD" != "$NEW" ]; then
  getent passwd "$OLD" >/dev/null && mal "el usuario del constructor ($OLD) sigue existiendo" \
                                  || bien "el usuario del constructor ya no existe"
fi
[ -d /usr/share/omarchy ] && [ ! -L /usr/share/omarchy ] \
  && bien "/usr/share/omarchy es un directorio real" \
  || mal "/usr/share/omarchy no es un directorio real"

N_CMD=$(find /usr/bin -maxdepth 1 -name 'omarchy-*' | wc -l)
[ "$N_CMD" -ge 400 ] && bien "$N_CMD comandos omarchy-*" || mal "solo $N_CMD comandos omarchy-* (esperaba >=400)"

N_ROTO=$(find /usr/bin /usr/local/bin /home/"$NEW" -xdev -xtype l 2>/dev/null | wc -l)
[ "$N_ROTO" -le 5 ] && bien "$N_ROTO enlaces colgando" || mal "$N_ROTO enlaces colgando"

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
    echo "  quitando ${#PORNOMBRE[@]} fichero(s) cuyo NOMBRE lleva '$OLD':"
    for f in "${PORNOMBRE[@]}"; do echo "    $f"; rm -rf "$f"; done
  fi
  RESTAN=$(find /home/"$NEW" /etc /usr/local /opt -xdev -mindepth 1 \
      -regextype posix-extended -regex "$RX_OLD" 2>/dev/null | wc -l)
  [ "$RESTAN" -eq 0 ] && bien "ningun nombre de fichero menciona a $OLD" || mal "$RESTAN nombres siguen mencionando a $OLD"
fi

# The clipboard: the five components that can break it.
[ -x /usr/local/bin/omarchy-arm-vdagent ] && bien "agente del portapapeles instalado" || mal "falta /usr/local/bin/omarchy-arm-vdagent"
grep -qs -- ' -X ' /etc/systemd/system/spice-vdagentd.service.d/override.conf \
  && bien "spice-vdagentd con -X" || mal "spice-vdagentd sin -X: el portapapeles no funcionara"
[ -e "/home/$NEW/.config/systemd/user/graphical-session.target.wants/omarchy-arm-vdagent.service" ] \
  && bien "agente habilitado en la sesion grafica" \
  || mal "el agente no quedo habilitado para $NEW"
if grep -vs -- '^[[:space:]]*--' "/home/$NEW/.config/hypr/autostart.lua" 2>/dev/null | grep -qs spice-vdagent; then
  mal "autostart.lua lanza el agente oficial: vdagentd desconectara a los dos"
else
  bien "autostart.lua no lanza el agente oficial"
fi

[ "$(ls /etc/ssh/ssh_host_* 2>/dev/null | wc -l)" -eq 0 ] && bien "sin claves ssh de host" || mal "quedan claves ssh de host"

# Binaries compiled inside the VM: the build path remains in their
# Debug info. grep -rl doesn't find them because it looks for text, not symbols.
if [ "$OLD" != "$NEW" ]; then
  # strings may not be available (it comes with binutils); if it's missing, report it and don't
  # invent a verdict.
  if ! command -v strings >/dev/null 2>&1; then
    echo "  ? binarios de /usr/local/bin: sin 'strings' no se puede comprobar"
  else
    SUCIOS=""
    for b in /usr/local/bin/*; do
      [ -f "$b" ] || continue
      strings "$b" 2>/dev/null | grep -q "/home/$OLD" && SUCIOS="$SUCIOS $b"
    done
    [ -z "$SUCIOS" ] && bien "ningun binario de /usr/local/bin menciona al constructor" \
                     || mal "binarios con la ruta del constructor dentro:$SUCIOS (ver RUSTFLAGS/CARGO_HOME en stage3)"
  fi
fi
[ -f /root/failed-packages.txt ] && mal "queda /root/failed-packages.txt" \
                                 || bien "sin residuos del constructor en /root"

echo ""
if [ "$FALLOS" -ne 0 ]; then
  echo "==> SANITIZE_FALLO: $FALLOS invariante(s) rotos; esta imagen NO se puede distribuir"
  exit 1
fi
echo ""
echo "==> SANITIZE_OK"
__PAYLOAD_PROVISION_SANITIZE_SH__
chmod +x "$W/provision/sanitize.sh"

mkdir -p "$W/provision"
cat > "$W/provision/extras.sh" <<'__PAYLOAD_PROVISION_EXTRAS_SH__'
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

c_ok=$'\033[32m'; c_warn=$'\033[33m'; c_err=$'\033[31m'; c_hi=$'\033[1;36m'; c_dim=$'\033[2m'; c_off=$'\033[0m'
title() { echo; echo "${c_hi}━━━ $* ━━━${c_off}"; }
info()  { echo "  $*"; }
ok()    { echo "  ${c_ok}✓${c_off} $*"; }
warn()  { echo "  ${c_warn}!${c_off} $*" >&2; }
fail()  { echo "  ${c_err}✗${c_off} $*" >&2; }

# /tmp is tmpfs and limited by RAM: compiling .NET or OBS there will run
# out of space halfway. Work is done on real disk.
WORK="${XDG_CACHE_HOME:-$HOME/.cache}/omarchy-arm-extras"
OK_LIST=(); KO_LIST=()

# ── catalog ────────────────────────────────────────────────────────────────
#  clave|titulo|descripcion
CATALOG=(
  "1password|1Password|Gestor de contrasenas. Tarball arm64 oficial de AgileBits"
  "1password-cli|1Password CLI|El comando op. Binario estatico arm64 oficial"
  "obsidian|Obsidian|Notas en markdown. AppImage arm64 oficial"
  "typora|Typora|Editor markdown WYSIWYG. Paquete arm64 oficial via AUR"
  "localsend|LocalSend|Enviar ficheros entre dispositivos. Build arm64 oficial"
  "chrome|Google Chrome|Trae Widevine para arm64: habilita Spotify y Netflix web"
  "spotify-web|Spotify (webapp)|Lanzador de open.spotify.com + reasigna SUPER+SHIFT+M"
  "pinta|Pinta|Editor de imagenes. Compilado con el .NET arm64 de Microsoft"
  "obs|OBS Studio|Captura y streaming. Compilado sin el plugin de navegador"
)

catalog_keys()  { printf '%s\n' "${CATALOG[@]}" | cut -d'|' -f1; }
catalog_title() { printf '%s\n' "${CATALOG[@]}" | awk -F'|' -v k="$1" '$1==k{print $2}'; }
catalog_desc()  { printf '%s\n' "${CATALOG[@]}" | awk -F'|' -v k="$1" '$1==k{print $3}'; }

# ── utilities ──────────────────────────────────────────────────────────────
have() { command -v "$1" >/dev/null 2>&1; }

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
    spotify-web)   grep -q "open.spotify.com" "$HOME/.config/hypr/bindings.lua" 2>/dev/null ;;
    pinta)         pacman -Q pinta            >/dev/null 2>&1 ;;
    obs)           pacman -Q obs-studio       >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

need_sudo() {
  sudo -n true 2>/dev/null && return 0
  info "Se necesita sudo para instalar paquetes."
  sudo -v || { fail "sin privilegios"; return 1; }
}

# Builds an AUR package by resolving common pitfalls on ARM:
#  · the clone URL uses the PackageBase, which is not always the name
#  · many PKGBUILDs declare arch=(x86_64) by default, not due to incompatibility
#  · a PKGBUILD can generate multiple subpackages, and only one may have the broken dependency
aur_build() {
  # A single `local` expands ALL values before assigning any, so
  # $pkg would not exist when building $dir, and with set -u the script aborts.
  local pkg="$1" want="${2:-$1}"
  local dir="$WORK/$pkg" base
  pacman -Q "$want" >/dev/null 2>&1 && { ok "$want ya instalado"; return 0; }

  base=$(curl -fsSL --max-time 20 "https://aur.archlinux.org/rpc/v5/info?arg[]=$pkg" \
         | sed -n 's/.*"PackageBase":"\([^"]*\)".*/\1/p' | head -1)
  [ -n "$base" ] || base="$pkg"

  rm -rf "$dir"; mkdir -p "$WORK"
  git clone -q "https://aur.archlinux.org/$base.git" "$dir" 2>/dev/null
  [ -f "$dir/PKGBUILD" ] || { fail "no se pudo clonar $pkg (base: $base)"; return 1; }

  # Several PKGBUILDs verify the upstream signature in check(). If the key is
  # not in the keyring, makepkg aborts. Those declared by the PKGBUILD itself
  # are imported, instead of skipping the verification.
  local keys k
  keys=$(sed -n '/^validpgpkeys=(/,/)/p' "$dir/PKGBUILD" | grep -oE '[0-9A-Fa-f]{40}')
  for k in $keys; do
    [ ${#k} -ge 16 ] || continue
    gpg --list-keys "$k" >/dev/null 2>&1 && continue
    info "importando clave GPG ${k: -8}"
    gpg --keyserver keyserver.ubuntu.com --recv-keys "$k" >/dev/null 2>&1 \
      || gpg --keyserver keys.openpgp.org --recv-keys "$k" >/dev/null 2>&1 \
      || warn "no pude importar ${k: -8}: la verificación de firma fallará"
  done

  if ! grep -qE "^arch=\(.*\b(aarch64|any)\b" "$dir/PKGBUILD"; then
    sed -i "s/^arch=(\(.*\))/arch=(\1 'aarch64')/" "$dir/PKGBUILD"
    info "arch= parcheado para incluir aarch64"
  fi

  ( cd "$dir" && makepkg -si --noconfirm --needed --noprogressbar ) >"$dir/build.log" 2>&1 && return 0
  fail "falló la compilación de $pkg — log: $dir/build.log"
  tail -5 "$dir/build.log" | sed 's/^/      /'
  return 1
}

# ── installers ────────────────────────────────────────────────────────────

do_1password() {
  title "1Password"
  info "AgileBits publica arm64 SOLO como tarball: no hay .deb ni .rpm para esta arquitectura."
  local url=https://downloads.1password.com/linux/tar/stable/aarch64/1password-latest.tar.gz
  mkdir -p "$WORK"; rm -rf "$WORK/1p"; mkdir -p "$WORK/1p"
  curl -fL --progress-bar "$url" -o "$WORK/1p/1p.tar.gz" || { fail "descarga fallida"; return 1; }
  # It is a password manager: the signature is verified before installing it.
  local KEY=3FEF9748469ADBE15DA7CA80AC2D62742012EA22
  if curl -fsSL "$url.sig" -o "$WORK/1p/1p.tar.gz.sig" 2>/dev/null; then
    gpg --list-keys "$KEY" >/dev/null 2>&1 \
      || gpg --keyserver keyserver.ubuntu.com --recv-keys "$KEY" >/dev/null 2>&1 \
      || gpg --keyserver keys.openpgp.org --recv-keys "$KEY" >/dev/null 2>&1
    if gpg --verify "$WORK/1p/1p.tar.gz.sig" "$WORK/1p/1p.tar.gz" >/dev/null 2>&1; then
      ok "firma GPG de AgileBits verificada"
    else
      fail "LA FIRMA NO VERIFICA — se aborta la instalación"; return 1
    fi
  else
    warn "no hay .sig disponible; se instala sin verificar la firma"
  fi
  tar -xzf "$WORK/1p/1p.tar.gz" -C "$WORK/1p" || { fail "no se pudo extraer"; return 1; }
  local src; src=$(find "$WORK/1p" -maxdepth 1 -type d -name '1password-*' | head -1)
  [ -n "$src" ] || { fail "el tarball no tiene la forma esperada"; return 1; }
  sudo mkdir -p /opt/1Password
  sudo cp -a "$src"/. /opt/1Password/
  ( cd /opt/1Password && sudo ./after-install.sh ) >/dev/null 2>&1 || warn "after-install.sh dio errores (suele ser inocuo)"
  have 1password && ok "$(1password --version 2>/dev/null | head -1 || echo instalado)" || { fail "no quedó en el PATH"; return 1; }
  info "${c_dim}En Hyprland conviene lanzarlo con --ozone-platform=wayland${c_off}"
}

do_1password_cli() { title "1Password CLI"; aur_build 1password-cli && ok "$(op --version 2>/dev/null)"; }

do_obsidian() {
  title "Obsidian"
  info "Hay AppImage y tarball arm64 oficiales. Se usa el tarball: no depende de fuse2."
  # NOTE: releases/latest might be an Android-only release (a standalone .apk).
  # You must find the last one actually published as a desktop arm64 tarball.
  local url
  url=$(curl -fsSL --max-time 30 "https://api.github.com/repos/obsidianmd/obsidian-releases/releases?per_page=15" \
        | grep -oE '"browser_download_url": *"[^"]*obsidian-[0-9.]+-arm64\.tar\.gz"' \
        | head -1 | sed 's/.*"\(https[^"]*\)"/\1/')
  [ -n "$url" ] || { fail "no encontré ningún tarball arm64 en los últimos releases"; return 1; }
  info "$(basename "$url")"
  mkdir -p "$WORK"; curl -fL --progress-bar "$url" -o "$WORK/obsidian.tar.gz" || { fail "descarga fallida"; return 1; }
  sudo rm -rf /opt/obsidian; sudo mkdir -p /opt/obsidian
  sudo tar -xzf "$WORK/obsidian.tar.gz" -C /opt/obsidian --strip-components=1 || { fail "no se pudo extraer"; return 1; }
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
  ok "Obsidian instalado en /opt/obsidian ($(basename "$url"))"
}

do_typora() {
  title "Typora"
  info "El paquete AUR 'typora' baja el .deb arm64 oficial. No uses typora-electron: pide electron42, que no existe en ARM."
  aur_build typora && ok "$(pacman -Q typora)"
}

do_localsend() { title "LocalSend"; aur_build localsend-bin localsend-bin && ok "$(pacman -Q localsend-bin)"; }

do_chrome() {
  title "Google Chrome"
  info "Chrome arm64 incluye Widevine (el DRM que exigen Spotify y Netflix web)."
  info "Chromium de los repos NO lo trae, y el paquete chromium-widevine es solo x86_64."
  aur_build google-chrome || return 1
  ok "$(pacman -Q google-chrome)"
  info "${c_dim}Comprueba el DRM en chrome://components → 'Widevine Content Decryption Module'${c_off}"
}

do_spotify_web() {
  title "Spotify (webapp)"
  # Omarchy treats Spotify as a native package, not as a webapp — and that package is
  # x86_64. On ARM, the working method is the web version, which requires Widevine.
  if ! have google-chrome-stable; then
    warn "sin Google Chrome la web de Spotify no reproducirá: instala antes 'chrome'"
  fi
  if have omarchy-webapp-install; then
    omarchy-webapp-install "Spotify" "https://open.spotify.com" \
      "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/png/spotify.png" \
      "$(have google-chrome-stable && echo 'google-chrome-stable --app=https://open.spotify.com')" \
      >/dev/null 2>&1 && ok "lanzador creado en el menú de aplicaciones"
  else
    warn "omarchy-webapp-install no está disponible"
  fi
  # Reassign SUPER+SHIFT+M, which in Omarchy points to the native binary
  local f="$HOME/.config/hypr/bindings.lua"
  if [ -f "$f" ] && ! grep -q "open.spotify.com" "$f"; then
    cat >> "$f" <<'LUA'

-- Spotify has no native aarch64 client: SUPER+SHIFT+M opens the web app.
-- Requires Google Chrome, which provides Widevine on arm64.
o.bind("SUPER + SHIFT + M", "Spotify", o.launch("google-chrome-stable --app=https://open.spotify.com"))
LUA
    ok "SUPER+SHIFT+M reasignado (reinicia la sesión para aplicarlo)"
  fi
  info "${c_dim}Alternativa en terminal, ya instalada: spotify-player${c_off}"
}

do_pinta() {
  title "Pinta"
  info "Microsoft sí publica .NET para linux-arm64; Arch solo lo empaqueta para x86_64."
  info "Se instala el runtime desde el tarball oficial y luego el paquete de Pinta, que es arch=any."
  aur_build dotnet-runtime-bin dotnet-runtime-bin || { fail "sin runtime .NET no se puede seguir"; return 1; }
  local url=https://geo.mirror.pkgbuild.com/extra/os/x86_64/
  local file; file=$(curl -fsSL --max-time 30 "$url" | grep -o 'pinta-[0-9][^"]*-any\.pkg\.tar\.zst' | sort -V | tail -1)
  [ -n "$file" ] || { fail "no encontré el paquete de Pinta"; return 1; }
  info "$file  ${c_dim}(la ruta dice x86_64 pero el paquete es arch=any)${c_off}"
  mkdir -p "$WORK"; curl -fL --progress-bar "$url$file" -o "$WORK/$file" || return 1
  sudo pacman -U --noconfirm "$WORK/$file" >/dev/null 2>&1 && ok "$(pacman -Q pinta)" || { fail "pacman -U falló"; return 1; }
  warn "queda fuera del gestor de actualizaciones: cada versión hay que repetirla a mano"
}

do_obs() {
  title "OBS Studio"
  info "OBS compila bien en aarch64. Lo único que lo bloquea en Arch Linux ARM es el"
  info "subpaquete del navegador, cuyo 'cef' solo existe para x86_64. Se desactiva."
  warn "compilar Qt6 + OBS dentro de la VM lleva un buen rato"
  local dir="$WORK/obs-studio"
  rm -rf "$dir"; mkdir -p "$WORK"
  git clone -q --depth 1 https://gitlab.archlinux.org/archlinux/packaging/packages/obs-studio.git "$dir" \
    || { fail "no pude clonar el PKGBUILD de Arch"; return 1; }
  cd "$dir" || return 1
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
  info "PKGBUILD parcheado: aarch64, sin CEF, sin plugin de navegador"
  if makepkg -si --noconfirm --needed --noprogressbar >"$dir/build.log" 2>&1; then
    ok "$(pacman -Q obs-studio)"
    info "${c_dim}Sin aceleración por hardware en la VM: codificará con x264 por CPU${c_off}"
  else
    fail "falló la compilación — log: $dir/build.log"
    tail -6 "$dir/build.log" | sed 's/^/      /'
    return 1
  fi
}

run_item() {
  local k="$1"
  if [ "${FORCE:-0}" != "1" ] && is_installed "$k"; then
    title "$(catalog_title "$k")"
    ok "ya viene instalada en esta imagen (--force para reinstalar)"
    return 0
  fi
  case "$k" in
    1password)     do_1password ;;
    1password-cli) do_1password_cli ;;
    obsidian)      do_obsidian ;;
    typora)        do_typora ;;
    localsend)     do_localsend ;;
    chrome)        do_chrome ;;
    spotify-web)   do_spotify_web ;;
    pinta)         do_pinta ;;
    obs)           do_obs ;;
    *) fail "no conozco '$k'"; return 1 ;;
  esac
}

show_list() {
  echo
  echo "${c_hi}Apps que se instalan desde su fuente oficial${c_off}"
  echo "${c_dim}Las propietarias no vienen dentro a proposito: redistribuir sus binarios"
  echo "en una imagen que se reparte seria problematico. Aqui se descargan en tu"
  echo "maquina, del sitio del fabricante.${c_off}"
  echo
  local k
  while read -r k; do
    if is_installed "$k"; then
      printf "  ${c_hi}%-15s${c_off} %s ${c_dim}[ya instalada]${c_off}\n" "$k" "$(catalog_desc "$k")"
    else
      printf "  ${c_hi}%-15s${c_off} %s\n" "$k" "$(catalog_desc "$k")"
    fi
  done < <(catalog_keys)
  echo
  echo "${c_dim}Uso: omarchy-arm-extras <clave> [clave...]   ·   --all para todo${c_off}"
  echo
}

# ── main ────────────────────────────────────────────────────────────────────
SELECTED=()
FORCE=0
if [ "${1:-}" = "--force" ] || [ "${1:-}" = "-f" ]; then FORCE=1; shift; fi
case "${1:-}" in
  --list|-l) show_list; exit 0 ;;
  --all|-a)  mapfile -t SELECTED < <(catalog_keys) ;;
  -h|--help) sed -n '3,20p' "$0" | sed 's/^#\{0,2\} \{0,1\}//'; exit 0 ;;
  "")
    if have gum; then
      show_list
      mapfile -t SELECTED < <(
        while read -r k; do printf '%s — %s\n' "$k" "$(catalog_title "$k")"; done < <(catalog_keys) \
        | gum choose --no-limit --header "Selecciona qué instalar (espacio marca, enter confirma)" \
        | cut -d' ' -f1
      )
    else
      show_list; exit 0
    fi ;;
  *) SELECTED=("$@") ;;
esac

[ ${#SELECTED[@]} -gt 0 ] || { info "nada seleccionado"; exit 0; }

need_sudo || exit 1
mkdir -p "$WORK"

for k in "${SELECTED[@]}"; do
  [ -z "$k" ] && continue
  if run_item "$k"; then OK_LIST+=("$k"); else KO_LIST+=("$k"); fi
done

title "Resumen"
[ ${#OK_LIST[@]} -gt 0 ] && ok "instalado: ${OK_LIST[*]}"
if [ ${#KO_LIST[@]} -gt 0 ]; then
  fail "falló: ${KO_LIST[*]}"
  # The working directory is not deleted: inside are the build.log files, which are
  # The only thing it allows us to determine is why it failed.
  info "logs en $WORK/<paquete>/build.log"
else
  rm -rf "$WORK"
fi
echo
__PAYLOAD_PROVISION_EXTRAS_SH__
chmod +x "$W/provision/extras.sh"

mkdir -p "$W/provision"
cat > "$W/provision/armsync.sh" <<'__PAYLOAD_PROVISION_ARMSYNC_SH__'
#!/bin/bash
# Post-update hook for ARM installations.
#
# In this installation, Omarchy does not come from its pacman package (which
# exists only for x86_64), but from a git checkout. omarchy-update-dev runs
# `git pull` only when OMARCHY_PATH points OUTSIDE /usr/share/omarchy; here it
# points exactly there. Without this hook, the Omarchy tree would never update:
# the system would receive new packages while Omarchy's scripts, themes, and
# configuration remained frozen at the cloned version.
set -uo pipefail
TREE=/usr/share/omarchy

git -C "$TREE" rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

# The tree can belong to the user (development VM) or root (distributed image).
if [ -w "$TREE/.git" ]; then GIT=(git -C "$TREE"); else GIT=(sudo git -C "$TREE"); fi

echo -e "\e[32m\nActualizar el árbol de Omarchy (checkout git)\e[0m"
before=$("${GIT[@]}" rev-parse --short HEAD 2>/dev/null)
if ! "${GIT[@]}" pull --ff-only 2>&1 | sed 's/^/  /'; then
  echo "  no se pudo hacer fast-forward; el árbol queda como estaba"
  exit 0
fi
after=$("${GIT[@]}" rev-parse --short HEAD 2>/dev/null)
if [ "$before" = "$after" ]; then echo "  ya estaba al día ($after)"; exit 0; fi
echo "  $before → $after"

# Link new binaries while preserving ARM-specific wrappers.
# (omarchy-pkg-add is a real file, not a symlink: do not overwrite it.)
n=0
for f in "$TREE"/bin/*; do
  [ -f "$f" ] || continue
  b=$(basename "$f"); t="/usr/bin/$b"
  [ -e "$t" ] && [ ! -L "$t" ] && continue
  [ -L "$t" ] && continue
  # Link to /usr/share/omarchy, not $TREE: that path survives the user rename
  # performed by the sanitizer (see stage3).
  sudo ln -sfn "/usr/share/omarchy/bin/$b" "$t" 2>/dev/null && n=$((n+1))
done
[ "$n" -gt 0 ] && echo "  $n binarios nuevos enlazados en /usr/bin"
# Links that point to commands already removed from the tree.
sudo find /usr/bin -xtype l -delete 2>/dev/null || true
exit 0
__PAYLOAD_PROVISION_ARMSYNC_SH__
chmod +x "$W/provision/armsync.sh"

cat > "$W/provision/clipbrd.sh" <<'__PAYLOAD_PROVISION_CLIPBRD_SH__'
#!/bin/bash
#
#  omarchy-arm-clipboard — shared clipboard with Mac, via the folder
#  shared by UTM.
#
#  WHY IT IS NEEDED
#  UTM offers "Shared Clipboard", but that only works if the guest
#  runs spice-vdagent, and spice-vdagent's clipboard is pure X11: its
#  clipboard.c delegates everything to vdagent_x11_* and there is not a single reference to
#  wlr-data-control in its code. Under Hyprland (native Wayland) it cannot
#  work, no matter if the service starts.
#
#  HOW IT WORKS
#  Monitors /mnt/share/.clipboard in both directions: if the file changes,
#  it copies it to the guest's clipboard; if the guest's clipboard
#  changes, it writes it to the file. On the Mac, an equivalent script does the
#  same with pbcopy/pbpaste. Text only.
#
#  USAGE
#    omarchy-arm-clipboard             monitors (launched by the user service)
#    omarchy-arm-clipboard --install   installs the service and starts it
#    omarchy-arm-clipboard --host      prints the script for the Mac
#
set -uo pipefail

SHARE="${OMARCHY_CLIPBOARD_DIR:-/mnt/share}"
FILE="$SHARE/.clipboard"
INTERVALO="${OMARCHY_CLIPBOARD_INTERVAL:-1}"

uso() { sed -n '3,26p' "$0" | sed 's/^#\{0,2\} \{0,1\}//'; }

instalar() {
  mkdir -p ~/.config/systemd/user
  cat > ~/.config/systemd/user/omarchy-arm-clipboard.service <<'UNIT'
[Unit]
Description=Portapapeles compartido con el anfitrion (via carpeta compartida de UTM)
After=graphical-session.target
PartOf=graphical-session.target
ConditionEnvironment=WAYLAND_DISPLAY

[Service]
Type=simple
ExecStart=/usr/local/bin/omarchy-arm-clipboard
Restart=on-failure
RestartSec=5

[Install]
WantedBy=graphical-session.target
UNIT
  systemctl --user daemon-reload
  systemctl --user enable --now omarchy-arm-clipboard.service && echo "servicio activo"
  systemctl --user --no-pager status omarchy-arm-clipboard.service | head -5
}

script_anfitrion() {
  cat <<'MACEOF'
#!/bin/bash
# Run ON THE MAC. Synchronizes the clipboard with the VM through the
# folder you have shared in the VM settings in UTM.
#   ./clipboard-mac.sh ~/path/to/shared/folder
set -uo pipefail
DIR="${1:?uso: $0 <carpeta compartida con la VM>}"
F="$DIR/.clipboard"
mkdir -p "$DIR"; touch "$F"
ultimo_local=""; ultimo_remoto="$(cat "$F" 2>/dev/null || true)"
while :; do
  actual="$(pbpaste 2>/dev/null || true)"
  if [ "$actual" != "$ultimo_local" ] && [ -n "$actual" ]; then
    printf '%s' "$actual" > "$F"; ultimo_local="$actual"; ultimo_remoto="$actual"
  fi
  remoto="$(cat "$F" 2>/dev/null || true)"
  if [ "$remoto" != "$ultimo_remoto" ] && [ -n "$remoto" ]; then
    printf '%s' "$remoto" | pbcopy; ultimo_remoto="$remoto"; ultimo_local="$remoto"
  fi
  sleep 1
done
MACEOF
}

vigilar() {
  command -v wl-paste >/dev/null || { echo "falta wl-clipboard" >&2; exit 1; }
  if [ ! -d "$SHARE" ]; then
    echo "no hay carpeta compartida en $SHARE." >&2
    echo "En UTM: Ajustes de la VM -> Compartir -> elige una carpeta, y reinicia." >&2
    exit 1
  fi
  touch "$FILE" 2>/dev/null || { echo "no puedo escribir en $FILE" >&2; exit 1; }
  local ultimo_local ultimo_remoto actual remoto
  ultimo_local="$(wl-paste --no-newline 2>/dev/null || true)"
  ultimo_remoto="$(cat "$FILE" 2>/dev/null || true)"
  while :; do
    # guest -> file
    actual="$(wl-paste --no-newline 2>/dev/null || true)"
    if [ "$actual" != "$ultimo_local" ] && [ -n "$actual" ]; then
      printf '%s' "$actual" > "$FILE"
      ultimo_local="$actual"; ultimo_remoto="$actual"
    fi
    # file -> guest
    remoto="$(cat "$FILE" 2>/dev/null || true)"
    if [ "$remoto" != "$ultimo_remoto" ] && [ -n "$remoto" ]; then
      printf '%s' "$remoto" | wl-copy
      ultimo_remoto="$remoto"; ultimo_local="$remoto"
    fi
    sleep "$INTERVALO"
  done
}

case "${1:-}" in
  --install) instalar ;;
  --host)    script_anfitrion ;;
  -h|--help) uso ;;
  "")        vigilar ;;
  *)         echo "opcion desconocida: $1" >&2; uso >&2; exit 1 ;;
esac
__PAYLOAD_PROVISION_CLIPBRD_SH__
chmod +x "$W/provision/clipbrd.sh"

cat > "$W/provision/vdagent.py" <<'__PAYLOAD_PROVISION_VDAGENT_PY__'
#!/usr/bin/env python3
"""
omarchy-arm-vdagent — shared clipboard between the host and Hyprland.

HOW THE SPICE CLIPBOARD WORKS, AND WHY THIS EXISTS

    The host's SPICE client does NOT communicate with the session agent: it
    communicates with the spice-vdagentd daemon through the virtio port. The
    daemon, in turn, multiplexes to session agents through a Unix socket
    (/run/spice-vdagentd/spice-vdagent-sock). That is how it works in any
    other VM.

    The official agent (spice-vdagent) implements that side, but delivers the
    clipboard to X11: vdagent.c:421 calls
    vdagent_clipboards_new(vdagent_display_get_x11(...)), and its repository
    contains no reference to wlr-data-control. Under Hyprland it starts and
    dies with "cannot open display".

    This program fills that exact gap: it speaks the udscs protocol with
    spice-vdagentd just like the official agent, and uses wl-copy/wl-paste on
    the other side. The daemon still handles communication with the host.

    One important detail: vdagentd serves only the agent in the ACTIVE seat0
    session (vdagentd.c:746). In a VM where SDDM launches Hyprland, that check
    often fails, so the daemon must start with -X
    (disable-session-integration, vdagentd.c:1258).

    Text only. No images or files.
"""
import os, sys, socket, struct, subprocess, threading, time, signal

SOCK = os.environ.get("VDAGENTD_SOCK", "/run/spice-vdagentd/spice-vdagent-sock")

# vdagentd-proto.h
GUEST_XORG_RESOLUTION = 0
MONITORS_CONFIG       = 1
CLIPBOARD_GRAB        = 2
CLIPBOARD_REQUEST     = 3
CLIPBOARD_DATA        = 4
CLIPBOARD_RELEASE     = 5
VERSION               = 6
CLIENT_DISCONNECTED   = 12

SEL_CLIPBOARD = 0          # VD_AGENT_CLIPBOARD_SELECTION_CLIPBOARD
TIPO_UTF8     = 1          # VD_AGENT_CLIPBOARD_UTF8_TEXT

DEBUG = bool(os.environ.get("VDAGENT_DEBUG"))
def log(*a):
    if DEBUG: print("[vdagent]", *a, file=sys.stderr, flush=True)


class Agente:
    def __init__(self, sock):
        self.s = sock
        self.lock = threading.Lock()
        self.ultimo_local = None
        self.esperando = threading.Event()
        self.recibido = None

    def enviar(self, tipo, arg1=0, arg2=0, datos=b""):
        cab = struct.pack("<IIII", tipo, arg1, arg2, len(datos))
        with self.lock:
            self.s.sendall(cab + datos)
        log("→", tipo, arg1, arg2, len(datos))

    def _leer(self, n):
        b = b""
        while len(b) < n:
            t = self.s.recv(n - len(b))
            if not t: raise EOFError
            b += t
        return b

    def bucle(self):
        while True:
            try:
                tipo, a1, a2, size = struct.unpack("<IIII", self._leer(16))
                datos = self._leer(size) if size else b""
            except (EOFError, OSError) as e:
                log("socket cerrado:", e); return
            log("←", tipo, a1, a2, size)

            if tipo == CLIPBOARD_GRAB:
                # the host offers something: we request it
                self.enviar(CLIPBOARD_REQUEST, SEL_CLIPBOARD, TIPO_UTF8)

            elif tipo == CLIPBOARD_REQUEST:
                texto = leer_portapapeles() or ""
                self.enviar(CLIPBOARD_DATA, SEL_CLIPBOARD, TIPO_UTF8,
                            texto.encode("utf-8"))

            elif tipo == CLIPBOARD_DATA:
                if a2 == TIPO_UTF8:
                    texto = datos.decode("utf-8", "replace")
                    escribir_portapapeles(texto)
                    self.ultimo_local = texto
                    log("  recibido del anfitrion:", len(texto), "bytes")

            elif tipo == VERSION:
                log("  vdagentd version:", datos.decode("utf8", "replace").strip())


def leer_portapapeles():
    try:
        r = subprocess.run(["wl-paste", "--no-newline", "--type", "text/plain"],
                           capture_output=True, timeout=5)
        return r.stdout.decode("utf-8", "replace") if r.returncode == 0 else None
    except Exception:
        return None


def escribir_portapapeles(texto):
    try:
        subprocess.run(["wl-copy", "--type", "text/plain;charset=utf-8"],
                       input=texto.encode("utf-8"), timeout=5)
    except Exception as e:
        log("wl-copy fallo:", e)


def resolucion():
    """Return the actual resolution if hyprctl is available, or a safe default."""
    try:
        r = subprocess.run(["hyprctl", "monitors", "-j"], capture_output=True, timeout=4)
        if r.returncode == 0:
            import json
            m = json.loads(r.stdout)[0]
            return int(m["width"]), int(m["height"])
    except Exception:
        pass
    return 1920, 1200


def vigilar(ag):
    """Offer clipboard data copied inside the VM to the host."""
    while True:
        t = leer_portapapeles()
        if t is not None and t != ag.ultimo_local:
            ag.ultimo_local = t
            if t:
                ag.enviar(CLIPBOARD_GRAB, SEL_CLIPBOARD, 0,
                          struct.pack("<I", TIPO_UTF8))
        time.sleep(1)


def main():
    for c in ("wl-paste", "wl-copy"):
        if subprocess.run(["sh", "-c", f"command -v {c}"],
                          capture_output=True).returncode != 0:
            print(f"falta {c} (paquete wl-clipboard)", file=sys.stderr); return 1
    if not os.path.exists(SOCK):
        print(f"no existe {SOCK}.", file=sys.stderr)
        print("Arranca el demonio:  sudo systemctl start spice-vdagentd",
              file=sys.stderr)
        return 1

    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(SOCK)
    ag = Agente(s)

    # The official agent announces its resolution as soon as it connects; vdagentd uses
    # it to know that there is a live graphical session behind.
    # struct vdagentd_guest_xorg_resolution = 5 ints: width, height, x, y,
    # display_id (vdagentd-proto.h:51). If the size does not match exactly,
    # vdagentd disconnects the agent without further notice (vdagentd.c:1088).
    ancho, alto = resolucion()
    ag.enviar(GUEST_XORG_RESOLUTION, ancho, alto,
              struct.pack("<iiiii", ancho, alto, 0, 0, 0))

    ag.ultimo_local = leer_portapapeles()
    threading.Thread(target=vigilar, args=(ag,), daemon=True).start()
    try:
        ag.bucle()
    except KeyboardInterrupt:
        pass
    finally:
        s.close()
    return 0


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    sys.exit(main())
__PAYLOAD_PROVISION_VDAGENT_PY__
chmod +x "$W/provision/vdagent.py"

cat > "$W/provision/share.sh" <<'__PAYLOAD_PROVISION_SHARE_SH__'
#!/bin/bash
#
# omarchy-arm-share — mounts the folder shared from UTM.
#
# UTM has two modes and the user selects one in VM Settings → Sharing:
#
#    VirtFS       9p device with mount_tag "share". Mounted directly.
#    SPICE WebDAV virtio port org.spice-space.webdav.0. spice-webdavd serves
#                 it at http://localhost:9843/ and is mounted using davfs2.
#
# This script detects which one is active and performs the appropriate action. Without arguments
# it mounts; with --umount it unmounts; with --status it shows the current state.
#
set -uo pipefail
PUNTO="${OMARCHY_SHARE_MNT:-/mnt/share}"
TAG=share
PUERTO_WEBDAV=/dev/virtio-ports/org.spice-space.webdav.0
URL=http://localhost:9843/

hay_9p()     { grep -qw 9p /proc/filesystems 2>/dev/null && [ -e /sys/bus/virtio/drivers/9pnet_virtio ]; }
hay_webdav() { [ -e "$PUERTO_WEBDAV" ]; }
montado()    { mountpoint -q "$PUNTO"; }

estado() {
  echo "  punto de montaje: $PUNTO"
  echo "  montado:          $(montado && echo sí || echo no)"
  echo "  modo VirtFS (9p): $(hay_9p && echo disponible || echo no)"
  echo "  modo SPICE WebDAV:$(hay_webdav && echo ' disponible' || echo ' no')"
  if hay_webdav; then
    echo "  spice-webdavd:    $(systemctl is-active spice-webdavd 2>&1)"
  fi
  montado && { echo "  contenido:"; ls -la "$PUNTO" 2>/dev/null | head -6 | sed 's/^/    /'; }
}

montar() {
  montado && { echo "ya está montado en $PUNTO"; return 0; }
  sudo mkdir -p "$PUNTO"

  # 1) VirtFS: the simplest option, if the device is
  if sudo mount -t 9p -o trans=virtio,version=9p2000.L,rw,msize=512000 "$TAG" "$PUNTO" 2>/dev/null; then
    echo "montado por VirtFS (9p) en $PUNTO"; return 0
  fi

  # 2) SPICE WebDAV
  if hay_webdav; then
    sudo systemctl start spice-webdavd 2>/dev/null || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      curl -s -m 2 -o /dev/null "$URL" && break
      sleep 1
    done
    if ! curl -s -m 3 -o /dev/null "$URL"; then
      echo "spice-webdavd no responde en $URL" >&2
      echo "  systemctl status spice-webdavd" >&2
      return 1
    fi
    # davfs2 prompts for username and password: not needed here
    if printf '\n\n' | sudo mount -t davfs -o rw,uid=$(id -u),gid=$(id -g) "$URL" "$PUNTO" 2>/dev/null; then
      echo "montado por SPICE WebDAV en $PUNTO"; return 0
    fi
    echo "davfs2 no pudo montar $URL" >&2
    return 1
  fi

  echo "no encuentro ninguna carpeta compartida." >&2
  echo "En UTM: Ajustes de la VM → Compartir → elige una ruta (VirtFS o SPICE WebDAV)," >&2
  echo "y apaga y enciende la VM." >&2
  return 1
}

case "${1:-}" in
  --umount|-u) sudo umount "$PUNTO" && echo "desmontado" ;;
  --status|-s) estado ;;
  -h|--help)   sed -n '3,14p' "$0" | sed 's/^#\{0,2\} \{0,1\}//' ;;
  "")          montar ;;
  *)           echo "opción desconocida: $1" >&2; exit 1 ;;
esac
__PAYLOAD_PROVISION_SHARE_SH__
chmod +x "$W/provision/share.sh"

mkdir -p "$W/scripts"
cat > "$W/scripts/build.exp" <<'__PAYLOAD_SCRIPTS_BUILD_EXP__'
#!/usr/bin/expect -f
# Drives the console-based construction of the Alpine live image.
set timeout 900
log_user 1
match_max 400000

proc die {code msg} { puts "\n!! $msg"; exit $code }
proc wait_for {pat code msg {t 900}} {
    set timeout $t
    expect {
        -ex $pat {}
        timeout  { die $code "TIMEOUT: $msg" }
        eof      { die [expr {$code+40}] "EOF inesperado: $msg" }
    }
}

# write_payloads replaces @OMARM_ROOT@ when deploying this file. If the
# marker is still present, it means it is running from a repository clone:
# then the root comes from OMARM_ROOT or the current directory.
set ROOT "@OMARM_ROOT@"
if {[string match "@*@" $ROOT]} {
  set ROOT [expr {[info exists env(OMARM_ROOT)] ? $env(OMARM_ROOT) : [pwd]}]
}
spawn -noecho $ROOT/scripts/qemu-build.sh

# --- Alpine live login (root without password)
wait_for "localhost login:" 10 "el live de Alpine no llegó al login" 300
send "root\r"
wait_for "localhost:~#" 11 "no hay shell de root en Alpine" 120

send "export PS1='RDY> '; echo TOK_SH_\$?\r"
wait_for "TOK_SH_0" 12 "no se pudo fijar el prompt" 60

# --- locate and mount the provisioning ISO
send "mkdir -p /media/prov; for d in /dev/vd? /dev/sr?; do mount -t iso9660 -o ro \$d /media/prov 2>/dev/null && \[ -f /media/prov/stage1.sh \] && break; umount /media/prov 2>/dev/null; done; ls /media/prov; echo TOK_PROV_\$?\r"
wait_for "TOK_PROV_0" 13 "no se encontró el ISO de aprovisionamiento" 120

send "test -s /media/prov/alarm-rootfs.tgz; echo TOK_TGZ_\$?\r"
wait_for "TOK_TGZ_0" 14 "falta el rootfs de Arch Linux ARM en el ISO" 60

# --- complete build (partitioning + chroot + packages + dotfiles)
set timeout -1
# stage1.sh emits the token TOK_BUILD_<rc> itself (a pipe to tee
# would mask the return code).
send "export DISK=/dev/vda; sh /media/prov/stage1.sh 2>&1 | tee /tmp/build.log\r"

expect {
    -ex "TOK_BUILD_0" {
        puts "\n\n==========================================="
        puts "   CONSTRUCCION COMPLETADA"
        puts "===========================================\n"
    }
    -re {TOK_BUILD_[1-9][0-9]*} {
        puts "\n\n!!!!!! LA CONSTRUCCION FALLO !!!!!!\n"
        set timeout 300
        send "echo; echo ---- ultimas 80 lineas ----; tail -n 80 /tmp/build.log; echo TOK_TAIL_\$?\r"
        catch { wait_for "TOK_TAIL_" 15 "tail" 300 }
        exit 20
    }
    eof { die 16 "EOF durante la construcción" }
}

# --- verify the resulting disk
set timeout 600
send "mount -o subvol=@ /dev/vda2 /mnt 2>/dev/null || mount /dev/vda2 /mnt; mount /dev/vda1 /mnt/boot 2>/dev/null; echo '==== VERIFICACION ===='; echo '-- ESP --'; find /mnt/boot -maxdepth 3 | head -40; echo '-- kernel --'; ls -la /mnt/boot/Image* /mnt/boot/initramfs* 2>/dev/null; echo '-- usuario --'; ls -la /mnt/home/; echo '-- dotfiles --'; for h in /mnt/home/*/; do echo \"  \$h:\"; ls \"\$h/.config\" 2>/dev/null | tr '\\n' ' '; echo; done; echo; echo '-- hyprland --'; ls -la /mnt/usr/bin/Hyprland 2>/dev/null; echo TOK_VERIFY_\$?\r"
catch { wait_for "TOK_VERIFY_" 17 "verificación" 600 }

send "sync; umount -R /mnt 2>/dev/null; poweroff -f\r"
expect eof
puts "\n===== VM DE CONSTRUCCION APAGADA ====="
exit 0
__PAYLOAD_SCRIPTS_BUILD_EXP__
chmod +x "$W/scripts/build.exp"

mkdir -p "$W/scripts"
cat > "$W/scripts/repair.exp" <<'__PAYLOAD_SCRIPTS_REPAIR_EXP__'
#!/usr/bin/expect -f
# Usage: scripts/repair.exp <script-inside-the-ISO.sh>
# Start Alpine with the disk already installed and run that script in the chroot.
set timeout 900
log_user 1
match_max 400000
set FIX [lindex $argv 0]
if {$FIX eq ""} { puts "uso: repair.exp <fix.sh>"; exit 1 }

proc wait_for {pat code msg {t 900}} {
    set timeout $t
    expect { -ex $pat {} timeout { puts "\n!! TIMEOUT: $msg"; exit $code }
             eof { puts "\n!! EOF: $msg"; exit [expr {$code+40}] } }
}
# write_payloads replaces @OMARM_ROOT@ when deploying this file. If the
# marker is still there, it means it is running from a repository clone:
# then the root comes from OMARM_ROOT or the current directory.
set ROOT "@OMARM_ROOT@"
if {[string match "@*@" $ROOT]} {
  set ROOT [expr {[info exists env(OMARM_ROOT)] ? $env(OMARM_ROOT) : [pwd]}]
}
spawn -noecho $ROOT/scripts/qemu-build.sh
wait_for "localhost login:" 10 "login de Alpine" 300
send "root\r"
wait_for "localhost:~#" 11 "shell de root" 120
send "export PS1='RDY> '; echo TOK_SH_\$?\r"
wait_for "TOK_SH_0" 12 "prompt" 60
send "mkdir -p /media/prov; for d in /dev/vd? /dev/sr?; do mount -t iso9660 -o ro \$d /media/prov 2>/dev/null && \[ -f /media/prov/repair.sh \] && break; umount /media/prov 2>/dev/null; done; ls /media/prov; echo TOK_PROV_\$?\r"
wait_for "TOK_PROV_0" 13 "ISO de aprovisionamiento" 120

set timeout -1
send "export FIXSCRIPT=$FIX; sh /media/prov/repair.sh 2>&1 | tee /tmp/repair.log\r"
expect {
    -ex "TOK_REPAIR_0" { puts "\n\n===== REPARACION COMPLETADA =====\n" }
    -re {TOK_REPAIR_[1-9][0-9]*} { puts "\n\n!!!!! LA REPARACION FALLO !!!!!\n"; exit 20 }
    eof { puts "\n!! EOF"; exit 16 }
}
set timeout 300
send "sync; poweroff -f\r"
expect eof
exit 0
__PAYLOAD_SCRIPTS_REPAIR_EXP__
chmod +x "$W/scripts/repair.exp"

mkdir -p "$W/scripts"
cat > "$W/scripts/qemu.sh" <<'__PAYLOAD_SCRIPTS_QEMU_SH__'
#!/bin/bash
# Build VM: NATIVE aarch64 with HVF (no emulation) on Apple Silicon.
# Alpine live via serial console + provisioning ISO with the ALARM rootfs.
set -e
# The root is set by write_payloads when deploying this file.
ROOT=@OMARM_ROOT@
cd "$ROOT"
: "${VM_SMP:=8}"
: "${VM_MEM:=8192}"
FW=$(brew --prefix qemu)/share/qemu/edk2-aarch64-code.fd
: "${PROV_ISO:=provision/provision.iso}"
: "${DISK_IMG:=vm/omarchy-arm.qcow2}"

[ -f vm/efi-vars.fd ] || dd if=/dev/zero of=vm/efi-vars.fd bs=1m count=64 status=none

exec qemu-system-aarch64 \
  -accel hvf -cpu host -smp "$VM_SMP" -m "$VM_MEM" \
  -M virt,highmem=on,gic-version=3 \
  -drive if=pflash,format=raw,unit=0,readonly=on,file="$FW" \
  -drive if=pflash,format=raw,unit=1,file=vm/efi-vars.fd \
  -drive if=none,id=hd,file="$DISK_IMG",format=qcow2,cache=writeback,discard=unmap \
  -device virtio-blk-pci,drive=hd \
  -drive if=none,id=live,file=dl/alpine-virt-aarch64.iso,format=raw,media=cdrom,readonly=on \
  -device virtio-blk-pci,drive=live,bootindex=0 \
  -drive if=none,id=prov,file="$PROV_ISO",format=raw,media=cdrom,readonly=on \
  -device virtio-blk-pci,drive=prov \
  -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
  -device virtio-rng-pci \
  -nographic

__PAYLOAD_SCRIPTS_QEMU_SH__
chmod +x "$W/scripts/qemu.sh"

mkdir -p "$W/scripts"
cat > "$W/scripts/make-utm.sh" <<'__PAYLOAD_SCRIPTS_MAKE-UTM_SH__'
#!/bin/bash
# Manually create the .utm bundle and register it in UTM.
#
# UTM 4.7 only scans ~/Library/Containers/com.utmapp.UTM/Data/Documents/ once
# upon app launch (listRefresh() is called from ContentView.onAppear),
# so you must close UTM, write the bundle, and reopen it.
# The config.plist requires all TEN top-level keys: they are decoded with
# decode(), not decodeIfPresent(), and omitting any causes UTM to reject it.
set -euo pipefail

# The root is inferred from the script's own location: thus the repo can be
# cloned anywhere without editing anything.
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
DOCS="$HOME/Library/Containers/com.utmapp.UTM/Data/Documents"
NAME="${1:-Omarchy ARM}"
: "${DEST_DIR:=$DOCS}"
BUNDLE="$DEST_DIR/$NAME.utm"
: "${SRC_QCOW:=$ROOT/vm/omarchy-arm.qcow2}"
VARS_TPL=/Applications/UTM.app/Contents/Resources/qemu/edk2-arm-vars.fd
: "${UTM_CPUS:=8}"
: "${UTM_MEM:=8192}"

[ -f "$SRC_QCOW" ] || { echo "!! falta $SRC_QCOW"; exit 1; }
[ -f "$VARS_TPL" ] || { echo "!! falta la plantilla de NVRAM UEFI $VARS_TPL"; exit 1; }

VM_UUID=$(uuidgen)
# Anyone receiving the bundle reads these notes in UTM before launching: they must
# state the actual credentials, not those of the builder.
NOTES_USER="${NOTES_USER:-omarchy}"
NOTES_PASS="${NOTES_PASS:-$NOTES_USER}"
# These two go inside XML. An '&' or a '<' in the password used to break the
# config.plist, and since `plutil -lint` is at the end, the error occurred AFTER
# copying the entire disk: nine gigabytes wasted to die with a message that
# did not mention the password anywhere.
xmlq() { printf "%s" "${1-}" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }
NOTES_USER=$(xmlq "$NOTES_USER")
NOTES_PASS=$(xmlq "$NOTES_PASS")

DISK_UUID=$(uuidgen)
MAC=$(printf '02:%02X:%02X:%02X:%02X:%02X' $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)))

# UTM only scans Documents upon app launch, so to recognize the
# bundle you must restart it. But force-closing it wipes out any
# VMs the user has running, so check first.
if [ "$DEST_DIR" = "$DOCS" ] && pgrep -x UTM >/dev/null; then
  UTMCTL=/Applications/UTM.app/Contents/MacOS/utmctl
  CORRIENDO=$("$UTMCTL" list 2>/dev/null | awk '$2=="started"{print $3" "$4}' | grep -v "^$" || true)
  if [ -n "$CORRIENDO" ]; then
    echo "==> HAY VMs EN MARCHA en UTM:"
    echo "$CORRIENDO" | sed 's/^/      /'
    echo "    Para registrar el bundle hay que reiniciar UTM, y eso las cortaria."
    if [ -t 0 ] && [ "${ASSUME_YES:-}" != "1" ]; then
      printf "    ¿Cerrarlas y reiniciar UTM? [s/N]: "
      read -r R </dev/tty || R=""
      case "$(printf '%s' "$R" | tr '[:upper:]' '[:lower:]')" in
        s|si|y|yes) : ;;
        *) echo "==> no se reinicia UTM: importa el bundle a mano con Archivo → Importar"; SKIP_RESTART=1 ;;
      esac
    else
      echo "==> modo desatendido: NO se cierra UTM. Importa el bundle a mano."
      SKIP_RESTART=1
    fi
  fi
  if [ "${SKIP_RESTART:-0}" != "1" ]; then
    echo "==> cerrando UTM para que reescanee Documents"
    osascript -e 'quit app "UTM"' >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x UTM >/dev/null || break; sleep 1; done
    pgrep -x UTM >/dev/null && { pkill -x UTM || true; sleep 2; }
  fi
fi

echo "==> creando $BUNDLE"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Data"
echo "    copiando disco ($(du -h "$SRC_QCOW" | cut -f1))"
cp -c "$SRC_QCOW" "$BUNDLE/Data/$DISK_UUID.qcow2" 2>/dev/null || cp "$SRC_QCOW" "$BUNDLE/Data/$DISK_UUID.qcow2"
# The VARS half of the aarch64 UEFI uses the edk2-ARM-vars.fd template (not aarch64);
# UTM provides edk2-aarch64-code.fd at runtime via -L.
install -m 0644 "$VARS_TPL" "$BUNDLE/Data/efi_vars.fd"

cat > "$BUNDLE/config.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Backend</key>
	<string>QEMU</string>
	<key>ConfigurationVersion</key>
	<integer>4</integer>
	<key>Information</key>
	<dict>
		<key>Name</key>
		<string>$NAME</string>
		<key>UUID</key>
		<string>$VM_UUID</string>
		<key>IconCustom</key>
		<false/>
		<key>Icon</key>
		<string>arch-linux</string>
		<key>Notes</key>
		<string>Arch Linux ARM (aarch64) + Hyprland + dotfiles de Omarchy 4.
Usuario: ${NOTES_USER} · Contraseña: ${NOTES_PASS} (también root). Cámbiala con passwd.
La tecla Option (⌥) actúa como SUPER. Lee LEEME.md.</string>
	</dict>
	<key>System</key>
	<dict>
		<key>Architecture</key>
		<string>aarch64</string>
		<key>Target</key>
		<string>virt</string>
		<key>CPU</key>
		<string>default</string>
		<key>CPUFlagsAdd</key>
		<array/>
		<key>CPUFlagsRemove</key>
		<array/>
		<key>CPUCount</key>
		<integer>$UTM_CPUS</integer>
		<key>ForceMulticore</key>
		<false/>
		<key>MemorySize</key>
		<integer>$UTM_MEM</integer>
		<key>JITCacheSize</key>
		<integer>0</integer>
	</dict>
	<key>QEMU</key>
	<dict>
		<key>DebugLog</key>
		<false/>
		<key>UEFIBoot</key>
		<true/>
		<key>RNGDevice</key>
		<true/>
		<key>BalloonDevice</key>
		<false/>
		<key>TPMDevice</key>
		<false/>
		<key>Hypervisor</key>
		<true/>
		<key>RTCLocalTime</key>
		<false/>
		<key>PS2Controller</key>
		<false/>
		<key>AdditionalArguments</key>
		<array/>
	</dict>
	<key>Input</key>
	<dict>
		<key>UsbBusSupport</key>
		<string>3.0</string>
		<key>UsbSharing</key>
		<false/>
		<key>MaximumUsbShare</key>
		<integer>3</integer>
	</dict>
	<key>Sharing</key>
	<dict>
		<key>DirectoryShareMode</key>
		<string>VirtFS</string>
		<key>DirectoryShareReadOnly</key>
		<false/>
		<key>ClipboardSharing</key>
		<true/>
	</dict>
	<key>Display</key>
	<array>
		<dict>
			<key>Hardware</key>
			<string>virtio-gpu-gl-pci</string>
			<key>DynamicResolution</key>
			<true/>
			<key>NativeResolution</key>
			<false/>
			<key>UpscalingFilter</key>
			<string>Nearest</string>
			<key>DownscalingFilter</key>
			<string>Linear</string>
		</dict>
	</array>
	<key>Drive</key>
	<array>
		<dict>
			<key>Identifier</key>
			<string>$DISK_UUID</string>
			<key>ImageName</key>
			<string>$DISK_UUID.qcow2</string>
			<key>ImageType</key>
			<string>Disk</string>
			<key>Interface</key>
			<string>VirtIO</string>
			<key>InterfaceVersion</key>
			<integer>1</integer>
			<key>ReadOnly</key>
			<false/>
		</dict>
	</array>
	<key>Network</key>
	<array>
		<dict>
			<key>Mode</key>
			<string>Shared</string>
			<key>Hardware</key>
			<string>virtio-net-pci</string>
			<key>MacAddress</key>
			<string>$MAC</string>
			<key>IsolateFromHost</key>
			<false/>
			<key>PortForward</key>
			<array/>
		</dict>
	</array>
	<key>Serial</key>
	<array>
		<dict>
			<key>Mode</key>
			<string>Ptty</string>
			<key>Target</key>
			<string>Auto</string>
		</dict>
	</array>
	<key>Sound</key>
	<array>
		<dict>
			<key>Hardware</key>
			<string>intel-hda</string>
		</dict>
	</array>
</dict>
</plist>
PLIST

echo "==> validando el plist"
plutil -lint "$BUNDLE/config.plist"
du -sh "$BUNDLE"
ls -la "$BUNDLE" "$BUNDLE/Data"

if [ "$DEST_DIR" = "$DOCS" ]; then
  echo "==> abriendo UTM para que registre el bundle"
  open -a UTM
  sleep 6
  /Applications/UTM.app/Contents/MacOS/utmctl list || true
else
  echo "==> bundle creado fuera de la carpeta de UTM (no se registra)"
fi

echo ""
echo "Bundle:  $BUNDLE"
echo "UUID:    $VM_UUID"
echo "Arrancar: /Applications/UTM.app/Contents/MacOS/utmctl start \"$NAME\""
__PAYLOAD_SCRIPTS_MAKE-UTM_SH__
chmod +x "$W/scripts/make-utm.sh"
  # All values are quoted: config.env is consumed with "source" and
  # anyone can contain spaces (VM_FULLNAME is the obvious case, but also
  # a password or a VM name). Without quotes, the second word is
  # executed as a command and the chroot dies with 127.
  # SINGLE quotes, not double. Using double quotes only resolved the
  # spaces: the guest runs `. config.env` and re-expands the contents,
  # so a password containing '$' or a backtick would arrive altered (or execute
  # something). With single quotes and ' escaped as '\'' the value travels literally.
  cfgq() { printf "%s" "${1-}" | sed "s/'/'\\\\''/g"; }
  cat > "$W/provision/config.env" <<CFGEOF
VM_USER='$(cfgq "$VM_USER")'
VM_PASSWORD='$(cfgq "$VM_PASSWORD")'
VM_FULLNAME='$(cfgq "$VM_FULLNAME")'
VM_EMAIL='$(cfgq "$VM_EMAIL")'
VM_HOSTNAME='$(cfgq "$VM_HOSTNAME")'
VM_TIMEZONE='$(cfgq "$VM_TIMEZONE")'
VM_KEYMAP='$(cfgq "$VM_KEYMAP")'
VM_XKB='$(cfgq "$VM_XKB")'
VM_LOCALE='$(cfgq "$VM_LOCALE")'
VM_LOCALE_EXTRA='$(cfgq "$VM_LOCALE_EXTRA")'
DISK='/dev/vda'
OMARCHY_REF='$(cfgq "$OMARCHY_REF")'
ALARM_MIRROR_PRIMARY='$(cfgq "$ALARM_MIRROR_PRIMARY")'
ALARM_MIRROR_SECONDARY='$(cfgq "$ALARM_MIRROR_SECONDARY")'
DIST_OLD_USER='$(cfgq "$VM_USER")'
DIST_NEW_USER='$(cfgq "$DIST_NEW_USER")'
HACER_TOOLS='$(cfgq "$HACER_TOOLS")'
HACER_LIBRES='$(cfgq "$HACER_LIBRES")'
CFGEOF
  # Harnesses carry the root as a marker @OMARM_ROOT@: it is replaced upon
  # deployment. Previously it was the literal path on the Mac where they were written.
  sed -i '' "s#@OMARM_ROOT@#$W#g" \
    "$W/scripts/build.exp" "$W/scripts/repair.exp" "$W/scripts/qemu.sh" "$W/scripts/make-utm.sh" 2>/dev/null || true
  sed -i '' "s#scripts/qemu-build.sh#scripts/qemu.sh#g" "$W/scripts/build.exp" "$W/scripts/repair.exp" 2>/dev/null || true
  sed -i '' "s#^ROOT=.*#ROOT=$W#" "$W/scripts/qemu.sh" "$W/scripts/make-utm.sh" 2>/dev/null || true
}

make_iso() {  # make_iso <destination.iso> <file...>
  local out="$1"; shift
  local d; d=$(mktemp -d)
  cp "$@" "$d"/
  rm -f "$out"
  hdiutil makehybrid -iso -joliet -default-volume-name PROVISION -o "$out" "$d" >/dev/null
  rm -rf "$d"
}

# ─────────────────────────────── phase: build ───────────────────────────────
ph_build() {
  phase "build · construccion del disco (headless, QEMU + HVF)"
  write_payloads
  # Short names: hdiutil truncates long ones in the ISO9660 tree
  make_iso "$W/provision/provision.iso" \
    "$W/provision/stage1.sh" "$W/provision/stage2.sh" "$W/provision/stage3.sh" \
    "$W/provision/config.env" "$W/provision/packages-core.txt" "$W/provision/packages-extra.txt"
  ln -f "$W/dl/alarm-rootfs.tgz" /tmp/alarm-rootfs.tgz 2>/dev/null || true
  # the rootfs travels inside the provisioning ISO
  local d; d=$(mktemp -d)
  cp "$W/provision"/{stage1.sh,stage2.sh,stage3.sh,config.env,packages-core.txt,packages-extra.txt} "$d"/
  cp "$W/provision"/{extras.sh,armsync.sh,clipbrd.sh,vdagent.py,share.sh} "$d"/
  ln "$W/dl/alarm-rootfs.tgz" "$d/alarm-rootfs.tgz" 2>/dev/null || cp "$W/dl/alarm-rootfs.tgz" "$d/"
  rm -f "$W/provision/provision.iso"
  hdiutil makehybrid -iso -joliet -default-volume-name PROVISION -o "$W/provision/provision.iso" "$d" >/dev/null
  rm -rf "$d"
  ok "ISO de aprovisionamiento $(du -h "$W/provision/provision.iso" | cut -f1)"

  # Rebuilding discards the previous disk, which takes ~40 minutes of work. If there is
  # one and the session is interactive, it asks; otherwise, it keeps a copy.
  if [[ -s $W/vm/omarchy-arm.qcow2 ]]; then
    if confirm "Ya existe un disco construido ($(du -h "$W/vm/omarchy-arm.qcow2" | cut -f1)). ¿Descartarlo y reconstruir?" no; then
      rm -f "$W/vm/omarchy-arm.qcow2"
    else
      mv "$W/vm/omarchy-arm.qcow2" "$W/vm/omarchy-arm.qcow2.anterior"
      info "el anterior queda en $W/vm/omarchy-arm.qcow2.anterior"
    fi
  fi
  rm -f "$W/vm/efi-vars.fd"
  qemu-img create -f qcow2 "$W/vm/omarchy-arm.qcow2" "$DISK_SIZE" >/dev/null
  dd if=/dev/zero of="$W/vm/efi-vars.fd" bs=1m count=64 status=none

  info "arrancando el constructor (Alpine live → chroot → 3 etapas)"
  info "esto tarda ~40 min segun la red; el log completo en $W/logs/build.log"
  VM_SMP=$BUILD_SMP VM_MEM=$BUILD_MEM PROV_ISO="$W/provision/provision.iso" \
    expect -f "$W/scripts/build.exp" > "$W/logs/build.log" 2>&1
  local rc=$?
  # stage2 emits TOK_STAGE3_<rc>: without checking it, a stage3 that fails entirely
  # (without dotfiles, without tools, without theme) passed as a successful build.
  if grep -qa "TOK_STAGE3_" "$W/logs/build.log" && ! grep -qa "TOK_STAGE3_0" "$W/logs/build.log"; then
    sed 's/\x1b\[[0-9;?=]*[a-zA-Z]//g' "$W/logs/build.log" | grep -aE "^(!!|==>)" | tail -25
    die "stage3 fallo: el disco existe pero no tiene la configuracion de Omarchy. Log: $W/logs/build.log"
  fi
  grep -qa "TOK_BUILD_0" "$W/logs/build.log" || {
    sed 's/\x1b\[[0-9;?=]*[a-zA-Z]//g' "$W/logs/build.log" | tail -40
    die "la construccion fallo (rc=$rc); revisa $W/logs/build.log"
  }
  ok "disco construido: $(du -h "$W/vm/omarchy-arm.qcow2" | cut -f1)"
}

# ──────────────────────────────── phase: utm ────────────────────────────────
ph_utm() {
  phase "utm · bundle .utm"
  write_payloads
  [[ -s $W/vm/omarchy-arm.qcow2 ]] || die "no hay disco construido; ejecuta la fase build"
  # Deleting a VM with the same name destroys its disk. If one already exists, it asks;
  # without a terminal, it chooses another name instead of destroying anything.
  if "$UTMCTL" list 2>/dev/null | grep -q "  $VM_NAME$"; then
    if confirm "Ya existe una VM llamada '$VM_NAME' en UTM. ¿Borrarla y reemplazarla?" no; then
      "$UTMCTL" delete "$VM_NAME" >/dev/null 2>&1 || true; sleep 2
    else
      VM_NAME="$VM_NAME $(date +%H%M)"
      info "se registrara como '$VM_NAME'"
    fi
  fi
  local ulog="$W/logs/make-utm.log"
  if ! SRC_QCOW="$W/vm/omarchy-arm.qcow2" UTM_CPUS=$UTM_CPUS UTM_MEM=$UTM_MEM \
       NOTES_USER="$VM_USER" NOTES_PASS="$VM_PASSWORD" ASSUME_YES="${ASSUME_YES:-}" \
       bash "$W/scripts/make-utm.sh" "$VM_NAME" > "$ulog" 2>&1; then
    tail -20 "$ulog"
    die "make-utm.sh fallo; log completo en $ulog"
  fi
  tail -4 "$ulog"
  [[ -f "$DOCS/$VM_NAME.utm/config.plist" ]] || die "el bundle no quedo en $DOCS"
  ok "bundle creado en $DOCS/$VM_NAME.utm"
}

# ─────────────────────────────── phase: verify ──────────────────────────────
ph_verify() {
  phase "verify · arranque y comprobacion"
  "$UTMCTL" start "$VM_NAME" >/dev/null 2>&1 || true
  info "esperando al arranque..."
  sleep 60
  local pty; pty=$("$UTMCTL" attach "$VM_NAME" 2>&1 | grep -o '/dev/ttys[0-9]*' | head -1)
  # Previously this was "warn + return 0": without a serial port there is no verification
  # possible, and proceeding to sanitize/package would package an image that no one has
  # looked at. If you really want to skip it: --from sanitize.
  [[ -n $pty ]] || die "no se pudo abrir el puerto serie de '$VM_NAME'; sin el no hay verificacion posible (si quieres continuar igualmente: --from sanitize)"
  # Previously this phase collected metrics and did not compare them with anything, so
  # it ended in "ok" regardless of what happened. Now the guest emits a verdict
  # and the host checks it. Six conditions, all necessary:
  #   H  Hyprland vivo
  #   Q  quickshell running (if it were waybar, this would be Omarchy 3)
  #   B  >=400 omarchy-* commands in /usr/bin (counted by name, not by
  #      total directory size: /usr/bin has ~2900 system files and
  #      "ls | wc -l" would pass any threshold even if there were none)
  #   R  <=5 broken symlinks (one is from qt6-webengine, unrelated to this)
  #   U  >=6 user units installed: without them first-run fails in a loop
  #   V  the tree version starts with 4
  # The previous threshold checked /usr/local/bin, where commands are no longer placed: it was
  # a guaranteed false positive once they were moved to /usr/bin.
  local vlog="$W/logs/verify.log"
  # NOTE: the heredoc is QUOTED. Without quotes, the host's bash expands
  # the $(...) before expect sees them, and the checks run on
  # the Mac instead of inside the VM (pgrep with BSD syntax, systemctl
  # nonexistent). The three required values are passed via the environment and
  # read with $env(...), which is a Tcl feature, not bash.
  PTY="$pty" GUSER="$VM_USER" GPASS="$VM_PASSWORD" \
  expect > "$vlog" 2>&1 <<'EXPEOF'
set timeout 180
log_user 1
set fd [open $env(PTY) w+]
fconfigure $fd -mode 115200,n,8,1 -translation binary -buffering none
spawn -open $fd
send "\r"
sleep 2
expect {
  -re {login:} { send "$env(GUSER)\r"; expect -re {[Pp]assword:}; send "$env(GPASS)\r"; sleep 5 }
  -re {\$ $} {}
  -re {❯} {}
  timeout {}
}
# NOTE: no `ls` here. Omarchy aliases ls to eza in long format, and the alias
# is active because this runs in an interactive shell via the serial console. With
# long format the line starts with permissions, so `grep '^omarchy-'`
# returns zero matches and verify marks a perfectly good image as KO. find is not
# aliased and does not depend on output format.
# KNOWN LIMITATION: this validates the FIRST boot. A failure that only appeared
# on reboot -such as the one fixed by fixes/19 in older images, where the
# the official agent was resurrected from autostart.lua - it would not be visible here. It was verified by
# hand that the current image does indeed survive a reboot: the agent starts with the
# graphical session. Therefore, a second pass is NOT added, as it would be a fixed cost
# in every build against a hypothesis. If a bug of
# that type reappears someday, this is the place to restart and repeat the verdict.
#
# NOTE 2: the token is SPLIT (VERED\"ICTO_OK\"). The serial console echoes the
# command, so if the token traveled whole, the log would contain the string
# VEREDICTO_OK before the guest responded with anything, and the host's `grep`
# would find it there: the phase would always return OK, regardless of what happened.
# Split, the echo shows VERED"ICTO_OK" and only the actual response matches.
#
# C counts the five known ways the clipboard can die. None
# require a connected SPICE client, so it can be checked here.
send "H=\$(pgrep -c Hyprland); Q=\$(pgrep -c quickshell); B=\$(find /usr/bin -maxdepth 1 -name 'omarchy-*' | wc -l); R=\$(find /usr/bin /usr/local/bin -xtype l | wc -l); U=\$(find /usr/lib/systemd/user -maxdepth 1 -name 'omarchy-*.service' | wc -l); V=\$(cat /usr/share/omarchy/version 2>/dev/null | cut -d. -f1); C=0; test -x /usr/local/bin/omarchy-arm-vdagent && C=\$((C+1)); grep -qs -- ' -X ' /etc/systemd/system/spice-vdagentd.service.d/override.conf && C=\$((C+1)); systemctl is-active --quiet spice-vdagentd && C=\$((C+1)); systemctl --user is-active --quiet omarchy-arm-vdagent.service && C=\$((C+1)); grep -vs -- '^\[\[:space:]]*--' ~/.config/hypr/autostart.lua | grep -qs spice-vdagent || C=\$((C+1)); echo \"### H=\$H Q=\$Q BINS=\$B ROTOS=\$R UNITS=\$U VER=\$V CLIP=\$C/5\"; if \[ \$H -ge 1 ] && \[ \$Q -ge 1 ] && \[ \$B -ge 400 ] && \[ \$R -le 5 ] && \[ \$U -ge 6 ] && \[ \"\$V\" = 4 ] && \[ \$C -eq 5 ]; then echo VERED\"ICTO_OK\"; else echo VERED\"ICTO_KO\"; fi\r"
expect { -re {VEREDICTO_(OK|KO)} {} timeout {} }
EXPEOF
  sed 's/\x1b\[[0-9;?=]*[a-zA-Z]//g' "$vlog" | grep -aE "^###" | tail -1
  if grep -qa "^VEREDICTO_OK" "$vlog"; then
    ok "VM '$VM_NAME' verificada: Omarchy 4, Hyprland + quickshell vivos, comandos y unidades en su sitio, portapapeles operativo"
  elif grep -qa "^VEREDICTO_KO" "$vlog"; then
    sed 's/\x1b\[[0-9;?=]*[a-zA-Z]//g' "$vlog" | tail -20
    die "la VM arranca pero el escritorio no esta completo; log en $vlog"
  else
    # This also cannot be a warning: if the guest does not respond, we know
    # nothing about the image, and the next step would be to package and distribute it.
    sed 's/\x1b\[[0-9;?=]*[a-zA-Z]//g' "$vlog" | tail -20
    die "el invitado no emitio veredicto por el puerto serie; log en $vlog"
  fi
}

# ────────────────────────────── phase: sanitize ─────────────────────────────
ph_sanitize() {
  phase "sanitize · copia limpia para distribuir"
  write_payloads
  "$UTMCTL" stop "$VM_NAME" >/dev/null 2>&1 || true
  while [[ $("$UTMCTL" status "$VM_NAME" 2>/dev/null) == started ]]; do sleep 3; done

  local src; src=$(find "$DOCS/$VM_NAME.utm/Data" -name '*.qcow2' | head -1)
  [[ -s $src ]] || src="$W/vm/omarchy-arm.qcow2"
  rm -f "$W/dist/dist.qcow2"
  cp -c "$src" "$W/dist/dist.qcow2" 2>/dev/null || cp "$src" "$W/dist/dist.qcow2"
  ok "copia de trabajo hecha (la VM original no se toca)"

  make_iso "$W/provision/repair.iso" "$W/provision/repair.sh" "$W/provision/sanitize.sh" \
           "$W/provision/config.env" "$W/provision/extras.sh" "$W/provision/armsync.sh"
  info "limpiando (usuario generico, sin claves ni identidad)..."
  PROV_ISO="$W/provision/repair.iso" DISK_IMG="$W/dist/dist.qcow2" \
  DIST_OLD_USER="$VM_USER" DIST_NEW_USER="$DIST_NEW_USER" \
    expect -f "$W/scripts/repair.exp" sanitize.sh > "$W/logs/sanitize.log" 2>&1
  # TOK_REPAIR_0 only indicates that the chroot did not crash, and sanitize.sh runs without
  # -e: it returned 0 even if usermod had failed and the image retained the
  # builder's user. The meaningful token is SANITIZE_OK, which
  # now causes sanitize.sh to print only if its invariants are met.
  if grep -qa "SANITIZE_FALLO" "$W/logs/sanitize.log"; then
    sed 's/\x1b\[[0-9;?=]*[a-zA-Z]//g' "$W/logs/sanitize.log" | grep -aE "✗|SANITIZE_FALLO" | tail -20
    die "la imagen no paso los invariantes de distribucion; revisa $W/logs/sanitize.log"
  fi
  grep -qa "SANITIZE_OK" "$W/logs/sanitize.log" || {
    sed 's/\x1b\[[0-9;?=]*[a-zA-Z]//g' "$W/logs/sanitize.log" | tail -30
    die "la limpieza no llego al final; revisa $W/logs/sanitize.log"
  }
  grep -qa "TOK_REPAIR_0" "$W/logs/sanitize.log" || {
    sed 's/\x1b\[[0-9;?=]*[a-zA-Z]//g' "$W/logs/sanitize.log" | tail -30
    die "la limpieza fallo; revisa $W/logs/sanitize.log"
  }
  ok "imagen sanitizada y con los invariantes de distribucion comprobados"
}

# ────────────────────────────── phase: package ──────────────────────────────
ph_package() {
  phase "package · compactar y comprimir"
  [[ -s $W/dist/dist.qcow2 ]] || die "no hay imagen sanitizada; ejecuta la fase sanitize"
  info "compactando y comprimiendo los clusters del qcow2..."
  rm -f "$W/dist/slim.qcow2"
  # -c compresses within the qcow2 itself: the image occupies half the space even when
  # decompressed on the recipient's disk. It decompresses upon reading.
  qemu-img convert -c -O qcow2 "$W/dist/dist.qcow2" "$W/dist/slim.qcow2" || die "qemu-img convert fallo"
  qemu-img check "$W/dist/slim.qcow2" >/dev/null || die "la imagen compactada no valida"
  ok "$(du -h "$W/dist/dist.qcow2" | cut -f1) → $(du -h "$W/dist/slim.qcow2" | cut -f1)"

  # The distributed bundle does NOT include $VM_NAME. That name is from the builder and
  # can be anything ("Omarchy ARM v5" in one of the batches), and was carried
  # inside the zip as both the directory name and the <key>Name</key> value, so that
  # when importing it into UTM, it appeared with the internal versioning of whoever created it.
  # Additionally, the README says "double-click on Omarchy ARM.utm", which did not exist at the time.
  local DNAME="${DIST_VM_NAME:-Omarchy ARM}"
  rm -rf "$W/dist/$DNAME.utm"
  SRC_QCOW="$W/dist/slim.qcow2" DEST_DIR="$W/dist" UTM_CPUS=$UTM_CPUS UTM_MEM=$UTM_MEM \
    NOTES_USER="$DIST_NEW_USER" NOTES_PASS="$DIST_NEW_USER" \
    bash "$W/scripts/make-utm.sh" "$DNAME" >/dev/null \
    || die "no se pudo crear el bundle distribuible"
  # Final check: neither the plist nor the BUNDLE NAME should bear any trace of the
  # user or the builder's project name.
  if grep -q "\b$VM_USER\b" "$W/dist/$DNAME.utm/config.plist" 2>/dev/null; then
    die "el config.plist del bundle menciona a '$VM_USER'; revisa make-utm.sh"
  fi
  if [[ "$DNAME" != "$(printf '%s' "$DNAME" | tr -cd 'A-Za-z .-')" ]]; then
    die "el nombre de distribucion '$DNAME' lleva caracteres raros; usa algo neutro"
  fi
  write_readme "$W/dist/LEEME.md"

  info "comprimiendo..."
  ( cd "$W/dist" && rm -f omarchy-arm-utm.zip \
      && zip -r -q -1 omarchy-arm-utm.zip "$DNAME.utm" LEEME.md \
      && shasum -a 256 omarchy-arm-utm.zip > omarchy-arm-utm.zip.sha256 )
  rm -f "$W/dist/dist.qcow2" "$W/dist/slim.qcow2"
  ok "listo: $W/dist/omarchy-arm-utm.zip ($(du -h "$W/dist/omarchy-arm-utm.zip" | cut -f1))"
  cat "$W/dist/omarchy-arm-utm.zip.sha256"
}

write_readme() {
  # The text resides in provision/src/LEEME.md and is embedded as-is (scripts/sync
  # re-embeds it). When there were two manual copies, the script's version fell behind
  # and was carried inside the zip stating false things -- 432 commands when there were
  # 439, "the zip takes up 7 GB" when it was 3.6 -- and even included an internal note
  # for the maintainer inside.
  cat > "$1" <<'__PAYLOAD_LEEME_MD__'
# Omarchy sobre Arch Linux ARM — imagen para UTM en Apple Silicon

Imagen construida con
[`build-omarchy-arm.sh`](https://github.com/ggalancs/omarchy-arm-utm).

Máquina virtual **aarch64 nativa** (acelerada con HVF, sin emulación) con
Arch Linux ARM + Hyprland y la configuración, temas y herramientas de
[Omarchy 4](https://omarchy.org).

## Requisitos

- Mac con Apple Silicon (M1 o superior)
- [UTM](https://mac.getutm.app) 4.7 o posterior
- ~11 GB de disco libre: el `.zip` ocupa 3,6 GB y la imagen descomprimida
  otros 7,2 GB, más lo que crezca al usarla

## Instalación

1. Descomprime el `.zip`.
2. Doble clic en el `.utm` que aparece (o **Archivo → Importar** en UTM).
3. Arranca la VM.

Entra solo, sin pedir contraseña.

## Credenciales

| | |
|---|---|
| Usuario | `omarchy` |
| Contraseña | `omarchy` (también para root) |

**Cambia la contraseña nada más entrar:** abre un terminal y ejecuta `passwd`.

## Teclado

macOS se queda con la tecla Cmd antes de que UTM la reciba (Cmd+Space abre
Spotlight), así que la VM está configurada con Alt y Super intercambiados:

| Tecla del Mac | En la VM |
|---|---|
| **Option (⌥)** | SUPER |
| Cmd (⌘) | ALT |

Atajos principales: **⌥+Space** abre el menú de Omarchy, **⌥+Return** un
terminal, **⌥+K** el listado completo de atajos.

Si prefieres el comportamiento original, quita `altwin:swap_lalt_lwin` de
`~/.config/hypr/input.lua` y activa la captura de entrada de UTM (requiere dar
permisos de Accesibilidad y Monitorización de entrada a UTM en Ajustes del
Sistema → Privacidad y seguridad).

## Qué esperar

Funciona: el escritorio Hyprland completo con la barra de Omarchy, temas,
menú, terminal, navegador, y los 439 comandos `omarchy-*`.

Incluye además las herramientas propias de Omarchy **compiladas para aarch64**,
que no se publican para ARM: `tensaku` (anotación de capturas), `omacalc`,
`omacut`, `omawrite`, `aether` (temas), `cliamp` (reproductor), `ttfx` (efectos
del salvapantallas), `omarchy-nvim`, `mise`, `tzupdate`, `yaru-icon-theme`,
`ttf-ia-writer`, `hyprland-preview-share-picker`, `xdg-terminal-exec`,
`tobi-try`, `ufw-docker` y `yay`.

Y dos aplicaciones de software libre ya compiladas para ARM: **OBS Studio
32.2.2** (sin el plugin de navegador, cuyo CEF es x86-only) y **Pinta 3.1.2**
(sobre el .NET arm64 oficial de Microsoft).

Limitaciones propias de correr Omarchy en ARM:

- **Sin aceleración GL dentro de la VM.** Las ventanas se dibujan por software
  (llvmpipe). Bajo virtio-gpu los clientes GPU se mapean pero no se pintan; el
  blur y las sombras vienen desactivados para compensar. Es fluido para uso
  normal, no para vídeo ni 3D.
- **Falta `herdr`**: quiere la semántica de Zig 0.15, y ni ARM ni x86_64
  empaquetan ya esa versión (los dos van por la 0.16).
- **El disco viene comprimido** dentro del `.qcow2`. Ocupa la mitad y se
  descomprime al vuelo; si prefieres velocidad de lectura sobre espacio,
  `qemu-img convert -O qcow2 disco.qcow2 sin-comprimir.qcow2`.

## Portapapeles y carpeta compartida

**El portapapeles funciona en los dos sentidos**: copias en el Mac y pegas en
la VM, y al revés. Solo texto. Dos condiciones:

- **«Share clipboard» activado** en UTM (*Preferencias de la VM → Sharing*).
- **La VM abierta como ventana.** Arrancada sin ventana (`utmctl start`) no hay
  ningún cliente SPICE conectado, así que el canal existe pero no lleva nada.

Si no va, esto dice en cuál de los tres saltos se corta —cliente SPICE →
`spice-vdagentd` → sesión de Hyprland—:

```bash
systemctl is-active spice-vdagentd              # el demonio
systemctl --user status omarchy-arm-vdagent     # el agente de tu sesión
```

**Carpeta compartida**: elige una en *Preferencias de la VM → Sharing* y dentro
ejecuta `omarchy-arm-share`. Detecta solo si UTM está en modo VirtFS o en modo
SPICE WebDAV y la monta en `/mnt/share` de la forma que corresponda.
`omarchy-arm-share --status` para ver cómo quedó, `--umount` para soltarla.

## Las apps que no vienen dentro

1Password, Obsidian, Typora, LocalSend y Google Chrome **no están en la
imagen**, pero no porque no funcionen: todas tienen build ARM64 oficial. No van
dentro porque son propietarias y empaquetarlas en una imagen que se distribuye
sería redistribuir binarios de terceros.

La imagen trae un instalador que las descarga de su fuente oficial:

```bash
omarchy-arm-extras --list     # ver qué puede instalar
omarchy-arm-extras            # menú interactivo
omarchy-arm-extras obsidian   # una concreta
omarchy-arm-extras --all      # todas las que falten
```

El listado marca `[ya instalada]` lo que la imagen ya trae, y `--all` lo omite.

También está en el menú de aplicaciones como **«Instalar apps que faltan (ARM)»**.

| Clave | Qué hace |
|---|---|
| `1password` | Tarball arm64 oficial, con verificación de firma GPG |
| `1password-cli` | El comando `op`, binario estático arm64 |
| `obsidian` | Tarball arm64 oficial |
| `typora` | Paquete arm64 oficial vía AUR |
| `localsend` | Build arm64 oficial |
| `chrome` | Trae Widevine para arm64: habilita Spotify y Netflix web |
| `spotify-web` | Lanzador de la web + reasigna `⌥+Shift+M` |
| `pinta` | Ya viene instalada; la clave sirve para reinstalarla |
| `obs` | Ya viene instalado; la clave sirve para reinstalarlo |

**Sobre Spotify**: no hay cliente nativo para ARM, pero la web sí funciona —
necesita Widevine, que viene dentro de Google Chrome arm64. Instala `chrome` y
luego `spotify-web`. En terminal ya tienes `spotify-player` instalado.
- **`omarchy-update` funciona**, pero cuando Omarchy introduzca un paquete
  propio nuevo, lo omitirá con un aviso en vez de instalarlo.

## Resolución

Fija en 1920x1200. Para cambiarla, edita `~/.config/hypr/monitors.lua` y
**reinicia la VM** — cambiar el modo en caliente deja la pantalla en blanco bajo
virtio-gpu.

## Nota

Imagen no oficial, sin relación con Basecamp ni con el proyecto Omarchy.
Omarchy solo soporta x86_64; esto es una reconstrucción equivalente sobre
Arch Linux ARM.
__PAYLOAD_LEEME_MD__
}

# ──────────────────────────────────── questions ────────────────────────────
# Only what is truly a decision is asked, and getting it wrong is costly.
# Everything else (Alpine version, rootfs URL, Omarchy branch, disk size, and
# locales) remains configurable through environment variables: these are
# implementation details, not decisions.
# Use ':=' so they can be set from the environment, just like the rest:
#   HACER_LIBRES=no ./build-omarchy-arm.sh --yes
: "${HACER_TOOLS:=si}"
: "${HACER_LIBRES:=si}"
: "${HACER_DIST:=si}"

cuestionario() {
  detectar_del_anfitrion
  if (( ! INTERACTIVO )); then
    # No terminal: preserve the historical fully automatic behavior. Save the
    # answers so a later --from does not start with different values.
    # If a previous run already saved answers, do not overwrite them: a follow-up
    # `--yes` used to destroy what the user had answered manually.
    [[ -f "$W/respuestas.env" ]] || guardar_respuestas
    return
  fi
  phase "configuracion"
  info "Enter acepta el valor entre corchetes. Detectados de tu Mac."
  echo

  ask VM_TIMEZONE "Zona horaria"                     "$VM_TIMEZONE"
  ask VM_KEYMAP   "Teclado (consola)"                "$VM_KEYMAP"
  ask VM_XKB      "Teclado (Hyprland/Wayland)"       "$VM_XKB"
  echo
  ask UTM_CPUS    "Nucleos para la VM"               "$UTM_CPUS"
  ask UTM_MEM     "Memoria para la VM (MiB)"         "$UTM_MEM"
  ask DISK_SIZE   "Tamano del disco"                 "$DISK_SIZE"
  echo

  # About 40 minutes of compilation. The desktop works without these tools, but
  # the screensaver, screenshot annotator, calculator, and others are missing.
  if confirm "Compilar las 17 herramientas de Omarchy que no existen para ARM (~40 min)?" si; then
    HACER_TOOLS=si
  else
    HACER_TOOLS=no
    warn "sin ellas faltaran ttfx, tensaku, omacalc, omacut, omawrite, aether, cliamp..."
  fi
  echo

  # OBS and Pinta are the most expensive parts of the build. The distributable
  # image includes them because they are free software, but a test VM does not need them.
  if confirm "Incluir OBS Studio y Pinta (software libre, se compilan: ~45 min)?" si; then
    HACER_LIBRES=si
  else
    HACER_LIBRES=no
    info "se pueden anadir despues desde dentro: omarchy-arm-extras pinta obs"
  fi
  echo

  # The most consequential choice: an image for distribution or a VM for personal use.
  info "Dos usos posibles:"
  info "  · imagen para repartir  → renombra el usuario a '$DIST_NEW_USER', borra"
  info "    claves SSH e identidad, y genera un zip de ~6,5 GB (~30 min extra)"
  info "  · VM para ti            → se queda como esta, con el usuario '$VM_USER'"
  if confirm "Preparar la imagen para repartir?" no; then
    HACER_DIST=si
    ask DIST_NEW_USER "Usuario de la imagen distribuible" "$DIST_NEW_USER"
  else
    HACER_DIST=no
    ask VM_USER     "Usuario de la VM"     "$VM_USER"
    ask VM_PASSWORD "Contrasena"           "$VM_PASSWORD"
    ask VM_FULLNAME "Nombre completo"      "$VM_FULLNAME"
  fi
  echo
  info "resumen: $VM_KEYMAP/$VM_XKB · $VM_TIMEZONE · ${UTM_CPUS} nucleos · ${UTM_MEM} MiB · disco $DISK_SIZE"
  info "         herramientas: $HACER_TOOLS · OBS+Pinta: $HACER_LIBRES · repartir: $HACER_DIST"
  confirm "Empezar?" si || die "cancelado"
  guardar_respuestas
}

# ──────────────────────────────────── main ─────────────────────────────────
# Print the full header regardless of length. A fixed '2,30p' range made --help
# lose the phase list as soon as the banner grew.
usage() { awk 'NR>1 && /^#/{print; next} NR>1{exit}' "$0" | sed 's/^#\{0,2\} \{0,1\}//'; }

run_from=""; run_only=""
while (($#)); do
  case "$1" in
    # Use ${2:-}, not $2: with `set -u`, a missing argument otherwise aborts
    # with "unbound variable" and a line number instead of the useful message below.
    --from) run_from="${2:-}"; [[ -n $run_from ]] || { usage; die "--from necesita una fase (${PHASES[*]})"; }; shift 2 ;;
    --only) run_only="${2:-}"; [[ -n $run_only ]] || { usage; die "--only necesita una fase (${PHASES[*]})"; }; shift 2 ;;
    --list) printf '%s\n' "${PHASES[@]}"; exit 0 ;;
    --yes|-y|--sin-preguntas) ASSUME_YES=1; INTERACTIVO=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "opcion desconocida: $1" ;;
  esac
done

# The build username ends up in a sanitizer `find ... -regex` and throughout
# guest paths. A strange or very short name turns that sweep into a shotgun, so
# require a valid username that is not a substring of the distributable user.
[[ $VM_USER =~ ^[a-z_][a-z0-9_-]{2,31}$ ]] \
  || die "VM_USER='$VM_USER' no vale: minusculas, digitos, '-' y '_', empezando por letra, 3-32 caracteres"
[[ $DIST_NEW_USER == *"$VM_USER"* ]] \
  && die "VM_USER='$VM_USER' es parte de DIST_NEW_USER='$DIST_NEW_USER'; elige otro"

# Combining the two does nothing: if the --only phase comes BEFORE the
# --from phase in the array, the loop never sets started=1 and the script
# would finish announcing "Completed in 0 min." with rc=0 without doing anything
# at all. They are mutually exclusive, so we state it and move on.
[[ -n $run_from && -n $run_only ]] && die "--from y --only son excluyentes: elige uno"

# A misspelled phase name must not exit successfully without doing anything.
for sel in "$run_from" "$run_only"; do
  [[ -z $sel ]] && continue
  printf '%s\n' "${PHASES[@]}" | grep -qxF "$sel" \
    || die "fase desconocida: '$sel' (validas: ${PHASES[*]})"
done

# Resuming or running a single phase must not reopen the questionnaire, but it MUST
# retrieve what was answered the previous time.
if [[ -z $run_from && -z $run_only ]]; then
  cargar_respuestas          # previous answers appear as defaults
  cuestionario
else
  cargar_respuestas || true
  if [[ -f "$W/respuestas.env" ]]; then
    info "reanudando con las respuestas de $W/respuestas.env (usuario '$VM_USER', repartir: ${HACER_DIST:-no})"
  else
    warn "no hay $W/respuestas.env: se usaran los valores por defecto, que pueden no ser los que elegiste"
  fi
fi

# Phase trimming is decided HERE: after the questionnaire and loading the
# answers, with the final value of HACER_DIST, and never when the user
# has manually named sanitize or package -- that would mean doing nothing and exiting
# successfully, which is exactly what was just removed in two other places.
if [[ ${HACER_DIST:-si} == no \
      && $run_from != sanitize && $run_from != package \
      && $run_only != sanitize && $run_only != package ]]; then
  PHASES=(deps fetch prepare build utm verify)
fi

started=0
[[ -z $run_from ]] && started=1
t0=$SECONDS
for p in "${PHASES[@]}"; do
  [[ -n $run_only && $p != "$run_only" ]] && continue
  [[ -n $run_from && $p == "$run_from" ]] && started=1
  (( started )) || continue
  ensure_dirs
  "ph_$p" || die "fallo en la fase '$p'"
done
echo
echo "${c_ok}Completado en $(( (SECONDS-t0)/60 )) min.${c_off}"
