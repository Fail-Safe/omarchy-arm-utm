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
#    OMARCHY_LANG=es ./build-omarchy-arm.sh  # force Spanish (en|es|auto)
#
# Phases:
#    deps      check host dependencies
#    fetch     download Alpine ISO + ALARM rootfs (pinned SHA-256 hashes)
#    prepare   capture repository databases and calculate the pinned package list
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
for _v in OMARCHY_LANG VM_TIMEZONE VM_KEYMAP VM_XKB UTM_CPUS UTM_MEM \
          INCLUDE_LIBRE_APPS HACER_LIBRES; do
  [ -n "${!_v:-}" ] && FIJADO_POR_ENTORNO="$FIJADO_POR_ENTORNO $_v"
done
unset _v
del_entorno() { case " $FIJADO_POR_ENTORNO " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

: "${W:=$HOME/omarchy-arm-build}"        # working directory
: "${OMARCHY_LANG:=auto}"                # UI language: auto, en, or es
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
# OJO con este nombre: `omarchy-arm-utm.zip` es el de la PRIMERA publicacion
# en archive.org, y ahi se queda congelado para que los enlaces y los sha256
# publicados en agosto sigan resolviendo a los bytes exactos para los que se
# escribieron. Estaba incrustado aqui, asi que el constructor producia un
# fichero con ese mismo nombre: subirlo era pisar el original.
: "${DIST_ZIP:=omarchy-arm-utm-v2.zip}"  # nombre del zip que se reparte
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

detect_ui_language() {
  local requested="$OMARCHY_LANG" locale="" keyboard=""
  case "$requested" in
    en|es) return 0 ;;
    auto) ;;
    *) printf "Invalid OMARCHY_LANG='%s'; expected auto, en, or es.\n" "$requested" >&2; return 2 ;;
  esac

  locale=$(defaults read -g AppleLocale 2>/dev/null || true)
  keyboard=$(defaults read "$HOME/Library/Preferences/com.apple.HIToolbox.plist" \
    AppleSelectedInputSources 2>/dev/null || true)

  case "$locale" in
    *_ES*|*-ES*|*_MX*|*-MX*|*@rg=ES*|*@rg=MX*) OMARCHY_LANG=es; return 0 ;;
  esac
  case "$keyboard" in
    *Spanish*|*Mexican*|*Mexico*) OMARCHY_LANG=es; return 0 ;;
  esac
  OMARCHY_LANG=en
}
detect_ui_language || exit $?

ui_text() {
  if [[ $OMARCHY_LANG == es ]]; then printf '%s' "${2:-$1}"; else printf '%s' "$1"; fi
}
phase() { local text; text=$(ui_text "$1" "${2:-$1}"); echo; echo "${c_hi}━━━ $text ━━━${c_off}"; }
info()  { local text; text=$(ui_text "$1" "${2:-$1}"); echo "  $text"; }
ok()    { local text; text=$(ui_text "$1" "${2:-$1}"); echo "  ${c_ok}✓${c_off} $text"; }
warn()  { local text; text=$(ui_text "$1" "${2:-$1}"); echo "  ${c_warn}!${c_off} $text" >&2; }
die()   { local text; text=$(ui_text "$1" "${2:-$1}"); echo "  ${c_err}✗ $text${c_off}" >&2; exit 1; }

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
RESPUESTAS_VARS=(OMARCHY_LANG VM_NAME VM_USER VM_PASSWORD VM_FULLNAME VM_EMAIL VM_HOSTNAME
                 VM_TIMEZONE VM_KEYMAP VM_XKB VM_LOCALE VM_LOCALE_EXTRA
                 OMARCHY_REF DIST_NEW_USER DISK_SIZE UTM_CPUS UTM_MEM
                 HACER_TOOLS INCLUDE_LIBRE_APPS HACER_DIST)

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
    grep -q "^${v}=" "$W/respuestas.env" || continue
    val=$(. "$W/respuestas.env" >/dev/null 2>&1; printf '%s' "${!v-}")
    printf -v "$v" '%s' "$val"
  done
  # Migrate saved answers from builds created before INCLUDE_LIBRE_APPS became
  # canonical. An explicit current environment value always wins.
  if ! del_entorno INCLUDE_LIBRE_APPS \
      && ! grep -q '^INCLUDE_LIBRE_APPS=' "$W/respuestas.env" \
      && grep -q '^HACER_LIBRES=' "$W/respuestas.env"; then
    val=$(. "$W/respuestas.env" >/dev/null 2>&1; printf '%s' "${HACER_LIBRES-}")
    case "$val" in
      si) INCLUDE_LIBRE_APPS=yes ;;
      no) INCLUDE_LIBRE_APPS=no ;;
      *) die "invalid legacy HACER_LIBRES='$val'; expected si or no" "HACER_LIBRES antiguo no valido: '$val'; se esperaba si o no" ;;
    esac
  fi
  case "$INCLUDE_LIBRE_APPS" in
    yes|no) ;;
    *) die "invalid INCLUDE_LIBRE_APPS='$INCLUDE_LIBRE_APPS'; expected yes or no" "INCLUDE_LIBRE_APPS no valido: '$INCLUDE_LIBRE_APPS'; se esperaba yes o no" ;;
  esac
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
  local yes_hint no_hint
  if [[ $OMARCHY_LANG == es ]]; then yes_hint=S/n; no_hint=s/N; else yes_hint=Y/n; no_hint=y/N; fi
  read -r -p "  $q [$([[ $def == si ]] && echo "$yes_hint" || echo "$no_hint")]: " ans </dev/tty || ans=""
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
      Spanish*|Mexican*|*Mexico*) km=es; xk=es ;;
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
  phase "deps · host dependencies" "deps · dependencias del anfitrion"
  [[ $(uname -s) == Darwin ]] || die "this only runs on macOS" "esto solo corre en macOS"
  [[ $(uname -m) == arm64  ]] || die "Apple Silicon is required (HVF for aarch64)" "hace falta Apple Silicon (HVF para aarch64)"
  command -v brew >/dev/null || die "Homebrew is missing: https://brew.sh" "falta Homebrew: https://brew.sh"
  for f in qemu expect aria2; do
    brew list --formula "$f" >/dev/null 2>&1 || { info "installing $f..." "instalando $f..."; brew install "$f" >/dev/null; }
  done
  command -v qemu-system-aarch64 >/dev/null || die "qemu-system-aarch64 is missing" "falta qemu-system-aarch64"
  command -v expect >/dev/null || die "expect is missing" "falta expect"
  # git and python3 come from the Command Line Tools, which on a freshly
  # set up Mac are not present. They are used in 'prepare' and in branch checking.
  for c in git python3 zip shasum curl hdiutil; do
    command -v "$c" >/dev/null || die "'$c' is missing (did you run 'xcode-select --install'?)" "falta '$c' (¿ejecutaste 'xcode-select --install'?)"
  done
  [[ -x $UTMCTL ]] || die "UTM is missing: brew install --cask utm" "falta UTM: brew install --cask utm"
  # Measured in a real build: the disk reaches 9.5 GB, the copy for
  # sanitizing to another 6.5 and the zip to 4. With APFS clones the peak is around 30.
  local free; free=$(df -g "$HOME" | tail -1 | awk '{print $4}')
  (( free > 40 )) || die "~40 GB free is required (${free} GB available)" "hacen falta ~40 GB libres (hay ${free} GB)"
  ok "qemu $(qemu-system-aarch64 --version | head -1 | awk '{print $4}'), UTM $(defaults read /Applications/UTM.app/Contents/Info.plist CFBundleShortVersionString), ${free} GB free" \
     "qemu $(qemu-system-aarch64 --version | head -1 | awk '{print $4}'), UTM $(defaults read /Applications/UTM.app/Contents/Info.plist CFBundleShortVersionString), ${free} GB libres"
}

# Any phase can be run standalone with --only/--from, so the directories
# they cannot depend on deps having been passed.
ensure_dirs() { mkdir -p "$W"/{dl,vm,provision,scripts,logs,dist,shots}; }

# ─────────────────────────────── phase: fetch ───────────────────────────────
sha256_file() { shasum -a 256 "$1" | awk '{print $1}'; }

validate_sha256() {
  local digest="$1" label="$2"
  [[ $digest =~ ^[0-9a-fA-F]{64}$ ]] \
    || die "invalid SHA-256 for $label: expected 64 hexadecimal digits" "sha256 no valido para $label: se esperaban 64 digitos hexadecimales"
}

validate_fetch_url() {
  case "$1" in
    https://*|file://*) ;;
    *) die "insecure URL for $2: only https:// and file:// are allowed" "URL no segura para $2: solo se permiten https:// y file://" ;;
  esac
}

verify_sha256() {
  local file="$1" expected="$2" label="$3" got
  validate_sha256 "$expected" "$label"
  expected=$(printf '%s' "$expected" | tr 'A-F' 'a-f')
  got=$(sha256_file "$file") || { warn "could not calculate the SHA-256 of $label" "no se pudo calcular el sha256 de $label"; return 1; }
  if [[ $got != "$expected" ]]; then
    warn "$label does not match the pinned SHA-256 (expected $expected, got $got)" "$label no cuadra con el sha256 fijado (esperado $expected, obtenido $got)"
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
      || die "cached $label failed verification; retained at $dest for inspection" "$label en cache no supera la verificacion; se conserva en $dest para inspeccion"
    ok "$label cached, SHA-256 verified ($(du -h "$dest" | cut -f1))" "$label en cache, sha256 verificado ($(du -h "$dest" | cut -f1))"
    return 0
  fi

  info "$label"
  if ! aria2c -x8 -s8 -c --file-allocation=none -q \
      -d "$(dirname "$partial")" -o "$(basename "$partial")" "$url"; then
    die "could not download $label ($url); the partial download was retained for resuming" "no se pudo descargar $label ($url); la descarga parcial se conserva para reanudar"
  fi
  if ! verify_sha256 "$partial" "$expected" "$label"; then
    rm -f "$partial" "$partial.aria2"
    die "the $label download was rejected" "se rechazo la descarga de $label"
  fi
  mv "$partial" "$dest"
  rm -f "$partial.aria2"
  ok "$label downloaded, SHA-256 verified ($(du -h "$dest" | cut -f1))" "$label descargado, sha256 verificado ($(du -h "$dest" | cut -f1))"
}

ph_fetch() {
  phase "fetch · base images" "fetch · imagenes base"
  local iso="$W/dl/alpine-virt-aarch64.iso"
  local tgz="$W/dl/alarm-rootfs.tgz"

  fetch_verified "$ALPINE_URL" "$ALPINE_SHA256" "$iso" \
    "Alpine $ALPINE_ISO ($(ui_text 'live bootstrap environment' 'entorno live para el bootstrap'))"
  fetch_verified "$ALARM_URL" "$ALARM_SHA256" "$tgz" \
    "$(ui_text 'Arch Linux ARM rootfs' 'rootfs de Arch Linux ARM')"
}

# ───────────────────────────── core Git source lock ─────────────────────────
CORE_SOURCE_KEYS=(omarchy omarchy-pkgs ttfx yay xdg-terminal-exec yaru-icon-theme
                  ttf-ia-writer tzupdate ufw-docker mise-bin aether cliamp
                  1password-cli typora localsend-bin google-chrome
                  dotnet-runtime-bin obs-studio-pkgbuild obs-studio-source
                  obs-libdshowcapture obs-browser obs-websocket)

write_core_source_lock() {
  mkdir -p "$W/provision"
  cat > "$W/provision/core-git-sources.tsv" <<'__PAYLOAD_CORE_GIT_SOURCES_TSV__'
# key  repository  refresh-ref  reviewed-commit
#
# The build fetches only the commit in column 4. Column 3 is used by the
# maintainer refresh tool and, for Omarchy, by the post-install update hook.
omarchy https://github.com/basecamp/omarchy.git refs/heads/quattro 56fbaf4689e3eb6867c0b7f375ae49964f183774
omarchy-pkgs https://github.com/omacom-io/omarchy-pkgs.git HEAD 6daa7c90e481c61b4e65fbed1e3c048bd25c790e
ttfx https://github.com/omacom-io/ttfx.git HEAD 7203e354498462064b7c0a89375051f65cf2ce99
yay https://aur.archlinux.org/yay.git HEAD cb43f84828ab4f9700f7c6f9c6d7a923d4cfaff0
xdg-terminal-exec https://aur.archlinux.org/xdg-terminal-exec.git HEAD a52e8f23c0be7d482b944c6cf5ddee172da171e4
yaru-icon-theme https://aur.archlinux.org/yaru.git HEAD 7206d6736121b4564998262d99d6afdbc28b1563
ttf-ia-writer https://aur.archlinux.org/ttf-ia-writer.git HEAD e9aa94080338d7a7f83a561ce64bf30ab4fb24e4
tzupdate https://aur.archlinux.org/tzupdate.git HEAD 1b3c3bdf6289a348da09eed57d653d3f6dce1956
ufw-docker https://aur.archlinux.org/ufw-docker.git HEAD 76e18ac8c40a4e8f018f4b35289718a29eca3d6d
mise-bin https://aur.archlinux.org/mise-bin.git HEAD 7e310939340a658f9cd3fcbf6fbc7f1904ba6f88
aether https://aur.archlinux.org/aether.git HEAD 0f047f40a200121075ca3cedce59ddf226f2a0f1
cliamp https://aur.archlinux.org/cliamp.git HEAD 76b9ce02837a49de0fa50cfa3da5d1c0c692ece5
1password-cli https://aur.archlinux.org/1password-cli.git HEAD b0d208821677a5dbb883a8b92f06a5c92b9e861a
typora https://aur.archlinux.org/typora.git HEAD 029ff738d5928db82edfa34fc365fcb6743a74e5
localsend-bin https://aur.archlinux.org/localsend-bin.git HEAD a408db7b17712e0d56c49ca3feb5546808a3220c
google-chrome https://aur.archlinux.org/google-chrome.git HEAD 1cf56b57305f59919b74a559906d60002edd95a3
omazed https://aur.archlinux.org/omazed.git HEAD 8ca767b734d455000b37919c2aa71038b9a04290
dotnet-runtime-bin https://aur.archlinux.org/dotnet-core-bin.git HEAD 2c499d7ce634efb8e93eee4c4239490b02e98e09
obs-studio-pkgbuild https://gitlab.archlinux.org/archlinux/packaging/packages/obs-studio.git HEAD 8a0774a179eba2c08b7fff44252098d609c9c6d5
obs-studio-source https://github.com/obsproject/obs-studio.git refs/tags/32.2.2^{} ba2f32bdf791005443988a4955e963663e16b1ed
obs-libdshowcapture https://github.com/obsproject/libdshowcapture.git PINNED 8878638324393815512f802640b0d5ce940161f1
obs-browser https://github.com/obsproject/obs-browser.git PINNED 3f0a2cdf378939ebe3c6f9ab36d4ea100c25aac2
obs-websocket https://github.com/obsproject/obs-websocket.git PINNED 1ef34bf48110c2a18184e50e41cd0b1a855e2147
__PAYLOAD_CORE_GIT_SOURCES_TSV__
}

write_free_app_artifact_lock() {
  mkdir -p "$W/provision"
  cat > "$W/provision/free-app-artifacts.tsv" <<'__PAYLOAD_FREE_APP_ARTIFACTS_TSV__'
# key  exact-url  sha256  required-signing-fingerprint
pinta-package https://geo.mirror.pkgbuild.com/extra/os/x86_64/pinta-3.1.2-2-any.pkg.tar.zst 3f9d4977ecef3e97bf6bd1daea5e677d74d4173f3222679fc085940e7751c7ed 14E46FE5FD69F2E287E244DB632C3CC0D1C9CAF6
__PAYLOAD_FREE_APP_ARTIFACTS_TSV__
}

write_optional_app_artifact_lock() {
  mkdir -p "$W/provision"
  cat > "$W/provision/optional-app-artifacts.tsv" <<'__PAYLOAD_OPTIONAL_APP_ARTIFACTS_TSV__'
# key  exact-url  sha256  required-signing-fingerprint
1password-package https://downloads.1password.com/linux/tar/stable/aarch64/1password-8.12.34.arm64.tar.gz ea5102363d6cf3442b96a7abd6743da8c1d261f56a628e1a3c183d84fa65fdcb 3FEF9748469ADBE15DA7CA80AC2D62742012EA22
obsidian-package https://github.com/obsidianmd/obsidian-releases/releases/download/v1.13.7/obsidian-1.13.7-arm64.tar.gz 98aac34d1f132a35cf506fc3fa196d595dcdeefdebd44b0cc5faaa7a1a210de2 -
zed-package https://github.com/zed-industries/zed/releases/download/v1.17.2/zed-linux-aarch64.tar.gz 4f75332ab8155a5a62b0cdc473473cf8938959cf3cd2b0145e2975969d7e8929 -
__PAYLOAD_OPTIONAL_APP_ARTIFACTS_TSV__
}

