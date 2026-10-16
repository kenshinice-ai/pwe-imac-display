#!/bin/zsh
#
# Build the receiver's two libraries from source, once per architecture:
#
#   pwe/receiver-deps.sh <prefix-root>        → <prefix-root>/{arm64,x86_64}/{include,lib}
#
# Why not Homebrew's copies, as upstream does:
#   - Homebrew builds for the macOS it runs on. Its FFmpeg needs macOS 14, so the
#     receiver would not even launch on the 2014–2017 iMacs this app is for
#     (upstream issue #167: missing CVBufferCopyAttachments on Big Sur).
#   - Homebrew's FFmpeg is GPL-3.0 (it links x264 and x265). PWE ships the
#     binary under its own name, so it ships an LGPL build instead.
#
# What gets built: FFmpeg with H.264 and HEVC decoding, VideoToolbox and
# swscale only — everything the receiver calls and nothing else — and SDL2.
# Both static, both for macOS 11. Sources are pinned by SHA-256.
#
# Known trade-off: no nasm on the build Mac, so FFmpeg's hand-written x86
# assembly is off. Hardware decoding through VideoToolbox is unaffected; only
# the software fallback is slower on Intel.
set -euo pipefail

ROOT="${1:?usage: receiver-deps.sh <prefix-root>}"
SRC="${PWE_DEPS_SRC:-$ROOT/src}"
MIN_MACOS=11.0

FFMPEG=ffmpeg-9.0.2
FFMPEG_SHA=8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e
FFMPEG_URL=https://ffmpeg.org/releases/$FFMPEG.tar.xz
SDL=SDL2-2.32.10
SDL_SHA=5f5993c530f084535c65a6879e9b26ad441169b3e25d789d83287040a9ca5165
SDL_URL=https://github.com/libsdl-org/SDL/releases/download/release-2.32.10/$SDL.tar.gz

# The cache is reused only when everything that shaped it is unchanged: the
# sources, the target, this script (its configure flags), and the compiler.
SCRIPT_HASH="$(shasum -a 256 "$0" | cut -c1-16)"
CC_VERSION="$(clang --version | head -1)"
SDK_VERSION="$(xcrun --show-sdk-version)"
STAMP="$FFMPEG+$SDL+macos$MIN_MACOS+script:$SCRIPT_HASH+$CC_VERSION+sdk$SDK_VERSION"

# One build at a time per cache: a second run waits instead of building over it.
LOCK="$ROOT/.lock"
mkdir -p "$ROOT"
LOCKED=0
for _ in {1..600}; do mkdir "$LOCK" 2>/dev/null && { LOCKED=1; break; }; sleep 1; done
[[ "$LOCKED" == 1 ]] || { echo "✗ another build has held $LOCK for ten minutes"; exit 1; }
trap 'rmdir "$LOCK" 2>/dev/null' EXIT
mkdir -p "$SRC"

fetch() {  # fetch <file> <url> <sha256>
  local file="$SRC/$1"
  # Download beside the target and rename, so an interrupted run leaves no
  # partial file that fails the checksum on every later run.
  [[ -f "$file" ]] || { curl -sfL "$2" -o "$file.part" && mv "$file.part" "$file"; }
  local actual; actual="$(shasum -a 256 "$file" | cut -d' ' -f1)"
  if [[ "$actual" != "$3" ]]; then
    echo "✗ $1: SHA-256 $actual, expected $3" >&2
    exit 1
  fi
}

fetch "$FFMPEG.tar.xz" "$FFMPEG_URL" "$FFMPEG_SHA"
fetch "$SDL.tar.gz" "$SDL_URL" "$SDL_SHA"

