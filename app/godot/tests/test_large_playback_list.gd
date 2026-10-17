extends SceneTree
## Synthetic directory stress: no media, network requests or headset settings are touched.
const Library := preload("res://scripts/library_menu.gd")
var checks := 0
var failures: Array[String] = []
var measurements: Array[Dictionary] = []
var selection_measurements: Array[Dictionary] = []

class CountedLibrary extends "res://scripts/library_menu.gd":
	var rebuilds := 0
	var conversions := 0
	func _rebuild_rows() -> void:
		rebuilds += 1
		super()
	func _entry_row(entry: Dictionary) -> Dictionary:
		conversions += 1
		return super(entry)

class SelectionPlatform extends RefCounted:
	var mutations: Array[String] = []
	func media_file_management_enabled(_enabled: bool) -> void: pass
	func media_file_delete(target: String) -> int:
		mutations.append(target)
		return mutations.size()

class CountedActions extends "res://scripts/library_file_actions.gd":
	var key_calls := 0
	var order_calls := 0
	var index_calls := 0
	func row_key(row: Dictionary) -> String:
		key_calls += 1
		return super(row)
	func order() -> String:
		order_calls += 1
		return super()
	func _index_rows() -> void:
		index_calls += 1
		super()

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func _initialize() -> void: call_deferred("run")

func fixture(source: int, count: int, mode: String) -> Node3D:
	var menu := CountedLibrary.new(); root.add_child(menu); menu.set_process(false)
	menu.file_actions = CountedActions.new(menu)
	menu.section = source; menu.view_mode = mode; menu.visible = true
	var entries: Array = []
	var scheme := "file:///disk/"
	match source:
		Library.Section.LOCAL: menu._local_stack = [{"id": "/disk", "title": "Movies"}]
		Library.Section.SMB:
			scheme = "smb://fixture/Movies/"; menu._smb_server = "fixture"; menu._smb_path = "Movies"
		Library.Section.DLNA:
			scheme = "dlna://fixture/"; menu._dlna_server = "fixture"
		Library.Section.CLOUD:
			scheme = "cloud://fixture/Movies/"; menu._cloud_stack = [{"id": "/fixture/Movies", "title": "Movies"}]
	# Local/SMB/DLNA sort numerically; a loaded cloud snapshot keeps provider order.
	for i in range(count, 0, -1):
		entries.append({"id": "%05d.mp4" % i, "uri": scheme + "%05d.mp4" % i,
			"title": "[Studio] 视频 %05d — Long media filename.mp4" % i, "size": 123456789, "modified": 1729000000000})
	match source:
		Library.Section.LOCAL: menu._local_entries = entries
		Library.Section.SMB: menu._smb_entries = entries
		Library.Section.DLNA: menu._dlna_entries = entries
		Library.Section.CLOUD: menu._cloud_entries = entries
	return menu

func row_buttons(menu: Node3D) -> Array:
	return menu._buttons.filter(func(button): return menu._row_target(button.target))

func click(menu: Node3D, target: int) -> bool:
	var matches: Array = menu._buttons.filter(func(button): return button.target == target and button.node.visible and button.enabled)
	if matches.is_empty(): return false
	var node: Node3D = matches[0].node
	var origin := node.global_position + node.global_basis.z * 0.3
	var direction := -node.global_basis.z
	menu.press_pointer("right_hand", origin, direction, true)
	menu.release_pointer("right_hand", origin, direction, true)
	return true

func select_index(menu: Node3D, index: int) -> bool:
	menu._set_scroll(float(index / menu._cols()))
	var slot: int = index - menu._first_line() * menu._cols()
	return click(menu, (menu.file_actions.SELECT_BASE if menu.view_mode == "list" else Library.ROW_BASE) + slot)

