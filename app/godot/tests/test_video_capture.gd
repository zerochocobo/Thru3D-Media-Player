extends SceneTree
const Capture := preload("res://scripts/video_capture.gd")
const Overlay := preload("res://scripts/capture_overlay.gd")
const Menu := preload("res://scripts/player_menu.gd")
const Format := preload("res://scripts/capture_mode.gd")
const Photo := preload("res://scripts/photo_display.gd")
const Privacy := preload("res://scripts/media_privacy.gd")
var checks := 0
var failures: Array[String] = []

class Platform extends RefCounted:
	var requests: Array[Dictionary] = []
	var results := {}
	var support_reads := 0
	var stops: Array[Dictionary] = []
	var clocks: Array[Dictionary] = []
	func original_capture_supported() -> bool:
		support_reads += 1
		return true
	func original_capture_request(json: String) -> int:
		requests.append(JSON.parse_string(json)); return requests.size()
	func original_capture_status(id: int) -> String: return JSON.stringify(results.get(id, {"state": "saving"}))
	func original_capture_stop(id: int, end_us: int) -> bool:
		stops.append({"id": id, "end_us": end_us}); return true
	func original_capture_clock(id: int, position_us: int, playing: bool) -> void:
		clocks.append({"id": id, "position_us": position_us, "playing": playing})

class Video extends Node3D:
	var platform := Platform.new()
	var geometry := 1
	var packed_file := false
	var stereo_sbs := true
	var top_bottom := false
	var stereo_half := false
	var swap_eyes := false
	var fisheye_fov := 180
	var local_uri := "smb://server/video_180_sbs.mp4"
	var requested_play := false
	var audio_track_id := -1
	var playback_speed := 1.0
	var media := {"session_id": 7, "state": "paused", "playback": {"details": {"audio_track_id": "2", "audio_tracks": [{"id": 2, "stream_index": 3}]}}}
	var source_ms := 12345
	var valid_frame := true
	var frame_reads := 0
	var captures: RefCounted
	func bookmark_snapshot() -> Dictionary:
		frame_reads += 1
		return {"position_ms": source_ms} if valid_frame else {}

class Main extends "res://scripts/main.gd":
	func _controller_allowed(_hand: String) -> bool: return true
	func _input_focused() -> bool: return true

class CapturedVideo extends "res://scripts/mpv_video_display.gd":
	var revisions := 0
	func _request_revision(_position_ms: int = -1, _mode: String = "") -> void: revisions += 1
	func _apply_geometry() -> void: pass

func check(value: bool, message: String) -> void:
	checks += 1
	if not value: failures.append(message)

func _initialize() -> void: call_deferred("run")

