extends SceneTree
const Menu := preload("res://scripts/library_menu.gd")
var checks := 0
var failures: Array[String] = []

class Platform extends Object:
	signal media_list(id: int, payload: String)
	var calls: Array[Dictionary] = []
	func media_cloud_directory_page(path: String, offset: int, force: bool, order: String, folder_id: String) -> int:
		calls.append({"path": path, "offset": offset, "force": force, "order": order, "folder_id": folder_id})
		return calls.size()
	func media_cloud_cancel(_id: int) -> void: pass
	func respond(values: Dictionary = {}) -> void:
		var request: Dictionary = calls.back()
		var result := {"state": "ready", "path": request.path, "offset": request.offset, "order": request.order,
			"total": -1, "page_size": 48, "next_offset": 48, "entries": [{"title": "movie.mp4", "uri": "cloud://account/Movies/movie.mp4", "size": 12}]}
		result.merge(values, true)
		media_list.emit(calls.size(), JSON.stringify(result))

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)
func _initialize() -> void: call_deferred("_run")
func _run() -> void:
	preload("res://scripts/i18n.gd").use("en")
	var platform := Platform.new()
	var menu := Menu.new()
	root.add_child(menu); menu.attach_platform(platform)
	menu.section = Menu.Section.CLOUD; menu.visible = true
	menu._cloud_stack = [{"id": "/account", "title": "Cloud", "provider": "quark_open"}]
	menu._load_cloud(false)
	check(platform.calls.size() == 1 and platform.calls[0].offset == 0, "Root requests exactly its first batch")
	platform.respond({"entries": [{"id": "/account/Movies", "title": "Movies", "container": true, "cloud_id": "stable-folder-id"}], "next_offset": -1})
	menu._choose(menu.rows[0])
	check(platform.calls.size() == 2 and platform.calls.back().folder_id == "stable-folder-id", "Entering a folder passes its stable ID without enumerating parents")
	check(menu._cloud_stack.back().cloud_id == "stable-folder-id", "Navigation stack retains identity for restored locations")
	var saved_location: Dictionary = JSON.parse_string(JSON.stringify(preload("res://scripts/media_location.gd").clean({"type":"cloud", "path":menu._cloud_path(), "stack":menu._cloud_stack})))
	platform.respond()
	check(menu.rows.size() == 1 and menu._cloud_total == -1 and menu._cloud_next == 48, "Short first batch displays immediately while total is unknown")
	check(platform.calls.size() == 2, "Displaying first batch never fetches continuation")
	menu._turn_cloud_page(1)
	check(platform.calls.size() == 3 and platform.calls.back().offset == 48, "Next requests only its logical page; provider cursor stays out of UI")
	platform.respond({"state": "error", "error": "Cloud connection failed", "error_reason": "cloud_page_expired"})
	check(menu.rows.size() == 1 and menu._cloud_page == 0, "Expired cursor preserves current content until explicit refresh")
	menu._activate(Menu.REFRESH)
	check(platform.calls.size() == 4 and platform.calls.back().offset == 0 and platform.calls.back().folder_id == "stable-folder-id", "Refresh restarts expired pagination at first batch with the same identity")
	platform.respond({"entries": [], "next_offset": 48})
	check(menu.rows.is_empty() and menu._cloud_next == 48 and platform.calls.size() == 4, "Empty provider batch with continuation remains navigable without automatic scanning")
	menu._turn_cloud_page(1); platform.respond({"next_offset": -1})
	check(menu._cloud_page == 1 and menu.rows.size() == 1 and menu._cloud_next == -1, "Explicit next page finishes an unknown-length directory")
	var allowed := ["source", "name_asc", "name_desc", "modified_asc", "modified_desc"]
	menu._cloud_stack[0]["sort_orders"] = allowed
	menu.file_actions.load({str(Menu.Section.CLOUD): "size_desc"})
	check(menu.file_actions.cloud_order() == "name_asc" and not menu.file_actions.supports_order("size_desc"), "Unsupported saved Quark size order falls back without full local sort")
	var before := platform.calls.size(); menu.file_actions.choose_order("size_desc")
	check(platform.calls.size() == before, "Unsupported sort cannot issue a request")
	menu.file_actions.choose_order("modified_desc")
	check(platform.calls.back().offset == 0 and platform.calls.back().order == "modified_desc", "Changing supported sort requests only its first page")
	platform.respond({"next_offset": -1, "sort_orders": allowed})
	check(menu.file_actions.cloud_order() == "modified_desc", "Server sort commits after success")
	menu._cloud_stack[0].erase("sort_orders"); menu.file_actions.load({str(Menu.Section.CLOUD): "size_desc"})
	menu._cloud_offsets.assign([0]); menu._load_cloud(false)
	platform.respond({"order": "name_asc", "order_fallback": true, "sort_orders": allowed, "next_offset": -1})
	check(menu.file_actions.cloud_order() == "name_asc" and menu.status.is_empty(), "First response can migrate legacy unsupported order with explicit capabilities")
	menu._load_cloud(false)
	platform.respond({"state": "error", "error": "Cloud connection failed", "error_reason": "cloud_location_expired"})
	check(menu._cloud_stack.size() == 2, "Missing legacy identity does not silently navigate away")
	menu._activate(Menu.REFRESH)
	check(menu._cloud_stack.size() == 1 and platform.calls.back().path == "/account" and platform.calls.back().offset == 0, "Explicit refresh recovers a legacy location at its account root")
	platform.respond({"entries": [], "next_offset": -1})
	menu.collections.open_location({"uri":"cloud://account/Movies/movie.mp4", "location":saved_location})
	check(platform.calls.back().path == "/account/Movies" and platform.calls.back().folder_id == "stable-folder-id", "Reopening a saved source location passes its ID after persistence without path discovery")
	platform.respond({"next_offset": -1})
	print("cloud native paging checks=%d failures=%d" % [checks, failures.size()])
	for failure in failures: push_error(failure)
	menu.queue_free(); await process_frame; platform.free()
	quit(0 if failures.is_empty() else 1)
