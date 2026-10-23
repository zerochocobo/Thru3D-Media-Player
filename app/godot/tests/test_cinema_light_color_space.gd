extends SceneTree
## Actual GL pixels: multiply albedo and irradiance in linear light, not sRGB.
const Hall := preload("res://shaders/cinema_baked_surface.gdshader")
const Seat := preload("res://shaders/cinema_baked_seat.gdshader")
var failures: Array[String] = []

func _initialize() -> void: run.call_deferred()
func texture(value: float) -> ImageTexture:
	var image := Image.create(4, 4, false, Image.FORMAT_RGB8)
	image.fill(Color(value, value, value))
	return ImageTexture.create_from_image(image)

func run() -> void:
	if DisplayServer.get_name() == "headless": quit(2); return
	var view := SubViewport.new(); view.size = Vector2i(64, 64)
	view.own_world_3d = true; view.render_target_update_mode = SubViewport.UPDATE_ALWAYS; root.add_child(view)
	var camera := Camera3D.new(); view.add_child(camera); camera.position.z = 2
	var quad := QuadMesh.new(); quad.size = Vector2(2, 2)
	var arrays := quad.get_mesh_arrays()
	var colors := PackedColorArray(); var secondary := PackedVector2Array()
	for vertex in arrays[Mesh.ARRAY_VERTEX]:
		colors.append(Color(.5, .5, .5, sqrt(.25 / 8)))
		secondary.append(Vector2.ONE * sqrt(.25 / 8))
	arrays[Mesh.ARRAY_COLOR] = colors; arrays[Mesh.ARRAY_TEX_UV2] = secondary
	var mesh := ArrayMesh.new(); mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var instance := MeshInstance3D.new(); instance.mesh = mesh; view.add_child(instance)
	var samples := []
	for shader in [Hall, Seat]:
		var material := ShaderMaterial.new(); material.shader = shader
		material.set_shader_parameter("surface_texture", texture(.5))
		if shader == Hall:
			material.set_shader_parameter("light_texture", texture(Color(.25, .25, .25).linear_to_srgb().r))
			material.set_shader_parameter("light_off_texture", texture(Color(.25 / 8, .25 / 8, .25 / 8).linear_to_srgb().r))
		instance.material_override = material
		for tint_value in ([1.0, .5] if shader == Hall else [1.0]):
			if shader == Hall: material.set_shader_parameter("tint", Color(tint_value, tint_value, tint_value))
			for mix_value in [0.0, .5, 1.0]:
				material.set_shader_parameter("cinema_light_mix", mix_value)
				await process_frame; await RenderingServer.frame_post_draw; await RenderingServer.frame_post_draw
				var actual := view.get_texture().get_image().get_pixel(32, 32).r
				var linear := Color(tint_value, tint_value, tint_value).srgb_to_linear().r * Color(.5, .5, .5).srgb_to_linear().r * lerpf(.25, 2.0, mix_value)
				var expected := Color(linear, linear, linear).linear_to_srgb().r
				samples.append({"shader": shader.resource_path, "mix": mix_value, "actual": actual, "expected": expected})
				if absf(actual - expected) > .015: failures.append(str(samples.back()))
	print("CINEMA_LIGHT_COLOR_SPACE checks=9 failures=%d samples=%s" % [failures.size(), str(samples)])
	for failure in failures: printerr("FAIL: " + failure)
	view.queue_free(); await process_frame
	quit(0 if failures.is_empty() else 1)
