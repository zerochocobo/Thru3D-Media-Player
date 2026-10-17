extends SceneTree
## Profile 5 and software decode: MPV's RGBA frames copied once per frame into the picture layer,
## shown with the surface's own shape and eyes; the eye buffers keep the file when the layer cannot.
const Video := preload("res://scripts/mpv_video_display.gd")
const VideoLayer := preload("res://scripts/video_layer.gd")
const Geometry := preload("res://scripts/video_geometry.gd")
var checks := 0
var failures: Array[String] = []

class Host extends RefCounted:
	var created: Array = []
	var copied: Array = []
	var refuse_create := false
	func create_layer_image(slot: int, w: int, h: int, _levels: int, _static: bool) -> bool:
		if refuse_create: return false
		if created.is_empty() or created[-1] != [slot, w, h]: created.append([slot, w, h])
		return true
	func acquire_layer_image(_slot: int) -> int: return 1
	func copy_layer_texture(slot: int, texture: int) -> bool:
		copied.append([slot, texture])
		return true
	func release_layer_image(_slot: int, _mipmaps: bool) -> bool: return true
	func close_mpv_video(_id: int) -> void: pass
	func detach_mpv_pair(_id: int, _token: int) -> void: pass

class Layers extends "res://scripts/video_layer.gd":
	var shown := PackedFloat32Array()
	func update_session() -> void: pass
	func available() -> bool: return true
	func supports(_geometry: int, _curved: bool) -> bool: return true
	func _apply(count: int, values: PackedFloat32Array, _orders := PackedInt32Array()) -> bool:
		shown = values
		return count > 0

class Reopen extends "res://scripts/mpv_video_display.gd":
	var opens: Array = []
	func open_local(uri: String, _title: String, start_ms: int = 0, _restore_mode: bool = true,
			_alpha: bool = false, _basename: String = "", _metadata: Dictionary = {}) -> bool:
		opens.append({"uri": uri, "position": start_ms, "eye_buffer": _eye_buffer_only, "read_compat": _network_interleave_next})
		if opens.size() > 3: return false # the device recursed through close_video
		close_video()
		media.begin(media.session_id + 1)
		_layer_requested = false
		return true

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func _initialize() -> void: call_deferred("_run")

func _frame(token: int) -> Dictionary:
	return {"session_id": 5, "color_target": "texture", "color_texture_id": 40 + token, "width": 3840, "height": 1920, "slot_token": token}

