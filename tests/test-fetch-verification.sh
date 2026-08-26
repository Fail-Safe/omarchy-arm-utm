#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/omarchy-fetch-test.XXXXXX")
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

mkdir -p "$TMP/bin" "$TMP/source"
printf 'alpine fixture\n' > "$TMP/source/alpine.iso"
printf 'alarm fixture\n' > "$TMP/source/alarm.tar.gz"
alpine_sha=$(shasum -a 256 "$TMP/source/alpine.iso" | awk '{print $1}')
alarm_sha=$(shasum -a 256 "$TMP/source/alarm.tar.gz" | awk '{print $1}')

cat > "$TMP/bin/aria2c" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
dir=.; output=""; url=""
while (($#)); do
  case "$1" in
    -d) dir="$2"; shift 2 ;;
    -o) output="$2"; shift 2 ;;
    -x*|-s*|-c|-q|--file-allocation=none) shift ;;
    *) url="$1"; shift ;;
  esac
done
case "$url" in file://*) cp "${url#file://}" "$dir/$output" ;; *) exit 90 ;; esac
MOCK
chmod +x "$TMP/bin/aria2c"

run_fetch() {
  PATH="$TMP/bin:$PATH" W="$TMP/work" \
    ALPINE_ISO=alpine.iso ALPINE_URL="file://$TMP/source/alpine.iso" ALPINE_SHA256="$alpine_sha" \
    ALARM_URL="file://$TMP/source/alarm.tar.gz" ALARM_SHA256="$alarm_sha" \
    bash "$ROOT/build-omarchy-arm.sh" --only fetch
}

echo "==> valid downloads"
run_fetch >/dev/null
cmp "$TMP/source/alpine.iso" "$TMP/work/dl/alpine-virt-aarch64.iso"
cmp "$TMP/source/alarm.tar.gz" "$TMP/work/dl/alarm-rootfs.tgz"

echo "==> valid cached files"
run_fetch >/dev/null

echo "==> corrupted cache is rejected and retained"
printf 'corrupt\n' > "$TMP/work/dl/alarm-rootfs.tgz"
if run_fetch >"$TMP/cache.out" 2>&1; then
  echo "corrupted cache was accepted" >&2; exit 1
fi
grep -q 'en cache no supera la verificacion' "$TMP/cache.out"
grep -q '^corrupt$' "$TMP/work/dl/alarm-rootfs.tgz"

echo "==> mismatched new download is rejected and partial is removed"
rm -rf "$TMP/work"
if PATH="$TMP/bin:$PATH" W="$TMP/work" \
    ALPINE_ISO=alpine.iso ALPINE_URL="file://$TMP/source/alpine.iso" ALPINE_SHA256="$alarm_sha" \
    ALARM_URL="file://$TMP/source/alarm.tar.gz" ALARM_SHA256="$alarm_sha" \
    bash "$ROOT/build-omarchy-arm.sh" --only fetch >"$TMP/mismatch.out" 2>&1; then
  echo "mismatched download was accepted" >&2; exit 1
fi
test ! -e "$TMP/work/dl/alpine-virt-aarch64.iso.partial"
grep -q 'se rechazo la descarga' "$TMP/mismatch.out"

echo "==> missing or malformed checksum is rejected"
rm -rf "$TMP/work"
if PATH="$TMP/bin:$PATH" W="$TMP/work" \
    ALPINE_ISO=alpine.iso ALPINE_URL="file://$TMP/source/alpine.iso" ALPINE_SHA256=missing \
    ALARM_URL="file://$TMP/source/alarm.tar.gz" ALARM_SHA256="$alarm_sha" \
    bash "$ROOT/build-omarchy-arm.sh" --only fetch >"$TMP/checksum.out" 2>&1; then
  echo "missing checksum was accepted" >&2; exit 1
fi
grep -q 'sha256 no valido' "$TMP/checksum.out"

echo "==> insecure URL is rejected before download"
rm -rf "$TMP/work"
if PATH="$TMP/bin:$PATH" W="$TMP/work" \
    ALPINE_ISO=alpine.iso ALPINE_URL="http://example.invalid/alpine.iso" ALPINE_SHA256="$alpine_sha" \
    ALARM_URL="file://$TMP/source/alarm.tar.gz" ALARM_SHA256="$alarm_sha" \
    bash "$ROOT/build-omarchy-arm.sh" --only fetch >"$TMP/url.out" 2>&1; then
  echo "insecure URL was accepted" >&2; exit 1
fi
grep -q 'URL no segura' "$TMP/url.out"

echo "fetch verification tests: pass"
