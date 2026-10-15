# Source, build and controls guide

Source-release scope, development entry points and detailed controls moved here from the feature overview.

## Source release

This repository contains application source, build scripts, third-party source pins/patches, and tests. Model weights, compiled dependencies, signing keys, personal media and development records are excluded.

**A fresh clone does not yet build an APK without external dependencies and the exact runtime models.** The default matting model is a project-modified, distilled RVM model. Its weights are not hosted in this source release; the upstream RVM checkpoint is not a drop-in replacement. See [model requirements](MODELS.md) before starting an Android build. This source snapshot is not presented as a complete corresponding-source offer for an existing APK.

The desktop Godot tests and native depth-stabilizer test can run without model weights or an Android toolchain.

## Architecture

```text
Godot scenes / GDScript / OpenXR
              │
Android Kotlin plugin: media libraries, permissions, playback sessions
              │ JNI
libmpv / FFmpeg → decoder Surface or shared textures → OpenXR layers / Godot
              └ MNN OpenCL: recurrent matting and monocular depth
```

| Directory | Purpose |
| --- | --- |
| `app/godot` | XR scenes, menus, shaders, localization and host tests |
| `android` | Kotlin Godot plugin, Gradle wrapper and JVM tests |
| `native` | JNI media bridge, rendering and inference backends |
| `cloud/openlist` | Embedded OpenList Go adapter and synthetic tests |
| `tools` | Build, conversion and verification entry points |
| `models` | Model contracts, checksums and licenses; no weights |
| `third_party` | Dependency sources, patches, provenance and notices |
| `benchmarks`, `tests` | Verification programs and synthetic fixtures |

## Getting started

```powershell
git clone https://github.com/zerochocobo/Thru3D-Media-Player.git Thru3D
cd Thru3D
python tools/Check-PublicSource.py

# Source-only tests: point this at your Godot executable.
$env:GODOT_EXE = (Get-Command godot).Source
./tools/Test-Source.ps1
```

For Android, prepare the pinned toolchain and externally supplied, version-matched models as described in [BUILD.md](BUILD.md):

```powershell
$env:THRU3D_TOOL_ROOT = Join-Path $HOME '.cache/thru3d-toolchain'
./tools/Import-ModelAssets.ps1 -FromDirectory ./external-model-assets
./tools/Build-Player.ps1 -ToolRoot $env:THRU3D_TOOL_ROOT -UsePreparedModelAssets -XrVendor Quest
# PICO uses a separate export preset and vendor loader.
./tools/Build-Player.ps1 -ToolRoot $env:THRU3D_TOOL_ROOT -UsePreparedModelAssets -XrVendor Pico
# Experimental: requires a compatible standard OpenXR runtime on the device.
./tools/Build-Player.ps1 -ToolRoot $env:THRU3D_TOOL_ROOT -UsePreparedModelAssets -XrVendor OpenXR
```

Rebuildable outputs use `build/output/`; temporary data uses `tmp/`. Formal release archives and private signing material use persistent directories, all excluded from public Git. A locally built application has your own signing identity. It cannot necessarily update an installed distribution signed by another key.

## Controls

Open the VR menu with the left Menu button. Point a controller ray at a control and press that controller's trigger. Libraries, settings, list popups and photo menus use thumbsticks only for scrolling. The ordinary video control bar allows seek, volume and immersive zoom shortcuts; pointer capture suppresses them, with a return-to-center gate after capture or lists close. Hand pointing/pinching is also supported. Desktop input is intended for development previews.

The right A button defaults to video play/pause or closing an expanded photo; left X opens the library. B/Y returns one layer at a time, closing a popup before going to the parent folder. With no media open, the outermost library stays visible; right trigger or B can reopen it if hidden. During playback, contextual library/popup Back retains priority; B/Y on the plain video transport or with controls hidden closes the video, saves its existing progress and returns to the full library. Photo Back keeps its existing behavior. Configured button combinations retain priority. Point outside a menu and press the trigger to dismiss it. Video settings open above the playback bar; photo settings retain their full-panel layout. Settings → Controls lets you select bindings, configure combinations and interface movement, and view animated gesture guides. Conflicts require a confirmed swap or cancellation; Back and ray selection remain available. Click the 3D/volume icons to adjust, or double-click to toggle/mute.

