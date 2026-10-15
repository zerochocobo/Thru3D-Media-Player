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
		opens.append({"uri": uri, "position": start_ms, "eye_buffer": _eye_buffer_only})
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
		"details": {"position_seconds": "2.0", "duration_seconds": "20"}}))
	reopen._update_layer()
	check(reopen.opens.size() == 1 and reopen.opens[0].eye_buffer and reopen._layer_blocked_uri == reopen.local_uri,
		"A layer session incompatible before its first frame reopens on the RGBA frames: %s" % [reopen.opens])
	reopen._update_layer()
	check(reopen.opens.size() == 1, "The reopened session is not reopened again")
	reopen.free()
	origin.free()
	print("Frame picture layer checks=%d failures=%d" % [checks, failures.size()])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)
