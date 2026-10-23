# Changelog

[简体中文](CHANGELOG.zh-CN.md)

Newest first, following product release milestones. Some development/source snapshots contained features before their product release. Original APK identifiers `0.2` and `0.4` are retained; `0.4` was also called `0.4.0` in release notes. Availability depends on device, server and media capabilities.

## 0.13.2 — 2026-10-23

- Unify bookmarks and A–B repeat management, with bookmark-based endpoints, clickable seek times, per-video storage and playback controls.
- Add Blu-ray ISO title selection with separate main-feature/extra resume handling. Supported non-3D HDMV menus offer ray selection and a sharp dedicated toolbar, menu return and language carry-over. BD-J menus are identified explicitly; Java menu execution is unsupported.
- Read ZIP/CBZ, RAR/CBR and 7z comics as folders with thumbnails/navigation memory, compatible encryption, password entry and a private password book. Solid archives and some codecs are unsupported; remote sources need bounded random reads. Provider-side extraction is not used.
- Include current video/image PiP windows in supported original-format VR screenshots while retaining source projection/stereo packing. Screenshot and clip capabilities remain separately documented.
- Refine inward PiP feathering, pinch dragging, initial placement and remembered image-picker directories; remove the unrelated puzzle entry from that picker.
- Make Grand cinema (Test) available in Debug and Release, with automatic/manual dual baked lighting and movement. Hold right A to aim, release to teleport, and use trigger for menus. Improve stairs/landings, footwells, fixture depth and restored control placement. This source release supplies the generation pipeline; scene/model assets are prepared separately.
- Fix local Quest delete/rename using search-only ancestor directory handles, retaining no-follow, no-replace and real write-permission enforcement.
- Improve ISO/range caching, coalesce rapid comic page requests and fix archive address reuse; refine disc-menu toolbar and tooltip clarity.

## 0.13.1 — 2026-10-22

- Improve PICO controller visuals: prefer runtime-provided geometry, then use interaction-profile-specific Neo3, PICO 4-family or 4 Ultra fallbacks with existing trigger/grip/stick/button animation.
- Keep controller feedback visible when runtime geometry is unavailable. OpenXR still owns poses and input mappings; this is not hardware acceptance on every PICO model.
- Retain joint-based ray/pinch fallback code and upstream notices. The final PICO interaction profile follows the current compatibility policy; this does not claim universal PICO hand-tracking enablement.

## 0.13.0 — 2026-10-22

- Add up to three picture-in-picture windows sharing the current video frame, with region selection, 1–8× zoom, movement/distance, window shapes and individual closing. Zoom is remembered per numbered window.
- Allow a window to show a static image through the existing source picker, with image scaling and return to video mode. A bounded asynchronous loader releases resources on close/replacement.
- Improve supported compositor layers, the shared atlas and transparent/fisheye projection caches. Refine stereo zoom disparity, upright placement and main-video-first quality budgeting; performance remains device/content dependent.
- Resume directory browsing per source/account, directory and All/Video/Photo filter. The setting is enabled by default; disabling it starts ordinary re-entry at the top while explicit parent navigation retains its context.
- Directory positions follow playback-history privacy: All can survive restart, Local Only keeps network positions in memory, and None keeps all positions only for the current run. Clearing history clears positions; private-session positions are never backfilled after recording is enabled.
- Remember directory sorting, fix 115 folder-first ordering and improve bounded cloud paging/parent return. Restoring a position does not trigger an automatic full-directory crawl.
- Improve library ray feedback, Emby favorites/artwork and crisp filenames on translucent controls. Still-image navigation yields to playback shortcuts while a video session exists.
- Fix routing of the control-bar watch toggle and refine image-window controls, corner scaling, source-change cleanup and closing behavior.
- Rebuild the experimental auditorium as a locally generated baked hall. Entry, loading and actions remain Debug-only; generated scene models and textures are excluded from this source release.

## 0.12.7 — 2026-10-21

- Add a hand-tracked wrist watch with time, battery and playback progress. Touch the face for projected playback/timeline/subtitle controls; toggle it from the video control bar.
- Add provider-aware cloud page sizes and an explicit load-all option, remembered per account. Loading remains bounded by provider capabilities and cancellation; it is not a background scan.
- Remember video and photo 2D-to-3D strengths separately across files while retaining per-file mode enablement and native-stereo source settings.
- Add one controlled recovery attempt when playback stops advancing unexpectedly, without repeated player restart loops.
- Remove the redundant capture-entry tooltip and refine stick recenter submission and menu input isolation.

