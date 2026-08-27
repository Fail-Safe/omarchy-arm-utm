#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/omarchy-language-test.XXXXXX")
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

mkdir -p "$TMP/bin" "$TMP/home"
cat > "$TMP/bin/defaults" <<'MOCK'
#!/usr/bin/env bash
if [[ $* == "read -g AppleLocale" ]]; then
  printf '%s\n' "${MOCK_APPLE_LOCALE:-en_US}"
else
  printf '%s\n' "${MOCK_KEYBOARD:-U.S.}"
fi
MOCK
chmod +x "$TMP/bin/defaults"

detect() {
  HOME="$TMP/home" PATH="$TMP/bin:$PATH" OMARCHY_LANG=auto \
    MOCK_APPLE_LOCALE="${1:-en_US}" MOCK_KEYBOARD="${2:-U.S.}" \
    bash "$ROOT/build-omarchy-arm.sh" --print-language
}

[[ $(detect en_US U.S.) == en ]]
[[ $(detect en_ES U.S.) == es ]]
[[ $(detect es_MX U.S.) == es ]]
[[ $(detect en_MX U.S.) == es ]]
[[ $(detect 'en_US@rg=ESzzzz' U.S.) == es ]]
[[ $(detect 'en_US@rg=MXzzzz' U.S.) == es ]]
[[ $(detect es_AR U.S.) == en ]]
[[ $(detect en_US 'Spanish - ISO') == es ]]
[[ $(detect en_US Mexican) == es ]]

[[ $(HOME="$TMP/home" PATH="$TMP/bin:$PATH" OMARCHY_LANG=en \
  MOCK_APPLE_LOCALE=es_ES bash "$ROOT/build-omarchy-arm.sh" --print-language) == en ]]
[[ $(HOME="$TMP/home" PATH="$TMP/bin:$PATH" OMARCHY_LANG=es \
  MOCK_APPLE_LOCALE=en_US bash "$ROOT/build-omarchy-arm.sh" --print-language) == es ]]

if HOME="$TMP/home" PATH="$TMP/bin:$PATH" OMARCHY_LANG=fr \
    bash "$ROOT/build-omarchy-arm.sh" --print-language >"$TMP/invalid.out" 2>&1; then
  echo "invalid OMARCHY_LANG was accepted" >&2
  exit 1
fi
grep -q "Invalid OMARCHY_LANG='fr'" "$TMP/invalid.out"

if OMARCHY_LANG=en SRC_QCOW="$TMP/missing.qcow2" \
    bash "$ROOT/scripts/make-utm.sh" >"$TMP/utm-en.out" 2>&1; then
  echo "make-utm accepted a missing source disk" >&2
  exit 1
fi
grep -q 'missing .*missing.qcow2' "$TMP/utm-en.out"

if OMARCHY_LANG=es SRC_QCOW="$TMP/missing.qcow2" \
    bash "$ROOT/scripts/make-utm.sh" >"$TMP/utm-es.out" 2>&1; then
  echo "make-utm accepted a missing source disk" >&2
  exit 1
fi
grep -q 'falta .*missing.qcow2' "$TMP/utm-es.out"

printf 'test disk\n' > "$TMP/disk.qcow2"
printf 'test vars\n' > "$TMP/vars.fd"
for language in en es; do
  OMARCHY_LANG="$language" SRC_QCOW="$TMP/disk.qcow2" VARS_TPL="$TMP/vars.fd" \
    DEST_DIR="$TMP/utm-$language" NOTES_USER=tester NOTES_PASS=secret \
    bash "$ROOT/scripts/make-utm.sh" 'Language Test' >"$TMP/utm-$language.out"
done
grep -q 'User: tester.*Password: secret' "$TMP/utm-en/Language Test.utm/config.plist"
grep -q 'The Option key.*acts as SUPER' "$TMP/utm-en/Language Test.utm/config.plist"
grep -q 'Usuario: tester.*Contraseña: secret' "$TMP/utm-es/Language Test.utm/config.plist"
grep -q 'La tecla Option.*actúa como SUPER' "$TMP/utm-es/Language Test.utm/config.plist"

OMARCHY_LANG=en bash "$ROOT/build-omarchy-arm.sh" --help > "$TMP/help-en"
OMARCHY_LANG=es bash "$ROOT/build-omarchy-arm.sh" --help > "$TMP/help-es"
grep -q '^Usage:' "$TMP/help-en"
grep -q '^Uso:' "$TMP/help-es"

for helper in omarchy-arm-extras omarchy-arm-clipboard omarchy-arm-share; do
  OMARCHY_LANG=en bash "$ROOT/provision/src/$helper" --help > "$TMP/$helper-en"
  OMARCHY_LANG=es bash "$ROOT/provision/src/$helper" --help > "$TMP/$helper-es"
  grep -q '^Usage:' "$TMP/$helper-en"
  grep -q '^Uso:' "$TMP/$helper-es"
done

cat > "$TMP/bin/git" <<'MOCK'
#!/usr/bin/env bash
case "$*" in
  *'rev-parse --is-inside-work-tree'*) exit 0 ;;
  *'rev-parse --short HEAD'*) printf '%s\n' 83881e9 ;;
  *'pull --ff-only'*) printf '%s\n' 'Already up to date.' ;;
esac
MOCK
cat > "$TMP/bin/sudo" <<'MOCK'
#!/usr/bin/env bash
exec "$@"
MOCK
chmod +x "$TMP/bin/git" "$TMP/bin/sudo"

for hook in provision/src/hooks/10-arm-sync provision/repair-iso/armsync.sh; do
  OMARCHY_LANG=en PATH="$TMP/bin:$PATH" bash "$ROOT/$hook" > "$TMP/hook-en.out"
  grep -q 'Update the Omarchy tree (Git checkout)' "$TMP/hook-en.out"
  grep -q 'already up to date (83881e9)' "$TMP/hook-en.out"
  if grep -Eq 'Actualizar|ya estaba|binarios|árbol' "$TMP/hook-en.out"; then
    echo "$hook emitted Spanish text in English mode" >&2
    exit 1
  fi

  OMARCHY_LANG=es PATH="$TMP/bin:$PATH" bash "$ROOT/$hook" > "$TMP/hook-es.out"
  grep -q 'Actualizar el árbol de Omarchy (checkout git)' "$TMP/hook-es.out"
  grep -q 'ya estaba al día (83881e9)' "$TMP/hook-es.out"
done

OMARCHY_LANG=en bash "$ROOT/scripts/update-base-image-pins.sh" --help > "$TMP/pins-en"
OMARCHY_LANG=es bash "$ROOT/scripts/update-base-image-pins.sh" --help > "$TMP/pins-es"
grep -q '^Usage:' "$TMP/pins-en"
grep -q '^Uso:' "$TMP/pins-es"

echo "language selection tests: pass"
