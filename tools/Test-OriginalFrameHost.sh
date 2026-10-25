#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source="${THRU3D_FFMPEG_SOURCE:?Set THRU3D_FFMPEG_SOURCE to the pinned FFmpeg source directory}"
work="$repo/build/frame-ffmpeg-host"
out="$repo/build/output/screenshot-20261024/host"
mkdir -p "$work" "$out"
cd "$work"
fingerprint=$(sha256sum "$repo/tools/Test-OriginalFrameHost.sh" | cut -d' ' -f1)
if [[ ! -f config.h || ! -f frame-config.sha256 || $(cat frame-config.sha256) != "$fingerprint" ]]; then
    "$source/configure" --disable-everything --disable-autodetect --disable-doc --disable-programs \
        --disable-debug --disable-x86asm --enable-shared --disable-static \
        --disable-avdevice --disable-avfilter --disable-swresample \
        --enable-demuxer=mov,matroska,mpegts --enable-decoder=h264,hevc \
        --enable-parser=h264,hevc --enable-protocol=file,http,tcp
    printf '%s' "$fingerprint" >frame-config.sha256
fi
make -j4
g++ -std=c++17 -O2 -Wall -Wextra -Werror \
    -I"$repo/native/mpv/include/ffmpeg" "$repo/native/mpv/original_frame_host.cpp" \
    -L"$work/libavformat" -L"$work/libavcodec" -L"$work/libavutil" -L"$work/libswscale" \
    -lavformat -lavcodec -lavutil -lswscale \
    -Wl,-rpath,"$work/libavformat:$work/libavcodec:$work/libavutil:$work/libswscale" -o "$out/frame-host"
echo 'Production source frame core host build passed'
