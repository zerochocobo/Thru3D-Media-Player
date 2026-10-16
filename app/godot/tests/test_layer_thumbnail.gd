extends SceneTree
## Library pictures of videos shown on the compositor layer (copied from the decoder surface).
## godot --headless --xr-mode off --path app/godot --script res://tests/test_layer_thumbnail.gd

const Video := preload("res://scripts/mpv_video_display.gd")
const Thumbnails := preload("res://scripts/thumbnail_cache.gd")
const Geometry := preload("res://scripts/video_geometry.gd")
var checks := 0
var failures: Array[String] = []

class BindingProbe extends "res://scripts/pair_texture_binding.gd":
	func bind(target: ShaderMaterial, pair: Dictionary) -> bool:
		material = target
		ticket = pair.duplicate(true)
		layer = str(pair.get("color_target", "")) == "layer"
		return true

class BridgeProbe extends RefCounted:
	var requests: Array = []
	var pins := 0
	var pending := 2 # polls answered "pending" before the result
	var outcome := "ready"
	var shade := 200
	func request_mpv_layer_thumbnail(id: int, width: int, height: int, rotation: int, crop: PackedFloat32Array, w: int, h: int) -> int:
		requests.append({"id": id, "width": width, "height": height, "rotation": rotation, "crop": crop, "size": Vector2i(w, h)})
		return requests.size()
	func get_mpv_layer_thumbnail_state(_request: int) -> String:
		if pending > 0:
			pending -= 1
			return "pending"
		return outcome
	func take_mpv_layer_thumbnail(_request: int) -> PackedByteArray:
		var pixels := PackedByteArray()
		pixels.resize(Thumbnails.SIZE.x * Thumbnails.SIZE.y * 4)
		pixels.fill(shade)
		return pixels
	func pin_mpv_pair(_id: int, _token: int) -> bool:
		pins += 1
		return false
	func set_mpv_playing(_id: int, _play: bool) -> void: pass
	func close_mpv_video(_id: int) -> void: pass
	func detach_mpv_pair(_id: int, _token: int) -> bool: return true

func check(value: bool, reason: String) -> void:
	checks += 1
	if not value: failures.append(reason)

func near(crop: PackedFloat32Array, expected: Array) -> bool:
	for i in 4:
		if absf(crop[i] - float(expected[i])) > 0.0005: return false
	return true

func layer_video(bridge: BridgeProbe, uri: String, pair: Dictionary, geometry: int) -> Video:
	var video := Video.new()
	video.platform = bridge
	root.add_child(video)
	video.material = ShaderMaterial.new()
	video._binding = BindingProbe.new()
	pair.merge({"session_id": 3, "slot_token": 9, "color_target": "layer", "pts_us": 12000000, "source_epoch": 1})
	video._binding.bind(video.material, pair)
	video.media.begin(3)
	video.media.state = "playing"
	video.media.last_pair = pair
	video.local_uri = uri
	video.geometry = geometry
	video.video_layer_shown = true
	video._thumb_after_ms = 0
	video._thumb_tries = 0
	return video

