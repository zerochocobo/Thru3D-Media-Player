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
	# The setting: 72 Hz by default; low-end GPUs never offer or keep 120 Hz.
	var settings := ConfigFile.new()
	setting(Quality.load_refresh_cap(settings, false) == 72, "Default cap is 72 Hz")
	setting(Quality.load_refresh_cap(settings, true) == 72, "Low-end GPUs also default to 72 Hz")
	settings.set_value("video", "refresh_cap", 120)
	setting(Quality.load_refresh_cap(settings, false) == 120, "120 Hz is kept on capable GPUs")
	setting(Quality.load_refresh_cap(settings, true) == 90, "Low-end GPUs stop at 90 Hz")
	settings.set_value("video", "refresh_cap", 75)
	setting(Quality.load_refresh_cap(settings, false) == 72, "Unknown values fall back to the default")
	setting(Quality.refresh_choices(false) == [120, 90, 72] and Quality.refresh_choices(true) == [90, 72], "Low-end devices do not list 120 Hz")
	setting(Quality.REFRESH_NAMES.keys().all(func(cap): return Quality.REFRESH_HINTS.has(cap)), "Every choice explains its refresh rates")
	# Cinema relief: high foveation only, restored when it ends. The eye buffers keep their size:
	# a live resize leaks GLES3 targets on Quest.
	var display = Display.new()
	display.foveation_level = 1; display.render_scale = 1.1
	display.set_scene_relief(true)
	setting(display.scene_relief and display.foveation_level == 1 and display.render_scale == 1.1, "Relief keeps the user's own foveation and scale")
	setting(Display.SCENE_RELIEF_FOVEATION == 3, "Relief uses high foveation")
	setting(not display.has_method("request_layer_relief") and not ("relief_max_scale" in display), "Nothing resizes the eye buffers at runtime")
	display.set_scene_relief(false)
	setting(not display.scene_relief, "Relief ends")
	# CPU/GPU levels: a seek's brief non-playing state must not drop sustained-high.
	display.request_performance_demand(true, 1000)
	setting(display.performance_demand, "Playback raises the levels at once")
	display.request_performance_demand(false, 2000)
	display.request_performance_demand(false, 2300)
	setting(display.performance_demand, "A seek reopen keeps the levels high")
	display.request_performance_demand(true, 2400)
	display.request_performance_demand(false, 4000)
	display.request_performance_demand(false, 4000 + Display.PERFORMANCE_SETTLE_MS - 1)
	setting(display.performance_demand, "Playing again restarts the settle time")
	display.request_performance_demand(false, 4000 + Display.PERFORMANCE_SETTLE_MS)
	setting(not display.performance_demand, "A lasting stop drops to sustained-low")
	display.request_performance_demand(false, 9000)
	setting(not display.performance_demand, "Low demand stays low")
	# 120 Hz the headset cannot fill: 5 slow seconds in a row put the file on the slower rates.
	setting(Display.refresh_slow(72.0, 120.0) and Display.refresh_slow(95.0, 120.0), "Below 80% of 120 Hz is slow")
	setting(not Display.refresh_slow(108.0, 120.0), "Small misses keep 120 Hz")
	setting(not Display.refresh_slow(40.0, 90.0) and not Display.refresh_slow(40.0, 72.0), "90 Hz and below are never demoted")
	var bar = load("res://scripts/mpv_video_display.gd").new()
	bar.local_uri = "file:///b.mp4"; bar.requested_play = true; bar.media.state = "playing"
	for second in 5: bar.check_refresh_load(120.0, true, 1000 * (second + 1), 90.0)
	for second in 2: bar.check_refresh_load(120.0, false, 6000 + 1000 * second, 90.0)
	setting(not bar.refresh_overloaded, "A control bar that hides after its idle time does not demote the file, nor the second the counter lags")
	bar.check_refresh_load(120.0, false, 8000, 110.0)
	for second in 9: bar.check_refresh_load(120.0, true, 9000 + 1000 * second, 90.0)
	setting(not bar.refresh_overloaded, "Nine slow seconds in a menu are not enough")
	bar.check_refresh_load(120.0, true, 18000, 90.0)
	setting(bar.refresh_overloaded, "Ten slow seconds in a menu demote the file too")
	bar.free()
	var video = load("res://scripts/mpv_video_display.gd").new()
	video.local_uri = "file:///a.mp4"; video.requested_play = true; video.media.state = "playing"
	for second in 4: video.check_refresh_load(120.0, false, 1000 * (second + 1), 60.0)
	setting(not video.refresh_overloaded, "Four slow seconds are not enough")
	video.check_refresh_load(120.0, false, 5000, 119.0)
	for second in 4: video.check_refresh_load(120.0, false, 6000 + 1000 * second, 60.0)
	setting(not video.refresh_overloaded, "A good second restarts the count")
	video.check_refresh_load(120.0, false, 10000, 60.0)
	video.check_refresh_load(120.0, false, 10500, 60.0)
	setting(video.refresh_overloaded, "Five slow seconds in a row demote the file")
	video.check_refresh_load(72.0, false, 12000, 72.0)
	setting(video.refresh_overloaded, "The decision stays for the file")
	video.picture_quality = not video.picture_quality
	video.check_refresh_load(72.0, false, 13000, 72.0)
	setting(not video.refresh_overloaded, "Changing picture quality mode tries the fast panel again")
	video.media.state = "paused"
	for second in 8: video.check_refresh_load(120.0, false, 14000 + 1000 * second, 20.0)
	setting(not video.refresh_overloaded, "A paused file is not judged")
	video.free()
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
