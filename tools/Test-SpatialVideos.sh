#!/usr/bin/env bash
# Host regression for the same MV-HEVC helper used by the locked Android MPV.
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
samples=${1:?Supply your licensed spatial-video sample directory}
archive=${2:?Supply the locked FFmpeg archive path}
source="$repo/tmp/spatial-video/ffmpeg"
build="$repo/build/spatial-video-host"
logs="$repo/build/output"
python3 - "$repo/third_party/mpv/source-lock.json" "$archive" <<'PY'
import hashlib, json, sys
from pathlib import Path
record = next(s for s in json.loads(Path(sys.argv[1]).read_text())['sources'] if s['name'] == 'ffmpeg')
if hashlib.sha256(Path(sys.argv[2]).read_bytes()).hexdigest() != record['sha256']:
    raise SystemExit('FFmpeg archive does not match the locked decoder')
PY
mkdir -p "$source" "$build" "$logs"
if [[ ! -f "$source/configure" ]]; then
    tar -xf "$archive" --strip-components=1 -C "$source"
fi
cd "$build"
if [[ ! -f config.h ]]; then
    "$source/configure" --disable-doc --disable-programs --disable-autodetect \
        --disable-network --disable-everything --enable-protocol=file \
        --enable-demuxer=mov --enable-decoder=hevc --enable-parser=hevc \
        --disable-avdevice --disable-avfilter --disable-swscale --disable-swresample \
        --disable-x86asm >"$logs/spatial-ffmpeg-configure.log" 2>&1
fi
make -j"${QUEST_MPV_CORES:-6}" >"$logs/spatial-ffmpeg-build.log" 2>&1
cc -std=c11 -Wall -Wextra -Werror -I. -I"$source" -I"$repo/native/mpv" \
    "$repo/tests/native/spatial_video_test.c" \
    libavformat/libavformat.a libavcodec/libavcodec.a libavutil/libavutil.a \
    -lm -lpthread -ldl -o spatial_video_test
shopt -s nullglob
files=("$samples"/iPhone16Pro_SVD_*.mov)
[[ ${#files[@]} -ge 5 ]] || { echo 'At least five original MV-HEVC samples are required' >&2; exit 2; }
./spatial_video_test "${files[@]}" >"$logs/spatial-video-native-test.log" 2>&1
cat "$logs/spatial-video-native-test.log"
