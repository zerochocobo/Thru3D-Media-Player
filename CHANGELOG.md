# Changelog

[简体中文](CHANGELOG.zh-CN.md)

Newest first, following product release milestones. Some development/source snapshots contained features before their product release. Original APK identifiers `0.2` and `0.4` are retained; `0.4` was also called `0.4.0` in release notes. Availability depends on device, server and media capabilities.

## 0.17.5 — 2026-11-10

- Restore Featured Beta badges for Niconico, TikTok, Instagram Reels and Internet Archive after the recorded Quest ordinary featured-entry/video-selection/page-button/audio-video/seek/retained-return journeys. Scope remains limited to those paths and formats; this does not establish all-content or PICO acceptance. Keep foreign manual playback and fullscreen behavior, without restoring URL-only foreign toolbar Beta entries. Other overseas badges and pending iQIYI/Youku badges remain withheld; China-store Featured stays seven CN sites.
- Add a session-only viewing-hand lock with guarded recovery, distinct from persistent screen-edit locking; improve lock input ownership and close conflicting submenus. Add independent photo default/last-mode preferences and an explicit 180-degree video-rotation preset.
- Pipeline bounded Alpha mask capture and schedule masks against their video frames, with a cut-out interpolation option. Reduce XR eye-buffer work when only the compositor video layer is visible and keep the reduced buffers stable through menus/seeks. Preserve the existing video/depth cadence; measured scope is not a universal smoothness, memory or thermal guarantee.
- Improve Niconico SPA/long-playlist ownership, ordinary TikTok/Instagram rendered-player selection and audio-tail handling, Archive file identity, bounded large MP4 sample tables and complete iQIYI playlist transport. iQIYI headset readiness/1080p validation remains incomplete; Naver/Reddit have no accepted Featured-entry chain and are not promoted to Featured acceptance; other adapters retain their own validation limits.
- Stop repeatedly retrying a failed layer return while preserving later valid recovery. Improve PICO projected-control handling, offer direct USB access when its system provider cannot play a file, and request QIYU passthrough only through available platform capability. Beach interaction/foley/meteor source updates are included; model/scene/texture/audio payloads remain separately supplied and excluded from Git.
- Keep private keys, credentials, user backups/media, weights, internal development records and promotion excluded. Miracast remains hidden/detached. Current source follows the recorded release input cut, including exact pinned TED files; that inclusion is not TED headset acceptance or a new badge.

## 0.17.4 — 2026-11-09

- Expand AI GPU compatibility with a Vulkan fallback when OpenCL cannot initialize, plus portable RVM activation restoration and Vulkan scheduling/transfer improvements. Keep the existing video 28 ms capture policy and browser cadence; do not trade fewer depth updates for XR frame rate. Reported Quest 2 video/base-portrait and browser-effect checks do not establish all-device, photo/enhanced-portrait or sustained 72 FPS/30 Hz acceptance.
- Replace internal PNG image handoffs with lossless, bounded and versioned pixel transfers for photos, reading and related previews, and process the newest captured browser frame without waiting for another callback. Original file formats and explicit user exports remain separate.
- Add a persistent linked screen-edit lock for flat video, with corner/menu controls and feedback; playback, seeking, volume, subtitles and depth strength remain usable. Add a global option to hide passive playback status while keeping actionable errors and confirmations.
- Share the global footer with browser windows/projected controls and tighten its vertical layout. Improve scene playback-panel placement and controller ownership; add beach leisure/prop interactions and shoreline/celestial details. Public Git still excludes the private scene/model/texture/audio payloads and modeling studies.
- Retire failed SMB connection contexts and retry eligible reads; the current source also waits for closing MPV sources before opening another after rapid presentation switches. Seek CPU/GPU performance levels stay sustained-high. The last two changes are not guaranteed in every previously delivered APK; actual network/seek and presentation behavior needs matching package validation.
- Withdraw foreign featured-list Beta badges and toolbar Beta play entries; preserve manual playback and experimental in-page buttons. Withdraw iQIYI/Youku directory badges pending required validation, without disabling the validated domestic routes. The China-store channel keeps exactly seven CN featured sites. Earlier fixed-sample success does not override current Instagram/Niconico/TikTok/Archive user failures or establish ordinary browsing compatibility.

## 0.17.3 — 2026-11-09

