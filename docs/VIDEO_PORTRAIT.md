# Stereo video portrait passthrough

Eligible ordinary flat 2D video can reuse its decoded frame/mask as a stereo person surface in passthrough. Depth strength, independent size/distance and remembered placement are provided; moving from cinema retains viewing position. Automatic distance is off initially. Optional enhanced depth adds inference/geometry work and may reduce frame rate or increase heat. Subject/crop/shot/mask ambiguity can fall back; multiple people, fast motion and occlusion are not guaranteed. This does not reconstruct an unrestricted 3D scene.

Frame identity, calibrated source rays, mask/depth coordination, bounded work and paused redraws use the existing production pipeline. Compatibility fallback and lighter low-end defaults target Quest 2/PICO Neo3 class hardware but do not establish all-headset visual or sustained-performance acceptance. Generated models, original human videos, training data, private masks/recordings and device evidence remain excluded; separately prepared runtime models are still required.

VR grip/thumbstick adjustment uses existing controller interactions, with per-file viewing memory, recenter, live numeric/scale guidance and horizontal stereo alignment up to ±10%. These controls alter the view, not physical headset IPD. See [runtime settings](RUNTIME_SETTINGS.md) for AI memory limits and [model requirements](MODELS.md) for payload preparation.

普通平面视频的人像立体透视受遮罩、片源与设备限制；自动距离默认关闭，精细层次可降帧。原始人物素材、模型权重和设备日志不公开。
