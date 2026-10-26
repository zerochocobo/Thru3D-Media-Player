# Live subtitles

For eligible videos without existing subtitle tracks or external subtitle files, enable Live subtitles and choose Chinese, English or Japanese as the speech language. The separate Moonshine Tiny Streaming model performs local recognition on the selected audio. Existing subtitle style/line controls support original and optional translated text. No microphone capture or synthesized interpretation is added.

Video keeps playing while recognition prepares an 8/12/20-second lead. Seeking restarts work at the target and keeps the loaded model; progress and source errors are exposed. Some cloud sources and seeks still have long first-cue delays. Recognition completeness, accuracy, latency and minimum-device throughput are not guaranteed.

Original cues are reused within a bounded per-video cache. Persistence follows the independent per-file settings privacy policy; network content is not written when that policy allows local content only. Disabling persistence does not automatically erase previously saved data; use the existing per-file clearing action. Translation sessions remain runtime data.

Translation is optional and sends recognized dialogue text/language choices to Bing with Edge fallback through the existing comic translation client. It does not upload audio or video. No embedded developer API key is supplied; connectivity, provider behavior and rate limits apply. See [comic translation scope](COMIC_READING.md).

## Separate runtime and models

`third_party/moonshine/model.json` pins upstream source revision 234f60faa0eb388b01cdf7e60aca232af37aefda (v0.1.5), the C API header and 24 files for the three Tiny Streaming bundles. `tools/environment/Prepare-Listening.ps1` builds the runtime from that source and verifies/downloads the pinned model files into ignored `models/listening/{zh,en,ja}/`. Activate the pinned Android toolchain first. `Build-ListeningRuntime.ps1` accepts `-ToolRoot` or `THRU3D_TOOL_ROOT`; it reuses the existing pinned full ONNX Runtime 1.28.0. The source patch and receipts check runtime lifetimes, ELF bindings and packaged hashes. Normal Build-Player prepares and verifies listening for Debug and Release and stops for missing/corrupt inputs.

The retained upstream LICENSE expressly covers these streaming speech models under MIT; the same file separately describes non-streaming legacy models and TTS data with other terms. Do not infer those other models have the same grant. This Git source includes metadata, header, license and preparation tools, without model payloads, native binaries, private transcripts, recordings, credentials or device captures. The existing narration/reference-recording provenance limitation remains; see [models](MODELS.md).

实时字幕支持无现成字幕的视频，本地识别中／英／日语音，可选联网翻译。逐片原文缓存遵循配置隐私策略；首次准备和跳转后可能等待较久。源码仓库不含模型权重、个人字幕／录音、设备数据或凭据。
