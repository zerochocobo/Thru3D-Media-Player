# Changelog

[简体中文](CHANGELOG.zh-CN.md)

Newest first, following product release milestones. Some development/source snapshots contained features before their product release. Original APK identifiers `0.2` and `0.4` are retained; `0.4` was also called `0.4.0` in release notes. Availability depends on device, server and media capabilities.

## 0.8.0 — 2026-10-13

This update adds Blu-ray ISO playback and cloud-drive search, improves media-server browsing, and refines display adjustments and file navigation.

- **Blu-ray ISO playback**: Play compatible unencrypted standard and MVC 3D Blu-ray ISOs directly, without extracting or converting them first. Supports audio-track selection, pausing and seeking. See [Blu-ray scope](docs/BLURAY.md).
- **Improved cloud ISO playback**: Fixed some 115 ISOs failing to open or showing a blank screen, reduced repeated folder requests, improved network reading and seeking, and refined ISO detection for media-server sources.
- **Cloud-drive search**: Search by keyword and filter videos, photos or folders. Available scopes include the current folder, subfolders or the entire drive, depending on the provider, with paged results and access to their locations.
- **Upgraded Emby/Jellyfin browsing**: Added poster walls, multiple detail images and actor-related titles. Home screens show libraries and a horizontal Recently Opened row. Select multipart videos directly in their details, ordered by numeric markers such as cd1 and cd2.
- **Stereo alignment fixes**: Addressed disappearing pictures and reopening failures after alignment adjustments. Existing alignment settings remain usable, with invalid fields reset independently.
- **Better navigation and menu visibility**: Preserve page and scroll positions when returning to a parent folder, reduce some cloud-folder browsing stalls, restore missing filename brackets, and fix close-up portrait 3D pictures covering settings.
- **Individual reset controls**: Restore individual color, screen, subtitle, photo and stereo-alignment sliders. Color adjustments also support resetting the current page; resetting strength does not enable a disabled 3D effect.
- **Simplified color presets**: Keep Original, Warm, Cool and Custom, removing the redundant Daylight preset. Existing Daylight settings return to Original while retaining custom adjustments.

## 0.7.0 — 2026-10-13

This release collects improvements since 0.6.1, including the 0.7.0 Alpha features and subsequent fixes.

- **More efficient playback and photo viewing**: Reduced GPU overhead for ordinary video playback and improved display efficiency for supported 2D-to-3D content and large photos, reducing loading and switching stalls.
- **Clearer, more stable menus**: Improved text and icon sampling, added high-resolution menus on supported devices with automatic fallback when frame rates drop, and fixed menu-switching crashes and mirrored backgrounds.
- **Custom controls and gesture demonstrations**: Assign controller buttons and combinations by media context, restore defaults, and confirm swaps when bindings conflict. Animated guides demonstrate pinching and zooming. Video play/pause defaults to the right A button; menu exit controls remain available.
- **Configurable interface movement**: Bind a held controller input to move the current panel, the picture with its control bar, or all application panels. Placement is retained within the current session.
- **Multi-row Photo Wall**: Choose and remember one, two or three rows while retaining photo proportions and continuous groups. Multi-row walls remain centered around the view with a limit on downward placement.
- **Improved photo browsing and loading feedback**: Added white frosted loading sweeps and soft reveals. Expanded photos support dragging at a constant viewing distance, remembered headset-relative placement and closing with the right A button. Fixed overlapping thumbnails, unavailable adjustment sliders and seams at 3D photo edges.
- **Double-click shortcuts**: Click the 3D icon to adjust strength or double-click to toggle the effect while retaining its strength. Click the volume icon to adjust or double-click to mute/restore. Volume and mute state persist between launches, with a red muted indicator.
- **Text subtitle styles**: Choose from five text/outline color presets, expand a compact subtitle appearance section, and find global subtitle options under Video. PGS subtitles retain their source colors and layout.
- **Improved immersive stereo subtitles**: Updated per-eye projection for VR180, fisheye and other immersive modes, keeping subtitles anchored when you turn your head. Distance is adjustable from 0.1 to 5 meters; near-field comfort depends on the headset and viewing conditions.
- **Per-video subtitle and audio preferences**: Keep selections when switching between person passthrough, 2D-to-3D and ordinary playback, and restore them when reopening the same video, including subtitles off and automatic audio selection.
- **Playback fixes**: Addressed missing pictures in some rotated, portrait and fisheye videos, blanking during seeking, opening-time restarts, transient Dolby Vision display errors and paused 3D updates. Undoing an opening-time display setting can restore the more efficient render path. The FPS overlay can identify the active path for troubleshooting.
- **Library and subtitle compatibility**: Hover over truncated names to read the full filename; connection/account management stays at the appropriate root. Improved DLNA external-subtitle retention when metadata is incomplete or playback addresses change.

