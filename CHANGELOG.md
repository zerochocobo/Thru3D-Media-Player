# Changelog

[简体中文](CHANGELOG.zh-CN.md)

Newest first, following product release milestones. Some development/source snapshots contained features before their product release. Original APK identifiers `0.2` and `0.4` are retained; `0.4` was also called `0.4.0` in release notes. Availability depends on device, server and media capabilities.

## 0.10.0 — 2026-10-16

This update expands Alpha passthrough controls, improves thumbstick seeking, panel placement and file management, and provides clearer playback errors and better compatibility.

- **Alpha edge controls**: Adjust Alpha Feather and Alpha Edge Shrink from playback or library settings to refine portrait outlines.
- **Alpha model-size selection**: Choose 256, 320, 384 or 512 with a remembered global preference to balance cutout detail and performance. First use of a size may take about a minute to prepare; the current size stays active meanwhile.
- **Updated Alpha frame-rate default**: New settings default to a 30 FPS limit, adjustable for your headset. Existing saved preferences are retained.
- **Preview thumbstick seeks before committing**: Default steps are 20 seconds on the left controller and 10 seconds on the right. Hold to accumulate, then return the stick to center to seek. Target-time feedback fades after the new picture appears.
- **Less intrusive buffering feedback**: With controls hidden, a small independent indicator shows loading stages, elapsed time and measured read speed without opening the playback bar. Visible controls use their existing status area.
- **More natural panel placement**: Playback, settings, subtitle, bookmark and library panels face the viewing position when opened or placed, making stacked panels easier to read. Improved menu-edge rendering.
- **Return directly to the library with B/Y**: Exit ordinary video playback and return to the library without opening the controls first. Popups, folders and active drags retain their contextual Back or cancel priority.
- **Improved controller combinations**: Added optional 180-degree turning for 360-degree media and previous/next-video actions. Grip and trigger modifiers work in either order, with fixes for blank-space grip captures blocking combinations.
- **Optional file-management mode**: List checkboxes support multi-select deletion, with preview and confirmation for file operations and renaming. Matching-basename companion files can be updated together; supported sources now include file/folder renaming through 115 Open.
- **Optimized presentation for more videos**: Compatible Dolby Vision Profile 5 and software-decoded videos can use efficient layer presentation, with associated subtitle support.
- **More stable 3D Blu-ray seeking**: Fixed picture corruption after seeking in some MVC titles and improved decoder recovery and multi-clip transitions.
- **Restored exact 2:1 detection**: Unspecified videos with an exact 2:1 aspect ratio default to VR180 side-by-side stereo. Explicit filename tags, media metadata and saved manual settings take precedence.
- **Clearer playback failures**: Errors automatically open a concise dialog with expandable details. Reopen it from the playback bar after dismissal, with more accurate network-source and decoder failure information.

## 0.9.2 — 2026-10-15

This update improves multi-clip Blu-ray playback, subtitle and photo rendering, controller navigation, external subtitles and Emby browsing.

- **Improved multi-clip 3D Blu-ray playback**: Added support for compatible multi-clip MVC Blu-ray ISOs, with better clip transitions, cross-clip seeking and end-of-title handling. Fixed failures when opening some titles.
- **More efficient subtitle rendering**: Optimized immersive VR subtitles and flat-screen PGS bitmap subtitles to reduce rendering overhead, while retaining existing position and size controls.
- **Improved photo viewing**: Sharper magnifier details and optimized portrait passthrough and native spatial-photo presentation in supported viewing modes.
- **Better portrait-video presentation**: Optimized supported flat videos with rotation metadata, maintaining the correct orientation with less rendering overhead.
- **Clearer trigger and grip controls**: Video triggers select controls and show/hide the playback bar, preventing accidental picture movement when dismissing it. Use grip to move the picture or reorient VR video. Photo dragging and hand interaction remain available.
- **More natural Back navigation**: B/Y first closes the current popup or returns to the parent folder before hiding playback controls. Improved library recovery when using only the right controller.
- **Keep the current file visible**: Reopening the playback browser locates the playing file, including after previous/next navigation, with better positioning across large lists and compact layouts.
- **Correct per-video effect memory**: 2D-to-3D is remembered separately for each video and defaults to Off for new files; photos retain their separate global preference. Manually enabled video portrait passthrough no longer carries over to the next opening; filename-based detection remains available.
- **Less intrusive thumbstick seeking**: Fixed the playback bar unexpectedly appearing during network-video seeking and subsequent buffering when controls were hidden.
- **Better external-subtitle recovery and selection**: Fixed missing external subtitles for some DLNA videos opened from recent playback. Matching filenames take priority, followed by a subtitle matching the interface language. Manual choices and saved Off settings take precedence.
- **Improved Emby browsing and details**: Lists prioritize full movie titles, with filenames in hover hints. Eligible single-movie folders can show landscape artwork; cast cards place portraits above names, with improved still-image layouts.
- **Compact sorting popup**: Choose server-supported sorting by date added, title, release date, duration or rating, with ascending/descending order and remembered preferences. The list stays in place while editing your choice; applying a new server sort reloads from the first page.

