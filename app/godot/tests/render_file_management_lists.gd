extends SceneTree
const Menu := preload("res://scripts/library_menu.gd")
const Actions := preload("res://scripts/library_file_actions.gd")
var checks := 0
var failures: Array[String] = []
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)
func _initialize() -> void: call_deferred("_run")
func _run() -> void:
	var output := OS.get_environment("FILE_MANAGEMENT_PREVIEW_DIR")
	if output.is_empty(): quit(1); return
	DirAccess.make_dir_recursive_absolute(output)
	var viewport := SubViewport.new(); viewport.size = Vector2i(1600, 1100); viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS; root.add_child(viewport)
	var camera := Camera3D.new(); camera.fov = 70; viewport.add_child(camera)
	var platform := preload("res://tests/test_library_file_actions.gd").Platform.new()
	var menu := Menu.new(); camera.add_child(menu); menu.attach_platform(platform); menu.set_process(false)
	var normal_only := OS.get_environment("FILE_MANAGEMENT_NORMAL_ONLY") == "1"
	for language in ["en", "zh", "zh_Hant", "ja"]:
		menu.I18n.use(language)
		for view in ["off", "grid_off", "off_hint", "grid_off_hint", "list", "single", "multi", "grid_edit", "grid_multi", "compact_off", "compact_grid_off", "compact_off_hint", "compact_grid_off_hint", "compact", "compact_selected", "compact_confirm", "rename", "rename_preview", "folder_rename", "settings", "settings_hint", "settings_entry"]:
			if normal_only and view not in ["off", "compact_off"]: continue
			var locked: bool = view.contains("off") or view == "settings_entry"
			menu.file_actions.settings_return.clear(); menu.file_actions.reset(); menu.file_actions.set_enabled(not locked)
			menu.compact = view.begins_with("compact"); menu.section = Menu.Section.LOCAL; menu.view_mode = "grid" if view.contains("grid") else "list"
			menu._local_all_files = true; menu._cloud_stack.clear(); menu._cloud_busy = false
			menu._local_stack = [{"id":"/disk", "title":"Movies"}]
			menu._local_entries = []
			for i in (1500 if view.begins_with("grid_") else 8):
				menu._local_entries.append({"title":"旅行 %02d - A long video title.mp4" % i, "uri":"file:///disk/%02d.mp4" % i,
					"size":104857600, "modified":100, "kind":"video", "can_delete":i != 7, "can_rename":i != 7})
			menu.current_file_provider = func(): return "file:///disk/00.mp4"
			menu.visible = true; menu.scroll = 0; menu.refresh()
			if view in ["grid_edit", "grid_multi"]:
				menu._activate(Actions.EDIT_MODE); menu._set_scroll(250)
				if view == "grid_multi": menu.file_actions.toggle(menu.rows[1000]); menu.file_actions.toggle(menu.rows[1001])
			if view in ["single", "multi", "compact_selected", "compact_confirm"]:
				menu.file_actions.toggle(menu.rows[0])
				if view == "multi": menu.file_actions.toggle(menu.rows[1])
			if view == "compact_confirm": menu._activate(Actions.DELETE_FILE)
			if view in ["rename", "rename_preview"]:
				menu.file_actions.rename.open(menu.rows[0])
				if view == "rename_preview":
					menu.file_actions.rename.phase = "preview"
					menu.file_actions.rename.moves = [{"from":"旅行.mp4", "to":"旅行2026.mp4"}, {"from":"旅行.srt", "to":"旅行2026.srt"}, {"from":"旅行.jpg", "to":"旅行2026.jpg"}, {"from":"旅行.nfo", "to":"旅行2026.nfo"}]
			if view == "folder_rename":
				menu.section = Menu.Section.CLOUD; menu._cloud_stack = [{"id":"/account", "title":"115"}]
				menu.file_actions.rename.open({"title":"旅行.2026", "uri":"cloud://account/folder", "folder":true, "can_rename":true})
			if view.begins_with("settings"): menu.section = Menu.Section.SETTINGS; menu.tab = Menu.GENERAL_TAB; menu.refresh()
			if view == "settings_entry":
				menu.section = Menu.Section.LOCAL; menu.refresh(); menu._activate(Actions.EDIT_MODE)
			menu._draw()
			if view.ends_with("off_hint"):
				for item in menu._buttons:
					if item.target == Actions.EDIT_MODE:
						menu.update_pointer("right_hand", item.node.to_global(Vector3(0, 0, 0.3)), -item.node.global_basis.z, true); break
			if view == "settings_hint":
				var hint := menu.I18n.t("Delete or rename files in supported library sections. Managing files is easier in list view. Available actions depend on the source and permissions.")
				for id in menu._tips:
					if menu._tips[id] == hint:
						menu._hover["left_hand"] = id; menu._update_tooltip(); break
			await process_frame; await RenderingServer.frame_post_draw; await RenderingServer.frame_post_draw
			var label: String = language + "-" + view
			var boxes := 0
			for item in menu._buttons:
				if normal_only: break
				if not item.node.visible or not menu.file_actions.selection_target(item.target): continue
				boxes += 1
				for body in menu._buttons:
					if body.node.visible and menu._row_target(body.target): check(not item.rect.intersects(body.rect), label + " checkbox does not overlap a row")
			if view.contains("off"):
				check(boxes == 0, label + " locked view has no selection checkboxes")
				check(menu._buttons.any(func(item): return item.target == Actions.EDIT_MODE), label + " locked entry is visible")
			if view.ends_with("off_hint"):
				check(menu._tooltip != null and menu._tooltip.visible and menu._tooltip.get_child(0).text.contains(menu.I18n.t("Allow file management")), label + " ray shows enabling path")
				check(menu._tooltip.mesh.size.x <= 0.91, label + " entry tooltip wraps within the panel")
			if view == "settings_entry": check(menu._buttons.any(func(item): return item.target == Menu.BACK), label + " shortcut includes a return button")
			if view in ["list", "compact"]: check(boxes > 0, label + " opt-in has visible checkboxes")
			if view in ["grid_edit", "grid_multi"]:
				check(menu.file_actions.editing and menu.scroll == 250, label + " large grid stays at its editing position")
				check(menu.file_actions.selected_rows().size() == (2 if view == "grid_multi" else 0), label + " grid selection matches checkmarks")
			if view == "compact_selected": check(menu._lines() == 4, label + " footer reserves its own space")
			if view == "compact_confirm": check(menu.text_snapshot().contains(menu.I18n.t("Playback will stop before deletion")), label + " current playback deletion is explicit")
			if view == "settings_hint":
				check(menu._tooltip != null and menu._tooltip.visible, label + " toggle tooltip is visible")
				check(menu._tooltip.mesh.size.x <= 0.91, label + " tooltip wraps within the menu")
			if view == "rename":
				check(not menu.file_actions.rename.selected_all, label + " keeps input text")
				check(menu.text_snapshot().contains(".mp4"), label + " read-only extension is visible")
			for node in menu.find_children("*", "Label3D", true, false):
				if node.text == menu.I18n.t("Also rename files with the same basename"):
					check(node.get_aabb().size.x <= 1.12, label + " companion option fits its button")
			var image := viewport.get_texture().get_image()
			check(image.save_png(output.path_join(label + ".png")) == OK, label + " saves pixels")
	menu.queue_free(); viewport.queue_free(); await process_frame; platform.free()
	print("File management rendering: %d checks, %d failures" % [checks, failures.size()])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)
