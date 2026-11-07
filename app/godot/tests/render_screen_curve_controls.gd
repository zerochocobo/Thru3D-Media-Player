extends SceneTree

const Menu := preload("res://scripts/player_menu.gd")
const PhotoMenu := preload("res://scripts/photo_menu.gd")
const I18n := preload("res://scripts/i18n.gd")
var output := ProjectSettings.globalize_path("res://../../build/output/screen-curve/previews")

func _initialize() -> void: _run.call_deferred()

func _run() -> void:
	DirAccess.make_dir_recursive_absolute(output)
	var viewport := SubViewport.new()
	viewport.size = Vector2i(1400, 1200)
	viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var camera := Camera3D.new()
	camera.fov = 60
	viewport.add_child(camera)
	var checks := 0
	for language in ["zh", "en", "ja"]:
		I18n.use(language)
		for mode in ["floating", "cinema", "photo"]:
			camera.position.y = 0.35 if mode != "photo" else 0.0
			var state := {"has_video": true, "has_image": true, "count": 1, "geometry": 0, "screen_curve": 144.5,
				"screen_scale": 100, "screen_distance": 2, "screen_dimensions": Vector2(3.2, 1.35),
				"source_uri": "file:///widescreen.mp4", "title": "Cinema", "playing": true}
			if mode == "cinema":
				state.merge({"screen_scene_locked": true, "screen_scene_curve": true, "screen_curve": rad_to_deg(32.0 / 24),
					"screen_curve_max": rad_to_deg(32.0 / 24), "screen_curve_ticks": [0.0, rad_to_deg(32.0 / 50), rad_to_deg(32.0 / 35), rad_to_deg(32.0 / 24)],
					"cinema_picture_size": 100.0}, true)
			var menu := PhotoMenu.new() if mode == "photo" else Menu.new()
			menu.state_provider = func(): return state
			camera.add_child(menu)
			menu.position = Vector3(0, -0.15, -2.0)
			menu.set_process(false)
			menu.toggle()
			menu._adjustment = "photo_curve" if mode == "photo" else "screen"
			menu.refresh()
			await process_frame
			await RenderingServer.frame_post_draw
			await RenderingServer.frame_post_draw
			var row: Dictionary = menu._adjust_rows[Menu.SCREEN_CURVE_SLIDER]
			assert(row.label.text.ends_with("°"), "Curve slider displays degrees")
			assert(row.span.y <= 76.4 if mode == "cinema" else row.span.y == 180.0, "Per-context curve limit")
			assert(row.ticks.size() >= 4, "Reference values appear on the slider")
			assert(menu._buttons.filter(func(b): return b.target >= Menu.SCREEN_CURVE and b.target < Menu.SCREEN_CURVE_SLIDER).is_empty(), "No curve preset buttons")
			checks += 4
			viewport.get_texture().get_image().save_png(output.path_join(mode + "-" + language + ".png"))
			menu.free()
	viewport.free()
	print("Screen curve controls render: %d checks, 0 failures" % checks)
	quit()