## 0.6.1 — 2026-10-11

- Fixed some videos streamed from Thru3D Media Server stopping after a few seconds, improving continuous playback and seeking.
- Improved connection compatibility for Thru3D Media Server live transcoded streams.
- Videos with built-in person masks now activate the passthrough background when the video appears, avoiding a premature switch to only your surroundings during loading.

## 0.6.0 — 2026-10-11

- Added native stereo HEIC/HEIF spatial photos and iPhone MOV/MV-HEVC spatial-video decoding, including supported person-Alpha passthrough. Output is sRGB; compatibility and performance depend on media and device.
- Added side thumbnails, grouped Photo Wall and randomized Memory Fragments, with hand-driven overview browsing, expand/return placement and remembered layouts.
- Improved large-photo loading feedback, asynchronous switching and stable photo placement.
- Added one-button 3D/person preparation for selected ordinary flat photos, with 0%–200% depth strength and synchronized color/mask updates. Native stereo, panoramas and photo overviews retain their own presentation.
- Added session-scoped head following for flat video, individual/portrait photos and menus; it starts disabled at launch.
- Added a temporary environment-passthrough footer control, independent of media mode; person-Alpha playback keeps passthrough enabled.
- Added stereo/left-eye/right-eye video views and saved per-video horizontal/vertical alignment corrections (±5%, 0.05% steps). Monocular views display the selected logical eye to both headset eyes.
- Simplified menu closing/back controls, stopped treating every 2:1 video as VR180, and locked native spatial-video format to prevent repeated depth conversion.
- Updated portable signing validation and public-source export boundaries: caller-owned keys and identity metadata remain private, missing/mismatched keys stop packaging, and export state uses persistent storage.

## 0.5.2 — 2026-10-11

- Added live 10–40 FPS person-Alpha processing controls (default 20) and an optional video/engine FPS overlay; actual throughput depends on device, media and load.
- Added device-dependent automatic quality defaults while preserving saved manual overrides.
- Fixed H.264 startup stalls/exits and cleaned stray photo-3D edges around hair, faces and arms.
- Raised photo 3D strength to 200% and added animated preparation feedback.
- Fixed DLNA directories with external subtitle metadata and 115 directory failures caused by duplicate names; ambiguous names now request renaming.

## 0.5.1 — 2026-10-11

- Added Plex phone/computer pairing, library browsing and original-file playback, with improved LAN connection selection.
- Corrected Dolby Vision Profile 5 green-tinted playback on compatible hardware; no blanket profile support, Dolby certification or native HDR claim.
- Added embedded PGS bitmap subtitles for flat-screen video, including switching while paused. Immersive projections continue to use text subtitles.
- Added 0.25×–3× playback speed, audio pitch correction and one-button return to 1×.
- Reorganized Screen/Playback/Info settings. Added flat-screen distance, size and curvature controls, and −90°–90° picture rotation while subtitles stay upright.
- Added 50%–200% text subtitle sizing, independent flat-video vertical position and filename guidance. Text controls do not change PGS layout.
- Improved modification-time sorting with folders first for local/SMB/cloud libraries, and ascending/descending DLNA name sorting.
- Fixed screen percentages and slider positions, straightened settings panels, and placed conditional speed/rotation resets beside their sliders.

## 0.5.0 — 2026-10-10

- Upgraded media-server sections, Continue Watching, Recently Added, categories, details, continuous loading and restored navigation/scroll state.
- Added capability-dependent favorites: server-backed where supported, otherwise local; no playback-progress writeback promise.
- Added Aliyun Drive, Quark and remote WebDAV connections. The 115 Open display name became 115.
- Added manual DLNA addresses and server-exposed external subtitles.
- Added photo adjustment controls and a separate 2×–8× magnifier referenced to actual displayed image size; flat-photo distance is 0.3–10 m and size 40%–600%.
- Fixed immersive opening alignment, stale mode locks and Quest passthrough clarity while retaining selected display quality.
- Improved embedded web-login scaling/input and reauthentication entry points.
- Removed unused JCIFS HTTP adapters and strengthened package checks while retaining required HTTP media compatibility.

