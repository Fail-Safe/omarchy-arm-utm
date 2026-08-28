#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/omarchy-libre-app-setting.XXXXXX")
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

print_setting() {
  env -u INCLUDE_LIBRE_APPS -u HACER_LIBRES \
    HOME="$TMP/home" W="$1" OMARCHY_LANG=en \
    bash "$ROOT/build-omarchy-arm.sh" --print-libre-apps
}

mkdir -p "$TMP/home"
[[ $(print_setting "$TMP/default") == yes ]]
[[ $(INCLUDE_LIBRE_APPS=yes HOME="$TMP/home" W="$TMP/canonical-yes" OMARCHY_LANG=en \
  bash "$ROOT/build-omarchy-arm.sh" --print-libre-apps) == yes ]]
[[ $(INCLUDE_LIBRE_APPS=no HOME="$TMP/home" W="$TMP/canonical-no" OMARCHY_LANG=en \
  bash "$ROOT/build-omarchy-arm.sh" --print-libre-apps) == no ]]
[[ $(HACER_LIBRES=si HOME="$TMP/home" W="$TMP/legacy-yes" OMARCHY_LANG=en \
  bash "$ROOT/build-omarchy-arm.sh" --print-libre-apps) == yes ]]
[[ $(HACER_LIBRES=no HOME="$TMP/home" W="$TMP/legacy-no" OMARCHY_LANG=en \
  bash "$ROOT/build-omarchy-arm.sh" --print-libre-apps) == no ]]
[[ $(INCLUDE_LIBRE_APPS=yes HACER_LIBRES=no HOME="$TMP/home" W="$TMP/precedence" OMARCHY_LANG=en \
  bash "$ROOT/build-omarchy-arm.sh" --print-libre-apps) == yes ]]

mkdir -p "$TMP/saved-new" "$TMP/saved-legacy" "$TMP/saved-invalid"
printf "INCLUDE_LIBRE_APPS='no'\n" > "$TMP/saved-new/respuestas.env"
printf "HACER_LIBRES='no'\n" > "$TMP/saved-legacy/respuestas.env"
printf "HACER_LIBRES='maybe'\n" > "$TMP/saved-invalid/respuestas.env"
[[ $(print_setting "$TMP/saved-new") == no ]]
[[ $(print_setting "$TMP/saved-legacy") == no ]]
[[ $(INCLUDE_LIBRE_APPS=yes HOME="$TMP/home" W="$TMP/saved-legacy" OMARCHY_LANG=en \
  bash "$ROOT/build-omarchy-arm.sh" --print-libre-apps) == yes ]]

if INCLUDE_LIBRE_APPS=si HOME="$TMP/home" W="$TMP/invalid-new" OMARCHY_LANG=en \
    bash "$ROOT/build-omarchy-arm.sh" --print-libre-apps >"$TMP/invalid-new.out" 2>&1; then
  echo "invalid canonical libre-app setting was accepted" >&2
  exit 1
fi
grep -q "invalid INCLUDE_LIBRE_APPS='si'" "$TMP/invalid-new.out"

if HACER_LIBRES=yes HOME="$TMP/home" W="$TMP/invalid-legacy" OMARCHY_LANG=en \
    bash "$ROOT/build-omarchy-arm.sh" --print-libre-apps >"$TMP/invalid-legacy.out" 2>&1; then
  echo "invalid legacy libre-app setting was accepted" >&2
  exit 1
fi
grep -q "invalid legacy HACER_LIBRES='yes'" "$TMP/invalid-legacy.out"

if print_setting "$TMP/saved-invalid" >"$TMP/saved-invalid.out" 2>&1; then
  echo "invalid saved legacy libre-app setting was accepted" >&2
  exit 1
fi
grep -q "invalid legacy HACER_LIBRES='maybe'" "$TMP/saved-invalid.out"

grep -Fq "INCLUDE_LIBRE_APPS='\$(cfgq \"\$INCLUDE_LIBRE_APPS\")'" "$ROOT/build-omarchy-arm.sh"
rg -q 'INCLUDE_LIBRE_APPS="yes"' "$ROOT/provision/src/config.env" "$ROOT/provision/repair-iso/config.env"
rg -q 'HACER_TOOLS INCLUDE_LIBRE_APPS HACER_DIST' "$ROOT/build-omarchy-arm.sh"
rg -q 'si\) INCLUDE_LIBRE_APPS=yes' "$ROOT/provision/src/stage3.sh"
rg -q 'no\) INCLUDE_LIBRE_APPS=no' "$ROOT/provision/src/stage3.sh"
grep -Fq 'echo VERD\"ICT_OK\"' "$ROOT/build-omarchy-arm.sh"
rg -q 'VERDICT_\(OK\|KO\)' "$ROOT/build-omarchy-arm.sh"
if rg -n 'VEREDICTO_(OK|KO)' "$ROOT/build-omarchy-arm.sh" "$ROOT/provision/src"; then
  echo "legacy Spanish verdict token remains in executable paths" >&2
  exit 1
fi

echo "libre-app setting tests: pass"
