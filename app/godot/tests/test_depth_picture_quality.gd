extends SceneTree
## Picture quality mode under 2D to 3D: the bridge's stereo pair is drawn into the picture layer denoised,
## enlarged and sharpened eye by eye instead of copied, and the eye buffers' draw stays out of its way.
const Video := preload("res://scripts/mpv_video_display.gd")
const VideoLayer := preload("res://scripts/video_layer.gd")
const Geometry := preload("res://scripts/video_geometry.gd")
var checks := 0
var failures: Array[String] = []

class Host extends RefCounted:
	var created: Array = []
	var copied: Array = []
	var enhanced: Array = []
	var refuse_above := 0 # widths above this are refused (0: none)
	func create_layer_image(slot: int, w: int, h: int, _levels: int, _static: bool) -> bool:
		if refuse_above > 0 and w > refuse_above: return false
		if created.is_empty() or created[-1] != [slot, w, h]: created.append([slot, w, h])
		return true
	func acquire_layer_image(_slot: int) -> int: return 1
	func copy_layer_texture(slot: int, texture: int) -> bool:
		copied.append([slot, texture])
		return true
	func enhance_layer_texture(slot: int, texture: int, w: int, h: int, across: int, down: int, sharpen: float, grade: PackedFloat32Array,
			_step: float, _tolerance: float) -> bool:
		enhanced.append({"slot": slot, "texture": texture, "source": [w, h], "eyes": [across, down], "sharpen": sharpen, "graded": not grade.is_empty()})
		return true
	func enhance_frame_texture(_texture: int, _external: bool, _w: int, _h: int, _sx: float, _sy: float, _ow: int, _oh: int,
			_across: int, _down: int, _sharpen: float, _step: float, _tolerance: float) -> int: return 0
	func set_layer_picture_quality(_enabled: bool) -> void: pass
	func release_layer_image(_slot: int, _mipmaps: bool) -> bool: return true
	func close_mpv_video(_id: int) -> void: pass
	func detach_mpv_pair(_id: int, _token: int) -> void: pass

class PlainHost extends RefCounted:
	func create_layer_image(_slot: int, _w: int, _h: int, _levels: int, _static: bool) -> bool: return true
	func copy_layer_texture(_slot: int, _texture: int) -> bool: return true
	func set_layer_picture_quality(_enabled: bool) -> void: pass
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

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func _initialize() -> void: call_deferred("_run")

## A 1080p frame's stereo pair as the bridge hands it over.
func _pair(token: int, width := 1920, height := 1080) -> Dictionary:
	return {"session_id": 5, "color_target": "texture", "color_texture_id": 40 + token, "warp_texture_id": 80 + token,
		"width": width, "height": height, "warp_width": width * 2, "warp_height": height, "slot_token": token, "stereo_sbs": true}

