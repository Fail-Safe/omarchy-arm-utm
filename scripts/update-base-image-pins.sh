#!/usr/bin/env bash
# Verify current base images and optionally update their reviewed SHA-256 pins.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WRITE=0
CACHE=""
: "${OMARCHY_LANG:=$(bash "$ROOT/build-omarchy-arm.sh" --print-language)}"
ui_text() { if [[ $OMARCHY_LANG == es ]]; then printf '%s' "${2:-$1}"; else printf '%s' "$1"; fi; }

usage() {
  if [[ $OMARCHY_LANG == es ]]; then cat <<'EOF'
Uso: scripts/update-base-image-pins.sh [--write] [--cache DIR]

Descarga y verifica la ISO actual de Alpine y el rootfs de Arch Linux ARM.
Sin --write solo muestra los hashes propuestos. --cache reutiliza descargas
verificadas en DIR; hacen falta unos 1,7 GB para las dos copias independientes.
EOF
  else cat <<'EOF'
Usage: scripts/update-base-image-pins.sh [--write] [--cache DIR]

Downloads and verifies the current Alpine ISO and Arch Linux ARM rootfs.
Without --write it only prints the proposed pins. --cache reuses verified
downloads in DIR; expect roughly 1.7 GB for the two independent rootfs copies.
EOF
  fi
}

while (($#)); do
  case "$1" in
    --write) WRITE=1; shift ;;
    --cache) CACHE="${2:-}"; [[ -n $CACHE ]] || { usage >&2; exit 2; }; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "$(ui_text "unknown option: $1" "opcion desconocida: $1")" >&2; usage >&2; exit 2 ;;
  esac
done

for command_name in curl gpg shasum cmp python3; do
  command -v "$command_name" >/dev/null || { echo "$(ui_text "missing command: $command_name" "falta el comando: $command_name")" >&2; exit 1; }
done

if [[ -n $CACHE ]]; then
  mkdir -p "$CACHE"
  WORK=$(cd "$CACHE" && pwd)
  CLEAN_WORK=0
else
  WORK=$(mktemp -d "${TMPDIR:-/tmp}/omarchy-base-pins.XXXXXX")
  CLEAN_WORK=1
fi
cleanup() {
  if [[ $CLEAN_WORK -eq 1 && -n ${WORK:-} && -d $WORK ]]; then
    rm -rf "$WORK"
  fi
}
trap cleanup EXIT

ALARM_NAME=ArchLinuxARM-aarch64-latest.tar.gz
ALARM_SECONDARY_NAME=ArchLinuxARM-aarch64-latest.fl.tar.gz
ALARM_PRIMARY=https://ca.us.mirror.archlinuxarm.org/os/$ALARM_NAME
ALARM_SECONDARY=https://fl.us.mirror.archlinuxarm.org/os/$ALARM_NAME
ALARM_SIGNER=68B3537F39A313B3E574D06777193F152BDBE6A6
KEYRING_COMMIT=91e6b11698f8df66042d56aaa56fbe9c9263847d
KEY_URL=https://raw.githubusercontent.com/archlinuxarm/archlinuxarm-keyring/$KEYRING_COMMIT/packager/builder.asc
KEY_SHA256=26196ae6d6efbb1138be6805245d577adbcd94b887eaf0569f88efe003e6b3d9
ALPINE_BASE=https://dl-cdn.alpinelinux.org/alpine/v3.24/releases/aarch64

download() {
  local url="$1" dest="$2"
  [[ -s $dest ]] && return 0
  curl -fL --retry 3 --connect-timeout 20 -o "$dest.partial" "$url"
  mv "$dest.partial" "$dest"
}

sha256_file() { shasum -a 256 "$1" | awk '{print $1}'; }
require_sha256() {
  local file="$1" expected="$2" got
  got=$(sha256_file "$file")
  [[ $got == "$expected" ]] || {
    echo "$(ui_text "SHA-256 mismatch for $file: expected $expected, got $got" "SHA-256 incorrecto para $file: se esperaba $expected, se obtuvo $got")" >&2
    exit 1
  }
}

echo "==> $(ui_text 'Arch Linux ARM: two official HTTPS mirrors' 'Arch Linux ARM: dos mirrors HTTPS oficiales')"
download "$ALARM_PRIMARY" "$WORK/$ALARM_NAME"
download "$ALARM_SECONDARY" "$WORK/$ALARM_SECONDARY_NAME"
cmp "$WORK/$ALARM_NAME" "$WORK/$ALARM_SECONDARY_NAME" \
  || { echo "$(ui_text 'official mirrors returned different rootfs bytes' 'los mirrors oficiales devolvieron rootfs diferentes')" >&2; exit 1; }
