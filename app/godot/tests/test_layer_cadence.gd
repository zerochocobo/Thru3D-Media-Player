extends SceneTree
## Layer cadence (MPV patch 0006) runs only on the compositor it was calibrated on.
const Layer := preload("res://scripts/video_layer.gd")
var failures: Array[String] = []
var checks := 0
func _initialize() -> void:
	expect(Layer.cadence_runtime("Oculus", false), "Meta runtime (Oculus name) uses the cadence")
	expect(Layer.cadence_runtime(" Meta Horizon ", false), "Meta runtime name variants use the cadence")
	expect(not Layer.cadence_runtime("PICO OpenXR Runtime", true), "PICO keeps the original releases")
	expect(not Layer.cadence_runtime("Oculus", true), "A PICO build never enables it")
	expect(not Layer.cadence_runtime("", false), "Unknown runtimes keep the original releases")
	expect(Layer.META_LATCH_LEAD_NS == 16_000_000, "The Quest 3 latch lead stays calibrated")
	print("Layer cadence: %d checks, %d failures" % [checks, failures.size()])
	for failure in failures: print("FAIL: " + failure)
	quit(1 if failures.size() else 0)
func expect(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)
