# AirPlay reception (experimental)

The library sidebar provides independent DLNA and AirPlay reception switches/status. Compatible AirPlay mirroring opens an independent window with ray/grip movement, resizing, distance and audio controls. Reception state, pairing validation, rotation surfaces and initial placement have dedicated source checks. Device/network/OS/content differences remain; no Apple certification, protected-content compatibility or universal phone acceptance is claimed.

The protocol is based on pinned UxPlay and Android adaptation, with retained ShairPlay/RPiPlay, llhttp/playfair, libplist and OpenSSL notices in third_party/airplay. sources.json records exact source URLs, archive hashes and patched outputs. Prepare-Airplay.ps1/prepare_airplay.py restore those sources for the native CMake build. The 20-byte SRP-SHA1 proof-length patch and local synthetic regression are included. Pairing/session keys are runtime data, never source assets; no phone identity, password, private key or captured stream is shipped.

AirPlay窗口不是原生提取所有手机应用视频；接收需要合适网络及来源允许。PIN／会话凭据仅运行时产生，源码不含用户手机记录或投屏样本。0.17.2起Debug与Release均要求另行准备沙滩资源，公开Git仍不含场景／模型数据。

## 0.17.1 access and decoder configuration

Pairing without a manually entered code is the default. A globally remembered password requirement switches to a fresh verification code for connections; both paths retain encrypted pairing, and neither stores user passwords in source. Decoder configuration/parameter sets survive timestamp changes until replaced, improving affected first-frame and audio readiness. Synthetic SRP/profile/transport checks do not establish all-device or iPad acceptance.

## Known verification limit in 0.17.1

The optimized Linux host protocol regression reproducibly accepts an earlier Digest challenge nonce after a failed password attempt (HTTP/RTSP 200 where 401 is expected). This is an unresolved authentication freshness defect, not a passing security check. The upstream nonce-generation call is inside an assertion that is removed with `NDEBUG`; the optimized host build uses that flag. Android behavior has not been independently retested during this source synchronization. Do not rely on the password option as a strong network access boundary; use experimental reception only on a trusted network. The released runtime source is preserved here pending a separately validated fix.

0.17.1 本地优化构建的协议回归可重复发现旧 Digest nonce 被接受，不能把口令模式当作可靠的网络访问边界；请只在可信网络使用实验性接收。上游 nonce 生成位于会被 NDEBUG 移除的断言内，本轮未重新验收 Android 行为，也未修改发布运行源码来掩盖失败。

0.17.2 includes a change to begin composition after decoded output submission, but its reported phone picture/audio issue has not completed acceptance and is not advertised as a verified fix. The optimized-host authentication defect above is not repaired by this source update.

## 0.17.3 reception boundary

Miracast is hidden and detached from the shared receiver in all builds; it is an abandoned dormant experiment, not phone mirroring support. DLNA/AirPlay remain. No helper activation, device probing or app-installed sender is required or performed by source synchronization. The existing optimized-host AirPlay Digest freshness defect is unchanged and is not a passed security check.

## 0.17.6 player mode

An AirPlay mirror starts in picture-in-picture and can be expanded into the regular live player. Compatible streams can use 2D-to-3D or person passthrough, alongside live captions and mute. The return control restores the original window position and size in the same session and adapts to the current phone orientation. Playback controls reflect the live stream. Phone and low-end headset performance varies. The protocol and its existing authentication limitation above remain unchanged.

AirPlay 从画中画进入普通实时播放器，可使用兼容的 2D 转 3D 或人物透视，并可同时开启实时字幕。返回时在同一会话恢复原窗口位置和大小，按手机当前横竖屏重新布局。

## 0.17.7 discovery diagnostics

Exported diagnostics include native receiver startup and Android service registration outcomes. Discovery reliability remains under investigation.

## 0.17.9 multicast reception

AirPlay holds its own Android multicast lock while reception is enabled, so discovery does not depend on DLNA being active.
