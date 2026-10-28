# Browser and web-video scope

The standard channel includes a GeckoView browser (Beta), with up to four tabs and two visible windows. Floating/cinema placement, draggable chrome, title/close/navigation controls, system/ray keyboard input and recovery share the player UI. Inactive sessions are unloaded/recovered to bound work. Normal exit coordinates profile shutdown; website state is not guaranteed after force termination. Bookmarks/history are separate from website login; clearing history does not sign out. Cookies, logins, profile directories, URLs and user libraries stay outside this Git source.

Eligible manually requested or fullscreen web video can hand off to native playback and return to its originating tab. The extractor/runtime uses pinned yt-dlp and youtubedl-android; page-derived media/projection and selected browser-session information are passed through bounded runtime interfaces. Signed links/cookies are runtime data, never shipped credentials. Only selected compatible formats are handed off; YouTube selection is bounded to up-to-4K SDR, not every representation or hardware format. Flat, VR180, 360° and EAC depend on actual stream metadata; a page label is not a projection guarantee. The optional captured spherical-metadata test fixtures are supplied separately; no video/audio sample payload is published.

Site adapters, login permissions, geoblocks, DRM, codecs, expiring links and network conditions can prevent handoff. Subscription pages staying in the website do not establish working premium playback or permission to extract it. Douyin native handoff is disabled after the separate-audio attempt was withdrawn; Twitch/Niconico remain unreliable. No bypass of DRM/paywalls or universal website playback is claimed. Browser navigation and native media extraction remain distinct operations.

## Optional LAN management

The user explicitly starts temporary bookmark/history sharing for a phone/computer on the same network. It supports search/edit, bookmark import/export and copying/removing history, with an optional pairing code and confirmation before closing access. The random access token, pairing state and remote edits are runtime user data. Stop sharing when finished. The Git source includes the local HTML/JS/CSS and synthetic socket/frontend tests, not any real library, token, browser session or device log. No automatic upload is configured.

## Channel and preparation

`standard` enables the browser. `pico_cn_store` hides its entry and blocks direct opening while leaving account web login independent. These are build-time channels, not saved preferences, and keep the same application ID/signing identity; installing one over the other replaces it rather than creating a second app. Source defaults to standard. No channel change clears website data or implies store approval.

The pinned GeckoView ARM64 artifact/source revision, MPL-2.0, yt-dlp/Android wrapper notices and ICU charset detection notice accompany `third_party`. Binaries, Python runtime, engine AAR and yt-dlp asset are external preparation inputs. Build-Player prepares/verifies the runtime and browser toolchain, checks packaged runtime/channel fields and retains runtime platform min/target SDK. Public verification does not log into a website or operate a headset. See [build instructions](BUILD.md) and [licensing](LICENSING.md).

浏览器为Beta，站点、DRM、网络与实际格式会限制播放。仅普通渠道开放入口；源码不含Cookie、书签历史、分享口令、登录档案或真实视频样本。