validate_core_source_lock() {
  local lock="$1" line key url ref commit extra expected seen=" "
  [[ -s $lock ]] || die "missing core Git source lock: $lock" "falta el bloqueo de fuentes Git principales: $lock"
  while IFS= read -r line || [[ -n $line ]]; do
    [[ -z $line || $line == \#* ]] && continue
    read -r key url ref commit extra <<< "$line"
    [[ -z ${extra:-} && $key =~ ^[a-z0-9][a-z0-9._+-]*$ && $url == https://* \
        && $ref =~ ^(HEAD|PINNED|refs/heads/[A-Za-z0-9._/-]+|refs/tags/[A-Za-z0-9._/+:-]+\^\{\})$ \
        && $commit =~ ^[0-9a-f]{40}$ ]] \
      || die "invalid core Git source-lock record: $line" "registro invalido en el bloqueo de fuentes Git: $line"
    [[ $seen != *" $key "* ]] || die "duplicate core Git source-lock key: $key" "clave duplicada en el bloqueo de fuentes Git: $key"
    seen="$seen$key "
  done < "$lock"
  for expected in "${CORE_SOURCE_KEYS[@]}"; do
    [[ $seen == *" $expected "* ]] || die "missing core Git source-lock key: $expected" "falta la clave del bloqueo de fuentes Git: $expected"
  done
  read -r key url ref commit < <(awk '$1 == "omarchy" { print; exit }' "$lock")
  [[ $url == https://github.com/basecamp/omarchy.git && $ref == "refs/heads/$OMARCHY_REF" ]] \
    || die "the Omarchy source lock is incompatible with OMARCHY_REF='$OMARCHY_REF'" "el bloqueo de Omarchy no es compatible con OMARCHY_REF='$OMARCHY_REF'"
}

validate_free_app_artifact_lock() {
  local lock="$1" line key url digest signer extra count=0
  [[ -s $lock ]] || die "missing free-app artifact lock: $lock" "falta el bloqueo de artefactos de apps libres: $lock"
  while IFS= read -r line || [[ -n $line ]]; do
    [[ -z $line || $line == \#* ]] && continue
    read -r key url digest signer extra <<< "$line"
    [[ -z ${extra:-} && $key == pinta-package \
        && $url =~ ^https://geo\.mirror\.pkgbuild\.com/extra/os/x86_64/pinta-[0-9][A-Za-z0-9._+-]*-any\.pkg\.tar\.zst$ \
        && $digest =~ ^[0-9a-f]{64}$ && $signer =~ ^[0-9A-F]{40}$ ]] \
      || die "invalid free-app artifact-lock record: $line" "registro invalido en el bloqueo de artefactos de apps libres: $line"
    count=$((count + 1))
  done < "$lock"
  [[ $count == 1 ]] || die "free-app artifact lock must contain exactly one Pinta record" "el bloqueo de artefactos debe contener exactamente un registro de Pinta"
}

validate_optional_app_artifact_lock() {
  local lock="$1" line key url digest signer extra seen=" "
  [[ -s $lock ]] || die "missing optional-app artifact lock: $lock" "falta el bloqueo de artefactos de apps opcionales: $lock"
  while IFS= read -r line || [[ -n $line ]]; do
    [[ -z $line || $line == \#* ]] && continue
    read -r key url digest signer extra <<< "$line"
    [[ -z ${extra:-} && $key =~ ^(1password-package|obsidian-package|zed-package)$ \
        && $url == https://* && $digest =~ ^[0-9a-f]{64}$ \
        && $signer =~ ^(-|[0-9A-F]{40})$ ]] \
      || die "invalid optional-app artifact-lock record: $line" "registro invalido en el bloqueo de artefactos opcionales: $line"
    [[ $seen != *" $key "* ]] || die "duplicate optional-app artifact-lock key: $key" "clave duplicada en el bloqueo de artefactos opcionales: $key"
    seen="$seen$key "
  done < "$lock"
  [[ $seen == *" 1password-package "* && $seen == *" obsidian-package "* ]] \
    || die "optional-app artifact lock is incomplete" "el bloqueo de artefactos opcionales esta incompleto"
}

core_source_record() {
  awk -v key="$1" '$1 == key { print; exit }' "$2"
}

# ───────────────────── Arch Linux ARM repository snapshot ──────────────────
ALARM_REPOSITORIES=(core extra alarm aur)

capture_alarm_mirror() {
  local mirror="$1" destination="$2" marker_before marker_after repository timeout
  mkdir -p "$destination"
  marker_before=$(curl -fsSL --max-time 30 "$mirror/aarch64/sync") || return 1
  [[ $marker_before =~ ^[0-9]+$ ]] || return 1
  for repository in "${ALARM_REPOSITORIES[@]}"; do
    timeout=120
    [[ $repository == extra ]] && timeout=240
    curl -fsSL --max-time "$timeout" \
      "$mirror/aarch64/$repository/$repository.db" \
      -o "$destination/$repository.db" || return 1
  done
  marker_after=$(curl -fsSL --max-time 30 "$mirror/aarch64/sync") || return 1
  [[ $marker_after == "$marker_before" ]] || return 1
  printf '%s\n' "$marker_after"
}

validate_alarm_repository_snapshot() {
  local directory="$W/provision/alarm-repositories"
  [[ -x $W/provision/alarm-repository-snapshot.py ]] \
    || die "the repository snapshot validator is missing; run prepare" "falta el validador de la captura de repositorios; ejecuta prepare"
  [[ -d $directory && -s $directory/manifest.tsv ]] \
    || die "the Arch Linux ARM repository snapshot is missing; run prepare" "falta la captura de repositorios de Arch Linux ARM; ejecuta prepare"
  python3 "$W/provision/alarm-repository-snapshot.py" validate \
    "$directory" "$directory/manifest.tsv" \
    || die "the Arch Linux ARM repository snapshot is invalid; run prepare" "la captura de repositorios de Arch Linux ARM no es valida; ejecuta prepare"
}

capture_alarm_repository_snapshot() {
  validate_fetch_url "$ALARM_MIRROR_PRIMARY" "$(ui_text 'primary Arch Linux ARM mirror' 'mirror primario de Arch Linux ARM')"
  validate_fetch_url "$ALARM_MIRROR_SECONDARY" "$(ui_text 'secondary Arch Linux ARM mirror' 'mirror secundario de Arch Linux ARM')"
  [[ $ALARM_MIRROR_PRIMARY != "$ALARM_MIRROR_SECONDARY" ]] \
    || die "two distinct Arch Linux ARM mirrors are required" "se necesitan dos mirrors distintos de Arch Linux ARM"

  local temporary primary secondary candidate final previous
  local primary_marker secondary_marker repository captured_at snapshot
  temporary=$(mktemp -d "$W/provision/.alarm-repository-snapshot.XXXXXX")
  primary="$temporary/primary"
  secondary="$temporary/secondary"
  candidate="$temporary/candidate"
  final="$W/provision/alarm-repositories"
  previous="$W/provision/.alarm-repositories.previous.$$"

  info "capturing all four repository databases from two official HTTPS mirrors..." \
       "capturando las cuatro bases de repositorios desde dos mirrors HTTPS oficiales..."
  primary_marker=$(capture_alarm_mirror "$ALARM_MIRROR_PRIMARY" "$primary") \
    || { rm -rf "$temporary"; die "the primary mirror did not provide one stable repository set" "el mirror primario no proporciono un conjunto estable de repositorios"; }
  secondary_marker=$(capture_alarm_mirror "$ALARM_MIRROR_SECONDARY" "$secondary") \
    || { rm -rf "$temporary"; die "the secondary mirror did not provide one stable repository set" "el mirror secundario no proporciono un conjunto estable de repositorios"; }
  [[ $primary_marker == "$secondary_marker" ]] \
    || { rm -rf "$temporary"; die "the official mirrors report different repository sync markers" "los mirrors oficiales informan marcadores de sincronizacion distintos"; }

  mkdir -p "$candidate"
  for repository in "${ALARM_REPOSITORIES[@]}"; do
    cmp -s "$primary/$repository.db" "$secondary/$repository.db" \
      || { rm -rf "$temporary"; die "$repository.db differs between the official mirrors" "$repository.db difiere entre los mirrors oficiales"; }
    cp "$primary/$repository.db" "$candidate/$repository.db"
  done
  captured_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  python3 "$W/provision/alarm-repository-snapshot.py" write-manifest \
    "$candidate" "$candidate/manifest.tsv" \
    "$ALARM_MIRROR_PRIMARY" "$ALARM_MIRROR_SECONDARY" \
    "$primary_marker" "$captured_at" \
    || { rm -rf "$temporary"; die "could not write the repository snapshot manifest" "no se pudo escribir el manifiesto de la captura de repositorios"; }
  python3 "$W/provision/alarm-repository-snapshot.py" validate \
    "$candidate" "$candidate/manifest.tsv" \
    || { rm -rf "$temporary"; die "the captured repository set failed validation" "el conjunto capturado de repositorios no supero la validacion"; }

  [[ ! -e $previous ]] || { rm -rf "$temporary"; die "temporary repository snapshot path already exists: $previous" "ya existe la ruta temporal de la captura: $previous"; }
  [[ ! -e $final ]] || mv "$final" "$previous"
  if ! mv "$candidate" "$final"; then
    [[ ! -e $previous ]] || mv "$previous" "$final"
    rm -rf "$temporary"
    die "could not publish the captured repository set" "no se pudo publicar el conjunto capturado de repositorios"
  fi
  rm -rf "$previous" "$temporary"
  snapshot=$(awk -F '\t' '$1 == "snapshot-id" { print $2 }' "$final/manifest.tsv")
  ok "repository snapshot ${snapshot:0:12}, sync marker $primary_marker" \
     "captura de repositorios ${snapshot:0:12}, marcador de sincronizacion $primary_marker"
}

# ────────────────────────────── phase: prepare ──────────────────────────────
ph_prepare() {
  phase "prepare · package list" "prepare · lista de paquetes"
  write_payloads
  validate_core_source_lock "$W/provision/core-git-sources.tsv"
  capture_alarm_repository_snapshot
  local omarchy_commit
  omarchy_commit=$(core_source_record omarchy "$W/provision/core-git-sources.tsv" | awk '{ print $4 }')
  # The list is computed against the REVIEWED commit of Omarchy intersected with what
  # exists in Arch Linux ARM. Doing it here, rather than with a fixed list, prevents the
  # package selection from disagreeing with the source tree installed in stage 3.
  local base=/tmp/om-base.$$ core extra
  core="$W/provision/alarm-repositories/core.db"
  extra="$W/provision/alarm-repositories/extra.db"
  curl -fsSL --max-time 60 \
    "https://raw.githubusercontent.com/basecamp/omarchy/$omarchy_commit/install/omarchy-base.packages" \
    -o "$base" || die "could not read Omarchy's package list" "no se pudo leer la lista de paquetes de Omarchy"
  local d=/tmp/alarmdb.$$; rm -rf "$d"; mkdir -p "$d"; ( cd "$d" && tar -xzf "$core"; tar -xzf "$extra" )
  ls -1 "$d" | sed -E 's/-[^-]+-[^-]+$//' | sort -u > /tmp/alarm-pkgs.$$

  # quickshell-git does not exist in ALARM; quickshell 0.3.x replaces it.
  # nvim and ttf-jetbrains-mono-nerd-basic are proper names from Omarchy.
  python3 - "$base" /tmp/alarm-pkgs.$$ "$W/provision" "$OMARCHY_LANG" <<'PYEOF'
import sys, pathlib
base, alarm_f, out, lang = sys.argv[1], sys.argv[2], pathlib.Path(sys.argv[3]), sys.argv[4]
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
if lang == "es":
    print(f"  nucleo={len(core)}  extras={len(ext)}  sin equivalente en ARM={len(set(miss))}")
    print("  no disponibles:", " ".join(sorted(set(miss))))
else:
    print(f"  core={len(core)}  extras={len(ext)}  without an ARM equivalent={len(set(miss))}")
    print("  unavailable:", " ".join(sorted(set(miss))))
PYEOF
  rm -rf "$d" "$base" /tmp/alarm-pkgs.$$
  # Without this, a write error would go unnoticed and the build would die later,
  # far from the cause.
  [ -s "$W/provision/packages-core.txt" ] || die "could not write the package lists" "no se pudieron escribir las listas de paquetes"
  ok "lists generated against pinned Omarchy ${omarchy_commit:0:12}: $(grep -cvE '^#|^$' "$W/provision/packages-core.txt") core, $(grep -cvE '^#|^$' "$W/provision/packages-extra.txt") extras" \
     "listas generadas contra Omarchy fijado ${omarchy_commit:0:12}: $(grep -cvE '^#|^$' "$W/provision/packages-core.txt") en el nucleo, $(grep -cvE '^#|^$' "$W/provision/packages-extra.txt") extras"
}

# ─────────────────────────── payloads (written to $W) ──────────────────
write_payloads() {
  # Provision files and expect harnesses are materialized here so that
  # this script is self-contained: a single file reproduces the entire process.
mkdir -p "$W/provision"
write_core_source_lock
write_free_app_artifact_lock
write_optional_app_artifact_lock
cat > "$W/provision/alarm-repository-snapshot.py" <<'__PAYLOAD_ALARM_REPOSITORY_SNAPSHOT_PY__'
#!/usr/bin/env python3
"""Validate an ALARM repository snapshot and record installed package provenance."""

from __future__ import annotations

import argparse
import base64
import binascii
import hashlib
import pathlib
import re
import subprocess
import sys
import tarfile


REPOSITORIES = ("core", "extra", "alarm", "aur")
FORMAT = "alarm-repository-snapshot-v1"
SHA256 = re.compile(r"[0-9a-f]{64}")


def fail(message: str) -> "NoReturn":
    raise SystemExit(message)


def file_sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def snapshot_id(records: dict[str, tuple[str, int]]) -> str:
    canonical = "".join(
        f"repo\t{repository}\t{records[repository][0]}\t{records[repository][1]}\n"
        for repository in REPOSITORIES
    )
    return hashlib.sha256(canonical.encode()).hexdigest()


def load_manifest(path: pathlib.Path) -> tuple[dict[str, str], dict[str, tuple[str, int]]]:
    metadata: dict[str, str] = {}
    records: dict[str, tuple[str, int]] = {}
    for number, raw in enumerate(path.read_text().splitlines(), 1):
        if not raw or raw.startswith("#"):
            continue
        fields = raw.split("\t")
        if fields[0] == "repo":
            if len(fields) != 4 or fields[1] not in REPOSITORIES:
                fail(f"invalid repository record at {path}:{number}")
            if fields[1] in records or not SHA256.fullmatch(fields[2]):
                fail(f"duplicate or invalid repository record at {path}:{number}")
            try:
                size = int(fields[3])
            except ValueError:
                fail(f"invalid repository size at {path}:{number}")
            if size <= 0:
                fail(f"invalid repository size at {path}:{number}")
            records[fields[1]] = (fields[2], size)
        else:
            if len(fields) != 2 or fields[0] in metadata:
                fail(f"duplicate or invalid metadata at {path}:{number}")
            metadata[fields[0]] = fields[1]

    required = {
        "format",
        "architecture",
        "primary-url",
        "secondary-url",
        "sync-marker",
        "captured-at",
        "snapshot-id",
    }
    if set(metadata) != required:
        fail(f"snapshot metadata fields do not match {sorted(required)}")
    if metadata["format"] != FORMAT or metadata["architecture"] != "aarch64":
        fail("unsupported repository snapshot format or architecture")
    if not metadata["primary-url"].startswith("https://") or not metadata[
        "secondary-url"
    ].startswith("https://"):
        fail("repository snapshot sources must use HTTPS")
    if metadata["primary-url"] == metadata["secondary-url"]:
        fail("repository snapshot requires two distinct official mirrors")
    if not metadata["sync-marker"].isdigit():
        fail("invalid repository snapshot sync marker")
    if set(records) != set(REPOSITORIES):
        fail(f"snapshot repositories do not match {list(REPOSITORIES)}")
    expected_id = snapshot_id(records)
    if metadata["snapshot-id"] != expected_id:
        fail("repository snapshot ID does not match its records")
    return metadata, records


def validate(snapshot_dir: pathlib.Path, manifest: pathlib.Path) -> tuple[dict[str, str], dict[str, tuple[str, int]]]:
    metadata, records = load_manifest(manifest)
    actual_names = {path.name for path in snapshot_dir.glob("*.db")}
    expected_names = {f"{repository}.db" for repository in REPOSITORIES}
    if actual_names != expected_names:
        fail(f"snapshot database files do not match {sorted(expected_names)}")
    for repository in REPOSITORIES:
        path = snapshot_dir / f"{repository}.db"
        expected_hash, expected_size = records[repository]
        if path.stat().st_size != expected_size:
            fail(f"{repository}.db size does not match the snapshot manifest")
        if file_sha256(path) != expected_hash:
            fail(f"{repository}.db SHA-256 does not match the snapshot manifest")
        try:
            with tarfile.open(path, "r:*") as archive:
                next((member for member in archive if member.name.endswith("/desc")))
        except (tarfile.TarError, StopIteration):
            fail(f"{repository}.db is not a usable pacman repository database")
    return metadata, records


def write_manifest(args: argparse.Namespace) -> None:
    snapshot_dir = pathlib.Path(args.snapshot_dir)
    records = {
        repository: (
            file_sha256(snapshot_dir / f"{repository}.db"),
            (snapshot_dir / f"{repository}.db").stat().st_size,
        )
        for repository in REPOSITORIES
    }
    lines = [
        f"format\t{FORMAT}",
        "architecture\taarch64",
        f"primary-url\t{args.primary_url}",
        f"secondary-url\t{args.secondary_url}",
        f"sync-marker\t{args.sync_marker}",
        f"captured-at\t{args.captured_at}",
        f"snapshot-id\t{snapshot_id(records)}",
    ]
    lines.extend(
        f"repo\t{repository}\t{records[repository][0]}\t{records[repository][1]}"
        for repository in REPOSITORIES
    )
    pathlib.Path(args.manifest).write_text("\n".join(lines) + "\n")


def parse_desc(raw: bytes) -> dict[str, list[str]]:
    fields: dict[str, list[str]] = {}
    key: str | None = None
    for line in raw.decode("utf-8", "strict").splitlines():
        if len(line) >= 3 and line.startswith("%") and line.endswith("%"):
            key = line[1:-1]
            fields.setdefault(key, [])
        elif line and key is not None:
            fields[key].append(line)
    return fields


def one(fields: dict[str, list[str]], key: str) -> str:
    values = fields.get(key, [])
    if len(values) != 1:
        fail(f"repository record has no unique %{key}% field")
    return values[0]


def repository_packages(snapshot_dir: pathlib.Path) -> dict[tuple[str, str, str], list[dict[str, str]]]:
    packages: dict[tuple[str, str, str], list[dict[str, str]]] = {}
    for repository in REPOSITORIES:
        with tarfile.open(snapshot_dir / f"{repository}.db", "r:*") as archive:
            for member in archive:
                if not member.isfile() or not member.name.endswith("/desc"):
                    continue
                source = archive.extractfile(member)
                if source is None:
                    continue
                try:
                    fields = parse_desc(source.read())
                except UnicodeDecodeError:
                    continue
                if "NAME" not in fields:
                    continue
                name, version = one(fields, "NAME"), one(fields, "VERSION")
                package_hash = one(fields, "SHA256SUM")
                signature = one(fields, "PGPSIG")
                if not SHA256.fullmatch(package_hash):
                    fail(f"invalid package SHA-256 for {repository}/{name}")
                try:
                    signature_bytes = base64.b64decode(signature, validate=True)
                except (ValueError, binascii.Error):
                    fail(f"invalid package PGP signature for {repository}/{name}")
                architecture = one(fields, "ARCH")
                key = (name, version, architecture)
                packages.setdefault(key, []).append(
                    {
                        "repository": repository,
                        "filename": one(fields, "FILENAME"),
                        "package-sha256": package_hash,
                        "signature-sha256": hashlib.sha256(signature_bytes).hexdigest(),
                    }
                )
    return packages


def installed_packages(local_db: pathlib.Path) -> list[tuple[str, str, str, pathlib.Path]]:
    installed: list[tuple[str, str, str, pathlib.Path]] = []
    for desc in local_db.glob("*/desc"):
        fields = parse_desc(desc.read_bytes())
        if "NAME" not in fields:
            continue
        installed.append(
            (one(fields, "NAME"), one(fields, "VERSION"), one(fields, "ARCH"), desc.parent)
        )
    if not installed:
        fail(f"no installed packages found under {local_db}")
    return sorted(installed)


def cached_package_mtree(
    cache_dir: pathlib.Path, local_record: pathlib.Path, record: dict[str, str]
) -> str | None:
    package = cache_dir / record["filename"]
    local_mtree = local_record / "mtree"
    if not package.is_file() or not local_mtree.is_file():
        return None
    if file_sha256(package) != record["package-sha256"]:
        return None
    extracted = subprocess.run(
        ["bsdtar", "-xOf", str(package), ".MTREE"],
        capture_output=True,
        check=False,
    )
    if extracted.returncode != 0 or extracted.stdout != local_mtree.read_bytes():
        return None
    return hashlib.sha256(extracted.stdout).hexdigest()


HEADER = (
    "snapshot-id\tevidence\trepository-candidate\tname\tversion\tarchitecture\t"
    "filename\tpackage-sha256\tpgp-signature-sha256\tinstalled-mtree-sha256"
)


def provenance_lines(
    snapshot_dir: pathlib.Path,
    manifest: pathlib.Path,
    local_db: pathlib.Path,
    cache_dir: pathlib.Path,
) -> list[str]:
    metadata, _ = validate(snapshot_dir, manifest)
    available = repository_packages(snapshot_dir)
    lines = [HEADER]
    for name, version, architecture, local_record in installed_packages(local_db):
        records = available.get((name, version, architecture), [])
        if not records:
            values = (
                metadata["snapshot-id"], "local-or-unknown", "-", name, version,
                architecture, "-", "-", "-", "-",
            )
        elif len(records) > 1:
            candidates = ",".join(record["repository"] for record in records)
            values = (
                metadata["snapshot-id"], "ambiguous-snapshot-match", candidates,
                name, version, architecture, "-", "-", "-", "-",
            )
        else:
            record = records[0]
            mtree_hash = cached_package_mtree(cache_dir, local_record, record)
            evidence = "repository-cache+mtree" if mtree_hash else "snapshot-metadata-only"
            values = (
                metadata["snapshot-id"],
                evidence,
                record["repository"],
                name,
                version,
                architecture,
                record["filename"],
                record["package-sha256"],
                record["signature-sha256"],
                mtree_hash or "-",
            )
        lines.append("\t".join(values))
    return lines


def write_provenance(args: argparse.Namespace) -> None:
    snapshot_dir = pathlib.Path(args.snapshot_dir)
    lines = provenance_lines(
        snapshot_dir,
        pathlib.Path(args.manifest),
        pathlib.Path(args.local_db),
        pathlib.Path(args.cache_dir),
    )
    pathlib.Path(args.output).write_text("\n".join(lines) + "\n")


def validate_provenance(args: argparse.Namespace) -> None:
    snapshot_dir = pathlib.Path(args.snapshot_dir)
    metadata, _ = validate(snapshot_dir, pathlib.Path(args.manifest))
    available = repository_packages(snapshot_dir)
    installed = {
        (name, version, architecture): local_record
        for name, version, architecture, local_record in installed_packages(pathlib.Path(args.local_db))
    }
    rows = pathlib.Path(args.provenance).read_text().splitlines()
    if not rows or rows[0] != HEADER:
        fail("installed-package provenance header is invalid")
    seen: set[tuple[str, str, str]] = set()
    for number, row in enumerate(rows[1:], 2):
        fields = row.split("\t")
        if len(fields) != 10:
            fail(f"invalid installed-package provenance row {number}")
        snapshot, evidence, candidate, name, version, architecture, filename, package_hash, signature_hash, mtree_hash = fields
        key = (name, version, architecture)
        if snapshot != metadata["snapshot-id"] or key not in installed or key in seen:
            fail(f"wrong snapshot, unknown package, or duplicate provenance row {number}")
        seen.add(key)
        records = available.get(key, [])
        if not records:
            expected = ("local-or-unknown", "-", "-", "-", "-", "-")
        elif len(records) > 1:
            expected = (
                "ambiguous-snapshot-match",
                ",".join(record["repository"] for record in records),
                "-", "-", "-", "-",
            )
        else:
            record = records[0]
            if evidence not in {"repository-cache+mtree", "snapshot-metadata-only"}:
                fail(f"invalid repository evidence in provenance row {number}")
            expected = (
                evidence,
                record["repository"],
                record["filename"],
                record["package-sha256"],
                record["signature-sha256"],
                mtree_hash,
            )
            if evidence == "repository-cache+mtree":
                local_mtree = installed[key] / "mtree"
                if not SHA256.fullmatch(mtree_hash) or not local_mtree.is_file() \
                        or file_sha256(local_mtree) != mtree_hash:
                    fail(f"installed mtree evidence does not validate in provenance row {number}")
            elif mtree_hash != "-":
                fail(f"metadata-only provenance has mtree evidence in row {number}")
        actual = (evidence, candidate, filename, package_hash, signature_hash, mtree_hash)
        if actual != expected:
            fail(f"installed-package provenance fields do not validate in row {number}")
    if seen != set(installed):
        fail("installed-package provenance is incomplete")


def main() -> None:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    writer = subparsers.add_parser("write-manifest")
    writer.add_argument("snapshot_dir")
    writer.add_argument("manifest")
    writer.add_argument("primary_url")
    writer.add_argument("secondary_url")
    writer.add_argument("sync_marker")
    writer.add_argument("captured_at")
    writer.set_defaults(handler=write_manifest)

    checker = subparsers.add_parser("validate")
    checker.add_argument("snapshot_dir")
    checker.add_argument("manifest")
    checker.set_defaults(handler=lambda args: validate(pathlib.Path(args.snapshot_dir), pathlib.Path(args.manifest)))

    provenance = subparsers.add_parser("provenance")
    provenance.add_argument("snapshot_dir")
    provenance.add_argument("manifest")
    provenance.add_argument("output")
    provenance.add_argument("--local-db", default="/var/lib/pacman/local")
    provenance.add_argument("--cache-dir", default="/var/cache/pacman/pkg")
    provenance.set_defaults(handler=write_provenance)

    provenance_check = subparsers.add_parser("validate-provenance")
    provenance_check.add_argument("snapshot_dir")
    provenance_check.add_argument("manifest")
    provenance_check.add_argument("provenance")
    provenance_check.add_argument("--local-db", default="/var/lib/pacman/local")
    provenance_check.set_defaults(handler=validate_provenance)

    args = parser.parse_args()
    args.handler(args)


if __name__ == "__main__":
    main()
__PAYLOAD_ALARM_REPOSITORY_SNAPSHOT_PY__
chmod +x "$W/provision/alarm-repository-snapshot.py"
cat > "$W/provision/stage1.sh" <<'__PAYLOAD_PROVISION_STAGE1_SH__'
#!/bin/sh
# Stage 1 — runs on the Alpine live environment (busybox ash).
# Partitions the disk, deploys the Arch Linux ARM rootfs, and enters chroot.
set -eu
PROV=/media/prov
. "$PROV/config.env"
: "${OMARCHY_LANG:=en}"
ui_text() { if [ "$OMARCHY_LANG" = es ]; then printf '%s' "${2:-$1}"; else printf '%s' "$1"; fi; }
log()  { text=$(ui_text "$1" "${2:-$1}"); echo ""; echo "==> [stage1] $text"; }
warn() { text=$(ui_text "$1" "${2:-$1}"); echo "!!  [stage1] $text"; }

# Reliable exit marker: a pipe to tee masks the return code,
# so the script itself emits the token.
trap 'rc=$?; [ "$rc" -ne 0 ] && echo "TOK_BUILD_$rc"' EXIT

log "network" "red"
ip link set eth0 up 2>/dev/null || true
udhcpc -i eth0 -q -n -t 15 >/dev/null 2>&1 || true
ip -4 addr show eth0 | grep -o 'inet [0-9.]*' || echo "  $(ui_text '(no IPv4)' '(sin IPv4)')"

log "Alpine repositories and tools" "repositorios y herramientas de Alpine"
V=$(cut -d. -f1,2 < /etc/alpine-release)
cat > /etc/apk/repositories <<EOF
https://dl-cdn.alpinelinux.org/alpine/v$V/main
https://dl-cdn.alpinelinux.org/alpine/v$V/community
EOF
apk update >/dev/null
apk add --no-cache parted dosfstools btrfs-progs libarchive-tools e2fsprogs >/dev/null
echo "  ok: $(parted --version | head -1)"

log "loading filesystem modules from the live kernel" "cargando modulos de sistema de ficheros del kernel del live"
for m in btrfs vfat fat nls_cp437 nls_iso8859-1 nls_utf8 crc32c-generic xxhash_generic; do
  modprobe "$m" 2>/dev/null || true
done
if grep -qw btrfs /proc/filesystems; then
  ROOTFS=btrfs
else
  warn "btrfs is unavailable in the live kernel -> using ext4 for root" "btrfs no disponible en el kernel del live -> se usara ext4 para la raiz"
  ROOTFS=ext4
fi
grep -qw vfat /proc/filesystems || warn "vfat is not listed in /proc/filesystems" "vfat no listado en /proc/filesystems"
echo "  $(ui_text 'root' 'raiz'): $ROOTFS   filesystems: $(tr '\n' ' ' < /proc/filesystems | tr -s ' ')"

log "partitioning $DISK (GPT: 1 GiB ESP + $ROOTFS root)" "particionando $DISK (GPT: ESP 1GiB + raiz $ROOTFS)"
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
  log "btrfs subvolumes @ and @home" "subvolumenes btrfs @ y @home"
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

log "deploying the Arch Linux ARM rootfs (bsdtar -xpf preserves xattr/ACL)" "desplegando rootfs de Arch Linux ARM (bsdtar -xpf, preserva xattr/ACL)"
# The ESP is mounted AFTER: vfat does not support the symlinks included in /boot in the
# tarball. The kernel is repopulated by pacman in stage2 on the already-mounted ESP.
bsdtar -xpf "$PROV/alarm-rootfs.tgz" -C /mnt
echo "  $(ui_text 'contents' 'contenido'): $(ls /mnt | tr '\n' ' ')"
[ -d /mnt/etc ] && [ -d /mnt/usr ] || { warn "incomplete rootfs" "rootfs incompleto"; exit 1; }

log "mounting the ESP at /boot" "montando la ESP en /boot"
rm -rf /mnt/boot
mkdir -p /mnt/boot
mount -t vfat "${DISK}1" /mnt/boot
df -h /mnt /mnt/boot

log "chroot mounts" "montajes del chroot"
for d in proc sys dev run tmp; do mkdir -p "/mnt/$d"; done
mount -t proc  none /mnt/proc
mount -t sysfs none /mnt/sys
mount --rbind /dev /mnt/dev
mount --make-rslave /mnt/dev
mount -t tmpfs none /mnt/run
mount -t tmpfs -o size=4G none /mnt/tmp
mkdir -p /mnt/dev/pts && mount -t devpts none /mnt/dev/pts 2>/dev/null || true

log "DNS inside the chroot" "DNS dentro del chroot"
rm -f /mnt/etc/resolv.conf
grep -Eq '^[[:space:]]*nameserver[[:space:]]+' /etc/resolv.conf \
  || { warn "DHCP did not provide a DNS resolver" "el DHCP no proporciono un resolver DNS"; exit 1; }
cp /etc/resolv.conf /mnt/etc/resolv.conf

log "copying payload" "copiando payload"
mkdir -p /mnt/root/prov
cp "$PROV/stage2.sh" "$PROV/stage3.sh" "$PROV/config.env" "$PROV/core-git-sources.tsv" "$PROV/free-app-artifacts.tsv" "$PROV/optional-app-artifacts.tsv" \
   "$PROV/alarm-repository-snapshot.py" "$PROV/packages-core.txt" "$PROV/packages-extra.txt" /mnt/root/prov/
cp -R "$PROV/alarm-repositories" /mnt/root/prov/
[ -f "$PROV/extras.sh" ] && cp "$PROV/extras.sh" /mnt/root/prov/omarchy-arm-extras
[ -f "$PROV/menu-compat.sh" ] && cp "$PROV/menu-compat.sh" /mnt/root/prov/omarchy-arm-menu-compat
[ -f "$PROV/arm-menu.jsonc" ] && cp "$PROV/arm-menu.jsonc" /mnt/root/prov/omarchy-arm-menu.jsonc
[ -f "$PROV/armsync.sh" ] && cp "$PROV/armsync.sh" /mnt/root/prov/10-arm-sync
[ -f "$PROV/clipbrd.sh" ] && cp "$PROV/clipbrd.sh" /mnt/root/prov/omarchy-arm-clipboard
[ -f "$PROV/vdagent.py" ] && cp "$PROV/vdagent.py" /mnt/root/prov/omarchy-arm-vdagent
[ -f "$PROV/share.sh" ] && cp "$PROV/share.sh" /mnt/root/prov/omarchy-arm-share
cat > /mnt/root/prov/fsinfo.env <<EOF
ROOTFS=$ROOTFS
ROOT_MOUNT_OPTS=$MOPT_ROOT
EOF
chmod +x /mnt/root/prov/stage2.sh /mnt/root/prov/stage3.sh /mnt/root/prov/alarm-repository-snapshot.py

log "entering chroot -> stage2" "entrando en chroot -> stage2"
set +e
chroot /mnt /bin/bash /root/prov/stage2.sh
rc=$?
set -e

log "unmounting" "desmontando"
sync
umount -R /mnt/tmp /mnt/run /mnt/dev /mnt/sys /mnt/proc 2>/dev/null || true
umount -R /mnt/boot 2>/dev/null || true
umount -R /mnt 2>/dev/null || umount -l /mnt
sync
echo "==> [stage1] $(ui_text 'finished' 'terminado') rc=$rc"
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

ui_text() { if [[ ${OMARCHY_LANG:-en} == es ]]; then printf '%s' "${2:-$1}"; else printf '%s' "$1"; fi; }
log()  { local text; text=$(ui_text "$1" "${2:-$1}"); echo ""; echo "==> [stage2] $text"; }
warn() { local text; text=$(ui_text "$1" "${2:-$1}"); echo "!!  [stage2] $text"; }

trap 'warn "failed at line $LINENO" "fallo en la linea $LINENO"; exit 1' ERR

# ---------------------------------------------------------------- pacman
SNAPSHOT_DIR=/root/prov/alarm-repositories
SNAPSHOT_MANIFEST="$SNAPSHOT_DIR/manifest.tsv"
SNAPSHOT_REPOSITORIES=(core extra alarm aur)

validate_repository_snapshot() {
  local repository line tag name digest size extra actual_size count
  local primary_url secondary_url snapshot_records="" computed_snapshot_id
  [[ -s $SNAPSHOT_MANIFEST ]] || { warn "the repository snapshot manifest is missing" "falta el manifiesto de la captura de repositorios"; return 1; }
  [[ $(find "$SNAPSHOT_DIR" -maxdepth 1 -type f -name '*.db' | wc -l) -eq 4 ]] \
    || { warn "the repository snapshot must contain exactly four databases" "la captura de repositorios debe contener exactamente cuatro bases"; return 1; }
  [[ $(awk -F '\t' '$1 == "format" && $2 == "alarm-repository-snapshot-v1" && NF == 2 { count++ } END { print count + 0 }' "$SNAPSHOT_MANIFEST") -eq 1 ]]
  [[ $(awk -F '\t' '$1 == "architecture" && $2 == "aarch64" && NF == 2 { count++ } END { print count + 0 }' "$SNAPSHOT_MANIFEST") -eq 1 ]]
  [[ $(awk -F '\t' '$1 == "primary-url" && $2 ~ /^https:\/\// && NF == 2 { count++ } END { print count + 0 }' "$SNAPSHOT_MANIFEST") -eq 1 ]]
  [[ $(awk -F '\t' '$1 == "secondary-url" && $2 ~ /^https:\/\// && NF == 2 { count++ } END { print count + 0 }' "$SNAPSHOT_MANIFEST") -eq 1 ]]
  primary_url=$(awk -F '\t' '$1 == "primary-url" { print $2 }' "$SNAPSHOT_MANIFEST")
  secondary_url=$(awk -F '\t' '$1 == "secondary-url" { print $2 }' "$SNAPSHOT_MANIFEST")
  [[ $primary_url != "$secondary_url" ]]
  [[ $(awk -F '\t' '$1 == "sync-marker" && $2 ~ /^[0-9]+$/ && NF == 2 { count++ } END { print count + 0 }' "$SNAPSHOT_MANIFEST") -eq 1 ]]
  [[ $(awk -F '\t' '$1 == "captured-at" && NF == 2 { count++ } END { print count + 0 }' "$SNAPSHOT_MANIFEST") -eq 1 ]]
  [[ $(awk 'NF && $1 !~ /^#/ { count++ } END { print count + 0 }' "$SNAPSHOT_MANIFEST") -eq 11 ]]
  SNAPSHOT_ID=$(awk -F '\t' '$1 == "snapshot-id" && NF == 2 { print $2 }' "$SNAPSHOT_MANIFEST")
  [[ $SNAPSHOT_ID =~ ^[0-9a-f]{64}$ ]] || { warn "the repository snapshot ID is invalid" "el identificador de la captura de repositorios no es valido"; return 1; }
  [[ $(awk -F '\t' '$1 == "repo" { count++ } END { print count + 0 }' "$SNAPSHOT_MANIFEST") -eq 4 ]]

  for repository in "${SNAPSHOT_REPOSITORIES[@]}"; do
    count=$(awk -F '\t' -v repository="$repository" '$1 == "repo" && $2 == repository { count++ } END { print count + 0 }' "$SNAPSHOT_MANIFEST")
    [[ $count -eq 1 ]] || { warn "missing or duplicate snapshot record for $repository" "falta o esta duplicado el registro de la captura para $repository"; return 1; }
    line=$(awk -F '\t' -v repository="$repository" '$1 == "repo" && $2 == repository { print; exit }' "$SNAPSHOT_MANIFEST")
    snapshot_records+="$line"$'\n'
    IFS=$'\t' read -r tag name digest size extra <<< "$line"
    [[ $tag == repo && $name == "$repository" && -z ${extra:-} && $digest =~ ^[0-9a-f]{64}$ && $size =~ ^[0-9]+$ ]]
    actual_size=$(stat -c '%s' "$SNAPSHOT_DIR/$repository.db")
    [[ $actual_size == "$size" ]] || { warn "$repository.db size does not match its manifest" "el tamano de $repository.db no coincide con su manifiesto"; return 1; }
    printf '%s  %s\n' "$digest" "$SNAPSHOT_DIR/$repository.db" | sha256sum -c - >/dev/null \
      || { warn "$repository.db SHA-256 does not match its manifest" "el sha256 de $repository.db no coincide con su manifiesto"; return 1; }
    tar -tzf "$SNAPSHOT_DIR/$repository.db" >/dev/null \
      || { warn "$repository.db is not a usable pacman database" "$repository.db no es una base utilizable de pacman"; return 1; }
  done
  computed_snapshot_id=$(printf '%s' "$snapshot_records" | sha256sum | awk '{ print $1 }')
  [[ $computed_snapshot_id == "$SNAPSHOT_ID" ]] \
    || { warn "the repository snapshot ID does not match its records" "el identificador de la captura no coincide con sus registros"; return 1; }
}

log "verifying the build-scoped repository snapshot" "verificando la captura de repositorios de esta construccion"
validate_repository_snapshot
install -d -m 0755 /var/lib/pacman/sync /usr/share/omarchy-arm/alarm-repositories
for repository in "${SNAPSHOT_REPOSITORIES[@]}"; do
  install -m 0644 "$SNAPSHOT_DIR/$repository.db" "/var/lib/pacman/sync/$repository.db"
  install -m 0644 "$SNAPSHOT_DIR/$repository.db" "/usr/share/omarchy-arm/alarm-repositories/$repository.db"
done
install -m 0644 "$SNAPSHOT_MANIFEST" /usr/share/omarchy-arm/alarm-repositories/manifest.tsv
install -m 0755 /root/prov/alarm-repository-snapshot.py /usr/share/omarchy-arm/alarm-repository-snapshot.py
echo "  $(ui_text 'snapshot' 'captura'): ${SNAPSHOT_ID:0:12}"

log "initializing the Arch Linux and Arch Linux ARM keyrings" "inicializando los llaveros de Arch Linux y Arch Linux ARM"
pacman-key --init
pacman-key --populate archlinux archlinuxarm

# The mirrors included in the tarball use HTTP. Although pacman verifies the signature of
# each package, TLS also protects the index, version selection, and
# availability. Two official mirrors with valid certificates are set.
: "${ALARM_MIRROR_PRIMARY:=https://ca.us.mirror.archlinuxarm.org}"
: "${ALARM_MIRROR_SECONDARY:=https://fl.us.mirror.archlinuxarm.org}"
case "$ALARM_MIRROR_PRIMARY" in https://*) ;; *) warn "the primary mirror must use HTTPS" "el mirror primario debe usar HTTPS"; exit 1 ;; esac
case "$ALARM_MIRROR_SECONDARY" in https://*) ;; *) warn "the secondary mirror must use HTTPS" "el mirror secundario debe usar HTTPS"; exit 1 ;; esac
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

# Retry package downloads without refreshing the build-scoped databases.
pac() {
  local intento
  for intento in 1 2 3; do
    if pacman -S --noconfirm --needed --disable-download-timeout "$@"; then return 0; fi
    warn "pacman failed (attempt $intento/3); retrying in ${intento}0 seconds" "pacman fallo (intento $intento/3); reintentando en ${intento}0 s"
    sleep "${intento}0"
  done
  return 1
}

log "updating the system from the captured repository snapshot" "actualizando el sistema desde la captura de repositorios"
pacman -Su --noconfirm --needed --disable-download-timeout \
  || pacman -Su --noconfirm --needed --disable-download-timeout

log "base system" "sistema base"
# linux-firmware is intentionally omitted: ~800 MB useless in a VM
pac base base-devel linux-aarch64 \
  sudo git vim networkmanager openssh which man-db man-pages less \
  btrfs-progs dosfstools e2fsprogs efibootmgr \
  rsync wget curl unzip zip

# ---------------------------------------------------------------- localization
log "timezone, locales, keyboard, and hostname" "zona horaria, locales, teclado, hostname"
ln -sf "/usr/share/zoneinfo/$VM_TIMEZONE" /etc/localtime
sed -i "s/^#\(${VM_LOCALE} \)/\1/; s/^#\(${VM_LOCALE_EXTRA} \)/\1/" /etc/locale.gen
grep -q "^${VM_LOCALE} " /etc/locale.gen || echo "${VM_LOCALE} UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=$VM_LOCALE" > /etc/locale.conf
# Hyprland reads XKBLAYOUT from here (default/hypr/input.lua); KEYMAP only
# covers the text console.
printf 'KEYMAP=%s\nXKBLAYOUT=%s\n' "$VM_KEYMAP" "$VM_XKB" > /etc/vconsole.conf
printf "OMARCHY_LANG='%s'\n" "${OMARCHY_LANG:-en}" > /etc/omarchy-arm.conf
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
log "user $VM_USER" "usuario $VM_USER"
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
log "mkinitcpio (virtio + btrfs modules)" "mkinitcpio (modulos virtio + btrfs)"
sed -i 's/^MODULES=.*/MODULES=(virtio virtio_pci virtio_blk virtio_scsi virtio_net virtio_gpu 9p 9pnet 9pnet_virtio btrfs ext4)/' /etc/mkinitcpio.conf
grep -q '^MODULES=' /etc/mkinitcpio.conf || echo 'MODULES=(virtio virtio_pci virtio_blk virtio_gpu 9p 9pnet_virtio btrfs)' >> /etc/mkinitcpio.conf
mkinitcpio -P
echo "  /boot:"; ls -la /boot

# ---------------------------------------------------------------- UEFI boot
log "systemd-boot on the ESP" "systemd-boot en la ESP"
# --no-variables: we do not write to NVRAM; UTM boots via the fallback path
# \EFI\BOOT\BOOTAA64.EFI, which bootctl installs as well.
bootctl --esp-path=/boot --no-variables install

# The ESP is mounted empty AFTER extracting the rootfs, so /boot has no kernel.
# "pacman -S --needed" does not reinstall it if the installed version already matches
# the one in the repository, so the package reinstall is forced.
if [ ! -f /boot/Image ] && [ ! -f /boot/vmlinuz-linux-aarch64 ]; then
  echo "  $(ui_text '/boot is empty: reinstalling linux-aarch64 to populate it' '/boot vacio: reinstalando linux-aarch64 para repoblarlo')"
  pacman -S --noconfirm --disable-download-timeout linux-aarch64 || warn "could not reinstall the kernel" "no se pudo reinstalar el kernel"
  mkinitcpio -P || warn "mkinitcpio failed after reinstalling" "mkinitcpio fallo tras reinstalar"
fi

KERNEL_IMG=""
for c in /boot/Image /boot/vmlinuz-linux-aarch64 /boot/Image.gz; do
  [ -f "$c" ] && { KERNEL_IMG="/$(basename "$c")"; break; }
done
[ -n "$KERNEL_IMG" ] || { warn "kernel image not found in /boot" "no encuentro la imagen del kernel en /boot"; ls -la /boot; exit 1; }

INITRD=""
for c in /boot/initramfs-linux-aarch64.img /boot/initramfs-linux.img; do
  [ -f "$c" ] && { INITRD="/$(basename "$c")"; break; }
done
[ -n "$INITRD" ] || { warn "initramfs not found" "no encuentro el initramfs"; ls -la /boot; exit 1; }

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
title    Arch Linux ARM — Omarchy ($(ui_text 'verbose' 'verboso'))
linux    $KERNEL_IMG
initrd   $INITRD
options  root=LABEL=OMROOT $KERNEL_ROOTFLAGS rw
EOF
echo "  kernel=$KERNEL_IMG initrd=$INITRD"
echo "  ESP:"; find /boot/EFI /boot/loader -maxdepth 3 | sort

# ---------------------------------------------------------------- networking
log "network: NetworkManager (disabling systemd-networkd from the tarball)" "red: NetworkManager (se desactiva systemd-networkd del tarball)"
systemctl disable systemd-networkd.service systemd-networkd.socket 2>/dev/null || true
systemctl disable systemd-resolved.service 2>/dev/null || true
rm -f /etc/systemd/network/*.network 2>/dev/null || true
systemctl enable NetworkManager.service
systemctl enable systemd-timesyncd.service 2>/dev/null || true

# ---------------------------------------------------------------- desktop
log "installing the desktop stack (Hyprland + Omarchy tools)" "instalando el stack de escritorio (Hyprland + herramientas de Omarchy)"
install_list() {
  local file="$1" label="$2" fatal="$3"
  mapfile -t PKGS < <(grep -vE '^\s*#|^\s*$' "$file")
  echo "  $label: ${#PKGS[@]} $(ui_text 'packages' 'paquetes')"
  if pac "${PKGS[@]}"; then return 0; fi
  warn "$label: bulk installation failed after 3 attempts; trying packages individually" "$label: instalacion en bloque fallida tras 3 intentos; probando uno a uno"
  local FAILED=()
  for p in "${PKGS[@]}"; do
    pacman -S --noconfirm --needed --disable-download-timeout "$p" >/dev/null 2>&1 && continue
    # Retry failed packages: the mirror, not the package, is usually at fault.
    sleep 3
    pacman -S --noconfirm --needed --disable-download-timeout "$p" >/dev/null 2>&1 || FAILED+=("$p")
  done
  if [ ${#FAILED[@]} -gt 0 ]; then
    warn "$label not installed: ${FAILED[*]}" "$label no instalados: ${FAILED[*]}"
    printf '%s\n' "${FAILED[@]}" >> /root/failed-packages.txt
    [ "$fatal" = fatal ] && return 1
  fi
  return 0
}
install_list /root/prov/packages-core.txt  "$(ui_text 'core' 'nucleo')" fatal
set +e
install_list /root/prov/packages-extra.txt "extras" soft
set -e

log "system services" "servicios de sistema"
systemctl enable sddm.service 2>/dev/null || warn "sddm is unavailable" "sddm no disponible"
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
# (vdagentd.c:746, systemd-login.c:272) fails with Hyprland launched by SDDM,
# and then the daemon silently discards the clipboard.
#
# Use the environment file already read by Arch's unit instead of replacing
# ExecStart, so future package changes remain effective.
#
# Do not add -f: it means --fake-uinput, not foreground. It skips the ioctls
# that configure /dev/uinput, prevents the absolute pointer from being created,
# and produces "write /dev/uinput: Invalid argument" on every boot.
rm -rf /etc/systemd/system/spice-vdagentd.service.d
printf 'SPICE_VDAGENTD_EXTRA_ARGS=-X\n' > /etc/conf.d/spice-vdagentd
systemctl enable spice-vdagentd.service 2>/dev/null || true
systemctl enable spice-vdagentd.socket 2>/dev/null || true
echo "  $(ui_text 'spice-vdagentd with -X (required under Hyprland)' 'spice-vdagentd con -X (necesario bajo Hyprland)')"

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
echo "  $(ui_text 'spice-webdavd enabled (UTM SPICE WebDAV mode)' 'spice-webdavd habilitado (modo SPICE WebDAV de UTM)')"

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
echo "  $(ui_text '/mnt/share prepared (VirtFS through fstab, WebDAV through omarchy-arm-share)' '/mnt/share preparado (VirtFS por fstab, WebDAV con omarchy-arm-share)')"
systemctl enable bluetooth.service 2>/dev/null || true
systemctl enable docker.service 2>/dev/null || true
usermod -aG docker "$VM_USER" 2>/dev/null || true

# ---------------------------------------------------------------- dotfiles
log "stage 3: Omarchy dotfiles as $VM_USER" "etapa 3: dotfiles de Omarchy como $VM_USER"
chmod +x /root/prov/stage3.sh
install -Dm644 /root/prov/core-git-sources.tsv /usr/share/omarchy-arm/core-git-sources.tsv
install -Dm644 /root/prov/free-app-artifacts.tsv /usr/share/omarchy-arm/free-app-artifacts.tsv
install -Dm644 /root/prov/optional-app-artifacts.tsv /usr/share/omarchy-arm/optional-app-artifacts.tsv
install -d -o "$VM_USER" -g "$VM_USER" "/home/$VM_USER"
# stage3 runs as a normal user and /root is 0750: any test you perform on
# /root/prov returns false without error. A readable copy is left in their home.
PROVDIR="/home/$VM_USER/.omarchy-arm-prov"
mkdir -p "$PROVDIR"
for f in omarchy-arm-extras omarchy-arm-menu-compat omarchy-arm-menu.jsonc 10-arm-sync omarchy-arm-clipboard omarchy-arm-vdagent omarchy-arm-share; do
  [ -f "/root/prov/$f" ] && install -m 0644 "/root/prov/$f" "$PROVDIR/$f"
done
cp /root/prov/stage3.sh /root/prov/config.env "/home/$VM_USER/"
chown -R "$VM_USER:$VM_USER" "$PROVDIR"
chown "$VM_USER:$VM_USER" "/home/$VM_USER/stage3.sh" "/home/$VM_USER/config.env"
echo "  $(ui_text 'available to stage3' 'disponible para stage3'): $(ls "$PROVDIR" | tr '\n' ' ')"
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
[ $STAGE3_RC -eq 0 ] || warn "stage3 finished with errors (rc=$STAGE3_RC)" "stage3 termino con errores (rc=$STAGE3_RC)"
echo "TOK_STAGE3_$STAGE3_RC"
rm -f "/home/$VM_USER/stage3.sh" "/home/$VM_USER/config.env"
rm -rf "$PROVDIR"

log "recording installed-package provenance" "registrando la procedencia de los paquetes instalados"
python3 /usr/share/omarchy-arm/alarm-repository-snapshot.py validate \
  /usr/share/omarchy-arm/alarm-repositories \
  /usr/share/omarchy-arm/alarm-repositories/manifest.tsv
python3 /usr/share/omarchy-arm/alarm-repository-snapshot.py provenance \
  /usr/share/omarchy-arm/alarm-repositories \
  /usr/share/omarchy-arm/alarm-repositories/manifest.tsv \
  /usr/share/omarchy-arm/alarm-package-provenance.tsv
python3 /usr/share/omarchy-arm/alarm-repository-snapshot.py validate-provenance \
  /usr/share/omarchy-arm/alarm-repositories \
  /usr/share/omarchy-arm/alarm-repositories/manifest.tsv \
  /usr/share/omarchy-arm/alarm-package-provenance.tsv
echo "  $(ui_text 'repository packages verified from cached bytes' 'paquetes de repositorios verificados desde bytes en cache'): $(awk -F '\t' 'NR > 1 && $2 == "repository-cache+mtree" { count++ } END { print count + 0 }' /usr/share/omarchy-arm/alarm-package-provenance.tsv)"
echo "  $(ui_text 'snapshot metadata matches without cached bytes' 'coincidencias con la captura sin bytes en cache'): $(awk -F '\t' 'NR > 1 && $2 == "snapshot-metadata-only" { count++ } END { print count + 0 }' /usr/share/omarchy-arm/alarm-package-provenance.tsv)"
echo "  $(ui_text 'local, unknown, or ambiguous packages' 'paquetes locales, desconocidos o ambiguos'): $(awk -F '\t' 'NR > 1 && $2 != "repository-cache+mtree" && $2 != "snapshot-metadata-only" { count++ } END { print count + 0 }' /usr/share/omarchy-arm/alarm-package-provenance.tsv)"

# ---------------------------------------------------------------- login SDDM
log "SDDM: Omarchy session with autologin" "SDDM: sesion Omarchy con autologin"
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
echo "  $(ui_text 'session' 'sesion')=$SESSION"
ls /usr/local/share/wayland-sessions /usr/share/wayland-sessions 2>/dev/null

# ---------------------------------------------------------------- VM settings
log "virtual-machine-specific settings" "ajustes propios de maquina virtual"
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

log "cleanup" "limpieza"
rm -f /etc/sudoers.d/99-install
paccache -rk1 2>/dev/null || true
rm -rf /var/cache/pacman/pkg/* 2>/dev/null || true

log "summary" "resumen"
echo "  kernel:    $(pacman -Q linux-aarch64 2>/dev/null || echo '?')"
echo "  hyprland:  $(pacman -Q hyprland 2>/dev/null || echo 'NO INSTALADO')"
echo "  sddm:      $(pacman -Q sddm 2>/dev/null || echo 'NO INSTALADO')"
echo "  mesa:      $(pacman -Q mesa 2>/dev/null || echo '?')"
echo "  $(ui_text 'user' 'usuario'):   $(id "$VM_USER")"
echo "  dotfiles:  $(ls -d /home/$VM_USER/.config/hypr 2>/dev/null || ui_text 'MISSING' 'FALTAN')"
sync
touch /root/STAGE2_OK
echo ""
echo "==> [stage2] $(ui_text 'COMPLETED' 'COMPLETADO')"
__PAYLOAD_PROVISION_STAGE2_SH__
chmod +x "$W/provision/stage2.sh"

mkdir -p "$W/provision"
cat > "$W/provision/stage3.sh" <<'__PAYLOAD_PROVISION_STAGE3_SH__'
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
__PAYLOAD_PROVISION_STAGE3_SH__
chmod +x "$W/provision/stage3.sh"

mkdir -p "$W/provision"
cat > "$W/provision/repair.sh" <<'__PAYLOAD_PROVISION_REPAIR_SH__'
#!/bin/sh
# Re-mount the already installed system on /dev/vda and run a script inside the chroot,
# without re-partitioning or downloading anything. To iterate after a specific failure.
set -eu
PROV=/media/prov
. "$PROV/config.env" 2>/dev/null || true
: "${OMARCHY_LANG:=en}"
ui_text() { if [ "$OMARCHY_LANG" = es ]; then printf '%s' "${2:-$1}"; else printf '%s' "$1"; fi; }
log() { text=$(ui_text "$1" "${2:-$1}"); echo ""; echo "==> [repair] $text"; }
warn() { text=$(ui_text "$1" "${2:-$1}"); echo "!!  [repair] $text" >&2; }
trap 'rc=$?; [ "$rc" -ne 0 ] && echo "TOK_REPAIR_$rc"' EXIT

log "kernel modules" "modulos del kernel"
# Mounting btrfs/vfat only requires the kernel module, not the user-space utilities:
# this stage does NOT depend on having network access.
for m in btrfs vfat fat nls_cp437 nls_iso8859-1 nls_utf8 crc32c-generic xxhash_generic; do
  modprobe "$m" 2>/dev/null || true
done
grep -qw btrfs /proc/filesystems || { warn "the live kernel does not support btrfs" "el kernel del live no soporta btrfs"; exit 1; }
echo "  filesystems: $(tr '\n' ' ' < /proc/filesystems | tr -s ' ')"

log "network (best effort; convenience only)" "red (best-effort, solo por comodidad)"
ip link set eth0 up 2>/dev/null || true
udhcpc -i eth0 -q -n -t 8 >/dev/null 2>&1 || true
ip -4 addr show eth0 2>/dev/null | grep -o 'inet [0-9.]*' || echo "  $(ui_text '(no network; continuing anyway)' '(sin red; se continua igualmente)')"

log "mounting the installed system" "montando el sistema instalado"
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
grep -Eq '^[[:space:]]*nameserver[[:space:]]+' /etc/resolv.conf \
  || { warn "DHCP did not provide a DNS resolver" "el DHCP no proporciono un resolver DNS"; exit 1; }
cp /etc/resolv.conf /mnt/etc/resolv.conf
df -h /mnt /mnt/boot

log "running $FIXSCRIPT inside the chroot" "ejecutando $FIXSCRIPT dentro del chroot"
mkdir -p /mnt/root/prov
cp "$PROV/$FIXSCRIPT" /mnt/root/prov/
[ -f "$PROV/config.env" ] && cp "$PROV/config.env" /mnt/root/prov/
[ -f "$PROV/core-git-sources.tsv" ] && cp "$PROV/core-git-sources.tsv" /mnt/root/prov/
[ -f "$PROV/free-app-artifacts.tsv" ] && cp "$PROV/free-app-artifacts.tsv" /mnt/root/prov/
[ -f "$PROV/optional-app-artifacts.tsv" ] && cp "$PROV/optional-app-artifacts.tsv" /mnt/root/prov/
[ -f "$PROV/extras.sh" ] && cp "$PROV/extras.sh" /mnt/root/prov/omarchy-arm-extras
[ -f "$PROV/menu-compat.sh" ] && cp "$PROV/menu-compat.sh" /mnt/root/prov/omarchy-arm-menu-compat
[ -f "$PROV/arm-menu.jsonc" ] && cp "$PROV/arm-menu.jsonc" /mnt/root/prov/omarchy-arm-menu.jsonc
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
log "removing /root/prov from the installed system" "retirando /root/prov del sistema instalado"
ls /mnt/root/prov 2>/dev/null | tr '\n' ' '; echo
rm -rf /mnt/root/prov

log "unmounting" "desmontando"
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
  for lock in core-git-sources.tsv free-app-artifacts.tsv optional-app-artifacts.tsv; do
    [ -f "/root/prov/$lock" ] \
      || { warn "the reviewed source lock $lock was missing" "faltaba el bloqueo revisado de fuentes $lock"; exit 1; }
    install -Dm644 "/root/prov/$lock" "/usr/share/omarchy-arm/$lock"
  done
  install -Dm755 "$EXTRAS_SRC" /usr/local/bin/omarchy-arm-extras
  if [ -f /root/prov/omarchy-arm-menu-compat ]; then
    install -Dm755 /root/prov/omarchy-arm-menu-compat /usr/local/lib/omarchy-arm/menu-compat
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
      ln -sfn /usr/local/lib/omarchy-arm/menu-compat "/usr/local/bin/$command"
    done
  else
    warn "ARM menu compatibility dispatcher is missing" "falta el dispatcher de compatibilidad del menu ARM"
  fi
  if [ -f /root/prov/omarchy-arm-menu.jsonc ]; then
    install -Dm644 /root/prov/omarchy-arm-menu.jsonc /usr/share/omarchy-arm/omarchy-menu.jsonc
    ARM_MENU_TARGET="/home/$NEW/.config/omarchy/extensions/omarchy-menu.jsonc"
    if [ ! -e "$ARM_MENU_TARGET" ] \
        || grep -q 'OMARCHY_ARM_MANAGED_MENU_V1' "$ARM_MENU_TARGET" 2>/dev/null \
        || ! grep -Eq '^[[:space:]]*"[^"]+"[[:space:]]*:' "$ARM_MENU_TARGET" 2>/dev/null; then
      install -Dm644 /root/prov/omarchy-arm-menu.jsonc "$ARM_MENU_TARGET"
      chown "$NEW:$NEW" "$ARM_MENU_TARGET"
    else
      warn "Existing custom Omarchy menu extension preserved; unsupported ARM actions remain blocked when invoked" "Se conservo la extension personalizada del menu de Omarchy; las acciones ARM no compatibles siguen bloqueadas al invocarlas"
    fi
  else
    warn "ARM menu overlay is missing" "falta el overlay del menu ARM"
  fi
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

log "removing orphaned packages" "quitando paquetes huerfanos"
# Build dependencies left by makepkg -s and firmware for hardware absent from
# a VM would make the user's first update ask what to do with them. -Qtdq lists
# only dependency-installed packages no longer required by anything. Repeat
# because removing one layer can expose another orphan.
for _vuelta in 1 2 3 4; do
  mapfile -t HUERFANOS < <(pacman -Qtdq 2>/dev/null || true)
  [ "${#HUERFANOS[@]}" -gt 0 ] && [ -n "${HUERFANOS[0]:-}" ] || break
  echo "  $(ui_text 'pass' 'vuelta') $_vuelta: ${HUERFANOS[*]}"
  pacman -Rns --noconfirm "${HUERFANOS[@]}" >/dev/null 2>&1 \
    || { warn "could not remove: ${HUERFANOS[*]}" "no pude quitar: ${HUERFANOS[*]}"; break; }
done
echo "  $(ui_text 'remaining orphans' 'huerfanos restantes'): $(pacman -Qtdq 2>/dev/null | wc -l)"

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

if [ -x /usr/local/bin/omarchy-arm-verify-tools ]; then
  TOOL_RESULT=$(/usr/local/bin/omarchy-arm-verify-tools "${HACER_TOOLS:-si}" 2>&1)
  [ $? -eq 0 ] && bien "$TOOL_RESULT" || mal "$TOOL_RESULT"
else
  mal "the ARM tool verifier is missing" "falta el verificador de herramientas ARM"
fi

BROWSER_POLICY_DIR=/etc/chromium/policies/managed
[ -d "$BROWSER_POLICY_DIR" ] && [ ! -L "$BROWSER_POLICY_DIR" ] \
  && [ "$(stat -c '%U:%G:%a' "$BROWSER_POLICY_DIR" 2>/dev/null)" = root:root:755 ] \
  && bien "Chromium policy directory is root-owned and mode 755" "el directorio de politicas de Chromium pertenece a root y tiene modo 755" \
  || mal "Chromium policy directory is not safely owned" "el directorio de politicas de Chromium no tiene propiedad segura"

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
# This runs in a chroot, so validate the environment file that will pass -X to
# the daemon. The booted-image checker validates the live process instead.
grep -qs -- '-X' /etc/conf.d/spice-vdagentd \
  && bien "spice-vdagentd will receive -X" "spice-vdagentd recibira -X" \
  || mal "spice-vdagentd lacks -X: clipboard will not work" "spice-vdagentd sin -X: el portapapeles no funcionara"
[ -e /etc/systemd/system/spice-vdagentd.service.d ] \
  && mal "an obsolete spice-vdagentd override remains" "queda un override antiguo de spice-vdagentd" \
  || bien "no obsolete spice-vdagentd override" "sin override antiguo"
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

N_HUERF=$(pacman -Qtdq 2>/dev/null | wc -l)
[ "$N_HUERF" -eq 0 ] && bien "sin paquetes huerfanos" \
                     || mal "$N_HUERF paquetes huerfanos: la primera actualizacion preguntara por ellos"

echo ""
if [ "$FALLOS" -ne 0 ]; then
  echo "==> SANITIZE_FALLO: $(ui_text "$FALLOS broken invariant(s); this image MUST NOT be distributed" "$FALLOS invariante(s) rotos; esta imagen NO se puede distribuir")"
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
__PAYLOAD_PROVISION_EXTRAS_SH__
chmod +x "$W/provision/extras.sh"

cat > "$W/provision/menu-compat.sh" <<'__PAYLOAD_PROVISION_MENU_COMPAT_SH__'
#!/bin/bash
# ARM compatibility dispatcher for Omarchy menu and CLI actions.
set -uo pipefail

REAL=${OMARCHY_ARM_REAL_BIN:-/usr/share/omarchy/bin}
SELF=$(basename "$0")

ui_text() {
  if [[ ${OMARCHY_LANG:-en} == es ]]; then printf '%s' "${2:-$1}"; else printf '%s' "$1"; fi
}

unsupported() {
  local name="$1"
  printf '\n\033[31m%s\033[0m\n' "$(ui_text "$name is not supported by this ARM image." "$name no es compatible con esta imagen ARM.")" >&2
  printf '%s\n' "$(ui_text 'The menu hides this entry because its current Linux distribution is x86-only or has not passed the ARM review and launch tests.' 'El menu oculta esta entrada porque su distribucion Linux actual solo sirve para x86 o aun no ha pasado la revision y las pruebas de arranque en ARM.')" >&2
  return 1
}

run_real() {
  local command="$1"
  shift
  exec "$REAL/$command" "$@"
}

case "$SELF" in
  omarchy-arm-menu-compat)
    echo "This program is invoked through the Omarchy ARM compatibility links in /usr/local/bin."
    ;;

  omarchy-arm-show-failed)
    status=${1:-1}
    : 2>/dev/null <>/dev/tty || exit "$status"
    while read -rsn 1 -t 0.1 _ </dev/tty; do :; done
    printf '\n\033[31m● \033[0mInstallation failed (status %s). Press any key to close...' "$status" >/dev/tty
    read -rsn 1 </dev/tty
    echo >/dev/tty
    exit "$status"
    ;;

  omarchy-launch-floating-terminal-with-presentation)
    # Keep upstream's presentation, but show Done only for actual success. Menu
    # installers also opt into strict ARM package resolution so a missing app
    # cannot be skipped while its dependencies are partially installed.
    # shellcheck disable=SC1091
    source omarchy-restart-gum
    cmd="$*"
    strict=""
    case "$cmd" in
      omarchy-install-*|omarchy-voxtype-install*|omarchy-games-retro-install*|omarchy-default-*\ --install*)
        strict='export OMARCHY_ARM_STRICT_PACKAGES=1; ' ;;
    esac
    presentation_script="omarchy-show-logo; ${strict}${cmd}; status=\$?; if (( status == 0 )); then omarchy-show-done; elif (( status != 130 )); then omarchy-arm-show-failed \"\$status\"; fi; exit \$status"
    exec setsid uwsm-app -- xdg-terminal-exec --app-id=org.omarchy.terminal --title=Omarchy -e bash -c "$presentation_script"
    ;;

  omarchy-channel-set)
    printf '%s\n' "$(ui_text 'Omarchy package channels are x86_64-only and cannot be selected on this ARM image.' 'Los canales de paquetes de Omarchy solo sirven para x86_64 y no se pueden seleccionar en esta imagen ARM.')" >&2
    printf '%s\n' "$(ui_text 'Use Update > Omarchy; the ARM post-update hook tracks the reviewed upstream Git branch without replacing the Arch Linux ARM repositories.' 'Usa Actualizar > Omarchy; el hook ARM sigue la rama Git revisada sin sustituir los repositorios de Arch Linux ARM.')" >&2
    exit 1
    ;;

  omarchy-install-browser)
    case "${1:-}" in
      chrome) exec omarchy-arm-extras chrome ;;
      chromium|firefox) run_real "$SELF" "$@" ;;
      edge) unsupported "Microsoft Edge" ;;
      brave) unsupported "Brave" ;;
      brave-origin) unsupported "Brave Origin" ;;
      zen) unsupported "Zen Browser" ;;
      *) echo "Usage: omarchy-install-browser <chromium|chrome|firefox>" >&2; exit 1 ;;
    esac
    ;;

  omarchy-install-service-1password)
    if ! omarchy-arm-extras 1password 1password-cli; then exit 1; fi
    extension_id=aeblfdkhhhdcdjpifhhbdiojplfjncoa
    extension_dir=/usr/share/chromium/extensions
    if command -v chromium >/dev/null 2>&1; then
      sudo mkdir -p "$extension_dir" || exit 1
      printf '{ "external_update_url": "%s" }\n' 'https://clients2.google.com/service/update2/crx' \
        | sudo tee "$extension_dir/$extension_id.json" >/dev/null || exit 1
      sudo chmod 644 "$extension_dir/$extension_id.json" || exit 1
    fi
    command -v uwsm-app >/dev/null 2>&1 && command -v 1password >/dev/null 2>&1 \
      && uwsm-app -- 1password >/dev/null 2>&1 &
    ;;

  omarchy-install-service-spotify)
    exec omarchy-arm-extras spotify-web
    ;;

  omarchy-install-editor-zed)
    omarchy-arm-extras zed || exit 1
    command -v uwsm-app >/dev/null 2>&1 \
      && setsid uwsm-app -- gtk-launch dev.zed.Zed >/dev/null 2>&1 &
    ;;

  omarchy-install-terminal)
    [[ ${1:-} == ghostty ]] && { unsupported "Ghostty"; exit 1; }
    run_real "$SELF" "$@"
    ;;

  omarchy-install-and-launch)
    packages=${2:-}
    case "$packages" in
      'bitwarden bitwarden-cli') unsupported "Bitwarden" ;;
      cursor-bin) unsupported "Cursor" ;;
      sublime-text-4) unsupported "Sublime Text" ;;
      grok-bot) unsupported "Grok Bot" ;;
      t3code-bin) unsupported "T3 Code" ;;
      minecraft-launcher) unsupported "Minecraft" ;;
      *) run_real "$SELF" "$@" ;;
    esac
    ;;

  omarchy-install-app)
    packages=${2:-}
    case "$packages" in
      lmstudio-bin) unsupported "LM Studio" ;;
      ollama|ollama-cuda|ollama-rocm) unsupported "Ollama" ;;
      *) run_real "$SELF" "$@" ;;
    esac
    ;;

  omarchy-install-service-dropbox) unsupported "Dropbox" ;;
  omarchy-install-service-nordvpn) unsupported "NordVPN" ;;
  omarchy-install-service-once) unsupported "ONCE" ;;
  omarchy-install-editor-vscode) unsupported "Visual Studio Code" ;;
  omarchy-install-editor-emacs) unsupported "Omarchy Emacs" ;;
  omarchy-install-ai-chatgpt) unsupported "ChatGPT Desktop" ;;
  omarchy-voxtype-install) unsupported "Voxtype" ;;
  omarchy-install-preinstalls) unsupported "Restore Preinstalls" ;;
  omarchy-install-gaming-steam) unsupported "Steam" ;;
  omarchy-install-gaming-retroarch) unsupported "RetroArch full-core setup" ;;
  omarchy-install-gaming-geforce-now) unsupported "GeForce NOW" ;;
  omarchy-install-gaming-xbox-controllers) unsupported "Xbox controller DKMS driver" ;;
  omarchy-install-gaming-battlenet) unsupported "Battle.net" ;;
  omarchy-install-gaming-lutris) unsupported "Lutris Windows-game stack" ;;
  omarchy-install-gaming-heroic) unsupported "Heroic Games Launcher" ;;
  omarchy-games-retro-install) unsupported "RetroArch Game Launcher" ;;

  *)
    echo "Unknown Omarchy ARM compatibility entry point: $SELF" >&2
    exit 127
    ;;
esac
__PAYLOAD_PROVISION_MENU_COMPAT_SH__
chmod +x "$W/provision/menu-compat.sh"

cat > "$W/provision/arm-menu.jsonc" <<'__PAYLOAD_PROVISION_ARM_MENU_JSONC__'
{
  // OMARCHY_ARM_MANAGED_MENU_V1
  // This overlay keeps the upstream checkout clean while ensuring every visible
  // Install action has an audited ARM path. Hidden entries remain callable only
  // through explicit CLI commands, which return an ARM-specific failure.

  "update.channel": {"when":"false"},
  "update.channel.stable": {"when":"false"},
  "update.channel.rc": {"when":"false"},
  "update.channel.edge": {"when":"false"},
  "update.channel.dev": {"when":"false"},

  "install.windows": {"when":"false"},
  "install.preinstalls": {"when":"false"},

  "install.browser.chrome": {"disabled":"command -v google-chrome-stable >/dev/null"},
  "install.browser.edge": {"when":"false"},
  "install.browser.brave": {"when":"false"},
  "install.browser.brave-origin": {"when":"false"},
  "install.browser.zen": {"when":"false"},

  "setup.default.browser.edge": {"when":"false"},
  "setup.default.browser.brave": {"when":"false"},
  "setup.default.browser.brave-origin": {"when":"false"},
  "setup.default.browser.zen": {"when":"false"},

  "install.service.1password": {"disabled":"command -v 1password >/dev/null"},
  "install.service.spotify": {"label":"Spotify (Web)","disabled":"[[ -f \"$HOME/.local/share/applications/Spotify.desktop\" ]]"},
  "install.service.dropbox": {"when":"false"},
  "install.service.nordvpn": {"when":"false"},
  "install.service.once": {"when":"false"},
  "install.service.bitwarden": {"when":"false"},

  "install.editor.zed": {"disabled":"[[ -x \"$HOME/.local/zed.app/bin/zed\" ]]"},
  "install.editor.vscode": {"when":"false"},
  "install.editor.cursor": {"when":"false"},
  "install.editor.sublime": {"when":"false"},
  "install.editor.emacs": {"when":"false"},

  "setup.default.editor.vscode": {"when":"false"},
  "setup.default.editor.cursor": {"when":"false"},
  "setup.default.editor.sublime": {"when":"false"},
  "setup.default.editor.emacs": {"when":"false"},

  "install.terminal.ghostty": {"when":"false"},
  "setup.default.terminal.ghostty": {"when":"false"},

  "install.ai.chatgpt": {"when":"false"},
  "install.ai.dictation": {"when":"false"},
  "install.ai.grok-bot": {"when":"false"},
  "install.ai.lm-studio": {"when":"false"},
  "install.ai.ollama": {"when":"false"},
  "install.ai.t3-code": {"when":"false"},

  "install.gaming.steam": {"when":"false"},
  "install.gaming.retroarch": {"when":"false"},
  "install.gaming.minecraft": {"when":"false"},
  "install.gaming.geforce-now": {"when":"false"},
  "install.gaming.xbox-controllers": {"when":"false"},
  "install.gaming.battlenet": {"when":"false"},
  "install.gaming.lutris": {"when":"false"},
  "install.gaming.heroic": {"when":"false"},
  "install.gaming.retro-launcher": {"when":"false"},

  "install.development.php.symfony": {"when":"false"}
}
__PAYLOAD_PROVISION_ARM_MENU_JSONC__

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
# Generated guest configuration.
# shellcheck disable=SC1091
[ -r /etc/omarchy-arm.conf ] && . /etc/omarchy-arm.conf
: "${OMARCHY_LANG:=en}"
ui_text() { if [[ $OMARCHY_LANG == es ]]; then printf '%s' "${2:-$1}"; else printf '%s' "$1"; fi; }

git -C "$TREE" rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

# The tree can belong to the user (development VM) or root (distributed image).
if [ -w "$TREE/.git" ]; then GIT=(git -C "$TREE"); else GIT=(sudo git -C "$TREE"); fi

printf '\033[32m\n%s\033[0m\n' "$(ui_text 'Update the Omarchy tree (Git checkout)' 'Actualizar el árbol de Omarchy (checkout git)')"
before=$("${GIT[@]}" rev-parse --short HEAD 2>/dev/null)
if ! "${GIT[@]}" pull --ff-only 2>&1 | sed 's/^/  /'; then
  echo "  $(ui_text 'fast-forward failed; the tree was left unchanged' 'no se pudo hacer fast-forward; el árbol queda como estaba')"
  exit 0
fi
after=$("${GIT[@]}" rev-parse --short HEAD 2>/dev/null)
if [ -r /usr/share/omarchy-arm/omarchy-menu.jsonc ] \
    && ! grep -q 'OMARCHY_ARM_MANAGED_MENU_V1' "$HOME/.config/omarchy/extensions/omarchy-menu.jsonc" 2>/dev/null; then
  printf '\033[31m  %s\033[0m\n' "$(ui_text 'ARM menu safety overlay is missing; restore it before using new Install or Channel entries.' 'Falta el overlay de seguridad del menu ARM; restauralo antes de usar entradas nuevas de Instalar o Canal.')" >&2
fi
if [ "$before" = "$after" ]; then echo "  $(ui_text 'already up to date' 'ya estaba al día') ($after)"; exit 0; fi
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
[ "$n" -gt 0 ] && echo "  $(ui_text "$n new binaries linked in /usr/bin" "$n binarios nuevos enlazados en /usr/bin")"
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
[ -r /etc/omarchy-arm.conf ] && . /etc/omarchy-arm.conf
: "${OMARCHY_LANG:=en}"
ui_text() { if [[ $OMARCHY_LANG == es ]]; then printf '%s' "${2:-$1}"; else printf '%s' "$1"; fi; }

SHARE="${OMARCHY_CLIPBOARD_DIR:-/mnt/share}"
FILE="$SHARE/.clipboard"
INTERVALO="${OMARCHY_CLIPBOARD_INTERVAL:-1}"

uso() {
  if [[ $OMARCHY_LANG == es ]]; then
    cat <<'EOF'
Portapapeles compartido con el Mac mediante la carpeta compartida de UTM.

Uso:
  omarchy-arm-clipboard             vigilar cambios
  omarchy-arm-clipboard --install   instalar e iniciar el servicio
  omarchy-arm-clipboard --host      imprimir el script para el Mac
EOF
  else
    cat <<'EOF'
Clipboard sharing with the Mac through UTM's shared folder.

Usage:
  omarchy-arm-clipboard             monitor changes
  omarchy-arm-clipboard --install   install and start the service
  omarchy-arm-clipboard --host      print the companion Mac script
EOF
  fi
}

instalar() {
  mkdir -p ~/.config/systemd/user
  local description; description=$(ui_text 'Clipboard shared with the host (through UTM shared folder)' 'Portapapeles compartido con el anfitrion (via carpeta compartida de UTM)')
  cat > ~/.config/systemd/user/omarchy-arm-clipboard.service <<UNIT
[Unit]
Description=$description
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
  systemctl --user enable --now omarchy-arm-clipboard.service && ui_text 'service active' 'servicio activo'; echo
  systemctl --user --no-pager status omarchy-arm-clipboard.service | head -5
}

script_anfitrion() {
  if [[ $OMARCHY_LANG == es ]]; then
    cat <<'MACEOF'
#!/bin/bash
# Ejecuta EN EL MAC. Sincroniza el portapapeles con la VM mediante la
# carpeta compartida configurada en UTM.
#   ./clipboard-mac.sh ~/ruta/a/la/carpeta/compartida
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
  else
    cat <<'MACEOF'
#!/bin/bash
# Run ON THE MAC. Synchronizes the clipboard with the VM through the
# folder you have shared in the VM settings in UTM.
#   ./clipboard-mac.sh ~/path/to/shared/folder
set -uo pipefail
DIR="${1:?usage: $0 <folder shared with the VM>}"
F="$DIR/.clipboard"
mkdir -p "$DIR"; touch "$F"
last_local=""; last_remote="$(cat "$F" 2>/dev/null || true)"
while :; do
  current="$(pbpaste 2>/dev/null || true)"
  if [ "$current" != "$last_local" ] && [ -n "$current" ]; then
    printf '%s' "$current" > "$F"; last_local="$current"; last_remote="$current"
  fi
  remote="$(cat "$F" 2>/dev/null || true)"
  if [ "$remote" != "$last_remote" ] && [ -n "$remote" ]; then
    printf '%s' "$remote" | pbcopy; last_remote="$remote"; last_local="$remote"
  fi
  sleep 1
done
MACEOF
  fi
}

vigilar() {
  command -v wl-paste >/dev/null || { echo "$(ui_text 'wl-clipboard is missing' 'falta wl-clipboard')" >&2; exit 1; }
  if [ ! -d "$SHARE" ]; then
    echo "$(ui_text "there is no shared folder at $SHARE." "no hay carpeta compartida en $SHARE.")" >&2
    echo "$(ui_text 'In UTM: VM Settings -> Sharing -> choose a folder, then restart.' 'En UTM: Ajustes de la VM -> Compartir -> elige una carpeta, y reinicia.')" >&2
    exit 1
  fi
  touch "$FILE" 2>/dev/null || { echo "$(ui_text "cannot write to $FILE" "no puedo escribir en $FILE")" >&2; exit 1; }
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
  *)         echo "$(ui_text "unknown option: $1" "opcion desconocida: $1")" >&2; uso >&2; exit 1 ;;
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
LANGUAGE = os.environ.get("OMARCHY_LANG", "")
if not LANGUAGE:
    try:
        with open("/etc/omarchy-arm.conf", encoding="utf-8") as config:
            for line in config:
                if line.startswith("OMARCHY_LANG="):
                    LANGUAGE = line.split("=", 1)[1].strip().strip("'\"")
                    break
    except OSError:
        pass
LANGUAGE = "es" if LANGUAGE == "es" else "en"

def ui_text(english, spanish):
    return spanish if LANGUAGE == "es" else english

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
                log(ui_text("socket closed:", "socket cerrado:"), e); return
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
                    log(ui_text("  received from host:", "  recibido del anfitrion:"), len(texto), "bytes")

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
        log(ui_text("wl-copy failed:", "wl-copy fallo:"), e)


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
            print(ui_text(f"missing {c} (wl-clipboard package)", f"falta {c} (paquete wl-clipboard)"), file=sys.stderr); return 1
    if not os.path.exists(SOCK):
        print(ui_text(f"{SOCK} does not exist.", f"no existe {SOCK}."), file=sys.stderr)
        print(ui_text("Start the daemon:  sudo systemctl start spice-vdagentd",
                      "Arranca el demonio:  sudo systemctl start spice-vdagentd"),
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
[ -r /etc/omarchy-arm.conf ] && . /etc/omarchy-arm.conf
: "${OMARCHY_LANG:=en}"
ui_text() { if [[ $OMARCHY_LANG == es ]]; then printf '%s' "${2:-$1}"; else printf '%s' "$1"; fi; }
usage() {
  if [[ $OMARCHY_LANG == es ]]; then
    printf '%s\n' 'Uso: omarchy-arm-share [--status|--umount]' \
      'Monta la carpeta compartida de UTM mediante VirtFS o SPICE WebDAV.'
  else
    printf '%s\n' 'Usage: omarchy-arm-share [--status|--umount]' \
      'Mounts the UTM shared folder through VirtFS or SPICE WebDAV.'
  fi
}
PUNTO="${OMARCHY_SHARE_MNT:-/mnt/share}"
TAG=share
PUERTO_WEBDAV=/dev/virtio-ports/org.spice-space.webdav.0
URL=http://localhost:9843/

hay_9p()     { grep -qw 9p /proc/filesystems 2>/dev/null && [ -e /sys/bus/virtio/drivers/9pnet_virtio ]; }
hay_webdav() { [ -e "$PUERTO_WEBDAV" ]; }
montado()    { mountpoint -q "$PUNTO"; }

estado() {
  echo "  $(ui_text 'mount point' 'punto de montaje'): $PUNTO"
  echo "  $(ui_text 'mounted' 'montado'):          $(montado && ui_text yes sí || ui_text no no)"
  echo "  $(ui_text 'VirtFS (9p) mode' 'modo VirtFS (9p)'): $(hay_9p && ui_text available disponible || ui_text no no)"
  echo "  $(ui_text 'SPICE WebDAV mode' 'modo SPICE WebDAV'):$(hay_webdav && ui_text ' available' ' disponible' || ui_text ' no' ' no')"
  if hay_webdav; then
    echo "  spice-webdavd:    $(systemctl is-active spice-webdavd 2>&1)"
  fi
  montado && { echo "  $(ui_text 'contents' 'contenido'):"; ls -la "$PUNTO" 2>/dev/null | head -6 | sed 's/^/    /'; }
}

montar() {
  montado && { echo "$(ui_text "already mounted at $PUNTO" "ya está montado en $PUNTO")"; return 0; }
  sudo mkdir -p "$PUNTO"

  # 1) VirtFS: the simplest option, if the device is
  if sudo mount -t 9p -o trans=virtio,version=9p2000.L,rw,msize=512000 "$TAG" "$PUNTO" 2>/dev/null; then
    echo "$(ui_text "mounted through VirtFS (9p) at $PUNTO" "montado por VirtFS (9p) en $PUNTO")"; return 0
  fi

  # 2) SPICE WebDAV
  if hay_webdav; then
    sudo systemctl start spice-webdavd 2>/dev/null || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      curl -s -m 2 -o /dev/null "$URL" && break
      sleep 1
    done
    if ! curl -s -m 3 -o /dev/null "$URL"; then
      echo "$(ui_text "spice-webdavd is not responding at $URL" "spice-webdavd no responde en $URL")" >&2
      echo "  systemctl status spice-webdavd" >&2
      return 1
    fi
    # davfs2 prompts for username and password: not needed here
    if printf '\n\n' | sudo mount -t davfs -o "rw,uid=$(id -u),gid=$(id -g)" "$URL" "$PUNTO" 2>/dev/null; then
      echo "$(ui_text "mounted through SPICE WebDAV at $PUNTO" "montado por SPICE WebDAV en $PUNTO")"; return 0
    fi
    echo "$(ui_text "davfs2 could not mount $URL" "davfs2 no pudo montar $URL")" >&2
    return 1
  fi

  echo "$(ui_text 'no shared folder was found.' 'no encuentro ninguna carpeta compartida.')" >&2
  echo "$(ui_text 'In UTM: VM Settings → Sharing → choose a path (VirtFS or SPICE WebDAV),' 'En UTM: Ajustes de la VM → Compartir → elige una ruta (VirtFS o SPICE WebDAV),')" >&2
  echo "$(ui_text 'then power the VM off and on.' 'y apaga y enciende la VM.')" >&2
  return 1
}

case "${1:-}" in
  --umount|-u) sudo umount "$PUNTO" && ui_text unmounted desmontado; echo ;;
  --status|-s) estado ;;
  -h|--help)   usage ;;
  "")          montar ;;
  *)           echo "$(ui_text "unknown option: $1" "opción desconocida: $1")" >&2; exit 1 ;;
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

set UI_LANG [expr {[info exists env(OMARCHY_LANG)] && $env(OMARCHY_LANG) eq "es" ? "es" : "en"}]
proc ui_text {english spanish} { global UI_LANG; expr {$UI_LANG eq "es" ? $spanish : $english} }
proc die {code english spanish} { puts "\n!! [ui_text $english $spanish]"; exit $code }
proc wait_for {pat code english spanish {t 900}} {
    set timeout $t
    expect {
        -ex $pat {}
        timeout  { die $code "TIMEOUT: $english" "TIMEOUT: $spanish" }
        eof      { die [expr {$code+40}] "unexpected EOF: $english" "EOF inesperado: $spanish" }
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
wait_for "localhost login:" 10 "the Alpine live system did not reach login" "el live de Alpine no llegó al login" 300
send "root\r"
wait_for "localhost:~#" 11 "there is no root shell in Alpine" "no hay shell de root en Alpine" 120

send "export PS1='RDY> '; echo TOK_SH_\$?\r"
wait_for "TOK_SH_0" 12 "could not set the prompt" "no se pudo fijar el prompt" 60

# --- locate and mount the provisioning ISO
send "mkdir -p /media/prov; for d in /dev/vd? /dev/sr?; do mount -t iso9660 -o ro \$d /media/prov 2>/dev/null && \[ -f /media/prov/stage1.sh \] && break; umount /media/prov 2>/dev/null; done; ls /media/prov; echo TOK_PROV_\$?\r"
wait_for "TOK_PROV_0" 13 "the provisioning ISO was not found" "no se encontró el ISO de aprovisionamiento" 120

send "test -s /media/prov/alarm-rootfs.tgz; echo TOK_TGZ_\$?\r"
wait_for "TOK_TGZ_0" 14 "the Arch Linux ARM rootfs is missing from the ISO" "falta el rootfs de Arch Linux ARM en el ISO" 60

# --- complete build (partitioning + chroot + packages + dotfiles)
set timeout -1
# stage1.sh emits the token TOK_BUILD_<rc> itself (a pipe to tee
# would mask the return code).
send "export DISK=/dev/vda; sh /media/prov/stage1.sh 2>&1 | tee /tmp/build.log\r"

expect {
    -ex "TOK_BUILD_0" {
        puts "\n\n==========================================="
        puts "   [ui_text {BUILD COMPLETED} {CONSTRUCCION COMPLETADA}]"
        puts "===========================================\n"
    }
    -re {TOK_BUILD_[1-9][0-9]*} {
        puts "\n\n!!!!!! [ui_text {THE BUILD FAILED} {LA CONSTRUCCION FALLO}] !!!!!!\n"
        set timeout 300
        set tail_label [ui_text {last 80 lines} {ultimas 80 lineas}]
        send "echo; echo ---- $tail_label ----; tail -n 80 /tmp/build.log; echo TOK_TAIL_\$?\r"
        catch { wait_for "TOK_TAIL_" 15 "tail output" "salida de tail" 300 }
        exit 20
    }
    eof { die 16 "EOF during the build" "EOF durante la construcción" }
}

# --- verify the resulting disk
set timeout 600
set verify_label [ui_text {VERIFICATION} {VERIFICACION}]
set user_label [ui_text {user} {usuario}]
send "mount -o subvol=@ /dev/vda2 /mnt 2>/dev/null || mount /dev/vda2 /mnt; mount /dev/vda1 /mnt/boot 2>/dev/null; echo '==== $verify_label ===='; echo '-- ESP --'; find /mnt/boot -maxdepth 3 | head -40; echo '-- kernel --'; ls -la /mnt/boot/Image* /mnt/boot/initramfs* 2>/dev/null; echo '-- $user_label --'; ls -la /mnt/home/; echo '-- dotfiles --'; for h in /mnt/home/*/; do echo \"  \$h:\"; ls \"\$h/.config\" 2>/dev/null | tr '\\n' ' '; echo; done; echo; echo '-- hyprland --'; ls -la /mnt/usr/bin/Hyprland 2>/dev/null; echo TOK_VERIFY_\$?\r"
catch { wait_for "TOK_VERIFY_" 17 "verification" "verificación" 600 }

send "sync; umount -R /mnt 2>/dev/null; poweroff -f\r"
expect eof
puts "\n===== [ui_text {BUILD VM POWERED OFF} {VM DE CONSTRUCCION APAGADA}] ====="
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
set UI_LANG [expr {[info exists env(OMARCHY_LANG)] && $env(OMARCHY_LANG) eq "es" ? "es" : "en"}]
proc ui_text {english spanish} { global UI_LANG; expr {$UI_LANG eq "es" ? $spanish : $english} }
if {$FIX eq ""} { puts [ui_text "usage: repair.exp <fix.sh>" "uso: repair.exp <fix.sh>"]; exit 1 }

proc wait_for {pat code english spanish {t 900}} {
    set timeout $t
    expect { -ex $pat {} timeout { puts "\n!! TIMEOUT: [ui_text $english $spanish]"; exit $code }
             eof { puts "\n!! EOF: [ui_text $english $spanish]"; exit [expr {$code+40}] } }
}
# write_payloads replaces @OMARM_ROOT@ when deploying this file. If the
# marker is still there, it means it is running from a repository clone:
# then the root comes from OMARM_ROOT or the current directory.
set ROOT "@OMARM_ROOT@"
if {[string match "@*@" $ROOT]} {
  set ROOT [expr {[info exists env(OMARM_ROOT)] ? $env(OMARM_ROOT) : [pwd]}]
}
spawn -noecho $ROOT/scripts/qemu-build.sh
wait_for "localhost login:" 10 "Alpine login" "login de Alpine" 300
send "root\r"
wait_for "localhost:~#" 11 "root shell" "shell de root" 120
send "export PS1='RDY> '; echo TOK_SH_\$?\r"
wait_for "TOK_SH_0" 12 "prompt" "prompt" 60
send "mkdir -p /media/prov; for d in /dev/vd? /dev/sr?; do mount -t iso9660 -o ro \$d /media/prov 2>/dev/null && \[ -f /media/prov/repair.sh \] && break; umount /media/prov 2>/dev/null; done; ls /media/prov; echo TOK_PROV_\$?\r"
wait_for "TOK_PROV_0" 13 "provisioning ISO" "ISO de aprovisionamiento" 120

set timeout -1
send "export FIXSCRIPT=$FIX; sh /media/prov/repair.sh 2>&1 | tee /tmp/repair.log\r"
expect {
    -ex "TOK_REPAIR_0" { puts "\n\n===== [ui_text {REPAIR COMPLETED} {REPARACION COMPLETADA}] =====\n" }
    -re {TOK_REPAIR_[1-9][0-9]*} { puts "\n\n!!!!! [ui_text {THE REPAIR FAILED} {LA REPARACION FALLO}] !!!!!\n"; exit 20 }
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
: "${VARS_TPL:=/Applications/UTM.app/Contents/Resources/qemu/edk2-arm-vars.fd}"
: "${UTM_CPUS:=8}"
: "${UTM_MEM:=8192}"
: "${OMARCHY_LANG:=auto}"

detect_ui_language() {
  local locale="" keyboard=""
  case "$OMARCHY_LANG" in
    en|es) return 0 ;;
    auto) ;;
    *) printf "Invalid OMARCHY_LANG='%s'; expected auto, en, or es.\n" "$OMARCHY_LANG" >&2; return 2 ;;
  esac
  locale=$(defaults read -g AppleLocale 2>/dev/null || true)
  keyboard=$(defaults read "$HOME/Library/Preferences/com.apple.HIToolbox.plist" \
    AppleSelectedInputSources 2>/dev/null || true)
  case "$locale" in *_ES*|*-ES*|*_MX*|*-MX*|*@rg=ES*|*@rg=MX*) OMARCHY_LANG=es; return 0 ;; esac
  case "$keyboard" in *Spanish*|*Mexican*|*Mexico*) OMARCHY_LANG=es; return 0 ;; esac
  OMARCHY_LANG=en
}
detect_ui_language || exit $?
ui_text() { if [[ $OMARCHY_LANG == es ]]; then printf '%s' "${2:-$1}"; else printf '%s' "$1"; fi; }

validate_plist() {
  if command -v plutil >/dev/null 2>&1; then
    plutil -lint "$1"
    return
  fi
  python3 - "$1" <<'PY'
import plistlib
import sys

with open(sys.argv[1], "rb") as plist_file:
    plistlib.load(plist_file)
print(f"{sys.argv[1]}: OK")
PY
}

[ -f "$SRC_QCOW" ] || { echo "!! $(ui_text "missing $SRC_QCOW" "falta $SRC_QCOW")"; exit 1; }
[ -f "$VARS_TPL" ] || { echo "!! $(ui_text "missing UEFI NVRAM template $VARS_TPL" "falta la plantilla de NVRAM UEFI $VARS_TPL")"; exit 1; }

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
if [[ $OMARCHY_LANG == es ]]; then
  NOTES_TEXT="Arch Linux ARM (aarch64) + Hyprland + dotfiles de Omarchy 4.
Usuario: ${NOTES_USER} · Contraseña: ${NOTES_PASS} (también root). Cámbiala con passwd.
La tecla Option (⌥) actúa como SUPER. Lee LEEME.md."
else
  NOTES_TEXT="Arch Linux ARM (aarch64) + Hyprland + Omarchy 4 dotfiles.
User: ${NOTES_USER} · Password: ${NOTES_PASS} (also root). Change it with passwd.
The Option key (⌥) acts as SUPER. Read LEEME.md."
fi

DISK_UUID=$(uuidgen)
MAC=$(printf '02:%02X:%02X:%02X:%02X:%02X' $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)))

# UTM only scans Documents upon app launch, so to recognize the
# bundle you must restart it. But force-closing it wipes out any
# VMs the user has running, so check first.
if [ "$DEST_DIR" = "$DOCS" ] && pgrep -x UTM >/dev/null; then
  UTMCTL=/Applications/UTM.app/Contents/MacOS/utmctl
  CORRIENDO=$("$UTMCTL" list 2>/dev/null | awk '$2=="started"{print $3" "$4}' | grep -v "^$" || true)
  if [ -n "$CORRIENDO" ]; then
    echo "==> $(ui_text 'UTM HAS RUNNING VMs:' 'HAY VMs EN MARCHA en UTM:')"
    echo "$CORRIENDO" | sed 's/^/      /'
    echo "    $(ui_text 'Registering the bundle requires restarting UTM, which would stop them.' 'Para registrar el bundle hay que reiniciar UTM, y eso las cortaria.')"
    if [ -t 0 ] && [ "${ASSUME_YES:-}" != "1" ]; then
      printf "    %s " "$(ui_text 'Stop them and restart UTM? [y/N]:' '¿Cerrarlas y reiniciar UTM? [s/N]:')"
      read -r R </dev/tty || R=""
      case "$(printf '%s' "$R" | tr '[:upper:]' '[:lower:]')" in
        s|si|y|yes) : ;;
        *) echo "==> $(ui_text 'UTM will not be restarted; import the bundle manually with File → Import' 'no se reinicia UTM: importa el bundle a mano con Archivo → Importar')"; SKIP_RESTART=1 ;;
      esac
    else
      echo "==> $(ui_text 'unattended mode: UTM will NOT be closed. Import the bundle manually.' 'modo desatendido: NO se cierra UTM. Importa el bundle a mano.')"
      SKIP_RESTART=1
    fi
  fi
  if [ "${SKIP_RESTART:-0}" != "1" ]; then
    echo "==> $(ui_text 'closing UTM so it rescans Documents' 'cerrando UTM para que reescanee Documents')"
    osascript -e 'quit app "UTM"' >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x UTM >/dev/null || break; sleep 1; done
    pgrep -x UTM >/dev/null && { pkill -x UTM || true; sleep 2; }
  fi
fi

echo "==> $(ui_text 'creating' 'creando') $BUNDLE"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Data"
echo "    $(ui_text 'copying disk' 'copiando disco') ($(du -h "$SRC_QCOW" | cut -f1))"
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
		<string>$NOTES_TEXT</string>
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

echo "==> $(ui_text 'validating the plist' 'validando el plist')"
validate_plist "$BUNDLE/config.plist"
du -sh "$BUNDLE"
ls -la "$BUNDLE" "$BUNDLE/Data"

if [ "$DEST_DIR" = "$DOCS" ]; then
  echo "==> $(ui_text 'opening UTM so it registers the bundle' 'abriendo UTM para que registre el bundle')"
  open -a UTM
  sleep 6
  /Applications/UTM.app/Contents/MacOS/utmctl list || true
else
  echo "==> $(ui_text 'bundle created outside the UTM folder (not registered)' 'bundle creado fuera de la carpeta de UTM (no se registra)')"
fi

echo ""
echo "Bundle:  $BUNDLE"
echo "UUID:    $VM_UUID"
echo "$(ui_text 'Start' 'Arrancar'): /Applications/UTM.app/Contents/MacOS/utmctl start \"$NAME\""
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
OMARCHY_LANG='$(cfgq "$OMARCHY_LANG")'
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
INCLUDE_LIBRE_APPS='$(cfgq "$INCLUDE_LIBRE_APPS")'
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
  phase "build · disk construction (headless, QEMU + HVF)" "build · construccion del disco (headless, QEMU + HVF)"
  write_payloads
  validate_alarm_repository_snapshot
  ln -f "$W/dl/alarm-rootfs.tgz" /tmp/alarm-rootfs.tgz 2>/dev/null || true
  # the rootfs travels inside the provisioning ISO
  local d; d=$(mktemp -d)
  cp "$W/provision"/{stage1.sh,stage2.sh,stage3.sh,config.env,core-git-sources.tsv,free-app-artifacts.tsv,optional-app-artifacts.tsv,alarm-repository-snapshot.py,packages-core.txt,packages-extra.txt} "$d"/
  cp -R "$W/provision/alarm-repositories" "$d"/
  cp "$W/provision"/{extras.sh,armsync.sh,clipbrd.sh,vdagent.py,share.sh} "$d"/
  ln "$W/dl/alarm-rootfs.tgz" "$d/alarm-rootfs.tgz" 2>/dev/null || cp "$W/dl/alarm-rootfs.tgz" "$d/"
  rm -f "$W/provision/provision.iso"
  hdiutil makehybrid -iso -joliet -default-volume-name PROVISION -o "$W/provision/provision.iso" "$d" >/dev/null
  rm -rf "$d"
  ok "provisioning ISO $(du -h "$W/provision/provision.iso" | cut -f1)" "ISO de aprovisionamiento $(du -h "$W/provision/provision.iso" | cut -f1)"

  # Rebuilding discards the previous disk, which takes ~40 minutes of work. If there is
  # one and the session is interactive, it asks; otherwise, it keeps a copy.
  if [[ -s $W/vm/omarchy-arm.qcow2 ]]; then
    if confirm "$(ui_text "A built disk already exists ($(du -h "$W/vm/omarchy-arm.qcow2" | cut -f1)). Discard and rebuild it?" "Ya existe un disco construido ($(du -h "$W/vm/omarchy-arm.qcow2" | cut -f1)). ¿Descartarlo y reconstruir?")" no; then
      rm -f "$W/vm/omarchy-arm.qcow2"
    else
      mv "$W/vm/omarchy-arm.qcow2" "$W/vm/omarchy-arm.qcow2.anterior"
      info "the previous disk remains at $W/vm/omarchy-arm.qcow2.anterior" "el anterior queda en $W/vm/omarchy-arm.qcow2.anterior"
    fi
  fi
  rm -f "$W/vm/efi-vars.fd"
  qemu-img create -f qcow2 "$W/vm/omarchy-arm.qcow2" "$DISK_SIZE" >/dev/null
  dd if=/dev/zero of="$W/vm/efi-vars.fd" bs=1m count=64 status=none

  info "starting the builder (Alpine live → chroot → 3 stages)" "arrancando el constructor (Alpine live → chroot → 3 etapas)"
  info "this takes ~40 minutes depending on the network; full log at $W/logs/build.log" "esto tarda ~40 min segun la red; el log completo en $W/logs/build.log"
  OMARCHY_LANG=$OMARCHY_LANG VM_SMP=$BUILD_SMP VM_MEM=$BUILD_MEM PROV_ISO="$W/provision/provision.iso" \
    expect -f "$W/scripts/build.exp" > "$W/logs/build.log" 2>&1
  local rc=$?
  # stage2 emits TOK_STAGE3_<rc>: without checking it, a stage3 that fails entirely
  # (without dotfiles, without tools, without theme) passed as a successful build.
  if grep -qa "TOK_STAGE3_" "$W/logs/build.log" && ! grep -qa "TOK_STAGE3_0" "$W/logs/build.log"; then
    sed 's/\x1b\[[0-9;?=]*[a-zA-Z]//g' "$W/logs/build.log" | grep -aE "^(!!|==>)" | tail -25
    die "stage3 failed: the disk exists but does not have the Omarchy configuration. Log: $W/logs/build.log" "stage3 fallo: el disco existe pero no tiene la configuracion de Omarchy. Log: $W/logs/build.log"
  fi
  grep -qa "TOK_BUILD_0" "$W/logs/build.log" || {
    sed 's/\x1b\[[0-9;?=]*[a-zA-Z]//g' "$W/logs/build.log" | tail -40
    die "the build failed (rc=$rc); check $W/logs/build.log" "la construccion fallo (rc=$rc); revisa $W/logs/build.log"
  }
  ok "disk built: $(du -h "$W/vm/omarchy-arm.qcow2" | cut -f1)" "disco construido: $(du -h "$W/vm/omarchy-arm.qcow2" | cut -f1)"
}

