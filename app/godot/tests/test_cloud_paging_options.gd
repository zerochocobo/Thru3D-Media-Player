extends SceneTree
const Menu := preload("res://scripts/library_menu.gd")
const Paging := preload("res://scripts/cloud_pagination.gd")
var checks := 0
var failures: Array[String] = []

class Platform extends Object:
	signal media_list(id: int, payload: String)
	var calls: Array[Dictionary] = []
	var cancelled: Array[int] = []
	func media_cloud_page_options(path: String, offset: int, force: bool, order: String, folder: String, size: int, subtitles: bool) -> int:
		calls.append({"path": path, "offset": offset, "force": force, "order": order, "folder": folder, "page_size": size, "subtitles": subtitles})
		return calls.size()
	func media_cloud_cancel(id: int) -> void: cancelled.append(id)
	func respond(values: Dictionary = {}, id: int = -1) -> void:
		if id < 0: id = calls.size()
		var r: Dictionary = calls[id - 1]
		var entry := {"title": "film%d.mp4" % r.offset, "uri": "cloud://account/film%d.mp4" % r.offset, "cloud_id": str(r.offset), "size": 100}
		var result := {"state": "ready", "path": r.path, "offset": r.offset, "order": r.order, "page_size": r.page_size,
			"raw_count": 1, "raw_ids": [str(r.offset)], "entries": [entry], "total": -1, "next_offset": r.offset + r.page_size}
		result.merge(values, true)
		media_list.emit(id, JSON.stringify(result))

func check(value: bool, name: String) -> void:
	checks += 1
	if not value: failures.append(name)

func _initialize() -> void: call_deferred("_run")

