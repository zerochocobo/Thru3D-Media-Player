#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
work=${THRU3D_MPV_WORK:-$HOME/.cache/thru3d-mpv}
export PATH="$work/host-venv/bin:$work/android-ndk-r30/toolchains/llvm/prebuilt/linux-x86_64/bin:$PATH"
python3 "$repo/tools/environment/Prepare-DvdSources.py"
cross=()
if [[ "${1:-}" == --host ]]; then
    prefix="$repo/build/mvc-host-prefix"
    output="$repo/build/dvd-host"
elif [[ $# == 0 ]]; then
    prefix="$work/mpv-android/buildscripts/prefix/arm64"
    output="$repo/build/dvd-android"
    cross=(--cross-file "$prefix/crossfile.txt")
else
    echo 'Only --host is accepted' >&2; exit 2
fi
export PKG_CONFIG_SYSROOT_DIR="$prefix"
export PKG_CONFIG_LIBDIR="$prefix/usr/local/lib/pkgconfig"
unset PKG_CONFIG_PATH
meson setup "$output/read" "$repo/tmp/dvd-sources/libdvdread-7.0.1" "${cross[@]}" \
    --prefix=/usr/local --libdir=lib --default-library=static -Dbuildtype=release -Db_staticpic=true -Dlibdvdcss=disabled
ninja -C "$output/read" -j4
DESTDIR="$prefix" ninja -C "$output/read" install
meson setup "$output/nav" "$repo/tmp/dvd-sources/libdvdnav-7.0.0" "${cross[@]}" \
    --prefix=/usr/local --libdir=lib --default-library=static -Dbuildtype=release -Db_staticpic=true -Denable_examples=false
ninja -C "$output/nav" -j4
DESTDIR="$prefix" ninja -C "$output/nav" install
