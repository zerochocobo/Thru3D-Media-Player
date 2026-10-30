# Runtime models

No model weights are stored in this Git repository. `models/manifest/runtime-assets.json` records the exact runtime MNN files, their sizes, SHA256 and conversion manifests. Model licenses remain in `models/licenses`.

## Version-matched assets

Normal playback expects:

```text
external-model-assets/
  rvm-mnn/rvm.mnn       modified/distilled RVM, RGBA uint8-range input
  depth-mnn/depth.mnn   ZipDepth video comparison profile, 512×288 input
  depth-mnn/depth_compat.mnn   ZipDepth video default on every headset, 384×224 input
  depth-mnn/photo_depth.mnn   Independent still-photo Depth Anything V2 Small, 518×518 input
```

Import without trusting the supplied files' own metadata:

```powershell
./tools/Import-ModelAssets.ps1 -FromDirectory ./external-model-assets
./tools/Import-ModelAssets.ps1 -VerifyOnly
```

The importer checks every model against the committed catalog before copying, reconstructs the model manifests, and installs the license notices. Models land in ignored Android assets. Do not commit them. The prepared-assets build mode supports ordinary Debug/Release builds; full numerical diagnostics require additional reference models and generated oracles.

**There is no hosted download for the project-distilled student in this initial source release.** A matching, independently obtained model directory is required for an APK build. Do not invent a release URL or substitute an upstream file while retaining the student's checksums. The importer fails explicitly if the files are missing or wrong. Source-only tests do not need these files.

## Source and transformations

