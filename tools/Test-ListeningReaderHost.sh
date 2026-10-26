#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ffmpeg="$repo/build/narration-readers-host"
headers="$repo/tmp/narration-deps/FFmpeg-094a2f8a2a5e7fa64736e067de224ce28fdf5979"
output="$repo/build/output/live-interpretation/reader"
mkdir -p "$output/include"
cp "${LISTENING_JNI_HEADER:?Set LISTENING_JNI_HEADER to the NDK jni.h}" "$output/include/jni.h"
g++ -std=c++17 -O2 -Wall -Wextra -Werror -Wno-misleading-indentation -ffunction-sections -fdata-sections \
    -I"$output/include" -I"$repo/third_party/moonshine" -I"$headers" \
    "$repo/tests/native/listening_reader_host.cpp" \
    -L"$ffmpeg/libavformat" -L"$ffmpeg/libavcodec" -L"$ffmpeg/libavutil" -L"$ffmpeg/libswresample" \
    -lavformat -lavcodec -lavutil -lswresample -Wl,--gc-sections \
    -Wl,-rpath,"$ffmpeg/libavformat:$ffmpeg/libavcodec:$ffmpeg/libavutil:$ffmpeg/libswresample" \
    -o "$output/reader-host"
echo 'Production listening audio reader host build passed'
g++ -std=c++17 -O2 -Wall -Wextra -Werror -Wno-misleading-indentation -ffunction-sections -fdata-sections \
    -I"$output/include" -I"$repo/third_party/moonshine" -I"$headers" \
    "$repo/tests/native/listening_cancel_host.cpp" \
    -L"$ffmpeg/libavformat" -L"$ffmpeg/libavcodec" -L"$ffmpeg/libavutil" -L"$ffmpeg/libswresample" \
    -lavformat -lavcodec -lavutil -lswresample -Wl,--gc-sections -pthread \
    -Wl,-rpath,"$ffmpeg/libavformat:$ffmpeg/libavcodec:$ffmpeg/libavutil:$ffmpeg/libswresample" \
    -o "$output/cancel-host"
"$output/cancel-host"
if [[ -n "${LISTENING_HOST_RUNTIME:-}" ]]; then
    g++ -std=c++17 -O2 -Wall -Wextra -Werror -Wno-misleading-indentation -ffunction-sections -fdata-sections \
        -I"$output/include" -I"$repo/third_party/moonshine" -I"$headers" \
        "$repo/tests/native/listening_inference_host.cpp" \
        -L"$ffmpeg/libavformat" -L"$ffmpeg/libavcodec" -L"$ffmpeg/libavutil" -L"$ffmpeg/libswresample" \
        -L"$LISTENING_HOST_RUNTIME" -lmoonshine -l:libonnxruntime.so.1 \
        -lavformat -lavcodec -lavutil -lswresample -Wl,--gc-sections \
        -Wl,-rpath,"$LISTENING_HOST_RUNTIME:$ffmpeg/libavformat:$ffmpeg/libavcodec:$ffmpeg/libavutil:$ffmpeg/libswresample" \
        -o "$output/inference-host"
    echo 'Production listening inference host build passed'
fi