- Add Play Beta routes and featured entries for compatible Twitch public clips, TikTok detail pages, TED talks and Dailymotion. Preserve the legacy manual player action alongside Beta on foreign sites, explicit playback, source-scoped requests and retained-page return. Reported clip/detail validation does not imply all content, accounts or devices.
- Add browser history shortcuts and improve recovery when an external app launch is rejected. Bind iQIYI to the active SDK quality/full timeline and improve source-reset/seek recovery and escaped Youku identifiers; remaining site challenges and unverified branches are not advertised as resolved.
- Add restart/quit actions at the footer with two-step confirmation and session usage information. Improve compact action layout, oblique-angle icon visibility and initial photo-menu placement.
- Skip repeated per-frame audio/subtitle restore work while its inputs stay unchanged; release menu-layer viewports when an XR session stops. Improve system-keyboard fallback/selection for generic Android OpenXR without changing the Quest/PICO compatibility targets.
- Add lower-cost beach shaders and darker nighttime water for lower GPU tiers, improve lounger placement and finish Traditional Chinese/Japanese beach labels. Low-end compositor video layers default to unfiltered sampling. These source optimizations do not establish that Quest 2 OpenCL depth/person processing works; the observed failure remains documented.
- Hide the abandoned Miracast experiment in every build and disconnect it from the reception switch; keep DLNA and AirPlay. Technical dormant source remains, without a user-facing Miracast feature or claim of successful phone mirroring. Private models/scenery payloads, keys, credentials, personal backups and internal development/promotion remain excluded; known AirPlay authentication limits remain in the technical guide.

## 0.17.2 — 2026-11-08

- Add the private-beach cinema to distributed builds, with loungers, free movement, day/night controls, draggable sun/moon and nighttime handheld fireworks. Reorganize the scenery picker into compact four-column sections with the add-panorama card next to custom backgrounds. Public Git retains integration/shader source; scene/model/texture/audio payloads remain separately supplied and are not included here. Lower-tier hardware acceptance is not established by the Quest 3 observations.
- Add photo autoplay with a 3–30 second interval (5 seconds by default), timed from the final displayed image without waiting for neighbour preparation. Improve continuous rotation, 90-degree snapping, upright/ground layouts and contextual picture controls.
- Add continuous video/photo screen curvature and horizontal, vertical or spherical curve modes for eligible ordinary videos with a panorama-image background; preserve horizontal curvature after content rotation and independent cinema settings.
- Add compatible iQIYI, Douyin and Niconico Play Beta routes with current-media/request binding and retained-page/playhead return. Keep the legacy manual player button alongside Beta on foreign sites; domestic-site presentation remains separate. Niconico restores absolute position through the bound page player. These routes do not establish all-content, membership or headset compatibility.
- Improve browser keyboard visibility controls, address-field paste actions, focus-region aspect matching and the option to enable 3D when hiding browser controls. Keep browser Back separate from dismissing playback controls and improve source/library switching and pure-page rendering. Fullscreen continues to stay in the browser.
- Retry eligible hardware decoding while the retained webpage releases its decoder, and identify software fallback for affected 4K-and-larger sources. Model weights, private scenery/media, keys, passwords, profiles/backups and internal development/promotion material remain excluded. 3D text protection remains off; the known AirPlay optimized-host authentication issue remains documented in the technical guide.

## 0.17.1 — 2026-11-07

- Add a pure-page browser view that hides menus, borders and resize handles while keeping page clicks, scrolling and region focus available; toggle again to restore chrome. Keep the 3D strength popup above the lower frame so it remains visible and usable.
- Leave webpage fullscreen and media-server playback events in the browser, including browser 3D. Remove automatic native handoff and its speculative background pre-resolution; only explicit playback actions enter the player. Retain existing Emby/Jellyfin/Plex manual buttons and original-document return, without adding the withdrawn server Beta experiment.
- Add compatible Youku Play Beta with observed current-media binding and retained-page/playhead return. Account, source, entitlement and site verification limits remain; local acceptance does not bypass a headset verification challenge. iQIYI adaptation remains work in progress and is not advertised as available Beta.
- Default AirPlay reception to pairing without a user-entered code, with a persistent global “require password” option that displays a fresh verification code when enabled. Keep encrypted pairing in both modes. Preserve decoder parameter sets across configuration/frame timestamps to improve first-connect picture/audio readiness, including affected iPad sessions; not a universal phone/OS acceptance claim.
- Exclude private-beach resources from all Release and default Debug builds, hide the entry and fall back saved selections to the cinema. The explicit include option is Debug-only and rejected for Release; retained runtime/shader scaffolding is not a published usable scenery. Model/media payloads, keys, passwords, profiles/backups, private settings and internal development/promotion remain excluded. Douyin and 3D text protection remain unavailable.

## 0.17.0 — 2026-11-07

