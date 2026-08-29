#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
EXTRAS="$ROOT/provision/src/omarchy-arm-extras"
CORE_LOCK="$ROOT/checksums/core-git-sources.tsv"
ARTIFACT_LOCK="$ROOT/checksums/optional-app-artifacts.tsv"
REPAIR_DIR="$ROOT/provision/repair-iso"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/omarchy-optional-app-pins.XXXXXX")
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

cmp "$EXTRAS" "$REPAIR_DIR/extras.sh"
cmp "$ARTIFACT_LOCK" "$REPAIR_DIR/optional-app-artifacts.tsv"
rg -q 'optional-app-artifacts\.tsv' "$ROOT/provision/src/stage1.sh" \
  "$ROOT/provision/src/stage2.sh" "$REPAIR_DIR/repair.sh" "$REPAIR_DIR/sanitize.sh"
rg -q 'checksums/optional-app-artifacts\.tsv' "$ROOT/scripts/run-build.sh"

for key in 1password-cli typora localsend-bin google-chrome; do
  [[ $(awk -v key="$key" '$1 == key { count++ } END { print count + 0 }' "$CORE_LOCK") == 1 ]]
done
[[ $(awk '$1 == "1password-cli" { print $2 }' "$CORE_LOCK") == https://aur.archlinux.org/1password-cli.git ]]
[[ $(awk '$1 == "typora" { print $2 }' "$CORE_LOCK") == https://aur.archlinux.org/typora.git ]]
[[ $(awk '$1 == "localsend-bin" { print $2 }' "$CORE_LOCK") == https://aur.archlinux.org/localsend-bin.git ]]
[[ $(awk '$1 == "google-chrome" { print $2 }' "$CORE_LOCK") == https://aur.archlinux.org/google-chrome.git ]]

read -r onepassword_key onepassword_url onepassword_digest onepassword_signer onepassword_extra < <(
  awk '$1 == "1password-package" { print; exit }' "$ARTIFACT_LOCK"
)
[[ -z ${onepassword_extra:-} && $onepassword_key == 1password-package ]]
[[ $onepassword_url =~ ^https://downloads\.1password\.com/linux/tar/stable/aarch64/1password-[0-9]+\.[0-9]+\.[0-9]+\.arm64\.tar\.gz$ ]]
[[ $onepassword_digest =~ ^[0-9a-f]{64}$ ]]
[[ $onepassword_signer == 3FEF9748469ADBE15DA7CA80AC2D62742012EA22 ]]

read -r obsidian_key obsidian_url obsidian_digest obsidian_signer obsidian_extra < <(
  awk '$1 == "obsidian-package" { print; exit }' "$ARTIFACT_LOCK"
)
[[ -z ${obsidian_extra:-} && $obsidian_key == obsidian-package ]]
[[ $obsidian_url =~ ^https://github\.com/obsidianmd/obsidian-releases/releases/download/v[0-9]+\.[0-9]+\.[0-9]+/obsidian-[0-9]+\.[0-9]+\.[0-9]+-arm64\.tar\.gz$ ]]
[[ $obsidian_digest =~ ^[0-9a-f]{64}$ && $obsidian_signer == - ]]

awk '
  /REVIEWED_FREE_APP_HELPERS_BEGIN/ { copying = 1; next }
  /REVIEWED_FREE_APP_HELPERS_END/ { exit }
  copying { print }
' "$EXTRAS" > "$TMP/helpers.sh"
# shellcheck disable=SC1090 # Deliberately exercising extracted guest helpers.
. "$TMP/helpers.sh"
ui_text() { printf '%s' "$1"; }
fail() { printf '%s\n' "$1" >&2; }
# shellcheck disable=SC2034 # Consumed by the sourced helper functions.
CORE_SOURCE_LOCK="$TMP/core.tsv"
# shellcheck disable=SC2034 # Consumed by the sourced helper functions.
FREE_APP_ARTIFACT_LOCK="$ROOT/checksums/free-app-artifacts.tsv"
# shellcheck disable=SC2034 # Consumed by the sourced helper functions.
OPTIONAL_APP_ARTIFACT_LOCK="$TMP/artifacts.tsv"
cp "$CORE_LOCK" "$CORE_SOURCE_LOCK"
cp "$ARTIFACT_LOCK" "$OPTIONAL_APP_ARTIFACT_LOCK"
validate_optional_app_locks 1password 1password-cli obsidian typora localsend chrome

sed 's#https://aur.archlinux.org/google-chrome.git#https://example.invalid/google-chrome.git#' \
  "$CORE_LOCK" > "$CORE_SOURCE_LOCK"
if validate_optional_app_locks chrome >"$TMP/wrong-repo.out" 2>&1; then
  echo "substituted Chrome recipe repository was accepted" >&2; exit 1
fi
grep -q 'missing or invalid reviewed source pin' "$TMP/wrong-repo.out"

cp "$CORE_LOCK" "$CORE_SOURCE_LOCK"
sed "s/$obsidian_digest/HEAD/" "$ARTIFACT_LOCK" > "$OPTIONAL_APP_ARTIFACT_LOCK"
if validate_optional_app_locks obsidian >"$TMP/bad-artifact.out" 2>&1; then
  echo "malformed Obsidian artifact digest was accepted" >&2; exit 1
fi
grep -q 'missing or invalid reviewed optional-app artifact' "$TMP/bad-artifact.out"

mkdir -p "$TMP/bin" "$TMP/gpg-work"
printf 'reviewed bytes\n' > "$TMP/archive"
printf 'signature\n' > "$TMP/signature"
printf 'key\n' > "$TMP/key"
fixture_digest=$(shasum -a 256 "$TMP/archive" | awk '{ print $1 }')
cat > "$TMP/bin/gpg" <<'MOCK'
#!/usr/bin/env bash
case " $* " in
  *' --import '*) exit 0 ;;
  *' --fingerprint '*) printf 'fpr:::::::::%s:\n' "$GPG_TEST_FPR" ;;
  *' --verify '*) printf '[GNUPG:] VALIDSIG %s 2026-08-28 0 4 0 1 10 00 OTHER\n' "$GPG_TEST_SIGNER" ;;
  *) exit 2 ;;
esac
MOCK
chmod +x "$TMP/bin/gpg"
# shellcheck disable=SC2034 # Consumed by verify_1password_artifact.
WORK="$TMP/gpg-work"
GPG_TEST_FPR="$onepassword_signer" GPG_TEST_SIGNER="$onepassword_signer" PATH="$TMP/bin:$PATH" \
  verify_1password_artifact "$TMP/archive" "$TMP/signature" "$TMP/key" "$fixture_digest" "$onepassword_signer"
if GPG_TEST_FPR=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA \
    GPG_TEST_SIGNER="$onepassword_signer" PATH="$TMP/bin:$PATH" \
    verify_1password_artifact "$TMP/archive" "$TMP/signature" "$TMP/key" "$fixture_digest" "$onepassword_signer" \
    >"$TMP/key.out" 2>&1; then
  echo "unexpected 1Password signing key was accepted" >&2; exit 1
fi
grep -q 'signing-key fingerprint mismatch' "$TMP/key.out"
if GPG_TEST_FPR="$onepassword_signer" GPG_TEST_SIGNER=BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB \
    PATH="$TMP/bin:$PATH" \
    verify_1password_artifact "$TMP/archive" "$TMP/signature" "$TMP/key" "$fixture_digest" "$onepassword_signer" \
    >"$TMP/signer.out" 2>&1; then
  echo "unexpected 1Password artifact signer was accepted" >&2; exit 1
fi
grep -q 'signer does not match' "$TMP/signer.out"

awk '
  /REVIEWED_AUR_BUILD_BEGIN/ { copying = 1; next }
  /REVIEWED_AUR_BUILD_END/ { exit }
  copying { print }
' "$EXTRAS" > "$TMP/aur-build.sh"
# shellcheck disable=SC1090 # Deliberately exercising the shared AUR helper.
. "$TMP/aur-build.sh"
ok() { :; }
info() { :; }
warn() { :; }
clone_reviewed_source() {
  printf '%s\n' "$1" >> "$TMP/clone-calls"
  mkdir -p "$2"
  printf "validpgpkeys=()\narch=('aarch64')\n" > "$2/PKGBUILD"
}
mkdir -p "$TMP/force-bin"
cat > "$TMP/force-bin/pacman" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
cat > "$TMP/force-bin/makepkg" <<MOCK
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMP/makepkg-calls"
exit 0
MOCK
chmod +x "$TMP/force-bin"/*
# shellcheck disable=SC2034 # Consumed by the sourced AUR helper.
WORK="$TMP/force-work"
FORCE=1
for row in '1password-cli 1password-cli 1password-cli' \
           'typora typora typora' \
           'localsend-bin localsend-bin localsend-bin' \
           'google-chrome google-chrome google-chrome'; do
  read -r pkg want lock_key <<< "$row"
  : > "$TMP/clone-calls"; : > "$TMP/makepkg-calls"
  if ! PATH="$TMP/force-bin:$PATH" aur_build "$pkg" "$want" "$lock_key"; then
    echo "--force did not rebuild $pkg" >&2; exit 1
  fi
  grep -qx "$lock_key" "$TMP/clone-calls"
  grep -q -- '-si --noconfirm --noprogressbar' "$TMP/makepkg-calls"
  ! grep -q -- '--needed' "$TMP/makepkg-calls"
done

# shellcheck disable=SC2034 # Consumed by the sourced AUR helper.
FORCE=0
: > "$TMP/clone-calls"; : > "$TMP/makepkg-calls"
PATH="$TMP/force-bin:$PATH" aur_build typora typora typora
test ! -s "$TMP/clone-calls"
test ! -s "$TMP/makepkg-calls"

mkdir -p "$TMP/main-bin" "$TMP/home"
cat > "$TMP/main-bin/pacman" <<'MOCK'
#!/usr/bin/env bash
exit 1
MOCK
cat > "$TMP/main-bin/sudo" <<MOCK
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMP/sudo-calls"
exit 0
MOCK
cat > "$TMP/main-bin/tar" <<MOCK
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMP/tar-calls"
exit 0
MOCK
cat > "$TMP/main-bin/makepkg" <<MOCK
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMP/makepkg-calls"
exit 0
MOCK
cat > "$TMP/main-bin/curl" <<MOCK
#!/usr/bin/env bash
set -u
out=""
url=""
while ((\$#)); do
  case "\$1" in
    -o) out="\$2"; shift 2 ;;
    -*) shift ;;
    *) url="\$1"; shift ;;
  esac
done
case "\$url" in
  *.sig) exit 22 ;;
  *1password-*.tar.gz) printf 'reviewed bytes\n' > "\$out" ;;
  *obsidian-*.tar.gz) printf 'wrong bytes\n' > "\$out" ;;
  *) exit 22 ;;
esac
MOCK
chmod +x "$TMP/main-bin"/*

cp "$ARTIFACT_LOCK" "$TMP/main-artifacts.tsv"
sed "s/$onepassword_digest/$fixture_digest/" "$ARTIFACT_LOCK" > "$TMP/onepassword-artifacts.tsv"
if CORE_SOURCE_LOCK="$CORE_LOCK" OPTIONAL_APP_ARTIFACT_LOCK="$TMP/onepassword-artifacts.tsv" \
    FREE_APP_ARTIFACT_LOCK="$ROOT/checksums/free-app-artifacts.tsv" \
    PATH="$TMP/main-bin:$PATH" HOME="$TMP/home" XDG_CACHE_HOME="$TMP/cache" OMARCHY_LANG=en \
    bash "$EXTRAS" 1password >"$TMP/missing-signature.out" 2>&1; then
  echo "missing 1Password signature returned success" >&2; exit 1
fi
grep -q 'signature download failed' "$TMP/missing-signature.out" \
  || { cat "$TMP/missing-signature.out" >&2; exit 1; }
test ! -e "$TMP/tar-calls"
[[ $(cat "$TMP/sudo-calls") == '-n true' ]]

: > "$TMP/sudo-calls"
if CORE_SOURCE_LOCK="$CORE_LOCK" OPTIONAL_APP_ARTIFACT_LOCK="$ARTIFACT_LOCK" \
    FREE_APP_ARTIFACT_LOCK="$ROOT/checksums/free-app-artifacts.tsv" \
    PATH="$TMP/main-bin:$PATH" HOME="$TMP/home" XDG_CACHE_HOME="$TMP/cache" OMARCHY_LANG=en \
    bash "$EXTRAS" obsidian >"$TMP/obsidian-digest.out" 2>&1; then
  echo "Obsidian checksum mismatch returned success" >&2; exit 1
fi
grep -q 'artifact SHA-256 mismatch' "$TMP/obsidian-digest.out"
[[ $(cat "$TMP/sudo-calls") == '-n true' ]]

: > "$TMP/sudo-calls"
sed '/^google-chrome /d' "$CORE_LOCK" > "$TMP/wrong-core.tsv"
if CORE_SOURCE_LOCK="$TMP/wrong-core.tsv" OPTIONAL_APP_ARTIFACT_LOCK="$ARTIFACT_LOCK" \
    FREE_APP_ARTIFACT_LOCK="$ROOT/checksums/free-app-artifacts.tsv" \
    PATH="$TMP/main-bin:$PATH" HOME="$TMP/home" XDG_CACHE_HOME="$TMP/cache" OMARCHY_LANG=en \
    bash "$EXTRAS" --force chrome >"$TMP/missing-pin.out" 2>&1; then
  echo "missing Chrome source pin returned success" >&2; exit 1
fi
test ! -s "$TMP/sudo-calls"

! rg -n 'aur\.archlinux\.org/rpc|git clone.*aur\.archlinux\.org|releases\?per_page|installing without signature' "$EXTRAS"
rg -q 'aur_build 1password-cli 1password-cli 1password-cli' "$EXTRAS"
rg -q 'aur_build typora typora typora' "$EXTRAS"
rg -q 'aur_build localsend-bin localsend-bin localsend-bin' "$EXTRAS"
rg -q 'aur_build google-chrome google-chrome google-chrome' "$EXTRAS"
python3 "$ROOT/scripts/sync-payloads.py" --check >/dev/null

echo "optional-app source pin tests: pass"