# ──────────────────────────────── phase: utm ────────────────────────────────
ph_utm() {
  phase "utm · bundle .utm"
  write_payloads
  [[ -s $W/vm/omarchy-arm.qcow2 ]] || die "there is no built disk; run the build phase" "no hay disco construido; ejecuta la fase build"
  # Deleting a VM with the same name destroys its disk. If one already exists, it asks;
  # without a terminal, it chooses another name instead of destroying anything.
  if "$UTMCTL" list 2>/dev/null | grep -q "  $VM_NAME$"; then
    if confirm "$(ui_text "A VM named '$VM_NAME' already exists in UTM. Delete and replace it?" "Ya existe una VM llamada '$VM_NAME' en UTM. ¿Borrarla y reemplazarla?")" no; then
      "$UTMCTL" delete "$VM_NAME" >/dev/null 2>&1 || true; sleep 2
    else
      VM_NAME="$VM_NAME $(date +%H%M)"
      info "it will be registered as '$VM_NAME'" "se registrara como '$VM_NAME'"
    fi
  fi
  local ulog="$W/logs/make-utm.log"
  if ! SRC_QCOW="$W/vm/omarchy-arm.qcow2" UTM_CPUS=$UTM_CPUS UTM_MEM=$UTM_MEM \
       NOTES_USER="$VM_USER" NOTES_PASS="$VM_PASSWORD" ASSUME_YES="${ASSUME_YES:-}" OMARCHY_LANG="$OMARCHY_LANG" \
       bash "$W/scripts/make-utm.sh" "$VM_NAME" > "$ulog" 2>&1; then
    tail -20 "$ulog"
    die "make-utm.sh failed; full log at $ulog" "make-utm.sh fallo; log completo en $ulog"
  fi
  tail -4 "$ulog"
  [[ -f "$DOCS/$VM_NAME.utm/config.plist" ]] || die "the bundle was not created in $DOCS" "el bundle no quedo en $DOCS"
  ok "bundle created at $DOCS/$VM_NAME.utm" "bundle creado en $DOCS/$VM_NAME.utm"
}