- Add experimental browser-page/focused-region 2D-to-3D and person passthrough, separately or combined, with depth strength/position/render controls. Improve focused picking, lower-page control placement, sharpness, cold-start feedback and automatic collapse of idle strength popups. Device, page, protection and performance limits apply.
- Add experimental AirPlay mirror reception in an independent movable/resizable window with distance and audio controls. Improve PIN pairing validation, image clarity, audio, persisted reception state, portrait/landscape surface transitions and initial placement. Collect DLNA/AirPlay reception switches and statuses at the bottom of the library sidebar; no certification, DRM or universal phone compatibility claim.
- Add compatible Weibo, Tencent Video and Mango TV Play Beta handoffs alongside Bilibili, prefer Beta on adapted sites and provide larger in-page actions. Bind actually observed current-media responses, including supported HEVC/transport-stream/inline initialization, retain original browser documents where supported and restore playhead on return. This does not establish support for all programmes, subscription/region/protected streams or unchanged-URL cases. Douyin remains temporarily unavailable.
- Add a hover-only lower-left flat-video rotation control: drag or hold either arrow and release to the nearest 90°; the other three corners resize. Allow cinema picture resizing from corners with concise blocked-operation feedback; improve film-light sampling and cut response.
- Remember playback speed globally across videos/restarts and apply last/fixed projection preferences when opening external videos. Explain panorama format/aspect/size requirements and surface individual/batch import failures.
- Project intermittent AAudio timestamps to the current clock to improve video pacing after the Quest v29 update; retain bounded reset waits. Tested observations do not establish all-device, all-speed, headset-audio or absolute lip-sync acceptance, and high-load 8K accelerated playback remains limited.
- Fall back to ordinary playback when bounded MKV header inspection fails, retaining the possibility that an unidentified MVC file opens as 2D; read eligible UDF metadata stored as a plain File Entry in Blu-ray images. Reduce panorama texture growth across background changes and release player-owned keyboard callbacks on exit.
- Version 0.16.9 was skipped. Private-beach modeling/desktop studies, scene/texture payloads and new photo-model research are not advertised released features or included assets. Model weights, signing material, credentials, private media/backups/settings and internal development/promotion material remain excluded; 3D text protection remains off.

## 0.16.8 — 2026-11-05

- Add six UI palettes and custom background/accent/text colors, with preview, apply/cancel, quick switching and saved preferences. Improve light-theme text, icons, swatches and footer-logo grayscale; retain media/subtitle colors and the classic palette. Glass menus remain research, not a released feature.
- Reduce photo/comic/PDF 3D and page-turn waits through earlier neighbour preparation, overlapped color/depth work, bounded measured-memory caching and grouped GPU copies. Improve photo hole bridging and video stretch lookup at strong depth settings; this does not guarantee instant loads or artifact-free reconstruction on every device/source.
- Keep ordinary flat/curved video upright during sideways dragging, and make grip-plus-stick photo/video distance adjustments radial to the headset without introducing roll, pitch or yaw. Preserve explicit content rotation, supported follow behavior and cinema/immersive route boundaries.
- Add 123 cloud drive through official OpenList OAuth, browsing/search/range playback where supported, and accepted official login redirects to avoid a blank authorization page. Source tests use intercepted requests, not distributed accounts/tokens; account permissions and provider restrictions still apply.
- Add video shuffle with round-based repeat avoidance and actual previous-play history. Add remembered 0.5–2.0× comic narration and audition speed, with an independent accessible audition button for available voices; narration/model/translation prerequisites remain.
- Double the maximum PiP window size and improve hover, pressed and selected feedback. Honor opt-in default video 3D for eligible flat DLNA casts as soon as format/first-frame readiness is known; a missing duration/seek flag alone no longer blocks it. Preserve native stereo, partial-cast and explicit manual-choice gates.
- Restore Android HTTP(S) video chooser eligibility for compatible external apps while retaining URI/source validation. Keep the browser Beta label on the title line across languages. Douyin Beta remains temporarily unavailable and 3D text protection remains off; private media, personal settings, credentials, keys, weights and development/promotion material remain excluded.

## 0.16.7 — 2026-11-04

- Reduce per-frame menu/compositor work during eye-buffer playback and restore optimized native render-bridge compilation in Debug builds. Add GPU-fenced decoder-image return to prevent reuse before sampling completes, addressing intermittent future-frame flashes under depth inference; device/content limits remain.
- Add separate globally remembered 3D position controls for videos and photos. Video controls live in playback settings; photo controls are independent. Expand photo distance to 0.1–50 m and size to 5–3000%, correct sideways-drag roll and add remembered edge-feather strength including hard edges.
- Add configurable shared controller seek steps, media-server playback-report intervals and fresh resume-position lookup when returning to server libraries. Keep ray/trigger file selection; the experimental A-button confirmation was reverted.
- Allow live-subtitle/narration preferences to be configured while their features are off, retain runtime readiness gates, and improve detail expansion and cue/wait feedback. Audio processing lead is no longer described as completed subtitle coverage; this does not claim to repair recognition omissions or change the recognition/translation engine.
- Correct rotated flat/VR PiP orientation, aspect and cropping. Use a single source eye for both eyes in the paused temporary VR globe. Restore visible playback controls when leaving the cinema through a new source and refresh hidden menu-layer placement.
- Extend opt-in Quest Chinese input to supported naming/configuration/password forms. Reduce redundant browser hover events and compatible danmaku outline work. Bound abnormal audio reset waits; if playback freezes again at the same recovered position, stop reopening it indefinitely and show an error instead. Underlying system-audio failures are not claimed fixed.
- Preserve paused Douyin/Mango/Youku research, temporarily unavailable Douyin Beta and disabled 3D text protection. No model weights, personal dictionary/history, private media, credentials, signing material or development records are included.

