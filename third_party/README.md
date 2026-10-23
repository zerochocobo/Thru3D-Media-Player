# Third-party components

This directory retains upstream license texts, source locks, checksums and provenance. The application's overall GPL v3 choice does not replace these components' existing terms. See [licensing scope](../docs/LICENSING.md) for the component inventory and binary-release requirements.

- `openxr`: Khronos OpenXR headers used by the native compositor-layer bridge; their Apache-2.0 license text and upstream header notices are retained. Godot supplies the runtime loader.
- `mpv`: headers/provenance, exact source archives, library reference receipt and GPL/LGPL texts. The project's source-frame modification is in `native/mpv/patches`.
- `p115rsacipher`: original MIT notice and provenance for the Kotlin 115 RSA adaptation.
- `gradle`: wrapper Apache-2.0 license and notice.
- `polyhaven`: CC0 source and attribution for Belfast Sunset and the derived Morning Sky background; image notices and the conversion recipe accompany the source.
- `openlist`: AGPL-3.0 upstream license, Go/gomobile and dependency notices; the local Go adapter is in `cloud/openlist`, with the checksum-pinned build and source modification in `tools/environment/Prepare-OpenList.ps1`.

Godot, Godot OpenXR Vendors, MNN, ncnn and Maven dependencies are prepared externally. Keep their exact-version notices with redistributed outputs. The MNN fork is built from upstream 3.6.1 plus `tools/mnn/patch_mnn_vrpp.py`; models use their separately recorded licenses.

The repository includes only synthetic test media. Private human-video fixtures and model weights are excluded.

The CodeLibs JCIFS jar is staged by Gradle with unused HTTP/HTTPS NTLM adapters removed. Retained classes/resources keep upstream bytes and notices; SMB functions remain available. The combined binary OpenList obligations are recorded in the licensing scope above.

- edge264-mvc: pinned BSD-3-Clause decoder source recipe and license under third_party/edge264-mvc; player adapters are in native/mpv/mvc.
- libbluray and libudfread: pinned upstream source recipes and LGPL-2.1-or-later texts under third_party/bluray, linked through the FFmpeg source candidate.
- USB storage: checksum-pinned FatFs R0.16 (BSD-style) and NTFS-3G 2026.9.28 (GPL-2.0-or-later) source archives, plus the Apache-2.0 notice for the libaums-derived BOT/SCSI adaptation, under `third_party/usb`. The read-only adapters and native build configuration are in `native/usb` and the Android plugin.
- Thru3D CJK punctuation: renamed bracket-only subset of Noto Sans CJK SC 2.004 under SIL OFL-1.1; exact source/hash, rebuild script and notices accompany the font under app/godot/assets/fonts.

- Godot GDExtension C interface: unmodified compile-time header from Godot 4.5-stable, core/extension/gdextension_interface.h. The original MIT text is retained at native/xr-layer/gdextension/LICENSE.txt; the local OpenXR registration bridge uses the forward-compatible C ABI without godot-cpp.

- Default narration runtime source: ONNX Runtime and nlohmann/json (MIT), SentencePiece and MOSS runtime semantics (Apache-2.0), with bundled subcomponent notices in `third_party/narration`. Only source recipes, notices and metadata are included; no narration weights, preset codes or reference recordings.

- Built-in music and ambient recordings are excluded. Only their version-matched file metadata accompanies the player source; the project GPL license does not grant rights to excluded sound recordings. See `docs/AUDIO.md`.

- Optional experimental Windows desktop video: checksum-pinned FFmpegPlayer source/dependency recipes, local native patch and MIT/LGPL notices in `third_party/desktop-video`. No DLLs or archives are included; see `docs/EXPERIMENTAL_CINEMA.md` for build scope.

- Capture bridge compile-time FFmpeg headers: copied from the already pinned FFmpeg source, with local Android ARM64 public-header configuration, an adjacent per-header catalog and LGPL v2.1 text under `native/mpv/include/ffmpeg`. The runtime dependency and its separate license/source records are unchanged.

- Image decoders: checksum-pinned libtiff 4.7.2, libjpeg-turbo 3.1.2, OpenEXR 3.3.14, Imath 3.1.12 and libdeflate 1.24 source archives with their original notices under `tiff` and `openexr`. BSD-style, IJG and other included component terms remain applicable; see [image formats](../docs/IMAGE_FORMATS.md). No prebuilt image libraries are included.

- PICO controller fallback meshes: unmodified MIT WebXR Input Profiles assets, supplied separately using the pinned metadata and adjacent notice. MRTK3-derived hand joint interaction retains its notice in third_party/player-licenses/mrtk3.txt. CC0 cinema scan metadata and preparation recipes retain original asset provenance; raw scans, generated scenes and bakes are excluded.
