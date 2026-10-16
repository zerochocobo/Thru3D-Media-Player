#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_root="$PWD"
output="$task_root/build/output/usb-storage-tests"
tool_cache="$task_root/tmp/usb-fixture-tools"
mkdir -p "$output" "$tool_cache/root"
cmake -S native/usb -B build/output/usb-native-host -DCMAKE_BUILD_TYPE=Release > "$output/configure.log" 2>&1
cmake --build build/output/usb-native-host -j4 > "$output/build.log" 2>&1
(
  cd "$tool_cache"
  if ! compgen -G 'ntfs-3g*.deb' > /dev/null; then apt-get download ntfs-3g > download.log 2>&1; fi
  if ! compgen -G 'libntfs-3g*.deb' > /dev/null; then apt-get download libntfs-3g89t64 >> download.log 2>&1; fi
  for archive in *.deb; do dpkg-deb -x "$archive" root; done
)
export LD_LIBRARY_PATH="$tool_cache/root/usr/lib/x86_64-linux-gnu:$tool_cache/root/lib/x86_64-linux-gnu${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export LANG=C.UTF-8
python3 - "$output/data.bin" <<'PY'
import sys
with open(sys.argv[1], 'wb') as f:
    f.write(bytes((i*31+i//97)%256 for i in range(1100003)))
PY
checker="$task_root/build/output/usb-native-host/usb_image_check"
writer="$task_root/build/output/usb-native-host/usb_fixture_writer"
"$checker" --invalid
filename='电影-🎬.mkv'
for sector in 512 4096; do
  for fs in fat exfat; do
    # The generator uses 512 MiB for FAT32/4KiB to satisfy its minimum cluster count.
    image="$output/$fs-$sector.img"
    "$writer" "$fs" "$image" "$output/data.bin" "$filename" "$sector"
    before=$(sha256sum "$image" | cut -d' ' -f1)
    "$checker" fat "$image" "$filename" "$output/data.bin" "$sector"
    after=$(sha256sum "$image" | cut -d' ' -f1)
    [[ "$before" == "$after" ]]
  done
  image="$output/ntfs-$sector.img"
  truncate -s 128M "$image"
  mkntfs=$(find "$tool_cache/root" -type f -name mkntfs | head -1)
  ntfscp=$(find "$tool_cache/root" -type f -name ntfscp | head -1)
  "$mkntfs" -F -Q -s "$sector" "$image" > "$output/mkntfs-$sector.log" 2>&1
  "$ntfscp" -f "$image" "$output/data.bin" "/$filename"
  before=$(sha256sum "$image" | cut -d' ' -f1)
  "$checker" ntfs "$image" "$filename" "$output/data.bin" "$sector"
  after=$(sha256sum "$image" | cut -d' ' -f1)
  [[ "$before" == "$after" ]]
done
image="$output/exfat-large.img"
"$writer" exfat "$image" "$output/data.bin" "$filename" 512 large
before=$(sha256sum "$image" | cut -d' ' -f1)
"$checker" fat "$image" "$filename" "$output/data.bin" 512 large
after=$(sha256sum "$image" | cut -d' ' -f1)
[[ "$before" == "$after" ]]
echo 'USB filesystem images: all passed; all input hashes unchanged'
