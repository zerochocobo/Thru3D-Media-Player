extends SceneTree
## Playback diagnostic windows separate undisturbed playback from menus and seeks, and stay bounded.
const Windows := preload("res://scripts/playback_diagnostics.gd")
var failures: Array[String] = []
var checks := 0

func sample(frames: int, changes: Dictionary = {}) -> Dictionary:
	var result := {"frames": frames, "xr_frames": frames * 2, "decoder_drops": 0, "vo_drops": 0, "vo_late": 0, "avsync": "0.001", "cache": false, "container_fps": "59.94", "seek_serial": 0,
		"path": "L", "menu": "", "refresh": 120.0, "cap": 120, "performance": "sustained_high", "foveation": 0, "relief": false, "render_scale": 1.1, "inference": false}
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
	# No media names or identifiers reach the event.
	expect(not JSON.stringify(clean).contains("uri") and not JSON.stringify(clean).contains("title"), "The event carries no media identity")
	print("Playback diagnostics: %d checks, %d failures" % [checks, failures.size()])
	for failure in failures: printerr(failure)
	quit(1 if not failures.is_empty() else 0)

func expect(condition: bool, label: String) -> void:
	checks += 1
	if not condition: failures.append(label)
