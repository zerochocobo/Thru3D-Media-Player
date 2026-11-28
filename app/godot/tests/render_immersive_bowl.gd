extends SceneTree
## Far zoom-out renders a 360 sphere from outside: only the far bowl may show, never the near side
## (the bowl's rim legitimately reaches a little past the equator, so back content may edge it).
## Also loads every production sphere shader once so an OpenGL compile error shows in the log.
const Geometry := preload("res://scripts/video_geometry.gd")
const RADIUS := 50.0
const SHADERS := ["video_oes", "video_alpha_oes", "video_rvm_pair", "video_rvm_pair_oes", "video_layer_border", "video_layer_hole", "photo"]
var checks := 0
var failures: Array[String] = []

func _initialize() -> void: _run.call_deferred()
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func _run() -> void:
	var output := ProjectSettings.globalize_path("res://../../build/output/immersive-adjustments/bowl")
	DirAccess.make_dir_recursive_absolute(output)
	var view := SubViewport.new(); view.size = Vector2i(800, 800); view.own_world_3d = true
	view.render_target_update_mode = SubViewport.UPDATE_ALWAYS; root.add_child(view)
	var camera := Camera3D.new(); camera.fov = 90; camera.far = 4000; view.add_child(camera)
	var sphere := MeshInstance3D.new(); sphere.mesh = Geometry.hemisphere(RADIUS, 144, 72, TAU); view.add_child(sphere)
	# Front of the picture (-Z in mesh space) red, back green: the near side would show green.
	var probe := Shader.new()
	probe.code = "shader_type spatial;\nrender_mode unshaded, cull_disabled;\n#include \"res://shaders/video_coordinates.gdshaderinc\"\n" \
		+ "void vertex() { media_direction = VERTEX; }\nvoid fragment() {\n\tif (near_side(media_direction)) { discard; }\n\tALBEDO = media_direction.z < 0.0 ? vec3(1.0, 0.0, 0.0) : vec3(0.0, 1.0, 0.0);\n}\n"
	var material := ShaderMaterial.new(); material.shader = probe; sphere.material_override = material
	for zoom in [0.5, 1.5, 3.0]:
		sphere.position = Vector3(0, 0, -zoom * RADIUS)
		material.set_shader_parameter("viewer_seat", sphere.to_local(camera.global_position) if zoom > 1.0 else Vector3.ZERO)
		await RenderingServer.frame_post_draw; await RenderingServer.frame_post_draw
		var image := view.get_texture().get_image()
		image.save_png(output.path_join("bowl_%.1f.png" % zoom))
		var centre := image.get_pixel(400, 400)
		# Drawn whole, the near side's back content would sit in front of the centre.
		check(centre.r > .9 and centre.g < .1, "Centre shows the front of the picture at zoom %.1f" % zoom)
		if zoom >= 3.0:
			var corner := image.get_pixel(20, 20)
			check(corner.r < .1 and corner.g < .1, "Beyond the bowl is empty at zoom 3")
	# Production shaders: compile and draw once each with a seat outside the sphere.
	for name in SHADERS:
		var production := ShaderMaterial.new(); production.shader = load("res://shaders/%s.gdshader" % name)
		production.set_shader_parameter("video_geometry", 3)
		production.set_shader_parameter("viewer_seat", Vector3(0, 0, 3.0 * RADIUS))
		sphere.material_override = production
		await RenderingServer.frame_post_draw; await RenderingServer.frame_post_draw
		check(production.shader != null and production.shader.get_shader_uniform_list().any(func(u): return u.name == "viewer_seat"), "%s takes the viewer seat" % name)
	view.free()
	for failure in failures: push_error(failure)
	print("Immersive bowl render: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
