extends SceneTree
const Menu := preload("res://scripts/library_menu.gd")
const Search := preload("res://scripts/cloud_search.gd")
var checks := 0
var failures: Array[String] = []
class Platform extends Object:
	signal media_list(id: int, payload: String)
	var requests: Array[Dictionary] = []
	var cancelled: Array[int] = []
	var clipboard := "旅行 #%.mp4"
	func media_cloud_page(path: String, offset: int, force: bool) -> int:
		requests.append({"action": "browse", "path": path, "offset": offset, "force": force}); return requests.size()
	func media_cloud_search(path: String, query: String, scope: String, kind: String, cursor: String, force: bool) -> int:
		requests.append({"action": "search", "path": path, "query": query, "scope": scope, "kind": kind, "cursor": cursor, "force": force}); return requests.size()
	func media_cloud_search_resolve(path: String, token: String) -> int:
		requests.append({"action": "resolve", "path": path, "token": token}); return requests.size()
	func media_cloud_cancel(id: int) -> void: cancelled.append(id)
	func media_clipboard_text() -> String: return clipboard
	func browse_reply(id: int, scopes: Array = ["current", "tree", "all"]) -> void:
		var request := requests[id - 1]
		var entries: Array = [{"id": "/mount1", "title": "Cloud", "container": true}] if request.path == "" else [{"id": request.path + "/root.mp4", "uri": "cloud://mount1/root.mp4", "title": "root.mp4", "kind": "video"}]
		media_list.emit(id, JSON.stringify({"state": "ready", "path": request.path, "offset": request.offset, "entries": entries, "search_scopes": scopes, "next_offset": -1, "total": entries.size()}))
	func search_reply(id: int, entries: Array = [], next: String = "", override: Dictionary = {}) -> void:
		var request: Dictionary = requests[id - 1].duplicate()
		request.merge({"state": "ready", "source": "cloud_search", "entries": entries, "next_cursor": next, "limited": false}, true)
		request.merge(override, true); media_list.emit(id, JSON.stringify(request))
	func result(token: String, title: String = "旅行 #%.mp4", folder: bool = false) -> Dictionary:
		return {"title": title, "container": folder, "kind": "video", "relative_path": "/中文目录/" + title, "search_path": "/mount1", "search_token": token}
func check(value: bool, message: String) -> void:
	checks += 1
	if not value: failures.append(message)
func button(menu: Node, target: int) -> Dictionary:
	for item in menu._buttons:
		if item.target == target: return item
	return {}
