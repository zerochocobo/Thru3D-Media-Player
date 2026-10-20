extends SceneTree
## The projection mask must retain fractional coverage over both scenery and passthrough.
const HOLE := preload("res://shaders/menu_layer_hole.gdshader")
var failures: Array[String] = []
var checks := 0

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func _initialize() -> void: _run.call_deferred()

func _run() -> void:
	var viewport := SubViewport.new()
	viewport.size = Vector2i(320, 80)
	viewport.own_world_3d = true
	viewport.transparent_bg = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var camera := Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 1.0
	camera.position.z = 1.0
	viewport.add_child(camera)
	var background := MeshInstance3D.new()
	background.mesh = QuadMesh.new()
	background.mesh.size = Vector2(4, 1)
	var plate := StandardMaterial3D.new()
	plate.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	plate.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	plate.albedo_color = Color(0.6, 0.4, 0.2, 1.0)
	background.material_override = plate
	viewport.add_child(background)
	var mask := Image.create(5, 1, false, Image.FORMAT_RGBA8)
	for x in 5: mask.set_pixel(x, 0, Color(1, 1, 1, float(x) / 4.0))
	var hole := MeshInstance3D.new()
	hole.mesh = QuadMesh.new()
	hole.mesh.size = Vector2(4, 1)
	hole.position.z = 0.01
	var material := ShaderMaterial.new()
	material.shader = HOLE
	material.render_priority = 5
	material.set_shader_parameter("menu_texture", ImageTexture.create_from_image(mask))
	hole.material_override = material
	viewport.add_child(hole)
	for alpha in [1.0, 0.6]:
		plate.albedo_color.a = alpha
		hole.visible = false
		await process_frame; await RenderingServer.frame_post_draw
		var reference := viewport.get_texture().get_image()
		hole.visible = true
		await process_frame; await RenderingServer.frame_post_draw
		var result := viewport.get_texture().get_image()
		for x in 5:
			var point := Vector2i(32 + 64 * x, 40)
			var before := reference.get_pixelv(point)
			var after := result.get_pixelv(point)
			var keep := 1.0 - mask.get_pixel(x, 0).a
			check(absf(after.a - before.a * keep) < 0.015,
				"Fractional alpha survives at coverage %d, background %s" % [x, alpha])
			# Desktop Compatibility stores the premultiplied scene in display space.
			for channel in 3:
				check(absf(after[channel] - before[channel] * keep) < 0.02,
					"Premultiplied channel %d follows coverage %d, background %s" % [channel, x, alpha])
	# A tooltip's fractional hole must not prevent the opaque menu hole behind it
	# from clearing the same pixels. Their transparent draw order changes with view angle.
	var panel := MeshInstance3D.new()
	panel.mesh = hole.mesh
	panel.position.z = 0.005
	var panel_material := ShaderMaterial.new(); panel_material.shader = HOLE
	var opaque := Image.create(1, 1, false, Image.FORMAT_RGBA8); opaque.fill(Color.WHITE)
	panel_material.set_shader_parameter("menu_texture", ImageTexture.create_from_image(opaque))
	panel.material_override = panel_material; viewport.add_child(panel)
	plate.albedo_color.a = 1.0
	for priority in [4, 6]:
		panel_material.render_priority = priority
		await process_frame; await RenderingServer.frame_post_draw
		var result := viewport.get_texture().get_image()
		var worst := 0.0
		for x in 5:
			var color := result.get_pixel(32 + 64 * x, 40)
			worst = maxf(worst, maxf(color.a, maxf(color.r, maxf(color.g, color.b))))
		check(worst < 0.015, "Overlapping menu/tooltip holes clear scenery in either draw order: priority %d, residual %.3f" % [priority, worst])
	viewport.queue_free()
	for failure in failures: push_error(failure)
	print("Menu edge coverage: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
