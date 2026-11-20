extends SceneTree
## The compositor video shows through a hole cleared in the eye buffer. A scene's blended surfaces
## (lamp glows, glass) behind the screen must not land on that hole; ones in front still show.
## Needs a renderer: run without --headless.
var viewport := SubViewport.new()
var failures: Array[String] = []

func _initialize() -> void:
	_run.call_deferred()

func _quad(z: float, material: Material, size: float) -> MeshInstance3D:
	var quad := MeshInstance3D.new()
	var mesh := QuadMesh.new()
	mesh.size = Vector2.ONE * size
	quad.mesh = mesh
	quad.material_override = material
	quad.position = Vector3(0, 0, z)
	viewport.add_child(quad)
	return quad

func _centre() -> Color:
	for frame in 4: await process_frame
	return viewport.get_texture().get_image().get_pixel(32, 32)

func _check(ok: bool, label: String) -> void:
	if not ok: failures.append(label)

func _run() -> void:
	viewport.transparent_bg = true
	viewport.size = Vector2i(64, 64)
	viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var camera := Camera3D.new()
	viewport.add_child(camera)
	camera.current = true
	var wall := StandardMaterial3D.new()
	wall.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	wall.albedo_color = Color(0.2, 0.2, 0.2)
	_quad(-6.0, wall, 20.0)
	var glow := StandardMaterial3D.new()
	glow.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	glow.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	glow.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	glow.albedo_color = Color(1, 1, 0.6)
	var lamp := _quad(-5.0, glow, 3.0)
	var hole := ShaderMaterial.new()
	hole.shader = load("res://shaders/video_layer_hole.gdshader")
	hole.render_priority = -128
	_quad(-2.0, hole, 1.0)
	var behind: Color = await _centre()
	_check(behind.is_equal_approx(Color(0, 0, 0, 0)), "A glow behind the screen leaves the hole clear (%s)" % behind)
	lamp.position.z = -1.0
	var ahead: Color = await _centre()
	_check(ahead.r > 0.9 and ahead.a > 0.9, "A glow in front of the screen still shows (%s)" % ahead)
	for failure in failures: push_error(failure)
	print("Video layer hole: 2 checks, %d failures" % failures.size())
	quit(0 if failures.is_empty() else 1)
