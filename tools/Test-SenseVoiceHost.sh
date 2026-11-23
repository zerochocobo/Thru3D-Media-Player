#!/usr/bin/env bash
# Build the SenseVoice desktop check (tests/native/sense_voice_host.cpp) in WSL.
# Uses the Moonshine runtime's kaldi-native-fbank sources and Linux ONNX Runtime.
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
third="$repo/tmp/moonshine-runtime-source/core/third-party"
runtime="${LISTENING_HOST_RUNTIME:-$repo/tmp/live-interpretation/moonshine-voice-linux-x86_64/lib}"
output="$repo/build/output/sense-voice-host"
mkdir -p "$output"
# The Linux runtime is ORT 1.23; the product headers target 1.28. Every call used
# here exists in API 23, so request that version for the desktop check only.
mkdir -p "$output/include"
cp "$repo"/tmp/narration-deps/onnxruntime_*.h "$repo/tmp/narration-deps/json.hpp" "$output/include/"
sed -i 's/#define ORT_API_VERSION 28/#define ORT_API_VERSION 23/' "$output/include/onnxruntime_c_api.h"
# Third-party sources build quietly; the project files keep full warnings.
objects=()
for name in feature-fbank feature-mfcc feature-raw-audio-samples whisper-feature feature-functions feature-window mel-computations online-feature rfft kaldi-math log; do
    g++ -std=c++17 -O2 -w -I"$third" -I"$third/kissfft" -c "$third/kaldi-native-fbank/csrc/$name.cc" -o "$output/$name.o"
    objects+=("$output/$name.o")
done
for name in kiss_fft kiss_fftr; do
    gcc -O2 -w -c "$third/kissfft/$name.c" -o "$output/$name.o"; objects+=("$output/$name.o")
done
g++ -std=c++17 -O2 -Wall -Wextra -I"$output/include" -I"$third" -I"$repo/native/narration"     "$repo/tests/native/sense_voice_host.cpp" "${objects[@]}"     -L"$runtime" -l:libonnxruntime.so.1 -Wl,-rpath,"$runtime" -o "$output/sense-voice-host"
echo "SenseVoice host built: $output/sense-voice-host"
