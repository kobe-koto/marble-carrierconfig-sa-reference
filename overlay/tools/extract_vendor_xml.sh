#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "usage: $0 /path/to/CarrierConfigResCommon.apk" >&2
    exit 2
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APK="$1"
AAPT2="${AAPT2:-$(command -v aapt2)}"
DUMP="$ROOT/overlay/input/vendor.xmltree"
OUT="$ROOT/overlay/input/vendor.xml"

[[ -f "$APK" ]] || { echo "APK not found: $APK" >&2; exit 1; }
"$AAPT2" dump xmltree "$APK" --file res/xml/vendor.xml > "$DUMP"
python3 "$ROOT/overlay/tools/xmltree_to_xml.py" "$DUMP" "$OUT"
echo "Wrote: $OUT"
echo "Review it before building; it is intentionally ignored by git."
