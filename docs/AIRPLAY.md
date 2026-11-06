# AirPlay reception (experimental)

The library sidebar provides independent DLNA and AirPlay reception switches/status. Compatible AirPlay mirroring opens an independent window with ray/grip movement, resizing, distance and audio controls. Reception state, pairing validation, rotation surfaces and initial placement have dedicated source checks. Device/network/OS/content differences remain; no Apple certification, protected-content compatibility or universal phone acceptance is claimed.

The protocol is based on pinned UxPlay and Android adaptation, with retained ShairPlay/RPiPlay, llhttp/playfair, libplist and OpenSSL notices in third_party/airplay. sources.json records exact source URLs, archive hashes and patched outputs. Prepare-Airplay.ps1/prepare_airplay.py restore those sources for the native CMake build. The 20-byte SRP-SHA1 proof-length patch and local synthetic regression are included. Pairing/session keys are runtime data, never source assets; no phone identity, password, private key or captured stream is shipped.

AirPlay窗口不是原生提取所有手机应用视频；接收需要合适网络及来源允许。PIN／会话凭据仅运行时产生，源码不含用户手机记录或投屏样本。普通Debug继续排除私人沙滩资源，不需要生成沙滩建模。
