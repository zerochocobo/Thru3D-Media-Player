# Offline subtitle narration dependencies

- ONNX Runtime 1.28.0: Microsoft, MIT; upstream and stripped runtime digests in dependencies.json.
- SentencePiece 0.2.1: Google, Apache-2.0; bundled protobuf-lite, Abseil and Darts-clone notices retained.
- nlohmann/json 3.12.0: Niels Lohmann, MIT.
- MOSS-TTS-Nano runtime semantics: OpenMOSS revision 8b7bcc9341b3b4ef3a3a58ba1338a7d85ff133eb, Apache-2.0.
- Subtitle extraction uses the existing pinned MPV/FFmpeg binaries and license/source records under third_party/mpv.

The copied notices retain their copyright statements and conditions; trailing whitespace and extra blank lines at EOF are normalized.
No model weights, preset codes or reference recordings are bundled here. The individual reference-recording provenance for the four preset IDs remains unverified for commercial distribution. The separate pinned model provisioner is for local testing.
