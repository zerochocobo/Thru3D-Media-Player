# Browser and web-video scope

The standard channel includes a GeckoView browser (Beta), with up to four tabs and four visible windows on the higher-performance tier (two on the lower tier). Floating/cinema placement, draggable chrome, title/close/navigation controls, system/ray keyboard input and recovery share the player UI. Inactive sessions are unloaded/recovered to bound work. Normal exit coordinates profile shutdown; website state is not guaranteed after force termination. Bookmarks/history are separate from website login; clearing history does not sign out. Cookies, logins, profile directories, URLs and user libraries stay outside this Git source.

Eligible manually requested or fullscreen web video can hand off to native playback and return to its originating tab. The extractor/runtime uses pinned yt-dlp and youtubedl-android; page-derived media/projection and selected browser-session information are passed through bounded runtime interfaces. Signed links/cookies are runtime data, never shipped credentials. Only selected compatible formats are handed off; YouTube selection is bounded to up-to-4K SDR, not every representation or hardware format. Flat, VR180, 360° and EAC depend on actual stream metadata; a page label is not a projection guarantee. The optional captured spherical-metadata test fixtures are supplied separately; no video/audio sample payload is published.

Site adapters, login permissions, geoblocks, DRM, codecs, expiring links and network conditions can prevent handoff. Subscription pages staying in the website do not establish working premium playback or permission to extract it. Douyin native handoff is disabled after the separate-audio attempt was withdrawn; Twitch/Niconico remain unreliable. No bypass of DRM/paywalls or universal website playback is claimed. Browser navigation and native media extraction remain distinct operations.

Featured sites use horizontal icon/name cards, with up to 15 sites per page. A green player badge identifies sites with successful native-playback samples; hovering explains that only some videos may be compatible. iQIYI and Douyin are browser entries without this badge. Pages expand automatically with the catalog, and switching language or distribution channel returns to the first page.

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
