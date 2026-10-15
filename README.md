# Thru3D Media Player

[简体中文](README.zh-CN.md) · [Changelog](CHANGELOG.md) · [中文更新日志](CHANGELOG.zh-CN.md)

Standalone Android VR/MR media player for Meta Quest and PICO. Play videos and photos, explore media libraries, and combine supported content with passthrough and stereo effects directly on your headset.

Current source version: **0.9.2** (Android versionCode **23**). An experimental standard OpenXR Android export is also available.

Minimum compatibility targets are **Quest 2** and **PICO Neo3**. Source/build compatibility does not establish hardware performance or interaction acceptance on every device.

## Features

- Video and photo viewing: flat, 180° and 360° projections; mono and side-by-side stereo.
- Person matting and passthrough composition for supported 180° video projections.
- Depth-based 2D-to-3D viewing for flat mono videos and photos.
- Local Android document access, SMB, WebDAV, DLNA and media-server libraries; 115, Baidu, Aliyun Drive, Quark and OneDrive connections.
- Audio tracks, text subtitles and flat-video PGS bitmap subtitles; 0.25×–3× playback speed with pitch correction and per-file viewing preferences.
- Plex phone/computer pairing and original-file library playback.
- Dolby Vision Profile 5 color handling on compatible hardware; no blanket profile, certification or native HDR claim.
- Picture rotation, flat-screen distance/size/curvature and text subtitle sizing/position; subtitles remain upright when the picture rotates.
- Controller ray/trigger selection and hand interaction; English, Chinese and Japanese UI.
- Persistent timestamp bookmarks, source-frame previews for recent playback, and paged media navigation.
- Rendered hands/controllers and display-quality controls, including sharpness and flat-screen adjustments.
- VR-native account forms and in-app web login; speed-first and precise seek policies.
- Immersive photo presentation, pinch-drag navigation, adjacent-photo preload and cached 3D conversion; photo stereo strength is adjustable up to 200%.
- Media-server sections, filters, details, continuation pages and capability-dependent favorites; manual DLNA endpoints and exposed external subtitles.
- Photo distance/size controls and a separate 2–8× magnifier referenced to the displayed image; source-dependent file management.
- Efficient compositor-layer video/photo presentation and high-resolution menus on supported devices, with fallback for unsupported effects or low menu frame rates.
- Context-specific controller bindings, combinations, confirmed conflict swaps, interface movement and animated gesture guides.
- Remembered per-video audio/subtitle selections, five text subtitle styles and anchored immersive stereo subtitles.
- Double-click 3D/volume shortcuts, persistent volume/mute state and full-filename hover hints.
- Direct main-feature playback of supported unencrypted standard/MVC 3D Blu-ray ISOs, including compatible multi-clip titles, with audio tracks and seeking; see [Blu-ray scope](docs/BLURAY.md).
- Provider-dependent cloud keyword search, scope and media-type filters without background whole-drive scanning.
- Emby/Jellyfin poster walls, actor-related titles, detail artwork, multipart selection and home playback history.
- Individual slider resets, color-page reset, and Original/Warm/Cool/Custom color choices.
- List/icon directory browsing, per-server Emby/Jellyfin view/size preferences, full synopses and scrollable details.
- Compact/full library switching during playback with the control bar retained and grouped placement.
- Per-video subtitle synchronization (±10 s, 0.1 s steps), matching-filename auto-loading and flat-screen PGS size/position controls.
- Supported STRM link playback, remote loading stages/measured read speed and accessible error details.
- Independent supersampling/sharpness, fixed-distance grip dragging and same-hand thumbstick distance control.
- Efficient color adjustments on supported devices: compatible exposure, contrast and white balance retain compositor presentation; gamma/saturation options offer performance tooltips.
- Compact playback settings, color and stereo-view panels above the controls, with trigger-tap menu dismissal outside the panel.
- Available file size alongside playback position, and retained year/duration details on media-server cards with viewing status.

- External-subtitle recovery and automatic filename/interface-language selection, with manual/saved choices taking priority.
- Contextual B/Y Back navigation and right-controller-only library recovery; video triggers operate controls while grip moves the picture.
- Emby full titles, eligible single-movie-folder landscape artwork, portrait cast cards and compact server-supported sorting.
- Efficient compositor paths for supported immersive text/flat PGS subtitles, photo magnifiers/portraits/spatial photos and flat rotated video.

## Spatial media and photo layouts

- Native stereo HEIC/HEIF spatial photos and iPhone MV-HEVC spatial video playback; spatial video can use the supported people-passthrough path. Spatial-photo output is sRGB, not a native HDR claim.
- Side thumbnails, one-to-three-row Photo Wall and Memory Fragments, with asynchronous loading feedback, expanded-photo dragging and remembered layouts.
- Portrait passthrough for selected ordinary flat photos, with 0–200% stereo strength. Native stereo/panorama photos and overview grids are outside this portrait path.
- Session-scoped head following for flat videos, single photos/portraits and menus; an independent environment-passthrough footer control. No permanent spatial-anchor or full-wall head-lock claim.
- Stereo/left-view/right-view video display and per-video horizontal/vertical alignment. Both eyes display the selected logical view in single-view mode; it does not disable one panel or alter headset IPD.

[Source and controls guide](docs/SOURCE_GUIDE.md) · [Build](docs/BUILD.md) · [Licensing](docs/LICENSING.md)
