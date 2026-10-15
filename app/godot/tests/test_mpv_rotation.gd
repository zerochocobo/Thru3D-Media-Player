extends SceneTree

const Video := preload("res://scripts/mpv_video_display.gd")
var checks := 0
var failures: Array[String] = []

class Backend extends RefCounted:
	var speeds: Array = []
	func set_mpv_speed(id: int, value: float) -> bool:
		speeds.append([id, value])
		return true
	func close_mpv_video(_id: int) -> void: pass

class Layers extends "res://scripts/video_layer.gd":
	func update_session() -> void: pass
	func available() -> bool: return true
	func supports(_geometry: int, _curved: bool) -> bool: return true

class ReopenProbe extends "res://scripts/mpv_video_display.gd":
	var opens: Array = []
	func open_local(uri: String, title: String, start_ms: int = 0, restore_mode: bool = true,
			alpha: bool = false, _basename: String = "", _metadata: Dictionary = {}) -> bool:
		opens.append({"uri": uri, "title": title, "position": start_ms, "eye_buffer": _eye_buffer_only,
			"restore": restore_mode, "alpha": alpha})
		media.begin(media.session_id + 1)
		screen_rotation = 0.0
		playback_speed = 1.0
		_layer_session = false
		return true

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func _initialize() -> void: call_deferred("_run")

func _run() -> void:
	var video := ReopenProbe.new()
	root.add_child(video)
	video.set_process(false)
	var backend := Backend.new()
	video.platform = backend
	video.video_layer = Layers.new(null)
	video.local_uri = "file:///rotation.mp4"
	video.display_name = "rotation"
	video.geometry = 0
	video.stereo_sbs = false
	video.media.begin(1)
	check(video._layer_wanted(), "An ordinary unrotated file retains the decoder Surface path")
	video.screen_rotation = 23.0
	video.playback_speed = 1.5
	# A curved screen cannot turn its cylinder: the rotated surface falls back to normalized RGBA.
	video.screen_curve = 0.35
	video._layer_return_uri = video.local_uri
	video._on_state(1, JSON.stringify({"state": "playing", "layer_active": true,
		"layer_compatible": false, "source_rotation_degrees": 90,
		"details": {"position_seconds": "1.5", "duration_seconds": "10"}}))
	check(video.screen_rotation == 23.0, "Source orientation does not add a second manual rotation")
	check(video._layer_return_uri.is_empty(), "A normalized cover frame cannot schedule a raw Surface reopen")
	check(not video._layer_wanted(), "A source rotation blocks the unnormalized decoder Surface")
	video._update_layer()
	check(video.opens.size() == 1 and video.opens[0].eye_buffer, "A cached cover's initial Surface session falls back before its first frame")
	check(video.opens[0].position == 1500, "Surface fallback preserves the observed position without a displayed pair")
	check(video.screen_rotation == 23.0 and video.playback_speed == 1.5, "Reopen preserves the user's manual rotation and playback speed")
	check(backend.speeds == [[2, 1.5]], "Reopened MPV receives the retained playback speed")
	video.screen_curve = 0.0
	video._layer_blocked_uri = ""
	video.media.format = {"width": 2160, "height": 3840, "pixel_aspect": 1.0, "source_rotation_degrees": 90}
	video._accept_source_rotation(90)
	check(video._layer_wanted() and video._layer_blocked_uri.is_empty(), "A flat mono rotated file keeps the decoder Surface; the compositor turns its quad")
	video.screen_curve = 0.35
	check(not video._layer_wanted(), "Curving a rotated file's screen leaves the Surface")
	video.screen_curve = 0.0
	for rotation in [90, 180, 270]:
		video.media.format = {"width": 2160 if rotation != 180 else 3840,
			"height": 3840 if rotation != 180 else 2160, "pixel_aspect": 1.0,
			"source_rotation_degrees": rotation, "unapplied_rotation_degrees": 0}
		video.set_screen_rotation(0)
		video._apply_geometry()
		check((video._flat.size.y > video._flat.size.x) == (rotation != 180), "Normalized dimensions preserve portrait/landscape aspect")
		check(video.screen_rotation == 0.0 and video.panel.transform.basis.is_equal_approx(Basis.IDENTITY), "Straighten leaves the already normalized file upright")
		video.set_screen_rotation(-35)
		check(video.screen_rotation == -35.0 and video.media.format.source_rotation_degrees == rotation, "Manual adjustments preserve the file's source direction")
	video.local_uri = "file:///ordinary.mp4"
	video._accept_source_rotation(0)
	check(video._layer_wanted(), "Opening another unrotated file keeps the optimized Surface path")
	# A normal PICO video starts in the eye buffers for its cover, then rejoins the Surface.
	# Correcting its Surface flag must not bypass that optimized path or reapply source rotation.
	video.video_layer._surface_flip = false
	video.set_screen_rotation(0)
	video.media.frame_counter = 1
	video.media.last_pair = {"pts_us": 2000000}
	video._layer_return_uri = video.local_uri
	video._thumb_after_ms = 2000
	var open_count := video.opens.size()
	video._update_layer()
	check(video.opens.size() == open_count, "Cover acquisition keeps the normal PICO video in the eye buffers")
	video._thumb_after_ms = -1
	video._thumbnail_busy = true
	video._update_layer()
	check(video.opens.size() == open_count, "Cover upload finishes before the Surface reopen")
	video._thumbnail_busy = false
	video._update_layer()
	check(video.opens.size() == open_count + 1 and not video.opens[-1].eye_buffer,
		"After the cover a normal PICO video still reopens on the compositor Surface")
	check(video.opens[-1].position == 2000 and video.screen_rotation == 0.0,
		"Cover handoff keeps the shown position without adding manual rotation")
	check(not video.video_layer._surface_flip, "Cover handoff retains the corrected Surface orientation")
	video.video_layer = null
	video.free()
	for failure in failures: push_error(failure)
	print("MPV rotation: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