# ─────────────────────────────── phase: verify ──────────────────────────────
ph_verify() {
  phase "verify · boot and validation" "verify · arranque y comprobacion"
  "$UTMCTL" start "$VM_NAME" >/dev/null 2>&1 || true
  info "waiting for the VM to boot..." "esperando al arranque..."
  sleep 60
  local pty="" attempt
  for attempt in 1 2 3 4 5 6 7 8 9 10 11 12; do
    # `utmctl attach` normally prints the PTY and exits, but it can also wait
    # indefinitely for UTM's serial backend. Bound each attempt so the retry
    # loop is real rather than another unbounded wait.
    pty=$(python3 - "$UTMCTL" "$VM_NAME" <<'PY' \
      | grep -o '/dev/ttys[0-9]*' | head -1
import subprocess, sys

process = subprocess.Popen([sys.argv[1], "attach", sys.argv[2]], stdout=subprocess.PIPE,
                           stderr=subprocess.STDOUT)
try:
    output, _ = process.communicate(timeout=5)
except subprocess.TimeoutExpired as error:
    process.terminate()
    try:
        remainder, _ = process.communicate(timeout=2)
    except subprocess.TimeoutExpired:
        process.kill()
        remainder, _ = process.communicate()
    output = (error.output or b"") + (remainder or b"")
sys.stdout.buffer.write(output or b"")
PY
    )
    [[ -n $pty ]] && break
    (( attempt == 1 )) && info "waiting for UTM's serial port..." "esperando el puerto serie de UTM..."
    sleep 5
  done
  # Previously this was "warn + return 0": without a serial port there is no verification
  # possible, and proceeding to sanitize/package would package an image that no one has
  # looked at. If you really want to skip it: --from sanitize.
  [[ -n $pty ]] || die "could not open the serial port for '$VM_NAME'; verification is impossible without it (to continue anyway: --from sanitize)" "no se pudo abrir el puerto serie de '$VM_NAME'; sin el no hay verificacion posible (si quieres continuar igualmente: --from sanitize)"
  # Previously this phase collected metrics and did not compare them with anything, so
  # it ended in "ok" regardless of what happened. Now the guest emits a verdict
  # and the host checks it. Thirteen conditions, all necessary:
  #   H  Hyprland running
  #   Q  quickshell running (if it were waybar, this would be Omarchy 3)
  #   B  >=400 omarchy-* commands in /usr/bin (counted by name, not by
  #      total directory size: /usr/bin has ~2900 system files and
  #      "ls | wc -l" would pass any threshold even if there were none)
  #   R  <=5 broken symlinks (one is from qt6-webengine, unrelated to this)
  #   U  >=6 user units installed: without them first-run fails in a loop
  #   V  the tree version starts with 4
  #   C  all five clipboard integration checks pass
  #   T  ttfx is available (the real binary or the static fallback)
  #   X  the selected tool contract passes (18 native tools for a full build,
  #      or the functional ttfx fallback for a lightweight build)
  #   Y  Chromium's managed-policy directory is a real, root-owned mode-755 directory
  #   P  installed Omarchy is exactly the reviewed source-lock commit
  #   F  both reviewed libre-app packages are installed when INCLUDE_LIBRE_APPS=yes
  #   S  the captured repository databases and installed-package provenance validate
  # The previous threshold checked /usr/local/bin, where commands are no longer placed: it was
  # a guaranteed false positive once they were moved to /usr/bin.
  local vlog="$W/logs/verify.log"
  # NOTE: the heredoc is QUOTED. Without quotes, the host's bash expands
  # the $(...) before expect sees them, and the checks run on
  # the Mac instead of inside the VM (pgrep with BSD syntax, systemctl
  # nonexistent). Required values are passed via the environment and read with
  # $env(...), which is a Tcl feature, not bash. Distribution builds repeat the
  # verdict after a real reboot because session regressions have previously
  # appeared only on the second boot.
  PTY="$pty" GUSER="$VM_USER" GPASS="$VM_PASSWORD" GLIBRE_APPS="$INCLUDE_LIBRE_APPS" \
    GTOOLS="$HACER_TOOLS" GREBOOT="$HACER_DIST" \
  expect > "$vlog" 2>&1 <<'EXPEOF'
set timeout 30
log_user 1
match_max 200000
remove_nulls 1
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
# NOTE 2: the token is SPLIT (VERD\"ICT_OK\"). The serial console echoes the
# command, so if the token traveled whole, the log would contain the string
# VERDICT_OK before the guest responded with anything, and the host's `grep`
# would find it there: the phase would always return OK, regardless of what happened.
# Split, the echo shows VERD"ICT_OK" and only the actual response matches.
#
# C counts the five known ways the clipboard can die. None
# require a connected SPICE client, so it can be checked here.
send "python3 /usr/share/omarchy-arm/alarm-repository-snapshot.py validate-provenance /usr/share/omarchy-arm/alarm-repositories /usr/share/omarchy-arm/alarm-repositories/manifest.tsv /usr/share/omarchy-arm/alarm-package-provenance.tsv >/dev/null 2>&1 && echo SNAP\"SHOT_OK\" || echo SNAP\"SHOT_KO\"\r"
expect { -re {SNAPSHOT_(OK|KO)} {} timeout {} }
send "D=/etc/chromium/policies/managed; test -d \"\$D\" && ! test -L \"\$D\" && test \"\$(stat -c '%U:%G:%a' \"\$D\")\" = root:root:755 && echo BROWSER_\"POLICY_OK\" || echo BROWSER_\"POLICY_KO\"\r"
expect { -re {BROWSER_POLICY_(OK|KO)} {} timeout {} }
send "/usr/local/bin/omarchy-arm-verify-tools \"$env(GTOOLS)\" >/dev/null 2>&1 && echo TOOL\"S_OK\" || echo TOOL\"S_KO\"\r"
expect { -re {TOOLS_(OK|KO)} {} timeout {} }
send "H=\$(pgrep -c Hyprland); Q=\$(pgrep -c quickshell); B=\$(find /usr/bin -maxdepth 1 -name 'omarchy-*' | wc -l); R=\$(find /usr/bin /usr/local/bin -xtype l | wc -l); U=\$(find /usr/lib/systemd/user -maxdepth 1 -name 'omarchy-*.service' | wc -l); V=\$(cat /usr/share/omarchy/version 2>/dev/null | cut -d. -f1); C=0; test -x /usr/local/bin/omarchy-arm-vdagent && C=\$((C+1)); pgrep -af spice-vdagentd | grep -q -- ' -X' && C=\$((C+1)); systemctl is-active --quiet spice-vdagentd && C=\$((C+1)); systemctl --user is-active --quiet omarchy-arm-vdagent.service && C=\$((C+1)); grep -vs -- '^\[\[:space:]]*--' ~/.config/hypr/autostart.lua | grep -qs spice-vdagent || C=\$((C+1)); T=0; command -v ttfx >/dev/null 2>&1 && T=1; P=0; L=\$(awk '\$1 == \"omarchy\" { print \$4 }' /usr/share/omarchy-arm/core-git-sources.tsv 2>/dev/null); A=\$(git -C /usr/share/omarchy rev-parse HEAD 2>/dev/null); \[ -n \"\$L\" ] && \[ \"\$A\" = \"\$L\" ] && P=1; F=0; pacman -Q pinta >/dev/null 2>&1 && F=\$((F+1)); pacman -Q obs-studio >/dev/null 2>&1 && F=\$((F+1)); E=0; \[ \"$env(GLIBRE_APPS)\" = yes ] && E=2; echo \"### H=\$H Q=\$Q BINS=\$B ROTOS=\$R UNITS=\$U VER=\$V CLIP=\$C/5 TTFX=\$T PIN=\$P FREE=\$F/\$E\"; if \[ \$H -ge 1 ] && \[ \$Q -ge 1 ] && \[ \$B -ge 400 ] && \[ \$R -le 5 ] && \[ \$U -ge 6 ] && \[ \"\$V\" = 4 ] && \[ \$C -eq 5 ] && \[ \$T -eq 1 ] && \[ \$P -eq 1 ] && \[ \$F -ge \$E ]; then echo VERD\"ICT_OK\"; else echo VERD\"ICT_KO\"; fi\r"
set timeout 60
expect { -re {VERDICT_(OK|KO)} {} timeout {} }
if {$env(GREBOOT) eq "si"} {
  send "sudo systemctl reboot\r"
  set timeout 240
  set reboot_ready 0
  expect {
    -re {[Pp]assword.*:} { send "$env(GPASS)\r"; exp_continue }
    -re {login:} { set reboot_ready 1 }
    timeout {}
  }
  if {$reboot_ready} {
    send "$env(GUSER)\r"
    expect -re {[Pp]assword:}
    send "$env(GPASS)\r"
    sleep 8
    send "H=\$(pgrep -c Hyprland); Q=\$(pgrep -c quickshell); C=0; test -x /usr/local/bin/omarchy-arm-vdagent && C=\$((C+1)); pgrep -af spice-vdagentd | grep -q -- ' -X' && C=\$((C+1)); systemctl is-active --quiet spice-vdagentd && C=\$((C+1)); systemctl --user is-active --quiet omarchy-arm-vdagent.service && C=\$((C+1)); grep -vs -- '^\[\[:space:]]*--' ~/.config/hypr/autostart.lua | grep -qs spice-vdagent || C=\$((C+1)); T=0; /usr/local/bin/omarchy-arm-verify-tools \"$env(GTOOLS)\" >/dev/null 2>&1 && T=1; S=0; python3 /usr/share/omarchy-arm/alarm-repository-snapshot.py validate-provenance /usr/share/omarchy-arm/alarm-repositories /usr/share/omarchy-arm/alarm-repositories/manifest.tsv /usr/share/omarchy-arm/alarm-package-provenance.tsv >/dev/null 2>&1 && S=1; D=/etc/chromium/policies/managed; B=0; test -d \"\$D\" && ! test -L \"\$D\" && test \"\$(stat -c '%U:%G:%a' \"\$D\")\" = root:root:755 && B=1; echo \"### REBOOT H=\$H Q=\$Q CLIP=\$C/5 TOOLS=\$T SNAPSHOT=\$S BROWSER_POLICY=\$B\"; if \[ \$H -ge 1 ] && \[ \$Q -ge 1 ] && \[ \$C -eq 5 ] && \[ \$T -eq 1 ] && \[ \$S -eq 1 ] && \[ \$B -eq 1 ]; then echo REBO\"OT_OK\"; else echo REBO\"OT_KO\"; fi\r"
    set timeout 90
    expect { -re {REBOOT_(OK|KO)} {} timeout { send_user "\nREBOOT_KO timeout\n" } }
  } else {
    send_user "\nREBOOT_KO no-login\n"
  }
}
EXPEOF
  sed 's/\x1b\[[0-9;?=]*[a-zA-Z]//g' "$vlog" | grep -aE "^###" | tail -1
  # SNAPSHOT_OK is the first command result after login, so systemd's OSC shell
  # integration can prefix it on the same physical line. The echoed command
  # contains SNAP"SHOT_OK" split across quotes, so an unanchored search still
  # cannot mistake command echo for the result.
  local reboot_ok=1
  [[ $HACER_DIST != si ]] || grep -qa "^REBOOT_OK" "$vlog" || reboot_ok=0
  if grep -qa "^VERDICT_OK" "$vlog" && grep -qa "SNAPSHOT_OK" "$vlog" \
      && grep -qa "BROWSER_POLICY_OK" "$vlog" \
      && grep -qa "TOOLS_OK" "$vlog" && (( reboot_ok )); then
    ok "VM '$VM_NAME' verified: reviewed sources and repository snapshot, package provenance, desktop, commands, units, and clipboard" "VM '$VM_NAME' verificada: fuentes y captura de repositorios revisadas, procedencia de paquetes, escritorio, comandos, unidades y portapapeles"
  elif grep -qa "^VERDICT_KO" "$vlog" || grep -qa "SNAPSHOT_KO" "$vlog" \
      || grep -qa "BROWSER_POLICY_KO" "$vlog" \
      || grep -qa "TOOLS_KO" "$vlog" || grep -qa "REBOOT_KO" "$vlog"; then
    sed 's/\x1b\[[0-9;?=]*[a-zA-Z]//g' "$vlog" | tail -20
    die "the VM boots but the desktop is incomplete; log at $vlog" "la VM arranca pero el escritorio no esta completo; log en $vlog"
  else
    # This also cannot be a warning: if the guest does not respond, we know
    # nothing about the image, and the next step would be to package and distribute it.
    sed 's/\x1b\[[0-9;?=]*[a-zA-Z]//g' "$vlog" | tail -20
    die "the guest did not emit a verdict over the serial port; log at $vlog" "el invitado no emitio veredicto por el puerto serie; log en $vlog"
  fi
}

