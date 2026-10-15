extends SceneTree
## Photo features on the compositor layer: the magnifier's quads (crop, window, eye split), the
## portrait cutout source and a spatial photo's per-eye shift.
const Photo := preload("res://scripts/photo_display.gd")
const VideoLayer := preload("res://scripts/video_layer.gd")
var failures: Array[String] = []
var checks := 0

class MaskedHost extends RefCounted:
	func copy_layer_band_masked(_slot: int, _color: int, _mask: int, _y: int, _rows: int) -> bool: return true

func check(value: bool, message: String) -> void:
	checks += 1
	if not value: failures.append(message)

func _initialize() -> void: call_deferred("_run")

func _rect(values: PackedFloat32Array) -> Rect2:
	return Rect2(values[9], values[10], values[11], values[12])

func _run() -> void:
	var origin := XROrigin3D.new()
	root.add_child(origin)
	var camera := XRCamera3D.new()
	camera.position = Vector3(0, 1.6, 0)
	origin.add_child(camera)
	var photo := Photo.new()
	root.add_child(photo)
	photo.view_camera = camera
	photo.video_layer = VideoLayer.new(null)
	photo.video_layer._flip = true
	photo.panel.visible = true
	photo.global_position = Vector3(0, 1.6, -2.5)
	photo._flat.size = Vector2(2.0, 1.0)
	photo.toggle_inspect()
	check(photo.inspect and photo._detail.visible, "Inspect opens the detail window")
	var image := Vector2(4000, 2000)
	var mono: Dictionary = photo._magnifier_layers(origin, image, -1)
	check(mono.layers.size() == 1, "A mono picture needs one magnifier quad")
	var values: PackedFloat32Array = mono.layers[0].values
	var aspect: Vector2 = photo._detail_material.get_shader_parameter("crop_aspect")
	var span := aspect / photo.magnification
	var expected := Rect2((photo.crop_center - span * 0.5) * image, span * image)
	check(_rect(values).position.is_equal_approx(expected.position) and _rect(values).size.is_equal_approx(expected.size),
		"The quad shows the shader's crop of the picture: %s vs %s" % [_rect(values), expected])
	check(int(values[26]) == VideoLayer.PICTURE_SLOT and int(values[27]) == VideoLayer.OPAQUE and int(mono.layers[0].order) == VideoLayer.OVERLAY_ORDER,
		"Opaque quad over the picture slot, above the picture layer")
	check(mono.window == Rect2(0, 0, 1, 1), "A crop inside the picture fills the window")
	var stereo: Dictionary = photo._magnifier_layers(origin, Vector2(8000, 2000), 1)
	check(stereo.layers.size() == 2 and int(stereo.layers[0].values[1]) == 1 and int(stereo.layers[1].values[1]) == 2, "A stereo pair: a quad per eye")
	check(is_equal_approx(_rect(stereo.layers[1].values).position.x - _rect(stereo.layers[0].values).position.x, 4000.0),
		"The right eye's crop is in the pair's right half")
	# A picture smaller than the window at its true scale: the quad shrinks to the covered part.
	photo.magnification = 0.4
	photo._update_inspect()
	var small: Dictionary = photo._magnifier_layers(origin, image, -1)
	check(not small.layers.is_empty() and small.window.size.x < 1.0 and _rect(small.layers[0].values).end.x <= image.x + 0.01
		and _rect(small.layers[0].values).position.x >= -0.01, "Margins stay outside the swapchain rect: %s" % [small.window])
	photo.magnification = 2.0
	photo._update_inspect()
	photo._show_magnifier_hole(mono.window)
	check(photo.magnifier_on_layer and photo._detail_hole.visible and photo._detail_material.get_shader_parameter("layer_cut") == Vector4(0, 0, 1, 1),
		"The detail window opens a hole over the quad")
	photo._hide_layer()
	check(not photo.magnifier_on_layer and not photo._detail_hole.visible and photo._detail_material.get_shader_parameter("layer_cut") == Vector4.ZERO,
		"Leaving the layer gives the window back to the shader")
	photo.close_inspect()
	check(photo._magnifier_layers(origin, image, -1).layers.is_empty(), "No quad while inspect is closed")
	photo.toggle_inspect()
	photo.set_projection(3)
	check(photo._magnifier_layers(origin, image, -1).layers.is_empty(), "Panoramas keep the projected eye-buffer magnifier")
	photo.set_projection(0)
	# A packed side-by-side photo: each eye's crop in its own half, swapped views swap halves.
	photo.stereo_sbs = true; photo.top_bottom = false
	if not photo.inspect: photo.toggle_inspect()
	photo._update_inspect()
	var packed: Dictionary = photo._magnifier_layers(origin, Vector2(8000, 2000), -1)
	check(packed.layers.size() == 2 and _rect(packed.layers[0].values).end.x <= 4000.01 and _rect(packed.layers[1].values).position.x >= 3999.99,
		"A packed stereo photo magnifies each eye's own view")
	photo.swap_eyes = true
	packed = photo._magnifier_layers(origin, Vector2(8000, 2000), -1)
	check(_rect(packed.layers[0].values).position.x >= 3999.99, "Swapped eyes: the left eye's crop is in the right half")
	photo.swap_eyes = false
	# Spatial photo: the shader moves source eye 0 by +disparity/2; the layer's left eye by -offset/2.
	photo._metadata = {"native_stereo": true, "spatial_disparity": 0.04}
	check(photo.stereo_offset_uv().is_equal_approx(Vector2(-0.04, 0)), "Spatial disparity becomes the layer's stereo offset")
	photo.swap_eyes = true
	check(photo.stereo_offset_uv().is_equal_approx(Vector2(0.04, 0)), "Swapped spatial views shift the other way")
	photo.swap_eyes = false
	photo.stereo_sbs = false
	check(photo.stereo_offset_uv() == Vector2.ZERO, "No shift once shown mono")
	photo._metadata = {}
	# Portrait cutout: the pair and its mask, premultiplied, only over passthrough.
	photo.platform = MaskedHost.new()
	photo.portrait_requested = true; photo.portrait_enabled = true
	photo._display_depth_data = {"stereo_image": Image.create(8, 4, false, Image.FORMAT_RGBA8)}
	photo._portrait_mask.resize(32)
	photo.transparent_background = false
	check(photo._layer_source().is_empty(), "With an environment behind, the cutout stays in the eye buffers")
	photo.transparent_background = true
	var cutout: Dictionary = photo._layer_source()
	check(str(cutout.get("key", "")).begins_with("portrait:") and int(cutout.get("blend", -1)) == VideoLayer.SOURCE_ALPHA
		and int(cutout.get("stereo", 0)) == 1 and cutout.get("mask") == photo._portrait_mask, "Over passthrough the cutout goes on the layer")
	photo._portrait_mask.resize(16)
	check(photo._layer_source().is_empty(), "A mask of another size never reaches the layer")
	photo.portrait_enabled = false
	photo._portrait_mask.resize(32)
	check(photo._layer_source().is_empty(), "No cutout before its mask is ready")
	photo.portrait_requested = false
	photo.platform = null
	print("Photo magnifier layer: %d checks, %d failures" % [checks, failures.size()])
	for failure in failures: print("FAIL: " + failure)
	quit(1 if failures.size() else 0)
