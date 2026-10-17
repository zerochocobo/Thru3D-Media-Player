# Architecture

## Application and interaction

`app/godot/scenes/main.tscn` and `scripts/main.gd` own application state. Godot OpenXR supplies tracking and the vendor-specific passthrough interface. GDScript menus use controller rays/triggers and hand pointing/pinching. Libraries, settings, list popups and photo menus reserve thumbsticks for scrolling. The ordinary video control bar permits seek, volume and immersive zoom shortcuts. Pointer capture suppresses shortcuts; leaving a list or ending capture requires the stick to return to center before reactivation.

Display geometry separates flat/180°/360° projection from mono/SBS layout and eye order. Menu pages, per-file preferences and localization are independent of the Android media backend. The desktop path is a development preview and mock backend, not an equivalent Android/XR playback implementation.

The application includes persistent timestamp-only bookmarks (`bookmark_store`, `bookmark_menu`, `timeline_markers`), paged recent-file previews, cloud account/pagination handling, and input visuals. `input_visuals.gd` uses runtime render models when available and licensed glTF hand fallbacks. Seek keeps a presented frame until the target frame arrives; `seek_policy.gd` routes speed-first and precise positioning. No ratings, stars or bookmark editing are exposed.

Photo presentation uses immersive screen geometry, adjacent-image preloading and a separate stereo cache. Flat-photo navigation uses a single-hand horizontal pinch drag followed by release; two-hand pinch zoom remains available. Photo stereo strength supports 0–200%, independently of video strength. Selected ordinary flat photos can prepare depth and person matting, with matched color/mask updates before switching the presented pair. `projected_subtitles.gd` and the shader include implement subtitles in the video projection.

Controller configuration is shared between the Controls UI and input dispatch (`controller_bindings.gd`). It preserves menu ray/trigger selection and exit controls, confirms conflicting swaps, and supports held interface movement and same-hand grip → trigger → target combinations. `file_track_memory.gd` persists explicit per-file audio/subtitle preferences and restores them after playback-core changes.

## Android boundary

`QuestPlayerPlugin.kt` exposes Godot-callable methods and owns Android media selection, libraries and lifecycle. Document grants, file descriptors and HTTP/SMB/cloud sources are managed in Kotlin. Authentication data stays in application-private storage; no account credentials belong in source control.

`LocalStoragePermissions` separates Android 10 legacy/read-permission access from Android 11+ all-files settings, with supported settings fallbacks and directory refresh. `DeviceBatteryStatus` interprets the sticky battery snapshot separately from cable connection; connected power alone does not mean charging.

The plugin contains older controlled MediaCodec/Media3 diagnostic paths. Normal video playback uses `MpvVideoBridge` and the native mpv source extension. Their presence in source does not mean that all paths execute during ordinary playback.

Account and server forms are rendered by `account_panel.gd` inside the VR library.
`AccountManager` owns transient authentication state and cancelled-request guards.
Web authentication uses `InAppWebLogin` to transfer in-memory WebView frames and
ray/keyboard events through the same host Activity. It does not launch account
Activities or the PICO 2D shell. Pause keeps the current workflow; an explicit
close cancels it. The global About page contains the license index and reader.
These bridges still require device-specific website/input validation.

## Rendering and inference

`native/mpv/mpv_source.cpp` connects libmpv's source-frame extension to JNI. `native/render-bridge` owns GPU texture/buffer operations. Frame PTS, generations and fences prevent mismatching image/alpha, showing stale frames after seek, or reusing a texture before GPU ownership is released.

`native/xr-layer` and `video_layer.gd` submit supported decoder Surfaces or prepared stereo/photo images directly to OpenXR compositor layers. Unsupported projections or matting configurations, non-compatible color effects and decoder formats use the existing rendering path. A minimal C-ABI GDExtension registers the OpenXR color-scale/bias extension before instance creation; supported compatible exposure, contrast, white balance and RGB gain/offset use compositor terms. Non-default gamma/saturation require the shader path. The linear-light fit does not promise identical pixels or fixed performance across all media/devices. Photos upload full-resolution images incrementally; selected photo effects can require the full shader path. `menu_composition.gd` groups menus into fixed-size planar layers, redraws when content changes and falls back when its frame-rate watchdog fires. The Khronos header sources and notices are retained under `third_party/openxr`.