func _initialize() -> void:
	await process_frame # the root enters the tree after _initialize starts
	Thumbnails.clear()
	var bridge := BridgeProbe.new()
	# VR180 side-by-side: the centre half of the left eye.
	var uri := "file:///storage/emulated/0/Movies/layer_sbs.mp4"
	var video := layer_video(bridge, uri, {"width": 7680, "height": 3840, "stereo_sbs": true, "top_bottom": false}, Geometry.Geometry.HALF_EQUIRECT)
	video._maybe_capture_thumbnail()
	check(video._layer_thumbnail_busy and not video._thumbnail_busy, "A layer copy runs without blocking pair presentation")
	video._maybe_capture_thumbnail()
	check(bridge.requests.size() == 1, "One copy per attempt")
	while video._layer_thumbnail_busy: await process_frame
	var request: Dictionary = bridge.requests[0]
	check(bridge.pins == 0, "The layer path pins no decoder pair")
	check(request.id == 3 and request.width == 7680 and request.height == 3840 and request.rotation == 0
		and request.size == Thumbnails.SIZE, "Request carries the session, displayed size and picture size")
	var eye := Thumbnails.crop_for(Geometry.Geometry.HALF_EQUIRECT, Vector2(3840, 3840))
	check(near(request.crop, [eye.x * 0.5, eye.y, eye.z * 0.5, eye.w]), "Crop lies inside the left eye: " + str(request.crop))
	check(Thumbnails.has(uri) and str(video._thumbnail_result.get("state")) == "stored", "Copied layer frame becomes the library picture")
	check(video._thumb_after_ms < 0, "A stored picture ends the attempts")
	video.queue_free()

	# Top-bottom 360: the top view, a quarter of the panorama.
	bridge.requests.clear(); bridge.pending = 0
	uri = "file:///storage/emulated/0/Movies/layer_tb.mp4"
	video = layer_video(bridge, uri, {"width": 4096, "height": 4096, "stereo_sbs": true, "top_bottom": true}, Geometry.Geometry.EQUIRECT_360)
	video._maybe_capture_thumbnail()
	while video._layer_thumbnail_busy: await process_frame
	eye = Thumbnails.crop_for(Geometry.Geometry.EQUIRECT_360, Vector2(4096, 2048))
	check(near(bridge.requests[0].crop, [eye.x, eye.y * 0.5, eye.z, eye.w * 0.5]), "Top-bottom crop lies inside the top view")
	check(Thumbnails.has(uri), "Top-bottom layer picture stored")
	video.queue_free()

	# A rotated flat mono source: the copy turns it as the layer does.
	bridge.requests.clear()
	uri = "file:///storage/emulated/0/Movies/layer_rotated.mp4"
	video = layer_video(bridge, uri, {"width": 1080, "height": 1920, "surface_rotation_degrees": 90}, Geometry.Geometry.FLAT)
	video._maybe_capture_thumbnail()
	while video._layer_thumbnail_busy: await process_frame
	check(bridge.requests[0].rotation == 90 and bridge.requests[0].width == 1080, "Rotation and displayed size reach the copy")
	video.queue_free()

	# A runtime whose surface cannot be copied: a few spaced tries, then none.
	bridge.requests.clear(); bridge.outcome = "failed:pixel_copy_2"
	uri = "file:///storage/emulated/0/Movies/layer_failed.mp4"
	video = layer_video(bridge, uri, {"width": 3840, "height": 2160}, Geometry.Geometry.FLAT)
	for attempt in 5:
		video.media.last_pair.pts_us = 12000000 + attempt * 3000000
		video._maybe_capture_thumbnail()
		while video._layer_thumbnail_busy: await process_frame
	check(bridge.requests.size() == 3 and video._thumb_after_ms < 0, "Copy failures stop after three tries: " + str(bridge.requests.size()))
	check(str(video._thumbnail_result.get("reason")) == "failed:pixel_copy_2" and not Thumbnails.has(uri), "Failure reason is reported, nothing stored")
	video.queue_free()

	# Not yet on the layer, or a closed video: nothing is requested.
	bridge.requests.clear(); bridge.outcome = "ready"
	uri = "file:///storage/emulated/0/Movies/layer_hidden.mp4"
	video = layer_video(bridge, uri, {"width": 3840, "height": 2160}, Geometry.Geometry.FLAT)
	video.video_layer_shown = false
	video._maybe_capture_thumbnail()
	check(bridge.requests.is_empty(), "No copy before the layer shows the video")
	# Closing while the copy runs drops its result.
	video.video_layer_shown = true
	video._maybe_capture_thumbnail()
	video._thumbnail_sequence += 1
	while video._layer_thumbnail_busy: await process_frame
	check(not Thumbnails.has(uri), "A copy that finishes after its video closed is discarded")
	video.queue_free()

	Thumbnails.clear()
	if failures.is_empty(): print("Layer thumbnail checks passed: ", checks)
	else:
		for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)
