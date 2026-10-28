extends RefCounted
## Debug-only offscreen observation of the actual projection mesh and pinned decoder frame.
const Binding := preload("res://scripts/pair_texture_binding.gd")

static func capture(parent: Node, pair: Dictionary, request: int) -> Dictionary:
	var result := {"state": "failed", "request_id": request, "images": [], "errors": [],
		"scope": "Quest GPU production mesh/shader and pinned decoder pixels; not XR compositor or subjective comfort",
		"projection": parent.layout_snapshot().stream_projection}
	var viewport := SubViewport.new(); viewport.size = Vector2i(513, 513); viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS; parent.add_child(viewport)
	var camera := Camera3D.new(); camera.fov = 80; viewport.add_child(camera)
	var surface := MeshInstance3D.new(); surface.mesh = parent.panel.mesh; viewport.add_child(surface)
	var material := ShaderMaterial.new(); material.shader = load("res://shaders/video_rvm_pair.gdshader")
	surface.material_override = material
	var binding := Binding.new()
	if not binding.bind(material, pair): viewport.queue_free(); return result
	for name in ["video_geometry", "projection_mesh", "projection_uv_packed", "stereo_sbs", "top_bottom", "stereo_half", "source_size", "color_uv_scale"]:
		var value: Variant = parent.material.get_shader_parameter(name)
		if value != null: material.set_shader_parameter(name, value)
	material.set_shader_parameter("alpha_enabled", false); material.set_shader_parameter("sharpness", 0.0)
	DirAccess.make_dir_recursive_absolute("user://diagnostics")
	for eye in (2 if parent.stereo_sbs else 1):
		material.set_shader_parameter("viewing_eye", eye + 1)
		for yaw in ([-90, 0, 90, 180] if parent.geometry == 3 else [-45, 0, 45]):
			camera.rotation.y = deg_to_rad(float(yaw))
			await RenderingServer.frame_post_draw; await RenderingServer.frame_post_draw
			var image := viewport.get_texture().get_image()
			var file := "projection_%d_eye%d_yaw%d.png" % [request, eye, yaw]
			if image.is_empty() or image.save_png("user://diagnostics/" + file) != OK:
				result.errors.append("Projection readback failed")
			else:
				var small: Image = image.duplicate(); small.resize(32, 32)
				var minimum := 1.0; var maximum := 0.0
				for y in 32:
					for x in 32:
						var color := small.get_pixel(x, y)
						minimum = minf(minimum, color.get_luminance()); maximum = maxf(maximum, color.get_luminance())
				result.images.append({"file": file, "eye": eye, "yaw": yaw, "contrast": maximum-minimum})
	var detached := binding.unbind(); viewport.queue_free()
	result["wrappers_detached"] = int(detached.get("slot_token", -1)) == int(pair.slot_token)
	result.state = "captured" if result.errors.is_empty() and result.wrappers_detached else "failed"
	return result
