#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
ROOT="$PWD"
SCRATCH="$ROOT/.build/live-ffmpeg"
mkdir -p "$SCRATCH" "$ROOT/Resources/LiveTools/bin" "$ROOT/Resources/LiveTools/Licenses"
ARCHIVE="$SCRATCH/ffmpeg-n8.0.tar.gz"
if [ ! -f "$ARCHIVE" ]; then
  curl --fail --location --retry 3 https://codeload.github.com/FFmpeg/FFmpeg/tar.gz/refs/tags/n8.0 -o "$ARCHIVE"
fi
printf '%s  %s\n' dd4030dbfdc34d9ff255a116bdd1caade42500ac2981efa27f8b151cc54c7b9e "$ARCHIVE" | shasum -a 256 -c -
if [ ! -d "$SCRATCH/FFmpeg-n8.0" ]; then tar -xzf "$ARCHIVE" -C "$SCRATCH"; fi
cd "$SCRATCH/FFmpeg-n8.0"
printf '8.0\n' > VERSION
./configure --prefix=/usr/local --arch=aarch64 --target-os=darwin --cc=/usr/bin/clang \
  --extra-cflags=-mmacosx-version-min=13.3 --extra-ldflags=-mmacosx-version-min=13.3 \
  --disable-autodetect --disable-everything --disable-doc --disable-debug --enable-small \
  --enable-ffmpeg --enable-ffprobe --disable-ffplay --enable-network --enable-securetransport --enable-pthreads --enable-videotoolbox --enable-audiotoolbox --enable-zlib \
  --enable-protocol=file,http,https,httpproxy,tcp,tls,crypto \
  --enable-demuxer=hls,mpegts,mov,flv,matroska,aac,mp3,wav,flac,ogg,aiff,image2,concat \
  --enable-muxer=matroska,mp4,mpegts,hls,segment,wav,image2,null \
  --enable-parser=h264,hevc,aac,aac_latm,mpegaudio,opus,vorbis,vp9,av1 \
  --enable-bsf=aac_adtstoasc,h264_mp4toannexb,hevc_mp4toannexb,extract_extradata \
  --enable-indev=lavfi --enable-filter=color,sine,testsrc2,null,anull,scale,format,aformat,aresample,trim,atrim,setpts,asetpts,transpose,hflip,vflip \
  --enable-encoder=mpeg4,h264_videotoolbox,aac,pcm_s16le,png \
  --enable-decoder=rawvideo,wrapped_avframe,h264,hevc,vp8,vp9,av1,mpeg4,h263,aac,mp3,opus,vorbis,flac,alac,pcm_s16le,pcm_s24le,pcm_f32le,png,mjpeg
make -j 6 ffmpeg ffprobe
cp ffmpeg "$ROOT/Resources/LiveTools/bin/ffmpeg"
cp ffprobe "$ROOT/Resources/LiveTools/bin/ffprobe"
cp COPYING.LGPLv2.1 "$ROOT/Resources/LiveTools/Licenses/FFmpeg-COPYING.LGPLv2.1.txt"
cp LICENSE.md "$ROOT/Resources/LiveTools/Licenses/FFmpeg-LICENSE.txt"
"$ROOT/Resources/LiveTools/bin/ffmpeg" -buildconf > "$ROOT/Resources/LiveTools/Licenses/FFmpeg-build-config.txt" 2>&1
mkdir -p "$ROOT/Resources/LiveTools/Source"
cp "$ARCHIVE" "$ROOT/Resources/LiveTools/Source/ffmpeg-n8.0.tar.gz"
cp "$ROOT/scripts/build-live-ffmpeg.sh" "$ROOT/Resources/LiveTools/Licenses/FFmpeg-build.sh"
"$ROOT/Resources/LiveTools/bin/ffmpeg" -version
