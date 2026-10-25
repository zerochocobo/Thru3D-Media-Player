#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work="$repo/build/capture-ffmpeg-host"
out="$repo/build/output/live-capture"
mkdir -p "$out"
bash "$repo/tools/Test-OriginalClipHost.sh"
g++ -std=c++17 -O2 -Wall -Wextra -Werror -pthread \
    -I"$repo/native/mpv/include/ffmpeg" "$repo/native/mpv/live/live_capture_audio_test.cpp" \
    -L"$work/libavformat" -L"$work/libavcodec" -L"$work/libavutil" -lavformat -lavcodec -lavutil \
    -Wl,-rpath,"$work/libavformat:$work/libavcodec:$work/libavutil" -o "$out/live-audio-test"
"$out/live-audio-test" "$out/audio-pop-fixed" >"$out/audio-pop-fixed.log"
cat "$out/audio-pop-fixed.log"
g++ -std=c++17 -O2 -Wall -Wextra -Werror -pthread \
    -I"$repo/native/mpv/include/ffmpeg" "$repo/native/mpv/live/live_capture_host.cpp" \
    -L"$work/libavformat" -L"$work/libavcodec" -L"$work/libavutil" -lavformat -lavcodec -lavutil \
    -Wl,-rpath,"$work/libavformat:$work/libavcodec:$work/libavutil" -o "$out/live-host"
for fixture in avc hdr; do
    mkdir -p "$out/$fixture"
    cp "$repo/build/output/original-capture/$fixture.mp4" "$out/$fixture/live-input.mp4"
    "$out/live-host" "$out/$fixture/live-input.mp4" "$out/$fixture/staged" "$out/$fixture/live.mkv" >"$out/$fixture/report.log"
    cat "$out/$fixture/report.log"
done
mkdir -p "$out/normal"
cp "$repo/build/output/original-capture/avc.mp4" "$out/normal/live-input.mp4"
"$out/live-host" "$out/normal/live-input.mp4" "$out/normal/staged" "$out/normal/live.mkv" normal >"$out/normal/report.log"
cat "$out/normal/report.log"

mkdir -p "$out/surround"
cp "$repo/build/output/original-capture/avc.mp4" "$out/surround/live-input.mp4"
"$out/live-host" "$out/surround/live-input.mp4" "$out/surround/staged" "$out/surround/live.mkv" surround >"$out/surround/report.log"
cat "$out/surround/report.log"

# Reproduce mpv's PTS-only MKV packets, including its unknown-duration sentinel.
for fixture in avc hdr; do
    mkdir -p "$out/mkv-$fixture"
    cp "$repo/build/output/original-capture/$fixture.mp4" "$out/mkv-$fixture/live-input.mp4"
    "$out/live-host" "$out/mkv-$fixture/live-input.mp4" "$out/mkv-$fixture/staged" "$out/mkv-$fixture/live.mkv" mkv >"$out/mkv-$fixture/report.log"
    cat "$out/mkv-$fixture/report.log"
done

g++ -std=c++17 -O2 -Wall -Wextra -Werror -pthread -I"$repo/native/mpv/include/ffmpeg" \
    "$repo/tests/native/live_timestamps_test.cpp" -L"$work/libavformat" -L"$work/libavcodec" -L"$work/libavutil" \
    -lavformat -lavcodec -lavutil -Wl,-rpath,"$work/libavformat:$work/libavcodec:$work/libavutil" -o "$out/timestamps-test"
LD_LIBRARY_PATH="$work/libavformat:$work/libavcodec:$work/libavutil${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "$out/timestamps-test"
