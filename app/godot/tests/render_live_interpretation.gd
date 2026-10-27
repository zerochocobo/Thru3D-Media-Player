extends SceneTree
const Menu := preload("res://scripts/player_menu.gd")
const I18n := preload("res://scripts/i18n.gd")
var failures := []
var checks := 0
func _initialize() -> void: run.call_deferred()
func run() -> void:
	var output := ProjectSettings.globalize_path("res://../../build/output/live-interpretation/ui")
	DirAccess.make_dir_recursive_absolute(output)
	var viewport := SubViewport.new(); viewport.size = Vector2i(1280, 1280); viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS; root.add_child(viewport)
	var camera := Camera3D.new(); camera.fov = 70; camera.position.y = .3; viewport.add_child(camera)
	var state := {"has_video": true, "title": "Video", "duration_ms": 240000, "position_ms": 10000,
		"source_uri": "file:///fixture.mp4", "subtitle_options": [], "subtitle_track": 0,
		"listening_available": true, "listening_enabled": true, "listening_source": "ja", "listening_target": "zh-Hans",
		"listening_lead": 12, "listening_state": "preparing", "subtitle_files_state": "ready"}
	var menu := Menu.new(); menu.state_provider = func(): return state
	camera.add_child(menu); menu.position.y = -.35; menu.toggle(); menu.set_process(false)
	for locale in ["zh", "zh_Hant", "en", "ja"]:
		I18n.use(locale)
		for mode in ["bilingual", "original", "off", "appearance", "embedded-off", "embedded-on", "pgs", "sidecars", "sidecars-open"]:
			state.listening_enabled = mode not in ["off", "embedded-off"]; state.listening_target = "" if mode == "original" else "zh-Hans"
			state.subtitle_options = [{"id": 1, "title": "English", "codec": "hdmv_pgs_subtitle" if mode == "pgs" else "subrip"}] if mode in ["embedded-off", "embedded-on", "pgs"] else []
			state.subtitle_track = 0 if state.subtitle_options.is_empty() else 1
			state.subtitle_files_available = mode in ["sidecars", "sidecars-open"]
			state.subtitle_files = ["movie.en.srt", "movie.ja.ass"] if state.subtitle_files_available else []
			menu._subtitle_files_open = mode == "sidecars-open"
			menu._subtitle_open = true; menu._subtitle_appearance_open = mode == "appearance"; menu.refresh()
			await process_frame; await RenderingServer.frame_post_draw; await RenderingServer.frame_post_draw
			if viewport.get_texture().get_image().save_png(output.path_join(locale + "-" + mode + ".png")) != OK: failures.append("save")
			for button in menu._buttons:
				if not menu.choices.targets.has(button.target): continue
				var label: Label3D = button.node.get_child(0)
				var width: float = menu.FONT.get_string_size(label.text, HORIZONTAL_ALIGNMENT_LEFT, -1, label.font_size).x * label.pixel_size
				checks += 1
				if width > button.rect.size.x: failures.append("Overflow " + locale + " " + label.text)
			checks += 1
			if menu.allows_playback_sticks(): failures.append("Popup allowed playback shortcut")
	menu.free(); viewport.free()
	print("Listening render: %d checks, %d failures" % [checks, failures.size()])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)