func _run() -> void:
	var origin := XROrigin3D.new()
	root.add_child(origin)
	var video := Video.new()
	origin.add_child(video)
	video.set_process(false)
	var host := Host.new()
	video.platform = host
	video.video_layer = Layers.new(null)
	video.video_layer.picture_quality = true
	video.geometry = Geometry.Geometry.FLAT
	video.depth_requested = true
	video.media.session_id = 5
	video.local_uri = "file:///movie-4k.mp4"
	video._binding.warped = true
	video._binding.ticket = _pair(1)
	check(video.picture_quality_available() and video.picture_quality_blocker() == "", "2D to 3D no longer keeps the mode off")
	video._sync_picture_lock()
	check(video.color_grade.curves_locked, "With the mode on offer, gamma and saturation wait for it under 3D too")

	check(video._show_depth_picture(origin, []), "The pair is shown on the picture layer with the mode off")
	check(host.copied == [[VideoLayer.PICTURE_SLOT, 81]] and host.enhanced.is_empty(), "Off: the pair is copied as it is")
	check(not video.layer_picture_baked(VideoLayer.PICTURE), "A copied pair leaves the layer's own filters on")

	video.set_picture_quality(true)
	check(video._show_depth_picture(origin, []), "On: the pair is still shown on the layer")
	check(host.enhanced.size() == 1 and host.enhanced[0].texture == 81 and host.enhanced[0].source == [3840, 1080]
		and host.enhanced[0].eyes == [2, 1], "On: the same pair is drawn again by the mode, eye by eye: %s" % [host.enhanced])
	check(host.copied.size() == 1, "On: no plain copy as well")
	check(video.layer_picture_baked(VideoLayer.PICTURE), "The drawn pair is sharpened and graded already")
	video._show_depth_picture(origin, [])
	check(host.enhanced.size() == 1, "The same pair is not drawn twice")
	video.picture_sharpness = 1.5
	video._show_depth_picture(origin, [])
	check(host.enhanced.size() == 2 and is_equal_approx(host.enhanced[-1].sharpen, 1.5), "A paused pair follows the sharpness slider")
	video._binding.ticket = _pair(2)
	video._show_depth_picture(origin, [])
	check(host.enhanced.size() == 3 and host.enhanced[-1].texture == 82, "Every new pair is drawn")

	video.picture_upscale = Video.Upscale.MAXIMUM
	video._binding.ticket = _pair(3)
	video._show_depth_picture(origin, [])
	check(host.created[-1] == [VideoLayer.PICTURE_SLOT, 7680, 2160], "Super resolution enlarges each eye of a 1080p pair to 4K: %s" % [host.created])
	check(Vector2i(video.video_layer.picture_size) == Vector2i(7680, 2160), "The layer takes the enlarged size")
	var sizes := video.picture_upscale_sizes()
	check(sizes.source == Vector2i(1920, 1080) and sizes.maximum == Vector2i(3840, 2160), "The menu names one eye's sizes: %s" % [sizes])
	video._depth_picture = true
	check(video.shown_picture().size == [3840, 2160] and video.shown_picture().upscaled, "The info page shows one enlarged eye")

	# 4K: the bridge draws the pair 2560 wide an eye; super resolution takes each eye back to 4K.
	video._binding.ticket = _pair(4, 3840, 2160)
	video._binding.ticket.warp_width = 5120; video._binding.ticket.warp_height = 1440
	host.refuse_above = 6000
	video._show_depth_picture(origin, [])
	check(host.created[-1] == [VideoLayer.PICTURE_SLOT, 5120, 1440] and host.enhanced[-1].source == [5120, 1440],
		"A runtime refusing the enlarged pair gets it at its own size, still drawn by the mode: %s" % [host.created])
	check(video._depth_upscale_failed == 5, "The refusal holds for this session")
	host.refuse_above = 0
	video._depth_picture = false
	check(video.picture_upscale_sizes().source == Vector2i(2560, 1440), "A 4K source is enlarged from the bridge's 2560-wide eye")

	# The eye buffers' draw stays off while the pair is on the layer.
	video._depth_picture = true
	video._binding.material = ShaderMaterial.new()
	video._sync_eye_quality()
	check(not video._binding.enhance_expected, "The eye buffers do not draw the mode a second time")

	video.set_picture_quality(false)
	video._binding.ticket = _pair(5)
	video._show_depth_picture(origin, [])
	check(host.copied[-1] == [VideoLayer.PICTURE_SLOT, 85] and not video.layer_picture_baked(VideoLayer.PICTURE), "Off again: plain copies")

	# A plugin without the draws keeps 2D to 3D as it was, and says why.
	video.platform = PlainHost.new()
	check(not video.picture_quality_available() and video.picture_quality_blocker() == "3d", "Without the draws 3D still explains the blocker")
	video._binding.warped = false
	video._binding.ticket = {}
	video._binding.material = null
	video.free()
	origin.free()
	print("Depth picture quality checks=%d failures=%d" % [checks, failures.size()])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)