func _run() -> void:
	preload("res://scripts/i18n.gd").use("en")
	var platform := Platform.new()
	var menu := Menu.new()
	root.add_child(menu); menu.attach_platform(platform); menu.visible = true; menu.section = Menu.Section.CLOUD
	var paging: RefCounted = menu.cloud_pagination
	paging.preferences.path = "user://test-cloud-paging-%d.cfg" % Time.get_ticks_usec()
	menu._cloud_stack = [{"id": "/account", "title": "115", "provider": "115_open"}]
	menu._load_cloud()
	check(platform.calls.back().page_size == 200, "115 defaults to 200")
	platform.respond({"total": 105600})
	paging.jump(127)
	check(platform.calls.back().offset == 25400 and platform.calls.size() == 2, "Page 128 jumps directly without scanning")
	platform.respond({"total": 105600})
	check(menu._cloud_page == 127 and menu.rows.size() == 1, "Direct jump commits requested page")
	paging.action(Paging.OPEN)
	check(menu._buttons.any(func(b): return b.target == Paging.GO) and not menu.browser_content(), "Numeric panel uses ray buttons and blocks list scrolling")
	var scroll_before: float = menu.scroll; menu.stick_scroll(-1.0, 0.5)
	check(menu.scroll == scroll_before and not menu._in_list(Vector3.ZERO), "Page panel blocks joystick and drag scrolling behind it")
	paging.action(Paging.DIGIT + 5)
	check(paging.input == "5", "First digit replaces the current page rather than appending to it")
	paging.action(Paging.CLOSE)
	menu._cloud_stack[0].provider = "quark_open"; menu._load_cloud()
	check(platform.calls.back().page_size == 100, "Quark uses its own 100-row default")
	platform.respond()
	paging.action(Paging.OPEN)
	check(not menu._buttons.any(func(b): return b.target == Paging.LAST), "Unknown totals do not show a last-page target")
	paging.action(Paging.CLOSE)
	paging.jump(3)
	check(platform.calls.back().offset == 100 and paging.opened, "Opaque jump starts from nearest known cursor with progress")
	platform.respond({"raw_count": 0, "raw_ids": [], "entries": []})
	paging.queue_at = 0; paging.tick()
	check(platform.calls.back().offset == 200, "An empty filtered batch still advances its raw continuation")
	platform.respond(); paging.queue_at = 0; paging.tick(); platform.respond()
	check(menu._cloud_page == 3 and not paging.opened, "Opaque jump reaches destination")
	paging.jump(1); platform.respond({"state": "error", "error_reason": "cloud_page_expired"})
	paging.queue_at = 0; paging.tick()
	check(platform.calls.back().offset == 0 and paging.opened, "Expired cursor rebuild is explicit and cancellable")
	platform.respond(); paging.queue_at = 0; paging.tick(); platform.respond()
	check(menu._cloud_page == 1, "Rebuilt cursor reaches the requested old page")
	paging.start_all()
	var key: String = paging.directory_key
	check(not paging.preferences.contains(key), "Starting all never persists a premature choice")
	platform.respond(); paging.tick()
	check(paging.raw_count == 1 and paging.mode == "loading" and not paging.preferences.contains(key), "Intermediate batch is not a completed listing")
	paging.stop()
	check(paging.mode == "partial" and menu.rows.size() == 1 and not paging.preferences.contains(key), "Stop preserves partial content without remembering all")
	paging.action(Paging.RESUME)
	check(platform.calls.back().offset == 100, "Resume requests exactly the next uncommitted batch")
	platform.respond({"next_offset": -1}); paging.tick()
	check(paging.mode == "all" and paging.raw_count == 2 and paging.preferences.contains(key), "Only final success remembers the directory")
	check(not menu._buttons.any(func(b): return b.target == menu.CLOUD_NEXT) and menu._buttons.any(func(b): return b.target == Paging.PAGED), "Completed all replaces paging controls")
	menu._load_cloud()
	check(paging.mode == "loading" and platform.calls.back().offset == 0 and not paging.preferences.contains(key), "Reentry automatically loads all and consumes old success marker")
	platform.respond({"state": "error", "error": "Cloud connection failed"})
	check(paging.mode == "partial" and not paging.preferences.contains(key), "Failed automatic reload cannot cause an automatic retry loop")
	menu._load_cloud()
	check(paging.mode == "paged", "Next visit after failure uses paging")
	platform.respond({"next_offset": -1})
	paging.start_all(); platform.respond({"next_offset": -1}); paging.tick()
	paging.restore_paged()
	check(not paging.preferences.contains(key) and paging.mode == "paged", "Restore paging clears this directory's remembered choice")
	platform.respond()
	paging.start_all(); platform.respond(); paging.tick(); paging.queue_at = 0; paging.tick()
	platform.respond({"raw_ids": ["0"], "entries": [{"title": "film.mp4", "uri": "cloud://account/film.mp4", "cloud_id": "0"}], "next_offset": -1})
	check(paging.mode == "partial" and not paging.preferences.contains(key), "Repeated identities cannot be remembered as complete")
	paging.start_all(); paging.raw_count = Paging.MAX_RAW
	platform.respond()
	check(paging.limited and paging.mode == "partial" and not paging.preferences.contains(key), "Count limit stops safely and never persists all")
	paging.start_all(); var late := platform.calls.size(); paging.stop(); platform.respond({"next_offset": -1}, late)
	check(paging.mode == "partial" and paging.raw_count == 0, "Cancelled late replies cannot mutate the view or persist a mode")
	menu._cloud_stack[0].provider = "baidu"; menu.settings_provider = func(): return {"cloud_page_sizes": {"baidu": 500}}
	menu._load_cloud()
	check(platform.calls.back().page_size == 500, "Per-provider global override reaches the request")
	platform.respond()
	paging.jump(526)
	check(platform.calls.back().offset == 263000, "Baidu supports cold numeric jumps")
	platform.respond({"raw_count": 0, "raw_ids": [], "entries": [], "next_offset": -1})
	check(menu._cloud_page == 0 and menu.status == "Page unavailable", "Out-of-range unknown total preserves the current page")
	# Frame-sliced preparation stays bounded even for a large valid response.
	paging.start_all()
	var many: Array = []; var ids: Array = []
	for i in 500:
		many.append({"title": "%d.mp4" % i, "uri": "cloud://account/%d.mp4" % i, "cloud_id": str(i)}); ids.append(str(i))
	platform.respond({"entries": many, "raw_ids": ids, "raw_count": 500, "next_offset": -1, "total": 500})
	paging.tick()
	check(paging.visible_rows.size() <= 32 and paging.mode == "loading", "Large batch preparation is split across frames")
	while not paging.batch.is_empty(): paging.tick()
	check(paging.mode == "all" and menu.rows.size() == 500, "Final frame commits prepared rows and remembers success")
	menu.remember_playback_context("cloud://account/100.mp4")
	paging.mode = "paged"; menu._cloud_entries = []
	menu.set_compact(true, true)
	while not paging.batch.is_empty(): paging.tick()
	check(paging.mode == "all" and menu.rows.size() == 500, "Returning to playback library restores full-mode rows without refetching")
	menu.media_filter = 2; menu.refresh()
	while not paging.batch.is_empty(): paging.tick()
	check(menu.rows.is_empty() and paging.mode == "all", "Filtering loaded metadata needs no additional provider calls")
	menu.media_filter = 0; paging.start_all()
	platform.respond({"entries": many, "raw_ids": ids, "raw_count": 500, "next_offset": 500})
	paging.tick(); paging.stop()
	while not paging.batch.is_empty(): paging.tick()
	check(paging.mode == "partial" and paging.raw_count == 500 and paging.accumulated.size() == 500, "Stop during row preparation commits the received batch exactly once")
	check(not paging.preferences.contains(paging.directory_key), "Stopping during preparation never saves full mode")
	paging.start_all(); paging.byte_count = Paging.MAX_BYTES
	platform.respond()
	check(paging.limited and paging.mode == "partial", "Byte budget also stops small-count but oversized metadata")
	paging.restore_paged()
	platform.respond({"entries": many, "raw_ids": ids, "raw_count": 500, "next_offset": 500})
	check(menu._cloud_busy and menu.rows.is_empty(), "Large ordinary pages also prepare rows off the response frame")
	paging.tick()
	check(paging.visible_rows.size() <= 32, "Ordinary page row preparation obeys the same frame budget")
	while not paging.batch.is_empty(): paging.tick()
	check(not menu._cloud_busy and menu.rows.size() == 500 and paging.mode == "paged", "Prepared ordinary page commits without changing full-mode preference")
	menu.file_actions.enabled = true; menu.refresh()
	menu.file_actions.selection[menu.file_actions.row_key(menu.rows[100])] = true
	check(menu.file_actions.selected_rows().size() == 1, "Enabling file management indexes already prepared rows")
	paging.start_all(); platform.respond({"next_offset": -1}); paging.tick()
	var order_events: Array = []
	menu.directory_order_changed.connect(func(): order_events.append(menu.rows.size()))
	menu.file_actions.choose_order("name_desc")
	check(paging.mode == "loading" and platform.calls.back().order == "name_desc", "Sorting a remembered full listing starts a new all-load in the chosen order")
	platform.respond({"next_offset": -1}); paging.tick()
	check(menu.file_actions.cloud_requested_order.is_empty() and menu.file_actions.cloud_order() == "name_desc" and order_events == [1], "Full-load sorting commits and notifies only after prepared rows exist")
	menu.file_actions.selection[menu.file_actions.row_key(menu.rows[0])] = true
	check(menu.file_actions.selected_rows().size() == 1, "Completed full listings support file selection")
	menu.file_actions.choose_order("size_desc")
	platform.respond({"state": "error", "error": "Cloud connection failed"})
	check(menu.file_actions.cloud_requested_order.is_empty() and menu.file_actions.cloud_order() == "name_desc" and not paging.preferences.contains(paging.directory_key), "Failure before the first sorted batch rolls back the pending order and leaves all-mode unremembered")
	paging.start_all(); platform.respond({"next_offset": -1}); paging.tick()
	menu.file_actions.choose_order("size_desc"); paging.stop()
	check(menu.file_actions.cloud_requested_order.is_empty() and menu.file_actions.cloud_order() == "name_desc", "Stopping before a sorted response clears the pending order")
	paging.start_all()
	platform.respond({"order": "source", "order_fallback": true, "sort_orders": ["source"], "next_offset": -1}); paging.tick()
	check(paging.mode == "all" and menu.file_actions.cloud_order() == "source" and menu._cloud_stack[0].sort_orders == ["source"], "Explicit provider sort fallback updates capabilities and the full-load scope")
	menu.remove_file_rows(menu.rows[0]); menu.refresh()
	check(menu.rows.is_empty() and paging.raw_count == 0, "Confirmed deletion updates full-mode cached rows and count")
	paging.cancel(); menu.compact = false; menu.section = Menu.Section.SETTINGS; menu.tab = Menu.GENERAL_TAB
	menu.scroll = 0.0; menu.refresh()
	var header: Dictionary = menu.rows.filter(func(row): return row.get("cloud_paging_group", false))[0]
	check(menu.rows.filter(func(row): return str(row.get("key", "")).begins_with("cloud_page_size/")).is_empty(), "Collapsed settings group creates no provider fields")
	var closed_nodes: int = menu.get_child_count()
	menu._choose(header)
	var fields: Array = menu.rows.filter(func(row): return str(row.get("key", "")).begins_with("cloud_page_size/"))
	check(fields.size() == 6 and fields.all(func(row): return row.choices.size() == 1), "Expanded group builds summaries without constructing any option lists")
	var target := -1
	for id in menu.choices.targets:
		if menu.choices.targets[id].get("key") == "cloud_page_size/115_open": target = int(id); break
	menu._activate(target)
	fields = menu.rows.filter(func(row): return str(row.get("key", "")).begins_with("cloud_page_size/"))
	check(fields.filter(func(row): return row.choices.size() > 1).size() == 1, "Opening one provider constructs only that provider's options")
	var popup_choices: Array = menu.choices.targets.values().filter(func(item): return item.get("kind") == "choose" and str(item.get("key", "")).begins_with("cloud_page_size/"))
	check(popup_choices.size() == 4 and popup_choices.all(func(item): return item.key == "cloud_page_size/115_open"), "Only the opened provider's popup has rendered option buttons")
	menu._choose(header)
	check(menu.choices.popup.is_empty() and menu.choices.opened.is_empty() and menu.get_child_count() == closed_nodes, "Collapse frees popup and provider nodes")
	for i in 12: menu._choose(header); menu._choose(header)
	check(menu.get_child_count() == closed_nodes, "Repeated expansion does not accumulate menu nodes")
	var preference_path: String = paging.preferences.path
	menu.queue_free(); await process_frame; platform.free()
	if FileAccess.file_exists(preference_path): DirAccess.remove_absolute(preference_path)
	print("cloud paging options checks=%d failures=%d" % [checks, failures.size()])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)