Both grip buttons move video pictures, interfaces or the photo magnifier. For videos, grip moves a flat screen or turns an immersive view; plain triggers operate controls and show/hide the playback bar. Grip plus the same controller's vertical thumbstick adjusts supported targets' distance; trigger plus stick remains available for flat photos. Standard menus remain upright; following mode uses head tilt. App/system recentering restores default menu placement, and placement offsets are session-only. The full playback library keeps the control bar available.

## Status and limitations

- Early source release; Android ARM64 builds use separate Quest, PICO and experimental standard OpenXR presets.
- Quest 3 has been used during development. PICO packaging checks do not establish PICO hardware playback, passthrough or hand-tracking validation.
- Matting quality, GPU support and sustained performance depend on the model, device and video. Host/packaging checks are not headset performance measurements.
- AI depth operates on flat mono content; video matting is limited to supported sources, including the dedicated spatial-video path; photo portrait matting applies to selected ordinary flat photos.
- Cloud/media-service adapters depend on third-party services and user authorization.

Read [architecture](ARCHITECTURE.md), [build](BUILD.md), [models](MODELS.md) and [testing](TESTING.md) for implementation details. Contributions are welcome; see [CONTRIBUTING.md](../CONTRIBUTING.md).

## License

Project-owned source is released under **GPL-3.0-only**. See [LICENSE](../LICENSE) for the complete GNU GPL v3 text and [licensing scope](LICENSING.md) for third-party code, models, assets and binary distribution requirements. Third-party components keep their existing licenses; this declaration does not relicense them or grant rights to excluded assets.

The embedded OpenList component is **AGPL-3.0**; its adapter, pinned build recipe and upstream/dependency notices are included. Combined binary distribution must satisfy its applicable AGPL obligations as explained in the licensing scope.

Pressing a controller trigger outside the video controls only dismisses them, so hand movement during that press cannot drag the picture. Timeline and slider dragging remain available. Video settings open on Playback, with color and stereo-view popup panels; photo settings retain their panel layout.

Video 2D-to-3D strength is remembered per file and defaults to Off for a new video; photos use an independent global preference. Manually enabled video portrait passthrough is not carried into the next opening. Matching external-subtitle filenames take priority, followed by the interface language; explicit/saved selections, including Off, override automatic choices.

## Seeking, combinations and Alpha settings

Thumbstick seeking previews a target before submitting it on a deliberate return to center. Default left/right steps are 20/10 seconds; holding accumulates. The current play/pause state is retained, and feedback waits for the matching presented frame before fading. Lists/settings and pointer captures cancel pending previews and retain shortcut isolation. Buffering uses the visible transport or a passive indicator without forcing controls open.

Grip and trigger modifiers may be pressed in either order on the same controller. Optional combinations provide half-turns only for 360-degree media and previous/next video navigation within the existing queue. Active UI captures and unavailable actions remain isolated; these combinations are not new default bindings.

Alpha has a global 256/320/384/512 model-size choice, with cached preparation and a default 30 FPS limit for unsaved preferences. A cold size may take about a minute to prepare; during playback the existing size stays active until preparation completes. Feather/shrink controls are available in playback and library settings. The updated Alpha presentation is included in the 0.10.0 Release scope; actual playback and inference rates depend on the headset, media and selected settings.

Opt-in file management provides source-dependent list selection, confirmed deletion and rename previews. Matching companions require exactly the same basename; folder renaming is not recursive. 115 Open support does not imply the legacy cookie provider can rename. Unknown write outcomes require status verification rather than automatic repeated writes.

Headsets/runtimes without support for the updated Alpha presentation automatically use eye-buffer Alpha.
