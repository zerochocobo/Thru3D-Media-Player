# Immersive video screenshots and live clips

Compatible VR180, fisheye and 360° videos offer a camera action through the existing ray/trigger menu. Recording status, elapsed time and stop remain accessible after hiding playback controls; right-controller B stops recording before ordinary Back actions.

## Output contract

- Screenshots independently decode a full-resolution source frame to PNG under `Pictures/Thru3D/`. They preserve the source stereo/panorama layout, without menus or passthrough backgrounds. From 0.13.2, supported screenshots also compose the current video/image PiP windows in the original projection/stereo layout; this is separate from live clip recording. The limit is 40 Mi-pixels. PNG is an 8-bit display decode, without preservation of original HDR bit depth.
- Recording requires **1× playback speed**. Compressed video packets retain original resolution, codec and available HDR metadata. The current export container is MKV under `Movies/Thru3D/`.
- Clip audio is the **actually presented application mix**, stored as 48 kHz stereo float32 PCM: original/external audio, volume/mute and dialogue processing, narration, ducking and simultaneously playing app music. Audio Off can still leave audible narration/music. Microphone, other apps and system UI sounds are excluded. Recording does not change playback settings or synthesize unheard speech.
- Recording observes playback packets and presented audio. It does not open another source reader or resolve another cloud URL. Stop exports the locally staged data, including when the original source is unavailable. The older independent-reader clip API remains in source for compatibility; the camera uses the live path.
- Start includes the preceding keyframe within a bounded 10-second/64 MiB GOP window; missing eligible data fails explicitly. End can retain video dependency frames. Frame-exact boundaries are not promised.
- Seeking, audio/video changes, speed changes, end, failure or an internal decoder reopen finish the clip. Pausing adds no recording time and does not automatically resume playback. Closing the video normally submits the staged export; process death has no recovery guarantee.
- Pending MediaStore entries publish only complete successful exports. `thru3d_mode` metadata preserves projection, stereo packing, eye order and fisheye FOV, without source names, URLs, accounts or viewing timestamps. Saved per-file choices retain priority; other players may ignore this field.

Flat video, photos, embedded-mask sources, unseekable/live streams, DRM and ISO are outside the stated capture scope. Exported media is independent of history-memory settings; actual recordings are excluded from this repository. Host tests do not establish Android MediaStore, hardware audio timestamps, HDR screenshot color or every headset/provider's compatibility.

## Source and build

Godot `video_capture.gd`, `capture_overlay.gd` and `capture_mode.gd` manage controls and layout metadata. Android `OriginalCapture.kt` handles screenshots/publication; `LiveClipCapture.kt`, `HeardPcm.kt` and `LiveCaptureNative.kt` connect live recording. Native production code and host fixtures are under `native/mpv/live/`.

The mpv playback observer requires `native/mpv/patches/0004-mpv-live-capture.patch`, its manifest, `quest_capture_client.c.inc` and `include/mpv/quest_capture.h`. Rebuild the pinned source using the preparation workflow and export a matching receipt. Upstream version pins remain fixed; the source workflow also applies `0005-mpv-aaudio-clock.patch` for seek recovery and recording watermarks when hardware timestamps are unavailable. Old prebuilt libraries without these patches are insufficient.

FFmpeg headers in `native/mpv/include/ffmpeg` retain their adjacent LGPL text and per-header catalog. `tools/environment/Prepare-CaptureHeaders.py --archive <pinned-archive>` reproduces the set. Linux/WSL `tools/Test-LiveCaptureHost.sh` requires `THRU3D_FFMPEG_SOURCE` pointing to the pinned source; it builds disposable host libraries, exercises production audio timing/mixing and stages synthetic clips. `python tools/Test-LiveCapture.py prepare` creates synthetic input; `verify` compares original video packet/decoded-frame hashes, local export without the source, presented PCM and timing. The older `Test-OriginalCapture.py` also tests the retained independent-reader API.

## 中文说明

兼容沉浸视频支持原始排布PNG截图，以及1倍速现场片段录制。录像保留原视频压缩包，音频记录应用实际播放的原声／外挂音轨、朗读和音乐，包含音量、静音及混音处理，不录麦克风或其他应用。截图仍是8位显示解码，不承诺原始HDR位深。

录制复用播放数据，停止后从本地暂存导出MKV，不重新读取片源。起点受关键帧窗口限制；跳转、切音轨／视频、改速或解码器重开会结束片段。只发布完整成功文件；实际录音不随源码公开。宿主测试不等于所有头显、MediaStore及硬件音频时序均已验收。

PiP still composition is in `native/mpv/pip_screenshot_core.h`, with synthetic host pixels in `tools/Test-PipScreenshot.py`. This does not turn the headset view into the source screenshot or add PiP composition to the clip contract.
