#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TOOL="$ROOT/provision/src/alarm-repository-snapshot.py"
BUILDER="$ROOT/build-omarchy-arm.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/omarchy-alarm-snapshot.XXXXXX")
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

add_database_record() {
  local source="$1" package="$2" version="$3" architecture="$4" hash="$5" signature="$6"
  mkdir -p "$source/$package-$version"
  printf '%%NAME%%\n%s\n\n%%VERSION%%\n%s\n\n%%ARCH%%\n%s\n\n%%FILENAME%%\n%s-%s-%s.pkg.tar.xz\n\n%%SHA256SUM%%\n%s\n\n%%PGPSIG%%\n%s\n' \
    "$package" "$version" "$architecture" "$package" "$version" "$architecture" "$hash" "$signature" \
    > "$source/$package-$version/desc"
}

SNAPSHOT="$TMP/snapshot"
PACKAGE_CACHE="$TMP/cache"
mkdir -p "$SNAPSHOT" "$PACKAGE_CACHE" "$TMP/package-source-verified" "$TMP/package-source-collision"
SIGNATURE=YWJjZA==
printf 'verified mtree bytes\n' > "$TMP/package-source-verified/.MTREE"
tar -cJf "$PACKAGE_CACHE/verified-package-2:1.0-3-aarch64.pkg.tar.xz" \
  -C "$TMP/package-source-verified" .MTREE
VERIFIED_HASH=$(shasum -a 256 "$PACKAGE_CACHE/verified-package-2:1.0-3-aarch64.pkg.tar.xz" | awk '{ print $1 }')
printf 'reviewed collision mtree bytes\n' > "$TMP/package-source-collision/.MTREE"
tar -cJf "$PACKAGE_CACHE/collision-package-1.0-1-aarch64.pkg.tar.xz" \
  -C "$TMP/package-source-collision" .MTREE
COLLISION_HASH=$(shasum -a 256 "$PACKAGE_CACHE/collision-package-1.0-1-aarch64.pkg.tar.xz" | awk '{ print $1 }')

for repository in core extra alarm aur; do mkdir -p "$TMP/db-source-$repository"; done
add_database_record "$TMP/db-source-core" verified-package '2:1.0-3' aarch64 "$VERIFIED_HASH" "$SIGNATURE"
add_database_record "$TMP/db-source-core" arch-package 1.0-1 aarch64 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa "$SIGNATURE"
add_database_record "$TMP/db-source-extra" shared-package 1.0-1 aarch64 bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb "$SIGNATURE"
add_database_record "$TMP/db-source-alarm" shared-package 1.0-1 aarch64 cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc "$SIGNATURE"
add_database_record "$TMP/db-source-aur" collision-package 1.0-1 aarch64 "$COLLISION_HASH" "$SIGNATURE"
for repository in core extra alarm aur; do
  tar -czf "$SNAPSHOT/$repository.db" -C "$TMP/db-source-$repository" .
done

python3 "$TOOL" write-manifest "$SNAPSHOT" "$SNAPSHOT/manifest.tsv" \
  https://primary.example https://secondary.example 1234 2026-08-28T12:00:00Z
python3 "$TOOL" validate "$SNAPSHOT" "$SNAPSHOT/manifest.tsv"

LOCAL_DB="$TMP/local"
for package_record in verified-package-2:1.0-3 shared-package-1.0-1 \
                      collision-package-1.0-1 arch-package-1.0-1 local-package-4.0-1; do
  mkdir -p "$LOCAL_DB/$package_record"
done
printf '%%NAME%%\nverified-package\n\n%%VERSION%%\n2:1.0-3\n\n%%ARCH%%\naarch64\n' > "$LOCAL_DB/verified-package-2:1.0-3/desc"
cp "$TMP/package-source-verified/.MTREE" "$LOCAL_DB/verified-package-2:1.0-3/mtree"
printf '%%NAME%%\nshared-package\n\n%%VERSION%%\n1.0-1\n\n%%ARCH%%\naarch64\n' > "$LOCAL_DB/shared-package-1.0-1/desc"
printf '%%NAME%%\ncollision-package\n\n%%VERSION%%\n1.0-1\n\n%%ARCH%%\naarch64\n' > "$LOCAL_DB/collision-package-1.0-1/desc"
printf 'locally built mtree bytes\n' > "$LOCAL_DB/collision-package-1.0-1/mtree"
printf '%%NAME%%\narch-package\n\n%%VERSION%%\n1.0-1\n\n%%ARCH%%\nx86_64\n' > "$LOCAL_DB/arch-package-1.0-1/desc"
printf '%%NAME%%\nlocal-package\n\n%%VERSION%%\n4.0-1\n\n%%ARCH%%\naarch64\n' > "$LOCAL_DB/local-package-4.0-1/desc"
python3 "$TOOL" provenance "$SNAPSHOT" "$SNAPSHOT/manifest.tsv" "$TMP/provenance.tsv" \
  --local-db "$LOCAL_DB" --cache-dir "$PACKAGE_CACHE"
