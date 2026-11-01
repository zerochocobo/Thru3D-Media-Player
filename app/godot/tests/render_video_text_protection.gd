extends SceneTree
## Actual Godot Compatibility material/array binding; desktop GPU, no Android/OES claim.
var failures: Array[String] = []
func _initialize() -> void: call_deferred("_run")
func _run() -> void:
	var output := ProjectSettings.globalize_path("res://../../build/output/text-protection/godot-render")
	DirAccess.make_dir_recursive_absolute(output)
	var viewport := SubViewport.new()
	viewport.size = Vector2i(640,352); viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var camera := Camera3D.new(); camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 1.1; camera.position.z = 2; viewport.add_child(camera)
	var quad := MeshInstance3D.new(); var mesh := QuadMesh.new(); mesh.size = Vector2(2,1.1); quad.mesh = mesh
	var material := ShaderMaterial.new(); material.shader = load("res://shaders/video_rvm_pair.gdshader")
	var source := Image.load_from_file(ProjectSettings.globalize_path("res://../../build/output/text-protection/gpu-review/source.png"))
	var near := Image.create(1280,352,false,Image.FORMAT_R8)
	for y in 352:
		for x in 1280: near.set_pixel(x,y,Color(0.9 if (x % 640) / 7 % 2 == 0 else 0.1,0,0))
	material.set_shader_parameter("color_texture",ImageTexture.create_from_image(source))
	material.set_shader_parameter("alpha_texture",ImageTexture.create_from_image(near))
	material.set_shader_parameter("source_size",Vector2(640,352))
	material.set_shader_parameter("model_size",Vector2(640,352))
	material.set_shader_parameter("alpha_enabled",false)
	material.set_shader_parameter("depth_shift",0.0175)
	quad.material_override = material; viewport.add_child(quad)
	var frames: Array[Image] = []
	for mode in 4:
		material.set_shader_parameter("depth_enabled",mode != 0)
		var boxes := PackedVector4Array([Vector4(0.0,0.70,1.0,0.91)])
		boxes.resize(8)
		material.set_shader_parameter("depth_text_regions",boxes)
		material.set_shader_parameter("depth_text_count",1 if mode >= 2 else 0)
		var opacity := Vector4.ONE * (0.5 if mode == 2 else 1.0)
		material.set_shader_parameter("depth_text_weights0",opacity)
		material.set_shader_parameter("depth_text_weights1",opacity)
		await process_frame
		await RenderingServer.frame_post_draw
		await RenderingServer.frame_post_draw
		var image := viewport.get_texture().get_image(); frames.append(image)
		image.save_png(output.path_join("material-%d.png" % mode))
	var errors := [0.0,0.0,0.0]
	for y in range(273,300):
		for x in range(195,440):
			for mode in 3:
				var a := frames[mode+1].get_pixel(x,y); var b := frames[0].get_pixel(x,y)
				errors[mode] += absf(a.r-b.r)+absf(a.g-b.g)+absf(a.b-b.b)
	if errors[0] < 1.0: failures.append("Unprotected fixture must deform")
	if errors[2] > 0.1: failures.append("Protected pixels differ from the original Godot material: %s" % errors)
	if errors[1] < 1.0 or absf(errors[0]-errors[1]) < 1.0: failures.append("Partial mask opacity was not bound to the real material")
	viewport.queue_free(); await process_frame
	print("Godot text protection rendering checks=3 failures=%d errors=%s" % [failures.size(),errors])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)
