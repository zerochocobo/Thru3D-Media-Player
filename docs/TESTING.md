# Testing

## Source-only checks

```powershell
python tools/Check-PublicSource.py
$env:GODOT_EXE = (Get-Command godot).Source
./tools/Test-Source.ps1
```

The public checker examines tracked files for excluded binary types, credentials and private paths. It is a publication boundary check, not a substitute for a full security review.

`Test-Source.ps1` runs the Godot GDScript host suite without activating the Android toolchain. It includes localization, media-library/menu interaction, controller/hand logic, projection/eye-order, preferences and image/depth handling. An OpenXR loader can be absent during headless tests; XR/device behavior is not part of their result.

The thumbnail capture test requires a desktop OpenGL renderer. The Windows runner starts that test with a hidden rendering window and requires its completion summary; a headless dummy-renderer timeout is not counted as a pass. The other host scripts run headlessly.

The native depth stabilizer can also be tested with a C++17 compiler:

```bash
mkdir -p build/tests
g++ -std=c++17 -Wall -Wextra -Werror -I native/rvm tests/native/depth_stabilizer_test.cpp native/rvm/depth_stabilizer.cpp -o build/tests/depth_stabilizer_test
./build/tests/depth_stabilizer_test
```

## Android tests

With the full toolchain configured, `Build-Player.ps1` runs JVM tests as part of plugin assembly. `Test-Player.ps1` provides the broader historical host/render checks. Additional `Test-*Device.ps1` tools require an authorized headset and their specified media/model fixtures.

Only project-generated synthetic media are distributed. Moving-person tests and student training require user-supplied, licensed media; original personal media, numerical captures and device identifiers are excluded. Generate your own fixtures before attempting those optional probes.

## What constitutes device verification

Record the APK hash, device/vendor, model hash, input media contract and test scope. Distinguish decoding, inference, presented unique video frames, engine ticks and final XR display. Test seeking, pause/resume, menu interactions, permission revocation, background/foreground transitions, stereo alignment and sustained operation separately.

Host tests and ELF/APK inspection do not prove passthrough visuals, audio synchronization, physical hand/controller interaction or sustained frame rate. PICO export success is not PICO hardware validation.

## Optional audio fixtures

The built-in recordings are excluded from public source. `test_background_audio.gd` and `test_audio_native_transport.gd` include built-in decoding paths and require the twelve caller-supplied assets described in [AUDIO.md](AUDIO.md). Without them, do not report the complete source suite as passed. Music UI rendering can use generated fixtures. `tests/packaging/test_narration_packaged.ps1` uses synthetic AAR/APK ZIP entries to verify required libraries, manifest, payload size and digest, including corrupt/missing cases. It does not run inference. The older exclusion regression describes a historical disabled configuration. The five small puzzle WAV effects are independently reproducible with `tools/Generate-PuzzleSounds.py` and are included, unlike the twelve excluded music/ambient recordings.

## 0.12.2 focused checks

Privacy/history and per-file settings have independent tests (`test_privacy_memory`, `test_smb_stereo_memory`). Narration/clone UI tests use fake backends; JVM policy, preview-session, voice-store, level and rhythm tests can run with synthetic audio. Real reference/model inference requires separately supplied assets. File-probe tests that require explicit fixture environment variables must remain skipped without caller-owned inputs.

Generate the optional auditorium geometry before its source/gate tests; see [experimental cinema](EXPERIMENTAL_CINEMA.md). Photo gradient parity requires compiling `tests/native/photo_gradient_probe.cpp` and setting `THRU3D_PHOTO_GRADIENT_PROBE`. Other photo suites use synthetic image/depth fixtures. Excluded built-in recordings remain required for complete music decoding tests; do not claim the entire suite passed without them.

## 0.12.3 capture and remote-reader checks

Capture state/format and UI tests use synthetic/fake inputs; the Linux/WSL packet-copy integration compares source/output compressed packets and supports file-descriptor output. Voice reference/subtitle host tests generate indexed MP4/MKV plus delayed-caption fixtures and loopback HTTP ranges. `tools/Test-VoiceCloneHost.sh` prepares its host libraries; `tools/media/test_voice_clone_sources.py` uses the companion MP4 inspector. None needs credentials or a headset. Debug cloud denial diagnostics must retain only bounded/redacted reasons, never full URLs or tickets.