Compatibility notes: MVC retains the existing software decoder and requires compatible clip layouts; this is not hardware MVC support or a whole-disc compatibility guarantee. Rotation layers cover supported flat, uncurved mono video. Subtitle-layer improvements cover immersive text and flat PGS; ordinary flat text retains its existing path. Language fallback selects external subtitles only, after manual/saved choices; old DLNA history without server/object identity may require one opening from the original folder.

## 0.9.1 — 2026-10-14

This update improves color-adjustment performance, streamlines playback settings and menus, and keeps media-card information visible alongside viewing progress.

- **More efficient color adjustments**: On supported devices, compatible adjustments such as exposure, contrast and color temperature reduce rendering overhead for high-resolution video playback.
- **Compact playback settings**: Settings, color adjustments and stereo-view controls now open in small panels above the playback bar, keeping playback controls available. Settings opens on the Playback tab for easier access to color adjustments.
- **Color-adjustment performance hints**: Indicators beside settings such as gamma and saturation explain their potential GPU cost when pointed at, helping you choose settings for your headset.
- **Simpler menu controls**: Removed duplicate floating actions and the shared close-menu button. Point outside a menu and press the trigger to dismiss it; recenter remains on the playback bar.
- **File size stays visible after playback**: File icons can show available file size and playback position together, while retaining progress bars for easy resuming and comparison.
- **Richer media-server cards**: Movie cards retain available details such as year and total duration alongside playback progress or watched status.

## 0.9.0 — 2026-10-14

This update adds STRM playback and remote loading feedback, and improves interface movement, menu placement and picture-quality controls.

- Added compatible STRM link-file playback from local, SMB and cloud sources, retaining history, viewing preferences and sidecar-subtitle association with the original index file.
- Remote videos and photos show loading stages, elapsed time and measured read speed; improved compatibility for some HTTPS, Emby remote streams and network ISO inputs.
- Playback failures show their reasons and allow recovery to the full library. Cloud-folder failures offer sanitized underlying reasons and codes; diagnostic improvements do not establish universal account-access fixes.
- Grip dragging retains viewing distance; grip or trigger plus the same controller's vertical thumbstick moves supported panels or flat pictures nearer/farther. Placement memory is session-only.
- Standard menus stay upright, while head-following mode uses head tilt. Fixed unwanted roll and behind-you flips; app/system recentering restores default menu placement.
- Single-photo and side-thumbnail layouts keep their picture position across image changes with following off; explicit recentering restores the picture to the current view.
- The full playback library retains the control bar and moves with it. Emby/Jellyfin internal pages use consistent larger layouts, with direct source-sidebar access and clearer filter/server-option icons.
- Supersampling and sharpness independently offer Off/Normal/Quality. Display Quality becomes Render Scale, with explanatory hints and migration of earlier sharpness levels to distinguishable effects.

## 0.8.1 — 2026-10-14

This update improves file browsing and media selection during playback, upgrades library details, and adds per-video subtitle synchronization.

- Added list/icon browsing with remembered preferences, existing metadata and playback progress, and retained browsing positions.
- Added a compact browser above playback controls for browsing, sorting and switching media; it can expand into the full library while retaining playback state and browsing context.
- Added Emby/Jellyfin poster, landscape-thumbnail and small-image filename views, three item sizes and per-server display preferences.
- Improved detail layouts with full synopses, scrollable parts/cast/artwork and content-tag queries for related titles.
- Both grip buttons are reserved for interface/photo-magnifier movement while advanced combinations remain available. Fixed ray feedback and coplanar browser/control-bar movement.
- Added subtitle synchronization within ±10 seconds, 0.1-second fine adjustment and reset, saved per video. Positive values delay subtitles; negative values advance them.
- Track selection keeps the adjustment panel open and empty areas intercept clicks. Matching-filename auto-loading prioritizes SRT, then ASS; manual and saved choices take precedence.
- Added flat-screen PGS size and vertical-position controls with individual resets and original colors retained.
- Reduced unnecessary VR picture/subtitle rendering work and prevented brief frame-rate dips from prematurely disabling high-resolution menus.

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
