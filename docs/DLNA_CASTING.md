# DLNA video casting receiver

From 0.13.3, enable the receiver in the player to advertise Thru3D as a foreground LAN MediaRenderer. Compatible senders provide an HTTP(S) video URL to the existing VR playback path. This is separate from browsing a DLNA server, phone-screen mirroring, AirPlay or Google Cast. Availability depends on the sender, network, URL lifetime, codecs and DRM; no universal app support is claimed.

Idle reception can accept a requested video automatically. Replacing active video/photo playback asks for confirmation. Text editors and independent games/voice management defer offers. Phone Play/Pause/Stop/Seek and volume/mute use the active transport token; stale commands cannot own a newer cast. Stop ends the cast and retains an explicit return to the previous media. Selecting ordinary local media detaches the cast. Reception is opt-in, with no pairing/authentication layer; any reachable compatible LAN controller may offer a video while enabled.

Cast links stay out of ordinary playback history, favorites, file-settings storage and source-dependent file/capture operations. An offer and its title/metadata are transient runtime state, not a public test input. Backgrounding stops network reception/discovery but retains the renderer state; foregrounding tries to reopen its port. This does not promise background streaming.

The bounded HTTP/SOAP layer accepts supported vendor arguments and transport actions. DTD/entities are rejected; GENA callbacks must match the requesting peer. Literal loopback, unspecified and link-local media destinations are rejected; hostnames are not DNS-resolved by this validation, so it is not a complete DNS-rebinding defense. Native cast limitations stay visible through the existing player capabilities.

The repository contains protocol source, synthetic/loopback tests and UI fixtures only. It contains no captured phone traffic, signed CDN links, personal titles or account credentials. Real LAN discovery, headset lifecycle and individual sender compatibility need separate device verification.

0.13.3 新增局域网 DLNA 视频接收，手动开启、正在播放时确认替换，停止后可返回原媒体；不是手机屏幕镜像。投屏地址不进入普通历史／收藏／逐片记忆。此协议未提供配对认证，启用期间兼容局域网控制端可发起请求；后台暂停网络接收，兼容性受发送端、媒体地址及设备限制。