## 0.16.6.1 — 2026-11-04

- PICO standard test release: add explicit user-triggered USB takeover for system-held disks, independent cinema curvature with a matching curved border, GPU-completion-safe decoder-image release and bounded AAudio reset waits. Automatic USB discovery does not force takeover; system remount/eject behavior and hardware acceptance are not established by source/build checks.
- Retain matching mpv patch generators, input receipts and source notices. This test release is distinct from the five-channel 0.16.6 release and is not a claim that every PICO playback or system-audio failure is resolved.

## 0.16.6 — 2026-11-04

- Add per-eye aspect-ratio presets and fine adjustment for flat/curved video, including cinema, remembered per video; immersive video and photos keep their independent behavior.
- Add opt-in offline simplified-Chinese pinyin input on Quest, with candidate paging, English/symbol input, a compact draggable keyboard and a pinned Apache-2.0 dictionary. Default off; PICO/OpenXR retain their existing input paths. Address bars use the system keyboard after the layout revision; compatible webpage text fields and app search remain supported.
- Improve cinema seat targeting, gold selection/seat feedback and light haptics; restore lighting/movement shortcuts beside Scene. Add configurable video volume and playback-library shortcuts without overwriting existing bindings.
- Keep browser chrome sharper on tall windows. Preserve minimum compatibility targets and existing paused-feature boundaries; build/startup checks do not establish acceptance on every headset.

## 0.16.5 — 2026-11-03

- Add a unified scenery picker and shared private panorama library with previews, batch import, rename/remove, progress and an action to use the current panorama as a background. Global and image modes share assets but remember choices independently; image backgrounds do not inherit the cinema. Improve menu placement after scenery transitions.
- Add optional default 2D-to-3D for eligible flat video and reuse of the last projection/stereo mode for unrecognized files without per-file settings. Both default off, per-file/recognized-format choices take precedence and photo settings remain independent. Cycle playback order directly from its icon.
- Expand manual native Alpha passthrough to compatible full-SBS 180° masked video while retaining fisheye support. Retain compiled video depth models across seek revisions, improve same-grade shot-cut handling and fill eligible burned-in letterbox bars before depth inference; these do not imply universal media or device compatibility.
- Add manual live captions/translation for eligible seekable DLNA cast audio. New cast sessions default off and retain only ephemeral cues; mode/decoder revisions preserve the same cast session without turning it into file history or a persistent subtitle task. Improve missing-cue recovery and entry state after 3D/passthrough changes.
- Add filename filtering to the external-subtitle picker, seeded from the media title and using directory search when supported. Add Emby/Jellyfin playback/progress/stop reporting under existing privacy controls, improve Plex library presentation and preserve server directory/detail/scroll state when returning from settings.
- Improve browser resizing from small/portrait windows to larger screens: retain nominal layout bounds, zoom beyond them and preserve independent edge dragging within pixel budgets. Lower compatible flat-screen distance/size minima to 0.1 m/5% and cap menu distance at 4 m. Repair panorama-photo conversion state and legacy GBK ZIP file/directory names while preserving valid Unicode and path checks.
- Douyin Play Beta is temporarily unavailable after the featured-entry regression; its ordinary/diagnostic source gates remain off and paused research is not restored. Jellyfin/Plex browser adapters remain technical source, not an advertised completed feature of this release. 3D text protection remains hidden/off; weights, personal backgrounds, credentials, logs and development material remain excluded.

## 0.16.4 — 2026-11-03

- Fix a native VR picture-in-picture timing-cache key overflow that could corrupt the caller's GL state, causing repeated image shaking, frozen playback or black menus on some VR videos. Store all common shader parameters separately from output dimensions/eye count/texture type; derive uniform and window capacities from their production descriptors.
- Improve stability when displaying the main video and up to three PiP windows together, retaining the existing compositor and source routes. Add a production-JNI GLES memory/state regression with ASan/UBSan and a pre-fix negative control; host checks do not establish headset-driver, lifecycle or background-resume acceptance.
- Keep 3D text protection and Douyin native/Beta handoff unavailable in the public export. Private logs, device captures, development records, model weights, signing material and personal backups remain excluded.

## 0.16.3 — 2026-11-02

