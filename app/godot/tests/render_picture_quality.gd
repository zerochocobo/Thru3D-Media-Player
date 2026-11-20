extends SceneTree
## Previews of picture quality mode in the player menu: QUEST_PLAYER_MENU_PREVIEW_DIR receives the images.
const Menu := preload("res://scripts/player_menu.gd")
const Grade := preload("res://scripts/color_grade.gd")
var state := {"has_video": true, "geometry": 1, "stereo": true, "playing": true, "playback_state": "playing",
	"title": "Travel journal · VR180", "source_size": "8192 x 4096", "codec": "hevc", "position_ms": 123456, "duration_ms": 600000,
	"xr_state": "focused", "layer_available": true, "grade_on_layer": true, "volume": 90, "audio_available": true,
	"picture_quality_supported": true, "picture_quality_available": true, "picture_quality": false, "picture_sharpness": 50.0,
	"picture_inherit_available": true, "picture_source": "last", "reuse_last_picture": false,
	"grade_curves_locked": true, "grade_values": Grade.DEFAULTS.duplicate(), "color_grade": {"preset": "Custom"}}

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	preload("res://scripts/i18n.gd").use(OS.get_environment("QUEST_UI_LANGUAGE") if OS.has_environment("QUEST_UI_LANGUAGE") else "en")
	var output := OS.get_environment("QUEST_PLAYER_MENU_PREVIEW_DIR")
	if output.is_empty():
		quit(1)
		return
	DirAccess.make_dir_recursive_absolute(output)
	var viewport := SubViewport.new()
	viewport.size = Vector2i(1280, 900)
	viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var camera := Camera3D.new()
	camera.fov = 60
	viewport.add_child(camera)
	var menu := Menu.new()
	menu.state_provider = func(): return state
	camera.add_child(menu)
	menu.position.y = -0.45
	menu.toggle()
	for shot in [{"name": "settings_off"}, {"name": "settings_on", "picture_quality": true, "grade_curves_locked": false, "picture_sharpness": 150.0, "picture_upscale": 1, "picture_denoise": 2, "reuse_last_picture": true, "picture_clear_available": true, "picture_source": "file", "capture": {"available": true}, "disc_menu_available": true},
			{"name": "settings_blocked", "picture_quality_available": false, "picture_quality_blocker": "alpha", "grade_curves_locked": false},
			{"name": "settings_folds_open", "picture_quality": true, "grade_curves_locked": false, "depth_open": true, "alpha_open": true},
			{"name": "grade_locked", "page": 0, "picture_quality_available": true}, {"name": "grade_locked_rgb", "page": 2},
			{"name": "grade_unlocked", "page": 0, "picture_quality": true, "grade_curves_locked": false}]:
		state.merge({"picture_quality": false, "picture_quality_available": true, "grade_curves_locked": true, "picture_quality_blocker": "", "reuse_last_picture": false, "picture_clear_available": false, "picture_source": "last", "capture": {}, "disc_menu_available": false}, true)
		state.merge(shot, true)
		menu.section = 1 if shot.has("depth_open") else 0
		menu._adjustment = "" if shot.has("depth_open") else "picture"
		menu._picture_tab = 1 if shot.has("page") else 0
		menu._picture_advanced = shot.has("page")
		menu._grade_page = int(shot.get("page", 0))
		menu._depth_expanded = shot.get("depth_open", false)
		menu._alpha_expanded = shot.get("alpha_open", false)
		menu.position.y = -0.52 if not shot.has("depth_open") else -0.78
		menu.set_layout_viewer(camera.global_transform)
		menu.refresh()
		if shot.name == "settings_off":
			# The switch's tooltip, as a ray would raise it.
			for button in menu._buttons:
				if menu._tips.get(button.target, "").begins_with(I18n_hint()):
					var centre: Vector2 = button.rect.get_center()
					menu.update_pointer("left_hand", menu.to_global(Vector3(centre.x, centre.y, 0.1)), -menu.global_basis.z, false)
		for frame in 40: await process_frame
		await RenderingServer.frame_post_draw
		await RenderingServer.frame_post_draw
		viewport.get_texture().get_image().save_png(output.path_join("picture_quality_%s.png" % shot.name))
	quit(0)

func I18n_hint() -> String:
	return preload("res://scripts/i18n.gd").t(Menu.PICTURE_QUALITY_HINT).left(12)
