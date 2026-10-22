extends SceneTree
const Menu := preload("res://scripts/library_menu.gd")
var checks := 0
var failures: Array[String] = []

class Platform extends RefCounted:
	signal media_list(id: int, payload: String)
	var calls: Array[Dictionary] = []
	var inserted := 0
	func media_cloud_cancel(_id: int) -> void: pass
	func media_cloud_page_options(path: String, offset: int, _force: bool, order: String, _folder: String, size: int, _subtitles: bool) -> int:
		calls.append({"path":path,"offset":offset,"order":order,"page_size":size})
		return calls.size()
	func reply() -> void:
		var request: Dictionary = calls.back()
		var entries: Array = []
		var parent: bool = request.path == "/account"
		if parent:
			for i in inserted: entries.append({"id":"/account/added%d" % i,"title":"Added %d" % i,"container":true})
		for i in (80 if parent else 4): entries.append({"id":request.path + "/folder%d" % i,"title":"Folder %d" % i,"container":true,"modified":100-i})
		var result: Dictionary = request.duplicate(true)
		result.merge({"state":"ready","entries":entries,"raw_count":entries.size(),"raw_ids":entries.map(func(row): return row.id),"total":1000 if parent else 4,"next_offset":int(request.offset) + int(request.page_size) if parent else -1})
		media_list.emit(calls.size(), JSON.stringify(result))

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok: failures.append(label)

func settle(menu: Node3D) -> void:
	for i in 8:
		menu.cloud_pagination.tick()
		await process_frame

func _initialize() -> void: call_deferred("run")

func run() -> void:
	var platform := Platform.new()
	var menu := Menu.new(); root.add_child(menu); menu.set_process(false)
	menu.attach_platform(platform); menu.visible = true; menu.section = Menu.Section.CLOUD
	menu.cloud_pagination.preferences.path = "user://directory-cloud-navigation-%d.cfg" % Time.get_ticks_usec()
	menu._cloud_stack = [{"id":"/account","title":"115","provider":"115_open"}]
	menu._load_cloud(); platform.reply(); await settle(menu)
	menu.file_actions.choose_order("modified_desc", false); platform.reply(); await settle(menu)
	menu.cloud_pagination.jump(2); platform.reply(); await settle(menu)
	check(menu._cloud_page == 2 and platform.calls.back().offset == 400, "Parent starts on its remembered remote page")
	var visited := {}
	for view in ["list", "grid"]:
		for breadcrumb in [false, true]:
			menu.set_view_mode(view); menu._set_scroll(4.25)
			var index: int = menu._first_line() * menu._cols() + menu._cols()
			var selected: Dictionary = menu.rows[index]
			var expected_order: String = visited.get(str(selected.container.id), "name_asc")
			var offset: float = float(index / menu._cols()) - menu.scroll
			menu._activate(Menu.ROW_BASE + index - menu._first_line() * menu._cols())
			check(platform.calls.back().offset == 0 and platform.calls.back().order == expected_order, "Child restores its own sort and pagination")
			platform.reply(); await settle(menu)
			menu.file_actions.choose_order("name_desc"); platform.reply(); await settle(menu)
			visited[str(selected.container.id)] = "name_desc"
			platform.inserted = menu._cols() * 2
			menu._activate(Menu.CRUMB_BASE + 1 if breadcrumb else Menu.BACK)
			check(platform.calls.back().path == "/account" and platform.calls.back().offset == 400 and platform.calls.back().order == "mixed_modified_desc", "Both return controls restore parent page, order and grouping")
			platform.reply(); await settle(menu)
			var restored := -1
			for i in menu.rows.size():
				if menu.Presentation.key(menu.rows[i]) == menu.Presentation.key(selected): restored = i; break
			check(restored >= 0 and is_equal_approx(float(restored / menu._cols()) - menu.scroll, offset), "Cloud folder keeps its screen row after insertions / " + view + " / " + str(breadcrumb))
			check(menu._cloud_page == 2 and not menu.file_actions.folders_first(), "Parent preferences survive child changes")
			platform.inserted = 0
			menu._refresh_source(); platform.reply(); await settle(menu)
	menu.queue_free(); await process_frame
	print("Cloud directory navigation: %d checks, %d failures" % [checks, failures.size()])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)