func _initialize() -> void: call_deferred("run")
func run() -> void:
	preload("res://scripts/i18n.gd").use("en")
	var platform := Platform.new(); var menu := Menu.new(); root.add_child(menu)
	menu.attach_platform(platform); menu.toggle(); menu._activate(Menu.NAV_BASE + Menu.Section.CLOUD); platform.browse_reply(1)
	check(button(menu, Search.OPEN).is_empty(), "Account list has no file search")
	menu._choose(menu.rows[0]); platform.browse_reply(2)
	check(not button(menu, Search.OPEN).is_empty(), "Directory has search entry")
	var original := menu._cloud_entries.duplicate(true)
	var search_button := button(menu, Search.OPEN)
	var ray_origin: Vector3 = search_button.node.to_global(Vector3(0, 0, 1))
	check(int(menu.ray_hit(ray_origin, -menu.global_basis.z).get("target", -999)) == Search.OPEN, "Controller ray hits the search icon")
	check(menu.press_pointer("right_controller", ray_origin, -menu.global_basis.z, true), "Controller trigger opens search")
	menu.release_pointer("right_controller", ray_origin, -menu.global_basis.z, true)
	check(menu.cloud_search.active and menu.cloud_search.editing and menu.cloud_search.scope == "all", "Cloud root defaults to native entire drive search")
	check(menu.rows.is_empty() and not menu._grid(), "Keyboard hides directory tiles")
	check(button(menu, Search.SCOPE + 1).enabled, "Subtree scope follows capabilities")
	menu._activate(Search.PASTE)
	check(menu.cloud_search.query == platform.clipboard, "UTF8 pasted query preserves Chinese and special characters")
	menu._activate(Search.SUBMIT); var id := platform.requests.size()
	check(platform.requests.back().query == platform.clipboard and platform.requests.back().cursor == "", "Search sends keyword and first cursor")
	platform.search_reply(id, [platform.result("s:0")], "s:1")
	check(menu.rows.size() == 1 and menu.rows[0].detail == "中文目录", "Results show filename and relative parent")
	check(menu._cloud_entries == original and not menu.cloud_search.editing, "Search preserves underlying browse snapshot")
	menu._activate(Search.NEXT); id = platform.requests.size()
	check(platform.requests.back().cursor == "s:1", "Next page uses native opaque cursor")
	platform.search_reply(id, [], "s:2")
	check(menu.rows.is_empty() and menu.status == "" and button(menu, Search.NEXT).enabled, "Empty filtered page retains continuation")
	menu._activate(Search.NEXT); id = platform.requests.size()
	platform.search_reply(id, [platform.result("s:96")])
	check(menu.cloud_search.page == 2 and not button(menu, Search.NEXT).enabled, "Last native page ends continuation")
	menu._activate(Search.PREVIOUS); id = platform.requests.size(); platform.search_reply(id, [], "s:2")
	check(menu.cloud_search.page == 1 and platform.requests.back().cursor == "s:1", "Previous page uses its recorded cursor")
	menu._activate(Search.REFRESH); id = platform.requests.size()
	check(platform.requests.back().force and platform.requests.back().cursor == "", "Refresh starts new search and bypasses directory cache")
	platform.search_reply(id, [platform.result("fresh:0")], "fresh:1")
	menu._activate(Search.KIND + 2); id = platform.requests.size()
	check(platform.requests.back().kind == "image" and platform.requests.back().cursor == "", "Type change resets paging")
	menu._activate(Search.SCOPE); var current_id := platform.requests.size()
	check(platform.cancelled.has(id) and platform.requests.back().scope == "current", "Range change cancels obsolete query")
	platform.search_reply(id, [platform.result("late:0", "late.mp4")])
	check(not menu.rows.any(func(row): return row.title == "late.mp4"), "Late result cannot overwrite changed range")
	platform.search_reply(current_id, [platform.result("current:0")], "", {"query": "wrong"})
	check(menu.status == "Cloud search failed" and menu.cloud_search.pending == 0, "Matching ID with wrong query is rejected")
	menu._activate(Search.INPUT); menu._activate(Search.CLEAR)
	menu.system_text_input.set_text("cloud_search", "中文")
	check(menu.cloud_search.query == "中文" and button(menu, Search.KEY + 10).is_empty(), "System editor accepts Chinese and replaces the custom letter keyboard")
	menu.cloud_search._set_draft("旅行"); menu._activate(Search.SUBMIT); id = platform.requests.size()
	platform.search_reply(id, [], "", {"limited": true})
	check(menu.status == "Too many results. Refine your search", "Provider cap asks for a narrower query, including empty filtered results")
	menu._activate(Search.REFRESH); id = platform.requests.size()
	menu.dismiss(); check(platform.cancelled.has(id) and not menu.cloud_search.active, "Dismissal cancels search and clears modal state")
	platform.search_reply(id, [platform.result("late:0")]); check(menu._cloud_entries == original, "Dismissed result does not change directory")
	menu.toggle(); menu.cloud_search.scopes = ["current"]; menu._activate(Search.OPEN)
	check(menu.cloud_search.scope == "current" and button(menu, Search.SCOPE + 1).is_empty() and button(menu, Search.SCOPE + 2).is_empty(), "Ali/Quark/WebDAV only expose current directory")
	menu.cloud_search._set_draft("旅行"); menu._activate(Search.SUBMIT); id = platform.requests.size()
	platform.search_reply(id, [platform.result("folder:0", "子目录", true)])
	menu._choose(menu.rows[0]); id = platform.requests.size()
	check(platform.requests.back().action == "resolve" and platform.requests.back().token == "folder:0", "Result path resolves only on selection")
	platform.media_list.emit(id, JSON.stringify({"source": "cloud_search_resolve", "state": "ready", "path": "/mount1", "token": "folder:0", "entry": {"id": "/mount1/父目录/子目录", "title": "子目录", "container": true}}))
	check(not menu.cloud_search.active and menu._cloud_path() == "/mount1/父目录/子目录" and menu._cloud_stack.size() == 3, "Resolved folder has real breadcrumbs and normal browser")
	platform.browse_reply(platform.requests.size(), ["current"])
	menu._activate(Search.OPEN); menu.cloud_search._set_draft("旅行"); menu._activate(Search.SUBMIT); id = platform.requests.size()
	platform.search_reply(id, [platform.result("video:0")])
	var selected: Array = []; menu.chosen.connect(func(uri, title): selected.append([uri, title]))
	menu._choose(menu.rows[0]); id = platform.requests.size()
	platform.media_list.emit(id, JSON.stringify({"source": "cloud_search_resolve", "state": "ready", "path": "/mount1/父目录/子目录", "token": "video:0", "entry": {"id": "/mount1/其他目录/旅行.mp4", "uri": "cloud://mount1/其他目录/旅行.mp4", "title": "旅行.mp4", "container": false, "kind": "video"}}))
	check(selected.size() == 1 and menu._cloud_path() == "/mount1/其他目录" and not menu.visible, "Selected video uses normal playback and its real parent context")
	for language in ["zh", "zh_Hant", "ja"]:
		preload("res://scripts/i18n.gd").use(language)
		for key in Search.SCOPE_NAMES + Search.KIND_NAMES + ["Search files", "Cloud search failed", "No matching files", "Too many results. Refine your search"]:
			check(I18nText(key) != key, "Search translation exists: " + language + "/" + key)
	print("cloud search checks=%d failures=%d" % [checks, failures.size()])
	for failure in failures: push_error(failure)
	menu.queue_free(); platform.free(); quit(0 if failures.is_empty() else 1)
func I18nText(key: String) -> String: return preload("res://scripts/i18n.gd").t(key)
