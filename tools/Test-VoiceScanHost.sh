#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source="$repo/tmp/narration-deps/FFmpeg-094a2f8a2a5e7fa64736e067de224ce28fdf5979"
work="$repo/build/narration-readers-host"
output="$repo/build/output/voice-scan-host"
# Host ORT is test-only; never copy it to the Android plugin or model directory.
ort="${VOICE_SCAN_HOST_ORT:?Set VOICE_SCAN_HOST_ORT to the host ONNX Runtime shared library}"
mkdir -p "$output"
g++ -std=c++17 -Wall -Wextra -Werror -Wno-misleading-indentation \
    -I"$repo/tests/native/narration_host" -I"$source" -I"$repo/tmp/narration-deps" \
    "$repo/tests/native/narration_host/scan.cpp" "$repo/native/narration/voice_segment.cpp" "$repo/native/narration/voice_scan.cpp" \
    -L"$work/libavformat" -L"$work/libavcodec" -L"$work/libavutil" -L"$work/libswresample" \
    -lavformat -lavcodec -lavutil -lswresample "$ort" -pthread \
    -Wl,-rpath,"$work/libavformat:$work/libavcodec:$work/libavutil:$work/libswresample:$(dirname "$ort")" \
    -o "$output/scan-host"
echo 'Production speech scanner host build passed'