# ────────────────────────────── phase: sanitize ─────────────────────────────
ph_sanitize() {
  phase "sanitize · clean distribution copy" "sanitize · copia limpia para distribuir"
  write_payloads
  "$UTMCTL" stop "$VM_NAME" >/dev/null 2>&1 || true
  while [[ $("$UTMCTL" status "$VM_NAME" 2>/dev/null) == started ]]; do sleep 3; done

  local src; src=$(find "$DOCS/$VM_NAME.utm/Data" -name '*.qcow2' | head -1)
  [[ -s $src ]] || src="$W/vm/omarchy-arm.qcow2"
  rm -f "$W/dist/dist.qcow2"
  cp -c "$src" "$W/dist/dist.qcow2" 2>/dev/null || cp "$src" "$W/dist/dist.qcow2"
  ok "working copy created (the original VM is untouched)" "copia de trabajo hecha (la VM original no se toca)"

  make_iso "$W/provision/repair.iso" "$W/provision/repair.sh" "$W/provision/sanitize.sh" \
           "$W/provision/config.env" "$W/provision/extras.sh" "$W/provision/armsync.sh"
  info "cleaning (generic user, no keys or identity)..." "limpiando (usuario generico, sin claves ni identidad)..."
  OMARCHY_LANG="$OMARCHY_LANG" PROV_ISO="$W/provision/repair.iso" DISK_IMG="$W/dist/dist.qcow2" \
  DIST_OLD_USER="$VM_USER" DIST_NEW_USER="$DIST_NEW_USER" \
    expect -f "$W/scripts/repair.exp" sanitize.sh > "$W/logs/sanitize.log" 2>&1
  # TOK_REPAIR_0 only indicates that the chroot did not crash, and sanitize.sh runs without
  # -e: it returned 0 even if usermod had failed and the image retained the
  # builder's user. The meaningful token is SANITIZE_OK, which
  # now causes sanitize.sh to print only if its invariants are met.
  if grep -qa "SANITIZE_FALLO" "$W/logs/sanitize.log"; then
    sed 's/\x1b\[[0-9;?=]*[a-zA-Z]//g' "$W/logs/sanitize.log" | grep -aE "✗|SANITIZE_FALLO" | tail -20
    die "the image failed the distribution invariants; check $W/logs/sanitize.log" "la imagen no paso los invariantes de distribucion; revisa $W/logs/sanitize.log"
  fi
  grep -qa "SANITIZE_OK" "$W/logs/sanitize.log" || {
    sed 's/\x1b\[[0-9;?=]*[a-zA-Z]//g' "$W/logs/sanitize.log" | tail -30
    die "sanitization did not complete; check $W/logs/sanitize.log" "la limpieza no llego al final; revisa $W/logs/sanitize.log"
  }
  grep -qa "TOK_REPAIR_0" "$W/logs/sanitize.log" || {
    sed 's/\x1b\[[0-9;?=]*[a-zA-Z]//g' "$W/logs/sanitize.log" | tail -30
    die "sanitization failed; check $W/logs/sanitize.log" "la limpieza fallo; revisa $W/logs/sanitize.log"
  }
  ok "image sanitized and distribution invariants verified" "imagen sanitizada y con los invariantes de distribucion comprobados"
}

