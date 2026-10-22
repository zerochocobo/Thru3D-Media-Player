extends SceneTree
const Menu := preload("res://scripts/library_menu.gd")
const Paging := preload("res://scripts/cloud_pagination.gd")
const I18n := preload("res://scripts/i18n.gd")
class Platform extends Object:
	func media_cloud_page_options(_path: String, _offset: int, _force: bool, _order: String, _folder: String, _size: int, _subtitles: bool) -> int: return 1
func _initialize() -> void: call_deferred("_run")
func _run() -> void:
	var output := ProjectSettings.globalize_path("res://../../build/output/cloud-paging-visuals")
	DirAccess.make_dir_recursive_absolute(output)
	var viewport := SubViewport.new(); viewport.size = Vector2i(1600, 1200)
	viewport.own_world_3d = true; viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS; root.add_child(viewport)
	var camera := Camera3D.new(); camera.fov = 52; viewport.add_child(camera)
	var platform := Platform.new()
	var menu := Menu.new(); camera.add_child(menu); menu.toggle(); menu.platform = platform
	menu.section = Menu.Section.CLOUD; menu._cloud_stack = [{"id": "/account", "provider": "115_open", "title": "115"}]
	menu._cloud_page = 127; menu._cloud_total = 105600; menu._cloud_page_size = 200; menu._cloud_next = 25600
	for i in 30: menu._cloud_entries.append({"title": "Film %03d.mp4" % i, "uri": "cloud://account/%d.mp4" % i, "size": 2147483648})
	for language in ["zh", "en", "ja"]:
		I18n.use(language)
		for view in ["paged", "jump", "warning", "progress", "all", "partial", "settings", "settings-expanded", "settings-dropdown", "compact"]:
			menu.section = Menu.Section.SETTINGS if view.begins_with("settings") else Menu.Section.CLOUD
			menu.tab = Menu.GENERAL_TAB; menu.compact = view == "compact"
			var paging: RefCounted = menu.cloud_pagination
			paging.settings_expanded = view in ["settings-expanded", "settings-dropdown"]
			menu.choices.opened = "cloud_page_size/115_open" if view == "settings-dropdown" else ""
			paging.opened = view in ["jump", "warning", "progress"]
			paging.warning = view == "warning"; paging.task = "all" if view == "progress" else ""
			paging.mode = view if view in ["all", "partial"] else "paged"; paging.input = "128"; paging.raw_count = 5268
			paging.scope = paging._scope(); paging.visible_rows.clear()
			for entry in menu._cloud_entries: paging.visible_rows.append(menu._entry_row(entry))
			paging.row_filter = paging._filter(); menu.refresh()
			await process_frame; await RenderingServer.frame_post_draw; await RenderingServer.frame_post_draw
			viewport.get_texture().get_image().save_png(output.path_join(language + "-" + view + ".png"))
	menu.platform = null; menu.free(); platform.free(); viewport.free()
	print("Cloud paging visual layouts=30")
	quit()
