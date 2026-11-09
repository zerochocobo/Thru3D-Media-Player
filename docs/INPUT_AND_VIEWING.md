# Input and viewing controls

Quest simplified-Chinese input is opt-in and offline. Its compact pinyin keyboard uses the fixed rime-pinyin-simp dictionary retained in third_party/pinyin_simp, plus the explicit project vocabulary in app/godot/input/pinyin_overrides.json. No user typing, learned dictionary, account or history is distributed. Candidate data and little-endian offsets are reproducible with `python tools/Build-ChineseLexicon.py --check`; source AUTHORS, Apache-2.0 LICENSE and modification notices are retained. This is app input UI, not an Android system IME. Address bars use the system keyboard; compatible webpage fields and app naming/search/configuration inputs use the optional keyboard. PICO and OpenXR keep their existing input routes.

Video aspect settings adjust one eye's displayed ratio for supported flat/curved videos and save per video. Cinema curvature is stored separately from ordinary screen curvature and follows a matching bent border. Video and photo 3D position are separately global, not per-file overrides. Photo distance spans0.1–50m, size5–3000%, with separately remembered edge feathering including hard edges. These ranges are controls, not a guarantee of comfort or rendering quality at every extreme/device.

Controller seek steps are shared between hands and configurable; ray/trigger selection remains authoritative. Media-server playback-report intervals are independent of privacy permission, which still decides whether reporting is allowed. Returning to a supported server library refreshes resume state rather than assuming the old list snapshot is current.

听译／朗读关闭时可配置偏好，启动仍遵循资源、来源与互斥条件。音频提前处理和当前／后续字幕句数分别显示；配置与反馈改进不改变识别、翻译或朗读核心引擎。视频与照片的立体位置分别全局保存，影院曲面不覆盖普通曲面。

0.16.8 adds round-based video shuffle and grip-plus-stick radial photo/video distance adjustment relative to the headset, preserving explicit content rotation. Eligible flat DLNA casts can apply default 3D at format/first-frame readiness even if duration or seekability metadata is missing; native stereo, partial-source and manual-choice boundaries remain.

0.17.0 remembers playback speed globally and applies last/fixed format preferences to external video opens. Hovering the lower-left flat-video corner reveals bidirectional rotation; release snaps to 90 degrees, other corners still resize. Cinema corners resize within limits. Public Git retains beach integration without its separately supplied scenery assets.

## 0.17.2 photos and curvature

Photo autoplay uses3–30seconds(default5), starting when the final current image is presented rather than waiting for neighbour conversion. Continuous rotation/90-degree snapping and upright/ground layouts complement continuous video/photo curvature. Eligible ordinary videos with a panorama-image background offer horizontal, vertical and spherical curves; cinema configuration stays independent. Browser Back and playback-control dismissal remain separate.

## 0.17.3 application actions

Footer restart/quit use a second confirmation and show session usage; action icons remain visible at oblique viewing angles. Audio/subtitle restore work is skipped per frame when its inputs are unchanged, preserving mandatory recovery on source/track changes. Menu-layer viewports retire on XR session stop. These controls and source checks are not a new device performance guarantee.

## 0.17.4 editing lock and status

Persistent screen/edit_locked defaults off, links the flat-video corner and screen-menu controls, and applies to free/cinema/beach flat screens, independently of control-bar spatial locking or saved recenter settings. It blocks user geometry edits while allowing explicit rescue recenter, playback/seek/volume/subtitles/depth strength; photos, immersive projections, browser/PiP own operations are outside its scope. Feedback/haptics are rate-limited. Passive playback status can be hidden globally without suppressing actionable errors/confirmations. Browser floating/projected controls reuse the compact global footer.
