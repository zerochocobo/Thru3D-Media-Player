extends SceneTree
## Real desktop GL Compatibility pixel checks of the unmodified production hole shader.
## Run without --headless (the dummy renderer cannot produce evidence):
## godot --path app/godot --rendering-method gl_compatibility --xr-mode off --script res://tests/render_cinema_occlusion.gd
## Eye offsets below are desktop cameras, not an OpenXR compositor test.

const HOLE := preload("res://shaders/video_layer_hole.gdshader")
const Visuals := preload("res://scripts/input_visuals.gd")
const SIZE := Vector2i(640, 480)
const REAR := Color(0.12, 0.18, 0.62)
const FRONT := Color(0.12, 0.82, 0.24)
const GLASS := Color(0.12, 0.82, 1.0, 0.5)
var failures: Array[String] = []
var checks: Array[Dictionary] = []
var observations: Array[Dictionary] = []
var viewport: SubViewport
var camera: Camera3D
var screen: MeshInstance3D
var front: MeshInstance3D
var glass: MeshInstance3D
var subtitle: Label3D
var controller: Node3D
var output := ""
var current_view := ""

func _initialize() -> void:
	_run.call_deferred()

func _check(ok: bool, label: String, detail: Dictionary = {}) -> void:
	checks.append({"view": current_view, "label": label, "passed": ok, "detail": detail})
	if not ok: failures.append(current_view + ": " + label + " " + str(detail))