python3 "$TOOL" validate-provenance "$SNAPSHOT" "$SNAPSHOT/manifest.tsv" \
  "$TMP/provenance.tsv" --local-db "$LOCAL_DB"
awk -F '\t' -v hash="$VERIFIED_HASH" '$2 == "repository-cache+mtree" && $3 == "core" && $4 == "verified-package" && $5 == "2:1.0-3" && $8 == hash && $10 ~ /^[0-9a-f]{64}$/ { found=1 } END { exit !found }' "$TMP/provenance.tsv"
awk -F '\t' '$2 == "ambiguous-snapshot-match" && $3 == "extra,alarm" && $4 == "shared-package" { found=1 } END { exit !found }' "$TMP/provenance.tsv"
awk -F '\t' '$2 == "snapshot-metadata-only" && $3 == "aur" && $4 == "collision-package" && $10 == "-" { found=1 } END { exit !found }' "$TMP/provenance.tsv"
awk -F '\t' '$2 == "local-or-unknown" && $3 == "-" && ($4 == "local-package" || $4 == "arch-package") { found++ } END { exit found != 2 }' "$TMP/provenance.tsv"

sed '$d' "$TMP/provenance.tsv" > "$TMP/truncated-provenance.tsv"
if python3 "$TOOL" validate-provenance "$SNAPSHOT" "$SNAPSHOT/manifest.tsv" \
    "$TMP/truncated-provenance.tsv" --local-db "$LOCAL_DB" >"$TMP/truncated.out" 2>&1; then
  echo "truncated installed-package provenance was accepted" >&2; exit 1
fi
grep -q 'provenance is incomplete' "$TMP/truncated.out"
{ cat "$TMP/provenance.tsv"; tail -n 1 "$TMP/provenance.tsv"; } > "$TMP/duplicate-provenance.tsv"
if python3 "$TOOL" validate-provenance "$SNAPSHOT" "$SNAPSHOT/manifest.tsv" \
    "$TMP/duplicate-provenance.tsv" --local-db "$LOCAL_DB" >"$TMP/duplicate.out" 2>&1; then
  echo "duplicate installed-package provenance row was accepted" >&2; exit 1
fi
grep -q 'duplicate provenance row' "$TMP/duplicate.out"
sed '2s/^[0-9a-f]*/ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff/' \
  "$TMP/provenance.tsv" > "$TMP/wrong-snapshot-provenance.tsv"
if python3 "$TOOL" validate-provenance "$SNAPSHOT" "$SNAPSHOT/manifest.tsv" \
    "$TMP/wrong-snapshot-provenance.tsv" --local-db "$LOCAL_DB" >"$TMP/wrong-snapshot.out" 2>&1; then
  echo "wrong provenance snapshot ID was accepted" >&2; exit 1
fi
grep -q 'wrong snapshot' "$TMP/wrong-snapshot.out"

cp "$SNAPSHOT/core.db" "$TMP/core.db.good"
printf 'tampered\n' >> "$SNAPSHOT/core.db"
if python3 "$TOOL" validate "$SNAPSHOT" "$SNAPSHOT/manifest.tsv" >"$TMP/tampered.out" 2>&1; then
  echo "tampered repository database was accepted" >&2; exit 1
fi
grep -q 'does not match the snapshot manifest' "$TMP/tampered.out"
mv "$TMP/core.db.good" "$SNAPSHOT/core.db"

cp "$SNAPSHOT/manifest.tsv" "$TMP/manifest.good"
sed '/^repo.*aur/d' "$TMP/manifest.good" > "$SNAPSHOT/manifest.tsv"
if python3 "$TOOL" validate "$SNAPSHOT" "$SNAPSHOT/manifest.tsv" >"$TMP/missing.out" 2>&1; then
  echo "snapshot with a missing repository was accepted" >&2; exit 1
fi
grep -q 'snapshot repositories do not match' "$TMP/missing.out"
cp "$TMP/manifest.good" "$SNAPSHOT/manifest.tsv"
cp "$SNAPSHOT/core.db" "$SNAPSHOT/unexpected.db"
if python3 "$TOOL" validate "$SNAPSHOT" "$SNAPSHOT/manifest.tsv" >"$TMP/extra.out" 2>&1; then
  echo "snapshot with an extra database was accepted" >&2; exit 1
fi
grep -q 'database files do not match' "$TMP/extra.out"
rm "$SNAPSHOT/unexpected.db"

mkdir -p "$TMP/bin" "$TMP/mock-state" "$TMP/work/provision"
cat > "$TMP/bin/curl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
url="" output=""
while (($#)); do
  case "$1" in
    -o) output="$2"; shift 2 ;;
    --max-time) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
