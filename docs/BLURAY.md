# Blu-ray ISO playback

0.8.0 adds direct playback of supported unencrypted Blu-ray main playlists through seekable ISO inputs. Decryption remains unsupported. From 0.13.2 the player adds title selection and supported non-3D HDMV menus; BD-J/Java menus are identified but not executed. The selected source must support random/range reads; opening a large network ISO can involve substantial metadata and stream probing.

MVC support uses progressive 720p/1080p, 8-bit 4:2:0 video with paired base/dependent views. Single and multi-clip MVC playlists require compatible stream layouts and frame rates; each clip must have an unambiguous SSIF/dependent-stream association. Still-image streams, missing views and incompatible layouts are rejected. Ordinary Blu-ray multi-clip titles also require compatible video/audio stream layouts across clips. MVC is decoded stereo, not AI depth conversion.

The BSD-licensed edge264-mvc decoder uses four workers. FFmpeg adapters under native/mpv/mvc read UDF/SSIF through the source's seekable AVIO, pair views by timestamps, and use both CLPI indexes for seeking. Standard video retains its normal decoder. Supported normal MVC presentation uses the existing OpenXR compositor path; physical playback quality and sustained performance remain device-dependent.

Reproduction uses tools/environment/Prepare-MvcDecoder.py, tools/environment/Prepare-BluraySources.py and tools/environment/mpv-linux/build_source.sh. Exact upstream archives and hashes are in third_party/edge264-mvc/manifest.json and third_party/bluray/source-lock.json. The source-build receipt records MVC inputs; updated JNI must use a matching rebuilt FFmpeg candidate. No upstream binaries or movie ISOs are included.

tools/environment/mpv-linux/build_mvc_host.sh and tools/media/Test-BluRayIsoHost.py provide optional Linux host checks with user-supplied unencrypted media. They require actual video frames and audio samples, rather than treating a successful exit with empty output as playback verification. Host decode output is distinct from headset sound, visual synchronization, controller input and long-term performance.

tools/media/Test-MultiClipMvcHost.py and benchmarks/native_mvc/iso_multiclip_probe.c verify continuous clip joins, cross-clip and repeated seeks, complete stereo output, independent H.264 base-eye pixels and audio timestamps. Pass --clip-boundaries in title seconds and --full to include an entire-title decode. With --full-workers 4, overlapping continuous whole-clip runs cover every join and the final EOF in parallel; this is distinct from a long-running single-instance soak test. The host build script accepts --x86-asm when NASM is available. Movie frames are compared in memory, not written to disk.

## Disc menu scope

The longest supported playlist remains the default. The title list exposes other cuts/extras without overwriting main-feature resume data. Supported HDMV menu sessions use eye-buffer disc presentation with controller rays and a dedicated sharp toolbar, dwell selection for submenus, menu return and language carry-over. MVC/3D discs and BD-J are outside this menu implementation. Menu detection is not a promise that every disc script is compatible. Current FFmpeg adapters require a matching rebuilt source receipt; no movie ISO or menu imagery is distributed.

## DVD ISO playback (0.15.2)

Supported unencrypted DVD ISOs use the seekable source adapter, title/chapter selection and libdvdnav controller-ray menu navigation. Return-to-menu is available during disc playback. Inputs must support random reads; network behavior and individual disc scripts can limit compatibility. No libdvdcss dependency, decryption or universal menu guarantee is provided.

`third_party/dvd/source-lock.json` pins libdvdread 7.0.1 and libdvdnav 7.0.0, both GPL-2.0-or-later. `tools/environment/Prepare-DvdSources.py`, `tools/environment/mpv-linux/build_dvd.sh` and the FFmpeg adapter build the corresponding native component. `tools/media/Test-DvdIsoHost.py` is an optional external-media check, not bundled film data. Source receipt and native libraries must be rebuilt together. No ISO, menu imagery or third-party binary is included.
