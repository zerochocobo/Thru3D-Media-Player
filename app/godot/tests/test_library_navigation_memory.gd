extends SceneTree
const Menu := preload("res://scripts/library_menu.gd")
var checks := 0
var failures: Array[String] = []
class Platform extends RefCounted:
	signal media_list(id: int, payload: String)
	var sequence := 0
	func reply(data: Dictionary) -> int:
		sequence += 1
		var id := sequence
		(func(): media_list.emit(id, JSON.stringify(data))).call_deferred()
		return id
	func entries(path: String) -> Array:
		var result: Array = []
		for i in (60 if path in ["/disk", "share", "root"] else 4):
			result.append({"id": path + "/folder%d" % i, "title": "Folder %d" % i, "container": true})
		return result
	func media_local_browse(path: String) -> int:
		return reply({"state": "ready", "path": path, "entries": entries(path)})
	func media_smb_browse(server: String, path: String) -> int:
		return reply({"state": "ready", "server_id": server, "path": path, "entries": entries(path)})
	func media_dlna_browse(server: String, path: String) -> int:
		return reply({"state": "ready", "server_id": server, "object_id": path, "entries": entries(path)})
func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok: failures.append(label)
func _initialize() -> void: call_deferred("run")
func run() -> void:
	var platform := Platform.new()
	var menu := Menu.new(); root.add_child(menu); menu.attach_platform(platform); menu.visible = true
	for source in [Menu.Section.LOCAL, Menu.Section.SMB, Menu.Section.DLNA]:
		menu.section = source; menu.scroll = 0.0
		menu._local_stack = [{"id": "/disk", "title": "Disk"}]
		menu._smb_server = "smb-account"; menu._smb_path = "share"
		menu._dlna_server = "dlna-account"; menu._dlna_stack = [{"id": "root", "title": "Root"}]
		if source == Menu.Section.LOCAL: menu._load_section()
		elif source == Menu.Section.SMB: menu._request("smb_browse", platform.media_smb_browse(menu._smb_server, menu._smb_path))
		else: menu._request("dlna_browse", platform.media_dlna_browse(menu._dlna_server, "root"))
		await process_frame; menu.refresh()
		menu._set_scroll(3.0)
		var header: Node = menu._buttons.filter(func(button): return button.target == Menu.BACK)[0].node
		menu._set_scroll(4.0)
		check(is_instance_valid(header) and menu._buttons.any(func(button): return button.node == header), "Scrolling keeps header for source " + str(source))
		menu._choose(menu.rows[13]); await process_frame
		check(menu.scroll == 0.0 and menu.rows.size() == 4, "Child begins at top for source " + str(source))
		menu._go_back(); await process_frame
		check(is_equal_approx(menu.scroll, 4.0) and menu.rows.size() == 60, "Back restores parent viewport for source " + str(source))
		menu._choose(menu.rows[30]); await process_frame; menu._go_to(1); await process_frame
		check(is_equal_approx(menu.scroll, 4.0), "Breadcrumb restores parent viewport for source " + str(source))
	menu.queue_free(); await process_frame
	print("Library navigation memory checks=%d failures=%d" % [checks, failures.size()])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)
