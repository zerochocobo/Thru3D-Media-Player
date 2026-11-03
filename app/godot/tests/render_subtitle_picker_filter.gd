extends SceneTree
const Library := preload("res://scripts/library_menu.gd")
const Fixture := preload("res://tests/test_subtitle_picker_filter.gd")
const Picker := preload("res://tests/test_subtitle_picker.gd")
const I18n := preload("res://scripts/i18n.gd")
var checks := 0
var failures: Array[String] = []

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok: failures.append(label)

func _initialize() -> void: call_deferred("run")

func run() -> void:
	var output := ProjectSettings.globalize_path("res://../../build/output/subtitle-picker-filter-20261103/previews")
	DirAccess.make_dir_recursive_absolute(output)
	var viewport := SubViewport.new(); viewport.size = Vector2i(2000, 1400); viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS; root.add_child(viewport)
	var camera := Camera3D.new(); camera.fov = 70; camera.position.y = 0.30; viewport.add_child(camera)
	var host := Fixture.Host.new()
	var browser := Library.new(); browser.platform = host; camera.add_child(browser); browser.set_process(false)
	for language in ["zh", "zh_Hant", "ja", "en"]:
		I18n.use(language)
		for mode in ["local", "empty", "cloud"]:
			browser.visible = true
			var location := {"source": "local", "local": [{"id": "/storage/emulated/0/Subtitles", "title": "Subtitles"}]}
			if mode == "cloud": location = {"source": "cloud", "cloud": [{"id": "/saved", "title": "Cloud"}, {"id": "/saved/Subtitles", "title": "Subtitles"}]}
			browser.begin_subtitle_picker(location, "Spider.Man.2026.1080p.MKV")
			var files: Array = [{"id": "/storage/emulated/0/Subtitles/Languages", "title": "Languages", "container": true}]
			for index in 9:
				files.append({"uri": "file:///storage/emulated/0/Subtitles/Spider.Man.%d.srt" % index, "title": "Spider.Man.2026.1080p.%02d.zh-Hans.srt" % index})
			Picker.reply(browser, host, files, {"next_offset": 48 if mode == "cloud" else -1, "total": 96 if mode == "cloud" else 10, "raw_count": 48 if mode == "cloud" else 10})
			browser._activate(browser.SubtitleFilter.OPEN)
			if mode == "empty": browser.subtitle_filter.apply("No matching film")
			await process_frame; await process_frame
			if mode == "cloud":
				Fixture.search_reply(browser, host, [{"title": "Spider.Man.2026.1080p.zh-Hans.ass", "kind": "subtitle", "container": false, "relative_path": "/Subtitles/Spider.Man.2026.1080p.zh-Hans.ass", "search_token": "preview:1"}], "preview:2")
			check(not browser.system_text_input.active(), "Prefilled filter does not open the keyboard")
			var inputs: Array = browser._buttons.filter(func(button): return button.target == browser.SubtitleFilter.INPUT)
			check(inputs.size() == 1 and browser._lines() == 6, "One compact input and six rows")
			for target in [browser.SubtitleFilter.OPEN, browser.SubtitleFilter.INPUT, browser.SubtitleFilter.CLEAR, Library.REFRESH]:
				var buttons: Array = browser._buttons.filter(func(button): return button.target == target)
				check(buttons.size() == 1, "Unique toolbar/input button")
				if buttons.size() == 1:
					var node: Node3D = buttons[0].node
					check(int(browser.ray_hit(node.to_global(Vector3(0, 0, 1)), -node.global_basis.z).get("target", -1)) == target, "Unobstructed pointer target")
			await process_frame; await RenderingServer.frame_post_draw; await RenderingServer.frame_post_draw
			check(viewport.get_texture().get_image().save_png(output.path_join(language + "-" + mode + ".png")) == OK, "Save preview")
			browser.dismiss()
	browser.free(); viewport.queue_free(); await process_frame
	FileAccess.open(output.path_join("verification.json"), FileAccess.WRITE).store_string(JSON.stringify({"checks": checks, "failures": failures, "layouts": 12}, "\t"))
	for failure in failures: push_error(failure)
	print("Subtitle picker filter render checks=%d failures=%d layouts=12" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
