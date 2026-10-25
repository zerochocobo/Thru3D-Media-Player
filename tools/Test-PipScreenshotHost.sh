#!/usr/bin/env bash
# Build the production compositor/encoder with the same pinned JPEG source as Android.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
out="$root/build/output/pip-screenshot"
scratch="$root/tmp/pip-screenshot-host"
mkdir -p "$out" "$scratch"
archive="$root/third_party/tiff/libjpeg-turbo-3.1.2.tar.gz"
echo '560f6338b547544c4f9721b18d8b87685d433ec78b3c644c70d77adad22c55e6  '"$archive" | sha256sum -c -
if [[ ! -f "$scratch/libjpeg-turbo-3.1.2/CMakeLists.txt" ]]; then
    tar -xzf "$archive" -C "$scratch"
fi
cmake -S "$scratch/libjpeg-turbo-3.1.2" -B "$out/jpeg-host" -DCMAKE_BUILD_TYPE=Release \
    -DENABLE_SHARED=OFF -DENABLE_STATIC=ON -DWITH_TURBOJPEG=OFF -DWITH_TOOLS=OFF -DWITH_TESTS=OFF -DWITH_SIMD=OFF
cmake --build "$out/jpeg-host" --target jpeg-static --parallel 4
# Normal systems provide zlib headers; the existing Android NDK header copy is also compatible.
zinclude=()
if [[ ! -f /usr/include/zlib.h && -f "$root/tmp/pip-screenshot/zinclude/zlib.h" ]]; then
    zinclude=(-I"$root/tmp/pip-screenshot/zinclude")
fi
g++ -std=c++17 -O2 -Wall -Wextra -Werror "${zinclude[@]}" \
    -I"$scratch/libjpeg-turbo-3.1.2/src" -I"$out/jpeg-host" \
    "$root/tests/native/pip_screenshot_host.cpp" "$out/jpeg-host/libjpeg.a" -l:libz.so.1 -o "$out/pip-screenshot-host"