- Add opt-in below-screen text/bitmap subtitle placement for eligible flat/curved 2D, SBS/TB and spatial video, with per-file memory across flat-video modes. Keep it off by default and at the end of subtitle style controls; immersive projection keeps its existing subtitle path.
- Add temporary passthrough while watching immersive video: pause the source into a small stereo globe, use a head-following exit control and short transitions, then restore the original view/play state. This is a session-only preview, not continued background video or a saved projection change.
- Decode compatible H.264 MVC MKV with validated MVC configuration and bounded/cancellable header inspection; recognize MK3D in browsing and cloud search. Preserve full-resolution left-first stereo and ordinary AVC/HEVC/SBS/TB decoder selection. Seeking/range access and existing MVC format limits apply.
- Add a global switch for filename-triggered passthrough. Improve media-server card icons, cloud-login font visibility and desktop/mobile retry behavior. Decode valid ZIP Unicode Path metadata while preserving archive path validation and legacy fallback.
- Stabilize photo/comic/reading caches by separating mutable image ownership and reserving composition memory headroom. Keep bounded allocations and explicit failures; no unlimited image size or uniform device-performance claim.
- Improve mounted-USB discovery, permission-aware reversible fallback, typed provider-failure handling and PICO system-eject/retry guidance. The in-app action stops this app's USB access; it does not unmount hardware. Some PICO provider/OS paths still fail, so this is not a universal USB playback fix.
- Retain redacted crash breadcrumbs/evidence across restarts and offer eligible next-launch log saving under the existing privacy policy; no automatic upload. Keep 3D text protection and Douyin native/Beta playback unavailable in the public export, with model weights, private logs/media and development records excluded.

## 0.16.2 — 2026-11-01

- Add opt-in dual text subtitles with independent selection/timing and narration choice. PGS/bitmap subtitles and active live-subtitle paths retain their supported boundaries. 3D text protection is disabled and hidden in this release, including saved enabled settings; detector source/contracts remain for future review, but weights are excluded from Git.
- Add adaptive photo/portrait neighbour caching and GPU preparation under measured frame/memory headroom, reuse prepared stereo textures and improve contextual photo controls, curved-surface clicks and rotation/disparity. Bound large-image/animation allocations and allow compatible previews or explicit failure instead of unbounded memory use; do not infer unlimited image sizes or uniform headset performance.
- Add Android external-video opening for eligible VIEW/SEND content, transient URI leases and original-source streaming. Validate incoming launch controls before Godot starts, bound resources and strip playlist credentials across media origins. The caller must grant source access; arbitrary apps, DRM and every URI/provider are not guaranteed. See external playback scope.
- Enable AI passthrough for eligible mono/stereo 360° video. Pace depth by source time and reduce repeated contours at strong stereo settings; preserve source stereo and existing fallback limits.
- Improve controller ray edges/target feedback, menu-layer repaint scheduling and browser placement across cinema transitions. Fix Emby assigned-folder artwork while keeping movie walls film-only.
- Keep Douyin native/Beta handoff unavailable in the current release despite retained adapter/diagnostic source. Do not advertise it as supported playback. Retain the Tiny detector package validation for complete builds while both Android detection and Godot 3D text protection remain forced off.

## 0.16.1 — 2026-10-31

- Add video 3D boost up to 200%, click-to-enable/restore strength and a separate Off action. Retain frames while AI 2D/3D paths change to reduce black gaps; a short still frame/audio pause can remain. Preserve the picture's background during Alpha passthrough when requested, including panorama/cinema placement, with independent photo backgrounds and saved preferences.
- Expand photos to static/animated AVIF, APNG, GIF, animated WebP and supported camera RAW families; animations can pause before compatible effects. Add Emby/Jellyfin original-photo browsing/album navigation. Preserve photo portrait intent across navigation, remove rectangular/feather rims and background flashes, and use transparent departure/loading presentation.
- Add browser region focus, clearer loading/click feedback, persistent playback actions and compact toolbar ray reveal. Isolate retired Gecko sessions and release their media before native playback; improve Bilibili primary-media/part/episode association, readiness gating, cancellation, retry and restored capture. Website/account/format restrictions still apply.
- Move supported cloud OAuth/login pages to in-headset Gecko windows with region focus and provider-specific desktop/touch modes. Retain authentication sessions and block ordinary controls behind them; improve refresh/input lifecycle and menu clarity. This does not establish that every real OneDrive authentication step or provider flow is fixed.
- Add PGS foreground tint swatches while retaining outlines/colored content, optional VR adjustment gauges and controller hints. Support Japanese kana reading in subtitle narration, fix split web-audio input for live subtitles and add independently seekable SMB PDF access with filename fixes.
- Add the ESO/S. Brunier Milky Way panorama as the third background, with retained CC-BY-4.0 attribution; keep photo viewing open after selecting a global background. Improve compatible HDR passthrough input, fallback input buffers, cinema cutout visibility and near placement. Do not infer native HDR output or all-headset acceptance.
- Publish pinned image-decoder source/build recipes and notices without personal test media. Meta store builds temporarily use “Thru3D Media Player XR”; other channels retain the standard display name and source defaults are restored. Research plans for hard-subtitle protection, shared cinema and fully continuous transitions are not implemented features.

## 0.16.0 — 2026-10-30

