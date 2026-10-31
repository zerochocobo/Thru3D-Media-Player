extends SceneTree
## Flat-screen PGS cues on their own compositor layer: the cue's part of the subtitle surface as a
## quad (or a cylinder section on a curved screen), copied once per cue into a bucket-sized swapchain.
const Video := preload("res://scripts/mpv_video_display.gd")
const VideoLayer := preload("res://scripts/video_layer.gd")
var checks := 0
var failures: Array[String] = []

class Host extends RefCounted:
	var created: Array = []
	var copies := 0
	var refuse_slot := -1
	func create_layer_image(slot: int, w: int, h: int, _levels: int, _static: bool) -> bool:
		if slot == refuse_slot: return false
		if created.is_empty() or created[-1] != [slot, w, h]: created.append([slot, w, h])
		return true
	func acquire_layer_image(_slot: int) -> int: return 1
	func copy_layer_texture(_slot: int, _texture: int) -> bool:
		copies += 1
		return true
	func release_layer_image(_slot: int, _mipmaps: bool) -> bool: return true
	func close_mpv_video(_id: int) -> void: pass
	func detach_mpv_pair(_id: int, _token: int) -> void: pass

class Layers extends "res://scripts/video_layer.gd":
	var shown := PackedFloat32Array()
	var orders := PackedInt32Array()
	var refuse_show := false
	func update_session() -> void: pass
	func available() -> bool: return true
	func supports(_geometry: int, _curved: bool) -> bool: return true
	func _apply(count: int, values: PackedFloat32Array, layer_orders := PackedInt32Array()) -> bool:
		shown = values
		orders = layer_orders
		return count > 0 and not refuse_show

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func _initialize() -> void: call_deferred("_run")

func _cue(version: int, width: int, height: int) -> Dictionary:
	return {"version": version, "width": width, "height": height, "x": 960 - width / 2, "y": 1000 - height,
		"canvas_width": 1920, "canvas_height": 1080}

func _apply(video: Node3D, cue: Dictionary) -> void:
	var pixels := PackedByteArray()
	pixels.resize(int(cue.width) * int(cue.height) * 4)
	video.bitmap_subtitles.apply(video.material, cue, 1, pixels)

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
	video.geometry = 0
	video.stereo_sbs = false
	video._layer_session = true
	video.global_position = Vector3(0, 1.5, -3)
	video.panel.visible = true
	_apply(video, _cue(1, 300, 50))
	var extras: Array = video._subtitle_layer_extras(origin)
	check(extras.size() == 1 and video._subtitle_on_layer, "A flat PGS cue goes on its own layer")
	var values: PackedFloat32Array = extras[0].values
	check(int(values[0]) == 0 and int(values[26]) == VideoLayer.SUBTITLE_SLOT and int(values[27]) == VideoLayer.SOURCE_ALPHA
		and int(extras[0].order) == VideoLayer.OVERLAY_ORDER, "Premultiplied quad from the subtitle slot above the video")
	check(host.created == [[VideoLayer.SUBTITLE_SLOT, 512, 64]] and host.copies == 1, "One copy into a 256 x 64 bucket: %s" % [host.created])
	check(Rect2(values[9], values[10], values[11], values[12]).is_equal_approx(Rect2(0, 0, 300, 50)), "The cue's pixels at the bucket's top left: %s" % [Rect2(values[9], values[10], values[11], values[12])])
	var rect: Vector4 = video.material.get_shader_parameter("bitmap_subtitle_rect")
	var screen: Vector2 = video._flat.size
	var expected: Vector3 = video.subtitle_transform() * Vector3((rect.x + rect.z / 2 - 0.5) * screen.x, (0.5 - rect.y - rect.w / 2) * screen.y, 0)
	check(Vector3(values[2], values[3], values[4]).is_equal_approx(expected), "Placed where the surface drew the cue: %s vs %s" % [Vector3(values[2], values[3], values[4]), expected])
	check(is_equal_approx(values[13], rect.z * screen.x) and is_equal_approx(values[14], rect.w * screen.y), "Sized as the cue's part of the screen")
	video._subtitle_layer_extras(origin)
	check(host.copies == 1, "An unchanged cue is not copied again")
	_apply(video, _cue(2, 400, 60))
	video._subtitle_layer_extras(origin)
	check(host.copies == 2 and host.created.size() == 1, "A new cue of the same bucket reuses the swapchain")
	# Curved screen: a section of the screen's own cylinder.
	video.set_screen_curve(0.35)
	values = video._subtitle_layer_extras(origin)[0].values
	var radius: float = video._curve_radius()
	rect = video.material.get_shader_parameter("bitmap_subtitle_rect")
	var pose := Transform3D(Basis(Quaternion(values[5], values[6], values[7], values[8])), Vector3(values[2], values[3], values[4]))
	var angle := (rect.x + rect.z / 2 - 0.5) * screen.x / radius
	var on_mesh: Vector3 = video.subtitle_transform() * Vector3(sin(angle) * radius, (0.5 - rect.y - rect.w / 2) * screen.y, (1.0 - cos(angle)) * radius)
	check(int(values[0]) == 1 and is_equal_approx(values[13], radius) and is_equal_approx(values[14], rect.z * screen.x / radius),
		"A curved screen gets a cylinder section of its radius")
	check((pose * Vector3(0, 0, -radius)).is_equal_approx(on_mesh), "The section's middle lies on the curved screen: %s vs %s" % [pose * Vector3(0, 0, -radius), on_mesh])
	video.set_screen_curve(0.0)
	# A cue scaled past the screen edge is clipped as the surface clipped it.
	video.subtitle_size = 2.0
	var wide := _cue(3, 1900, 100)
	var pixels := PackedByteArray(); pixels.resize(1900 * 100 * 4)
	video.bitmap_subtitles.apply(video.material, wide, 1, pixels, 2.0)
	values = video._subtitle_layer_extras(origin)[0].values
	check(values[9] > 0.0 and values[9] + values[11] < 1900.0, "Only the cue's on-screen part is shown")
	# Fallbacks: rotated surfaces, no layer session.
	video.material.set_shader_parameter("rotation_degrees", 90)
	check(video._subtitle_layer_extras(origin).is_empty() and not video._subtitle_on_layer, "A rotated source keeps the eye-buffer surface")
	video.material.set_shader_parameter("rotation_degrees", 0)
	video._layer_session = false
	check(video._subtitle_layer_extras(origin).is_empty(), "No layer outside a layer session")
	video._layer_session = true
	video.bitmap_subtitles.clear(video.material)
	check(video._subtitle_layer_extras(origin).is_empty(), "No cue, no layer")
	video.free()
	_depth_layers(origin)
	_tint_layers(origin)
	origin.free()
	print("Subtitle layers: %d checks, %d failures" % [checks, failures.size()])
	for failure in failures: print("FAIL: " + failure)
	quit(1 if failures.size() else 0)

