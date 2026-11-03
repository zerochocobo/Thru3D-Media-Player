#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ffmpeg="$repo/build/narration-readers-host"
headers="$repo/tmp/narration-deps/FFmpeg-094a2f8a2a5e7fa64736e067de224ce28fdf5979"
output="${1:-$repo/build/output/cast-listening-network-host}"
mkdir -p "$output/include"
jni="${LISTENING_JNI_HEADER:-$repo/build/output/live-interpretation/reader/include/jni.h}"
cp "$jni" "$output/include/jni.h"
g++ -std=c++17 -O2 -Wall -Wextra -Werror -Wno-misleading-indentation -ffunction-sections -fdata-sections \
    -I"$output/include" -I"$repo/third_party/moonshine" -I"$headers" \
    "$repo/tests/native/cast_listening_network_host.cpp" \
    -L"$ffmpeg/libavformat" -L"$ffmpeg/libavcodec" -L"$ffmpeg/libavutil" -L"$ffmpeg/libswresample" \
    -lavformat -lavcodec -lavutil -lswresample -Wl,--gc-sections -pthread \
    -Wl,-rpath,"$ffmpeg/libavformat:$ffmpeg/libavcodec:$ffmpeg/libavutil:$ffmpeg/libswresample" \
    -o "$output/cast-listening-network-host"
fixture_args=()
if [[ $# -ge 2 ]]; then fixture_args=(--fixture "$2"); fi
python3 "$repo/tools/Test-CastListeningNetworkHost.py" --reader "$output/cast-listening-network-host" --output "$output" "${fixture_args[@]}"