## 0.12.6 — 2026-10-21

Playback controls can now be locked in space and use adjustable panel transparency. Compatible 180° photos/screenshots can be used as front-hemisphere backgrounds, and Emby details can show server-provided artwork with optional rotation.

- Add playback refresh choices: up to 120 Hz, up to 90 Hz (default) and 72 Hz power saving, subject to runtime support and playback mode.
- Fix repeated seeks leaving video frozen while audio continues, including multiple paused timeline drags; add the pinned AAudio clock recovery patch.
- Reduce repeated buffering for affected poorly interleaved MP4 files on SMB using the bounded playback view.
- Fix stale preview buttons/sliders while scrolling cloud audio import folders.
- Improve long-title tooltips, stationary menu stability and idle rendering overhead.
- Improve compatible fisheye compositor presentation and refresh switching. AI passthrough and depth conversion retain the 72 Hz policy to limit additional load; this is not a universal performance claim.

## 0.12.5 — 2026-10-21

This update fixes missing cloud subtitles and external audio, restores bounded provider paging, and improves AI passthrough initialization.

- Restore same-folder SRT discovery and manual selection on affected 115, Quark and other cloud directories when sorting by name.
- Preserve raw provider metadata so M4A external audio tracks are recognized and loaded.
- Restore provider-supported sorting and paging instead of scanning an entire directory just to sort it. Name order follows each provider's returned results.
- Give the subtitle picker its own page offset and restore the media browsing position when returning.
- Keep unsupported optional GPU optimizations from failing the entire AI passthrough initialization.
- Classify AI failures separately from network/media reading failures and provide clearer recovery guidance.

## 0.12.4 — 2026-10-20

This update adds more image formats, subtitle browsing across folders, and live audio for VR recordings, while improving photo browsing, subtitle recovery, and playback of affected videos on 115.

- **TIFF, HDR and EXR image support**: Open images and large panoramas in these formats from local storage, SMB shares and cloud drives.
- **Browse for subtitles across folders**: Use the folder icon in the subtitle panel to choose subtitles from other local, SMB or cloud folders. The picker remembers your last location.
- **Live audio for VR recordings**: Record compatible VR videos at 1× speed while preserving the original video quality and capturing the audio actually played by the app, including original audio, subtitle narration and background music. Also fixed cases of popping and gaps in recorded audio.
- **New Morning Sky background and custom-background deletion**: Enjoy an 8K sky with adjustable orientation and brightness. Remove a custom background without deleting the original image.
- **Easier access to file management**: A locked entry now leads directly to the relevant setting when file management is disabled. Returning restores your browsing position.
- **More consistent browsing order**: File lists, photo walls and previous/next navigation follow a consistent order. Improved cloud-folder paging and returning to the file you were viewing.
- **More stable photo galleries**: Reduced resource usage in photo walls, memory fragments and large-image switching, improving reliability when browsing comics and photo collections.
- **Static stereo by default for photo 2D-to-3D**: First-time use now starts with static 3D. Spatial mode remains available, and saved preferences are retained.
- **Smoother custom panorama backgrounds**: Compatible 360° PNG screenshots can now be used as backgrounds. Fixed an unavailable close button after setting a background and delayed brightness updates while menus were open.
- **More reliable subtitle loading and recovery**: Improved automatic subtitle selection on media servers and subtitle recovery from cloud playback history. Fixed subtitles and narration turning off unexpectedly after switching to person passthrough.
- **Less repeated buffering with affected 115 videos**: Improved reading of certain MP4 files that repeatedly buffered after playback began, helping continuous playback and recovery after seeking.
- **Clearer voice-cloning controls**: Sample tracks have clearer labels, with selection available for multiple tracks. The lower close button now closes the cloning panel first while it is open.
- **Fixed controllers, hands and pointing rays disappearing during photo viewing**: Restored their visibility while viewing photos, making navigation, zooming and pointing easier.
- **Interface refinements**: Fixed background leakage and flickering around tooltips. Full filenames appear on hover only when truncated, and music settings have moved to the upper-right corner.

## 0.12.3 — 2026-10-20

This update adds original VR screenshots and lossless clip exports, fixes voice cloning from 115 and DLNA sources, and improves network recovery and menu presentation.

