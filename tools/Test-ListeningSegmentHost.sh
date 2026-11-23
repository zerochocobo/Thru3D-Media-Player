#!/usr/bin/env bash
# Build tests/native/listening_segment_host.cpp in WSL: production listening step
# with the Silero segment bridge, against the Linux Moonshine runtime (ORT 1.23).
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ffmpeg="$repo/build/narration-readers-host"
headers="$repo/tmp/narration-deps/FFmpeg-094a2f8a2a5e7fa64736e067de224ce28fdf5979"
runtime="${LISTENING_HOST_RUNTIME:-$repo/tmp/live-interpretation/moonshine-voice-linux-x86_64/lib}"
output="$repo/build/output/listening-segment-host"
mkdir -p "$output/include"
# Product headers target ORT 1.28; the Linux runtime is 1.23 and every call used exists in API 23.
cp "$repo"/tmp/narration-deps/onnxruntime_*.h "$repo/tmp/narration-deps/json.hpp" "$output/include/"
sed -i 's/#define ORT_API_VERSION 28/#define ORT_API_VERSION 23/' "$output/include/onnxruntime_c_api.h"
g++ -std=c++17 -O2 -Wall -Wextra -Werror -I"$output/include" -I"$repo/native/narration" \
    -c "$repo/native/narration/speech_segmenter_bridge.cpp" -o "$output/speech_segmenter_bridge.o"
g++ -std=c++17 -O2 -Wall -Wextra -Werror -Wno-misleading-indentation \
    -I"$repo/build/output/live-interpretation/reader/include" -I"$repo/third_party/moonshine" -I"$headers" -I"$output/include" \
    "$repo/tests/native/listening_segment_host.cpp" "$output/speech_segmenter_bridge.o" \
    -L"$ffmpeg/libavformat" -L"$ffmpeg/libavcodec" -L"$ffmpeg/libavutil" -L"$ffmpeg/libswresample" \
    -L"$runtime" -lmoonshine -l:libonnxruntime.so.1 -lavformat -lavcodec -lavutil -lswresample \
    -Wl,-rpath,"$runtime:$ffmpeg/libavformat:$ffmpeg/libavcodec:$ffmpeg/libavutil:$ffmpeg/libswresample" \
    -o "$output/listening-segment-host"
echo "Listening segment host built: $output/listening-segment-host"
