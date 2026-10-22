extends SceneTree
const Menu := preload("res://scripts/library_menu.gd")
var checks := 0
var failures: Array[String] = []
class Platform extends RefCounted:
	signal media_list(id: int, payload: String)
	var sequence := 0
	var inserted := 0
	var removed := ""
	var fail_child := false
	func reply(data: Dictionary) -> int:
		sequence += 1
		var id := sequence
		if fail_child and data.entries.size() == 4: data.merge({"state":"error","error":"Late child failure"}, true)
		(func(): media_list.emit(id, JSON.stringify(data))).call_deferred()
		return id
	func entries(path: String) -> Array:
		var result: Array = []
		for i in (60 if path in ["/disk", "share", "root"] else 4):
			if str(i) == removed: continue
			result.append({"id": path + "/folder%d" % i, "title": "Folder %d" % i, "container": true})
		if path in ["/disk", "share", "root"]:
			for i in inserted: result.append({"id":path + "/added%d" % i,"title":"Added %d" % i,"container":true})
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
	var menu := Menu.new(); root.add_child(menu); menu.set_process(false); menu.attach_platform(platform); menu.visible = true
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
		for view in ["list", "grid"]:
			for breadcrumb in [false, true]:
				menu.set_view_mode(view); menu._set_scroll(4.25)
				var selected: Dictionary = menu.rows[menu._first_line() * menu._cols() + menu._cols()]
				var identity := menu.Presentation.key(selected)
				var offset: float = float(menu.rows.find(selected) / menu._cols()) - menu.scroll
				menu._activate(Menu.ROW_BASE + menu.rows.find(selected) - menu._first_line() * menu._cols()); await process_frame
				menu.file_actions.choose_order("name_desc", false)
				platform.inserted = menu._cols() * 2
				if breadcrumb: menu._activate(Menu.CRUMB_BASE + 1)
				else: menu._activate(Menu.BACK)
				await process_frame
				var index := -1
				for i in menu.rows.size():
					if menu.Presentation.key(menu.rows[i]) == identity: index = i; break
				check(index >= 0 and is_equal_approx(float(index / menu._cols()) - menu.scroll, offset), "Opened folder keeps screen row after insertions via " + ("path" if breadcrumb else "back") + " / " + view + " / " + str(source))
				check(menu.file_actions.order() == "name_asc" and menu.file_actions.folders_first(), "Returning restores parent's preferences: " + str(source))
				# Jump across two levels through the actual path button.
				menu._choose(menu.rows[index]); await process_frame
				menu._choose(menu.rows[0]); await process_frame
				menu._activate(Menu.CRUMB_BASE + 1); await process_frame
				check(is_equal_approx(float(index / menu._cols()) - menu.scroll, offset), "Multi-level path jump preserves ancestor anchor: " + str(source))
				platform.inserted = 0
				# Refresh the parent before the next case without changing its path.
				if source == Menu.Section.LOCAL: menu._load_section()
				elif source == Menu.Section.SMB: menu._request("smb_browse", platform.media_smb_browse(menu._smb_server, menu._smb_path))
				else: menu._request("dlna_browse", platform.media_dlna_browse(menu._dlna_server, "root"))
				await process_frame; menu.refresh()
		for breadcrumb in [false, true]:
			menu._set_scroll(4.25)
			var index: int = menu._first_line() * menu._cols() + menu._cols()
			var selected: Dictionary = menu.rows[index]
			menu._choose(selected); await process_frame
			platform.removed = str(selected.title).trim_prefix("Folder ")
			menu._activate(Menu.CRUMB_BASE + 1 if breadcrumb else Menu.BACK); await process_frame
			check(is_equal_approx(menu.scroll, 4.25) and menu.rows.size() == 59, "Removed folder falls back near its original position: " + str(source))
			platform.removed = ""
			platform.fail_child = true
			menu._choose(menu.rows[index])
			menu._activate(Menu.CRUMB_BASE + 1 if breadcrumb else Menu.BACK); await process_frame
			check(menu.status != "Late child failure" and menu.rows.size() == 60, "Both return paths ignore delayed errors from child requests: " + str(source))
			platform.fail_child = false
	menu.queue_free(); await process_frame
	print("Library navigation memory checks=%d failures=%d" % [checks, failures.size()])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)