- Replace video/portrait depth with ZipDepth GPU models, keeping still-photo depth independent. Default to the 384×224 FP16 graph at low GPU priority on all headsets; pipeline inference/stabilization, reduce readback work and use mobile-friendly model operators. Publish source recipes, pins and MIT/GPL attribution without weights or private evaluation inputs. Performance remains device/content dependent.
- Add Fill gaps and Stretch edges modes for video 2D-to-3D, with Stretch edges as default and controls in playback/settings. Use a linear 0–100% video strength scale with a 50% recommendation, migrate saved strength once and correct depth letterbox/content normalization. Photo strength retains its separate range.
- Enable AI portrait passthrough for compatible flat side-by-side/top-bottom stereo videos, preserving source-eye stereo and independent size/distance adjustment. Resume photo portrait processing when navigating eligible pictures within the album and across layouts.
- Add a separate Bilibili Play (Beta) action alongside the existing route. Use the logged-in browser session, current UGC part/PGC episode metadata and actually observed video/audio requests; pause the source page before resolving. Improve cold-start, quality, CDN/header association and episode switching, without promising all member/region/DRM content or replacing the existing extractor.
- Wait for final photo stereo presentation before reveal and retain the complete old stereo frame during page departure, avoiding early flat reveals and cut-out holes. Keep settings choice tiles free of overlapping value captions.
- Further reduce cinema shader conversion work. Restore the explicit Meta store build target (`quest_store`, separate application ID), retaining the full browser/catalog. Update ZipDepth in-app notices and preparation guards; no store approval or fresh all-device acceptance is claimed by this source sync.

## 0.15.2 — 2026-10-30

- Add supported unencrypted DVD ISO playback, title/chapter selection and interactive disc menus with controller rays and return-to-menu controls. Include pinned libdvdread/libdvdnav source recipes and notices; encrypted discs and universal disc compatibility are outside this scope.
- Upgrade the browser to peer windows: up to four visible windows on the higher-performance tier and two on the lower tier, with four total tabs. Add explicit close/merge/tab transfer, bounded viewport resizing, featured-site/bookmark start pages, cinema controls and improved ray/drag behavior. Multiple windows do not imply simultaneous native video playback.
- Add per-site, opt-in network media detection for eligible browser streams, retaining the website-selected quality when transferable; unsupported/protected streams stay in the browser. Scope handoff progress/cancellation/errors to the source page and keep other browser windows available. Native handoffs no longer add global playback history. Improve Emby/Jellyfin web direct-play/resume handoff and Emby bookmark feedback.
- Improve interrupted HTTP/TLS recovery and unavailable-video feedback; fix missing Emby folders when media-type filters are active. Site/account/region/codec restrictions still apply; native iQIYI/Douyin handoff is not advertised.
- Render eligible flat text subtitles on a dedicated compositor layer for clearer edges, retaining size/position/style and fallback. Refine PiP edge/corner resizing, hover and drag feedback.
- Add fading center-alignment rings/crosshairs and gentle alignment feedback when moving immersive VR180/360/fisheye pictures. Reduce redundant cinema shader work and default playback to 72 Hz power saving while preserving saved refresh choices.
- Enable the browser in the PICO China channel; curated recommendations show only explicitly marked Chinese sites in every language. Add native-playback compatibility badges and expand in-app third-party credits/notices. No browser profiles, cookies, tokens, media, model weights, keys or personal backups are distributed.

## 0.15.1 — 2026-10-29

- Add up to four browser tabs and two visible windows, split/merge, dragging/resizing, floating/cinema modes and system-keyboard editing. Refine titled tab navigation, nearby draggable cinema controls, paused/inactive-session recovery and bounded background work.
- Automatically hand off eligible fullscreen web video to native playback, retaining manual handoff and return to its original tab. Use actual stream projection for flat/VR180/360° playback; add pre-resolution, network retries, recovered Bilibili page context and additional supported site adapters. Subscription/DRM playback is not native extraction support; Douyin stays in the browser, and Twitch/Niconico availability remains unreliable.
- Add optional temporary LAN bookmark/history management for phone/computer: search, edit, batch import/export of bookmarks, copy/remove history, optional pairing code and confirmed access closure. No library/cookies/credentials or share tokens are included in source.
- Add fixed grip/thumbstick VR picture adjustments, recenter/per-file memory, ±10% horizontal stereo alignment and live numeric/scale guidance. Refine mutually exclusive subtitle side panels, retained collapse/status, task access and sync controls.
- Add automatic external-subtitle charset detection and per-track overrides for common UTF/Chinese/Japanese/Korean/Western encodings. Convert a bounded copy for playback/narration without rewriting the original file.
- Extend voice-sampling/music format support, including MP3 and M4A, and verify long preview clauses finish before playback. The reference-sampling precision experiment was reverted; this release does not claim all cloned-voice failures are fixed.
- Add a PICO China store build channel with browser entry/direct-open disabled; normal channel retains it and account web login is independent. Separate display version from explicit upload versionCode, preserve the same package/signing identity and validate channel metadata. Source defaults to standard; no store-acceptance claim.

