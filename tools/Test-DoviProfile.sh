#!/usr/bin/env bash
# Host regression for the Profile 5 frame predicate compiled into libmpv.
# Uses the FFmpeg headers of the locked Android source build.
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
include="${1:?Pass the pinned FFmpeg include directory as the first argument}"
build="$repo/build/dovi-profile-host"
mkdir -p "$build"
cc -std=c11 -Wall -Wextra -Werror -I"$include" -I"$repo/native/mpv" \
    "$repo/tests/native/dovi_profile_test.c" -o "$build/dovi_profile_test"
"$build/dovi_profile_test"