download "$ALARM_PRIMARY.sig" "$WORK/$ALARM_NAME.sig"
download "$KEY_URL" "$WORK/archlinuxarm-builder.asc"
require_sha256 "$WORK/archlinuxarm-builder.asc" "$KEY_SHA256"

GNUPGHOME="$WORK/gnupg"
export GNUPGHOME
mkdir -p "$GNUPGHOME"
chmod 700 "$GNUPGHOME"
gpg --batch --quiet --import "$WORK/archlinuxarm-builder.asc"
status=$(gpg --batch --status-fd 1 --verify "$WORK/$ALARM_NAME.sig" "$WORK/$ALARM_NAME" 2>/dev/null) \
  || { echo "$(ui_text 'Arch Linux ARM signature verification failed' 'fallo la verificacion de la firma de Arch Linux ARM')" >&2; exit 1; }
printf '%s\n' "$status" | grep -F "VALIDSIG $ALARM_SIGNER " >/dev/null \
  || { echo "$(ui_text 'unexpected Arch Linux ARM signing fingerprint' 'huella de firma inesperada para Arch Linux ARM')" >&2; exit 1; }
alarm_sha=$(sha256_file "$WORK/$ALARM_NAME")

echo "==> $(ui_text 'Alpine: HTTPS checksum' 'Alpine: checksum por HTTPS')"
index=$(curl -fsSL --max-time 30 "$ALPINE_BASE/")
alpine_name=$(printf '%s' "$index" \
  | grep -oE 'alpine-virt-[0-9.]+-aarch64\.iso' | sort -V | tail -1 || true)
[[ -n $alpine_name ]] || { echo "$(ui_text 'could not resolve the current Alpine virt ISO' 'no se pudo determinar la ISO virt actual de Alpine')" >&2; exit 1; }
alpine_sha=$(curl -fsSL --max-time 30 "$ALPINE_BASE/$alpine_name.sha256" | awk '{print $1}')
[[ $alpine_sha =~ ^[0-9a-fA-F]{64}$ ]] \
  || { echo "$(ui_text 'Alpine did not publish a valid SHA-256' 'Alpine no publico un SHA-256 valido')" >&2; exit 1; }
download "$ALPINE_BASE/$alpine_name" "$WORK/$alpine_name"
require_sha256 "$WORK/$alpine_name" "$alpine_sha"

manifest="$WORK/base-images.sha256.new"
printf '%s  %s\n%s  %s\n' \
  "$alpine_sha" "$alpine_name" "$alarm_sha" "$ALARM_NAME" > "$manifest"

echo
echo "$(ui_text 'Verified pins:' 'Hashes verificados:')"
sed 's/^/  /' "$manifest"

if [[ $WRITE -eq 1 ]]; then
  python3 - "$ROOT/build-omarchy-arm.sh" "$alpine_name" "$alpine_sha" "$alarm_sha" "$OMARCHY_LANG" <<'PY'
import pathlib, sys

path = pathlib.Path(sys.argv[1])
alpine_name, alpine_sha, alarm_sha, language = sys.argv[2:]
replacements = {
    ': "${ALPINE_ISO:=': f': "${{ALPINE_ISO:={alpine_name}}}"',
    ': "${ALPINE_SHA256:=': f': "${{ALPINE_SHA256:={alpine_sha}}}"',
    ': "${ALARM_SHA256:=': f': "${{ALARM_SHA256:={alarm_sha}}}"',
}
lines = path.read_text().splitlines()
seen = {prefix: 0 for prefix in replacements}
for index, line in enumerate(lines):
    for prefix, replacement in replacements.items():
        if line.startswith(prefix):
            lines[index] = replacement
            seen[prefix] += 1
for prefix, count in seen.items():
    if count != 1:
        if language == "es":
            raise SystemExit(f"se esperaba una asignacion del builder que empezara por {prefix!r}; se encontraron {count}")
        raise SystemExit(f"expected one builder assignment starting with {prefix!r}; found {count}")
path.write_text("\n".join(lines) + "\n")
PY
  cp "$manifest" "$ROOT/checksums/base-images.sha256.new"
  mv "$ROOT/checksums/base-images.sha256.new" "$ROOT/checksums/base-images.sha256"
  echo "$(ui_text 'Updated build-omarchy-arm.sh and checksums/base-images.sha256' 'Actualizados build-omarchy-arm.sh y checksums/base-images.sha256')"
else
  echo "$(ui_text 'Dry run only; pass --write after reviewing these pins.' 'Solo simulacion; usa --write despues de revisar estos hashes.')"
fi
