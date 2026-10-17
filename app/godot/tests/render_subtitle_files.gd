extends SceneTree
const Menu := preload("res://scripts/player_menu.gd")
const I18n := preload("res://scripts/i18n.gd")
var checks := 0
var failures: Array[String] = []
func check(ok: bool, description: String) -> void:
	checks += 1
	if not ok: failures.append(description)
func _initialize() -> void: call_deferred("run")
func run() -> void:
	var output := OS.get_environment("SUBTITLE_FILES_OUTPUT")
	if output.is_empty(): quit(1); return
	DirAccess.make_dir_recursive_absolute(output)
	var viewport := SubViewport.new(); viewport.size = Vector2i(1600, 1100); viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS; root.add_child(viewport)
	var camera := Camera3D.new(); camera.fov = 60; viewport.add_child(camera)
	var menu := Menu.new(); viewport.add_child(menu); menu.set_process(false); menu.position = Vector3(0, -0.52, -1.9)
	var filename := "Movie.2026.Extended.Cut.1080p.BluRay.x264.ReleaseGroup.Simplified.Chinese.ass"
	var state := {"has_video": true, "source_uri": "file:///sample/movie.mp4", "title": "Movie", "duration_ms": 120000,
		"subtitle_track": 1, "subtitle_options": [{"id": 1, "codec": "subrip", "title": "movie.srt", "source_file": "movie.srt"}],
		"subtitle_files_available": true, "subtitle_files_state": "ready", "subtitle_files": ["movie.srt", filename, "Movie.Theatrical.Cut.zh-CN.srt", "Movie.Directors.Cut.en.srt", "Movie.Version.4.ass"]}
	menu.state_provider = func(): return state
	for language in ["zh", "zh_Hant", "en", "ja"]:
		I18n.use(language); menu.dismiss(); menu.toggle(); menu._activate(110)
		menu._activate(Menu.SUBTITLE_FILES)
		check(menu._subtitle_files_open and menu._subtitle_file_ids.size() == 3, "Three bounded candidate rows: " + language)
		var visible_buttons: Array = menu._buttons.filter(func(b): return b.node.is_visible_in_tree() and b.enabled and b.target != menu.NONE)
		for button in visible_buttons:
			var origin: Vector3 = button.node.to_global(Vector3(0, 0, 1))
			check(menu.ray_hit(origin, -menu.global_basis.z).get("target") == button.target, "Visible button receives its own ray: " + language + " " + str(button.target))
			if menu._subtitle_file_ids.has(button.target):
				var label: Label3D = button.node.get_child(0)
				check(label.font.get_string_size(label.text, HORIZONTAL_ALIGNMENT_LEFT, -1, label.font_size).x * label.pixel_size <= 0.80, "Candidate filename fits the tile: " + language)
		await shot(viewport, output.path_join(language + "-list.png"))
		var button: Dictionary = menu._buttons.filter(func(b): return b.target == Menu.SUBTITLE_FILE_ROW)[0]
		menu.update_pointer("right_hand", button.node.to_global(Vector3(0, 0, 1)), -menu.global_basis.z, true)
		check(menu._tooltip.visible and menu._tooltip.get_child(0).text == filename, "Full release name is available on hover: " + language)
		await shot(viewport, output.path_join(language + "-filename.png"))
		menu.update_pointer("right_hand", Vector3.ZERO, Vector3.ZERO, false)
		for status in ["loading", "error", "empty", "busy"]:
			state.subtitle_files_state = status if status in ["loading", "error"] else "ready"
			state.subtitle_file_error = "Subtitle folder access denied" if status == "error" else ""
			state.subtitle_file_loading = filename if status == "busy" else ""
			state.subtitle_files = [] if status == "empty" else [filename, "Other.srt"]
			menu.refresh()
			if status == "busy":
				if not menu._subtitle_files_open: menu._activate(Menu.SUBTITLE_FILES)
				check(menu._subtitle_file_ids.size() == 2 and menu._buttons.filter(func(b): return menu._subtitle_file_ids.has(b.target)).all(func(b): return not b.enabled), "Pending file selection cannot duplicate a load")
			else: check(not menu._buttons.any(func(b): return b.target == Menu.SUBTITLE_FILES), "The disclosure is hidden until other subtitles are confirmed")
			await shot(viewport, output.path_join(language + "-" + status + ".png"))
		state.subtitle_files_state = "ready"; state.subtitle_file_error = ""; state.subtitle_file_loading = ""
		state.subtitle_files = ["movie.srt", filename, "Movie.Theatrical.Cut.zh-CN.srt", "Movie.Directors.Cut.en.srt", "Movie.Version.4.ass"]
	viewport.queue_free(); await process_frame
	FileAccess.open(output.path_join("verification.json"), FileAccess.WRITE).store_string(JSON.stringify({"checks": checks, "failures": failures}, "\t"))
	for failure in failures: push_error(failure)
	print("Subtitle files render checks=%d failures=%d" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
func shot(viewport: SubViewport, path: String) -> void:
	await process_frame; await RenderingServer.frame_post_draw; await RenderingServer.frame_post_draw
	viewport.get_texture().get_image().save_png(path)
