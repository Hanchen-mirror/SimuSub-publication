#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
ROOT="$PWD"
SRC="$ROOT/Resources/MP3/Source/lame-3.100.tar.gz"
BUILD="$ROOT/.build/mp3-encoder"
mkdir -p "$BUILD"
tar -xzf "$SRC" -C "$BUILD"
cd "$BUILD/lame-3.100"
# Upstream's Darwin export list contains legacy/decoder symbols absent in an
# encoder-only build. No codec implementation is changed.
python3 - <<'PY'
from pathlib import Path
p=Path('include/libmp3lame.sym')
p.write_text('\n'.join(x for x in p.read_text().splitlines() if not (x.startswith('hip_') or x.startswith('lame_decode') or x=='lame_init_old'))+'\n')
PY
CC=clang CFLAGS='-O2 -mmacosx-version-min=13.3' LDFLAGS='-mmacosx-version-min=13.3' ./configure --host=arm-apple-darwin --disable-frontend --disable-decoder --disable-static --enable-shared
make -j4
cp libmp3lame/.libs/libmp3lame.0.dylib "$ROOT/Resources/MP3/libmp3lame.0.dylib"
install_name_tool -id '@rpath/libmp3lame.0.dylib' "$ROOT/Resources/MP3/libmp3lame.0.dylib"
