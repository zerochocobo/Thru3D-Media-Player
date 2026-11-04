extends SceneTree
const Player := preload("res://scripts/player_menu.gd")
const Library := preload("res://scripts/library_menu.gd")
const I18n := preload("res://scripts/i18n.gd")
const Listening := preload("res://scripts/live_interpretation.gd")
var failures: Array[String] = []
var checks := 0
func _initialize() -> void: run.call_deferred()
func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok: failures.append(label)
func run() -> void:
	var output := ProjectSettings.globalize_path("res://../../build/output/subtitle-side-panels/previews")
	DirAccess.make_dir_recursive_absolute(output)
	var viewport := SubViewport.new(); viewport.size = Vector2i(1600, 1100); viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS; root.add_child(viewport)
	var camera := Camera3D.new(); camera.fov = 55; camera.position.y = 0.08; viewport.add_child(camera)
	var menu := Player.new(); viewport.add_child(menu); menu.set_process(false)
	var video := preload("res://tests/test_live_interpretation.gd").Video.new()
	var listening := Listening.new(video); listening.enabled = true; listening.source = "ja"; listening.target = "zh-Hans"
	var state := {"has_video": true, "source_uri": "file:///preview.mkv", "title": "Video", "duration_ms": 120000,
		"subtitle_options": [{"id": 1, "title": "中文", "codec": "subrip"}, {"id": 2, "title": "English", "codec": "subrip"}], "subtitle_track": 1,
		"subtitle_files_available": true, "subtitle_files_state": "ready", "subtitle_files": ["movie.ja.srt"],
		"narration_configurable": true, "narration_available": true, "narration_enabled": true, "narration_status": "speaking", "narration_language": "zh", "narration_voice": "Yuewen", "narration_volume": 100, "narration_duck": 75,
		"listening_available": true, "listening_enabled": false, "listening_source": "ja", "listening_target": "zh-Hans", "listening_lead": 12, "subtitle_task_supported": true,
		"subtitle_size": 100.0, "subtitle_style": "white_black", "subtitle_line": 0}
	menu.state_provider = func(): return state
	menu.toggle(); menu.position = Vector3(0, -0.40, -1.85); menu._activate(110)
	for language in ["zh", "zh_Hant", "en", "ja"]:
		I18n.use(language)
		for mode in ["collapsed", "narration", "narration-off", "narration-unavailable", "language", "appearance", "appearance-offset", "appearance-immersive", "appearance-pgs", "appearance-pgs-yellow", "listening", "listening-off", "listening-empty", "listening-original", "listening-translated", "files"]:
			state.subtitle_options[0].codec = "hdmv_pgs_subtitle" if mode.begins_with("appearance-pgs") else "subrip"
			state.subtitle_pgs_tint = "yellow" if mode == "appearance-pgs-yellow" else "original"
			state.narration_available = not mode.begins_with("appearance-pgs") and mode != "narration-unavailable"
			state.listening_enabled = mode.begins_with("listening") and mode != "listening-off"; state.narration_enabled = state.narration_available and not state.listening_enabled and mode not in ["narration-off", "listening-off"]
			state.subtitle_delay = 1.5 if mode == "appearance-offset" else 0.0
			state.geometry = 1 if mode == "appearance-immersive" else 0
			listening.report = {"state": "ready", "epoch": 1, "ahead": 12.0, "position": 10.0, "cues": []}
			listening.translator.cache.clear()
			if mode in ["listening-original", "listening-translated"]:
				listening.report.cues = [{"start": 9.0, "end": 12.0, "text": "こんにちは"}]
				if mode == "listening-translated": listening.translator.cache[Listening.Protocol.cache_key("こんにちは", "ja", "zh-Hans")] = {"text": "你好"}
			listening.status_caption(10.0); listening._empty_caption_since = Time.get_ticks_msec() - 4001
			state.listening_state = "ready"; state.listening_caption = ""
			state.listening_status_caption = listening.status_caption(10.0)
			state.listening_detail_caption = listening.detail_caption(10.0)
			menu._subtitle_files_open = mode == "files"
			menu._set_subtitle_detail("" if mode in ["collapsed", "files"] else ("narration" if mode == "language" or mode.begins_with("narration") else ("appearance" if mode.begins_with("appearance") else "listening"))); menu.refresh()
			if mode == "language": menu.choices.opened = "narration_language"; menu.refresh()
			for entry in menu._buttons:
				if not entry.node.is_visible_in_tree(): continue
				var text: Label3D = entry.node.get_child(0)
				check(menu.text_width(text.text, text.font_size / menu.TEXT_RASTER_SCALE) <= entry.rect.size.x + 0.01, "Button text fits " + language + " / " + text.text)
				if entry.node.position.y > 0.285:
					check(entry.rect.position.x >= menu._subtitle_panel_bounds.position.x - 0.001 and entry.rect.end.x <= menu._subtitle_panel_bounds.end.x + 0.001, "Control fits the original total width " + language + " / " + text.text)
			if not mode.begins_with("appearance-pgs"):
				check(menu._subtitle_status_label != null and is_equal_approx(menu._subtitle_status_label.position.x, menu._subtitle_main_bounds.get_center().x), "Status stays in the original panel " + language)
			await shot(viewport, output.path_join(language + "-" + mode + ".png"))
	listening.translator.close(); video.free(); menu.free()
	var library := Library.new(); viewport.add_child(library); library.set_process(false)
	library.visible = true; library.section = library.Section.SETTINGS; library.tab = library.VIDEO_TAB
	library.position = Vector3(0, 0, -1.75)
	library.settings_provider = func(): return {"voice_manager": {"narration_clone_supported": true}, "subtitle_defaults": {"listening_source": "ja", "listening_target": "zh-Hans"}}
	library._video_settings_expanded["subtitles"] = true
	for language in ["zh", "zh_Hant", "en", "ja"]:
		I18n.use(language)
		for group in ["", "listening", "narration", "appearance"]:
			library._subtitle_settings_expanded = group; library.scroll = 4; library.refresh()
			await shot(viewport, output.path_join(language + "-global-" + ("collapsed" if group.is_empty() else group) + ".png"))
			if group == "appearance":
				library._set_scroll(library._max_scroll())
				await shot(viewport, output.path_join(language + "-global-appearance-bottom.png"))
	library.free(); viewport.queue_free(); await process_frame
	FileAccess.open(output.path_join("verification.json"), FileAccess.WRITE).store_string(JSON.stringify({"checks": checks, "failures": failures}))
	for failure in failures: push_error(failure)
	print("Subtitle side panel render: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
func shot(viewport: SubViewport, path: String) -> void:
	await process_frame; await RenderingServer.frame_post_draw; await RenderingServer.frame_post_draw
	check(viewport.get_texture().get_image().save_png(path) == OK, "Save " + path.get_file())
