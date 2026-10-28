#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source="$repo/tmp/narration-deps/FFmpeg-094a2f8a2a5e7fa64736e067de224ce28fdf5979"
work="$repo/build/narration-readers-host"
output="$repo/build/output/voice-clone-sources-20261020"
mkdir -p "$work" "$output"
cd "$work"
fingerprint=$(sha256sum "$repo/tools/Test-VoiceCloneHost.sh" | cut -d' ' -f1)
if [[ ! -f config.h || ! -f fixture-config.sha256 || $(cat fixture-config.sha256) != "$fingerprint" ]]; then
    "$source/configure" --disable-everything --disable-autodetect --disable-doc --disable-programs \
        --disable-debug --disable-x86asm --enable-shared --disable-static \
        --disable-avdevice --disable-avfilter --disable-swscale --enable-swresample \
        --enable-demuxer=mov,matroska,mpegts,srt,ass,webvtt,mp3,wav \
        --enable-decoder=aac,ac3,eac3,pcm_s16le,pcm_s24le,subrip,ass,webvtt,movtext,mp3float,mjpeg,alac \
        --enable-parser=aac,ac3,mpegaudio,mjpeg --enable-protocol=file,http,tcp
    printf '%s' "$fingerprint" >fixture-config.sha256
fi
make -j4 >"$output/ffmpeg-host-build.log" 2>&1
g++ -std=c++17 -Wall -Wextra -Werror -Wno-misleading-indentation -DNARRATION_HOST_SUBTITLES \
    -I"$repo/tests/native/narration_host" -I"$source" -I"$repo/tmp/narration-deps" \
    "$repo/tests/native/narration_host/readers.cpp" \
    "$repo/native/narration/voice_segment.cpp" "$repo/native/narration/subtitle_reader.cpp" \
    -L"$work/libavformat" -L"$work/libavcodec" -L"$work/libavutil" -L"$work/libswresample" \
    -lavformat -lavcodec -lavutil -lswresample -pthread \
    -Wl,-rpath,"$work/libavformat:$work/libavcodec:$work/libavutil:$work/libswresample" \
    -o "$output/readers-host"
echo 'Production reference/subtitle readers host build passed'
