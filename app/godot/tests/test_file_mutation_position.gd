extends SceneTree
## All writes are simulated responses. No real files, accounts or settings are used.
const Library := preload("res://scripts/library_menu.gd")
const CountedLibrary := preload("res://tests/test_large_playback_list.gd").CountedLibrary
const Actions := preload("res://scripts/library_file_actions.gd")
var checks := 0
var failures: Array[String] = []
var measurements: Array[Dictionary] = []

class Platform extends "res://tests/test_library_file_actions.gd".Platform:
	func media_local_browse(path: String) -> int:
		calls.append({"operation": "local_browse", "path": path}); return calls.size()
	func media_smb_browse(server: String, path: String) -> int:
		calls.append({"operation": "smb_browse", "server": server, "path": path}); return calls.size()

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func _initialize() -> void: call_deferred("run")

func files(scheme: String, first: int, count: int) -> Array:
	var entries: Array = []
	for index in range(first, first + count):
		entries.append({"id": "%05d.mp4" % index, "uri": scheme + "%05d.mp4" % index, "title": "%05d.mp4" % index,
			"size": 12345678, "modified": 100, "cloud_id": str(index), "can_delete": true, "can_rename": true})
	return entries

func fixture(source: int, count: int, view: String) -> Node3D:
	var menu := CountedLibrary.new(); root.add_child(menu); menu.set_process(false)
	menu.attach_platform(Platform.new()); menu.section = source; menu.visible = true
	menu.view_mode = "grid" if view == "grid-full" else "list"; menu.compact = view == "list-compact"
	if source == Library.Section.LOCAL:
		menu._local_stack = [{"id": "/disk", "title": "Movies"}]; menu._local_entries = files("file:///disk/", 1, count)
	elif source == Library.Section.SMB:
		menu._smb_server = "fixture"; menu._smb_path = "Movies"; menu._smb_entries = files("smb://fixture/Movies/", 1, count)
	else:
		menu._cloud_stack = [{"id": "/fixture/Movies", "title": "Movies"}]
		menu._cloud_entries = files("cloud://fixture/Movies/", 193, count)
		menu._cloud_page = 4; menu._cloud_offsets.assign([0, 48, 96, 144, 192]); menu._cloud_next = 240; menu._cloud_total = 5000
	menu.file_actions.set_enabled(true); menu.refresh()
	menu.file_actions.editing = view == "grid-full"
	menu._set_scroll(float(maxi(1, count / 2) / menu._cols()))
	menu.remember_playback_context()
	return menu

func top_keys(menu: Node3D) -> Array:
	return menu.rows.slice(menu._first_line() * menu._cols(), (menu._first_line() + 1) * menu._cols()).map(func(row): return Library.Presentation.key(row))

func dispose(menu: Node3D) -> void:
	var platform: Object = menu.platform
	menu.free(); platform.free()

func delete_selected(menu: Node3D) -> void:
	menu._activate(Actions.DELETE_FILE)
	check(menu.file_actions.modal == "delete" and menu.file_actions.plan_ready, "Deletion still requires the existing confirmation")
	menu._activate(Actions.CONFIRM)

func respond_delete(menu: Node3D) -> void:
	menu.platform.respond(menu.platform.calls.size(), "ready", {"deleted": true})

func rename_selected(menu: Node3D, title: String) -> void:
	menu._activate(Actions.Rename.OPEN)
	menu.file_actions.rename.name = title.get_basename()
	menu._activate(Actions.Rename.PREVIEW)
	var old_uri := str(menu.file_actions.target.uri)
	menu.platform.respond(menu.platform.calls.size(), "ready", {"preview": true, "plan": "fixture-plan", "moves": [{"from": str(menu.file_actions.target.title), "to": title}]})
	menu._activate(Actions.Rename.APPLY)
	menu.platform.respond(menu.platform.calls.size(), "ready", {"renamed": true, "new_uri": old_uri.get_base_dir() + "/" + title, "new_title": title})

