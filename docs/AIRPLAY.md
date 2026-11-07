# AirPlay reception (experimental)

The library sidebar provides independent DLNA and AirPlay reception switches/status. Compatible AirPlay mirroring opens an independent window with ray/grip movement, resizing, distance and audio controls. Reception state, pairing validation, rotation surfaces and initial placement have dedicated source checks. Device/network/OS/content differences remain; no Apple certification, protected-content compatibility or universal phone acceptance is claimed.

The protocol is based on pinned UxPlay and Android adaptation, with retained ShairPlay/RPiPlay, llhttp/playfair, libplist and OpenSSL notices in third_party/airplay. sources.json records exact source URLs, archive hashes and patched outputs. Prepare-Airplay.ps1/prepare_airplay.py restore those sources for the native CMake build. The 20-byte SRP-SHA1 proof-length patch and local synthetic regression are included. Pairing/session keys are runtime data, never source assets; no phone identity, password, private key or captured stream is shipped.

AirPlay窗口不是原生提取所有手机应用视频；接收需要合适网络及来源允许。PIN／会话凭据仅运行时产生，源码不含用户手机记录或投屏样本。普通Debug继续排除私人沙滩资源，不需要生成沙滩建模。

## 0.17.1 access and decoder configuration

Pairing without a manually entered code is the default. A globally remembered password requirement switches to a fresh verification code for connections; both paths retain encrypted pairing, and neither stores user passwords in source. Decoder configuration/parameter sets survive timestamp changes until replaced, improving affected first-frame and audio readiness. Synthetic SRP/profile/transport checks do not establish all-device or iPad acceptance.

## Known verification limit in 0.17.1

The optimized Linux host protocol regression reproducibly accepts an earlier Digest challenge nonce after a failed password attempt (HTTP/RTSP 200 where 401 is expected). This is an unresolved authentication freshness defect, not a passing security check. The upstream nonce-generation call is inside an assertion that is removed with `NDEBUG`; the optimized host build uses that flag. Android behavior has not been independently retested during this source synchronization. Do not rely on the password option as a strong network access boundary; use experimental reception only on a trusted network. The released runtime source is preserved here pending a separately validated fix.

0.17.1 本地优化构建的协议回归可重复发现旧 Digest nonce 被接受，不能把口令模式当作可靠的网络访问边界；请只在可信网络使用实验性接收。上游 nonce 生成位于会被 NDEBUG 移除的断言内，本轮未重新验收 Android 行为，也未修改发布运行源码来掩盖失败。