# ────────────────────────────── phase: package ──────────────────────────────
ph_package() {
  phase "package · compact and compress" "package · compactar y comprimir"
  [[ -s $W/dist/dist.qcow2 ]] || die "there is no sanitized image; run the sanitize phase" "no hay imagen sanitizada; ejecuta la fase sanitize"
  info "compacting and compressing QCOW2 clusters..." "compactando y comprimiendo los clusters del qcow2..."
  rm -f "$W/dist/slim.qcow2"
  # -c compresses within the qcow2 itself: the image occupies half the space even when
  # decompressed on the recipient's disk. It decompresses upon reading.
  qemu-img convert -c -O qcow2 "$W/dist/dist.qcow2" "$W/dist/slim.qcow2" || die "qemu-img convert failed" "qemu-img convert fallo"
  qemu-img check "$W/dist/slim.qcow2" >/dev/null || die "the compacted image failed validation" "la imagen compactada no valida"
  ok "$(du -h "$W/dist/dist.qcow2" | cut -f1) → $(du -h "$W/dist/slim.qcow2" | cut -f1)"

  # El bundle que se reparte NO lleva $VM_NAME. Ese nombre es del constructor y
  # puede ser cualquier cosa ("Omarchy ARM v5" en una de las tandas), y viajaba
  # dentro del zip como nombre de directorio y como <key>Name</key>, de modo que
  # al importarla en UTM aparecia con el versionado interno de quien la creo.
  # Ademas el LEEME dice «doble clic en Omarchy ARM.utm», que entonces no existia.
  # El nombre que vera quien la importe en UTM. Lleva la version a proposito:
  # "Omarchy ARM" a secas no distinguia nada el dia que salga Omarchy 5, y es
  # el mismo nombre con el que se anuncia en la galeria de UTM.
  local DNAME="${DIST_VM_NAME:-Omarchy 4 ARM64}"
  rm -rf "$W/dist/$DNAME.utm"
  OMARCHY_LANG="$OMARCHY_LANG" SRC_QCOW="$W/dist/slim.qcow2" DEST_DIR="$W/dist" UTM_CPUS=$UTM_CPUS UTM_MEM=$UTM_MEM \
    NOTES_USER="$DIST_NEW_USER" NOTES_PASS="$DIST_NEW_USER" \
    bash "$W/scripts/make-utm.sh" "$DNAME" >/dev/null \
    || die "could not create the distributable bundle" "no se pudo crear el bundle distribuible"
  # Final check: neither the plist nor the BUNDLE NAME should bear any trace of the
  # user or the builder's project name.
  if grep -q "\b$VM_USER\b" "$W/dist/$DNAME.utm/config.plist" 2>/dev/null; then
    die "the bundle config.plist mentions '$VM_USER'; check make-utm.sh" "el config.plist del bundle menciona a '$VM_USER'; revisa make-utm.sh"
  fi
  # Digitos incluidos: el nombre lleva la version. Sin ellos, este mismo filtro
  # rechazaba "Omarchy 4 ARM64", que es justo el nombre que queremos.
  if [[ "$DNAME" != "$(printf '%s' "$DNAME" | tr -cd 'A-Za-z0-9 .-')" ]]; then
    die "distribution name '$DNAME' contains unusual characters; use letters, digits, spaces, dots, or hyphens" "el nombre de distribucion '$DNAME' lleva caracteres raros; usa letras, digitos, espacio, punto o guion"
  fi
  write_readme "$W/dist/LEEME.md"

  info "compressing..." "comprimiendo..."
  ( cd "$W/dist" && rm -f "$DIST_ZIP" \
      && zip -r -q -1 "$DIST_ZIP" "$DNAME.utm" LEEME.md \
      && shasum -a 256 "$DIST_ZIP" > "$DIST_ZIP.sha256" )
  rm -f "$W/dist/dist.qcow2" "$W/dist/slim.qcow2"
  ok "ready: $W/dist/$DIST_ZIP ($(du -h "$W/dist/$DIST_ZIP" | cut -f1))" "listo: $W/dist/$DIST_ZIP ($(du -h "$W/dist/$DIST_ZIP" | cut -f1))"
  cat "$W/dist/$DIST_ZIP.sha256"
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
- ~9 GB de disco libre: el `.zip` y la imagen descomprimida ocupan unos
  3,7 GB cada uno, más lo que crezca al usarla

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
menú, terminal, navegador, y los 442 comandos `omarchy-*`.

Incluye además las herramientas propias de Omarchy **compiladas para aarch64**,
que no se publican para ARM: `tensaku` (anotación de capturas), `omacalc`,
`omacut`, `omawrite`, `aether` (temas), `cliamp` (reproductor), `ttfx` (efectos
del salvapantallas), `omarchy-nvim`, `mise`, `tzupdate`, `yaru-icon-theme`,
`ttf-ia-writer`, `hyprland-preview-share-picker`, `xdg-terminal-exec`,
`tobi-try`, `ufw-docker`, `yay` y `herdr`.

Y dos aplicaciones de software libre ya compiladas para ARM: **OBS Studio
32.2.2** (sin el plugin de navegador, cuyo CEF es x86-only) y **Pinta 3.1.2**
(sobre el .NET arm64 oficial de Microsoft).

Esta imagen se validó el **29-08-2026** con las 18 herramientas ARM, OBS y
Pinta; dos arranques consecutivos en UTM; portapapeles real en ambos sentidos;
y un arranque adicional del disco empaquetado en modo `qemu -snapshot`.

Limitaciones propias de correr Omarchy en ARM:

- **Sin aceleración GL dentro de la VM.** Las ventanas se dibujan por software
  (llvmpipe). Bajo virtio-gpu los clientes GPU se mapean pero no se pintan; el
  blur y las sombras vienen desactivados para compensar. Es fluido para uso
  normal, no para vídeo ni 3D.
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

1Password, Obsidian, Typora, LocalSend, Google Chrome y Zed **no están en la
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

El instalador no busca la versión más reciente en cada ejecución: usa artefactos
y recetas AUR revisados y fijados. 1Password exige tanto el SHA-256 registrado
como una firma de la clave oficial esperada; Obsidian exige su URL versionada y
SHA-256 exactos. Si falta un bloqueo o no coincide la verificación, se detiene
antes de modificar el sistema. `--force` reinstala la versión revisada.

También está en el menú de aplicaciones como **«Instalar apps que faltan (ARM)»**.
Las opciones normales **Install → Service → 1Password**, **Spotify (Web)**,
**Install → Browser → Chrome** e **Install → Editor → Zed** de Omarchy también
pasan por este instalador revisado para ARM, en vez del repositorio de paquetes
x86. Zed instala tanto `zed` como el comando `zeditor` que espera Omarchy.

El resto del catálogo no se muestra a ciegas: las entradas cuyo paquete actual
solo sirve para x86, está incompleto en ARM o aún no tiene fuente revisada y
prueba de arranque quedan ocultas mediante
`~/.config/omarchy/extensions/omarchy-menu.jsonc`. Si se invoca directamente
uno de esos instaladores por CLI, termina con un error claro de incompatibilidad
ARM. Siguen visibles las rutas nativas comprobadas: Firefox, Signal, Tailscale,
Helix, Vim, Alacritty, Foot, Kitty, fuentes, web apps y toolchains de desarrollo.

También queda oculto **Update → Channel** y bloqueado `omarchy-channel-set`,
porque esos canales sustituyen la configuración de pacman por mirrors de
Omarchy que solo publican x86. Usa **Update → Omarchy**: el hook ARM actualiza el
checkout Git revisado sin tocar los repositorios de Arch Linux ARM. La pantalla
verde **Done** solo aparece si el comando terminó correctamente.

| Clave | Qué hace |
|---|---|
| `1password` | Tarball arm64 oficial, con verificación de firma GPG |
| `1password-cli` | El comando `op`, binario estático arm64 |
| `obsidian` | Tarball arm64 oficial |
| `typora` | Paquete arm64 oficial vía AUR |
| `localsend` | Build arm64 oficial |
| `chrome` | Trae Widevine para arm64: habilita Spotify y Netflix web |
| `zed` | Tarball oficial Linux arm64 + integración de tema de Omarchy |
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
#   INCLUDE_LIBRE_APPS=no ./build-omarchy-arm.sh --yes
: "${HACER_TOOLS:=si}"
: "${HACER_DIST:=si}"

# INCLUDE_LIBRE_APPS is the canonical English control. HACER_LIBRES remains a
# read-only compatibility input for existing automation and saved answers.
if del_entorno INCLUDE_LIBRE_APPS; then
  :
elif del_entorno HACER_LIBRES; then
  case "$HACER_LIBRES" in
    si) INCLUDE_LIBRE_APPS=yes ;;
    no) INCLUDE_LIBRE_APPS=no ;;
    *) die "invalid legacy HACER_LIBRES='$HACER_LIBRES'; expected si or no" "HACER_LIBRES antiguo no valido: '$HACER_LIBRES'; se esperaba si o no" ;;
  esac
  FIJADO_POR_ENTORNO="$FIJADO_POR_ENTORNO INCLUDE_LIBRE_APPS"