## 0.4.2 — 2026-10-10

- Added horizontal/vertical immersive text subtitles with improved first-character alignment, multiline/bilingual layouts and long-line wrapping.
- Added live directional placement and extended subtitle distance to 0.1–10 m.
- Improved cloud-folder external-subtitle matching, including language suffixes and paged directories.
- Added text subtitles exposed by supported Emby, Jellyfin, Stash and XBVR servers.
- Extended external dubbing/audio discovery to supported cloud/media-server sources, including `movie.si.mix.m4a` naming.

## 0.4.1 — 2026-10-09

- Rebuilt the QUEST release as application version 0.4.1 / versionCode 8.
- No separate user-facing feature additions were recorded for this packaging revision; it retains the 0.4 feature set.

## 0.4 — 2026-10-09

Also called **0.4.0** in release notes; actual APK versionName was **0.4**.

- Improved photo-to-3D processing reuse, landscape/portrait depth and stable placement after zoom/reset.
- Added half-width SBS and half-height top-bottom stereo layouts, improved format detection and corrected some fisheye proportions.
- Simplified mode controls and moved eye swapping into playback settings.
- Added 115 Open/OneDrive authorization and switched Baidu sign-in to authorization. Existing Baidu accounts need reauthorization; saved legacy 115 accounts remain compatible.
- Added persistent name/modification-time/size sorting for local, SMB and cloud libraries.
- Added optional, confirmation-based file management, disabled by default: supported local/SMB deletion and 115 Open recycle-bin operations.
- Added bundled local/SMB video/subtitle/dubbing renaming, preserving history/bookmark links after complete success.
- Added removable-storage shortcuts, volume-change refresh and a control to stop app reads/preloading; this is not system-level safe eject.
- Added live subtitle distance/position controls, improved long track lists and refreshed About links.

## 0.3.1 — 2026-10-09

- Stabilized VR subtitles relative to video and improved PICO controller compatibility.
- Improved older-Android storage authorization, status/error feedback and directory refresh after permission changes.
- Distinguished charging from connected-but-not-charging power; showed red battery state below 20% when not charging.
- Moved 115 SMS send/verify actions above the keyboard.
- Enlarged launcher artwork while preserving the Thru3D / Media Player wordmark.

## 0.3.0 — 2026-10-09

- Added persistent timestamp bookmarks with timeline/list navigation, deletion and undo; no ratings or editing.
- Added larger immersive photo presentation, softer edges and slide/fade transitions.
- Added single-hand pinch-drag photo navigation and two-hand zoom; capped photo 3D strength at 100%, independently of video.
- Improved portrait depth, edge completion, adjacent-photo preload, looping and conversion-cache reuse/cleanup.
- Moved cloud/media-server forms and web login into VR and improved input layout/hand response.
- Added faster seeking with separate bookmark precision preferences and audio-track selection on the control bar.
- Allowed thumbstick playback shortcuts with ordinary video controls while retaining list/pointer-capture isolation.
- Improved subtitle placement/distance, Jellyfin connections, settings and near-hand/menu/background rendering.

## 0.2.1 — 2026-10-08

- Retained the displayed frame while seeking and corrected timeline targets jumping back before completion.
- Added recent-playback source-frame previews, poster fallback, bounded preview caches and paged history.
- Added controller/hand visual models and improved input/profile handling.
- Added separate QUEST/PICO and experimental standard OpenXR exports while retaining Quest 2 compatibility.

## 0.2 — 2026-10-07

- Upgraded SMB2/3 compatibility, encryption and direct share/subfolder access without enabling SMB1.
- Added global display-quality presets and live sharpness for videos/photos.
- Reorganized settings and added real restart/exit controls.
- Improved PICO panel/input integration and controller fallbacks, keeping accounts/media links compatible.

## 0.1.0 — 2026-10-07

- Initial standalone Android VR/MR video/photo test release.
- Added flat/180°/360° and stereo viewing, supported person-matting passthrough and depth-based 2D-to-3D rendering.
- Provided local/LAN/media-library access, audio tracks, subtitles and controller-ray/hand interaction.
- Supplied separate Quest/PICO builds with multilingual UI and dependency notices.
