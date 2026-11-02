extends SceneTree
const Menu := preload("res://scripts/library_menu.gd")
func _initialize() -> void: run.call_deferred()
func run() -> void:
	var output := ProjectSettings.globalize_path("res://../../build/output/filename-passthrough-checks/previews")
	DirAccess.make_dir_recursive_absolute(output)
	var viewport := SubViewport.new()
	viewport.size = Vector2i(1400, 900); viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS; root.add_child(viewport)
	var camera := Camera3D.new(); camera.fov = 60; viewport.add_child(camera)
	var menu := Menu.new(); camera.add_child(menu); menu.set_process(false); menu.visible = true
	menu.section = Menu.Section.SETTINGS; menu.tab = Menu.VIDEO_TAB
	for language in ["zh", "zh_Hant", "en", "ja"]:
		menu.I18n.use(language)
		for enabled in [true, false]:
			menu.settings_provider = func(): return {"alpha_auto_from_filename": enabled}
			menu.refresh()
			var rows: Array = menu.rows.filter(func(row): return row.get("key") == "alpha_auto_from_filename")
			if rows.size() != 1: push_error("Missing auto passthrough setting"); quit(1); return
			var index: int = menu.rows.find(rows[0]); menu._set_scroll(maxi(0, index - 2))
			var target := -1
			for button in menu._buttons:
				if menu._tips.get(button.target, "") == menu.I18n.t(Menu.AUTO_PASSTHROUGH_HINT): target = int(button.target); break
			if target < 0: push_error("Missing auto passthrough tooltip"); quit(1); return
			menu._hover = {"right_hand": target}; menu._update_tooltip()
			if not menu._tooltip.visible: push_error("Auto passthrough tooltip is hidden"); quit(1); return
			await process_frame; await RenderingServer.frame_post_draw; await RenderingServer.frame_post_draw
			viewport.get_texture().get_image().save_png(output.path_join("%s-%s.png" % [language, "on" if enabled else "off"]))
	menu.visible = false; viewport.queue_free(); await process_frame
	print("Filename passthrough render: 8 frames, 0 failures")
	quit(0)
