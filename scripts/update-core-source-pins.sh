#!/usr/bin/env bash
# Resolve proposed Git source pins and optionally update the reviewed manifest.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
LOCK="$ROOT/checksums/core-git-sources.tsv"
WRITE=0
VERIFY=0

usage() {
  cat <<'EOF'
Usage: scripts/update-core-source-pins.sh [--verify] [--write]

Prints a reviewable diff from the current core Git source lock to each source's
configured refresh ref. --verify also proves every recorded commit is directly
fetchable. --write updates the manifest and re-embeds it in the standalone
builder after review.
EOF
}

while (($#)); do
  case "$1" in
    --verify) VERIFY=1; shift ;;
    --write) WRITE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

(( WRITE )) && VERIFY=1

[[ -f $LOCK ]] || { echo "missing source lock: $LOCK" >&2; exit 1; }
command -v git >/dev/null || { echo "missing command: git" >&2; exit 1; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/omarchy-source-pins.XXXXXX")
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT
PROPOSED="$WORK/core-git-sources.tsv"

verify_fetchable() {
  local key="$1" url="$2" ref="$3" commit="$4" dir="$WORK/verify-$1" actual branch
  git -C "$WORK" init -q "verify-$key"
  git -C "$dir" remote add origin "$url"
  git -C "$dir" -c protocol.version=2 fetch -q --filter=blob:none --depth 1 origin "$commit" \
    || git -C "$dir" fetch -q --depth 1 origin "$commit"
  actual=$(git -C "$dir" rev-parse FETCH_HEAD)
  [[ $actual == "$commit" ]] || {
    echo "$key fetched $actual instead of $commit" >&2
    return 1
  }
  if [[ $key == omarchy && $ref == refs/heads/* ]]; then
    branch=${ref#refs/heads/}
    git -C "$dir" fetch -q origin "$ref:refs/remotes/origin/$branch"
    git -C "$dir" merge-base --is-ancestor "$commit" "refs/remotes/origin/$branch" || {
      echo "$key commit $commit is not on $ref" >&2
      return 1
    }
  fi
}

while IFS= read -r line || [[ -n $line ]]; do
  if [[ -z $line || $line == \#* ]]; then
    printf '%s\n' "$line" >> "$PROPOSED"
    continue
  fi
  read -r key url ref commit extra <<< "$line"
  [[ -z ${extra:-} && $key =~ ^[a-z0-9][a-z0-9._+-]*$ \
      && $url == https://* \
      && $ref =~ ^(HEAD|PINNED|refs/heads/[A-Za-z0-9._/-]+|refs/tags/[A-Za-z0-9._/+:-]+\^\{\})$ \
      && $commit =~ ^[0-9a-f]{40}$ ]] || {
    echo "invalid source-lock record: $line" >&2
    exit 1
  }
  (( VERIFY )) && verify_fetchable "$key" "$url" "$ref" "$commit"
  if [[ $ref == PINNED ]]; then
    proposed=$commit
  else
    proposed=$(git ls-remote "$url" "$ref" | awk 'NR == 1 { print $1 }')
  fi
  [[ $proposed =~ ^[0-9a-f]{40}$ ]] || {
    echo "could not resolve $key at $ref" >&2
    exit 1
  }
  printf '%s %s %s %s\n' "$key" "$url" "$ref" "$proposed" >> "$PROPOSED"
done < "$LOCK"

if cmp -s "$LOCK" "$PROPOSED"; then
  echo "core Git source pins are current"
else
  diff -u "$LOCK" "$PROPOSED" || true
fi

if (( WRITE )); then
  cp "$PROPOSED" "$LOCK.new"
  mv "$LOCK.new" "$LOCK"
  OMARCHY_LANG=en python3 "$ROOT/scripts/sync-payloads.py"
  echo "updated checksums/core-git-sources.tsv and the standalone builder"
else
  echo "dry run only; pass --write after reviewing the source changes"
fi
