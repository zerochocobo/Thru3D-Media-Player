# Browser and web-video scope

## Current 0.17.5 site status

Featured Beta badges are restored only for the recorded Quest ordinary-entry journeys of Niconico, TikTok, Instagram Reels and Internet Archive: select from Featured, choose/play a video, use the actual page button, verify native audio/video/seek and return to the same paused page. Historical failures remain part of their scope, and neither all-content nor PICO compatibility follows. Foreign URL-only toolbar Beta is still withdrawn; manual playback and experimental in-page buttons/cancellation remain. TED/Twitch/Dailymotion/Streamable/Odysee keep no Featured badge based only on fixed-detail or local checks. Naver Clip and Reddit have no accepted Featured-entry chain and get no new catalog badge. Pending iQIYI/Youku badges remain withdrawn. China-store Featured is exactly the original seven CN sites, independent of language. This source synchronization does not resume paused device/site work.

0.17.5只为已记录完整普通精选链路的四站恢复标记，其他海外及爱奇艺／优酷不扩标；国外旧手动和网页内实验保留，工具栏URL-only Beta不恢复。既有失败、未覆盖格式与PICO未验范围保留，不能推为整站支持。

The standard channel includes a GeckoView browser (Beta), with up to four tabs and four visible windows on the higher-performance tier (two on the lower tier). Floating/cinema placement, draggable chrome, title/close/navigation controls, system/ray keyboard input and recovery share the player UI. Inactive sessions are unloaded/recovered to bound work. Normal exit coordinates profile shutdown; website state is not guaranteed after force termination. Bookmarks/history are separate from website login; clearing history does not sign out. Cookies, logins, profile directories, URLs and user libraries stay outside this Git source.

Eligible explicitly requested web video can hand off to native playback and return to its originating tab; fullscreen stays in the browser from0.17.1. The extractor/runtime uses pinned yt-dlp and youtubedl-android; page-derived media/projection and selected browser-session information are passed through bounded runtime interfaces. Signed links/cookies are runtime data, never shipped credentials. Only selected compatible formats are handed off; YouTube selection is bounded to up-to-4K SDR, not every representation or hardware format. Flat, VR180, 360° and EAC depend on actual stream metadata; a page label is not a projection guarantee. The optional captured spherical-metadata test fixtures are supplied separately; no video/audio sample payload is published.

Site adapters, login permissions, geoblocks, DRM, codecs, expiring links and network conditions can prevent handoff. Subscription pages staying in the website do not establish working premium playback or permission to extract it. Historical disabled/incomplete adapter states are described by dated sections; current availability follows the status above. No bypass of DRM/paywalls or universal website playback is claimed. Browser navigation and native media extraction remain distinct operations.

Featured sites use horizontal icon/name cards with catalog pagination. In 0.17.5 only the four scoped overseas Featured journeys above and validated domestic branches have directory markers; iQIYI/Youku and other foreign entries remain unmarked. Badges are not all-site guarantees, and merely appearing in the catalog is not playback acceptance. Changing language or distribution channel returns to the first page.

## Optional LAN management

The user explicitly starts temporary bookmark/history sharing for a phone/computer on the same network. It supports search/edit, bookmark import/export and copying/removing history, with an optional pairing code and confirmation before closing access. The random access token, pairing state and remote edits are runtime user data. Stop sharing when finished. The Git source includes the local HTML/JS/CSS and synthetic socket/frontend tests, not any real library, token, browser session or device log. No automatic upload is configured.

## Channel and preparation

Both `standard` and `pico_cn_store` enable the browser. The China channel shows only Chinese featured sites (Bilibili, Weibo, Tencent Video, Mango TV, Youku, iQIYI and Douyin), regardless of UI language; standard retains the full catalog. This filters curated recommendations rather than arbitrary address entry. Account web login stays independent. These are build-time channels, not saved preferences, and keep the same application ID/signing identity; installing one over the other replaces it rather than creating a second app. Source defaults to standard. No channel change clears website data or implies store approval.

The pinned GeckoView ARM64 artifact/source revision, MPL-2.0, yt-dlp/Android wrapper notices and ICU charset detection notice accompany `third_party`. Binaries, Python runtime, engine AAR and yt-dlp asset are external preparation inputs. Build-Player prepares/verifies the runtime and browser toolchain, checks packaged runtime/channel fields and retains runtime platform min/target SDK. Public verification does not log into a website or operate a headset. See [build instructions](BUILD.md) and [licensing](LICENSING.md).

浏览器为Beta，站点、DRM、网络与实际格式会限制播放。普通与国内渠道均开放入口，国内渠道精选仅显示中国网站；源码不含Cookie、书签历史、分享口令、登录档案或真实视频样本。

## 0.15.2 window and media detection behavior

Windows are peers with explicit close, merge and tab-transfer controls. New tabs offer paginated featured sites/bookmarks. Handoff state belongs to its source page; other windows stay available. Native handoffs do not add global playback history. Multiple visible windows do not promise concurrent native video playback.

Per-site media detection is opt-in. Eligible captured streams can retain the selected website quality, including compatible server direct-play/resume. A failed quality-preserving transfer returns to the browser instead of silently substituting a lower-quality preview. DRM/EME and unsupported containers stay in the website. Signed links, request headers and cookies are ephemeral session data, excluded from source. This release retains the pinned extractor/Python/QuickJS fallback; a future Gecko-only architecture is not implemented here.

The optional Meta store target uses `quest_store`, enables the full browser/catalog, and has the separate `com.thru3d.quest` application identity. Request it explicitly with Build-Player `-QuestStore`; it does not replace either PICO channel.

