extends SceneTree
const Surface := preload("res://scripts/web_browser_surface.gd")
const BrowserWindow := preload("res://scripts/web_browser_window.gd")
var checks := 0
var failures: Array[String] = []

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok and failures.size() < 20: failures.append(message)

func _initialize() -> void:
	check(Surface.logical_for(Vector2(1.44, 0.90)) == Vector2i(1440, 900), "Default CSS viewport is exactly 1440x900")
	check(Surface.pixels_for(Vector2(1.44, 0.90), false) == Surface.PIXELS, "Default normal Surface matches Gecko runtime screen override")
	check(Surface.pixels_for(Vector2(1.44, 0.90), true) == Surface.LOW_END_PIXELS, "Default low-end Surface matches Gecko runtime screen override")
	check(Surface.logical_for(Vector2(2.0, 0.9)).x > 1440, "Widening still reflows the page")
	check(Surface.logical_for(Vector2(1.44, 1.8)).x < 1440, "Making the page tall still reflows it")
	check(Surface.logical_for(Vector2(2.88, 1.8)) == Vector2i(1440, 900), "Uniform physical enlargement keeps the same layout")
	check(Surface.logical_for(Vector2(0.01, 100)).x >= 1280, "Invalid old narrow geometry cannot select a mobile layout")
	var restored := BrowserWindow.clamp_page_size(Vector2(1.44, 1.8))
	check(Surface.logical_for(restored).x >= 1280 and is_equal_approx(restored.x, 1.44), "Old tall window is bounded without moving its horizontal edge")
	check(Surface.logical_for(Vector2(100, 0.01)).y >= 720, "Invalid old flat geometry cannot shrink below the minimum height")
	restored = BrowserWindow.clamp_page_size(Vector2(2.88, 0.45))
	check(Surface.logical_for(restored).y == 720 and is_equal_approx(restored.x, 2.88), "Old flat window regains enough height while keeping its width")
	check(restored.is_equal_approx(BrowserWindow.clamp_page_size(restored)), "Restoring bounded dimensions twice does not drift")
	check(Surface.logical_for(Vector2(2.5, 1.0)) == Vector2i(1800, 720), "Widest permitted layout retains 720 CSS pixels within the area budget")
	for w in range(144, 289, 3):
		for h in range(45, 181, 3):
			var size := BrowserWindow.clamp_page_size(Vector2(w, h) / 100.0)
			var logical := Surface.logical_for(size)
			var normal := Surface.pixels_for(size, false)
			var low := Surface.pixels_for(size, true)
			# Integer app units, as used by Gecko, avoid hiding density-rounding bugs.
			check(normal * 36 == logical * 60 and low * 45 == logical * 60, "Both tiers use identical CSS geometry at " + str(size))
			check(logical.x >= 1280, "All permitted shapes retain the minimum desktop width")
			check(logical.y >= 720, "All permitted shapes retain the minimum desktop height")
			check(normal.x * normal.y <= 2560 * 1600 and low.x * low.y <= 1920 * 1200, "Both pixel budgets remain bounded")
			check(maxi(normal.x, normal.y) <= 4096 and maxi(low.x, low.y) <= 2560, "Existing Surface edge limits remain bounded")
			check(mini(normal.x, normal.y) >= 256 and mini(low.x, low.y) >= 256, "Native attachment accepts extreme aspect ratios")
			check(absf(float(logical.x) / logical.y - size.x / size.y) < 0.035, "Quantization preserves resized aspect ratio")
	print("Browser viewport: %d checks, %d failures" % [checks, failures.size()])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)