func selection_cases() -> void:
	for source in [Library.Section.LOCAL, Library.Section.SMB, Library.Section.CLOUD]:
		for count in [300, 1500, 5000]:
			# The edit button is in the full grid browser; lists have direct checkboxes.
			for view in ["grid-full", "list-full", "list-compact"]:
				var label := "%s/%d/%s" % [source, count, view]
				var menu := fixture(source, count, "grid" if view == "grid-full" else "list")
				var platform := SelectionPlatform.new(); menu.platform = platform
				menu.compact = view == "list-compact"
				var entries: Array = menu._local_entries if source == Library.Section.LOCAL else (menu._smb_entries if source == Library.Section.SMB else menu._cloud_entries)
				for entry in entries: entry.can_delete = true
				menu.file_actions.set_enabled(true); menu.refresh()
				var actions: CountedActions = menu.file_actions
				var chosen: Array[String] = []
				menu.chosen.connect(func(uri, _title): chosen.append(uri))
				var rebuilds: int = menu.rebuilds
				actions.order_calls = 0; actions.index_calls = 0
				if view == "grid-full":
					check(click(menu, actions.EDIT_MODE) and actions.editing, "Actual ray enters grid editing: " + label)
				var start := Time.get_ticks_usec()
				check(select_index(menu, count - 1), "Ray selects the final file: " + label)
				var select_ms := (Time.get_ticks_usec() - start) / 1000.0
				var tail: String = menu.rows.back().uri
				check(actions.selected == tail and actions.selected_rows().size() == 1, "Tail selection resolves exactly one current item: " + label)
				check(select_index(menu, 0) and select_index(menu, count / 2), "Ray adds selections across distant screens: " + label)
				var expected := [str(menu.rows[0].uri), str(menu.rows[count / 2].uri), tail]
				check(actions.selected_rows().map(func(row): return str(row.uri)) == expected, "Selected files preserve directory order instead of click order: " + label)
				check(actions.selected_row().is_empty() and actions.can_delete_selection(), "Multiple selection has no single rename target: " + label)
				check(select_index(menu, count / 2) and select_index(menu, 0) and actions.selected == tail, "Ray deselects while retaining the offscreen tail: " + label)
				var max_keys := 0; var scroll_ms: Array[float] = []
				for step in 12:
					actions.key_calls = 0; start = Time.get_ticks_usec()
					menu._set_scroll(floorf(menu._max_scroll() * float(step) / 11.0))
					scroll_ms.append((Time.get_ticks_usec() - start) / 1000.0)
					max_keys = maxi(max_keys, actions.key_calls)
					check(actions.key_calls < 200 + 8 * menu._drawn_slots(), "Selected scrolling checks bounded visible/selected identities: " + label)
				check(menu.rebuilds == rebuilds and actions.order_calls == 0 and actions.index_calls == 0, "Editing, selecting and scrolling never rebuild/sort/reindex directory data: " + label)
				menu._set_scroll(0); menu.stick_scroll(-1.0, 0.016)
				check(menu.scroll > 0 and chosen.is_empty() and platform.mutations.is_empty(), "Editing scroll neither plays nor writes a file: " + label)
				check(select_index(menu, count - 1) and not actions.has_selection(), "Ray cancels the final selection: " + label)
				if view == "grid-full": check(click(menu, actions.EDIT_MODE) and not actions.editing, "Actual ray exits grid editing: " + label)
				# An authoritative refresh must replace indexed metadata and prune removed objects.
				actions.toggle(menu.rows[0]); var selected_uri := str(menu.rows[0].uri)
				for entry in entries:
					if str(entry.uri) == selected_uri: entry.can_delete = false
				menu.refresh()
				check(actions.has_selection() and not actions.can_delete_selection(), "Refresh uses updated permission metadata: " + label)
				for index in range(entries.size() - 1, -1, -1):
					if str(entries[index].uri) == selected_uri: entries.remove_at(index)
				menu.refresh()
				check(not actions.has_selection() and actions.selected_rows().is_empty(), "Refresh removes vanished selected identities: " + label)
				selection_measurements.append({"source": source, "count": count, "view": view, "tail_select_ms": select_ms,
					"selected_scroll_mean_ms": float(scroll_ms.reduce(func(a, b): return a + b, 0.0)) / scroll_ms.size(), "max_identity_checks_per_scroll": max_keys})
				menu.free()

func selection_identity_cases() -> void:
	var menu := fixture(Library.Section.CLOUD, 3, "grid")
	var platform := SelectionPlatform.new(); menu.platform = platform
	menu._cloud_entries = [{"uri": "cloud://fixture/Movies/same.mp4", "title": "same.mp4", "cloud_id": "a", "can_delete": true},
		{"uri": "cloud://fixture/Movies/same.mp4", "title": "same.mp4", "cloud_id": "b", "can_delete": true}]
	menu.file_actions.set_enabled(true); menu.refresh()
	menu.file_actions.toggle(menu.rows[1])
	check(menu.file_actions.selected_rows().size() == 1 and menu.file_actions.selected_row().cloud_id == "b", "Indexed selection distinguishes objects sharing a URI")
	var copy: Dictionary = menu.file_actions.selected_row(); copy.can_delete = false
	check(menu.file_actions.can_delete_selection(), "Selection results are copies of current metadata")
	menu._cloud_entries[1].cloud_id = "replacement"; menu.refresh()
	check(not menu.file_actions.has_selection(), "A replacement provider identity cannot inherit selection")
	menu._cloud_entries[1].cloud_id = "a"; menu.refresh(); menu.file_actions.toggle(menu.rows[0])
	check(menu.file_actions.selected_rows().size() == 2 and menu.file_actions.selected_row().is_empty(), "Duplicate current identities retain the existing multiple-row behavior")
	menu.rows.reverse()
	menu.rows[0].cloud_id = "changed-without-refresh"
	check(menu.file_actions.selected_rows().size() == 1, "Cached indices validate current identity before returning metadata")
	menu.free()

