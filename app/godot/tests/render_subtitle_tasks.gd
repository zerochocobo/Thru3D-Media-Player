extends SceneTree
const Library := preload("res://scripts/library_menu.gd")
const Player := preload("res://scripts/player_menu.gd")
const I18n := preload("res://scripts/i18n.gd")
func _initialize() -> void: run.call_deferred()
func run() -> void:
	var output := ProjectSettings.globalize_path("res://../../build/output/subtitle-tasks/previews").simplify_path()
	DirAccess.make_dir_recursive_absolute(output)
	var viewport := SubViewport.new(); viewport.size = Vector2i(1600, 1050); viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS; root.add_child(viewport)
	var camera := Camera3D.new(); camera.fov = 60; viewport.add_child(camera)
	var queue := {"paused": false, "jobs": []}
	for i in 9:
		queue.jobs.append({"id": str(i), "title": ["日本語映画", "Local film", "日本語映画 · 第二部"][i%3], "language": "ja", "target": "zh-Hans", "state": ["listening", "paused", "translating"][i%3], "progress": 48, "translated": 80, "total": 150, "speed": 8.1, "persistent": true})
	var defaults := {"subtitle_tasks": queue, "listening_source": "ja", "listening_target": "zh-Hans", "subtitle_task_mode": "translated", "subtitle_task_policy": "playback"}
	var menu := Library.new(); camera.add_child(menu); menu.set_process(false); menu.visible = true
	menu.section = menu.Section.SETTINGS; menu.tab = menu.VIDEO_TAB; menu.settings_provider = func(): return {"subtitle_defaults": defaults}
	for language in ["zh", "en", "ja", "zh_Hant"]:
		I18n.use(language); menu.subtitle_queue_open = false; menu._video_settings_expanded["subtitles"] = true; menu.scroll = 0; menu.refresh()
		await shot(viewport, output.path_join(language + "-defaults.png"))
		menu.subtitle_queue_open = true; menu.scroll = 0; menu.refresh()
		await shot(viewport, output.path_join(language + "-queue.png"))
	menu.free()
	var player := Player.new(); viewport.add_child(player); player.position = Vector3(0, -0.48, -1.85); player.set_process(false)
	var state := {"has_video": true, "title": "Film", "duration_ms": 600000, "subtitle_options": [], "subtitle_track": 0, "listening_available": true, "listening_enabled": true,
		"listening_source": "ja", "listening_target": "zh-Hans", "subtitle_task_mode": "translated", "subtitle_task_supported": true}
	player.state_provider = func(): return state
	player.toggle(); player._subtitle_open = true
	for language in ["zh", "en", "ja", "zh_Hant"]:
		I18n.use(language)
		for kind in ["start", "progress", "complete"]:
			state.subtitle_task = queue.jobs[0] if kind == "progress" else {}
			state.listening_cache_complete = kind == "complete"; state.listening_translation_complete = kind == "complete"; state.listening_cache_persistent = true
			player.refresh(); await shot(viewport, output.path_join(language + "-" + kind + ".png"))
	player.free(); viewport.queue_free(); await process_frame
	print("Subtitle task previews: 20 frames")
	quit(0)
func shot(viewport: SubViewport, path: String) -> void:
	await process_frame; await RenderingServer.frame_post_draw; await RenderingServer.frame_post_draw
	viewport.get_texture().get_image().save_png(path)