- **Original VR screenshots**: Capture compatible VR180, fisheye and 360° videos during playback or while paused. Save full-resolution source images as PNG files with stereo-layout information retained.
- **Lossless clip exports**: Save a selected video segment as MKV, preserving the original video quality and selected audio track. Clip boundaries may vary slightly with keyframe placement.
- **Persistent recording indicators**: Recording status, elapsed time and a stop control remain visible when playback controls are hidden. Press right-controller B to stop, then find saved images and clips in the local library.
- **115 voice-cloning fixes**: Improved original-audio sampling and cloned-voice auditions for affected MP4 files, reducing failures and unnecessary waiting across different segments.
- **DLNA candidate-search fixes**: Fixed positioning failures before the first cue in some external subtitles, improving candidate discovery and original/cloned voice auditions.
- **Better cloud-read recovery**: Improved recovery from temporary read errors, expired links and interrupted connections when resuming playback or sampling audio.
- **More consistent menu clarity**: Lower playback frame rates alone no longer trigger a reduction in menu display quality.
- **Smoother return from cinema-style placement**: Restore the ordinary screen toward your current gaze while retaining fixed viewing preferences, reducing unexpected position or distance changes.

Source scope: screenshots use decoded source images rather than the headset view; clips copy compressed video and the selected source audio, without compositing menus, effects, background music or narration. Current locked Android builds use MKV; keyframe-aligned boundaries and unsupported-source limits apply. See [capture scope](docs/CAPTURE.md).

## 0.12.2 — 2026-10-19

This update adds custom cloned voices, 19 narration languages and head-tracked spatial photo viewing, alongside optional music during videos and separate controls for history and per-file settings.

- **Custom cloned voices**: Pause a video, create a voice from a suitable original-audio segment, audition it and save it for subtitle narration in other videos.
- **My Voices manager**: Audition, select, rename and delete personal voices from subtitle controls or global settings, and choose a default voice for new videos. Narration remains manually enabled for each new video.
- **19 narration languages**: Read existing subtitle text in languages including Chinese, English, Japanese, Korean, French, German and Spanish. Select a language or follow subtitle metadata, with matching audition samples.
- **Head-tracked spatial photo viewing**: Apple spatial photos and completed 2D-to-3D photos offer depth changes with small head movements. Switch between Spatial Stereo and Static 3D; Apple's static mode retains the native stereo image.
- **Music alongside video**: An optional setting allows music during video playback, with music controls on the video bar and separate music volume. Video retains priority by default.
- **Separate history and per-file settings controls**: Keep subtitle, audio, stereo-alignment and narration preferences without recording playback history. Disable or clear each category independently.
- **More stable spatial photos**: Fixed frame deformation, sudden snap-back during head movement and small mesh gaps in affected photos, with clearer viewing-mode selection.
- **Voice audition and narration refinements**: Unified play/stop controls, clearer preparation feedback and reused audition caches. Local timing adjustments reduce some drawn-out openings and long pauses while retaining saved voices and original caches. Fixed voice restoration after reopening a video.
- **Unobstructed viewing**: Hands, controller models and rays hide when no control panel is open and return with the controls. Gesture recognition and playback shortcuts remain available.
- **More reliable stereo-alignment memory**: Fixed lost settings after USB reconnection and when entering the background before an adjustment was finished.
- **Cleaner music pages**: Music options and storage details move into settings, while quick playback controls remain available. Returning restores the playlist and browsing position.
- **More consistent interface**: Unified selection controls, typography and dropdown arrows, plus a landscape launcher card to improve readability and reduce icon cropping in affected launchers.
- **Current source refinements**: Remember photo viewing mode/strength globally and video depth strength per file. Scale spatial-photo relief with its actual display size, and condition cloned references with shared narration playback-level handling and independent narration volume. These changes do not establish a universal listening-quality or headset-performance guarantee.
- **Source/build scope**: The experimental auditorium, seating, movement and desktop prototype are Debug-only; Release rejects stale cinema settings while retaining cinema-style screen placement. Online panorama entries remain hidden. Voice models, preset payloads, reference recordings and personal voices are excluded from Git; see [models](docs/MODELS.md).

- **Latest screen/menu fixes**: Leaving cinema placement restores the ordinary screen toward the current view without overwriting fixed defaults. Slow frames no longer disable menu composition layers or reduce capture density; native capability fallback remains.