Immersive text subtitles intersect each physical eye's viewing ray with a shared video-local plane, rather than using a single-eye longitude offset. The current configurable distance is 0.1–5 m; source tests do not establish near-field headset comfort.

The normal matting backend uses MNN OpenCL with four recurrent states for each eye. ROI decisions are in Kotlin's `RoiController`; the default source snapshot uses the internal 320×320 fast profile. The normal UI exposes a remembered global 256/320/384/512 inference-size choice (default 320). A cold size can take about a minute to prepare while the current size stays active. This does not allow arbitrary replacement weights. ncnn/reference paths are retained for dedicated diagnostics; normal playback has no automatic CPU fallback.

The independent depth backend processes flat mono videos/photos using Depth Anything V2 Small. `depth_stabilizer` limits temporal variation before Godot renders depth-based stereo. Depth updates and display frames have distinct timing; a rendered-frame rate is not an inference rate.

## Build boundaries

The Godot export plugin references the separately built Kotlin AAR and Maven dependencies. The matching Godot template provides one engine. Each Android export preset enables one vendor loader. Models, SDK/addon binaries and native libraries are prepared outside Git and checked during packaging.

The public snapshot removes private store-capture automation from the application startup path. It retains runtime icons, the licensed background, synthetic fixtures and production behavior. Source-only tests do not establish headset passthrough quality, tracking or sustained thermal performance.

## Cloud providers

Existing 115 and Baidu clients retain encrypted account records. The embedded OpenList JNI core supplies additional provider connections, including 115 Open, OneDrive, Aliyun Drive and Quark. Only the capability-protected loopback media router listens on HTTP. Authorization stays in the same Activity's VR web panel; provider-specific callbacks are validated against the active session/state before importing credentials and checking directory access. Quark uses the FnNAS broker's nonce-bound callback exchange. No OpenList frontend or separate Android account window is used. Real-account and minimum-headset validation remains separate from source publication.

Media-server browsing separates home sections, loaded pages, filter/category state and detail navigation. Favorites use server support where available and a local fallback otherwise. Source policies and native/Go bridges provide supported rename/delete operations without assuming every backend permits writes. Photo magnification maps the displayed image's local projected size to a separate inspection window; it does not enlarge the underlying full-image shader.

## Cloud search and media-server browsing

cloud_search.gd and CloudDirectorySearch bridge bounded search sessions into the OpenList Go core. Current-folder filtering uses directory metadata; verified native provider routes add supported broader scopes. Capability responses determine the UI scope, with cancellation and account/query isolation. This is not a persistent whole-drive index.

media_server_gallery.gd supports Emby/Jellyfin library cards, detail artwork, actor queries and multipart selection. Part ordering uses explicit numeric markers, while each part retains its own media URI, metadata and playback preferences. ISO routing preserves source filename/container hints through local proxies. Returning to a parent restores directory pagination and scroll state.

The Blu-ray adapter and its pinned decoder/filesystem dependencies are described in BLURAY.md. Debug-only text-band menu experiments do not change the Release menu policy or establish a new released bandwidth improvement.

## Browser layout, placement and remote feedback

library_presentation.gd normalizes available metadata and existing playback records. Grid/list preference and stable entry anchors are shared across sources; this does not introduce a persistent whole-library watched index. Emby/Jellyfin view and size preferences are server-scoped. During playback, both compact and full browser layouts remain children of the current control bar, preserving its visible controls and grouped movement.

interface_move.gd uses head-centered fixed-distance dragging with explicit same-hand thumbstick depth changes. Standard menus use gravity and horizontal heading; following uses full head pose. Recenter resets menu offsets; photo reading frames retain placement across ordinary image changes.