func _tint_layers(origin: XROrigin3D) -> void:
	var video := Video.new(); origin.add_child(video); video.set_process(false)
	var host := Host.new(); video.platform = host; video.video_layer = Layers.new(null)
	video._layer_session = true; video.panel.visible = true
	var cue := _cue(1, 4, 1)
	var copies := 0
	for rgb in [0xffffff, 0xffe066, 0x80eaff, 0xffffff]:
		check(video.bitmap_subtitles.needs_pixels(cue, 1, rgb), "New tint invalidates the same paused cue")
		var patch := Image.create_empty(4, 1, false, Image.FORMAT_RGBA8)
		patch.fill(Color.hex((rgb << 8) | 255))
		video.bitmap_subtitles.apply(video.material, cue, 1, patch.get_data(), 1, 0, rgb)
		var texture := video.bitmap_subtitles.texture
		check(video._subtitle_layer_extras(origin).size() == 1 and host.copies == copies + 1, "Changing color uploads the independent layer once")
		copies = host.copies
		check(video.bitmap_subtitles.image.get_pixel(0, 0).is_equal_approx(patch.get_pixel(0, 0)), "Layer copy input contains the new tint, including Original restoration")
		if DisplayServer.get_name() != "headless":
			check(video._subtitle_texture.get_image().get_pixel(0, 0).is_equal_approx(patch.get_pixel(0, 0)), "Actual GPU layer bucket contains the selected tint")
		check(not video.bitmap_subtitles.needs_pixels(cue, 1, rgb), "Unchanged tint needs no new native pixels")
		video.bitmap_subtitles.apply(video.material, cue, 1, PackedByteArray(), 1.5, 0.5, rgb)
		video._subtitle_layer_extras(origin)
		check(video.bitmap_subtitles.texture == texture and host.copies == copies, "Resizing, repositioning and paused frames reuse the tinted texture")
	check(video.bitmap_subtitles.needs_pixels(cue, 2, 0xffffff), "A new source cannot reuse the same version's tint")
	video.bitmap_subtitles.clear(video.material)
	check(video._subtitle_layer_extras(origin).is_empty(), "Clearing a tinted cue removes its layer")
	video.free()