func local_cases() -> void:
	for source in [Library.Section.LOCAL, Library.Section.SMB]:
		for count in [1500, 5000]:
			for view in ["grid-full", "list-full", "list-compact"]:
				var label := "%s/%d/%s" % [source, count, view]
				var menu := fixture(source, count, view)
				var rebuilds: int = menu.rebuilds; var converted: int = menu.conversions
				var before: float = menu.scroll
				var index: int = menu._first_line() * menu._cols()
				var deleted_uri := str(menu.rows[index].uri)
				menu.file_actions.toggle(menu.rows[index]); delete_selected(menu)
				var start := Time.get_ticks_usec(); respond_delete(menu)
				var delete_ms := (Time.get_ticks_usec() - start) / 1000.0
				check(menu.rows.size() == count - 1 and not menu.rows.any(func(row): return row.uri == deleted_uri), "Remove only confirmed target: " + label)
				check(menu.scroll > 0 and absf(menu.scroll - before) <= 1.0, "Deleting the top visible file stays in its neighborhood: " + label)
				check(menu.rebuilds == rebuilds and menu.conversions == converted, "Deletion never rebuilds or reconverts the directory: " + label)
				var snapshots: Array = menu.file_entry_snapshots()
				check(not snapshots.any(func(entries): return entries.any(func(entry): return str(entry.get("uri", "")) == deleted_uri)), "Playback snapshot cannot resurrect the deleted file: " + label)
				# Deletion before the viewport keeps the old top file within the same first line.
				var anchor := str(menu.rows[menu._first_line() * menu._cols()].uri)
				menu.file_actions.toggle(menu.rows[0]); delete_selected(menu); respond_delete(menu)
				check(top_keys(menu).has(anchor), "Removing an earlier file preserves the visible anchor: " + label)
				# Rename the top visible file so natural sorting moves it to the directory's beginning.
				before = menu.scroll; index = menu._first_line() * menu._cols()
				var old_uri := str(menu.rows[index].uri)
				menu.file_actions.toggle(menu.rows[index]); start = Time.get_ticks_usec()
				rename_selected(menu, "00000-renamed.mp4")
				var rename_ms := (Time.get_ticks_usec() - start) / 1000.0
				check(menu.rows[0].title == "00000-renamed.mp4" and not menu.rows.any(func(row): return row.uri == old_uri), "Only renamed row is inserted into correct sorted position: " + label)
				check(menu.scroll > 0 and absf(menu.scroll - before) <= 1.0, "Renaming to the first sort position does not jump to it: " + label)
				check(menu.rebuilds == rebuilds and menu.conversions == converted + 1, "Rename converts exactly one affected row: " + label)
				check(not menu.platform.calls.any(func(call): return call.operation in ["local_browse", "smb_browse", "sort"]), "Successful local/SMB mutations do not re-fetch the folder: " + label)
				check(not menu.file_entry_snapshots().any(func(entries): return entries.any(func(entry): return str(entry.get("uri", "")) == old_uri)), "Playback snapshot uses the renamed identity: " + label)
				# At the end only the necessary range clamp may move the viewport backward.
				menu._set_scroll(menu._max_scroll()); menu.file_actions.toggle(menu.rows.back()); delete_selected(menu); respond_delete(menu)
				check(menu.scroll == menu._max_scroll() and menu.scroll > 0, "Deleting the final file stays at the remaining end: " + label)
				measurements.append({"source": source, "count": count, "view": view, "confirmed_delete_ms": delete_ms, "rename_workflow_ms": rename_ms,
					"full_rebuilds": menu.rebuilds - rebuilds, "converted_rows": menu.conversions - converted})
				dispose(menu)

func cloud_reply(menu: Node3D, entries: Array, total: int = 4999) -> void:
	var request: Dictionary = menu.platform.calls.back()
	menu.platform.respond(menu.platform.calls.size(), "ready", {"path": "/fixture/Movies", "offset": request.offset,
		"order": request.order, "entries": entries, "page_size": 48, "next_offset": request.offset + entries.size() if total > request.offset + entries.size() else -1, "total": total})

