extends SceneTree
const Menu := preload("res://scripts/library_menu.gd")
const Info := preload("res://scripts/library_presentation.gd")
var checks := 0
var failures: Array[String] = []
class Catalog extends RefCounted:
	var entries := {}
	func lookup(uri: String) -> Dictionary: return entries.get(uri, {})
	func list_recent() -> Array[Dictionary]:
		var result: Array[Dictionary] = []; result.assign(entries.values()); return result
func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok: failures.append(label)
func texts(menu: Node) -> Array[String]:
	var result: Array[String] = []
	for button in menu._buttons:
		if not menu._row_target(button.target): continue
		for child in button.node.get_children():
			if child is Label3D: result.append(child.text)
	return result
func _initialize() -> void: call_deferred("run")
func run() -> void:
	preload("res://scripts/i18n.gd").use("en")
	var catalog := Catalog.new()
	var raw := {"id": "/Movies/Film.mkv", "title": "Film.mkv", "uri": "smb://nas/Movies/Film.mkv", "size": 12884901888, "modified": 1791820800000, "duration_ms": 180000}
	catalog.entries[raw.uri] = {"uri": raw.uri, "title": raw.title, "position_ms": 90000, "duration_ms": 180000}
	var info := Info.info(raw, catalog)
	check(info.badge == "12.0 GB · 1:30", "Played badge keeps capacity and position together")
	check(info.status == "1:30 / 3:00" and is_equal_approx(info.ratio, 0.5), "Capacity does not change resume state")
	catalog.entries[raw.uri].position_ms = 0
	check(Info.info(raw, catalog).badge == "12.0 GB", "Zero progress keeps size")
	catalog.entries[raw.uri].position_ms = 90000
	check(Info.info({"title": "Unknown", "uri": raw.uri}, catalog).badge == "1:30", "No size is invented for old history")
	check(Info.info(raw, null).badge == "12.0 GB", "Unplayed badge still shows capacity")
	check(Info.info(raw.merged({"kind": "image"}), catalog).badge == "12.0 GB", "Photos never get video positions")
	var scene := {"title": "Film", "scene": raw.merged({"year": 2024, "has_cover": false})}
	info = Info.info(scene, catalog)
	check(info.card_detail == "2024 · 3:00 · 12.0 GB · 1:30", "Server cards retain all known metadata after playback")
	var output := OS.get_environment("QUEST_LIBRARY_METADATA_PREVIEW_DIR")
	if not output.is_empty(): DirAccess.make_dir_recursive_absolute(output)
	var viewport := SubViewport.new(); viewport.size = Vector2i(1400, 900); viewport.own_world_3d = true; viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS; root.add_child(viewport)
	var camera := Camera3D.new(); camera.fov = 60; viewport.add_child(camera)
	var menu := Menu.new(); menu.catalog = catalog; camera.add_child(menu); menu.visible = true; menu.load_view_mode("grid")
	menu._local_stack = [{"id": "/Movies", "title": "Movies"}]; menu._local_entries = [raw]
	menu._smb_server = "nas"; menu._smb_path = "Movies"; menu._smb_entries = [raw]
	menu._dlna_server = "dlna"; menu._dlna_stack = [{"id": "0", "title": "Movies"}]; menu._dlna_entries = [raw]
	menu._cloud_stack = [{"id": "/mount1", "title": "Drive"}]; menu._cloud_entries = [raw]
	for section in [Menu.Section.LOCAL, Menu.Section.SMB, Menu.Section.DLNA, Menu.Section.CLOUD]:
		menu.section = section
		var file: Dictionary = raw.duplicate(true)
		file.uri = {Menu.Section.LOCAL: "file:///Movies/Film.mkv", Menu.Section.SMB: raw.uri, Menu.Section.DLNA: "http://example.invalid/Film.mkv", Menu.Section.CLOUD: "cloud://mount1/Film.mkv"}[section]
		catalog.entries[file.uri] = {"uri": file.uri, "title": file.title, "position_ms": 90000, "duration_ms": 180000}
		menu._local_entries = [file]; menu._smb_entries = [file]; menu._dlna_entries = [file]; menu._cloud_entries = [file]
		for compact in [false, true]:
			menu.set_compact(compact); menu.refresh()
			check(texts(menu).any(func(value): return value.contains("12.0 GB") and value.contains("1:30")), "Actual grid label has size and position: %s/%s" % [section, compact])
			if not output.is_empty():
				await process_frame; await RenderingServer.frame_post_draw; await RenderingServer.frame_post_draw
				viewport.get_texture().get_image().save_png(output.path_join("files-%d-%s.png" % [section, "compact" if compact else "full"]))
		menu.set_compact(false); menu.load_view_mode("list"); menu.refresh()
		check(texts(menu).any(func(value): return value.contains("12.0 GB")), "List retains existing size: " + str(section))
		menu.load_view_mode("grid")
	menu.section = Menu.Section.MEDIA_SERVER; var browser: RefCounted = menu.server_browser
	browser.server = {"id": "demo", "name": "Cinema"}; browser.view = "scenes"; browser.end_reached = true; browser.total = 1
	browser.capabilities = {"artwork": true, "navigation": [], "filters": [], "sorts": ["title"], "search": false}
	browser.entries = [raw.merged({"year": 2024, "has_cover": false})]
	for mode in ["poster", "thumb"]:
		browser.display_preferences.demo = {"mode": mode, "size": 1}; menu.refresh()
		check(texts(menu).any(func(value): return value.begins_with("2024 · 3:00")), "Played server card keeps year and duration: " + mode)
		if not output.is_empty():
			await process_frame; await RenderingServer.frame_post_draw; await RenderingServer.frame_post_draw
			viewport.get_texture().get_image().save_png(output.path_join("server-" + mode + ".png"))
	menu.queue_free(); viewport.queue_free(); await process_frame
	print("Library metadata checks=%d failures=%d" % [checks, failures.size()])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)
