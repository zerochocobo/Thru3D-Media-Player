# Web video runtime

The application uses yt-dlp for local media discovery, and the Android Python and
QuickJS distribution from youtubedl-android. It does not use its download manager,
automatic updates, FFmpeg or aria2c packages.

- yt-dlp 2026.10.26: https://github.com/yt-dlp/yt-dlp/tree/2026.10.26
  (Unlicense; see LICENSE.yt-dlp). Its Python zip release includes its own
  dependency licensing files, including the EJS component where present.
- youtubedl-android 0.18.1: https://github.com/yausername/youtubedl-android
  (GPL-3.0; see LICENSE.youtubedl-android). Maven sources are available alongside
  the pinned artifact. WebVideoResolver uses its initialization API; our process
  environment follows the upstream YoutubeDL.kt layout. The execution wrapper is
  local, bounded, cancellable and does not print extractor output.
- Python: PSF license; QuickJS: MIT. Their license/source provenance and ABI/16 KiB
  compatibility must be included in the release dependency audit before shipping.

runtime.json pins the Python zip and its SHA-256. Build-Player downloads it to
build/web-video, verifies it, and stages it as an APK asset. No third-party account
credentials or browser cookies are included. This development integration does
not constitute a store submission or a completed distribution audit.
