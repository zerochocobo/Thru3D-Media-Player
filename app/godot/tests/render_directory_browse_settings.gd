extends SceneTree
const Menu := preload("res://scripts/library_menu.gd")
func _initialize() -> void: call_deferred("run")
func run() -> void:
	var output := ProjectSettings.globalize_path("res://../../build/output/directory-resume/previews").simplify_path()
	DirAccess.make_dir_recursive_absolute(output)
	var viewport := SubViewport.new()
	viewport.size = Vector2i(1400, 900); viewport.own_world_3d = true; viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var camera := Camera3D.new(); camera.fov = 60; viewport.add_child(camera)
	var menu := Menu.new(); camera.add_child(menu); menu.set_process(false); menu.visible = true
	menu.section = Menu.Section.SETTINGS; menu.tab = Menu.GENERAL_TAB
	for language in ["zh", "en"]:
		menu.I18n.use(language)
		for enabled in [true, false]:
			menu.restore_directory_position = enabled; menu.refresh()
			var rows: Array = menu.rows.filter(func(row): return row.get("key") == "library_restore_position")
			if rows.size() != 1: push_error("Missing directory position setting"); quit(1); return
			var row_index: int = menu.rows.find(rows[0]); menu._set_scroll(maxi(0, row_index - 3))
			var target := -1
			for button in menu._buttons:
				if menu._tips.get(button.target, "") == menu.I18n.t(Menu.BROWSE_POSITION_HINT): target = int(button.target); break
			if target < 0: push_error("Missing directory position tooltip"); quit(1); return
			menu._hover = {"right_hand":target}; menu._update_tooltip()
			if not menu._tooltip.visible: push_error("Directory position tooltip is hidden"); quit(1); return
			await process_frame; await RenderingServer.frame_post_draw; await RenderingServer.frame_post_draw
			viewport.get_texture().get_image().save_png(output.path_join("%s-%s.png" % [language, "on" if enabled else "off"]))
	menu.visible = false; viewport.queue_free(); await process_frame
	print("Directory browse settings render: 4 frames")
	quit(0)