func _run() -> void:
	output = ProjectSettings.globalize_path("res://../../build/output/cinema-prototype/occlusion")
	DirAccess.make_dir_recursive_absolute(output)
	if DisplayServer.get_name() == "headless" or RenderingServer.get_current_rendering_method() != "gl_compatibility":
		push_error("This fixture requires real desktop GL Compatibility rendering.")
		quit(2)
		return
	_setup()
	for sample in [
		{"name": "centre", "position": Vector3.ZERO},
		{"name": "left_eye", "position": Vector3(-0.032, 0, 0)},
		{"name": "right_eye", "position": Vector3(0.032, 0, 0)},
		{"name": "walk_right", "position": Vector3(0.75, 0.12, 0.5)},
		{"name": "walk_left_near", "position": Vector3(-0.65, -0.12, -0.7)}]:
		current_view = sample.name
		camera.position = sample.position
		camera.look_at(Vector3(0, 0, -6))
		await _view_checks()
	viewport.free()
	var transparent_leaks := observations.filter(func(entry: Dictionary) -> bool: return entry.leaks_over_video).size()
	var summary := {"engine": Engine.get_version_info().string, "renderer": RenderingServer.get_current_rendering_method(),
		"scope": "Desktop GL Compatibility transparent eye buffer; CPU premultiplied-alpha composition over a screen-projected checkerboard. No OpenXR session or hardware compositor.",
		"shader": "res://shaders/video_layer_hole.gdshader", "shader_modified": false,
		"checks": checks, "failures": failures, "observations": observations,
		"camera_views": 5, "baseline_checks_passed": failures.is_empty(),
		"transparent_behind_screen_probe_failures": transparent_leaks,
		"unrestricted_transparent_geometry_supported": transparent_leaks == 0,
		"limitation": "The production underlay hole does not write depth; ordinary alpha-blended geometry behind the screen leaks into the video aperture. Baseline success does not resolve this limitation."}
	var file := FileAccess.open(output.path_join("summary.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify(summary, "\t"))
	file.close()
	for failure in failures: push_error(failure)
	print("Cinema occlusion: %d pixel checks, %d failures; %s" % [checks.size(), failures.size(), output])
	quit(0 if failures.is_empty() else 1)

func _setup() -> void:
	viewport = SubViewport.new()
	viewport.size = SIZE
	viewport.own_world_3d = true
	viewport.transparent_bg = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	camera = Camera3D.new()
	camera.fov = 70
	camera.near = 0.05
	viewport.add_child(camera)
	var world := WorldEnvironment.new()
	world.environment = Environment.new()
	world.environment.background_mode = Environment.BG_COLOR
	world.environment.background_color = Color(0, 0, 0, 0)
	world.environment.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	viewport.add_child(world)
	_quad("RearOpaqueWall", Vector3(0, 0, -8), Vector2(18, 12), _mat(REAR))
	screen = _quad("ProductionVideoHole", Vector3(0, 0, -6), Vector2(6, 3.5), null)
	var hole := ShaderMaterial.new()
	hole.shader = HOLE
	hole.render_priority = -128
	screen.material_override = hole
	front = _quad("ForegroundOpaqueChair", Vector3(-1.2, 0.4, -4), Vector2(0.7, 0.7), _mat(FRONT))
	glass = _quad("GlassProbe", Vector3(0.9, 0.4, -4.5), Vector2(0.7, 0.7), _mat(GLASS))
	subtitle = Label3D.new()
	subtitle.text = "SUBTITLE"
	subtitle.font_size = 64
	subtitle.pixel_size = 0.005
	subtitle.position = Vector3(0, -0.85, -4)
	subtitle.modulate = Color(1, 0.88, 0.2)
	subtitle.outline_size = 0
	subtitle.no_depth_test = false
	subtitle.render_priority = 8
	viewport.add_child(subtitle)
	# Exercise the production generic controller mesh/material, without XR tracking.
	var visuals := Visuals.new()
	visuals.use_runtime_models = false
	viewport.add_child(visuals)
	controller = visuals._controller_model(false)
	controller.scale = Vector3.ONE * 6.0
	controller.position = Vector3(-0.8, -0.7, -3)
	viewport.add_child(controller)

func _mat(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.albedo_color = color
	if color.a < 1.0: material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	return material

func _quad(label: String, position: Vector3, size: Vector2, material: Material) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	node.name = label
	node.mesh = QuadMesh.new()
	node.mesh.size = size
	node.position = position
	node.material_override = material
	viewport.add_child(node)
	return node

func _capture(label: String) -> Image:
	await process_frame
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var result := viewport.get_texture().get_image()
	_check(result.save_png(output.path_join(current_view + "_" + label + "_eye.png")) == OK, "Save eye image " + label)
	return result

func _pixel(image: Image, world: Vector3) -> Color:
	var at := Vector2i(camera.unproject_position(world).round())
	if at.x < 0 or at.y < 0 or at.x >= image.get_width() or at.y >= image.get_height():
		_check(false, "Sample stays inside viewport", {"world": str(world), "pixel": str(at)})
		return Color.MAGENTA
	return image.get_pixelv(at)

func _diff(a: Color, b: Color) -> float:
	return Vector4(a.r - b.r, a.g - b.g, a.b - b.b, a.a - b.a).length()

func _view_checks() -> void:
	screen.visible = false
	glass.position.z = -4.5
	var reference := await _capture("reference_no_video")
	var foreground_reference := _pixel(reference, front.global_position)
	screen.visible = true
	var actual := await _capture("hole_glass_front")
	var centre := _pixel(actual, Vector3(0, 0.35, -6))
	var foreground := _pixel(actual, front.global_position)
	_check(centre.a < 0.02 and Vector3(centre.r, centre.g, centre.b).length() < 0.02,
		"Hole clears opaque wall behind video", {"rgba": str(centre)})
	_check(_diff(foreground, foreground_reference) < 0.03 and foreground.a > 0.98,
		"Opaque foreground retains color and alpha", {"rgba": str(foreground), "reference": str(foreground_reference)})
	var front_glass := _pixel(actual, glass.global_position)
	_check(front_glass.a > 0.47 and front_glass.a < 0.53 and front_glass.b > 0.35,
		"Transparent foreground glass blends over the cleared video aperture", {"rgba": str(front_glass)})
	var outside := _pixel(actual, Vector3(4.4, 0, -6))
	_check(outside.a > 0.98, "Opaque scene outside aperture stays opaque", {"rgba": str(outside)})
	_check(_preserved_bright_pixels(reference, actual, controller.global_position, Vector2(0.6, 0.8)) > 80,
		"Production controller foreground pixels survive hole")
	_check(_preserved_bright_pixels(reference, actual, subtitle.global_position, Vector2(2.0, 0.5)) > 80,
		"Depth-tested subtitle glyphs survive hole")
	_save_composite(actual, "hole_glass_front")
	# Transparent behind-screen geometry is a deliberate defect probe. The hole does
	# not write depth, so ordinary alpha materials may be drawn over the underlay.
	glass.position = Vector3(1.2, 0.5, -7)
	var glass_behind := await _capture("hole_glass_behind")
	var leaked := _pixel(glass_behind, glass.global_position)
	observations.append({"view": current_view, "probe": "transparent_geometry_behind_screen",
		"expected_for_depth_correct_video": "alpha zero inside aperture", "rgba": str(leaked),
		"leaks_over_video": leaked.a > 0.05})
	_save_composite(glass_behind, "hole_glass_behind")
	# An ordinary opaque textured video plane is a depth-writing control. This is
	# deliberately not a substitute for the application's compositor hole path.
	var original := screen.material_override
	var video := _mat(Color.WHITE)
	video.albedo_texture = _checker_texture()
	screen.material_override = video
	var opaque_video := await _capture("opaque_textured_video_control")
	var video_pixel := _pixel(opaque_video, glass.global_position)
	glass.visible = false
	var video_without_glass := await _capture("opaque_textured_no_glass_control")
	var clean_pixel := _pixel(video_without_glass, glass.global_position)
	_check(_diff(video_pixel, clean_pixel) < 0.03, "Depth-writing textured video rejects behind-screen glass",
		{"with_glass": str(video_pixel), "without_glass": str(clean_pixel)})
	_check(_diff(_pixel(opaque_video, front.global_position), foreground_reference) < 0.03,
		"Depth-writing textured video preserves nearer opaque geometry")
	screen.material_override = original
	glass.visible = true
	glass.position = Vector3(0.9, 0.4, -4.5)

func _preserved_bright_pixels(reference: Image, actual: Image, world: Vector3, extent: Vector2) -> int:
	var a := camera.unproject_position(world + Vector3(-extent.x * 0.5, extent.y * 0.5, 0))
	var b := camera.unproject_position(world + Vector3(extent.x * 0.5, -extent.y * 0.5, 0))
	var count := 0
	for y in range(maxi(0, ceili(a.y)), mini(SIZE.y, floori(b.y))):
		for x in range(maxi(0, ceili(a.x)), mini(SIZE.x, floori(b.x))):
			var before := reference.get_pixel(x, y)
			if before.r > 0.4 and before.g > 0.35 and before.a > 0.98 and _diff(before, actual.get_pixel(x, y)) < 0.03:
				count += 1
	return count

func _checker_texture() -> ImageTexture:
	var image := Image.create(64, 64, false, Image.FORMAT_RGB8)
	for y in 64:
		for x in 64:
			image.set_pixel(x, y, Color(0.9, 0.35, 0.08) if (x / 8 + y / 8) % 2 == 0 else Color(0.12, 0.45, 0.9))
	return ImageTexture.create_from_image(image)

func _save_composite(eye: Image, label: String) -> void:
	var composite := Image.create(SIZE.x, SIZE.y, false, Image.FORMAT_RGB8)
	for y in SIZE.y:
		for x in SIZE.x:
			# Desktop simulator of an underlay quad at the same pose as the hole.
			var ray_origin := camera.project_ray_origin(Vector2(x, y))
			var ray := camera.project_ray_normal(Vector2(x, y))
			var distance := (-6.0 - ray_origin.z) / ray.z
			var point := ray_origin + ray * distance
			var underlay := Color(0.02, 0.02, 0.025)
			if distance > 0 and absf(point.x) < 3 and absf(point.y) < 1.75:
				var tile := floori((point.x + 3) * 4) + floori((point.y + 1.75) * 4)
				underlay = Color(0.9, 0.35, 0.08) if tile % 2 == 0 else Color(0.12, 0.45, 0.9)
			var pixel := eye.get_pixel(x, y)
			# Godot's transparent eye texture stores premultiplied color.
			composite.set_pixel(x, y, Color(pixel.r + underlay.r * (1.0 - pixel.a),
				pixel.g + underlay.g * (1.0 - pixel.a), pixel.b + underlay.b * (1.0 - pixel.a)))
	_check(composite.save_png(output.path_join(current_view + "_" + label + "_composite.png")) == OK, "Save composed underlay image " + label)