## 0.12.1 — 2026-10-18

- **Narration remembered per video**: New videos start with narration off. Reopening a video restores its saved on/off state, language, voice and other narration preferences; controls released after switching videos no longer change the new video's settings.
- **Visible subtitles by default**: Narration leaves subtitles visible unless you explicitly hide them. The language selector remains available while narration is off; Chinese, English or Japanese defaults follow the interface language, with an explicit follow-subtitles option retained.
- **More reliable narration language selection**: Your selected language takes priority over subtitle metadata, including untagged external subtitles. Older automatic defaults migrate without overriding an explicit automatic-language choice.
- **Flat-screen defaults follow your adjustments**: Distance, size and placement become the next viewing defaults unless explicitly fixed. Fixed defaults survive temporary changes; releasing the lock saves the current layout. App and system recentering use the same defaults, with an initial 2 m / 100% layout.

## 0.12.0 — 2026-10-18

- **Offline subtitle narration**: Normal Debug and Release builds enable Chinese, English and Japanese text-subtitle narration with 12 preset voices, previews, line selection, volume, original-audio ducking and optional subtitle hiding. Timing adapts automatically up to 1.8×, with pause/resume and seek handling. Public source includes runtime recipes and metadata, while weights, preset payloads and reference recordings remain excluded; the independent commercial-source audit of reference recordings remains unresolved.
- **Photo puzzles**: Production Release entry points support ordinary, depth-converted and spatial photos, plus mono 360° panoramas, with seated/standing placement, piece-count choices, wrist rotation, a movable frame and off-hand reference. Save/resume separate sessions, browse unfinished/completed history and remove records without deleting originals. Procedurally generated cues and completion fireworks accompany play.
- **Cinema screen placement**: Added 100-inch, 150-inch and two giant-screen presets, eye-level placement, a temporary alignment grid and saved flat-view defaults. Flat screens support 1–50 m distance, 100%–3000% size and direct Off/Light/Medium/Wrap curvature selection.
- **Audio timing and dialogue controls**: Remember sync offsets per video and audio track, show full external-track names, follow headset media volume and save continuous quiet-dialogue enhancement per video.
- **Music previews and quick controls**: Preview supported local, USB and network audio before importing, including seeking. Hover controls show the current track and play/pause; storage details show audio usage/free space. No fixed library-wide quota; Android retains a 512 MB per-file limit.
- **System keyboard search**: Use available multilingual system input methods with paste, clear and retained search drafts. Broad 115 folder searches preserve found results and suggest narrowing the query.
- **Network playback**: Reuse nearby MP4 upstream reads and Blu-ray ISO preparation/playback data to reduce redundant loading on supported sources.
- **Panorama background**: Fixed bright seams and pole artifacts in affected display paths while retaining the source detail and orientation.

## 0.11.2 — 2026-10-18

This update adds a global music player, offline audio imports and video playback modes, alongside improvements to 115 startup, large libraries and controller pointers.

- **Global music player**: Use the same player from the home screen and photo viewer, with playback, track, seek and volume controls. Audio continues while changing photos or returning home and pauses when video playback begins.
- **Built-in music and ambience**: Choose from six calm, joyful and focus music tracks, plus six ambient recordings: stream, ocean, forest breeze, rain, summer night and distant city.
- **Custom playlists and playback queues**: Create, rename and organize playlists, with sequential, repeat-all, repeat-one and shuffle modes. The compact player shows the current track and its playlist source.
- **Offline audio imports**: Batch-import from supported local, USB, SMB, cloud and WebDAV sources. Completed imports play from a local copy without keeping the original source online. Removing an app copy leaves the original file untouched.
- **More audio formats**: Play MP3, OGG, WAV, FLAC and DTS audio, with multichannel tracks downmixed to stereo on the headset.
- **Four video playback modes**: Choose single-video playback, repeat-one, sequential playback or repeat-all, with a remembered preference. Supported cloud and media-server sources can continue across pages.
- **Less waiting when opening 115 videos**: Fixed redundant full-directory reads during playback preparation. The main video starts before external subtitles and audio tracks are prepared.
- **Smoother large libraries**: Improved scrolling, selection, sorting and editing in folders containing hundreds or thousands of files.
- **Keep your browsing position after file changes**: Deleting or renaming items better preserves the current page and nearby position, reducing jumps to the start and repeated reloads.
- **Less intrusive controller feedback**: Stationary hovering no longer keeps ordinary playback controls visible indefinitely. Fewer unnecessary rays during VR180/360 viewing, with feedback retained for active adjustments.
- **Correct pointer hits on menu backgrounds**: Rays retain a visible hit point over blank areas inside panels, with improved feedback on bookmarks, dropdowns and playback-mode popups.
- **Spatial-video playback fix**: Fixed some spatial videos incorrectly reporting no playable audio/video tracks, with automatic fallback when the initial video output is incompatible.