file_subtitle_timing.gd stores per-video timing separately from appearance, guarded against stale cross-source commits. The Android/native bridge applies subtitle delay before accepting updated text/bitmap snapshots. PGS display remains flat-screen only.

StrmFile/StrmHttp resolve bounded single-address indexes while retaining original-file identity. RemoteMediaHttp and MpvTlsTrust preserve TLS checks and source/header boundaries. TransferMeter and media_loading.gd publish actual read progress; playback_errors.gd and cloud_browse_error.gd expose sanitized failure details and browse recovery. See STRM_SUPPORT.md and MEDIA_LOADING.md for user-facing scope.

Video settings, grading and stereo controls use compact popups above the playback bar; photo settings retain the full panel. Menu backing surfaces intercept rays, while a trigger tap outside dismisses menus. library_presentation.gd and media_server_browser.gd preserve existing size/year/duration fields alongside viewing progress, without inventing missing metadata or expanding recent-playback storage.

## Navigation, subtitle and compositor behavior

Video triggers operate controls and show/hide transport; grip moves flat pictures or turns immersive video. Contextual B/Y routing closes the innermost popup, navigates to a parent directory, then closes ordinary video playback and returns to the library; photos retain their previous Back behavior. Library recovery also works with the right controller. Reopening a browser locates the playing item within its available context, without a background scan. Video depth preferences are file-scoped; photo depth preferences remain separate.

DLNA stores bounded playback references separately from its browsing cache, retaining object/server identity for recent-playback subtitle rediscovery. Subtitle snapshots preserve original external filenames; automatic selection tries a matching basename, then an interface-language external subtitle, while explicit/saved selections (including Off) take priority. Missing identity in already-evicted old history cannot be reconstructed from a media URL.

Supported immersive text and flat PGS use compositor layers; flat ordinary text keeps its current path. Rotation layers are limited to compatible uncurved flat mono pictures. Photo magnifier, portrait-mask and native stereo-photo paths use layers when their mode/runtime supports them; these source changes do not prove every device's performance.

Emby title presentation is distinct from filename hover hints. Eligible visible folders may borrow horizontal artwork only from a unique direct movie/video child, using bounded requests and caching. Cast/still layouts preserve aspect ratio. Sort popup editing leaves the background in place; applying a supported server sort reloads page one. Multi-clip MVC remains software decoding with compatible stream layouts as described in BLURAY.md.

## Passive feedback, panel placement and file operations

seek_feedback.gd owns a source/session-scoped thumbstick preview; return-to-center submits it, and only the matching presented frame completes feedback. seek_overlay.gd and playback_status_overlay.gd keep seek/buffering status independent of transport visibility. Panel layout uses captured viewer references and per-panel tangent planes rather than continuous implicit head following.

Structured playback failures retain sanitized upstream/native causes in a concise dialog with expandable details. File-management selection and guarded rename/delete operations remain opt-in and source-dependent; uncertain writes are verified instead of repeated. Compatible DV Profile 5 and software-frame picture-layer presentation is distinct from Alpha's GPU-copy pipeline; the updated Alpha presentation is included in the 0.10.0 Release scope. No new MVC hardware decoder, universal provider-access fix or upscaler is implied by these changes.

The updated Alpha compositor path is enabled for Release. GDScript requires both platform permission and XR_FB_composition_layer_alpha_blend support before requesting the layer; unsupported configurations retain eye-buffer Alpha. Debug comparison properties do not disable the Release default. This capability fallback is separate from the inference backend and does not imply a CPU inference fallback or universal performance guarantees.

The 0.11.1 source adds per-subtitle timing and same-folder choices, account-scoped cloud page/parent identity caches, and verified 115 management lookups. The subtitle-narration UI and Android gates remain disabled, and the build excludes its runtime and resources. See the source guide for released feature scope.

The global music transport shares one playback state across home/photo menus, imports complete private audio copies and pauses for video. `video_queue_pages.gd` provides bounded source-supported continuation. The narration source remains retained for development, while `Assert-NarrationExcluded.ps1` enforces package exclusion. Built-in music recordings are not part of the public source snapshot.
