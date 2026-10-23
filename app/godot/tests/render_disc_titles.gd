extends SceneTree
## Renders the control bar with its Blu-ray title list for visual review.
const Menu := preload("res://scripts/player_menu.gd")
var output := ProjectSettings.globalize_path("res://../../build/output/disc-titles")

func frames() -> void:
	await process_frame; await RenderingServer.frame_post_draw; await RenderingServer.frame_post_draw

func _initialize() -> void: call_deferred("run")

func run() -> void:
	DirAccess.make_dir_recursive_absolute(output)
	var viewport := SubViewport.new(); viewport.size = Vector2i(1400, 1000)
	viewport.own_world_3d = true; viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	viewport.transparent_bg = false; root.add_child(viewport)
	var environment := WorldEnvironment.new(); environment.environment = Environment.new()
	environment.environment.background_mode = Environment.BG_COLOR; environment.environment.background_color = Color(0.32, 0.36, 0.42)
	viewport.add_child(environment)
	var camera := Camera3D.new(); camera.fov = 52; camera.position = Vector3(0, 0.2, 1.45); viewport.add_child(camera)
	var titles := [
		{"playlist": 100, "duration_ms": 5808928, "chapters": 30, "height": 1080, "stereo": false, "audio": 5, "subtitles": 5},
		{"playlist": 201, "duration_ms": 602668, "chapters": 2, "height": 480, "stereo": false, "audio": 5, "subtitles": 5},
		{"playlist": 55, "duration_ms": 340340, "chapters": 35, "height": 2160, "stereo": false, "audio": 1, "subtitles": 0},
		{"playlist": 202, "duration_ms": 290056, "chapters": 2, "height": 480, "stereo": false, "audio": 5, "subtitles": 5},
		{"playlist": 203, "duration_ms": 208241, "chapters": 2, "height": 480, "stereo": true, "audio": 5, "subtitles": 5},
		{"playlist": 32, "duration_ms": 94027, "chapters": 1, "height": 1080, "stereo": false, "audio": 1, "subtitles": 0}]
	var playing := 100
	for language in ["zh", "en"]:
		preload("res://scripts/i18n.gd").use(language)
		var menu := Menu.new()
		menu.state_provider = func(): return {"has_video": true, "title": "绿色食品 Soylent Green (1973).iso", "duration_ms": 5808928, "position_ms": 1234000,
			"playing": true, "source_uri": "cloud://acc/Soylent.iso", "disc_titles": titles, "disc_main": 100, "disc_playlist": playing, "disc_first_view": true, "disc_menu_available": true,
			"capture": {"available": true, "ready": true}}
		viewport.add_child(menu); menu.set_process(false); menu.toggle()
		await frames()
		viewport.get_texture().get_image().save_png(output.path_join("disc-titles-open-%s.png" % language))
		if language == "zh":
			playing = 201
			menu.refresh(); await frames()
			viewport.get_texture().get_image().save_png(output.path_join("disc-titles-extra-zh.png"))
			playing = 100
			menu.queue_free(); await frames()
			# A Java menu keeps its place in the list, greyed.
			menu = Menu.new()
			menu.state_provider = func(): return {"has_video": true, "title": "人鬼情未了 Ghost (1990).iso", "duration_ms": 7597423, "position_ms": 0,
				"playing": true, "source_uri": "cloud://acc/Ghost.iso", "disc_titles": titles.slice(0, 3), "disc_main": 100, "disc_playlist": 100,
				"disc_first_view": true, "disc_menu_unsupported": true, "capture": {"available": true, "ready": true}}
			viewport.add_child(menu); menu.set_process(false); menu.toggle(); await frames()
			viewport.get_texture().get_image().save_png(output.path_join("disc-titles-bdj-zh.png"))
			menu.navigate_back(); menu.refresh(); await frames()
			viewport.get_texture().get_image().save_png(output.path_join("disc-titles-closed-zh.png"))
		menu.queue_free(); await frames()
	print("Disc titles render: passed")
	quit(0)
