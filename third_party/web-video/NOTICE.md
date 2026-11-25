# Web video runtime

The application uses yt-dlp for local media discovery, and the Android Python and
QuickJS distribution from youtubedl-android. It does not use its download manager,
automatic updates, FFmpeg or aria2c packages.

- yt-dlp 2026.11.23.232705 (official nightly): https://github.com/yt-dlp/yt-dlp/tree/696c0673e9e06bf50514a11e6796644771ce330e
  (Unlicense; see LICENSE.yt-dlp). The pinned Python zip includes EJS 0.8.0;
  its Meriyah and Astring notices are embedded in the solver JavaScript headers,
  not standalone license files. NOTICE.ejs.txt makes those original headers
  available to the in-app reader.
- youtubedl-android 0.18.1: https://github.com/yausername/youtubedl-android
  (GPL-3.0; see LICENSE.youtubedl-android). Maven sources are available alongside
  the pinned artifact. WebVideoResolver uses its initialization API; our process
  environment follows the upstream YoutubeDL.kt layout. The execution wrapper is
  local, bounded, cancellable and does not print extractor output.
- Python 3.12.11: PSF license and historical notices (LICENSE.python).
- QuickJS 2025-04-26: MIT (LICENSE.quickjs).
  Versions were read from the pinned wrapper's ARM64 payload. RUNTIME-NOTICE.txt
  records their sources and the native libraries carried by the Python bundle.
  These libraries still need their exact corresponding-source/notice inventory
  in the separate distribution audit; the Python license does not cover them.

runtime.json pins the Python zip and its SHA-256. Build-Player downloads it to
build/web-video, verifies it, and stages it as an APK asset. No third-party account
credentials or browser cookies are included. This development integration does
not constitute a store submission or a completed distribution audit.

## Updating the pinned extractor

Run `tools/Check-WebVideoUpdate.ps1` to compare both official release channels
with the pin. This is a read-only maintenance check; builds and installed apps
never follow a floating `latest` URL or update the extractor automatically.

For an update, review the upstream changes and choose a fixed release. Verify
the `yt-dlp` asset against both its GitHub asset digest and `SHA2-256SUMS`, then
update runtime.json (version, channel, source commit, URL, size and SHA-256).
Review the bundled EJS version, solver headers and license notices as well as
the Python/QuickJS compatibility; update this notice and RUNTIME-NOTICE.txt.
Run `tools/environment/Prepare-WebVideo.ps1`, then
`python -m unittest discover -s tests -p "test_web_video_*.py"` and
`python tools/Test-LicenseCatalog.py`. Check representative actual websites
separately: offline compatibility is not evidence of successful extraction.
Record results in prompt/HANDOVER_yyyyMMdd.md and commit the pin with its notices.
The next normal full build must pass the existing APK asset hash checks before
device validation. Reverting the pin and notices and rerunning preparation
restores the previous extractor; do not depend on build/ for a rollback copy.