## 0.11.1 — 2026-10-17

This update adds same-folder subtitle selection, per-subtitle sync memory and on-demand cloud browsing, with improvements to 115 startup, 2D-to-3D conversion and network playback.

- **Choose other subtitles from the same folder**: Select differently named files or alternate subtitle versions on supported local, USB, SMB, cloud and WebDAV sources. Manual cloud choices use the directory page from which the video was opened.
- **Per-subtitle sync memory**: Different subtitles for the same video keep separate timing offsets. Your selected subtitle and its settings can be restored on the next opening.
- **On-demand cloud pages and sorting**: Browse 115, Baidu, Aliyun Drive, Quark and OneDrive page by page, with provider-supported sorting, without first loading the entire directory.
- **Improved 2D-to-3D conversion**: More detailed video depth and adjusted temporal smoothing balance responsiveness and stability, with processing optimizations for videos and photos.
- **Less waiting in 115**: Reduced redundant folder lookups and subtitle/audio preparation, with improved subfolder navigation and target verification for deletion and renaming.
- **Smoother WebDAV browsing**: Reuse directory results to reduce repeated requests when paging or changing sort order.
- **Network playback fixes**: Improved playback of some MP4 files with prolonged buffering and WMV files that failed to display video, with automatic fallback for incompatible video output.
- **Fewer accidental controller wakeups**: Head movement, light touches and tracking jitter are less likely to reveal hidden pointers. Deliberate controller movement or a button press wakes them, with the first press taking effect.
- **Favorites and recent-history fixes**: Recent playback follows global privacy settings independently of the favorites lock. Fixed favorite icons obstructing 2D-to-3D and volume popups, and clarified the privacy-settings entry.
- **Stable photo-wall rows**: Browse multi-row photo walls by column while keeping photos in their original rows, including wraparound and incomplete final columns. Expanded photos retain individual navigation.
- **Clearer file browsing**: DLNA entries show file extensions when reliably available, with more compact folder-toolbar grouping.
- **Accurate Alpha FPS display**: The readout now reflects frames actually drawn, making frame-rate limits easier to assess.

## 0.11.0 — 2026-10-16

This update adds favorites, privacy controls and read-only USB playback, improves spatial media viewing, and refines controller interaction and subtitles.

- **Video, photo and folder favorites**: Save favorites during playback and switch between Recent and Favorites on the home screen for quick access to frequently viewed content and folders.
- **Return to the source folder**: Open the original location from recent items or favorites on supported sources to browse the same folder or a show's season.
- **Easier collection management**: List checkboxes, batch removal, hover actions and a brief undo window make organizing easier. Removing records or favorites leaves original files untouched.
- **Playback-history privacy controls**: Choose to record everything, local media only, or nothing. Separately clear existing network or all playback records while keeping account connections and explicitly saved favorites.
- **Favorites PIN and automatic locking**: Protect favorites with a four-digit PIN, encrypted storage, manual locking and configurable automatic locking. Locked favorites hide their contents and close protected playback. Clearer two-step PIN setup.
- **Read-only USB playback**: Browse supported FAT32, exFAT and NTFS drives, including compatible multi-partition devices, with videos, photos and same-folder subtitles. Improved read-only folder authorization for system-mounted partitions.
- **Stop using all USB drives at once**: A global library toolbar action stops this app's playback and access across USB drives and partitions without visiting each partition or opening system settings.
- **Better spatial media viewing**: Compatible spatial videos can use the source's recommended stereo offset, with a per-video switch. Spatial videos and photos with valid capture data offer capture-FOV matching to help set the display size.
- **Controller rays without open menus**: Move a controller or press a button to reveal its ray and hit point. Idle feedback hides with the playback controls.
- **Easier picture resizing**: Point at a flat video's corner and hold the trigger to resize proportionally. By default, the right stick adjusts flat-picture size or immersive zoom. Fixed reverse zoom with custom bindings while preserving saved controls.
- **Smoother photo-to-3D transitions**: Keep the original photo visible until the stereo image is ready, reducing temporary distortion and sudden picture changes.
- **PGS subtitles during 2D-to-3D playback**: Fixed disappearing bitmap subtitles when conversion is enabled, while retaining subtitle size and position controls.
- **More readable Emby/Jellyfin details**: Larger detail titles and expanded synopsis text, with more spacing for easier reading.

