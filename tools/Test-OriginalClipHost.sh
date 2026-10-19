#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source="${THRU3D_FFMPEG_SOURCE:?Set THRU3D_FFMPEG_SOURCE to the pinned FFmpeg source directory}"
muxers=mov,matroska,mpegts
if [[ ${1:-} == --with-mp4 ]]; then muxers+=,mp4; elif [[ $# != 0 ]]; then exit 2; fi
work="$repo/build/capture-ffmpeg-host"
mkdir -p "$work" "$repo/build/output/original-capture"
cd "$work"
fingerprint=$(sha256sum "$repo/tools/Test-OriginalClipHost.sh" | cut -d' ' -f1)-$muxers
if [[ ! -f config.h || ! -f capture-config.sha256 || $(cat capture-config.sha256) != "$fingerprint" ]]; then
    "$source/configure" --disable-everything --disable-autodetect --disable-doc --disable-programs \
        --disable-debug --disable-x86asm --enable-shared --disable-static \
        --disable-avdevice --disable-avfilter --disable-swscale --disable-swresample \
        --enable-demuxer=mov,matroska,mpegts --enable-muxer="$muxers" \
        --enable-decoder=h264,hevc,aac,pcm_s16le,vp8 \
        --enable-parser=h264,hevc,aac,ac3 --enable-protocol=file,http,tcp
    printf '%s' "$fingerprint" >capture-config.sha256
fi
make -j4
g++ -std=c++17 -Wall -Wextra -Werror -DTHRU3D_CAPTURE_HOST \
    -I"$repo/native/mpv/include/ffmpeg" "$repo/native/mpv/original_clip.cpp" \
    -L"$work/libavformat" -L"$work/libavcodec" -L"$work/libavutil" -lavformat -lavcodec -lavutil \
    -Wl,-rpath,"$work/libavformat:$work/libavcodec:$work/libavutil" \
    -o "$repo/build/output/original-capture/clip-host"
echo 'Production clip core host build passed'