func _depth_layers(origin: XROrigin3D) -> void:
	var camera := XRCamera3D.new()
	origin.add_child(camera)
	var video := Video.new()
	origin.add_child(video)
	video.set_process(false)
	video.view_camera = camera
	var host := Host.new()
	var layers := Layers.new(null)
	layers._flip = true
	video.platform = host
	video.video_layer = layers
	video.media.begin(7)
	video.media.state = "playing"
	video.media.frame_counter = 1
	video.panel.visible = true
	video.depth_requested = true
	video.depth_enabled = true
	video._binding.warped = true
	video._binding.ticket = {"session_id": 7, "width": 1920, "height": 1080, "slot_token": 1, "warp_texture_id": 77}
	video._apply_geometry()
	var cue := _cue(1, 300, 50)
	_apply(video, cue)
	video._update_layer()
	check(video.video_layer_shown and layers.shown.size() == VideoLayer.STRIDE * 3,
		"2D->3D submits its stereo picture and a PGS overlay together")
	check(video._subtitle_on_layer and not video._subtitle_surface.visible,
		"A submitted depth PGS overlay hides the duplicate eye-buffer surface")
	if layers.shown.size() == VideoLayer.STRIDE * 3:
		var values := layers.shown.slice(VideoLayer.STRIDE * 2)
		check(values[1] == 0 and values[26] == VideoLayer.SUBTITLE_SLOT and values[27] == VideoLayer.SOURCE_ALPHA
			and layers.orders == PackedInt32Array([VideoLayer.ORDER, VideoLayer.ORDER, VideoLayer.OVERLAY_ORDER]),
			"Depth PGS is an unwarped premultiplied overlay visible to both eyes above the stereo video")
	var copies := host.copies
	video._update_layer()
	check(host.copies == copies, "Paused depth playback reuses both the picture and subtitle copies")
	var pixels := PackedByteArray(); pixels.resize(300 * 50 * 4)
	video.bitmap_subtitles.apply(video.material, cue, 1, pixels, 1.5, 0.5)
	video._update_layer()
	if layers.shown.size() == VideoLayer.STRIDE * 3:
		var values := layers.shown.slice(VideoLayer.STRIDE * 2)
		check(is_equal_approx(values[13], 450.0 / 1920 * video._flat.size.x)
			and values[3] > video.subtitle_transform().origin.y - video._flat.size.y * 0.25,
			"Depth PGS size and position adjust the submitted layer geometry")
	check(host.copies == copies, "Depth PGS adjustments do not reupload unchanged pixels")
	video.set_screen_curve(0.35)
	video._update_layer()
	check(layers.shown.size() == VideoLayer.STRIDE * 3 and layers.shown[VideoLayer.STRIDE * 2] == 1,
		"Curved 2D->3D submits the PGS cylinder section")
	video.set_screen_curve(0.0)
	video.bitmap_subtitles.clear(video.material)
	video._update_layer()
	check(layers.shown.size() == VideoLayer.STRIDE * 2 and not video._subtitle_on_layer and not video._subtitle_surface.visible,
		"A depth subtitle gap/off immediately removes its overlay")
	_apply(video, _cue(2, 300, 50))
	video._update_layer()
	check(layers.shown.size() == VideoLayer.STRIDE * 3 and video._subtitle_on_layer,
		"A new PGS cue returns during depth playback")
	# If its swapchain cannot be uploaded, the subtitle must stay above the video hole.
	video._bitmap_layer_texture = null
	host.refuse_slot = VideoLayer.SUBTITLE_SLOT
	video._update_layer()
	check(video._subtitle_layer_failed and video.video_layer_shown and not video._subtitle_on_layer and video._subtitle_surface.visible
		and video.material.get_shader_parameter("separate_subtitles") == true,
		"A refused subtitle layer falls back to a separate visible surface over the depth picture")
	host.refuse_slot = -1
	video._subtitle_layer_failed = false
	video.material.set_shader_parameter("rotation_degrees", 90)
	video._update_layer()
	check(video._subtitle_surface.visible and not video._subtitle_on_layer
		and video._subtitle_material.get_shader_parameter("rotation_degrees") == 90,
		"Rotated depth source keeps its oriented subtitle surface over the video")
	video.material.set_shader_parameter("rotation_degrees", 0)
	# Failure after subtitle preparation must not leave it hidden on a layer that was never shown.
	host.refuse_slot = VideoLayer.PICTURE_SLOT
	video._binding.ticket.slot_token = 2
	video._update_layer()
	check(not video.video_layer_shown and not video._subtitle_on_layer
		and video.panel.material_override == video.material
		and video.material.get_shader_parameter("separate_subtitles") == false,
		"A refused depth picture restores inline PGS in the eye buffers in the same frame")
	host.refuse_slot = -1
	video._update_layer()
	check(video.video_layer_shown and video._subtitle_on_layer and not video._subtitle_surface.visible,
		"Depth picture recovery submits the cached PGS overlay")
	layers.refuse_show = true
	video._update_layer()
	check(not video.video_layer_shown and not video._subtitle_on_layer,
		"A refused layer submission also restores subtitle fallback")
	layers.refuse_show = false
	video._binding.warped = false
	video.depth_enabled = false
	video.depth_requested = false
	video._apply_geometry()
	video._update_layer()
	check(not video.video_layer_shown and not video._subtitle_on_layer
		and video.material.get_shader_parameter("bitmap_subtitle_enabled") == true,
		"Turning conversion off retains the current PGS cue on the ordinary video shader")
	video.free()
	camera.free()
