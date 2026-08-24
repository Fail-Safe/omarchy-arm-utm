#!/bin/bash
set -uo pipefail
echo "══ el recuento exacto que hace verify ══"
echo "  ls /usr/local/bin | wc -l  →  $(ls /usr/local/bin 2>/dev/null | wc -l)"
echo "  ls /usr/bin       | wc -l  →  $(ls /usr/bin 2>/dev/null | wc -l)"
echo
echo "  contenido de /usr/local/bin:"
ls -1 /usr/local/bin 2>/dev/null | head -12 | sed 's/^/    /'
echo "    ... ($(ls /usr/local/bin 2>/dev/null | wc -l) en total)"
echo
echo "══ ¿pasaría el umbral de 300? ══"
B=$(ls /usr/local/bin 2>/dev/null | wc -l)
[ "$B" -ge 300 ] && echo "  B=$B ≥ 300 → VEREDICTO_OK" || echo "  B=$B < 300 → VEREDICTO_KO"
echo "══ FINC ══"
