extends SceneTree

const Fixtures := preload("res://tests/test_video_capture.gd")
const Capture := preload("res://scripts/video_capture.gd")
const Menu := preload("res://scripts/player_menu.gd")
const Photo := preload("res://scripts/photo_display.gd")
const Privacy := preload("res://scripts/media_privacy.gd")
var failures: Array[String] = []
var checks := 0

class StalePip extends RefCounted:
	func active() -> bool: return true

class FlatVideo extends Fixtures.Video:
	var pip := StalePip.new()
	var cast_token := ""

func check(value: bool, message: String) -> void:
	checks += 1
	if not value: failures.append(message)

func _initialize() -> void: call_deferred("run")

func run() -> void:
	var video := FlatVideo.new()
	video.geometry = 0; video.stereo_sbs = false
	var capture := Capture.new(video)
	check(capture.ready() and capture.snapshot().available, "Flat movies expose capture actions")
	check(not capture.snapshot().pip, "A leftover VR PiP does not select composition for flat movies")
	check(capture.screenshot(), "Paused flat screenshot is accepted")
	var still: Dictionary = video.platform.requests[0]
	check(still.mode.geometry == 0 and not still.mode.stereo_sbs and still.exact_frame, "Screenshot keeps flat layout and paused source time")
	check(not still.has("pip"), "Flat screenshot never submits a PiP recipe")
	check(capture.start(), "Flat recording can start while a screenshot saves")
	var clip: Dictionary = video.platform.requests[1]
	check(clip.kind == "live_clip" and clip.session_id == 7, "Flat recording uses the same playback/audio owner as narrated VR recording")
	check(clip.mode.geometry == 0 and not clip.has("pip"), "Flat recording retains original packets without composition")
	check(not video.requested_play and capture.status().paused, "Starting capture does not force playback")
	video.requested_play = true; video.media.state = "playing"; video.source_ms += 2000
	capture.tick()
	check(capture.status().duration_ms == 2000 and video.platform.clocks[-1].playing, "Flat video updates the live audio clock")
	check(video.platform.requests.size() == 2 and not capture.recording.is_empty(), "No independent clip reader or unsupported PiP sample is requested")
	video.requested_play = false; video.media.state = "paused"; capture.tick()
	check(capture.status().paused and not video.platform.clocks[-1].playing, "Paused flat playback freezes the recorded audio clock")
	check(capture.stop() and video.platform.stops[-1].end_us == 14345000, "Stop seals the current source interval")
	check(not capture.stop() and video.platform.stops.size() == 1, "Flat recording cannot be stopped twice")
	var menu := Menu.new()
	menu.state_provider = func(): return {"has_video": true, "geometry": 0, "source_uri": video.local_uri, "capture": capture.snapshot()}
	root.add_child(menu); menu.visible = true; menu.refresh()
	check(menu._buttons.any(func(item): return item.target == Menu.CAPTURE), "Flat transport shows its camera action")
	menu._hover["right_hand"] = Menu.CAPTURE; menu._capture_hover_ms = Time.get_ticks_msec() - 200; menu._process_capture_hover()
	check(menu._buttons.any(func(item): return item.target == Menu.CAPTURE_PICTURE), "Flat camera opens screenshot actions")
	var previous_memory: String = Privacy.file_settings
	Privacy.file_settings = "none"
	var photo := Photo.new()
	photo.queue = [{"uri": "file:///Pictures/Thru3D/screenshot_flat.jpg", "title": "screenshot_flat.jpg"}]
	photo.mode_lock = {"geometry": 3, "layout": 1, "fisheye_fov": 180}
	var restored: Dictionary = photo._resolved_mode(0, {"capture_mode": still.mode})
	check(restored.geometry == 0 and not restored.stereo_sbs, "A flat screenshot overrides a global VR image lock without per-file memory")
	var exported := Fixtures.CapturedVideo.new()
	exported.geometry = 3; exported._capture_layout_pending = true
	exported.media.playback = {"details": {"capture_mode": JSON.stringify(clip.mode)}}
	check(exported._restore_capture_layout() and exported.geometry == 0 and not exported.stereo_sbs, "A saved flat clip restores its original layout")
	video.packed_file = true
	check(not capture.ready() and not capture.snapshot().available, "Flat support preserves embedded-mask restrictions")
	video.packed_file = false; video.cast_token = "cast"
	check(not capture.ready() and not capture.snapshot().available, "Flat support preserves cast restrictions")
	photo.panorama_tiles.free(); photo.free(); exported.free(); menu.free(); video.free()
	Privacy.file_settings = previous_memory
	print("Flat capture checks: %s (%d)" % ["passed" if failures.is_empty() else "FAILED", checks])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)
