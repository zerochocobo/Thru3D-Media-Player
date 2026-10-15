#!/usr/bin/env bash
set -euo pipefail
asm=--disable-x86asm
if [[ $# == 1 && $1 == --x86-asm ]]; then
    asm=--enable-x86asm
elif [[ $# != 0 ]]; then
    echo 'Only --x86-asm is accepted (requires NASM for faster host validation)' >&2
    exit 2
fi
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
work=${THRU3D_MPV_WORK:-$HOME/.cache/thru3d-mpv}
export PATH="$work/host-venv/bin:$PATH"
prefix="$repo/build/mvc-host-prefix"
export PKG_CONFIG_SYSROOT_DIR="$prefix"
export PKG_CONFIG_LIBDIR="$prefix/usr/local/lib/pkgconfig"
unset PKG_CONFIG_PATH
mkdir -p "$repo/build/mvc-ffmpeg-host"
cd "$repo/build/mvc-ffmpeg-host"
"$work/mpv-android/buildscripts/deps/ffmpeg/configure" \
    --disable-everything --disable-doc --disable-debug "$asm" --enable-gpl --enable-version3 \
    --enable-shared --disable-static \
    --enable-libbluray --pkg-config-flags=--static \
    --extra-cflags="-I$prefix/usr/local/include -msse4.1" --extra-ldflags="-L$prefix/usr/local/lib" \
    --enable-decoder=h264_mvc,h264,hevc,mpeg2video,dca,ac3,eac3,mlp,truehd,pcm_bluray --enable-demuxer=bd_mvc,mpegts \
    --enable-parser=h264,hevc,mpegvideo,dca,ac3,mlp --enable-protocol=file,http,tcp,bluray \
    --enable-muxer=null,rawvideo --enable-encoder=rawvideo,wrapped_avframe,pcm_s16le \
    --enable-filter=null,anull,buffer,buffersink,abuffer,abuffersink,format,aformat,scale,aresample \
    --disable-ffplay
make -j4
