#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
LOCK="$ROOT/checksums/core-git-sources.tsv"
STAGE3="$ROOT/provision/src/stage3.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/omarchy-core-pins-test.XXXXXX")
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

expected=(omarchy omarchy-pkgs ttfx yay xdg-terminal-exec yaru-icon-theme
          ttf-ia-writer tzupdate ufw-docker mise-bin aether cliamp herdr
          1password-cli typora localsend-bin google-chrome
          dotnet-runtime-bin obs-studio-pkgbuild obs-studio-source
          obs-libdshowcapture obs-browser obs-websocket)
for key in "${expected[@]}"; do
  [[ $(awk -v key="$key" '$1 == key { count++ } END { print count + 0 }' "$LOCK") == 1 ]]
done

awk '
  /^[[:space:]]*($|#)/ { next }
  NF != 4 || $1 !~ /^[a-z0-9][a-z0-9._+-]*$/ || $2 !~ /^https:\/\// ||
    $3 !~ /^(HEAD|PINNED|refs\/heads\/[A-Za-z0-9._\/-]+|refs\/tags\/[A-Za-z0-9._\/+:-]+\^\{\})$/ ||
    $4 !~ /^[0-9a-f]{40}$/ { exit 1 }
' "$LOCK"
[[ $(awk '$1 == "yaru-icon-theme" { print $2 }' "$LOCK") == https://aur.archlinux.org/yaru.git ]]

W="$TMP/work" OMARCHY_LANG=en bash "$ROOT/build-omarchy-arm.sh" --check-core-source-lock >/dev/null
cmp "$LOCK" "$TMP/work/provision/core-git-sources.tsv"

awk '
  /CORE_SOURCE_LOCK_HELPERS_BEGIN/ { copying = 1; next }
  /CORE_SOURCE_LOCK_HELPERS_END/ { exit }
  copying { print }
' "$STAGE3" > "$TMP/helpers.sh"

# shellcheck disable=SC1090 # Deliberately exercising the extracted guest helpers.
. "$TMP/helpers.sh"
ui_text() { printf '%s' "$1"; }
warn() { printf '%s\n' "$1" >&2; }
OMARCHY_REF=quattro
CORE_SOURCE_KEYS=("${expected[@]}")
SOURCE_LOCK="$TMP/lock.tsv"
cp "$LOCK" "$SOURCE_LOCK"
validate_core_source_lock

sed '/^herdr /d' "$LOCK" > "$SOURCE_LOCK"
if validate_core_source_lock >"$TMP/missing.out" 2>&1; then
  echo "missing source pin was accepted" >&2; exit 1
fi
grep -q 'missing core Git source-lock key: herdr' "$TMP/missing.out"

sed 's#^omarchy https://#omarchy http://#' "$LOCK" > "$SOURCE_LOCK"
if validate_core_source_lock >"$TMP/url.out" 2>&1; then
  echo "insecure source URL was accepted" >&2; exit 1
fi
grep -q 'invalid core Git source-lock record' "$TMP/url.out"

awk 'BEGIN { OFS=" " } $1 == "omarchy" { $4="HEAD" } { print }' "$LOCK" > "$SOURCE_LOCK"
if validate_core_source_lock >"$TMP/commit.out" 2>&1; then
  echo "moving source ref was accepted as a commit" >&2; exit 1
fi
grep -q 'invalid core Git source-lock record' "$TMP/commit.out"

git init -q --bare "$TMP/remote.git"
git init -q "$TMP/author"
git -C "$TMP/author" config user.email fixture@example.invalid
git -C "$TMP/author" config user.name Fixture
git -C "$TMP/author" config commit.gpgsign false
printf 'reviewed\n' > "$TMP/author/source.txt"
git -C "$TMP/author" add source.txt
git -C "$TMP/author" commit -qm reviewed
reviewed=$(git -C "$TMP/author" rev-parse HEAD)
git -C "$TMP/author" branch -M quattro
git -C "$TMP/author" remote add origin "$TMP/remote.git"
git -C "$TMP/author" push -q -u origin quattro
printf 'new head\n' > "$TMP/author/source.txt"
git -C "$TMP/author" commit -qam newer
newer=$(git -C "$TMP/author" rev-parse HEAD)
git -C "$TMP/author" push -q

printf 'fixture file://%s refs/heads/quattro %s\n' "$TMP/remote.git" "$reviewed" > "$SOURCE_LOCK"
clone_pinned fixture "$TMP/checkout" >/dev/null
[[ $(git -C "$TMP/checkout" rev-parse HEAD) == "$reviewed" ]]
[[ $(cat "$TMP/checkout/source.txt") == reviewed ]]
track_locked_branch fixture "$TMP/checkout"
git -C "$TMP/checkout" pull -q --ff-only
[[ $(git -C "$TMP/checkout" rev-parse HEAD) == "$newer" ]]

tree=$(git -C "$TMP/author" rev-parse HEAD^{tree})
off_branch=$(printf 'off-branch\n' | git -C "$TMP/author" commit-tree "$tree")
git -C "$TMP/author" push -q origin "$off_branch:refs/heads/unrelated"
printf 'fixture file://%s refs/heads/quattro %s\n' "$TMP/remote.git" "$off_branch" > "$SOURCE_LOCK"
clone_pinned fixture "$TMP/off-branch-checkout" >/dev/null
if track_locked_branch fixture "$TMP/off-branch-checkout" >"$TMP/off-branch.out" 2>&1; then
  echo "off-branch Omarchy-compatible pin was accepted" >&2; exit 1
fi
grep -q 'is not on refs/heads/quattro' "$TMP/off-branch.out"

! rg -n 'git clone|aur\.archlinux\.org/rpc' "$STAGE3"
rg -q 'cargo build --release --locked' "$STAGE3"
rg -q 'validate_core_source_lock \|\| exit 1' "$STAGE3"
rg -q 'core-git-sources\.tsv' "$ROOT/provision/src/stage1.sh" "$ROOT/provision/src/stage2.sh"
python3 "$ROOT/scripts/sync-payloads.py" --check >/dev/null

echo "core source pin tests: pass"
