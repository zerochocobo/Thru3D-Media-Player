# Display cadence and playback menus

`native/mpv/patches/0006-mpv-layer-cadence.patch` uses fresh compositor display timing, period and latch lead for supported MediaCodec layer playback. Releases follow latch slots; stale timing falls back to normal targets. This does not invent source frames or guarantee every codec matches panel refresh. The refresh preference defaults to 72 Hz power saving; saved choices are preserved, and up to 90/120 Hz remain available subject to runtime/device and AI/depth policies.

The exact generator, patch and SHA-256 manifest accompany the pinned mpv recipe. Public normalization updates changed generator input digests and retains reference hashes; altered pins/mismatched source fail verification. Keep source and receipts together when rebuilding.

Experimental control depth applies to VR video, with default/medium/zero-parallax modes. Captured visuals and pointer mapping share the current layout; flat/photo menus retain normal behavior. Five fixed composition slots, hint regrouping and inline render-scale choices work within the existing budget. Host/OpenGL checks do not establish physical-headset or sustained-performance acceptance.

The 0.14.0 FFmpeg patch 0007 requests MediaCodec real-time priority and source frame rate, with a retry without both hints on rejected configuration. The pinned generator/manifest accompany the dependency build. This is not an unconditional high-bitrate or 8K performance claim.