mirror=primary
[[ $url == *secondary* ]] && mirror=secondary
if [[ $url == */sync ]]; then
  count_file="$MOCK_STATE/$mirror-sync-count"
  count=0
  [[ ! -f $count_file ]] || count=$(cat "$count_file")
  count=$((count + 1))
  printf '%s\n' "$count" > "$count_file"
  if [[ ${MOCK_MODE:-ok} == drift && $mirror == primary && $count -gt 1 ]]; then
    printf '5678\n'
  else
    printf '1234\n'
  fi
  exit 0
fi
repository=${url%/*}; repository=${repository##*/}
source="$MOCK_FIXTURE/$repository.db"
if [[ ${MOCK_MODE:-ok} == mismatch && $mirror == secondary && $repository == extra ]]; then
  printf 'different database bytes\n' > "$output"
else
  cp "$source" "$output"
fi
MOCK
chmod +x "$TMP/bin/curl"

awk '/^ALARM_REPOSITORIES=/{copying=1} /^# ─.*phase: prepare/{copying=0} copying{print}' \
  "$BUILDER" > "$TMP/capture-functions.sh"
cp "$TOOL" "$TMP/work/provision/alarm-repository-snapshot.py"
chmod +x "$TMP/work/provision/alarm-repository-snapshot.py"
cat > "$TMP/run-capture.sh" <<'HARNESS'
#!/usr/bin/env bash
set -euo pipefail
W=$TEST_WORK
ALARM_MIRROR_PRIMARY=https://primary.example
ALARM_MIRROR_SECONDARY=https://secondary.example
ui_text() { printf '%s' "$1"; }
info() { :; }
ok() { :; }
validate_fetch_url() { [[ $1 == https://* ]]; }
die() { printf '%s\n' "$1" >&2; exit 1; }
. "$CAPTURE_FUNCTIONS"
capture_alarm_repository_snapshot
HARNESS
chmod +x "$TMP/run-capture.sh"

MOCK_STATE="$TMP/mock-state" MOCK_FIXTURE="$SNAPSHOT" TEST_WORK="$TMP/work" \
  CAPTURE_FUNCTIONS="$TMP/capture-functions.sh" PATH="$TMP/bin:$PATH" \
  bash "$TMP/run-capture.sh"
python3 "$TOOL" validate "$TMP/work/provision/alarm-repositories" \
  "$TMP/work/provision/alarm-repositories/manifest.tsv"
original_manifest=$(shasum -a 256 "$TMP/work/provision/alarm-repositories/manifest.tsv" | awk '{ print $1 }')

rm -rf "$TMP/mock-state"; mkdir "$TMP/mock-state"
if MOCK_MODE=mismatch MOCK_STATE="$TMP/mock-state" MOCK_FIXTURE="$SNAPSHOT" TEST_WORK="$TMP/work" \
    CAPTURE_FUNCTIONS="$TMP/capture-functions.sh" PATH="$TMP/bin:$PATH" \
    bash "$TMP/run-capture.sh" >"$TMP/mismatch.out" 2>&1; then
  echo "different official-mirror database bytes were accepted" >&2; exit 1
fi
[[ $(shasum -a 256 "$TMP/work/provision/alarm-repositories/manifest.tsv" | awk '{ print $1 }') == "$original_manifest" ]]

rm -rf "$TMP/mock-state"; mkdir "$TMP/mock-state"
if MOCK_MODE=drift MOCK_STATE="$TMP/mock-state" MOCK_FIXTURE="$SNAPSHOT" TEST_WORK="$TMP/work" \
    CAPTURE_FUNCTIONS="$TMP/capture-functions.sh" PATH="$TMP/bin:$PATH" \
    bash "$TMP/run-capture.sh" >"$TMP/drift.out" 2>&1; then
  echo "repository sync-marker drift was accepted" >&2; exit 1
fi
[[ $(shasum -a 256 "$TMP/work/provision/alarm-repositories/manifest.tsv" | awk '{ print $1 }') == "$original_manifest" ]]

if W="$TMP/missing-work" ASSUME_YES=1 "$BUILDER" --only build >"$TMP/missing-build.out" 2>&1; then
  echo "build without a prepared repository snapshot did not fail" >&2; exit 1
fi
grep -q 'repository snapshot is missing; run prepare' "$TMP/missing-build.out"

! rg -n 'pacman[[:space:]]+-S(y|yu)([[:space:]]|$)' "$ROOT/provision/src/stage2.sh"
rg -q 'pacman -Su --noconfirm' "$ROOT/provision/src/stage2.sh"
rg -q 'cp -R.*alarm-repositories' "$ROOT/provision/src/stage1.sh" "$ROOT/build-omarchy-arm.sh"
rg -q 'alarm-package-provenance\.tsv' "$ROOT/provision/src/stage2.sh" "$ROOT/build-omarchy-arm.sh"
python3 "$ROOT/scripts/sync-payloads.py" --check >/dev/null

echo "Arch Linux ARM repository snapshot tests: pass"