## 0.10.2 — 2026-10-16

This update adds manual use of built-in Alpha masks, restores automatic video covers and speeds up 115 folder deletion.

- **Built-in Alpha mask toggle**: For compatible full side-by-side fisheye videos, enable “Use the video's own Alpha mask” in the video mode panel to use the embedded mask without live AI matting. Your choice is saved per video and takes priority over filename detection.
- **Automatic video covers restored**: Fixed missing library covers after playing some videos, with improved stereo-video framing and orientation.
- **Faster 115 deletion**: Reduced waiting before deletion and processing time after confirmation for files and folders through 115 Open, while retaining confirmation and failure safeguards.
- **Clearer passthrough naming**: The playback bar's live matting control is now called “AI portrait passthrough” to distinguish it from a video's built-in Alpha mask.

- **Custom panorama guidance**: Global background settings now explain how to set a viewed 360° panorama as the player's background.

## 0.10.1 — 2026-10-16

This update improves menu responsiveness during playback, fixes playback-browser and flat-video recentering issues, and remembers your preferred library viewing distance.

- **Smoother menus during playback**: Reduced the extra load from playback controls and the media library to reduce stuttering when opening menus.
- **Faster settings navigation**: Reduced pauses when opening settings and switching tabs for more responsive interaction.
- **Playback-browser fixes**: Fixed cases where the browser became unclickable after changing videos or reappeared with the controls after being closed, covering compact and full library layouts.
- **Reliable flat-video recentering**: App and system recentering restore the default picture position and distance after grip movement or distance adjustments, preventing old offsets from returning after a video change. Picture size, curvature and content rotation are preserved.
- **Remembered library viewing distance**: Adjust the main library's distance with grip and thumbstick, and keep it when returning from playback, reopening the library or restarting the app. Recentering brings it to the center of your current gaze while retaining the saved distance.

## 0.10.0 — 2026-10-16

This update focuses on better Alpha passthrough quality and smoothness, alongside improved thumbstick seeking, panel placement, file management and playback error messages.

- **Major Alpha passthrough quality and default-FPS improvements**: Improved portrait cutout quality and viewing smoothness, with the default Alpha frame-rate limit raised from 20 to 30 FPS. The limit remains adjustable and existing saved preferences are retained. Headsets that do not support the updated Alpha path automatically fall back to eye-buffer Alpha.
- **Alpha edge controls**: Adjust Alpha Feather and Alpha Edge Shrink from playback or library settings to refine portrait outlines.
- **Alpha model-size selection**: Choose 256, 320, 384 or 512 with a remembered global preference to balance cutout detail and performance. First use of a size may take about a minute to prepare; the current size stays active meanwhile.
- **Preview thumbstick seeks before committing**: Default steps are 20 seconds on the left controller and 10 seconds on the right. Hold to accumulate, then return the stick to center to seek. Target-time feedback fades after the new picture appears.
- **Less intrusive buffering feedback**: With controls hidden, a small independent indicator shows loading stages, elapsed time and measured read speed without opening the playback bar. Visible controls use their existing status area.
- **More natural panel placement**: Playback, settings, subtitle, bookmark and library panels face the viewing position when opened or placed, making stacked panels easier to read. Improved menu-edge rendering.
- **Return directly to the library with B/Y**: Exit ordinary video playback and return to the library without opening the controls first. Popups, folders and active drags retain their contextual Back or cancel priority.
- **Improved controller combinations**: Added optional 180-degree turning for 360-degree media and previous/next-video actions. Grip and trigger modifiers work in either order, with fixes for blank-space grip captures blocking combinations.
- **Optional file-management mode**: List checkboxes support multi-select deletion, with preview and confirmation for file operations and renaming. Matching-basename companion files can be updated together; supported sources now include file/folder renaming through 115 Open.
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