func _run() -> void:
	var origin := XROrigin3D.new()
	root.add_child(origin)
	var video := Video.new()
	origin.add_child(video)
	video.set_process(false)
	var host := Host.new()
	video.platform = host
	video.video_layer = Layers.new(null)
	video.video_layer._flip = true
	video.geometry = Geometry.Geometry.HALF_EQUIRECT
	video.stereo_sbs = true
	video.media.session_id = 5
	video.local_uri = "file:///dv-profile5.mp4"
	video._layer_blocked_uri = video.local_uri
	video._binding.ticket = _frame(7)
	check(video._frame_picture_wanted(), "A Profile 5 file on MPV's RGBA frames goes to the picture layer")
	check(video._show_frame_picture(origin, []), "The frame is shown on the layer")
	check(host.created == [[VideoLayer.PICTURE_SLOT, 3840, 1920]] and host.copied == [[VideoLayer.PICTURE_SLOT, 47]],
		"One copy of the frame's texture into a frame-sized picture swapchain: %s %s" % [host.created, host.copied])
	var values: PackedFloat32Array = video.video_layer.shown
	check(values.size() == VideoLayer.STRIDE * 2 and int(values[19]) == VideoLayer.PICTURE and int(values[26]) == VideoLayer.PICTURE_SLOT
		and int(values[0]) == 2 and int(values[27]) == VideoLayer.OPAQUE, "Two opaque equirect layers over the picture slot")
	check(Rect2(values[9], values[10], values[11], values[12]) == Rect2(0, 0, 1920, 1920)
		and Rect2(values[VideoLayer.STRIDE + 9], values[VideoLayer.STRIDE + 10], values[VideoLayer.STRIDE + 11], values[VideoLayer.STRIDE + 12]) == Rect2(1920, 0, 1920, 1920),
		"Each eye shows its half of the frame")
	check(values[17] == 1.0, "GL pictures are top-first")
	video._show_frame_picture(origin, [])
	check(host.copied.size() == 1, "The same frame is not copied again on the next display frame")
	video._binding.ticket = _frame(8)
	video._show_frame_picture(origin, [])
	check(host.copied.size() == 2 and host.copied[-1] == [VideoLayer.PICTURE_SLOT, 48] and host.created.size() == 1,
		"A new frame reuses the swapchain")
	# Only the files the decoder surface cannot take, and only plain presentation.
	video._binding.ticket = _frame(9)
	video._binding.ticket.color_target = "external"
	check(not video._frame_picture_wanted(), "Decoder images stay on their own path")
	video._binding.ticket = _frame(9)
	video._layer_blocked_uri = ""
	check(not video._frame_picture_wanted(), "A file the surface can take reopens there instead")
	video._layer_blocked_uri = video.local_uri
	video.alpha_requested = true
	check(not video._frame_picture_wanted(), "Alpha keeps its eye-buffer shader")
	video.alpha_requested = false
	video.media.session_id = 6
	check(not video._frame_picture_wanted(), "A frame of an earlier session is never shown")
	video.media.session_id = 5
	# A refused swapchain (an XR2 Gen 1 runtime) leaves this file in the eye buffers until the next open.
	host.refuse_create = true
	video._binding.ticket = _frame(10)
	check(not video._show_frame_picture(origin, []) and video._frame_picture_failed and not video._frame_picture_wanted(),
		"A refused swapchain falls back to the eye buffers")
	# Alpha keeps the layer only where the runtime blends layers by the mask; elsewhere the video
	# layer would show uncut, so Alpha goes to the eye buffers.
	host.refuse_create = false
	video._layer_blocked_uri = ""
	video.alpha_requested = true
	video._layer_alpha_allowed = true
	video.video_layer.alpha_blend = false
	check(not video._layer_alpha() and not video._layer_presentation(), "Without the runtime's layer blending Alpha uses the eye buffers")
	video.video_layer.alpha_blend = true
	check(video._layer_alpha() and video._layer_presentation(), "With it Alpha stays on the layer")
	video._layer_alpha_allowed = false
	check(not video._layer_presentation(), "A build that does not allow it keeps the eye buffers")
	# The FPS overlay names why Alpha is in the eye buffers instead of always saying "alpha".
	check(video.layer_block_reason() == "alpha", "A build without layer Alpha says alpha")
	video._layer_alpha_allowed = true
	video.video_layer.alpha_blend = false
	check(video.layer_block_reason() == "blend", "A runtime without layer blending says blend")
	video.video_layer.alpha_blend = true
	video._layer_blocked_uri = video.local_uri
	check(video.layer_block_reason() == "decoder", "Otherwise the real blocker is named: %s" % video.layer_block_reason())
	video._layer_blocked_uri = ""
	video.alpha_requested = false
	video.free()
	# A software decoder on the layer surface never produces a frame: the session reports it at once
	# and the file reopens on MPV's RGBA frames instead of waiting for the output timeout.
	var reopen := Reopen.new()
	origin.add_child(reopen)
	reopen.set_process(false)
	reopen.platform = Host.new()
	reopen.video_layer = Layers.new(null)
	reopen.local_uri = "file:///hi10p.mp4"
	reopen.media.begin(3)
	reopen._layer_requested = true
	reopen._on_state(3, JSON.stringify({"state": "playing", "layer_compatible": false,
		"source_start_ms": 60000,
		"details": {"position_seconds": "2.0", "duration_seconds": "20"}}))
	reopen._update_layer()
	check(reopen.opens.size() == 1 and reopen.opens[0].eye_buffer and reopen._layer_blocked_uri == reopen.local_uri,
		"A layer session incompatible before its first frame reopens on the RGBA frames: %s" % [reopen.opens])
	reopen._update_layer()
	check(reopen.opens.size() == 1, "The reopened session is not reopened again")
	check(reopen.opens[0].position == 60000, "Fallback before the first frame retains the requested resume position")
	reopen.free()
	var network := Reopen.new()
	origin.add_child(network); network.set_process(false)
	network.platform = Host.new(); network.video_layer = Layers.new(null)
	network.local_uri = "https://media.example.test/movie.mp4"; network.media.begin(5); network._layer_requested = true
	network._on_state(5, JSON.stringify({"state": "opening", "network_interleave_suspect": true}))
	network._update_layer()
	check(network.opens.is_empty(), "Suspicious seeks alone cannot reopen a normal source")
	network._on_state(5, JSON.stringify({"state": "opening", "network_interleave_retry": true, "network_interleave_restart_ms": 125000}))
	network._update_layer()
	check(network.opens.size() == 1 and network.opens[0].position == 125000 and not network.opens[0].eye_buffer and network.opens[0].read_compat,
		"Confirmed network compatibility reopens at the actual position while keeping the hardware layer")
	network._update_layer()
	check(network.opens.size() == 1, "Consumed compatibility retry cannot reopen the replacement again")
	network.free()
	origin.free()
	print("Frame picture layer checks=%d failures=%d" % [checks, failures.size()])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)