## 0.15.0 — 2026-10-28

- Add stereo person passthrough for eligible ordinary flat 2D videos, adjustable depth strength, independent remembered size/distance and continuity from cinema placement. Optional enhanced depth is device dependent and can reduce frame rate; automatic distance starts disabled.
- Add the GeckoView browser (Beta): address/navigation, ray keyboard and website login, bookmarks/history search/edit/batch removal, and improved normal shutdown/restart persistence. Clearing history does not clear website login; no guarantee against forced-termination data loss.
- Add native YouTube/Bilibili web-video handoff with eligible passthrough/2D-to-3D playback, stream-authored YouTube VR180/360°/EAC and bounded up-to-4K SDR selection. Format, site, account and device limits apply.
- Improve AI passthrough compatibility/fallback, lighter low-end defaults, sustained-frame-drop adaptation, bounded mask/depth work and paused portrait redraws. Do not infer acceptance on every PICO headset.
- Correct live-subtitle status when reusable cues exist, so model-checking messages do not hide translation progress.

## 0.14.1 — 2026-10-27

- Add app-wide full-film original/bilingual subtitle preparation with queue management, pause/resume, priority, cancellation and retry. Reuse shared original/translated cue caches under per-file privacy rules; scheduling favors foreground playback or explicitly waits for idle resources. Saved eligible jobs can be restored; transient sessions remain session-only.
- Allow live subtitles with existing subtitle tracks/files. Fix stalled 0% progress and repeated audio-source reopening, identify prepared-task results, explain untranslated lines and automatically retry visible translation failures. Accuracy, cloud service limits and first-cue delays still apply.
- Add Emby/Jellyfin media-version selection in film details, retaining source-specific playback progress and viewing settings for each selected file.
- Add Automatic/Standard/Memory saver choices, mainly reducing AI portrait passthrough's additional buffers and limiting Auto output to 4096 pixels in saver mode. 2D-to-3D retains its frame slots and mainly receives a smaller network cache; plain playback is unchanged. Bound mask waits and improve passthrough recovery. Hide the experimental precision control and run FP16 for existing choices.
- Add diagnostic log settings: recent warnings/errors, compact/full detail, export to Download/Thru3D/logs and explicit temporary Wi-Fi sharing. Redact known sensitive fields, reduce periodic noise and show saved-log location. Logs are not automatically uploaded.
- Improve comic balloon selection, guarded missed-text recovery and complete speech requests; add Japanese word-boundary/reading preparation using Kuromoji/IPADIC. Package a separately supplied auxiliary manga detector, retaining conservative budgets and uncertainty limits. Reading errors and variable device cost remain possible.
- Preserve complete page edges only in magazine/comic layouts; ordinary single-image PDF/archive viewing retains its existing edge treatment. Fix music-hover actions unexpectedly changing the file-browser panel size/placement.
- Improve cancellation/timeouts and subsequent playback recovery after a failed Blu-ray ISO preflight. This does not add encrypted-disc or BD-J support.

## 0.14.0 — 2026-10-26

- Add live subtitles for videos without existing subtitle tracks/files: on-device Chinese, English and Japanese speech recognition, optional online translation, bilingual lines and existing subtitle styles. Playback continues during preparation with progress feedback. Recognition is not guaranteed accurate; some sources and seeks still have substantial first-subtitle delays. This feature does not add interpreted speech.
- Reuse recognized original cues per video under the independent per-file privacy policy, including backward seeks; keep the model loaded across seeks, restart recognition at the new target and retry translation failures.
- Improve shared cloud/115 range reads, cancellation, stalled-connection handoff, bounded pre-read and audio/video cache coordination when enabling live subtitles or seeking. Source concurrency limits can still apply.
- Improve comic bubble grouping, dense/mixed-script text and selective OCR recovery; retain generated 3D while paging with speech/translation, and enter paired reading directly from the magazine action. Remove Beta labels from comic reading/translation.
- Request real-time MediaCodec priority and source frame rate for compatible hardware decoding, retrying without those hints if configuration is rejected. Actual 8K/high-bitrate performance remains device/content dependent.
- Refine cinema seat steps, screen height, seated viewpoint and landing alignment. Enlarge video/photo top-bar hit regions and correct zero-parallax pointer alignment.
- Add consistent media-server/cloud provider icons and refine account/library headings, collection-return placement, footer clock/battery branding and collapsible AI portrait/subtitle settings.

## 0.13.5 — 2026-10-25

