# Original VR screenshots and source clips

Compatible VR180, fisheye and 360° videos offer source screenshots and lossless clip selection through the camera action. Controls reuse the existing ray/trigger menu. Recording status, elapsed time and stop remain available after hiding playback controls; right-controller B stops the current selection before ordinary Back actions.

## Output contract

- Screenshots save a full-resolution decoded source frame as PNG under `Pictures/Thru3D/`. They preserve the full source stereo/panorama layout, rather than the headset view. There is a 40 Mi-pixel limit; unsupported/oversized captures fail explicitly. PNG is an 8-bit display decode, not preservation of original HDR bit depth.
- Clips save compressed video and the selected source audio under `Movies/Thru3D/`. The current pinned Android FFmpeg muxer configuration produces MKV. MP4 is conditional on actual muxer/codec support; changing the extension does not add that support. Audio Off creates a silent clip; supported external audio can be read separately.
- No eye-buffer image, menu, passthrough background, user color/effect processing, microphone, background music or narration is mixed into these source outputs. Clip playback speed remains the source speed.
- Start is aligned to a previous keyframe, with a bounded 10-second preroll rejection; end may retain a few dependency frames. Frame-exact boundaries are not promised. Seeking, changing audio/video, end or failure finishes the selected interval; saving publishes only complete successful files through pending MediaStore entries.
- `thru3d_mode` PNG/container metadata carries projection, stereo packing, eye order and fisheye FOV, not source names, URLs, accounts or viewing timestamps. Explicit saved per-file choices still take priority. Third-party players need not understand this field.

Flat video, photos, packed embedded-mask sources, unseekable/live streams, DRM and ISO are outside the stated capture scope. Source/host checks do not establish Android MediaStore, HDR screenshot color or every headset/provider's compatibility. Exported files are caller-created public media, independent of history-memory settings; no actual captures are part of this Git repository.

## Source and tests

`video_capture.gd`, `capture_overlay.gd` and `capture_mode.gd` manage selection, feedback and format restoration; `OriginalCapture.kt` handles independent read leases and MediaStore publication. `native/mpv/original_clip.cpp` and `original_clip_core.h` share the production packet-copy core with host integration tests.

The FFmpeg public headers in `native/mpv/include/ffmpeg` derive from the existing pinned source archive, with retained LGPL text and per-header hashes. `tools/environment/Prepare-CaptureHeaders.py --archive <pinned-archive>` verifies and reproduces the set, including the documented Android ARM64 header configuration; it does not update the runtime dependency. Keep the adjacent notice/catalog when reusing these headers.

Godot `test_video_capture.gd` and desktop OpenGL `render_video_capture.gd` use fake platform state. Kotlin `CaptureFormatTest` checks PNG metadata/CRC. On Linux/WSL, `tools/Test-OriginalClipHost.sh` requires `THRU3D_FFMPEG_SOURCE` pointing to the pinned FFmpeg source and builds disposable host output. `tools/Test-OriginalCapture.py prepare/execute/verify` uses synthetic signals and compares packet hashes, timing, metadata and clean decoding; execute runs on Linux with `/proc/self/fd` support. Do not substitute personal media for missing fixtures.

## 原始截图与片段导出

兼容VR180／鱼眼／360视频可截图或选择无损片段，沿用手柄射线／扳机；独立状态条提供时长和停止，右手B优先结束当前选段。PNG保存完整解码片源排布，不是头显视野录屏，不含UI／背景／效果，且不承诺HDR原始位深；当前Android锁定依赖导出MKV，复制视频与所选音轨，不混入麦克风、音乐或朗读。起止受关键帧及依赖帧影响。

输出分别进入Pictures/Thru3D与Movies/Thru3D，只发布完整成功文件；排布字段不记录原URL、账号或文件名。平面、照片、特殊嵌入遮罩、直播／不可定位、DRM及ISO不在承诺范围内。导出文件不随Git发布；源码／宿主验证不等于系统解码器、MediaStore、所有设备和网络来源均已验收。
