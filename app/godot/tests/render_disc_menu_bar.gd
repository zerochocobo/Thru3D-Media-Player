extends SceneTree
## Renders the disc menu toolbar under a stand-in screen for visual review.
var failed := false
var output := ProjectSettings.globalize_path("res://../../build/output/disc-titles")

func frames() -> void:
	await process_frame; await RenderingServer.frame_post_draw; await RenderingServer.frame_post_draw

func _initialize() -> void: call_deferred("run")

func run() -> void:
	DirAccess.make_dir_recursive_absolute(output)
	var viewport := SubViewport.new(); viewport.size = Vector2i(1400, 1000)
	viewport.own_world_3d = true; viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS; root.add_child(viewport)
	var environment := WorldEnvironment.new(); environment.environment = Environment.new()
	environment.environment.background_mode = Environment.BG_COLOR; environment.environment.background_color = Color(0.32, 0.36, 0.42)
	viewport.add_child(environment)
	var origin := Node3D.new(); viewport.add_child(origin)
	var camera := Camera3D.new(); camera.fov = 60; camera.position = Vector3(0, 0, 0); origin.add_child(camera)
	# A cinema-sized screen far away: the toolbar must stay sharp there too.
	var panel := Node3D.new(); panel.position = Vector3(0, 1.0, -14.0); origin.add_child(panel)
	var screen := MeshInstance3D.new(); var quad := QuadMesh.new(); quad.size = Vector2(16.0, 9.0); screen.mesh = quad
	var material := StandardMaterial3D.new(); material.albedo_color = Color(0.05, 0.08, 0.06); material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	screen.material_override = material; panel.add_child(screen)
	for language in ["zh", "en"]:
		preload("res://scripts/i18n.gd").use(language)
		var bar := preload("res://scripts/disc_menu_bar.gd").new()
		origin.add_child(bar)
		bar.sync(true)
		bar.place(panel, quad.size, camera.global_position)
		var hovered: Dictionary = bar._buttons.filter(func(button): return button.target == bar.RESTART)[0]
		var point: Vector3 = hovered.node.global_position
		bar.update_pointer("right_hand", camera.global_position, (point - camera.global_position).normalized(), true)
		await frames()
		viewport.get_texture().get_image().save_png(output.path_join("disc-menu-bar-%s.png" % language))
		# The toolbar is captured into its own high-density compositor plane.
		var capture := preload("res://scripts/menu_composition.gd").new(); viewport.add_child(capture)
		capture.configure(origin, camera, null, [], false, true)
		capture.register_companion(bar)
		capture.update(); await frames()
		var slots: Array = capture.slots.filter(func(value): return value.used and value.nodes.has(bar._buttons[0].node))
		print("HD plane: ", slots.size(), " raw=", slots[0].raw.size if not slots.is_empty() else Vector2i.ZERO)
		if not slots.is_empty(): slots[0].raw.get_texture().get_image().save_png(output.path_join("disc-menu-bar-hd-%s.png" % language))
		if slots.is_empty(): failed = true
		var text: Node = bar._tooltip.get_child(0)
		var tips: Array = capture.slots.filter(func(value): return value.used and value.nodes.has(bar._tooltip) and value.nodes.has(text))
		print("tooltip text in a sharp plane: ", not tips.is_empty())
		if tips.is_empty(): failed = true
		capture.queue_free()
		bar.queue_free(); await frames()
	print("Disc menu bar render: %s" % ("failed" if failed else "passed"))
	quit(1 if failed else 0)