- Add Comic reading (Beta): on-device OCR of eligible dialogue bubbles, dwell speech with preset/custom voices, cancellation and bounded next-page OCR/audio preparation. Enable it per reading batch; other preferences persist. Conservative source-language/layout coverage can skip uncertain content; this is not full-page transcription.
- Add Comic translation (Beta): online batched Bing translation with Edge fallback, 19 narration-language targets (Simplified/Traditional Chinese separately), translated-text speech, text size and remembered light/dark appearance, defaulting to light. Non-reading ray hover reveals original text. Improve fitting, opaque page-edge coverage and overlays across supported generated 2D-to-3D viewing. Selected recognized dialogue is sent to providers; no offline translation or universal availability/accuracy claim.
- Add saved left/right/both hand selection for picture pinch gestures and menu invocation, defaulting to the right hand.
- Add recording-save progress/cancellation, improve multichannel original audio and narration capture, and fix image-PiP screenshot/recording cases. Flat/VR output limits remain explicit.
- Reduce PDF rendering/encoding work and reuse bounded page/spread caches. Prepare neighboring decoded pages/OCR/audio within memory budgets; remove neighboring photo-3D caching.
- Extend DLNA preset/next URI handling, Previous/Next navigation and continuation when the sender provides the next item; show the enabled green Receiving casts state with localized connection hints, and improve folder-toolbar placement.
- Make Grand cinema the new-user global background and remove its test label, retaining saved choices. Photos independently default to Belfast Sunset. Refine hall details/lighting, controls locking/dragging and background restoration after reading.
- Default video compositor sharpening to Off, preserving saved choices and the independent gentle photo default. Improve cloud range continuation/cache reuse and non-interleaved multi-audio MP4 reads.
- Fix zero-parallax pointer/icon alignment and scope experimental menu depth to VR video. Improve sample-time controls, voice naming, photo-background save feedback and panorama continuity when menus toggle.

## 0.13.4 — 2026-10-24

- Add local/supported cloud PDF reading, single/two-page and right-to-left layouts, PiP paging, and history/favorite reopening without whole-directory rescans. Retain bounded range/cache behavior and explicit unsupported/password errors.
- Add magazine/comic paired-image reading with pairing offsets, separate PDF/archive/photo layout memory and supported generated 3D/portrait paths. Restore archive inner directories and eligible folder favorites.
- Export saved bookmark A–B loops as named keyframe clips with progress, duplicate-save feedback and cancellation. Improve endpoint guidance, timeline bookmark selection and stale-frame protection; cuts are not frame-exact.
- Add flat-video screenshots/live recording and VR PiP clip composition. Full-resolution screenshots use quality-100 JPEG; live clips include actually heard audio/narration/music. Fix PTS-only MKV muxing and prefer eligible embedded thumbnail covers. JPEG remains lossy; PiP clips use bounded SDR H.264 composition.
- Add independent photo backgrounds/orientation/brightness and recoverable conversion failures; experimental VR menu depth, settings scroll hints, wrist-watch palettes and a thumbstick seek-feedback toggle.
- Add independent subtitle display-line selection and two-axis centers, legacy migration and separate horizontal/vertical memories. Simplify narration controls and add a shortcut with remembered preferences.
- Align supported video-layer release timing to compositor cadence, default the refresh preference to up to 120 Hz and reduce menu/ray/diagnostic work. Actual refresh/performance remains device/content dependent.
- Add cinema viewing-brightness tiers, last-seat memory, position preservation on recenter, movement/control occlusion fixes and automatic house lights after film close. Improve bounded legacy-RAR reads and small-archive caching.

## 0.13.3 — 2026-10-23

- Receive compatible DLNA HTTP(S) video casts on the local network in the existing VR player. Enable reception explicitly; replacing active media requires confirmation, and ended casts can return to the previous media. Support transport/volume feedback and keep cast links out of ordinary history, favorites and per-file memory. This is video casting, not phone-screen mirroring or universal app/DRM support.
- Harden sender compatibility and lifecycle: accept vendor SOAP arguments, HTTP/1.0 and absolute seeks; keep newer offers after Stop, restore audible unmute volume, suspend network reception in the background and retain active transport state. Defer offers during text entry and restrict literal headset-local addresses.
- Add subtitle-free custom voice sampling from caller-selected media/audio tracks, bounded speech detection and candidate selection, inline trimming/audition, and preview text in 19 languages. Silero VAD metadata, MIT notice and preparation recipe are included; weights, reference recordings and personal voices remain excluded.
- Add film-driven three-zone baked screen illumination, automatic/manual house-light controls, a faint idle screen glow and chair-target seating in Grand cinema (Test). Improve screen-wall darkness, screen size, fixture/row visibility and floor/seat teleport checks; keep Debug/Release resource validation.
- Improve large non-solid RAR indexing with bounded Quick Open handling, including encrypted-data cases, and fix conditional ZIP64 size/offset parsing without modifying shared upstream module caches.
- Fix ray-keyboard Shift feedback and prevent inactive editors/web panels from requesting the system keyboard; retain the normal system-input path for searches. Host checks do not establish all headset IME behavior.
- Keep up to five menu planes sharp when tooltips coexist, regroup after tooltip dismissal, and show the four render-scale choices inline. Move server background settings into the server browser and cap video 2D-to-3D strength at 100% with the 50% default retained; photo strength remains independent.

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
