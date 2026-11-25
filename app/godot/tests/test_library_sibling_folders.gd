extends SceneTree
const Menu := preload("res://scripts/library_menu.gd")
var checks := 0
var failures: Array[String] = []
class Platform extends RefCounted:
	signal media_list(id: int, payload: String)
	var sequence := 0
	var requested: Array = []
	func reply(data: Dictionary) -> int:
		sequence += 1
		var id := sequence
		(func(): media_list.emit(id, JSON.stringify(data))).call_deferred()
		return id
	func entries(path: String) -> Array:
		var result: Array = []
		for i in (6 if path in ["/disk", "share", "root"] else 2):
			result.append({"id": path + "/folder%d" % i, "title": "Folder %d" % i, "container": true})
		result.append({"id": path + "/clip.mp4", "title": "clip.mp4", "uri": "file://" + path + "/clip.mp4", "kind": "video"})
		return result
	func media_local_browse(path: String) -> int:
		requested.append(path)
		return reply({"state": "ready", "path": path, "entries": entries(path)})
	func media_smb_browse(server: String, path: String) -> int:
		requested.append(path)
		return reply({"state": "ready", "server_id": server, "path": path, "entries": entries(path)})
	func media_dlna_browse(server: String, path: String) -> int:
		requested.append(path)
		return reply({"state": "ready", "server_id": server, "object_id": path, "entries": entries(path)})
func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok: failures.append(label)
func _initialize() -> void: call_deferred("run")
func glyph(menu: Node, target: int) -> Dictionary:
	var found: Array = menu._buttons.filter(func(button): return button.target == target)
	return found[0] if found.size() == 1 else {}
func folders(menu: Node) -> Array:
	return menu.rows.filter(func(row): return row.has("container"))
func run() -> void:
	var platform := Platform.new()
	var menu := Menu.new(); root.add_child(menu); menu.set_process(false); menu.attach_platform(platform); menu.visible = true
	for source in [Menu.Section.LOCAL, Menu.Section.SMB, Menu.Section.DLNA]:
		var name := str(source)
		menu.section = source; menu.scroll = 0.0
		menu._local_stack = [{"id": "/disk", "title": "Disk"}]
		menu._smb_server = "smb-account"; menu._smb_path = "share"
		menu._dlna_server = "dlna-account"; menu._dlna_stack = [{"id": "root", "title": "Root"}]
		if source == Menu.Section.LOCAL: menu._load_section()
		elif source == Menu.Section.SMB: menu._request("smb_browse", platform.media_smb_browse(menu._smb_server, menu._smb_path))
		else: menu._request("dlna_browse", platform.media_dlna_browse(menu._dlna_server, "root"))
		await process_frame; menu.refresh()
		var parent := folders(menu)
		check(parent.size() == 6 and glyph(menu, Menu.SIBLING_NEXT).is_empty(), "No folder switch before entering a folder: " + name)
		menu._choose(parent[0]); await process_frame; menu.refresh()
		check(menu._sibling_index() == 0, "Entered folder is found among its siblings: " + name)
		var depth: int = menu._crumbs().size()
		check(not glyph(menu, Menu.SIBLING_PREVIOUS).get("enabled", true) and glyph(menu, Menu.SIBLING_NEXT).get("enabled", false),
			"First folder offers only next: " + name)
		menu._activate(Menu.SIBLING_NEXT); await process_frame; menu.refresh()
		check(menu._sibling_index() == 1 and folders(menu).size() == 2 and str(platform.requested.back()).ends_with(str(parent[1].container.id).get_file()),
			"Next opens the following folder's listing: " + name)
		check(menu._crumbs().size() == depth, "Switching replaces the open folder instead of nesting: " + name)
		menu._activate(Menu.SIBLING_PREVIOUS); await process_frame; menu.refresh()
		check(menu._sibling_index() == 0, "Previous goes back to the earlier folder: " + name)
		for step in 6: menu._activate(Menu.SIBLING_NEXT); await process_frame
		menu.refresh()
		check(menu._sibling_index() == 5 and not glyph(menu, Menu.SIBLING_NEXT).get("enabled", true), "Next stops at the last folder: " + name)
		menu._choose(folders(menu)[0]); await process_frame; menu.refresh()
		check(menu._sibling_index() == 0 and menu._crumbs().size() == depth + 1, "A deeper folder switches among its own siblings: " + name)
		menu._go_back(); await process_frame; menu.refresh()
		check(menu._sibling_index() == -1 and glyph(menu, Menu.SIBLING_NEXT).is_empty(),
			"Back at a level whose siblings were not listed shows no switch: " + name)
		menu._go_back(); await process_frame; menu.refresh()
		check(folders(menu).size() == 6, "Going up still lists the parent: " + name)
	menu.free()
	for failure in failures: printerr("FAIL: " + failure)
	print("library sibling folders: %d checks, %d failures" % [checks, failures.size()])
	quit(1 if not failures.is_empty() else 0)
