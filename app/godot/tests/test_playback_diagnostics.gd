extends SceneTree
## Playback diagnostic windows separate undisturbed playback from menus and seeks, and stay bounded.
const Windows := preload("res://scripts/playback_diagnostics.gd")
var failures: Array[String] = []
var checks := 0

func sample(frames: int, changes: Dictionary = {}) -> Dictionary:
	var result := {"frames": frames, "xr_frames": frames * 2, "decoder_drops": 0, "vo_drops": 0, "vo_late": 0, "avsync": "0.001", "cache": false, "container_fps": "59.94", "seek_serial": 0,
		"path": "L", "menu": "", "menu_layers": false, "menu_layer_repaints": 0,
		"refresh": 120.0, "cap": 120, "performance": "sustained_high", "foveation": 0, "relief": false, "render_scale": 1.1, "inference": false}
	result.merge(changes, true)
	return result

func _initialize() -> void:
	# Undisturbed playback closes every ten seconds with the rates and drop increments.
	var windows := Windows.new()
	expect(windows.tick(0, sample(0, {"vo_drops": 5})).is_empty(), "The first sample opens a window")
	expect(windows.tick(9000, sample(540, {"vo_drops": 5})).is_empty(), "A window stays open before ten seconds")
	var clean: Dictionary = windows.tick(10000, sample(600, {"vo_drops": 8, "decoder_drops": 1}))
	expect(clean.get("window_ms") == 10000 and clean.get("video_fps") == 60.0 and clean.get("xr_fps") == 120.0, "A clean window reports its rates")
	expect(clean.get("vo_drops") == 3 and clean.get("decoder_drops") == 1, "Drops are increments within the window")
	expect(clean.get("menu") == "" and clean.get("seeks") == 0 and clean.get("mixed") == false and clean.get("since_seek_ms") == -1, "A clean window is recognisable")
	expect(clean.get("refresh") == 120.0 and clean.get("performance") == "sustained_high" and clean.get("path") == "L", "The display state is reported")
	# Opening the menu closes the clean window, and the next one carries the menu.
	var opened: Dictionary = windows.tick(13000, sample(780, {"menu": "player", "vo_drops": 8}))
	expect(opened.get("menu") == "" and opened.get("window_ms") == 3000, "Opening a menu closes the window before it")
	var with_menu: Dictionary = windows.tick(23000, sample(1380, {"menu": "player", "vo_drops": 8}))
	expect(with_menu.get("menu") == "player" and with_menu.get("mixed") == false, "Time under the menu has its own window")
	# A change in composition can happen while the same menu stays on screen.
	windows = Windows.new()
	windows.tick(0, sample(0, {"menu": "player", "menu_layer_repaints": 9}))
	var before_layers: Dictionary = windows.tick(3000, sample(180, {"menu": "player", "menu_layers": true, "menu_layer_repaints": 9}))
	expect(before_layers.get("menu_layers") == false and before_layers.get("window_ms") == 3000, "A change in menu composition starts a new window")
	var with_layers: Dictionary = windows.tick(13000, sample(780, {"menu": "player", "menu_layers": true, "menu_layer_repaints": 12}))
	expect(with_layers.get("menu_layers") == true and with_layers.get("menu_layer_repaints") == 3, "The window reports active menu layers and the repaint increment")
	# A seek closes the window; the one after it counts the seek and has no frame rate.
	windows = Windows.new()
	windows.tick(0, sample(0))
	var before_seek: Dictionary = windows.tick(4000, sample(240, {"seek_serial": 1}))
	expect(before_seek.get("seeks") == 0 and before_seek.get("window_ms") == 4000, "A seek closes the window before it")
	var after_seek: Dictionary = windows.tick(7000, sample(9000, {"seek_serial": 1}))
	expect(after_seek.is_empty(), "The window after a seek stays open")
	after_seek = windows.tick(14000, sample(9400, {"seek_serial": 1}))
	expect(after_seek.get("seeks") == 1 and after_seek.get("video_fps") == -1.0 and after_seek.get("since_seek_ms") == 0, "The window after a seek is marked")
	var settled: Dictionary = windows.tick(24000, sample(10000, {"seek_serial": 1}))
	expect(settled.get("seeks") == 0 and settled.get("since_seek_ms") == 10000 and settled.get("video_fps") == 60.0, "Later windows report how long ago the seek was")
	# A held seek inside one short window joins it instead of writing an event per step.
	windows = Windows.new()
	windows.tick(0, sample(0))
	var events := 0
	for step in 3: events += int(not windows.tick(500 + step * 500, sample(0, {"seek_serial": step + 1})).is_empty())
	expect(events == 0, "Short windows absorb repeated seeks")
	var held: Dictionary = windows.tick(10000, sample(600, {"seek_serial": 3}))
	expect(held.get("seeks") == 3 and held.get("mixed") == true, "The absorbed seeks are counted and marked")
	# Stopping closes a long enough window and discards a very short one; counter restarts are not negative.
	windows = Windows.new()
	windows.tick(0, sample(100, {"vo_drops": 9}))
	windows.tick(1000, sample(150, {"vo_drops": 9}))
	expect(windows.tick(1500, {}).is_empty(), "A very short window is dropped when playback stops")
	windows.tick(2000, sample(0, {"vo_drops": 9}))
	var stopped: Dictionary = windows.tick(5000, sample(0, {"vo_drops": 2}))
	expect(stopped.is_empty(), "A window keeps running without a change")
	stopped = windows.tick(6000, {})
	expect(stopped.get("window_ms") == 4000 and stopped.get("vo_drops") == 0, "Stopping closes the window; a restarted counter is not negative")
	expect(windows.tick(7000, {}).is_empty(), "Idle samples write nothing")
	# Picture quality mode: a settings change starts a window, which carries the copy's rate, size and cost.
	windows = Windows.new()
	var copy := {"picture": "on up2 dn0 sh0.50", "copy_drawn": 100, "copy_failed": 1, "copy_out": "3840x2160",
		"copy_gpu_ms": 30.5, "copy_draw_ms": 34.0, "copy_window": 30.0, "copy_deep": true}
	windows.tick(0, sample(0, {"picture": "off"}))
	var before_picture: Dictionary = windows.tick(3000, sample(180, copy))
	expect(before_picture.get("picture") == "off" and before_picture.get("window_ms") == 3000, "A picture settings change starts a new window")
	var copying: Dictionary = windows.tick(13000, sample(780, copy.merged({"copy_drawn": 350, "copy_failed": 3}, true)))
	expect(copying.get("picture") == "on up2 dn0 sh0.50" and copying.get("copy_fps") == 25.0 and copying.get("copy_failed") == 2,
		"The window reports the copy's draws a second and failures")
	expect(copying.get("copy_out") == "3840x2160" and copying.get("copy_gpu_ms") == 30.5 and copying.get("copy_window") == 30.0,
		"The window carries the copy's output size, GPU time and window")
	expect(not clean.has("copy_fps"), "Playback without a copy reports none")
	# The release eye-buffer status can arrive before the first pair or after a seek.
	var pair := {"session_id": 1, "source_epoch": 2, "color_target": "external", "width": 8192,
		"height": 4096, "source_width": 8192, "source_height": 4096}
	var status := {"session_id": 1, "last_source_epoch": 2, "layer": false, "published": 10,
		"unique_post_draw_frames": 2, "decoder_recycle_waits": 1, "private_key": "private_value"}
	var eye := Windows.eye_sample(status, pair)
	expect(Windows.eye_sample(status, {}).is_empty() and Windows.eye_sample(status.merged({"layer": true}, true), pair).is_empty(), "Only a bound eye-buffer source is sampled")
	expect(Windows.eye_sample(status.merged({"last_source_epoch": 3}, true), pair).is_empty(), "The decoder epoch must match the bound frame")
	expect(Windows.eye_sample(status, pair.merged({"source_width": 0}, true)).is_empty(), "An incomplete frame descriptor is not a size measurement")
	windows = Windows.new()
	windows.tick(0, sample(0, {"path": "E:xr", "eye": eye}))
	var later := Windows.eye_sample(status.merged({"published": 45, "unique_post_draw_frames": 31}, true), pair)
	var event := windows.tick(10000, sample(30, {"path": "E:xr", "eye": later}))
	expect(event.eye_output.published == 35 and event.eye_output.unique_post_draw_frames == 29 and event.eye_output.decoder_recycle_waits == 0, "Producer and post-draw counts have independent increments")
	# The bridge keeps one copy in flight: draws that found its fence pending explain a halved bind rate.
	windows = Windows.new()
	windows.tick(0, sample(0, {"path": "E:xr", "eye": Windows.eye_sample(status.merged({"copy_fence_waits": 4}, true), pair)}))
	var fenced := windows.tick(10000, sample(30, {"path": "E:xr", "eye":
		Windows.eye_sample(status.merged({"copy_fence_waits": 19}, true), pair)}))
	expect(fenced.eye_output.copy_fence_waits == 15, "Draws waiting on the previous copy fence are counted per window")
	# Producer render time per window separates a stalled libmpv render from an idle producer.
	windows = Windows.new()
	windows.tick(0, sample(0, {"path": "E:xr", "eye": Windows.eye_sample(status.merged({"producer_render_us": 120000, "producer_slow_renders": 1}, true), pair)}))
	var producer := windows.tick(10000, sample(30, {"path": "E:xr", "eye":
		Windows.eye_sample(status.merged({"producer_render_us": 5620000, "producer_slow_renders": 91}, true), pair)}))
	expect(producer.eye_output.producer_render_us == 5500000 and producer.eye_output.producer_slow_renders == 90, "Producer render time and slow renders are counted per window")
	windows = Windows.new()
	windows.tick(0, sample(0, {"path": "E:xr", "eye": eye}))
	event = windows.tick(10000, sample(30, {"path": "E:xr", "eye": later}))
	expect(event.eye_output.external and event.eye_output.source == "8192x4096" and event.eye_output.output == "8192x4096", "The actual decoder image path and dimensions are reported")
	expect(not event.eye_output.has("superseded_decoder_images") and not event.eye_output.has("session") and not JSON.stringify(event).contains("private_value"), "Missing counters and private status are omitted")
	event = windows.tick(20000, sample(60, {"path": "E:xr", "eye": eye.merged({"session": 2}, true)}))
	expect(not event.has("eye_output"), "Opening a different decoder never differences unrelated counters")
	# No media names or identifiers reach the event.
	expect(not JSON.stringify(clean).contains("uri") and not JSON.stringify(clean).contains("title"), "The event carries no media identity")
	print("Playback diagnostics: %d checks, %d failures" % [checks, failures.size()])
	for failure in failures: printerr(failure)
	quit(1 if not failures.is_empty() else 0)

func expect(condition: bool, label: String) -> void:
	checks += 1
	if not condition: failures.append(label)
