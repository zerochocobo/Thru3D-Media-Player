extends SceneTree
## Compositor video layer values (native/xr-layer stride): shapes, eye rectangles and poses must
## reproduce the eye-buffer video exactly.

const Geometry := preload("res://scripts/video_geometry.gd")
const VideoLayer := preload("res://scripts/video_layer.gd")
const Surface := preload("res://scripts/media_surface.gd")
const S := VideoLayer.SURFACE_SIZE
var failures: Array[String] = []
var checks := 0

class FakeVideo extends "res://scripts/media_surface.gd":
	var viewing_eye := 0
	var offset := Vector2.ZERO
	var color_grade: RefCounted = null
	var layer_rotation := 0
	func stereo_offset_uv() -> Vector2:
		return offset

func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)

func _near(a: float, b: float) -> bool:
	return absf(a - b) < 0.001

func _initialize() -> void:
	call_deferred("_run")

func _layer(values: PackedFloat32Array, index: int) -> PackedFloat32Array:
	return values.slice(index * VideoLayer.STRIDE, (index + 1) * VideoLayer.STRIDE)

func _rect(layer: PackedFloat32Array) -> Rect2:
	return Rect2(layer[9], layer[10], layer[11], layer[12])

func _run() -> void:
	# The Surface contract is specific to the runtime and graphics API, not the APK vendor.
	for policy in [["Pico OpenXR Runtime", "opengl3", false], ["PICO", "opengl3_es", false],
			["Pico", "vulkan", true], ["PXR Runtime", "opengl3", false],
			["Oculus", "opengl3", true], ["Oculus", "opengl3_es", true], ["Oculus", "vulkan", false],
			["Meta", "opengl3", true], ["Other runtime", "opengl3", true], ["", "opengl3", true]]:
		_check(VideoLayer._surface_vertical_flip(policy[0], policy[1]) == policy[2],
			"Surface orientation policy: %s/%s" % [policy[0], policy[1]])
	for runtime in ["Bytedance PICO", "  Pico OpenXR Runtime  ", "", "OpenXR Runtime"]:
		_check(not VideoLayer._surface_vertical_flip(runtime, "opengl3", true),
			"PICO export cannot miss its Surface policy because of the runtime name")
	_check(not VideoLayer._surface_vertical_flip("Unknown", "opengl3", false, "PICO 4 Ultra"),
		"The generic OpenXR export recognizes the PICO 4 Ultra system")
	_check(not VideoLayer._surface_vertical_flip("Bytedance PICO", "opengl3"), "Vendor-prefixed PICO runtime")
	_check(VideoLayer._surface_vertical_flip("Oculus", "opengl3", true), "Known Meta runtime wins over the export hint")
	var origin := Node3D.new()
	root.add_child(origin)
	var video := FakeVideo.new()
	origin.add_child(video)
	video.initialize_surface(Shader.new())
	var layer := VideoLayer.new(null)
	layer._flip = true

	# VR180 side by side: one equirect layer per eye over its half of the one surface.
	video.geometry = Geometry.Geometry.HALF_EQUIRECT
	video.stereo_sbs = true
	video._apply_geometry()
	var values := layer.layer_values(video, origin)
	_check(values.size() == 2 * VideoLayer.STRIDE, "Stereo needs a layer per eye")
	var left := _layer(values, 0)
	var right := _layer(values, 1)
	_check(int(left[0]) == 2 and int(left[1]) == 1 and int(right[1]) == 2, "Equirect layers visible to left/right eye")
	_check(_rect(left) == Rect2(0, 0, S / 2, S) and _rect(right) == Rect2(S / 2, 0, S / 2, S), "Left half to the left eye")
	_check(_near(left[13], video.SPHERE_RADIUS) and _near(left[14], PI) and _near(left[15], PI / 2) and _near(left[16], -PI / 2),
		"VR180: radius 50, 180 degrees wide, full height")
	_check(left[17] == 1.0, "The Meta GLES decoder Surface retains its vertical flip")

	video.swap_eyes = true
	values = layer.layer_values(video, origin)
	_check(_rect(_layer(values, 0)) == Rect2(S / 2, 0, S / 2, S), "Swapped eyes show the right half to the left eye")
	video.swap_eyes = false
	video.viewing_eye = 2
	values = layer.layer_values(video, origin)
	_check(_rect(_layer(values, 0)) == _rect(_layer(values, 1)) and _rect(_layer(values, 0)).position.x == S / 2,
		"Viewing one eye shows that view to both eyes")
	video.viewing_eye = 0
	video.offset = Vector2(0.02, 0.0)
	values = layer.layer_values(video, origin)
	_check(_rect(_layer(values, 0)).position.x == 0 and _rect(_layer(values, 1)).end.x == S,
		"Positive alignment crops inside each eye instead of submitting out-of-bounds rectangles")
	video.offset = Vector2.ZERO
	video.top_bottom = true
	values = layer.layer_values(video, origin)
	_check(_rect(_layer(values, 0)) == Rect2(0, 0, S, S / 2) and _rect(_layer(values, 1)) == Rect2(0, S / 2, S, S / 2),
		"Top-bottom: the top half is the left eye")
	video.top_bottom = false

	video.geometry = Geometry.Geometry.EQUIRECT_360
	video._apply_geometry()
	values = layer.layer_values(video, origin)
	_check(_near(_layer(values, 0)[14], TAU), "360 spans the whole circle")
	# All signs, both packed axes, swapped views, portrait/landscape and every layer
	# shape. Reconstruct UV at the centre to verify cropping did not scale/flip offsets.
	for projection in [[0, 0.0], [0, 1.0], [1, 0.0], [3, 0.0]]:
		video.geometry = projection[0]; video.set_screen_curve(projection[1]); video.stereo_sbs = true
		video._apply_geometry()
		for tb in [false, true]:
			video.top_bottom = tb
			for swap in [false, true]:
				video.swap_eyes = swap
				for offset in [Vector2(-0.10, 0), Vector2(0.10, 0), Vector2(0, -0.05), Vector2(0, 0.05), Vector2(-0.10, 0.05), Vector2(0.10, -0.05)]:
					video.offset = offset
					for dimensions in [Vector2(4096, 4096), Vector2(2160, 3840), Vector2(3840, 1080)]:
						values = layer.layer_values(video, origin, VideoLayer.SURFACE, dimensions)
						for index in 2:
							var corrected := _layer(values, index)
							var rect := _rect(corrected)
							var source := 1 - index if swap else index
							var bounds := Rect2(0, source * dimensions.y * 0.5, dimensions.x, dimensions.y * 0.5) if tb else Rect2(source * dimensions.x * 0.5, 0, dimensions.x * 0.5, dimensions.y)
							_check(bounds.encloses(rect) and rect.has_area(), "Every correction stays inside its own eye and swapchain")
							_check(corrected[13] > 0 and corrected[14] > 0, "Corrected destination keeps a valid shape")
							if video.geometry == 3: _check(_near(corrected[14], TAU), "360 alignment wraps without losing the seam")
	video.offset = Vector2.ZERO; video.swap_eyes = false; video.top_bottom = false
	for shift in [Vector2(-0.025, -0.025), Vector2(0.025, 0.025), Vector2(-0.0123, 0.0078)]:
		var source_rect := Rect2(0, 0, 1920, 1080)
		var mapped := VideoLayer._aligned_layer(source_rect, shift, 0, PackedFloat32Array([2.0, 1.0]), Transform3D.IDENTITY, false)
		var size := Vector2(mapped.shape[0] / 2.0, mapped.shape[1])
		var centre := Vector2(mapped.pose.origin.x / 2.0, -mapped.pose.origin.y) + Vector2(0.5, 0.5)
		var destination := Rect2(centre - size * 0.5, size)
		var sampled: Vector2 = (mapped.rect.position + (Vector2(0.5, 0.5) - destination.position) / destination.size * mapped.rect.size) / source_rect.size
		_check(sampled.is_equal_approx(Vector2(0.5, 0.5) + shift), "Quantized crop maps the screen centre to exactly the shader's corrected UV")
		_check(Rect2(Vector2.ZERO, Vector2.ONE).encloses(destination), "Quantization cannot push the destination past angular/physical limits")

	# Flat mono: one quad of the screen size where the panel stands, relative to the XR origin.
	video.geometry = Geometry.Geometry.FLAT
	video.stereo_sbs = false
	origin.position = Vector3(0, 0, 5)
	video._apply_geometry()
	values = layer.layer_values(video, origin)
	var quad := _layer(values, 0)
	_check(values.size() == VideoLayer.STRIDE and int(quad[0]) == 0 and int(quad[1]) == 0, "Mono flat: one quad for both eyes")
	_check(_rect(quad) == Rect2(0, 0, S, S), "Mono uses the whole surface")
	_check(_near(quad[13], video._flat.size.x) and _near(quad[14], video._flat.size.y), "Quad has the screen size")
	var local := video.panel.global_transform.origin - origin.global_transform.origin
	_check(_near(quad[2], local.x) and _near(quad[3], local.y) and _near(quad[4], local.z), "Pose is in the origin's (play) space")

	# Curved: a cylinder centred on the viewer side of the screen, same arc width.
	video.set_screen_curve(1.0)
	values = layer.layer_values(video, origin)
	var cylinder := _layer(values, 0)
	var radius: float = video._curve_radius()
	_check(int(cylinder[0]) == 1 and _near(cylinder[13], radius), "Curved screens are cylinders of the curve radius")
	_check(_near(cylinder[14], video._flat.size.x / radius) and _near(cylinder[15], video._flat.size.x / video._flat.size.y),
		"Arc angle and aspect follow the screen size")
	_check(_near(cylinder[4], local.z + radius), "The cylinder centre is one radius towards the viewer")

	# Pictures (2D->3D pairs, photos): their own swapchain and size; a 2D->3D pair is side by side.
	video.set_screen_curve(0.0)
	var picture := Vector2(3840, 1080)
	values = layer.layer_values(video, origin, VideoLayer.PICTURE, picture, 1)
	_check(values.size() == 2 * VideoLayer.STRIDE and int(_layer(values, 0)[19]) == VideoLayer.PICTURE, "A 2D->3D pair is a stereo picture layer")
	_check(_rect(_layer(values, 0)) == Rect2(0, 0, 1920, 1080) and _rect(_layer(values, 1)) == Rect2(1920, 0, 1920, 1080),
		"Pair halves in picture pixels")
	_check(_layer(values, 0)[17] == 1.0, "Godot's top-first pictures retain their GL upload correction")
	# Fixing the PICO Surface must preserve poses, eye windows and GL picture orientation.
	for projection in [[Geometry.Geometry.FLAT, 0.0], [Geometry.Geometry.FLAT, 1.0],
			[Geometry.Geometry.HALF_EQUIRECT, 0.0], [Geometry.Geometry.EQUIRECT_360, 0.0]]:
		video.geometry = projection[0]
		video.set_screen_curve(projection[1])
		for stereo in [0, 1, 2]: # Mono, SBS and top-bottom.
			video.stereo_sbs = stereo > 0
			video.top_bottom = stereo == 2
			video._apply_geometry()
			layer._surface_flip = true
			var meta_values := layer.layer_values(video, origin)
			layer._surface_flip = VideoLayer._surface_vertical_flip("Pico", "opengl3")
			var surface_values := layer.layer_values(video, origin)
			var picture_values := layer.layer_values(video, origin, VideoLayer.PICTURE)
			_check(surface_values.size() == meta_values.size(), "PICO keeps the same compositor layer count")
			for eye in surface_values.size() / VideoLayer.STRIDE:
				var pico := _layer(surface_values, eye)
				_check(pico[17] == 0.0, "PICO GLES Surface has no additional vertical flip")
				_check(pico.slice(0, 17) == _layer(meta_values, eye).slice(0, 17),
					"Runtime orientation never rotates the pose or changes mono/SBS/TB eye windows")
				_check(_layer(picture_values, eye)[17] == 1.0, "GL pictures retain their flip on PICO")
	layer._surface_flip = true
	video.geometry = Geometry.Geometry.FLAT
	video.set_screen_curve(0.0)
	video.stereo_sbs = false
	video.top_bottom = false
	video._apply_geometry()
	# A photo's soft edge stays in the eye buffers: the layer shows the inner part of screen and picture.
	var inset := Vector2(0.05, 0.1)
	values = layer.layer_values(video, origin, VideoLayer.PICTURE, Vector2(6000, 4000), 0, inset)
	var inner := _layer(values, 0)
	_check(_rect(inner) == Rect2(300, 400, 5400, 3200), "Inset picture window")
	_check(_near(inner[13], video._flat.size.x * 0.9) and _near(inner[14], video._flat.size.y * 0.8), "Inset screen size")
	# A partial panorama covers only its window of the sphere, turned to its centre.
	video.geometry = Geometry.Geometry.EQUIRECT_360
	video._apply_geometry()
	values = layer.layer_values(video, origin, VideoLayer.PICTURE, Vector2(4000, 1000), 0, Vector2.ZERO, Vector4(0.5, 0.25, 0.25, 0.5))
	var pano := _layer(values, 0)
	_check(_near(pano[14], TAU * 0.25) and _near(pano[15], PI * 0.25) and _near(pano[16], -PI * 0.25), "Panorama window angles")
	var turned := Quaternion(pano[5], pano[6], pano[7], pano[8])
	var expected := Basis(Vector3.UP, -0.125 * TAU).get_rotation_quaternion()
	_check(turned.is_equal_approx(expected) or turned.is_equal_approx(-expected), "Panorama centre to the right of forward")
	video.geometry = Geometry.Geometry.FLAT
	video._apply_geometry()

	# Compositor filtering replaces the shader's sharpening.
	layer._settings = true
	video.sharpness = 0.6
	_check(int(_layer(layer.layer_values(video, origin), 0)[18]) == VideoLayer.NORMAL_SUPER_SAMPLING | VideoLayer.QUALITY_SHARPENING, "High sharpness: quality sharpening")
	video.sharpness = 0.2
	_check(int(_layer(layer.layer_values(video, origin), 0)[18]) == VideoLayer.NORMAL_SUPER_SAMPLING | VideoLayer.NORMAL_SHARPENING, "Low sharpness: normal sharpening")
	video.sharpness = 0.0
	_check(int(_layer(layer.layer_values(video, origin), 0)[18]) == VideoLayer.NORMAL_SUPER_SAMPLING, "No sharpening: supersampling only")
	layer._settings = false
	_check(int(_layer(layer.layer_values(video, origin), 0)[18]) == 0, "No settings extension: no settings struct")
	_check(not layer.available(), "An unbound layer is never offered")
	layer._flip = false
	_check(_layer(layer.layer_values(video, origin), 0)[17] == -1.0, "No extension explicitly requests omission")
	_check(_layer(layer.layer_values(video, origin, VideoLayer.PICTURE), 0)[17] == -1.0,
		"An unavailable layout extension is never submitted for GL pictures either")

	# Colour grade: a linear grade rides on the layer as scale/bias once the extension is enabled.
	layer._flip = true
	var grade = load("res://scripts/color_grade.gd").new()
	video.set("color_grade", grade)
	grade.select("Warm")
	layer.color_scale_bias = false
	var plain := _layer(layer.layer_values(video, origin), 0)
	_check(plain.size() == VideoLayer.STRIDE and plain[20] == 1.0 and plain[23] == 0.0, "Without the extension the layer carries no grade")
	_check(not layer.grades(grade), "Without the extension a graded file needs the eye buffers")
	layer.color_scale_bias = true
	_check(layer.grades(grade), "With the extension the warm preset stays on the layer")
	var warm := _layer(layer.layer_values(video, origin), 0)
	var terms: Dictionary = grade.layer_terms()
	_check(_near(warm[20], terms.scale.x) and _near(warm[22], terms.scale.z) and _near(warm[23], terms.bias.x), "The layer carries the grade's scale and bias")
	grade.select("Custom")
	grade.adjust("saturation", 1.3)
	_check(not layer.grades(grade), "Saturation still needs the eye buffers")
	grade.select("Original")
	layer.color_scale_bias = false
	_check(layer.grades(grade), "An ungraded file never needs the extension")
	# A rotated phone video on the decoder surface: the flat quad turns with its sides swapped.
	video.set("color_grade", null)
	video.geometry = Geometry.Geometry.FLAT
	video.stereo_sbs = false
	video.set_screen_curve(0.0)
	video._apply_geometry()
	var upright := _layer(layer.layer_values(video, origin), 0)
	video.layer_rotation = 90
	var quarter := _layer(layer.layer_values(video, origin), 0)
	_check(_near(quarter[13], upright[14]) and _near(quarter[14], upright[13]), "90 degrees swap the quad's width and height")
	var quarter_basis := Basis(Quaternion(quarter[5], quarter[6], quarter[7], quarter[8]))
	var upright_basis := Basis(Quaternion(upright[5], upright[6], upright[7], upright[8]))
	_check((upright_basis.inverse() * quarter_basis).is_equal_approx(Basis(Vector3.BACK, -PI / 2)), "The quad turns clockwise about its normal")
	video.layer_rotation = 180
	var flipped := _layer(layer.layer_values(video, origin), 0)
	_check(_near(flipped[13], upright[13]) and _near(flipped[14], upright[14]), "180 degrees keep the quad's sides")
	var picture_quad := _layer(layer.layer_values(video, origin, VideoLayer.PICTURE, Vector2(1000, 500)), 0)
	_check(_near(picture_quad[13], upright[13]) and _near(picture_quad[14], upright[14]), "Pictures ignore the surface rotation")
	video.layer_rotation = 0
	for failure in failures:
		push_error(failure)
	print("video layer: %d checks, %d failures" % [checks, failures.size()])
	quit(1 if failures.size() > 0 else 0)