func cloud_cases() -> void:
	for view in ["grid-full", "list-full", "list-compact"]:
		var menu := fixture(Library.Section.CLOUD, 48, view)
		var before: float = menu.scroll; var index: int = menu._first_line() * menu._cols()
		menu.file_actions.toggle(menu.rows[index]); delete_selected(menu); respond_delete(menu)
		check(menu._cloud_page == 4 and menu.platform.calls.back().operation == "sort" and menu.platform.calls.back().offset == 192, "Cloud deletion requests the current page, not page zero: " + view)
		check(menu._cloud_offsets == [0, 48, 96, 144, 192] and menu.scroll > 0 and absf(menu.scroll - before) <= 1.0, "Cloud pagination and neighborhood survive pending refresh: " + view)
		var entries: Array = menu._cloud_entries.duplicate(true); entries.append(files("cloud://fixture/Movies/", 241, 1)[0])
		cloud_reply(menu, entries)
		check(menu._cloud_page == 4 and menu.scroll > 0 and absf(menu.scroll - before) <= 1.0, "Authoritative page response preserves the viewport: " + view)
		before = menu.scroll; menu.file_actions.toggle(menu.rows[menu._first_line() * menu._cols()])
		rename_selected(menu, "00000-renamed.mp4")
		check(menu.platform.calls.back().offset == 192 and menu._cloud_page == 4 and menu.scroll > 0, "Cloud rename keeps the active page: " + view)
		cloud_reply(menu, menu._cloud_entries.duplicate(true))
		check(absf(menu.scroll - before) <= 1.0, "Cloud rename response keeps the old neighborhood: " + view)
		dispose(menu)
		# Empty a short final page as a batch; the previous page opens at its end.
		menu = fixture(Library.Section.CLOUD, 2, view)
		menu._cloud_page = 104; menu._cloud_offsets.clear()
		for page in 105: menu._cloud_offsets.append(page * 48)
		menu._cloud_total = 4994; menu._cloud_next = -1
		menu._cloud_entries = files("cloud://fixture/Movies/", 4993, 2); menu.refresh()
		menu.file_actions.toggle(menu.rows[0]); menu.file_actions.toggle(menu.rows[1]); delete_selected(menu)
		respond_delete(menu)
		check(menu.platform.calls.back().operation == "delete", "Batch waits until its final mutation before refreshing: " + view)
		respond_delete(menu)
		check(menu.platform.calls.back().operation == "sort" and menu.platform.calls.back().offset == 4944, "An emptied final page refreshes the adjacent previous page: " + view)
		cloud_reply(menu, files("cloud://fixture/Movies/", 4945, 48), 4992)
		check(menu._cloud_page == 103 and menu.scroll == menu._max_scroll() and menu.scroll > 0, "Previous page lands at its end instead of the start: " + view)
		dispose(menu)

func incremental_sort_cases() -> void:
	for order in ["name_asc", "name_desc", "modified_asc", "modified_desc", "size_asc", "size_desc"]:
		var menu := fixture(Library.Section.LOCAL, 60, "grid-full")
		for index in menu._local_entries.size():
			menu._local_entries[index].modified = (index % 3) * 10
			menu._local_entries[index].size = (index % 5) * 100
		menu._local_entries.append({"id": "/disk/folder", "title": "folder", "container": true})
		menu.file_actions.orders[str(Library.Section.LOCAL)] = order; menu.refresh()
		menu.file_actions.toggle(menu.rows[menu.rows.size() / 2]); rename_selected(menu, "00000-renamed.mp4")
		var expected: Array = menu.rows.duplicate(true)
		expected.sort_custom(func(a, b): return Actions.Order.before(a, b, order))
		check(menu.rows.map(func(row): return Library.Presentation.key(row)) == expected.map(func(row): return Library.Presentation.key(row)), "Incremental rename matches complete sort including folders: " + order)
		dispose(menu)

func run() -> void:
	preload("res://scripts/i18n.gd").use("en")
	local_cases(); cloud_cases(); incremental_sort_cases()
	var output := OS.get_environment("THRU3D_MUTATION_REPORT")
	if not output.is_empty(): FileAccess.open(output, FileAccess.WRITE).store_string(JSON.stringify({"checks": checks, "failures": failures, "measurements": measurements,
		"scope": "Synthetic desktop mutation responses only; no real file operations or headset timing"}, "\t"))
	print("File mutation position checks=%d failures=%d" % [checks, failures.size()])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)
