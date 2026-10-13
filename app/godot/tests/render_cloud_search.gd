extends SceneTree
const Menu := preload("res://scripts/library_menu.gd")
const SearchTest := preload("res://tests/test_cloud_search.gd")
const I18n := preload("res://scripts/i18n.gd")
var checks := 0
var failures: Array[String] = []
func _initialize() -> void: call_deferred("run")
func run() -> void:
	var output := ProjectSettings.globalize_path("res://../../build/output/cloud-search/previews")
	DirAccess.make_dir_recursive_absolute(output)
	var viewport := SubViewport.new(); viewport.size = Vector2i(1600, 1050); viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS; root.add_child(viewport)
	var camera := Camera3D.new(); camera.fov = 60; viewport.add_child(camera)
	var platform := SearchTest.Platform.new(); var menu := Menu.new(); camera.add_child(menu)
	menu.attach_platform(platform); menu.toggle(); menu._activate(Menu.NAV_BASE + Menu.Section.CLOUD)
	platform.browse_reply(1); menu._choose(menu.rows[0]); platform.browse_reply(2)
	for language in ["zh", "en", "zh_Hant", "ja"]:
		I18n.use(language); menu.cloud_search.scopes = ["current", "tree", "all"]; menu.cloud_search.open()
		menu.cloud_search.query = "旅行"; menu.refresh()
		await shot(viewport, menu, output.path_join(language + "-input.png"))
		menu.cloud_search.editing = false
		menu.cloud_search.entries = []
		for index in 20: menu.cloud_search.entries.append(platform.result("fixture:%d" % index, "旅行 %02d _ 中文 long_filename_4K_SBS.mp4" % index))
		menu.cloud_search.page = 1; menu.cloud_search.next_cursor = "fixture:2"; menu.refresh()
		await shot(viewport, menu, output.path_join(language + "-results.png"))
		menu._set_scroll(menu._max_scroll())
		await shot(viewport, menu, output.path_join(language + "-scrolled.png"))
		menu.cloud_search.scopes = ["current"]; menu.cloud_search.scope = "current"; menu.cloud_search.editing = true; menu.refresh()
		await shot(viewport, menu, output.path_join(language + "-current-only.png"))
		menu.cloud_search.close()
	var report := {"checks": checks, "failures": failures, "state": "passed" if failures.is_empty() else "failed", "previews": 16}
	var file := FileAccess.open(output.path_join("verification.json"), FileAccess.WRITE); file.store_string(JSON.stringify(report, "  ")); file.close()
	print("Cloud search render: %d checks, %d failures" % [checks, failures.size()])
	for failure in failures: push_error(failure)
	menu.queue_free(); platform.free(); viewport.queue_free()
	await process_frame; await process_frame
	quit(0 if failures.is_empty() else 1)
func shot(viewport: SubViewport, menu: Node3D, output: String) -> void:
	await process_frame; await RenderingServer.frame_post_draw; await RenderingServer.frame_post_draw
	for button in menu._buttons:
		if not button.node.visible: continue
		for child in button.node.get_children():
			if child is Label3D:
				var width: float = child.font.get_string_size(child.text, HORIZONTAL_ALIGNMENT_LEFT, -1, child.font_size).x * child.pixel_size
				checks += 1
				if width > button.rect.size.x + 0.004: failures.append("Text exceeds target: " + child.text + " / " + output.get_file())
	viewport.get_texture().get_image().save_png(output)
