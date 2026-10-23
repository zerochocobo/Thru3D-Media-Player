# Grand cinema (Test)

From 0.13.2 the labelled test auditorium is available in **Debug and Release**, including scene loading, dual baked lighting and movement. Saved cinema backgrounds remain selected. This replaces the older Debug-only policy; ordinary cinema screen presets remain available independently. Right A holds the movement target and releasing teleports; trigger operates menus. Right-hand-only use, floor/stair landing checks and restored menu placement follow the current production implementation.

## Prepare complete scene resources

Generated GLBs, baked textures, authoring .blend files and raw/derived scan images are excluded from public Git. Source blueprints, material shaders, authoring scripts and source/hash metadata are included. Normal Debug/Release packaging requires the complete locally prepared scene and `Assert-CinemaPackaged.ps1` fails if navigation, scene, both light states, nine mobile textures or runtime shaders/scripts are missing. The public build does not silently disable the feature to bypass that check.

Obtain the CC0 ambientCG sets named by `tools/cinema/textures/textures.json` and `tools/cinema/sample/textures/sources.json`. The latter also pins raw Color/Displacement/Roughness inputs. Place each original JPG set under `tmp/textures/raw/<asset-id>/`; original downloads remain external. With NumPy/Pillow and Blender 5.2:

```powershell
python tools/cinema/prepare_textures.py tmp/textures/raw
python tools/cinema/prepare_sample_textures.py
./tools/Build-CinemaLighting.ps1 -Godot godot -Blender blender
```

The first script defaults are not needed when an explicit raw directory is passed. The second uses repository-root tmp/textures/raw. The bake generates a persistent local authoring snapshot and hash record under `tools/cinema/full_hall/` and disposable bake output under `build/output/cinema-full-lighting/`; import copies validated scene/lighting data to the ignored runtime directory. Build-CinemaModel delegates to this dual-state pipeline. Generate-CinemaModel alone writes only navigation. Recreate these resources before full build-gate/geometry tests. The source snapshot supplies no prebuilt scene and does not claim every minimum headset's performance.

## Optional Windows desktop video

`tools/Prepare-CinemaDesktopVideo.ps1` verifies the pinned publisher archive in `third_party/desktop-video/manifest.json` and invokes `tools/Build-CinemaDesktopVideo.ps1` for the local repaired extension. Sources, patch and dependency archives are pinned by the adjacent build locks; outputs stay in build/, downloads in tmp/. Use `-Offline` for an existing verified cache. This needs the declared Windows C++ toolchain and does not install system software or modify Android exports. No DLLs or dependency archives are shipped in this source snapshot.

The extension carries the recorded MIT notices; the pinned FFmpeg dependency carries its own LGPL v3 text and recorded build configuration. The project license does not replace these notices. Source recipes and local preparation do not establish completion of binary redistribution obligations. See [licensing](LICENSING.md).

`tools/Test-CinemaBuildGate.ps1` checks real Debug and Release Windows engines, including stale settings and direct loading/actions. Geometry, loader and locomotion scripts use generated local assets. Desktop source checks do not prove headset performance or interaction acceptance.
