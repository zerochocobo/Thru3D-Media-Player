extends SceneTree
## Alpha mask edge settings: one value range shared by the eye-buffer shader and the compositor mask.
const AlphaEdge := preload("res://scripts/alpha_edge.gd")
var checks := 0
var failures: Array[String] = []

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func _initialize() -> void:
	check(AlphaEdge.bounds(100, 0).is_equal_approx(Vector2(0, 1)), "Full feather without shrink leaves the mask unchanged")
	var defaults := AlphaEdge.bounds(AlphaEdge.FEATHER_DEFAULT, AlphaEdge.SHRINK_DEFAULT)
	check(defaults.x > 0.1 and is_equal_approx(defaults.y, 1.0), "The default shrink trims the fringe and keeps the person opaque: %s" % [defaults])
	var hard := AlphaEdge.bounds(0, 0)
	check(hard.y - hard.x < 0.03 and is_equal_approx((hard.x + hard.y) / 2, 0.5), "No feather: a hard edge at half coverage")
	for feather in [0.0, 50.0, 100.0]:
		var shrunk := AlphaEdge.bounds(feather, 100)
		check(is_equal_approx(shrunk.y, 1.0) or shrunk.y < 1.0, "Never above 1")
		check(shrunk.y <= 1.0 and shrunk.x >= 0.39, "Shrinking moves the edge inward (feather %d): %s" % [feather, shrunk])
	check(is_equal_approx(AlphaEdge.bounds(100, 100).y, 1.0), "A fully covered person stays opaque at full shrink")
	check(AlphaEdge.bounds(-50, 400) == AlphaEdge.bounds(0, 100), "Out of range settings are clamped")
	var soft := AlphaEdge.bounds(100, 0); var mid := AlphaEdge.bounds(50, 0)
	check(mid.y - mid.x < soft.y - soft.x, "Less feather narrows the soft edge")
	print("Alpha edge: %d checks, %d failures" % [checks, failures.size()])
	for failure in failures: print("FAIL: " + failure)
	quit(1 if failures.size() else 0)
