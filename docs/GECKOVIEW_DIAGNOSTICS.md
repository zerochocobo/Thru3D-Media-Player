# Optional GeckoView frame diagnostics

Normal 0.18.8 builds use the official GeckoView 159.0.20261022150525 artifact pinned in third_party/geckoview/runtime.json. The optional diagnostic build uses the same Mozilla revision, 5add844c26613d7e4d84c799d6e23cf987b1240d, with [the frame probe patch](../native/geckoview/geckoview-159-frame-probe.patch). Preserve the upstream MPL-2.0 and notices in third_party/geckoview.

Apply the patch to that exact upstream source and build an ARM64 GeckoView AAR using Mozilla's build instructions. Build-Player -DouyinPlaybackLog -GeckoProbeAar <AAR> uses [the staging helper](../tools/geckoview/stage_engine.py), checks probe markers and requires the packaged libxul to match. Ordinary builds do not enable this probe.

The app binds diagnostic samples to current navigation, video and media epoch, rejects protected media and bounds sampling. Reports may contain user media information and stay outside this source repository. No recordings, reporter identities, account data or device logs are included. Probe results do not establish the cause of a device color issue or complete device validation.
