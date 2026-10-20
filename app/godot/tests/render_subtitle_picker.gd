extends SceneTree
const Menu := preload("res://scripts/player_menu.gd")
const Library := preload("res://scripts/library_menu.gd")
const Test := preload("res://tests/test_subtitle_picker.gd")
const I18n := preload("res://scripts/i18n.gd")
var failures: Array[String] = []
var checks := 0

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok: failures.append(label)

func panel_height(menu: Node) -> float:
	for decoration in menu._decorations:
		if decoration is MeshInstance3D and decoration.mesh is QuadMesh and is_equal_approx(decoration.mesh.size.x, 1.10) and decoration.mesh.size.y > 0.15:
			return decoration.mesh.size.y
	return -1

func save(viewport: SubViewport, path: String) -> void:
	await process_frame; await RenderingServer.frame_post_draw; await RenderingServer.frame_post_draw
	check(viewport.get_texture().get_image().save_png(path) == OK, "Save preview")

func _initialize() -> void: call_deferred("run")

func run() -> void:
	var output := ProjectSettings.globalize_path("res://../../build/output/subtitle-recovery/previews")
	DirAccess.make_dir_recursive_absolute(output)
	var viewport := SubViewport.new(); viewport.size = Vector2i(2000, 1400); viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS; root.add_child(viewport)
	var camera := Camera3D.new(); camera.fov = 70; camera.position.y = 0.30; viewport.add_child(camera)
	var state := {"has_video": true, "title": "Film", "source_uri": "medialib://saved/scene/7", "duration_ms": 240000, "position_ms": 40000, "subtitle_options": [], "subtitle_track": 0, "subtitle_browse_available": true}
	var menu := Menu.new(); menu.state_provider = func(): return state
	camera.add_child(menu); menu.position.y = -0.35; menu.toggle(); menu.set_process(false); menu._subtitle_open = true
	var host := Test.Host.new()
	var browser := Library.new(); browser.platform = host; camera.add_child(browser); browser.set_process(false); browser.visible = false
	for language in ["zh", "zh_Hant", "ja", "en"]:
		I18n.use(language); menu.visible = true; browser.visible = false
		state.subtitle_options = []; state.subtitle_track = 0; state.subtitle_browse_available = false
		menu.refresh(); var before := panel_height(menu)
		state.subtitle_browse_available = true; menu.refresh()
		check(is_equal_approx(before, panel_height(menu)) and before > 0, "Folder icon adds no panel height: " + language)
		var buttons: Array = menu._buttons.filter(func(button): return button.target in [Menu.SUBTITLE_AUTO, Menu.SUBTITLE_BROWSE, Menu.SUBTITLE_CLOSE])
		check(buttons.size() == 3, "Auto, folder and close share the title row")
		for button in buttons:
			var node: Node3D = button.node
			var origin := node.to_global(Vector3(0, 0, 1))
			check(int(menu.ray_hit(origin, -node.global_basis.z).get("target", -999)) == button.target, "Header pointer target is unobstructed")
		check(not menu.allows_playback_sticks(), "Subtitle menu reserves sticks for list scrolling")
		await save(viewport, output.path_join(language + "-no-subtitles.png"))
		state.subtitle_options = [{"id": 1, "title": "Film.zh-Hans.srt", "codec": "subrip"}, {"id": 2, "title": "Film.en.ass", "codec": "ass"}]
		state.subtitle_track = 1; menu.refresh()
		await save(viewport, output.path_join(language + "-with-subtitles.png"))
		menu.visible = false; browser.visible = true
		browser.begin_subtitle_picker({"source": "local", "local": [{"id": "/storage/emulated/0", "title": "Internal storage"}, {"id": "/storage/emulated/0/Subtitles", "title": "Subtitles"}]})
		var files: Array = [{"id": "/storage/emulated/0/Subtitles/Chinese", "title": "中文", "container": true}]
		for index in 9: files.append({"uri": "file:///storage/emulated/0/Subtitles/Film-%d.srt" % index, "title": "电影字幕 %02d · Film subtitle.srt" % index, "size": 123456})
		Test.reply(browser, host, files)
		check(browser._buttons.filter(func(button): return button.target >= Library.NAV_BASE and button.target < Library.NAV_BASE + Library.NAV.size()).size() == 3, "Picker limits navigation to supported sources")
		check(not browser._buttons.any(func(button): return button.target in [Library.FILTER_BASE, Library.VIEW_GRID, Library.AUDIO_IMPORT_DONE, Library.MUSIC_OPEN]), "Picker omits media filters, grid, import and music actions")
		await save(viewport, output.path_join(language + "-browse-local.png"))
		browser.dismiss(); browser.visible = true
		browser.begin_subtitle_picker({"source": "cloud", "cloud": [{"id": "/saved", "title": "Cloud drive"}, {"id": "/saved/Subtitles", "title": "Subtitles"}]})
		Test.reply(browser, host, files.map(func(row):
			var copy: Dictionary = row.duplicate(true)
			if copy.has("uri"): copy.uri = str(copy.uri).replace("file:///storage/emulated/0", "cloud://saved")
			return copy), {"next_offset": 48, "total": 49, "page_size": 48})
		await save(viewport, output.path_join(language + "-browse-cloud.png"))
		browser.dismiss()
	menu.free(); browser.free(); viewport.queue_free(); await process_frame
	FileAccess.open(output.path_join("verification.json"), FileAccess.WRITE).store_string(JSON.stringify({"checks": checks, "failures": failures, "layouts": 16}, "\t"))
	for failure in failures: push_error(failure)
	print("Subtitle picker render checks=%d failures=%d layouts=16" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