for ARCH in arm64 x86_64; do
  PREFIX="$ROOT/$ARCH"
  if [[ -f "$PREFIX/.stamp" && "$(<"$PREFIX/.stamp")" == "$STAMP" ]]; then
    echo "▸ $ARCH: up to date ($STAMP)"
    continue
  fi
  rm -rf "$PREFIX" "$ROOT/build-$ARCH"
  mkdir -p "$PREFIX" "$ROOT/build-$ARCH"
  HOST=$([[ $ARCH == arm64 ]] && echo aarch64-apple-darwin || echo x86_64-apple-darwin)
  CC_ARCH="clang -arch $ARCH -mmacosx-version-min=$MIN_MACOS"
  JOBS="$(sysctl -n hw.ncpu)"

  echo "▸ $ARCH: SDL2"
  tar -xzf "$SRC/$SDL.tar.gz" -C "$ROOT/build-$ARCH"
  (
    cd "$ROOT/build-$ARCH/$SDL"
    # Keep Homebrew out of the build: nothing from /opt/homebrew may end up linked.
    env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME="$HOME" \
      CC="$CC_ARCH" MACOSX_DEPLOYMENT_TARGET=$MIN_MACOS \
      ./configure --host="$HOST" --prefix="$PREFIX" \
        --enable-static --disable-shared --disable-video-x11 --disable-video-wayland \
        --disable-video-vulkan >"$ROOT/build-$ARCH/sdl-configure.log" 2>&1
    env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME="$HOME" MACOSX_DEPLOYMENT_TARGET=$MIN_MACOS \
      make -j"$JOBS" >"$ROOT/build-$ARCH/sdl-make.log" 2>&1
    make install >"$ROOT/build-$ARCH/sdl-install.log" 2>&1
  )

  echo "▸ $ARCH: FFmpeg (LGPL, H.264/HEVC decode, VideoToolbox, swscale)"
  tar -xJf "$SRC/$FFMPEG.tar.xz" -C "$ROOT/build-$ARCH"
  (
    cd "$ROOT/build-$ARCH/$FFMPEG"
    env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME="$HOME" MACOSX_DEPLOYMENT_TARGET=$MIN_MACOS \
      ./configure --prefix="$PREFIX" \
        --enable-cross-compile --arch="$ARCH" --target-os=darwin \
        --cc="$CC_ARCH" --extra-ldflags="-mmacosx-version-min=$MIN_MACOS" \
        --disable-x86asm \
        --disable-autodetect --disable-everything --disable-programs --disable-doc \
        --disable-network --disable-avformat --disable-avdevice --disable-avfilter \
        --disable-swresample \
        --enable-static --disable-shared --enable-pic \
        --enable-avcodec --enable-avutil --enable-swscale \
        --enable-decoder=h264,hevc --enable-parser=h264,hevc \
        --enable-videotoolbox --enable-hwaccel=h264_videotoolbox,hevc_videotoolbox \
        >"$ROOT/build-$ARCH/ffmpeg-configure.log" 2>&1
    grep -q "^License: LGPL" "$ROOT/build-$ARCH/ffmpeg-configure.log" \
      || grep -q "License: LGPL" ffbuild/config.log \
      || { echo "✗ FFmpeg is not configured as LGPL" >&2; exit 1; }
    # The exact configure line, as FFmpeg records it, ships in Licenses/ (LGPL).
    sed -n 's/^#define FFMPEG_CONFIGURATION "\(.*\)"$/\1/p' config.h > "$ROOT/build-$ARCH/configuration"
    [[ -s "$ROOT/build-$ARCH/configuration" ]] || { echo "✗ no FFMPEG_CONFIGURATION in config.h" >&2; exit 1; }
    env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME="$HOME" MACOSX_DEPLOYMENT_TARGET=$MIN_MACOS \
      make -j"$JOBS" >"$ROOT/build-$ARCH/ffmpeg-make.log" 2>&1
    make install >"$ROOT/build-$ARCH/ffmpeg-install.log" 2>&1
  )
  mv "$ROOT/build-$ARCH/configuration" "$PREFIX/ffmpeg-configuration.txt"

  print -r -- "$STAMP" > "$PREFIX/.stamp"
  echo "▸ $ARCH: done → $PREFIX"
done
