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