func run() -> void:
	var video := Video.new()
	video.captures = Capture.new(video)
	var capture: RefCounted = video.captures
	check(capture.start(), "Paused source can arm a recording")
	check(not video.requested_play and capture.snapshot().paused, "Arming leaves playback paused")
	check(capture.snapshot().duration_ms == 0, "Armed recording starts at zero")
	capture.tick(); capture.tick()
	check(capture.snapshot().duration_ms == 0, "Wall clock waiting creates no footage")
	check(capture.screenshot(), "Screenshot works during a paused recording")
	check(video.platform.requests[0].kind == "live_clip" and video.platform.requests[0].session_id == 7, "Recording attaches to the current playback, without another reader")
	check(video.platform.requests[1].position_us == 12345000 and video.platform.requests[1].mode.stereo_sbs, "Screenshot uses source PTS and complete stereo layout")
	video.platform.results[2] = {"state": "saved", "directory": "Pictures/Thru3D", "uri": "content://image/1"}
	capture._poll_after = 0; capture.tick()
	check(capture.notice.contains("Pictures/Thru3D"), "Publication success reports the actual directory")
	video.requested_play = true; video.media.state = "playing"; video.source_ms += 2750
	capture.tick()
	check(capture.snapshot().duration_ms == 2750 and not capture.snapshot().paused, "Counter follows source time")
	check(video.platform.requests.size() == 2 and video.platform.requests[0].kind == "live_clip", "Ticking live capture never submits another source export")
	video.media.playback.details.merge({"paused": "no", "paused_for_cache": "yes"})
	capture.tick()
	check(capture.status().paused and not video.platform.clocks[-1].playing, "Actual cache pause immediately freezes recording even when play is requested")
	video.media.playback.details.paused_for_cache = "no"
	capture.tick()
	check(not capture.status().paused and video.platform.clocks[-1].playing, "Resuming actual output updates the audio clock without waiting for the poll interval")
	video.media.playback.details.erase("paused"); video.media.playback.details.erase("paused_for_cache")
	var support_reads := video.platform.support_reads
	var frame_reads := video.frame_reads
	var hud_consistent := true
	for index in 500:
		var status: Dictionary = capture.status()
		hud_consistent = hud_consistent and status.recording and status.duration_ms == 2750
	check(hud_consistent, "Repeated HUD reads keep local recording state")
	check(video.platform.support_reads == support_reads and video.frame_reads == frame_reads, "Per-frame HUD status never crosses the native capability or source-frame boundary")
	video.requested_play = false; video.media.state = "paused"
	capture.tick()
	check(capture.snapshot().paused and capture.snapshot().duration_ms == 2750, "Pause freezes the selected clip")
	check(capture.stop(), "Stop accepts an active recording once")
	check(not capture.stop() and video.platform.stops.size() == 1, "Repeated B/stop cannot create duplicate exports")
	check(video.platform.stops[0].id == 1 and video.platform.stops[0].end_us == 15095000, "Stop seals the live recording at displayed source PTS")
	check(not capture.start(), "Saving a clip prevents another clip queue")
	capture._clock_after = 0; capture.tick()
	check(video.platform.clocks[-1].position_us == 0 and not video.platform.clocks[-1].playing, "Local saving still receives current playback load without reopening its source")
	video.platform.results[1] = {"state": "error", "error": "Not enough storage"}
	capture._poll_after = 0; capture.tick()
	check(not capture.snapshot().clip_busy and not capture.notice.is_empty(), "Export failure releases the slot and remains visible")
	check(capture.start(), "Recording can restart after failure")
	video.source_ms += 1000; capture.tick()
	var app := Main.new()
	app.video = video
	app._on_controller_button("by_button", "right_hand")
	check(capture.recording.is_empty() and app._controller_consumed.get("right_hand/by_button", false), "Right B stops before shortcuts, menus and close actions")
	app.video = null; app.free()
	video.platform.results[3] = {"state": "saved", "directory": "Movies/Thru3D", "uri": "content://video/1"}
	capture._poll_after = 0; capture.tick()
	video.media.playback.details.audio_tracks = [{"id": 2, "external": true, "title": "Clone voice"}]
	check(capture.start() and not video.platform.requests[-1].has("audio_title"), "External audio is captured from playback; saving never resolves its source again")
	video.source_ms += 1500; capture.tick(); video.local_uri = "file:///next.mp4"; capture.tick()
	check(capture.recording.is_empty() and video.platform.requests[-1].uri.begins_with("smb://"), "Switching files saves the departing source range")
	video.platform.results[4] = {"state": "saved", "directory": "Movies/Thru3D", "uri": "content://video/2"}
	capture._poll_after = 0; capture.tick()
	video.playback_speed = 1.5
	var previous_requests := video.platform.requests.size()
	check(not capture.start() and video.platform.requests.size() == previous_requests and capture.notice.contains("1"), "Unsupported speed cannot silently produce mismatched live audio")
	video.playback_speed = 1.0
	var overlay := Overlay.new()
	root.add_child(overlay)
	overlay.sync({"recording": true, "duration_ms": 65000})
	check(overlay.visible and overlay._time.text == "01:05", "Independent overlay displays active recording and time")
	var stopped := [false]
	overlay.stop_requested.connect(func(): stopped[0] = true)
	overlay._activate(Overlay.STOP)
	check(stopped[0], "Overlay has a separate stop action")
	overlay.sync({"recording": true, "paused": true, "duration_ms": 65000})
	check(overlay.visible and overlay._time.text == "01:05", "Paused recording indicator stays visible")
	overlay.update_pointer("left_hand", Vector3.ZERO, Vector3.FORWARD, true)
	check(not overlay._pointers.left_hand.line.visible, "Recording indicator leaves no permanent ray over the video")
	overlay.sync({"clip_busy": true})
	check(overlay.visible, "Finalizing remains visible with controls hidden")
	overlay.sync({})
	check(not overlay.visible, "Indicator disappears only after work and notices finish")
	var state := {"has_video": true, "geometry": 1, "source_uri": "file:///x.mp4", "capture": {"available": true, "ready": true}}
	var menu := Menu.new()
	menu.state_provider = func(): return state
	root.add_child(menu); menu.visible = true; menu.refresh()
	var camera := menu._buttons.filter(func(item): return item.target == Menu.CAPTURE)
	check(camera.size() == 1 and camera[0].rect.get_center().x > 0.28, "Camera sits right of favorites")
	menu._hover["right_hand"] = Menu.CAPTURE; menu._capture_hover_ms = Time.get_ticks_msec() - 200; menu._process_capture_hover()
	check(menu._capture_open and menu._buttons.any(func(item): return item.target == Menu.CAPTURE_PICTURE), "Ray hover opens screenshot and recording actions")
	state.capture.recording = true; menu.refresh()
	menu._hover.clear(); menu._capture_leave_ms = 0; menu._process_capture_hover()
	check(menu._capture_open, "Recording keeps the capture choices expanded")
	menu.dismiss(); overlay.sync(state.capture)
	check(not menu.visible and overlay.visible, "Dismissing transport never hides recording status")
	for geometry in [1, 2, 3]:
		var format := Format.clean({"version": 1, "geometry": geometry, "stereo_sbs": true, "top_bottom": true, "swap_eyes": true})
		check(format.geometry == geometry and format.top_bottom and format.swap_eyes, "Portable format preserves projection and both eyes")
	check(Format.clean({"version": 1, "geometry": 99}).is_empty(), "Untrusted unsupported projection is ignored")
	var portable := Format.clean({"version": 1, "geometry": 3, "stereo_sbs": true, "top_bottom": true, "swap_eyes": true})
	var original_memory: String = Privacy.file_settings
	Privacy.file_settings = "none"
	var photo := Photo.new()
	photo.queue = [{"uri": "file:///Pictures/Thru3D/screenshot_20261020_001200_000.png", "title": "screenshot_20261020_001200_000.png"}]
	photo.mode_lock = {"geometry": 0, "layout": 0, "fisheye_fov": 180}
	var restored: Dictionary = photo._resolved_mode(0, {"capture_mode": portable})
	check(restored.geometry == 3 and restored.top_bottom and restored.swap_eyes, "Timestamp-only screenshot restores VR/stereo even with per-file memory disabled")
	check(photo._resolved_mode(0, {}).geometry == 0, "Ordinary photos keep existing layout behavior")
	var exported_video := CapturedVideo.new()
	exported_video._capture_layout_pending = true
	exported_video.media.playback = {"details": {"capture_mode": JSON.stringify(portable)}}
	check(exported_video._restore_capture_layout() and exported_video.geometry == 3 and exported_video.top_bottom and exported_video.revisions == 1, "Late container metadata restores the exported source layout once")
	check(not exported_video._restore_capture_layout(), "Repeated status snapshots cannot reopen the decoder repeatedly")
	exported_video._capture_layout_pending = true; exported_video._capture_preference_exists = true; exported_video.geometry = 1
	check(not exported_video._restore_capture_layout() and exported_video.geometry == 1, "Explicit saved preference overrides capture metadata")
	# This layout-only fixture never runs Photo._ready(), which normally parents this helper.
	photo.panorama_tiles.free()
	exported_video.free(); photo.free(); Privacy.file_settings = original_memory
	menu.free(); overlay.free(); video.free()
	print("Original capture checks: %s (%d)" % ["passed" if failures.is_empty() else "FAILED", checks])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)
