#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work="$repo/build/pip-clip-ffmpeg-host"
out="$repo/build/output/pip-clip"
source="${THRU3D_FFMPEG_SOURCE:?Set THRU3D_FFMPEG_SOURCE to the pinned FFmpeg source directory}"
mkdir -p "$work" "$out"
cd "$work"
fingerprint=$(sha256sum "$repo/tools/Test-PipClipHost.sh" | cut -d' ' -f1)
if [[ ! -f config.h || ! -f pip-config.sha256 || $(cat pip-config.sha256) != "$fingerprint" ]]; then
    "$source/configure" --disable-everything --disable-autodetect --disable-doc --disable-programs \
        --disable-debug --disable-x86asm --enable-shared --disable-static --disable-avdevice --disable-avfilter --disable-swresample \
        --enable-demuxer=mov,matroska --enable-muxer=matroska --enable-decoder=h264,hevc,pcm_f32le --enable-parser=h264,hevc --enable-protocol=file
    printf '%s' "$fingerprint" >pip-config.sha256
fi
make -j4
zinclude=()
if [[ ! -f /usr/include/zlib.h && -f "$repo/tmp/pip-screenshot/zinclude/zlib.h" ]]; then
    zinclude=(-I"$repo/tmp/pip-screenshot/zinclude")
fi
g++ "${zinclude[@]}" -std=c++17 -O2 -Wall -Wextra -Werror \
    -I"$repo/native/mpv/include/ffmpeg" "$repo/tests/native/pip_clip_host.cpp" \
    -L"$work/libavformat" -L"$work/libavcodec" -L"$work/libavutil" -L"$work/libswscale" \
    -lavformat -lavcodec -lavutil -lswscale -Wl,-rpath,"$work/libavformat:$work/libavcodec:$work/libavutil:$work/libswscale" -o "$out/pip-clip-host"
