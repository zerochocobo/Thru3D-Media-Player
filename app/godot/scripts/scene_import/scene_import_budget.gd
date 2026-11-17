extends RefCounted
## Per-device limits for user-imported scenes. Starting values from the import plan;
## recalibrate against headset frame timings before the feature is exposed.
const LOW := "low"    # Quest 2, PICO Neo3, PICO 4
const HIGH := "high"  # Quest 3, PICO 4 Ultra

## A scene's own lights are kept, strongest first, rescaled and unshadowed (see the loader).
## The renderer draws each mesh again for every lamp that reaches it, hence the small caps: on
## Quest 3 a 676k-triangle cafe held 72 fps with two lamps and fell to 69 with four (2026-11-17).
const TIERS := {
	LOW: {"triangles": 300000, "batches": 100, "texture_bytes": 128 * 1024 * 1024,
		"texture_size": 1024, "sky_width": 4096, "lights": 1, "file_bytes": 256 * 1024 * 1024},
	HIGH: {"triangles": 800000, "batches": 200, "texture_bytes": 384 * 1024 * 1024,
		"texture_size": 2048, "sky_width": 4096, "lights": 2, "file_bytes": 768 * 1024 * 1024},
}

static func limits(tier: String) -> Dictionary:
	return TIERS.get(tier, TIERS[LOW])

## Names of the limits a scene still exceeds, in a stable order.
static func exceeded(stats: Dictionary, tier: String) -> Array[String]:
	var limit := limits(tier)
	var over: Array[String] = []
	for key in ["triangles", "batches", "texture_bytes"]:
		if int(stats.get(key, 0)) > int(limit[key]): over.append(key)
	return over
