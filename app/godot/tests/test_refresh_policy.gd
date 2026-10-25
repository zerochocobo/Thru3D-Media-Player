extends SceneTree
## Video refresh-rate choice: even repeats first, then the fastest panel, within the playback cap.
const Display := preload("res://scripts/xr_display.gd")
const Quality := preload("res://scripts/display_quality.gd")
const QUEST3 := [72.0, 80.0, 90.0, 120.0]
const PICO := [72.0, 90.0]
var failures: Array[String] = []
var checks := 0
func _initialize() -> void:
	expect(24.0, QUEST3, 120, 72.0, "24 fps shows each frame 3 refreshes")
	expect(23.976, QUEST3, 120, 72.0, "23.976 fps stays on 72 Hz")
	expect(30.0, QUEST3, 120, 90.0, "30 fps uses 90 Hz")
	expect(29.97, QUEST3, 120, 90.0, "29.97 fps uses 90 Hz")
	expect(60.0, QUEST3, 120, 120.0, "60 fps uses 120 Hz")
	expect(59.94, QUEST3, 120, 120.0, "59.94 fps uses 120 Hz")
	expect(50.0, QUEST3, 120, 120.0, "Uneven 50 fps takes the fastest panel")
	expect(60.0, QUEST3, 90, 0.0, "A 90 Hz cap keeps the default rate for 60 fps")
	expect(30.0, QUEST3, 90, 90.0, "A 90 Hz cap still matches 30 fps")
	expect(50.0, QUEST3, 90, 0.0, "A 90 Hz cap keeps uneven rates at the default")
	expect(30.0, QUEST3, 72, 0.0, "Power saving keeps 30 fps at the default")
	expect(24.0, QUEST3, 72, 72.0, "Power saving still shows 24 fps evenly")
	expect(60.0, QUEST3, 72, 0.0, "Power saving keeps 60 fps at the default")
	expect(30.0, PICO, 120, 90.0, "PICO 30 fps uses 90 Hz")
	expect(60.0, PICO, 120, 90.0, "Without 120 Hz uneven rates take the fastest panel")
	expect(0.0, QUEST3, 120, 0.0, "Unknown frame rate keeps the default")
	expect(INF, QUEST3, 120, 0.0, "Invalid frame rate keeps the default")
	expect(240.0, QUEST3, 120, 0.0, "Above-panel frame rate keeps the default")
	expect(30.0, [], 120, 0.0, "No reported rates keep the default")
	checks += 1
	if not is_equal_approx(Display.menu_refresh_rate(QUEST3), 72.0): failures.append("Menus use 72 Hz on Quest 3")
	checks += 1
	if not is_equal_approx(Display.menu_refresh_rate([60.0, 90.0]), 90.0): failures.append("Menus skip rates below 72 Hz")
	checks += 1
	if Display.menu_refresh_rate([]) != 0.0: failures.append("No reported rates leave the rate alone")
	# The setting: 120 Hz by default; low-end GPUs never offer or keep 120 Hz.
	var settings := ConfigFile.new()
	setting(Quality.load_refresh_cap(settings, false) == 120, "Default cap is 120 Hz")
	setting(Quality.load_refresh_cap(settings, true) == 90, "Low-end GPUs default to 90 Hz")
	settings.set_value("video", "refresh_cap", 120)
	setting(Quality.load_refresh_cap(settings, false) == 120, "120 Hz is kept on capable GPUs")
	setting(Quality.load_refresh_cap(settings, true) == 90, "Low-end GPUs stop at 90 Hz")
	settings.set_value("video", "refresh_cap", 75)
	setting(Quality.load_refresh_cap(settings, false) == 120, "Unknown values fall back to the default")
	setting(Quality.refresh_choices(false) == [120, 90, 72] and Quality.refresh_choices(true) == [90, 72], "Low-end devices do not list 120 Hz")
	setting(Quality.REFRESH_NAMES.keys().all(func(cap): return Quality.REFRESH_HINTS.has(cap)), "Every choice explains its refresh rates")
	# Cinema relief: high foveation and at most 1.0x eye buffers, restored when it ends.
	var display = Display.new()
	display.foveation_level = 1; display.render_scale = 1.1
	display.set_scene_relief(true)
	setting(display.scene_relief and display.foveation_level == 1 and display.render_scale == 1.1, "Relief keeps the user's own foveation and scale")
	setting(Display.SCENE_RELIEF_FOVEATION == 3 and Display.SCENE_RELIEF_MAX_SCALE == 1.0, "Relief uses high foveation and 1.0x eye buffers")
	display.set_scene_relief(false)
	setting(not display.scene_relief, "Relief ends")
	if display is Node: display.free()
	print("Refresh policy: %d checks, %d failures" % [checks, failures.size()])
	for failure in failures: print("FAIL: " + failure)
	quit(1 if failures.size() else 0)
func expect(fps: float, rates: Array, cap: float, wanted: float, message: String) -> void:
	checks += 1
	var rate := Display.video_refresh_rate(fps, rates, cap)
	if not is_equal_approx(rate, wanted): failures.append("%s (got %s)" % [message, rate])
func setting(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)
