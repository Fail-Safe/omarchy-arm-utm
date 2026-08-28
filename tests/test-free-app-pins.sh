#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
EXTRAS="$ROOT/provision/src/omarchy-arm-extras"
CORE_LOCK="$ROOT/checksums/core-git-sources.tsv"
ARTIFACT_LOCK="$ROOT/checksums/free-app-artifacts.tsv"
REPAIR_DIR="$ROOT/provision/repair-iso"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/omarchy-free-app-pins.XXXXXX")
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

cmp "$EXTRAS" "$REPAIR_DIR/extras.sh"
cmp "$ROOT/provision/src/repair.sh" "$REPAIR_DIR/repair.sh"
cmp "$ROOT/provision/src/sanitize.sh" "$REPAIR_DIR/sanitize.sh"
cmp "$CORE_LOCK" "$REPAIR_DIR/core-git-sources.tsv"
cmp "$ARTIFACT_LOCK" "$REPAIR_DIR/free-app-artifacts.tsv"
rg -q 'core-git-sources\.tsv' "$REPAIR_DIR/repair.sh"
rg -q 'free-app-artifacts\.tsv' "$REPAIR_DIR/repair.sh"
rg -q 'install -Dm644.*usr/share/omarchy-arm' "$REPAIR_DIR/sanitize.sh"
rg -q 'pacman-key --populate archlinux archlinuxarm' "$ROOT/provision/src/stage2.sh"

read -r artifact_key artifact_url artifact_digest artifact_signer artifact_extra < <(
  awk '$1 == "pinta-package" { print; exit }' "$ARTIFACT_LOCK"
)
[[ -z ${artifact_extra:-} && $artifact_key == pinta-package ]]
[[ $artifact_url =~ ^https://geo\.mirror\.pkgbuild\.com/extra/os/x86_64/pinta-[0-9][A-Za-z0-9._+-]*-any\.pkg\.tar\.zst$ ]]
[[ $artifact_digest =~ ^[0-9a-f]{64}$ ]]
[[ $artifact_signer =~ ^[0-9A-F]{40}$ ]]

for key in dotnet-runtime-bin obs-studio-pkgbuild obs-studio-source \
           obs-libdshowcapture obs-browser obs-websocket; do
  [[ $(awk -v key="$key" '$1 == key { count++ } END { print count + 0 }' "$CORE_LOCK") == 1 ]]
done
[[ $(awk '$1 == "dotnet-runtime-bin" { print $2 }' "$CORE_LOCK") == https://aur.archlinux.org/dotnet-core-bin.git ]]

awk '
  /REVIEWED_FREE_APP_HELPERS_BEGIN/ { copying = 1; next }
  /REVIEWED_FREE_APP_HELPERS_END/ { exit }
  copying { print }
' "$EXTRAS" > "$TMP/helpers.sh"
# shellcheck disable=SC1090 # Deliberately exercising extracted guest helpers.
. "$TMP/helpers.sh"
ui_text() { printf '%s' "$1"; }
fail() { printf '%s\n' "$1" >&2; }
CORE_SOURCE_LOCK="$TMP/core.tsv"
FREE_APP_ARTIFACT_LOCK="$TMP/artifacts.tsv"
cp "$CORE_LOCK" "$CORE_SOURCE_LOCK"
cp "$ARTIFACT_LOCK" "$FREE_APP_ARTIFACT_LOCK"
validate_free_app_locks pinta obs

sed 's#https://aur.archlinux.org/dotnet-core-bin.git#https://example.invalid/dotnet.git#' \
  "$CORE_LOCK" > "$CORE_SOURCE_LOCK"
if validate_free_app_locks pinta >"$TMP/wrong-repo.out" 2>&1; then
  echo "substituted dotnet recipe repository was accepted" >&2; exit 1
fi
grep -q 'missing or invalid reviewed source pin' "$TMP/wrong-repo.out"

cp "$CORE_LOCK" "$CORE_SOURCE_LOCK"
sed 's/3f9d4977ecef3e97bf6bd1daea5e677d74d4173f3222679fc085940e7751c7ed/HEAD/' \
  "$ARTIFACT_LOCK" > "$FREE_APP_ARTIFACT_LOCK"
if validate_free_app_locks pinta >"$TMP/bad-artifact.out" 2>&1; then
  echo "malformed Pinta artifact digest was accepted" >&2; exit 1
fi
grep -q 'missing or invalid reviewed Pinta artifact' "$TMP/bad-artifact.out"

printf 'different bytes\n' > "$TMP/pinta.pkg.tar.zst"
: > "$TMP/pinta.pkg.tar.zst.sig"
if verify_reviewed_artifact "$TMP/pinta.pkg.tar.zst" "$TMP/pinta.pkg.tar.zst.sig" \
    "$artifact_digest" "$artifact_signer" >"$TMP/hash.out" 2>&1; then
  echo "Pinta checksum mismatch was accepted" >&2; exit 1
fi
grep -q 'artifact SHA-256 mismatch' "$TMP/hash.out"

mkdir -p "$TMP/bin"
actual_digest=$(shasum -a 256 "$TMP/pinta.pkg.tar.zst" | awk '{ print $1 }')
cat > "$TMP/bin/gpg" <<'MOCK'
#!/usr/bin/env bash
printf '[GNUPG:] VALIDSIG AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA 2026-08-28 0 4 0 1 10 00 BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB\n'
MOCK
chmod +x "$TMP/bin/gpg"
if PATH="$TMP/bin:$PATH" verify_reviewed_artifact "$TMP/pinta.pkg.tar.zst" \
    "$TMP/pinta.pkg.tar.zst.sig" "$actual_digest" "$artifact_signer" >"$TMP/signer.out" 2>&1; then
  echo "unexpected Pinta signer was accepted" >&2; exit 1
fi
grep -q 'artifact signer does not match' "$TMP/signer.out"

mkdir -p "$TMP/main-bin"
cat > "$TMP/main-bin/pacman" <<'MOCK'
#!/usr/bin/env bash
exit 1
MOCK
cat > "$TMP/main-bin/sudo" <<MOCK
#!/usr/bin/env bash
printf 'sudo reached\n' > "$TMP/sudo-reached"
exit 0
MOCK
chmod +x "$TMP/main-bin/pacman" "$TMP/main-bin/sudo"
if CORE_SOURCE_LOCK="$CORE_LOCK" FREE_APP_ARTIFACT_LOCK="$TMP/missing.tsv" \
    PATH="$TMP/main-bin:$PATH" HOME="$TMP/home" OMARCHY_LANG=en \
    bash "$EXTRAS" pinta >"$TMP/fail-closed.out" 2>&1; then
  echo "missing artifact lock did not fail the installer" >&2; exit 1
fi
test ! -e "$TMP/sudo-reached"
grep -q 'missing reviewed artifact lock' "$TMP/fail-closed.out"

! rg -n 'curl .*geo\.mirror\.pkgbuild\.com|sort -V.*tail -1' "$EXTRAS"
rg -q 'aur_build dotnet-runtime-bin dotnet-runtime-bin dotnet-runtime-bin' "$EXTRAS"
rg -q 'clone_reviewed_source obs-studio-pkgbuild' "$EXTRAS"
[[ $(rg -c "#commit='\"\$[a-z_]+\"'" "$EXTRAS") -ge 4 ]]
rg -q 'verify_reviewed_artifact .* \|\| return 1' "$EXTRAS"
python3 "$ROOT/scripts/sync-payloads.py" --check >/dev/null

echo "free-app source pin tests: pass"
