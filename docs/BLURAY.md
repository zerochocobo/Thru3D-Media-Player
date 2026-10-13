# Blu-ray ISO playback

0.8.0 adds direct playback of supported unencrypted Blu-ray main playlists through seekable ISO inputs. It does not implement disc menus or decryption. The selected source must support random/range reads; opening a large network ISO can involve substantial metadata and stream probing.

MVC support uses progressive 720p/1080p, 8-bit 4:2:0 video from a single clip with paired base/dependent views. Multi-clip MVC, still-image streams, incompatible stream layouts and ambiguous dependency indexes are rejected. Ordinary Blu-ray multi-clip titles require compatible video/audio stream layouts across clips. MVC is decoded stereo, not AI depth conversion.

The BSD-licensed edge264-mvc decoder uses four workers. FFmpeg adapters under native/mpv/mvc read UDF/SSIF through the source's seekable AVIO, pair views by timestamps, and use both CLPI indexes for seeking. Standard video retains its normal decoder. Supported normal MVC presentation uses the existing OpenXR compositor path; physical playback quality and sustained performance remain device-dependent.

Reproduction uses tools/environment/Prepare-MvcDecoder.py, tools/environment/Prepare-BluraySources.py and tools/environment/mpv-linux/build_source.sh. Exact upstream archives and hashes are in third_party/edge264-mvc/manifest.json and third_party/bluray/source-lock.json. The source-build receipt records MVC inputs; updated JNI must use a matching rebuilt FFmpeg candidate. No upstream binaries or movie ISOs are included.

tools/environment/mpv-linux/build_mvc_host.sh and tools/media/Test-BluRayIsoHost.py provide optional Linux host checks with user-supplied unencrypted media. They require actual video frames and audio samples, rather than treating a successful exit with empty output as playback verification. Host decode output is distinct from headset sound, visual synchronization, controller input and long-term performance.