else
  INCLUDE_LIBRE_APPS=yes
fi
case "$INCLUDE_LIBRE_APPS" in
  yes|no) ;;
  *) die "invalid INCLUDE_LIBRE_APPS='$INCLUDE_LIBRE_APPS'; expected yes or no" "INCLUDE_LIBRE_APPS no valido: '$INCLUDE_LIBRE_APPS'; se esperaba yes o no" ;;
esac
unset HACER_LIBRES

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
  phase "configuration" "configuracion"
  info "Press Enter to accept the value in brackets. Detected from your Mac." "Enter acepta el valor entre corchetes. Detectados de tu Mac."
  echo

  ask VM_TIMEZONE "$(ui_text 'Timezone' 'Zona horaria')"                       "$VM_TIMEZONE"
  ask VM_KEYMAP   "$(ui_text 'Keyboard (console)' 'Teclado (consola)')"        "$VM_KEYMAP"
  ask VM_XKB      "$(ui_text 'Keyboard (Hyprland/Wayland)' 'Teclado (Hyprland/Wayland)')" "$VM_XKB"
  echo
  ask UTM_CPUS    "$(ui_text 'VM CPU cores' 'Nucleos para la VM')"             "$UTM_CPUS"
  ask UTM_MEM     "$(ui_text 'VM memory (MiB)' 'Memoria para la VM (MiB)')"    "$UTM_MEM"
  ask DISK_SIZE   "$(ui_text 'Disk size' 'Tamano del disco')"                  "$DISK_SIZE"
  echo

  # About 40 minutes of compilation. The desktop works without these tools, but
  # the screensaver, screenshot annotator, calculator, and others are missing.
  if confirm "$(ui_text 'Build the 17 Omarchy tools unavailable for ARM (~40 min)?' 'Compilar las 17 herramientas de Omarchy que no existen para ARM (~40 min)?')" si; then
    HACER_TOOLS=si
  else
    HACER_TOOLS=no
    warn "without them, ttfx, tensaku, omacalc, omacut, omawrite, aether, cliamp, and others will be missing..." "sin ellas faltaran ttfx, tensaku, omacalc, omacut, omawrite, aether, cliamp..."
  fi
  echo

  # OBS and Pinta are the most expensive parts of the build. The distributable
  # image includes them because they are free software, but a test VM does not need them.
  if confirm "$(ui_text 'Include OBS Studio and Pinta (free software; ~45 min to build)?' 'Incluir OBS Studio y Pinta (software libre, se compilan: ~45 min)?')" si; then
    INCLUDE_LIBRE_APPS=yes
  else
    INCLUDE_LIBRE_APPS=no
    info "they can be added later inside the VM: omarchy-arm-extras pinta obs" "se pueden anadir despues desde dentro: omarchy-arm-extras pinta obs"
  fi
  echo

  # The most consequential choice: an image for distribution or a VM for personal use.
  info "Two possible uses:" "Dos usos posibles:"
  info "  · distribution image → renames the user to '$DIST_NEW_USER', removes" "  · imagen para repartir  → renombra el usuario a '$DIST_NEW_USER', borra"
  info "    SSH keys and identity, and creates a ~6.5 GB ZIP (~30 min extra)" "    claves SSH e identidad, y genera un zip de ~6,5 GB (~30 min extra)"
  info "  · personal VM        → remains as-is with user '$VM_USER'" "  · VM para ti            → se queda como esta, con el usuario '$VM_USER'"
  if confirm "$(ui_text 'Prepare the image for distribution?' 'Preparar la imagen para repartir?')" no; then
    HACER_DIST=si
    ask DIST_NEW_USER "$(ui_text 'Distribution image user' 'Usuario de la imagen distribuible')" "$DIST_NEW_USER"
  else
    HACER_DIST=no
    ask VM_USER     "$(ui_text 'VM user' 'Usuario de la VM')"      "$VM_USER"
    ask VM_PASSWORD "$(ui_text 'Password' 'Contrasena')"           "$VM_PASSWORD"
    ask VM_FULLNAME "$(ui_text 'Full name' 'Nombre completo')"     "$VM_FULLNAME"
  fi
  echo
  info "summary: $VM_KEYMAP/$VM_XKB · $VM_TIMEZONE · ${UTM_CPUS} cores · ${UTM_MEM} MiB · disk $DISK_SIZE" "resumen: $VM_KEYMAP/$VM_XKB · $VM_TIMEZONE · ${UTM_CPUS} nucleos · ${UTM_MEM} MiB · disco $DISK_SIZE"
  info "         tools: $HACER_TOOLS · OBS+Pinta: $INCLUDE_LIBRE_APPS · distribution: $HACER_DIST" "         herramientas: $HACER_TOOLS · OBS+Pinta: $INCLUDE_LIBRE_APPS · repartir: $HACER_DIST"
  confirm "$(ui_text 'Start?' 'Empezar?')" si || die "cancelled" "cancelado"
  guardar_respuestas
}

