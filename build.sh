#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
FFMPEG_VERSION=9.0.2
FFMPEG_SHA256=6e374ed621e48faa40639307dff48ba6fe574a509977956d2cce9669b7cc27e9
FFMPEG_ROOT="$PWD/.build/ffmpeg-$FFMPEG_VERSION"
FFMPEG_PREFIX="$FFMPEG_ROOT/install"
if [[ ! -x "$FFMPEG_PREFIX/bin/ffmpeg" ]]; then
    mkdir -p "$FFMPEG_ROOT"
    ARCHIVE="$FFMPEG_ROOT/source.tar.gz"
    curl -fLsS "https://github.com/FFmpeg/FFmpeg/archive/refs/tags/n$FFMPEG_VERSION.tar.gz" -o "$ARCHIVE"
    echo "$FFMPEG_SHA256  $ARCHIVE" | shasum -a 256 -c -
    tar -xf "$ARCHIVE" -C "$FFMPEG_ROOT"
    (
        cd "$FFMPEG_ROOT/FFmpeg-n$FFMPEG_VERSION"
        ./configure --prefix="$FFMPEG_PREFIX" --disable-everything --disable-autodetect \
            --disable-network --disable-doc --disable-debug --disable-programs --enable-ffmpeg \
            --disable-avdevice --disable-swscale --disable-static --enable-shared --enable-small \
            --install-name-dir='@rpath' --enable-protocol=file --enable-demuxer=mov \
            --enable-muxer=ipod --enable-decoder=aac --enable-encoder=aac --enable-parser=aac \
            --enable-filter=acompressor,alimiter,aresample,aformat,anull
        make -j"$(sysctl -n hw.ncpu)"
        make install
    )
fi
APP="$PWD/build/Anki Audio Capture.app"
if [[ -n "${CODE_SIGN_IDENTITY:-}" ]]; then
    IDENTITY="$CODE_SIGN_IDENTITY"
else
    IDENTITY="$(security find-identity -v -p codesigning | awk '/\"Apple Development:/ && !found {print $2; found=1}')"
    IDENTITY="${IDENTITY:--}"
fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
cp .build/release/AnkiAudioCapture "$APP/Contents/MacOS/AnkiAudioCapture"
cp "$FFMPEG_PREFIX/bin/ffmpeg" "$APP/Contents/MacOS/ffmpeg"
install_name_tool -add_rpath '@loader_path/../Frameworks' "$APP/Contents/MacOS/ffmpeg"
for library in "$FFMPEG_PREFIX"/lib/*.dylib; do
    if [[ -L "$library" ]]; then
        cp -P "$library" "$APP/Contents/Frameworks/"
        continue
    fi
    name="$(basename "$library")"
    cp "$library" "$APP/Contents/Frameworks/$name"
    install_name_tool -add_rpath '@loader_path' "$APP/Contents/Frameworks/$name"
    codesign --force --sign "$IDENTITY" "$APP/Contents/Frameworks/$name"
done
cp "$FFMPEG_ROOT/FFmpeg-n$FFMPEG_VERSION/COPYING.LGPLv2.1" "$APP/Contents/Resources/FFmpeg-LICENSE.txt"
mkdir -p "$APP/Contents/Resources/anki-addon"
cp anki-addon/__init__.py "$APP/Contents/Resources/anki-addon/__init__.py"
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign "$IDENTITY" "$APP/Contents/MacOS/ffmpeg"
codesign --force --sign "$IDENTITY" "$APP"
echo "$APP"