func run() -> void:
	preload("res://scripts/i18n.gd").use("en")
	for source in [Library.Section.LOCAL, Library.Section.SMB, Library.Section.DLNA, Library.Section.CLOUD]:
		for count in [300, 1500, 5000]:
			for mode in ["list", "grid"]:
				var label := "%s/%d/%s" % [source, count, mode]
				var menu := fixture(source, count, mode)
				var actions: CountedActions = menu.file_actions
				menu.refresh()
				check(menu.rows.size() == count, "No directory limit or dropped files: " + label)
				check(actions.order_calls == (0 if source == Library.Section.CLOUD else 1), "Resolve sort preference once per sort: " + label)
				check(menu.rows[0].title.contains("%05d" % (count if source == Library.Section.CLOUD else 1)), "Preserve numeric/provider order: " + label)
				var current := {"uri": str(menu.rows.back().uri), "calls": 0}
				menu.current_file_provider = func(): current.calls += 1; return current.uri
				check(menu._current_file_index(menu.rows) == count - 1 and current.calls == 1, "Read playing identity once for a whole directory: " + label)
				menu.remember_playback_context()
				var start := Time.get_ticks_usec()
				menu.show_playback_files(true)
				var open_us := Time.get_ticks_usec() - start
				check(menu.scroll == menu._max_scroll(), "Open at the playing final item: " + label)
				var buttons := row_buttons(menu)
				check(buttons.size() <= (6 if mode == "list" else 9), "Geometry stays bounded to visible rows: " + label)
				check(buttons.any(func(button): return button.node.visible and button.base_color == Library.SELECTED), "Playing item is visible and highlighted: " + label)
				# Initialize the two persistent rays and tooltip before checking for retained nodes.
				var first_node: Node3D = buttons.filter(func(button): return button.node.visible)[0].node
				for hand in ["left_hand", "right_hand"]:
					menu.update_pointer(hand, first_node.global_position + first_node.global_basis.z * 0.3, -first_node.global_basis.z, true)
				var nodes := menu.get_child_count()
				var chosen: Array[String] = []
				menu.chosen.connect(func(uri, _title): chosen.append(uri))
				actions.key_calls = 0; actions.order_calls = 0
				var scroll_us: Array[int] = []
				for step in 12:
					start = Time.get_ticks_usec()
					menu._set_scroll(floorf(menu._max_scroll() * float(step) / 11.0))
					scroll_us.append(Time.get_ticks_usec() - start)
					check(row_buttons(menu).size() <= menu._drawn_slots(), "Scroll retains bounded row geometry: " + label)
					menu.update_pointer("left_hand", Vector3.ZERO, Vector3.FORWARD, true)
					menu.update_pointer("right_hand", Vector3.ZERO, Vector3.FORWARD, true)
				menu._set_scroll(0)
				menu.stick_scroll(-1.0, 0.016)
				check(menu.scroll > 0 and chosen.is_empty(), "Stick scrolls without choosing playback: " + label)
				check(actions.key_calls == 0 and actions.order_calls == 0, "Unselected scrolling never scans directory identities or sorts: " + label)
				check(menu.get_child_count() == nodes, "Scrolling retains no old row nodes: " + label)
				menu._set_scroll(menu._max_scroll())
				buttons = row_buttons(menu)
				var last: Dictionary = buttons.filter(func(button): return button.node.visible).back()
				var expected := str(menu.rows[menu._first_line() * menu._cols() + last.target - Library.ROW_BASE].uri)
				var node: Node3D = last.node
				var origin := node.global_position + node.global_basis.z * 0.3
				menu.press_pointer("right_hand", origin, -node.global_basis.z, true)
				menu.release_pointer("right_hand", origin, -node.global_basis.z, true)
				check(chosen == [expected], "Ray selects the correct tail item after scrolling: " + label)
				# Stale selections still cannot become an actionable current file.
				actions.selection = {"missing": {"uri": "file:///missing.mp4"}}
				check(not actions.has_selection() and actions.selected_rows().is_empty(), "Ignore stale selections: " + label)
				actions.reconcile()
				check(actions.selection.is_empty(), "Reconcile removes absent identities: " + label)
				measurements.append({"source": source, "count": count, "mode": mode, "open_ms": open_us / 1000.0,
					"scroll_max_ms": scroll_us.max() / 1000.0, "scroll_mean_ms": float(scroll_us.reduce(func(a, b): return a + b, 0)) / scroll_us.size() / 1000.0})
				menu.free()
	selection_cases()
	selection_identity_cases()
	var report := {"state": "passed" if failures.is_empty() else "failed", "checks": checks, "failures": failures,
		"measurements": measurements, "selection_measurements": selection_measurements, "scope": "Synthetic desktop Godot directories; no real video decoding or headset timing"}
	var output := OS.get_environment("THRU3D_PLAYLIST_PERFORMANCE_REPORT")
	if not output.is_empty(): FileAccess.open(output, FileAccess.WRITE).store_string(JSON.stringify(report, "\t"))
	print("Large playback list checks=%d failures=%d" % [checks, failures.size()])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)
