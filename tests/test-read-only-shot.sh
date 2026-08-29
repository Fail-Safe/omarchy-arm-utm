#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SHOT="$ROOT/scripts/qemu-shot.sh"

bash -n "$SHOT"
grep -Fq '  -snapshot \' "$SHOT"

echo "read-only screenshot boot test: pass"
