#!/bin/sh
set -eu
cd "$(dirname "$0")"
mkdir -p .build
ICON_STAGE="$(mktemp -d "$PWD/.build/icon-stage.XXXXXX")"
trap 'rm -rf "$ICON_STAGE"' EXIT
ICON_SET="$ICON_STAGE/AppIcon.iconset"
mkdir -p "$ICON_SET"
sips -s format png Resources/AppIcon.svg --out Resources/AppIcon.png >/dev/null
for POINTS in 16 32 128 256 512; do
  sips -z "$POINTS" "$POINTS" Resources/AppIcon.png --out "$ICON_SET/icon_${POINTS}x${POINTS}.png" >/dev/null
  PIXELS=$((POINTS * 2))
  sips -z "$PIXELS" "$PIXELS" Resources/AppIcon.png --out "$ICON_SET/icon_${POINTS}x${POINTS}@2x.png" >/dev/null
done
iconutil -c icns "$ICON_SET" -o Resources/AppIcon.icns
for PIXELS in 16 24 32 48 64 128 256; do
  sips -z "$PIXELS" "$PIXELS" Resources/AppIcon.png --out "$ICON_STAGE/ico-${PIXELS}.png" >/dev/null
done
# Package the resized PNGs directly; preserve their alpha without touching pixels.
python3 - "$ICON_STAGE" "$PWD/Resources/AppIcon.ico" <<'PY'
import struct
import sys
from pathlib import Path
root, output = map(Path, sys.argv[1:])
sizes = [16, 24, 32, 48, 64, 128, 256]
images = [(size, (root / f'ico-{size}.png').read_bytes()) for size in sizes]
offset = 6 + 16 * len(images)
entries = []
for size, data in images:
    dimension = 0 if size == 256 else size
    entries.append(struct.pack('<BBBBHHII', dimension, dimension, 0, 0, 1, 32, len(data), offset))
    offset += len(data)
output.write_bytes(struct.pack('<HHH', 0, 1, len(images)) + b''.join(entries) + b''.join(data for _, data in images))
PY
printf 'Built AppIcon.icns and AppIcon.ico\n'