## Bilibili Play (Beta), 0.16.0

The separate Beta button preserves the original Play route. It reads the active logged-in browser session and current UGC part/PGC episode responses, binds declared full-file tracks to actually observed requests and retains origin-scoped headers. It pauses source-page playback before resolution. Stale/cross-episode responses, absent tracks, DRM, unavailable entitlement, unsupported formats or site changes can return the user to the browser; member access is not universally supported and permissions are not bypassed. No account import, cookie/profile export or live media URL is part of this repository. Python/QuickJS/yt-dlp remain prepared runtime dependencies.

0.16.1 adds region focus and provider-specific in-headset authentication windows, preserving sessions across ordinary panel visibility and guarding detached input teardown. Ordinary controls are gated behind authentication; cookies/tokens remain runtime-private. Bilibili Beta waits for current-media readiness and preserves primary capture through previews, cancellation and restored sessions. Retired Gecko sessions release media before native playback. No real-account universal login acceptance is implied.

In 0.16.2 Douyin native/Beta playback remains unavailable. Adapter and diagnostic source is retained for development; its presence is not a supported user route. No live site/account or DRM acceptance is established by source-only checks.

0.16.3 improves cloud authorization font visibility and restarts eligible desktop/mobile mode retries at the authorization entry with the chosen viewport already applied. Browser/account authorization windows share the managed Gecko profile, while provider nonce/state checks and tab delegate separation remain. This does not establish universal provider login acceptance. Douyin remains closed in the public export, including Debug research capture; adapters and synthetic tests remain technical source only.

0.16.5 supports independent edge/corner resizing across nominal viewport thresholds, portrait layouts and pixel-budget limits; beyond layout bounds the window scales rather than repeatedly changing page resolution. Current-page state is restored after eligible SPA native handoff. Trust follows the verified page/frame's real current-media requests and track identity, including related hosting domains; each request retains only its own observed credential scope. This does not authorize copying cookies/Authorization to unrelated requests.

In the historical 0.16.5 release Douyin was temporarily unavailable after the featured-entry regression, including diagnostic overrides; paused Douyin/Mango/Youku research is not resumed by this source synchronization. Historical direct-page results do not establish featured/home/unchanged-URL switching acceptance. Jellyfin/Plex web adapters are retained source and are not advertised as completed0.16.5 features; normal media-library support is separate.

## 0.17.0 scope

Experimental page/focused-region stereo conversion and person passthrough can be combined; controls sit below the page and are captured sharply. Adapted Bilibili/Weibo/Tencent/Mango sites prefer Beta and current-document handoff, supported HEVC/TS/inline metadata and retained-document return. Scope follows observed current-media association and protection checks, not all site content. Douyin remains unavailable; this source synchronization performs no live site probes or paused domestic-site research.

## 0.17.1 explicit handoff and pure-page view

Fullscreen and Emby/Jellyfin/Plex page playback stay in the browser; no automatic pause, native-player switch or speculative background pre-resolution is triggered by them. Users retain browser 3D and explicit playback actions. Existing server buttons/retained-document return remain; the proposed new server Beta experiment is withdrawn. Pure-page view hides chrome/resize handles while preserving page interaction/focus, with an explicit way back. The strength popup stays above the lower frame. Compatible Youku Beta uses actual current-media association and source-scoped requests; site/account/entitlement/verification limits remain. Passive iQIYI diagnostic source is not an enabled Beta or a completed release feature.

## 0.17.2 adapted routes and controls

iQIYI, Douyin and Niconico add site-specific Play Beta routes with actually observed current-media/request binding and retained-page return. Niconico reuses the observed signed master manifest and restores time through the bound player setCurrentTime API. Foreign sites keep the legacy manual button independently cancellable alongside Beta; domestic presentation is unchanged. This supersedes the older Douyin/iQIYI availability statements above, without claiming all-content, entitlement or headset acceptance. Server buttons remain the existing manual ones; no fullscreen auto-handoff or withdrawn server experiment is restored. Keyboard visibility, address-field paste and focus aspect matching improve; hidden controls can optionally enable browser3D. Unfocused-key delivery and per-site fullscreen chrome behavior are not advertised as verified features.

## 0.17.3 site and recovery scope

Twitch public clips, TikTok detail, TED and Dailymotion have bounded reported headset handoff/seek/retained-page checks. Instagram headset evidence covers explicitly silent content; its audible hardware branch is not accepted. Red Bull, Streamable, Internet Archive and Odysee add adapter/entry source with local checks, not complete headset acceptance. iQIYI active SDK-quality/full-timeline binding, escaped Youku IDs and source-reset recovery change, but remaining hardware/site challenges are not declared solved. New adapters keep observed current-media identity, protection and per-request credential scope; foreign legacy manual actions remain independently available. History shortcuts and rejected external-app navigation retain the page. Generic OpenXR system-keyboard fallback/selection improves. This synchronization performs no live-site research, APK build or headset operation and does not resume the paused website task.

0.17.5 adapts ordinary rendered-player ownership/SPA changes, large HLS/MP4 declarations and complete iQIYI bridge payloads. Naver Clip/Reddit retain separate limited page/device evidence, but have no accepted Featured-entry chain; their new source is not catalog acceptance. The TED manifest/script/test inputs match the recorded release cut; their inclusion is not headset acceptance or a new Featured badge. No observed cookies, tokens, signed media addresses or user profiles are exported. Synthetic large-wire fixtures use declared.test/sdk.test data, not captured account payloads.
