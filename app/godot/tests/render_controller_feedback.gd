extends SceneTree
const Feedback := preload("res://scripts/controller_feedback.gd")
var checks := 0
var failures: Array[String] = []

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func _initialize() -> void: call_deferred("run")

func run() -> void:
	var output := ProjectSettings.globalize_path("res://../../build/output/controller-feedback-preview")
	DirAccess.make_dir_recursive_absolute(output)
	var viewport := SubViewport.new(); viewport.size = Vector2i(960, 640)
	viewport.own_world_3d = true; viewport.transparent_bg = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS; root.add_child(viewport)
	var camera := Camera3D.new(); viewport.add_child(camera)
	var screen := MeshInstance3D.new(); var quad := QuadMesh.new(); quad.size = Vector2(4, 3); screen.mesh = quad
	screen.position = Vector3(0, 0, -2.01); viewport.add_child(screen)
	var material := StandardMaterial3D.new(); material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.render_priority = -10; screen.material_override = material
	var feedback := Feedback.new(); viewport.add_child(feedback)
	var pose := Transform3D(Basis.IDENTITY, Vector3(0.35, -0.22, -0.4))
	var point := Vector3(0, 0, -2)
	var ray := [pose.origin, (point - pose.origin).normalized()]
	for bright in [false, true]:
		material.albedo_color = Color.WHITE if bright else Color.BLACK
		feedback.update_hand("right_hand", pose, ray, point, true, false, 0.01)
		await process_frame; await RenderingServer.frame_post_draw; await RenderingServer.frame_post_draw
		var image := viewport.get_texture().get_image()
		check(image.save_png(output.path_join("white.png" if bright else "black.png")) == OK, "Save pointer preview")
		var contrasting := 0
		for y in range(311, 329):
			for x in range(471, 489):
				var pixel := image.get_pixel(x, y)
				var luma := (pixel.r + pixel.g + pixel.b) / 3.0
				if luma < 0.35 if bright else luma > 0.5: contrasting += 1
		check(contrasting >= 8, "Reticle remains readable over white/black video: " + str(contrasting))
	# Model the transparent eye-buffer area used by video compositor underlays.
	screen.visible = false
	feedback.update_hand("right_hand", pose, ray, point, false, false, 0.01)
	await process_frame; await RenderingServer.frame_post_draw; await RenderingServer.frame_post_draw
	var image := viewport.get_texture().get_image()
	check(image.save_png(output.path_join("underlay-alpha.png")) == OK, "Save underlay alpha preview")
	check(image.get_pixel(480, 320).a > 0.8, "Cursor restores visible eye-buffer coverage above an underlay hole")
	feedback.update_hand("right_hand", pose, ray, point, false, false, Feedback.IDLE_SECONDS)
	await process_frame; await RenderingServer.frame_post_draw; await RenderingServer.frame_post_draw
	image = viewport.get_texture().get_image()
	check(image.save_png(output.path_join("idle.png")) == OK and image.get_pixel(480, 320).a < 0.01, "Idle feedback leaves no stale cursor")
	for failure in failures: push_error(failure)
	print("Controller feedback render: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
