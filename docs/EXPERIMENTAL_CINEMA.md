# Experimental auditorium (Debug only)

The auditorium scene, seat selection, movement and desktop prototype are experiments controlled by `OS.is_debug_build()`. Release hides their entries, refuses scene loading/actions and normalizes a saved Debug cinema background to the ordinary background. Existing cinema-style screen positioning remains available in Release. Online panorama entries also remain hidden in the current UI.

## Generate local geometry

Generated scene models and baked textures are excluded from public Git. The project-owned blueprint defines navigation geometry and seats; Blender builds and bakes the visible hall from its manifest, without external scene assets or personal media. Use the matching Godot executable and Blender 5.2:

```powershell
./tools/Build-CinemaModel.ps1 -Godot godot -Blender blender
godot --headless --editor --import --xr-mode off --path app/godot
```

This writes the ignored manifest, GLB and baked images under `app/godot/environments/grand_cinema/`. The Blender scripts are in `tools/cinema`; Generate-CinemaModel alone produces only the manifest. Generate them before enabling the Debug scene or running its geometry/loading/gate tests. Regeneration is optional for normal Release source builds. It does not enable the scene in Release.

## Optional Windows desktop video

`tools/Prepare-CinemaDesktopVideo.ps1` verifies the pinned publisher archive in `third_party/desktop-video/manifest.json` and invokes `tools/Build-CinemaDesktopVideo.ps1` for the local repaired extension. Sources, patch and dependency archives are pinned by the adjacent build locks; outputs stay in build/, downloads in tmp/. Use `-Offline` for an existing verified cache. This needs the declared Windows C++ toolchain and does not install system software or modify Android exports. No DLLs or dependency archives are shipped in this source snapshot.

The extension carries the recorded MIT notices; the pinned FFmpeg dependency carries its own LGPL v3 text and recorded build configuration. The project license does not replace these notices. Source recipes and local preparation do not establish completion of binary redistribution obligations. See [licensing](LICENSING.md).

`tools/Test-CinemaBuildGate.ps1` checks real Debug and Release Windows engines, including stale settings and direct loading/actions. Geometry, loader and locomotion scripts use generated local assets. Desktop source checks do not prove headset performance or interaction acceptance.