# ──────────────────────────────────── main ─────────────────────────────────
# Print the full header regardless of length. A fixed '2,30p' range made --help
# lose the phase list as soon as the banner grew.
usage() {
  if [[ $OMARCHY_LANG == es ]]; then
    cat <<'EOF'
Construye de forma autonoma una maquina virtual UTM con Arch Linux ARM,
Hyprland y la configuracion de Omarchy 4, y permite empaquetarla para distribuir.

Uso:
  ./build-omarchy-arm.sh                  todas las fases
  ./build-omarchy-arm.sh --from build     reanudar desde una fase
  ./build-omarchy-arm.sh --only package   ejecutar solo una fase
  ./build-omarchy-arm.sh --list           listar las fases
  OMARCHY_LANG=es ./build-omarchy-arm.sh  forzar espanol (en|es|auto)

Fases: deps, fetch, prepare, build, utm, verify, sanitize, package

Requisitos: macOS en Apple Silicon, Homebrew, UTM 4.7+, Command Line Tools
(git, python3) y unos 40 GB libres. No requiere sudo.
EOF
  else
    cat <<'EOF'
Autonomously build a UTM virtual machine with Arch Linux ARM, Hyprland, and
the Omarchy 4 configuration, with optional packaging for distribution.

Usage:
  ./build-omarchy-arm.sh                  all phases
  ./build-omarchy-arm.sh --from build     resume from a phase
  ./build-omarchy-arm.sh --only package   run only one phase
  ./build-omarchy-arm.sh --list           list phases
  OMARCHY_LANG=es ./build-omarchy-arm.sh  force Spanish (en|es|auto)

Phases: deps, fetch, prepare, build, utm, verify, sanitize, package

Requirements: macOS on Apple Silicon, Homebrew, UTM 4.7+, Command Line Tools
(git, python3), and about 40 GB free. No sudo required.
EOF
  fi
}

run_from=""; run_only=""
while (($#)); do
  case "$1" in
    # Use ${2:-}, not $2: with `set -u`, a missing argument otherwise aborts
    # with "unbound variable" and a line number instead of the useful message below.
    --from) run_from="${2:-}"; [[ -n $run_from ]] || { usage; die "--from requires a phase (${PHASES[*]})" "--from necesita una fase (${PHASES[*]})"; }; shift 2 ;;
    --only) run_only="${2:-}"; [[ -n $run_only ]] || { usage; die "--only requires a phase (${PHASES[*]})" "--only necesita una fase (${PHASES[*]})"; }; shift 2 ;;
    --list) printf '%s\n' "${PHASES[@]}"; exit 0 ;;
    --print-language) printf '%s\n' "$OMARCHY_LANG"; exit 0 ;;
    --print-libre-apps) cargar_respuestas; printf '%s\n' "$INCLUDE_LIBRE_APPS"; exit 0 ;;
    --check-core-source-lock) ensure_dirs; write_core_source_lock; write_free_app_artifact_lock; write_optional_app_artifact_lock; validate_core_source_lock "$W/provision/core-git-sources.tsv"; validate_free_app_artifact_lock "$W/provision/free-app-artifacts.tsv"; validate_optional_app_artifact_lock "$W/provision/optional-app-artifacts.tsv"; ok "reviewed source locks are valid" "los bloqueos de fuentes revisadas son validos"; exit 0 ;;
    --yes|-y|--sin-preguntas) ASSUME_YES=1; INTERACTIVO=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" "opcion desconocida: $1" ;;
  esac
done

# The build username ends up in a sanitizer `find ... -regex` and throughout
# guest paths. A strange or very short name turns that sweep into a shotgun, so
# require a valid username that is not a substring of the distributable user.
[[ $VM_USER =~ ^[a-z_][a-z0-9_-]{2,31}$ ]] \
  || die "VM_USER='$VM_USER' is invalid: use 3-32 lowercase letters, digits, '-' or '_', starting with a letter" "VM_USER='$VM_USER' no vale: minusculas, digitos, '-' y '_', empezando por letra, 3-32 caracteres"
[[ $DIST_NEW_USER == *"$VM_USER"* ]] \
  && die "VM_USER='$VM_USER' is part of DIST_NEW_USER='$DIST_NEW_USER'; choose another" "VM_USER='$VM_USER' es parte de DIST_NEW_USER='$DIST_NEW_USER'; elige otro"

# Combining the two does nothing: if the --only phase comes BEFORE the
# --from phase in the array, the loop never sets started=1 and the script
# would finish announcing "Completed in 0 min." with rc=0 without doing anything
# at all. They are mutually exclusive, so we state it and move on.
[[ -n $run_from && -n $run_only ]] && die "--from and --only are mutually exclusive; choose one" "--from y --only son excluyentes: elige uno"

# A misspelled phase name must not exit successfully without doing anything.
for sel in "$run_from" "$run_only"; do
  [[ -z $sel ]] && continue
  printf '%s\n' "${PHASES[@]}" | grep -qxF "$sel" \
    || die "unknown phase: '$sel' (valid: ${PHASES[*]})" "fase desconocida: '$sel' (validas: ${PHASES[*]})"
done

# Resuming or running a single phase must not reopen the questionnaire, but it MUST
# retrieve what was answered the previous time.
if [[ -z $run_from && -z $run_only ]]; then
  cargar_respuestas          # previous answers appear as defaults
  cuestionario
else
  cargar_respuestas || true
  if [[ -f "$W/respuestas.env" ]]; then
    info "resuming with answers from $W/respuestas.env (user '$VM_USER', distribution: ${HACER_DIST:-no})" "reanudando con las respuestas de $W/respuestas.env (usuario '$VM_USER', repartir: ${HACER_DIST:-no})"
  else
    warn "$W/respuestas.env does not exist: defaults will be used and may differ from your previous choices" "no hay $W/respuestas.env: se usaran los valores por defecto, que pueden no ser los que elegiste"
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
  "ph_$p" || die "phase '$p' failed" "fallo en la fase '$p'"
done
echo
echo "${c_ok}$(ui_text "Completed in $(( (SECONDS-t0)/60 )) min." "Completado en $(( (SECONDS-t0)/60 )) min.")${c_off}"
