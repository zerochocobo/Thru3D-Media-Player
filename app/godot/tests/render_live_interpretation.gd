extends SceneTree
const Menu := preload("res://scripts/player_menu.gd")
const I18n := preload("res://scripts/i18n.gd")
const CastCapabilities := preload("res://scripts/cast_capabilities.gd")
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
	var baseline := state.duplicate(true)
	var menu := Menu.new(); menu.state_provider = func(): return state
	camera.add_child(menu); menu.position.y = -.35; menu.toggle(); menu.set_process(false)
	for locale in ["zh", "zh_Hant", "en", "ja"]:
		I18n.use(locale)
		for mode in ["bilingual", "original", "off", "appearance", "embedded-off", "embedded-on", "pgs", "sidecars", "sidecars-open", "cast-on", "cast-off", "cast-failure", "cast-pgs", "cast-unseekable", "cast-waiting"]:
			state.clear(); state.merge(baseline.duplicate(true))
			var cast: bool = str(mode).begins_with("cast-")
			var unavailable: bool = mode in ["cast-unseekable", "cast-waiting"]
			state.listening_enabled = mode not in ["off", "embedded-off", "cast-off", "cast-failure", "cast-unseekable", "cast-waiting"]; state.listening_target = "" if mode == "original" else "zh-Hans"
			state.listening_visible = true; state.listening_available = not unavailable
			state.listening_unavailable_hint = ("Audio track unavailable" if mode == "cast-waiting" else "Available for seekable videos") if unavailable else ""
			state.cast = {"seek": mode != "cast-unseekable", "audio": mode != "cast-waiting"} if cast else {}
			state.source_uri = "http://192.0.2.1/film.mp4" if cast else "file:///fixture.mp4"
			state.listening_notice = I18n.t("Unable to open the audio track") if mode == "cast-failure" else ""
			state.listening_state = "audio_error" if mode == "cast-failure" else "preparing"
			state.subtitle_task_supported = not cast
			state.subtitle_options = [{"id": 1, "title": "English", "codec": "hdmv_pgs_subtitle" if mode in ["pgs", "cast-pgs"] else "subrip"}] if mode in ["embedded-off", "embedded-on", "pgs", "cast-failure", "cast-pgs"] else []
			state.subtitle_track = 0 if state.subtitle_options.is_empty() else 1
			state.subtitle_files_available = mode in ["sidecars", "sidecars-open"]
			state.subtitle_files = ["movie.en.srt", "movie.ja.ass"] if state.subtitle_files_available else []
			if cast: CastCapabilities.apply(state, state.cast)
			menu.refresh() # A source change closes popups before the user opens this one.
			menu._subtitle_files_open = mode == "sidecars-open"
			menu._subtitle_open = true; menu._set_subtitle_detail("appearance" if mode == "appearance" else "listening"); menu.refresh()
			await process_frame; await RenderingServer.frame_post_draw; await RenderingServer.frame_post_draw
			if viewport.get_texture().get_image().save_png(output.path_join(locale + "-" + mode + ".png")) != OK: failures.append("save")
			for button in menu._buttons:
				if not menu.choices.targets.has(button.target): continue
				var label: Label3D = button.node.get_child(0)
				var width: float = menu.FONT.get_string_size(label.text, HORIZONTAL_ALIGNMENT_LEFT, -1, label.font_size).x * label.pixel_size
				checks += 1
				if width > button.rect.size.x: failures.append("Overflow " + locale + " " + label.text)
			checks += 1
			if menu.allows_playback_sticks(): failures.append("Popup allowed playback shortcut " + locale + " " + mode)
			if cast:
				checks += 1
				if menu._buttons.any(func(button): return button.target in [menu.SUBTITLE_GENERATE, menu.SUBTITLE_TASK_CANCEL]): failures.append("Cast offered whole-film task")
			if mode == "cast-failure":
				checks += 1
				if not is_instance_valid(menu._subtitle_status_label) or menu._subtitle_status_label.text != state.listening_notice: failures.append("Failure notice missing " + locale)
			if unavailable:
				checks += 2
				if not menu._buttons.any(func(button): return button.target == menu.SUBTITLE_LISTENING and button.enabled): failures.append("Configuration entry missing " + locale)
				if not is_instance_valid(menu._subtitle_status_label) or menu._subtitle_status_label.text.is_empty(): failures.append("Unavailable reason missing " + locale)
	menu.free(); viewport.free()
	print("Listening render: %d checks, %d failures" % [checks, failures.size()])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)
