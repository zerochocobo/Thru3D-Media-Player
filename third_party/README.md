# Third-party components

This directory retains upstream license texts, source locks, checksums and provenance. The application's overall GPL v3 choice does not replace these components' existing terms. See [licensing scope](../docs/LICENSING.md) for the component inventory and binary-release requirements.

- `openxr`: Khronos OpenXR headers used by the native compositor-layer bridge; their Apache-2.0 license text and upstream header notices are retained. Godot supplies the runtime loader.
- `mpv`: headers/provenance, exact source archives, library reference receipt and GPL/LGPL texts. The project's source-frame modification is in `native/mpv/patches`.
- `p115rsacipher`: original MIT notice and provenance for the Kotlin 115 RSA adaptation.
- `gradle`: wrapper Apache-2.0 license and notice.
- `polyhaven`: CC0 source and attribution for the unmodified built-in background.
- `openlist`: AGPL-3.0 upstream license, Go/gomobile and dependency notices; the local Go adapter is in `cloud/openlist`, with the checksum-pinned build and source modification in `tools/environment/Prepare-OpenList.ps1`.

Godot, Godot OpenXR Vendors, MNN, ncnn and Maven dependencies are prepared externally. Keep their exact-version notices with redistributed outputs. The MNN fork is built from upstream 3.6.1 plus `tools/mnn/patch_mnn_vrpp.py`; models use their separately recorded licenses.

The repository includes only synthetic test media. Private human-video fixtures and model weights are excluded.

The CodeLibs JCIFS jar is staged by Gradle with unused HTTP/HTTPS NTLM adapters removed. Retained classes/resources keep upstream bytes and notices; SMB functions remain available. The combined binary OpenList obligations are recorded in the licensing scope above.

- edge264-mvc: pinned BSD-3-Clause decoder source recipe and license under third_party/edge264-mvc; player adapters are in native/mpv/mvc.
- libbluray and libudfread: pinned upstream source recipes and LGPL-2.1-or-later texts under third_party/bluray, linked through the FFmpeg source candidate.
- Thru3D CJK punctuation: renamed bracket-only subset of Noto Sans CJK SC 2.004 under SIL OFL-1.1; exact source/hash, rebuild script and notices accompany the font under app/godot/assets/fonts.

- Godot GDExtension C interface: unmodified compile-time header from Godot 4.5-stable, core/extension/gdextension_interface.h. The original MIT text is retained at native/xr-layer/gdextension/LICENSE.txt; the local OpenXR registration bridge uses the forward-compatible C ABI without godot-cpp.
