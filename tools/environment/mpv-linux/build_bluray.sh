#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
work=${THRU3D_MPV_WORK:-$HOME/.cache/thru3d-mpv}
export PATH="$work/host-venv/bin:$work/android-ndk-r30/toolchains/llvm/prebuilt/linux-x86_64/bin:$PATH"
python3 "$repo/tools/environment/Prepare-BluraySources.py"
cross=()
compiler=gcc
archiver=ar
if [[ "${1:-}" == '--host' ]]; then
    prefix="$repo/build/mvc-host-prefix"
    output="$repo/build/bluray-host"
elif [[ $# == 0 ]]; then
    prefix="$work/mpv-android/buildscripts/prefix/arm64"
    output="$repo/build/bluray-android"
    cross=(--cross-file "$prefix/crossfile.txt")
    compiler="$work/android-ndk-r30/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android23-clang"
    archiver="$work/android-ndk-r30/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-ar"
else
    echo 'Only --host is accepted' >&2
    exit 2
fi
mkdir -p "$output" "$prefix"
export PKG_CONFIG_SYSROOT_DIR="$prefix"
export PKG_CONFIG_LIBDIR="$prefix/usr/local/lib/pkgconfig"
unset PKG_CONFIG_PATH
udf="$repo/tmp/bluray-sources/libudfread-1.2.0"
bd="$repo/tmp/bluray-sources/libbluray-1.4.1"
meson setup "$output/udf" "$udf" "${cross[@]}" --prefix=/usr/local --libdir=lib \
    --default-library=static -Dbuildtype=release -Db_staticpic=true -Dembed_udfread=false -Denable_examples=false
ninja -C "$output/udf" -j4
DESTDIR="$prefix" ninja -C "$output/udf" install
meson setup "$output/bluray" "$bd" "${cross[@]}" --prefix=/usr/local --libdir=lib \
    --default-library=static -Dbuildtype=release -Db_staticpic=true -Dbdj_jar=disabled \
    -Denable_tools=false -Denable_examples=false -Dfreetype=disabled -Dfontconfig=disabled -Dlibxml2=disabled
ninja -C "$output/bluray" -j4
DESTDIR="$prefix" ninja -C "$output/bluray" install
# Expose the pinned parser through callbacks without modifying its verified cache.
"$compiler" -O2 -fPIC -DHAVE_CONFIG_H=1 -D_FILE_OFFSET_BITS=64 \
    -I"$output/bluray" -I"$bd/src" -I"$bd/src/libbluray" \
    -DTHRU3D_BLURAY_CLPI_SOURCE="\"$bd/src/libbluray/bdnav/clpi_parse.c\"" \
    -c "$repo/native/mpv/mvc/bluray_clpi_reader.c" -o "$output/bluray-clpi-reader.o"
mapfile -t members < <("$archiver" t "$output/bluray/src/libbluray.a" | grep 'clpi_parse.c.o$')
[[ ${#members[@]} == 1 ]] || { echo 'Pinned CLPI archive member differs' >&2; exit 2; }
cp "$output/bluray/src/libbluray.a" "$output/thru3d-libbluray.a"
"$archiver" d "$output/thru3d-libbluray.a" "${members[0]}"
"$archiver" rcs "$output/thru3d-libbluray.a" "$output/bluray-clpi-reader.o"
cp "$output/thru3d-libbluray.a" "$prefix/usr/local/lib/libbluray.a"
