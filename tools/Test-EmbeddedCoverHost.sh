#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work="$repo/build/capture-ffmpeg-host"
out="$repo/build/output/embedded-cover"
mkdir -p "$out"
# Configured by Test-LiveCaptureHost.sh / Test-OriginalClipHost.sh.
g++ -std=c++17 -O2 -Wall -Wextra -Werror -I"$repo/native/mpv/include/ffmpeg" \
    "$repo/tests/native/embedded_cover_host.cpp" -L"$work/libavformat" -L"$work/libavcodec" -L"$work/libavutil" \
    -lavformat -lavcodec -lavutil -Wl,-rpath,"$work/libavformat:$work/libavcodec:$work/libavutil" -o "$out/cover-host"
for name in none portrait landscape font oversize; do
    "$out/cover-host" "$out/$name.mkv" "$out/$name.bin"
done
