#!/usr/bin/env bash
set -euo pipefail
workspace="$(cd "$(dirname "$0")/../.." && pwd)"
deps="$workspace/build/airplay/deps"
ndk="${AIRPLAY_ANDROID_NDK:-${ANDROID_NDK_HOME:?Set AIRPLAY_ANDROID_NDK or ANDROID_NDK_HOME to the pinned NDK}}"
export ANDROID_NDK_ROOT="$ndk"
host_tag=linux-x86_64
if [[ "$(uname -s)" == Darwin ]]; then host_tag=darwin-x86_64; fi
export PATH="$ndk/toolchains/llvm/prebuilt/$host_tag/bin:$PATH"
mkdir -p "$deps/crypto" "$workspace/build/airplay/native"
if [[ ! -f "$deps/crypto/lib/libcrypto.a" ]]; then
    cd "$workspace/build/airplay/sources/openssl-3.5.9"
    perl Configure android-arm64 -D__ANDROID_API__=29 no-shared no-tests no-apps no-module --prefix="$deps/crypto" --libdir=lib
    make -j4 build_libs
    make install_dev
fi
cmake -S "$workspace/native/airplay" -B "$workspace/build/airplay/native" -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE="$ndk/build/cmake/android.toolchain.cmake" \
    -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=29 -DANDROID_STL=c++_static \
    -DCMAKE_BUILD_TYPE=RelWithDebInfo -DAIRPLAY_DEPS="$deps"
cmake --build "$workspace/build/airplay/native" -j4
python3 - "$workspace" <<'PY'
import hashlib, json, sys
from pathlib import Path
root = Path(sys.argv[1])
crypto = root / 'build/airplay/deps/crypto/lib/libcrypto.a'
source = root / 'build/airplay/sources/openssl-3.5.9/libcrypto.a'
def sha(path):
    with path.open('rb') as f: return hashlib.file_digest(f, 'sha256').hexdigest()
receipt = root / 'build/airplay/deps/crypto/receipt.json'
if receipt.exists():
    previous = json.loads(receipt.read_text())
    if previous['sha256'] != sha(crypto): raise RuntimeError('AirPlay crypto output digest differs')
else:
    if not source.exists() or sha(source) != sha(crypto): raise RuntimeError('AirPlay crypto install differs from compiled source output')
    receipt.write_text(json.dumps({'openssl':'3.5.9','api':29,'abi':'arm64-v8a','sha256':sha(crypto)}, indent=2)+'\n')
PY
