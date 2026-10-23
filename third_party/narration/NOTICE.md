# Offline subtitle narration dependencies

- ONNX Runtime 1.28.0: Microsoft, MIT; upstream and stripped runtime digests in dependencies.json.
- SentencePiece 0.2.1: Google, Apache-2.0; bundled protobuf-lite, Abseil and Darts-clone notices retained.
- nlohmann/json 3.12.0: Niels Lohmann, MIT.
- MOSS-TTS-Nano runtime semantics: OpenMOSS revision 8b7bcc9341b3b4ef3a3a58ba1338a7d85ff133eb, Apache-2.0.
- Subtitle extraction uses the existing pinned MPV/FFmpeg binaries and license/source records under third_party/mpv.
- Reference encoding uses MOSS-Audio-Tokenizer-Nano-ONNX revision ceff0d0749bfb3fa2d61149794ec6feef0d1e1ae; the two encoder payload hashes are pinned in clone_model.json. Audio segment conversion reuses the same FFmpeg/libswresample build. The encoder is loaded only by the private voice-clone process.

The copied notices retain their copyright statements and conditions; trailing whitespace and extra blank lines at EOF are normalized.
Normal Debug and Release packages include the verified INT8 model payload and built-in prompt codes from the Git-ignored models/narration cache. Raw reference audio is not included. The model/repository declare Apache-2.0; recording-by-recording provenance for the 12 selected presets remains unverified in the separate licensing review. Project authorization to bundle them does not itself establish third-party recording rights.

- Speech activity detection: Silero VAD v6.2, revision be95df9152c0d7618fa1edfeb296fc3dae32376f, MIT. See SILERO_LICENSE.txt and vad_model.json for the pinned upstream URL and SHA-256. Weights remain outside Git under models/narration. Streaming inference follows the upstream 512-sample / 64-context / recurrent-state interface. No speaker diarization or source separation is included.