| Model | Source | Project transformations |
| --- | --- | --- |
| RVM MobileNetV3 | [RVM v1.0.0](https://github.com/PeterL1n/RobustVideoMatting/releases/tag/v1.0.0); pinned ONNX in `rvm_mobilenetv3.json` | Ratio=1 specialization, unused output pruning, 0..255/RGBA input handling, operator fusion, sliced decoder and recurrent student distillation, MNN conversion. |
| ZipDepth base | Fixed revision `91f3fd21e131641f51e8d35736d1958350180e3a` of https://github.com/fabiotosi92/ZipDepth; checkpoint/source pins in `zipdepth_video*.json` | Video/portrait: FP16 512×288 and 384×224. Default all-headset 384×224 at LOW GPU priority; equivalent dense 1×1 projections and clamped convex upsample rewrite, retaining learned global context. |
| Depth Anything V2 Small | [ONNX model](https://huggingface.co/onnx-community/depth-anything-v2-small); source SHA256 in the runtime conversion manifest | Photos only: independent 518×518 model, aspect-preserving letterbox, content-only normalization. Folds input normalization, rewrite patch embedding/attention, and use MNN FP16 weights. |

RVM uses four recurrent states independently for each eye. Runtime models are not generic arbitrary ONNX/MNN files; tensor names, dimensions, conventions and the patched MNN kernels are part of the interface contract.

Relevant tools:

- `Prepare-RvmReference.ps1`: retrieve/import the pinned upstream ONNX with hash verification.
- `specialize_rvm_ratio_one.py`, `fuse_rvm_graph.py`, `slim_rvm_decoder.py`: graph modifications.
- `distill_rvm_decoder.py`: train/export a student using explicitly supplied, licensed media. `data --sources` takes a JSON array of `{ "file": "path/to/your-video.mp4", "exclude_seconds": [[0, 5]] }`; no original training filenames are built in.
- `prepare_rvm_mnn.py`: convert the matching student and upstream quality graph using `MNNCONVERT`.
- `prepare_depth_mnn.py --photo --install`: prepare the independent photo graph with caller-supplied licensed sample images.
- `prepare_zipdepth_mnn.py` and `zipdepth_mobile.py`: prepare/verify the pinned ZipDepth graph from caller-supplied source/checkpoint and at least four licensed images. Supply `--source`, `--images`, `--mnn-python`, `--mnnconvert`; run both default and `--compatible` profiles. Matching checkpoint/source hashes and `reviewed-commit.txt` are required; the script does not download or include weights. `Assert-VideoDepthModels.ps1` verifies both runtime graph contracts.
- `tools/mnn/patch_mnn_vrpp.py`: reproduce the MNN OpenCL HardSwish changes required by the matting graph.

For example, graph preparation begins with:

```powershell
./tools/models/Prepare-RvmReference.ps1
./.venv/Scripts/python.exe tools/models/specialize_rvm_ratio_one.py
$env:MNNCONVERT = (Get-Command mnnconvert).Source
```

Re-training on other media will generally produce different student weights and cannot reproduce the pinned student checksum. Changing a model requires updating the contract/catalog, conversion evidence and runtime validation together. Do not disable hash checks to imply equivalence.

## Licenses

The upstream RVM code is GPL-3.0; the project records its reused/sliced student weights as GPL-derived. The actual weight grant and appropriate modifiable form must be considered when distributing them. Depth Anything V2 **Small** weights are Apache-2.0; Base/Large/Giant have different terms. Excluding weights from Git does not settle obligations for APKs that embed them. See [licensing scope](LICENSING.md).

## Runtime Alpha sizes

The global inference-size choice is 256/320/384/512 (default 320), using the version-matched modified RVM contract above. This is not a general model-weight selector. First use of a size can prepare for about a minute while the existing size remains usable. No weights or private preparation caches are published. New Alpha processing-limit settings default to 30 FPS; saved settings take precedence, and actual throughput depends on device and media.

## Subtitle narration

Normal Debug and Release builds require the separate, version-matched INT8 bundle in `third_party/narration/model.json`: 11 size/SHA-256-pinned files, including data for 12 Chinese/English/Japanese voice presets. Supply it with `tools/environment/Prepare-NarrationModels.ps1 -SourceDirectory <bundle>` or `THRU3D_NARRATION_MODEL_SOURCE`; verified files persist under ignored `models/narration/<manifest-id>/`. Missing/corrupt files stop the build; no weights, preset codes or reference recordings are distributed in this Git source.

Runtime notices and model metadata do not grant rights to excluded voice inputs. The independent commercial-source audit of reference recordings remains unresolved. Build enablement and this source release are not copyright clearance for those recordings. Narration supports text subtitles; it does not imply bitmap-subtitle OCR or translation.

### Custom voices in 0.12.2

The separate `third_party/narration/clone_model.json` pins two reference-encoder files. Prepare them with `tools/environment/Prepare-VoiceCloneModels.ps1 -SourceDirectory <bundle>` or `THRU3D_NARRATION_CLONE_SOURCE`; storage is the ignored `models/narration/<clone-id>/`. Normal builds require both the existing 11-file narration bundle and this two-file encoder bundle. No missing-input fallback disables the feature silently.

The UI supports 19 text languages; the 12 preset voice origins are unchanged. Custom voice creation requires a suitable caller-provided audio reference and saves reference audio, codes and metadata in persistent app-private storage. None of these personal inputs/voices are published here, and runtime source/metadata do not confer rights to a person's voice or reference recording.

### Subtitle-free voice sampling in 0.13.3

`third_party/narration/vad_model.json` pins the MIT Silero VAD v6.2 model to its upstream revision, size and SHA-256; `SILERO_LICENSE.txt` retains the original notice. Supply the matching `silero_vad.onnx` with `tools/environment/Prepare-VoiceVadModel.ps1 -SourceDirectory <bundle>` or `THRU3D_VOICE_VAD_SOURCE`. The checked payload stays in ignored `models/narration/<vad-id>/`. Normal narration preparation and AAR/APK validation require this third bundle in addition to the INT8 narration and reference encoder files. No VAD weight is committed.

The unified sampling flow uses a caller-selected audio/video source and track, a bounded scan range, streaming speech activity detection, candidates, inline cropping and audition before saving a custom voice. Preview text covers the existing 19 text languages. Speech detection is not speaker diarization, separation or recording-rights clearance. References, cloned codes and personal voices remain app-private and excluded from public Git.

## Comic OCR

Two external PP-OCRv6 Small files are pinned in `third_party/comic-ocr/model.json`, separately from narration/reference/VAD. See [preparation/data boundaries](COMIC_READING.md). No OCR weight, training page or private transcript is published; existing voice provenance limitations remain.

## Live subtitle recognition

Three separately prepared Moonshine Tiny Streaming language bundles (24 pinned files) are required by normal Debug/Release builds. No ASR payload is committed. See [live subtitle preparation, privacy and limits](LIVE_SUBTITLES.md).

0.14.1 requires a third, pinned auxiliary manga detector alongside the original two OCR files; the runtime does not use the compared manga recognizer. See [comic preparation and reading dictionary](COMIC_READING.md). No new weight or private sample is published.

## ZipDepth and video strength in 0.16.0

The two ZipDepth runtime graphs are separate from still-photo Depth Anything V2. All headsets currently choose the 384×224 compatibility graph; the 512×288 graph remains packaged for comparison. Relative inverse depth is normalized over content after edge-filled letterboxing. Inference and temporal stabilization overlap using bounded frame ownership. No universal FPS, fidelity or all-headset acceptance follows from source checks.

Video 2D-to-3D defaults to Stretch edges, with Fill gaps as an alternative. The video slider is linear 0–100%, recommended 50%; its new maximum corresponds to the former 50%, with a one-time capped migration for saved choices. Photo strength retains 0–200%. These are rendering preferences, not a model selector.

ZipDepth upstream is MIT; its deployment approach also references the GPL-3.0 xr-3d-viewer conversion, with retained attribution in `zipdepth_mobile.py` and third-party notices. Rewritten convex weights clamp centered logits at 8 for FP16 range; do not describe the whole deployment as bit-exact upstream inference. Public manifests retain contracts and hashes, excluding private sample evaluation records and weights. Reference assets and any APK distribution need their own matching input/license review.
