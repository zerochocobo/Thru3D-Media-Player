#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work="$repo/build/image-host-linux"
prefix="$work/deps"
mkdir -p "$work/source" "$prefix" "$repo/build/output/image-formats"
check() { printf '%s  %s\n' "$2" "$1" | sha256sum -c -; }
check "$repo/third_party/image/zlib-1.3.2.tar.gz" b99a0b86c0ba9360ec7e78c4f1e43b1cbdf1e6936c8fa0f6835c0cd694a495a1
check "$repo/third_party/tiff/libjpeg-turbo-3.1.2.tar.gz" 560f6338b547544c4f9721b18d8b87685d433ec78b3c644c70d77adad22c55e6
if [[ ! -f "$prefix/lib/libz.a" ]]; then
    tar -xf "$repo/third_party/image/zlib-1.3.2.tar.gz" -C "$work/source"
    cmake -S "$work/source/zlib-1.3.2" -B "$work/zlib" -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$prefix" -DZLIB_BUILD_TESTING=OFF
    cmake --build "$work/zlib" --target install --parallel 4
fi
if [[ ! -f "$prefix/lib/libjpeg.a" ]]; then
    tar -xf "$repo/third_party/tiff/libjpeg-turbo-3.1.2.tar.gz" -C "$work/source"
    cmake -S "$work/source/libjpeg-turbo-3.1.2" -B "$work/jpeg" -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$prefix" -DENABLE_SHARED=OFF -DENABLE_STATIC=ON -DWITH_SIMD=OFF -DWITH_TESTS=OFF -DWITH_TOOLS=OFF
    cmake --build "$work/jpeg" --target install --parallel 4
fi
archive="$repo/tmp/image-ffmpeg-094a2f8a.tar.gz"
if [[ ! -f "$archive" ]]; then
    curl --fail --location --retry 2 'https://codeload.github.com/FFmpeg/FFmpeg/tar.gz/094a2f8a2a5e7fa64736e067de224ce28fdf5979' -o "$archive"
fi
check "$archive" 3633c09eb65cba9864fe4ca1eff75ca1423174869e423e5fe9d8fce028fcf66a
ffsource="$work/source/FFmpeg-094a2f8a2a5e7fa64736e067de224ce28fdf5979"
if [[ ! -f "$ffsource/configure" ]]; then tar -xf "$archive" -C "$work/source"; fi
ffbuild="$work/ffmpeg"
mkdir -p "$ffbuild"
fingerprint=$(sha256sum "$repo/tools/Test-ImageFormatsHost.sh" | cut -d' ' -f1)
if [[ ! -f "$ffbuild/config.h" || ! -f "$ffbuild/input.sha256" || $(cat "$ffbuild/input.sha256") != "$fingerprint" ]]; then
    (cd "$ffbuild" && "$ffsource/configure" --disable-everything --disable-autodetect --disable-doc --disable-programs \
        --disable-debug --disable-x86asm --disable-shared --enable-static --enable-pic \
        --disable-avdevice --disable-avfilter --disable-swresample --enable-swscale --enable-zlib \
        --enable-demuxer=gif,apng --enable-decoder=gif,apng --enable-parser=gif,png --enable-protocol=file \
        --extra-cflags="-I$prefix/include" --extra-ldflags="-L$prefix/lib")
    printf '%s' "$fingerprint" >"$ffbuild/input.sha256"
fi
make -C "$ffbuild" -j4
cmake -S "$repo/native/image" -B "$work/core" -G Ninja -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_PREFIX_PATH="$prefix" -DIMAGE_HOST_FFMPEG_DIR="$ffbuild"
cmake --build "$work/core" --target image_probe --parallel 4
echo "Image production core host probe: $work/core/image_probe"
