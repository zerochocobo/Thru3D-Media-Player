#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ffmpeg="$repo/build/narration-readers-host"
headers="$repo/tmp/narration-deps/FFmpeg-094a2f8a2a5e7fa64736e067de224ce28fdf5979"
output="$repo/build/output/listening-throughput-20261027"
runtime="${LISTENING_HOST_RUNTIME:-$repo/tmp/live-interpretation/moonshine-voice-linux-x86_64/lib}"
mkdir -p "$output"
for test in throughput queue; do
g++ -std=c++17 -O2 -Wall -Wextra -Werror -Wno-misleading-indentation -ffunction-sections -fdata-sections \
    -I"$repo/build/output/live-interpretation/reader/include" -I"$repo/third_party/moonshine" -I"$headers" \
    "$repo/tests/native/listening_${test}_host.cpp" \
    -L"$ffmpeg/libavformat" -L"$ffmpeg/libavcodec" -L"$ffmpeg/libavutil" -L"$ffmpeg/libswresample" \
    -L"$runtime" -lmoonshine -l:libonnxruntime.so.1 \
    -lavformat -lavcodec -lavutil -lswresample -Wl,--gc-sections \
    -Wl,-rpath,"$runtime:$ffmpeg/libavformat:$ffmpeg/libavcodec:$ffmpeg/libavutil:$ffmpeg/libswresample" \
    -o "$output/${test}-host"
done
echo 'Production listening throughput host built (no Android packaging)'
