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
