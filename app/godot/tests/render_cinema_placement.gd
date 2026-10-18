extends SceneTree
const Video := preload("res://scripts/mpv_video_display.gd")
const Menu := preload("res://scripts/player_menu.gd")
const I18n := preload("res://scripts/i18n.gd")
var checks := 0
var failures: Array[String] = []
var output := ProjectSettings.globalize_path("res://../../build/output/cinema-placement/visuals")

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func shot(viewport: SubViewport, name: String) -> void:
	await process_frame; await RenderingServer.frame_post_draw; await RenderingServer.frame_post_draw
	check(viewport.get_texture().get_image().save_png(output.path_join(name + ".png")) == OK, "Saved screenshot: " + name)

func _initialize() -> void: call_deferred("run")

func run() -> void:
	DirAccess.make_dir_recursive_absolute(output)
	var viewport := SubViewport.new(); viewport.size = Vector2i(1280, 1000); viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS; root.add_child(viewport)
	var camera := Camera3D.new(); camera.position = Vector3(0, 1.6, 0); camera.fov = 65; viewport.add_child(camera)
	var video := Video.new(); viewport.add_child(video); video.set_process(false); video.view_camera = camera
	video.local_uri = "file:///cinema/render.mp4"
	var color := Image.create(640, 360, false, Image.FORMAT_RGB8)
	color.fill(Color(0.10, 0.35, 0.62))
	color.fill_rect(Rect2i(0, 230, 640, 130), Color(0.07, 0.22, 0.3))
	color.fill_rect(Rect2i(110, 85, 95, 145), Color(0.25, 0.58, 0.65))
	color.fill_rect(Rect2i(400, 130, 110, 100), Color(0.6, 0.65, 0.4))
	video.material.set_shader_parameter("color_texture", ImageTexture.create_from_image(color))
	var alpha := Image.create(2, 2, false, Image.FORMAT_R8); alpha.fill(Color.BLACK)
	video.material.set_shader_parameter("alpha_texture", ImageTexture.create_from_image(alpha))
	video.material.set_shader_parameter("source_size", Vector2(640, 360)); video.material.set_shader_parameter("model_size", Vector2(2, 2))
	video.material.set_shader_parameter("alpha_enabled", false)
	video.media.format = {"width": 640, "height": 360}; video._apply_geometry()
	video.screen_distance = 3; video.set_flat_world_pose(Transform3D(Basis.IDENTITY, Vector3(0, 1.6, -3)))
	video.cinema.configure(video, true, camera.global_transform); video.cinema.height = -0.6; video.cinema.recenter(video, camera.global_transform)
	video.panel.visible = true
	var anchor: Vector3 = video.cinema.bottom.origin
	await shot(viewport, "cinema-small")
	video.cinema.show_guide(video, camera.global_transform, true)
	await shot(viewport, "cinema-adjusting-small")
	video.set_screen_scale(2.2)
	check(video.cinema.bottom.origin.is_equal_approx(anchor), "Rendered zoom retains world bottom")
	check(video.cinema.guide.visible and not video.has_node("CinemaReferences"), "Adjustment grid is visible without a screen frame")
	await shot(viewport, "cinema-adjusting-large")
	video.cinema.show_guide(video, camera.global_transform, false)
	await shot(viewport, "cinema-large")
	video.cinema.show_guide(video, camera.global_transform, true)
	video.cinema.push(video, camera.global_position, 2)
	await shot(viewport, "cinema-adjusting-pushed")
	video.cinema.hide_guide()
	await shot(viewport, "cinema-pushed")
	video.set_screen_curve(0.7); video._apply_geometry()
	await shot(viewport, "cinema-curved")
	video.cinema.configure(video, false, camera.global_transform)
	check(not video.has_node("CinemaReferences"), "Free mode has no cinema decorations")
	await shot(viewport, "free")
	video.set_screen_curve(0); video.cinema.configure(video, true, camera.global_transform)
	for preset in Video.ScreenPresets.ITEMS:
		video.screen_preset = preset.id; video._apply_geometry(); video.set_screen_distance(preset.distance)
		video.cinema.height = -preset.size.y * preset.eye_level; video.cinema.recenter(video, camera.global_transform)
		await shot(viewport, "preset-" + preset.id)
	video.cinema.set_eye_level(video, camera.global_transform, 0.5)
	await shot(viewport, "preset-giant32-centered")
	video.hide()
	var state := {"has_video": true, "geometry": 0, "screen_distance": 3.0, "screen_scale": 500.0, "screen_is_default": true, "screen_dimensions": Vector2(8.89, 5.0),
		"spatial_video": true, "spatial_metadata": {"horizontal_fov_degrees": 90}, "spatial_fov_available": true}
	var menu := Menu.new(); menu.state_provider = func(): return state
	menu.adjustment_requested.connect(func(key, value):
		if key == "screen_cinema": state.screen_cinema = value)
	camera.add_child(menu); menu.position.y = -0.45; menu.toggle(); menu._activate(Menu.SCREEN_SETTINGS)
	for language in ["en", "zh", "zh_Hant", "ja"]:
		I18n.use(language)
		for cinema in [false, true]:
			state.screen_cinema = cinema; menu.refresh()
			var targets := [Menu.SCREEN_CINEMA, Menu.SCREEN_CINEMA_OFF, Menu.SCREEN_SET_DEFAULT, Menu.SCREEN_AUTO_DEFAULT, 450, 451, Menu.SPATIAL_FOV, Menu.SETTINGS_CLOSE, 108,
				Menu.SCREEN_CURVE, Menu.SCREEN_CURVE + 1, Menu.SCREEN_CURVE + 2, Menu.SCREEN_CURVE + 3]
			if cinema: targets.append_array([Menu.SCREEN_PRESET, Menu.SCREEN_PRESET + 1, Menu.SCREEN_PRESET + 2, Menu.SCREEN_PRESET + 3, Menu.SCREEN_EYE_LEVEL, Menu.SCREEN_EYE_LEVEL + 1])
			else: check(menu._buttons.filter(func(item): return item.target >= Menu.SCREEN_PRESET and item.target < Menu.SCREEN_PRESET + 4).is_empty(), "Free mode hides cinema presets")
			for target in targets:
				var button: Dictionary = menu._buttons.filter(func(item): return item.target == target)[0]
				var node: Node3D = button.node
				check(menu.ray_hit(node.to_global(Vector3(0, 0, 0.5)), -node.global_basis.z).get("target", -1) == target, "Every cinema/free control is reachable: " + language)
			check(menu._adjust_rows.has(452) != cinema, "Rotation control is free-mode only")
			check(menu._adjust_rows[451].span.y == 3000, "Size slider reaches 3000 percent in both modes")
			await shot(viewport, language + ("-cinema-settings" if cinema else "-free-settings"))
			var on: Node3D = menu._buttons.filter(func(item): return item.target == Menu.SCREEN_CINEMA)[0].node
			menu.update_pointer("right_hand", on.to_global(Vector3(0, 0, 0.5)), -on.global_basis.z, true)
			check(is_instance_valid(menu._tooltip) and menu._tooltip.visible and menu._tooltip.get_child(0).text == menu._tips[Menu.SCREEN_CINEMA], "Cinema help is visible and complete: " + language)
			await shot(viewport, language + ("-cinema-help" if cinema else "-free-help"))
			menu.update_pointer("right_hand", Vector3.ZERO, Vector3.FORWARD, false)
			for target in [Menu.SCREEN_AUTO_DEFAULT, Menu.SCREEN_SET_DEFAULT]:
				var button: Node3D = menu._buttons.filter(func(item): return item.target == target)[0].node
				menu.update_pointer("right_hand", button.to_global(Vector3(0, 0, 0.5)), -button.global_basis.z, true)
				check(menu._tooltip.visible and menu._tooltip.get_child(0).text == menu._tips[target], "Automatic/fixed help is visible and complete: " + language)
				await shot(viewport, language + ("-cinema-" if cinema else "-free-") + ("automatic-help" if target == Menu.SCREEN_AUTO_DEFAULT else "fixed-help"))
				menu.update_pointer("right_hand", Vector3.ZERO, Vector3.FORWARD, false)
	for failure in failures: push_error(failure)
	print("Cinema placement render: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
