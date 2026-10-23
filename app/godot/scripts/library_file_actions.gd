extends RefCounted
## Opt-in list checkboxes and serial confirmed mutations. Requests outlive dismissal.
const Order := preload("res://scripts/library_order.gd")
const SORT := 9100
const EDIT_MODE := 9101
const DELETE_FILE := 9102
const CANCEL := 9103
const CONFIRM := 9104
const CHECK_STATUS := 9105
const FOLDERS_FIRST := 9106
const SELECT_BASE := 9200
const ORDER_BASE := 9120
var menu: Node3D
var editing := false
var enabled := false
var settings_return := {}
var selection := {}
var _row_indices := {} # Identity -> row indices, rebuilt with directory data, not on each tick/click.
var selected: String:
	get: return str(selection.values()[0].get("uri", "")) if selection.size() == 1 else ""
	set(value):
		selection.clear()
		if value.is_empty(): return
		_index_rows()
		for row in menu.rows:
			if not value.is_empty() and row_uri(row) == value:
				var copy: Dictionary = row.duplicate(true); copy.uri = value
				selection[row_key(row)] = copy
var selection_scope := ""
var deletions: Array[Dictionary] = []
var delete_index := 0
var prepare_index := 0
var batch_running := false
var deleted_count := 0
var modal := ""
var target: Dictionary = {}
var pending := 0
var checking := false
var uncertain := false
var failed := false
var preparing := false
var plan_ready := false
var orders := {}
var cloud_requested_order := ""
var cloud_committed_order := ""
var cloud_rollback := {}
const Rename := preload("res://scripts/library_rename.gd")
var rename: RefCounted

func _init(owner: Node3D) -> void:
	menu = owner; rename = Rename.new(owner)

func scope() -> String:
	if menu.archives.browsing: return JSON.stringify(["archive", menu.archives.target.get("uri", ""), menu.archives.directory]).sha256_text()
	var location: Array = [menu.section]
	match menu.section:
		menu.Section.LOCAL: location.append(menu._local_path())
		menu.Section.SMB: location.append_array([menu._smb_server, menu._smb_path])
		menu.Section.DLNA: location.append_array([menu._dlna_server, str(menu._dlna_stack.back().id) if not menu._dlna_stack.is_empty() else "0"])
		menu.Section.CLOUD: location.append(menu._cloud_path())
	return JSON.stringify(location).sha256_text()

func defaults() -> Dictionary:
	var saved: Variant = orders.get("default", {})
	return {"order": Order.normalize(saved.get("order", "name_asc")), "folders_first": bool(saved.get("folders_first", true))} if saved is Dictionary else {"order": "name_asc", "folders_first": true}

func preferences() -> Dictionary:
	var directories: Dictionary = orders.get("directories", {})
	var saved: Variant = directories.get(scope(), {})
	if saved is Dictionary and not saved.is_empty(): return saved
	var fallback := defaults()
	# Preserve old source preferences on migration, until a global default is chosen.
	if not orders.has("default"): fallback.order = Order.normalize(orders.get(str(menu.section), fallback.order))
	return fallback

func folders_first() -> bool:
	return bool(preferences().get("folders_first", true))

func grouping_supported() -> bool:
	if menu.archives.browsing: return true
	# Other cloud APIs do not expose a verified directory-wide grouping switch.
	# Do not manufacture it by reordering just one API page or crawling all pages.
	return menu.section != menu.Section.CLOUD or menu.cloud_pagination.provider() in ["", "115_open", "webdav"]

func save_preferences(value: Dictionary) -> void:
	if not orders.get("directories") is Dictionary: orders["directories"] = {}
	if orders.directories.get(scope(), {}) == value: return
	orders.directories[scope()] = value.duplicate(true)
	menu.setting_changed.emit("library_orders", orders.duplicate(true))

func set_default(key: String, value: Variant) -> void:
	var saved := defaults()
	if key == "library_default_order": saved.order = Order.normalize(value)
	else: saved.folders_first = bool(value)
	orders["default"] = saved
	menu.setting_changed.emit("library_orders", orders.duplicate(true))

func settings_rows() -> Array:
	var options: Array = []
	for i in Order.ORDERS.size(): options.append({"value": Order.ORDERS[i], "label": Order.LABELS[i]})
	var sort_row: Dictionary = menu._choice_row("Default sort order", "library_default_order", defaults().order, options)
	sort_row.dropdown = true
	return [sort_row,
		menu._choice_row("Folders first by default", "library_default_folders_first", defaults().folders_first,
		[{"value": false, "label": "Off"}, {"value": true, "label": "On"}])]

func folder() -> bool:
	if menu.archives.browsing: return false # Archive contents are read-only.
	return (menu.section == menu.Section.LOCAL and not menu._local_stack.is_empty()) or \
		(menu.section == menu.Section.SMB and not menu._smb_server.is_empty() and not menu._smb_path.is_empty()) or \
		(menu.section == menu.Section.CLOUD and not menu._cloud_stack.is_empty() and menu.cloud_accounts.mode.is_empty())

## Read existing listing metadata only. Local write flags also depend on the opt-in setting.
func entry_state() -> String:
	if not folder() or menu.audio_import_mode or menu.subtitle_picker_mode or menu.image_picker_mode or menu.cloud_search.active: return ""
	if menu.section == menu.Section.LOCAL:
		var volume: Dictionary = menu._local_volume()
		if menu._local_path().begins_with("usb://") or menu._local_path().begins_with("content://") or volume.get("removable", false) or volume.get("read_only", false): return "read_only"
	var entries: Array = {menu.Section.LOCAL: menu._local_entries, menu.Section.SMB: menu._smb_entries, menu.Section.CLOUD: menu._cloud_entries}.get(menu.section, [])
	var supported: bool = menu.PlatformMethods.supports(menu.platform, "media_file_delete") or \
		(menu.PlatformMethods.supports(menu.platform, "media_file_rename_prepare") and menu.PlatformMethods.supports(menu.platform, "media_file_rename"))
	if not supported: return ""
	if entries.any(func(row): return row.get("management_available", false) or row.get("can_delete", false) or row.get("can_rename", false)): return "available"
	return "unavailable" if menu.section == menu.Section.LOCAL and not entries.is_empty() else ""

func open_settings() -> void:
	var context := {"section": menu.section, "tab": menu.tab, "compact": menu.compact,
		"view_mode": menu.view_mode, "anchor": menu.capture_position(), "status": menu.status}
	menu.compact = false
	menu._activate(menu.NAV_BASE + menu.Section.SETTINGS)
	settings_return = context
	menu.refresh()

func return_from_settings(redraw: bool = true) -> bool:
	if settings_return.is_empty() or menu.section != menu.Section.SETTINGS: return false
	var context := settings_return.duplicate(true)
	settings_return.clear(); menu.choices.reset()
	menu.section = context.section; menu.tab = context.tab; menu.compact = context.compact
	menu.view_mode = context.view_mode; menu.status = context.status
	menu._position_to_restore = context.anchor
	if redraw: menu.refresh()
	else: menu._rebuild_rows() # Dismissal must capture the restored files, not the Settings rows.
	# Local capability flags must be read again after changing the global write gate.
	if menu.section == menu.Section.LOCAL and menu.PlatformMethods.supports(menu.platform, "media_local_browse"): menu._load_section()
	return true

func order() -> String:
	var value := Order.normalize(preferences().get("order", "name_asc"))
	return value if supports_order(value) else "name_asc"

func sortable() -> bool:
	if menu.archives.browsing: return true
	return folder() or (menu.section == menu.Section.DLNA and not menu._dlna_server.is_empty())

func supports_order(value: String) -> bool:
	if menu.archives.browsing: return value in Order.ORDERS and value != "source"
	if menu.section == menu.Section.DLNA: return value in ["name_asc", "name_desc"]
	if menu.section == menu.Section.CLOUD and not menu._cloud_stack.is_empty():
		var supported: Variant = menu._cloud_stack[0].get("sort_orders", Order.ORDERS)
		if supported is Array and value not in supported: return false
	return value in Order.ORDERS and (value != "source" or menu.section == menu.Section.CLOUD)

func load(value: Dictionary) -> void:
	orders = value.duplicate(true)

func reset() -> void:
	editing = false; selection.clear(); modal = ""
	_row_indices.clear()
	cloud_requested_order = ""; cloud_rollback = {}
	if pending == 0 and not uncertain:
		target = {}; deletions.clear(); batch_running = false

func selected_row() -> Dictionary:
	var rows := selected_rows()
	return rows[0] if rows.size() == 1 else {}

func row_key(row: Dictionary) -> String:
	return JSON.stringify([row_uri(row), str(row.get("cloud_id", ""))])

func selected_rows() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if selection.is_empty(): return result
	var indices: Array[int] = []
	for key in selection:
		for index: int in _row_indices.get(key, []):
			if index < menu.rows.size() and row_key(menu.rows[index]) == key: indices.append(index)
	indices.sort()
	for index in indices:
		var row: Dictionary = menu.rows[index]
		var copy: Dictionary = row.duplicate(true); copy.uri = row_uri(row)
		result.append(copy)
	return result

func list_management() -> bool:
	return enabled and menu.view_mode == "list" and folder() and not menu.cloud_search.active

func has_selection() -> bool:
	# Compact row sizing must inspect selected identities, never scan the whole directory.
	for key in selection:
		if _current_index(key) >= 0: return true
	return false

func _current_index(key: String) -> int:
	for index: int in _row_indices.get(key, []):
		if index < menu.rows.size() and row_key(menu.rows[index]) == key: return index
	return -1

func _index_rows() -> void:
	_row_indices.clear()
	for index in menu.rows.size():
		var key := row_key(menu.rows[index])
		if not _row_indices.has(key): _row_indices[key] = []
		_row_indices[key].append(index)

func needs_footer() -> bool:
	return has_selection() or pending > 0 or uncertain

func is_selected(row: Dictionary) -> bool:
	return selection.has(row_key(row))

func reconcile() -> void:
	var context := str([menu.section, menu._local_path(), menu._smb_server, menu._smb_path, menu._cloud_path(), menu._cloud_page, menu.media_filter, menu.cloud_search.active])
	if selection_scope != context:
		selection.clear(); selection_scope = context
	if enabled or not selection.is_empty(): _index_rows()
	else: _row_indices.clear()
	for key in selection.keys():
		if not _row_indices.has(key): selection.erase(key)

func selection_target(id: int) -> bool:
	return id >= SELECT_BASE and id < SELECT_BASE + menu._drawn_slots()

func idle() -> bool:
	return enabled and pending == 0 and not uncertain and not (menu.section == menu.Section.CLOUD and menu._cloud_busy)

func selectable(row: Dictionary) -> bool:
	return not row_uri(row).is_empty() and (delete_supported(row) or rename.supported(row))

func delete_supported(row: Dictionary) -> bool:
	return row.get("can_delete", false) and menu.PlatformMethods.supports(menu.platform, "media_file_delete")

func can_delete_selection() -> bool:
	var rows := selected_rows()
	return idle() and not rows.is_empty() and rows.all(func(row): return delete_supported(row))

func draw_checkbox(row_target: int, row: Dictionary, centre: Vector2) -> void:
	if not list_management(): return
	var available := selectable(row)
	menu._button(SELECT_BASE + row_target - menu.ROW_BASE, "", centre, Vector2(0.075, 0.086), available and idle(), "check" if is_selected(row) else "checkbox", is_selected(row), menu._list)
	menu._buttons.back()["list_row"] = row_target
	menu._buttons.back()["hover_disabled"] = not available
	menu._tips[SELECT_BASE + row_target - menu.ROW_BASE] = menu.I18n.t("Select" if available else "File management unavailable for this item")

func row_uri(row: Dictionary) -> String:
	return str(row.get("delete_uri", "")) if row.get("folder", false) else str(row.get("uri", ""))

func set_enabled(value: bool) -> void:
	enabled = value
	sync_platform()
	if not enabled: reset()

func sync_platform() -> void:
	if menu.PlatformMethods.supports(menu.platform, "media_file_management_enabled"):
		menu.platform.media_file_management_enabled(enabled)

func can_delete(row: Dictionary) -> bool:
	return idle() and delete_supported(row)

func select(row: Dictionary) -> bool:
	if not enabled or not editing or list_management(): return false
	toggle(row)
	return true

func toggle(row: Dictionary) -> void:
	if not idle(): return
	if _row_indices.is_empty(): _index_rows()
	var key := row_key(row)
	var index := _current_index(key)
	if index < 0 or not selectable(menu.rows[index]): return
	if selection.has(key): selection.erase(key)
	else:
		var copy: Dictionary = menu.rows[index].duplicate(true); copy.uri = row_uri(copy)
		selection[key] = copy
	menu.status = ""; menu.refresh_file_selection()

func sort_rows() -> void:
	if not sortable(): return
	if menu.section == menu.Section.CLOUD and not menu.archives.browsing: return
	var selected_order := order()
	var grouped := folders_first()
	save_preferences({"order": selected_order, "folders_first": grouped})
	menu.rows.sort_custom(func(a, b): return Order.before(a, b, selected_order, grouped))

func choose_order(value: String, grouped: Variant = null) -> void:
	if not sortable() or not supports_order(value): return
	if grouped != null and not grouping_supported(): return
	var priority := folders_first() if grouped == null else bool(grouped)
	if menu.section == menu.Section.CLOUD and not menu.archives.browsing:
		if not menu.PlatformMethods.supports(menu.platform, "media_cloud_sorted_page") and not menu.PlatformMethods.supports(menu.platform, "media_cloud_directory_page") and not menu.cloud_pagination.supported(): return
		cloud_requested_order = value if priority or not grouping_supported() else "mixed_" + value
		cloud_rollback = {"offsets": menu._cloud_offsets.duplicate(), "page": menu._cloud_page}
		menu._cloud_positions.erase(menu._cloud_position_key())
		menu._cloud_offsets.assign([0])
		menu._load_cloud(false, false, 0)
	else:
		save_preferences({"order": value, "folders_first": priority})
		menu.scroll = 0.0
	modal = ""; selected = ""
	menu.refresh()
	if menu.section != menu.Section.CLOUD or menu.archives.browsing: menu.directory_order_changed.emit()

func commit_cloud(value: String) -> void:
	cloud_committed_order = value; cloud_requested_order = ""
	cloud_rollback = {}
	if not value.is_empty():
		save_preferences({"order": Order.normalize(value.trim_prefix("mixed_")), "folders_first": not value.begins_with("mixed_") if grouping_supported() else folders_first()})

func cloud_order() -> String:
	if not cloud_requested_order.is_empty(): return cloud_requested_order
	return order() if folders_first() or not grouping_supported() else "mixed_" + order()

func cloud_failed() -> void:
	if not cloud_rollback.is_empty():
		menu._cloud_offsets.assign(cloud_rollback.offsets)
		menu._cloud_requested_page = int(cloud_rollback.page)
	cloud_requested_order = ""; cloud_rollback = {}

func action(id: int) -> bool:
	if not modal.is_empty():
		if modal == "rename": rename.action(id); return true
		if id == CANCEL: modal = ""; menu.refresh_file_selection()
		elif modal == "sort" and id == FOLDERS_FIRST: choose_order(order(), not folders_first())
		elif modal == "sort" and id >= ORDER_BASE and id < ORDER_BASE + Order.ORDERS.size(): choose_order(Order.ORDERS[id - ORDER_BASE])
		elif modal == "delete" and id == CONFIRM and idle() and plan_ready:
			batch_running = true; dispatch(false)
		elif id == CHECK_STATUS and uncertain and pending == 0: dispatch(true)
		return true
	if selection_target(id):
		var index: int = menu._first_line() * menu._cols() + id - SELECT_BASE
		if list_management() and index < menu.rows.size(): toggle(menu.rows[index])
		return true
	if id == SORT and sortable() and not editing and pending == 0:
		modal = "sort"; menu.refresh_file_selection(); return true
	if id == EDIT_MODE:
		if (entry_state() == "available" or (enabled and editing and folder())) and pending == 0 and not uncertain and not (menu.section == menu.Section.CLOUD and menu._cloud_busy):
			if not enabled: open_settings()
			elif not list_management(): editing = not editing; selection.clear(); menu.refresh_file_selection()
		return true
	if id == DELETE_FILE:
		if can_delete_selection():
			deletions = selected_rows().duplicate(true); delete_index = 0; prepare_index = 0
			deleted_count = 0; batch_running = false; failed = false; plan_ready = false; modal = "delete"
			prepare_folder()
			menu.refresh_file_selection()
		return true
	if id == Rename.OPEN:
		var row := selected_row()
		if rename.can_rename(row): rename.open(row)
		return true
	if id == CHECK_STATUS and uncertain:
		modal = "delete"; menu.refresh_file_selection(); return true
	return false

func prepare_folder() -> void:
	while prepare_index < deletions.size():
		if deletions[prepare_index].get("folder", false):
			if not menu.PlatformMethods.supports(menu.platform, "media_file_delete_prepare"):
				failed = true; menu.status = "File deletion unavailable for this source"; return
			target = deletions[prepare_index]
			preparing = true
			pending = int(menu.platform.media_file_delete_prepare(JSON.stringify(target)))
			if pending <= 0: pending = 0; preparing = false; failed = true
			return
		prepare_index += 1
	preparing = false; plan_ready = true
	if delete_index < deletions.size(): target = deletions[delete_index]

func dispatch(inspect: bool) -> void:
	if target.is_empty() or pending > 0 or (not inspect and not enabled): return
	checking = inspect
	var method := "media_file_delete_status" if inspect else "media_file_delete"
	if not menu.PlatformMethods.supports(menu.platform, method): return
	# Close readers only for the item about to be written, after final confirmation.
	if not inspect: menu.file_delete_preparing.emit(str(target.uri))
	pending = int(menu.platform.call(method, JSON.stringify(target)))
	if pending <= 0:
		pending = 0; failed = true; batch_running = false; menu.status = "File deletion failed"
	menu.refresh_file_selection()

func receive(id: int, payload: String) -> bool:
	if rename.receive(id, payload): return true
	if pending <= 0 or id != pending: return false
	pending = 0
	var result: Variant = JSON.parse_string(payload)
	if not result is Dictionary or str(result.get("uri", "")) != str(target.get("uri", "")):
		uncertain = not preparing; failed = true; batch_running = false; preparing = false
		menu.status = "Delete result needs checking"
	elif preparing:
		preparing = false
		if result.get("state") == "ready" and result.get("preview", false):
			for key in ["plan", "files", "folders"]: target[key] = result.get(key, 0)
			target["counts_known"] = result.get("counts_known", true)
			prepare_index += 1; prepare_folder()
		else:
			failed = true; menu.status = str(result.get("error", "File deletion failed"))
	elif result.get("state") == "ready" and (result.get("deleted", false) or (checking and not result.get("exists", true))):
		var uri := str(target.uri)
		uncertain = false; failed = false; selection.erase(row_key(target))
		menu.remove_file_rows(target)
		menu.file_deleted.emit(uri)
		deleted_count += 1; delete_index += 1; checking = false
		if batch_running and enabled and delete_index < deletions.size():
			target = deletions[delete_index]; dispatch(false); return true
		batch_running = false; modal = ""; target = {}; deletions.clear()
		menu.status = "File deleted" if deleted_count == 1 else menu.I18n.t("%d items deleted") % deleted_count
		# Refresh cloud pages after the entire batch; do not disturb snapshots mid-batch.
		if menu.section == menu.Section.CLOUD and enabled:
			menu.refresh_cloud_mutation()
	elif checking and result.get("state") == "ready" and result.get("changed", false):
		uncertain = false; failed = true; batch_running = false; modal = ""; selection.clear(); target = {}; deletions.clear()
		menu.status = "Cloud file changed. Refresh the folder"
	elif checking and result.get("state") == "ready":
		uncertain = false; failed = true; batch_running = false; menu.status = "File still exists"
		if target.get("folder", false):
			plan_ready = false; prepare_index = delete_index; prepare_folder()
	else:
		uncertain = checking or result.get("state") == "uncertain"
		failed = true; batch_running = false
		menu.status = str(result.get("error", "Delete result needs checking" if uncertain else "File deletion failed"))
	checking = false
	if menu.visible: menu.refresh_file_selection()
	return true

func draw_header() -> void:
	if not sortable(): return
	menu._button(SORT, "", menu._action_position(0.25), Vector2(0.09, 0.065), not editing and pending == 0 and not menu._cloud_busy, "sort")
	menu._tips[SORT] = menu.I18n.t("Sort")
	draw_entry(menu._action_position(0.36))

func draw_entry(position: Vector2) -> void:
	var state := entry_state()
	if enabled and editing and folder(): state = "available"
	if state.is_empty() or list_management(): return
	var available := state == "available"
	menu._button(EDIT_MODE, "", position, Vector2(0.09, 0.065), available and pending == 0 and not uncertain and not (menu.section == menu.Section.CLOUD and menu._cloud_busy), "check" if editing else "select", editing)
	var button: Dictionary = menu._buttons.back()
	button.hover_disabled = true
	if not enabled or not available:
		# This button opens Settings; the badge describes locked editing, not a dead hit target.
		for child in button.node.get_children():
			if child is MeshInstance3D and child.material_override is BaseMaterial3D: child.material_override.albedo_color = menu.MUTED
		var badge: MeshInstance3D = menu._quad(Vector2(0.027, 0.027), Vector3(0.027, -0.018, 0.007), menu.TILE, 15)
		button.node.add_child(badge)
		var lock: MeshInstance3D = menu._icon("lock", Vector3(0, 0, 0.002), 0.023, menu.MUTED, badge)
		lock.material_override.render_priority = 16
		if available:
			menu._tips[EDIT_MODE] = menu.I18n.t("File management is off") + "\n" + menu.I18n.t("Settings") + " → " + menu.I18n.t("General") + " → " + menu.I18n.t("Allow file management")
		else:
			menu._tips[EDIT_MODE] = menu.I18n.t("Read-only" if state == "read_only" else "File management unavailable for this folder")
	else:
		menu._tips[EDIT_MODE] = menu.I18n.t("Done" if editing else "Edit files")

func draw_footer() -> void:
	var rows := selected_rows()
	var compact: bool = menu.compact
	if compact and (pending > 0 or uncertain):
		var status_label: Label3D = menu._label(menu.I18n.t(pending_text()), Vector3(-0.49, -0.285, 0.004), 16)
		status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		if uncertain: menu._button(CHECK_STATUS, menu.I18n.t("Check status"), Vector2(0.32, -0.285), Vector2(0.36, 0.065), pending == 0, "refresh")
		return
	if rows.is_empty(): return
	var y := -0.285 if compact else -0.515
	var left := -0.49 if compact else -0.43
	var label: Label3D = menu._label(menu.I18n.t("%d selected") % rows.size(), Vector3(left, y, 0.004), 16 if compact else 18)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	var row: Dictionary = rows[0] if rows.size() == 1 else {}
	if rename.supported(row) and rows.size() == 1:
		menu._button(Rename.OPEN, menu.I18n.t("Rename"), Vector2(0.09 if compact else 0.38, y), Vector2(0.23, 0.065), rename.can_rename(row), "edit")
	if rows.all(func(item): return delete_supported(item)):
		menu._button(DELETE_FILE, menu.I18n.t("Delete"), Vector2(0.37 if compact else 0.68, y), Vector2(0.24 if compact else 0.28, 0.065), idle(), "trash")

func pending_text() -> String:
	if uncertain: return "Check status"
	if rename.request_id > 0: return "Checking…" if rename.phase == "input" else "Renaming…"
	return "Reading folder contents…" if preparing else "Checking…" if checking else "Deleting…"

func draw_modal() -> void:
	if modal == "rename": rename.draw(); return
	var names_only: bool = modal == "sort" and menu.section == menu.Section.DLNA
	var source_order: bool = menu.section == menu.Section.CLOUD and supports_order("source")
	menu._set_backdrop(Vector2(1.12, 0.60 if names_only else 0.94 if modal == "delete" else 1.02 if source_order else 0.86), Vector2(0.13, 0))
	var remaining := maxi(1, deletions.size() - delete_index)
	var heading := "Sort" if modal == "sort" else "Delete folder" if target.get("folder", false) else "Delete file"
	menu._label(menu.I18n.t("Delete %d items?") % remaining if modal == "delete" and remaining > 1 else menu.I18n.t(heading), Vector3(0.13, 0.14 if names_only else 0.34, 0.004), 25)
	if modal == "sort":
		for i in Order.ORDERS.size():
			if not supports_order(Order.ORDERS[i]): continue
			var field: String = Order.ORDERS[i].get_slice("_", 0)
			var available: bool = field in ["name", "source"] or menu.rows.any(func(row): return (field == "modified" or row.has("uri")) and int(row.get(field, -1)) >= 0)
			if menu.section == menu.Section.CLOUD: available = available and (menu.PlatformMethods.supports(menu.platform, "media_cloud_sorted_page") or menu.PlatformMethods.supports(menu.platform, "media_cloud_directory_page"))
			menu._button(ORDER_BASE + i, menu.I18n.t(Order.LABELS[i]), Vector2(-0.12 + (i % 2) * 0.50, 0.01 if names_only else 0.19 - (i / 2) * 0.135), Vector2(0.46, 0.095), available, "", order() == Order.ORDERS[i])
		menu._button(FOLDERS_FIRST, menu.I18n.t("Folders first"), Vector2(0.13, -0.12 if names_only else -0.34 if source_order else -0.215), Vector2(0.80, 0.09), grouping_supported() and not menu._cloud_busy, "check" if folders_first() else "checkbox", folders_first())
		if not grouping_supported():
			menu._buttons.back()["hover_disabled"] = true
			menu._tips[FOLDERS_FIRST] = menu.I18n.t("Folder grouping is controlled by this source")
		menu._button(CANCEL, menu.I18n.t("Close"), Vector2(0.13, -0.23 if names_only else -0.45 if source_order else -0.335), Vector2(0.38, 0.08))
		return
	var title: Label3D = menu._label(menu._fit_title(str(target.get("title", "")), "", 0.96, 22), Vector3(0.13, 0.21, 0.004), 22)
	title.modulate = menu.ACCENT
	var names := []
	for item in deletions.slice(delete_index): names.append(str(item.get("title", "")))
	menu._label(menu._fit_title(" · ".join(names) if remaining > 1 else str(target.get("uri", "")), "", 0.96, 16), Vector3(0.13, 0.11, 0.004), 16).modulate = menu.MUTED
	var items: Array = deletions.slice(delete_index) if not deletions.is_empty() else [target]
	var recycle: bool = target.get("delete_effect", "") == "recycle"
	var folders := 0; var files := 0; var current_affected := false
	var has_folders := items.any(func(item): return item.get("folder", false))
	var current := str(menu.current_file_provider.call()) if menu.current_file_provider.is_valid() else ""
	for item in items:
		folders += (int(item.get("folders", 0)) + (1 if remaining > 1 else 0)) if item.get("folder", false) else 0
		files += int(item.get("files", 0)) if item.get("folder", false) else 1
		var uri := str(item.get("uri", ""))
		current_affected = current_affected or (not current.is_empty() and (current == uri or (item.get("folder", false) and current.begins_with(uri.trim_suffix("/") + "/"))))
	var effect := "Moves the folder and all contents to the cloud recycle bin" if has_folders else "Moves the original file to the cloud recycle bin"
	if not recycle: effect = "Permanently deletes the folder and all contents" if has_folders else "Permanently deletes the original file"
	if remaining > 1: effect = "Moves selected items to the cloud recycle bin" if recycle else "Permanently deletes selected items"
	menu._label(menu.I18n.t(effect), Vector3(0.13, -0.01, 0.004), 18)
	if current_affected:
		menu._label(menu.I18n.t("Playback will stop before deletion"), Vector3(0.13, -0.075, 0.004), 17).modulate = menu.ACCENT
	if has_folders and plan_ready and items.all(func(item): return not item.get("folder", false) or item.get("counts_known", true)):
		menu._label(menu.I18n.t("%d files · %d folders") % [files, folders], Vector3(0.13, -0.13 if current_affected else -0.10, 0.004), 17)
	menu._label(menu.I18n.t(pending_text()) if pending > 0 else menu.I18n.t(menu.status) if failed or uncertain else "", Vector3(0.13, -0.21, 0.004), 16)
	menu._button(CANCEL, menu.I18n.t("Hide" if pending > 0 else "Cancel"), Vector2(-0.12, -0.38), Vector2(0.40, 0.08))
	menu._button(CHECK_STATUS if uncertain else CONFIRM, menu.I18n.t("Check status" if uncertain else "Delete"), Vector2(0.38, -0.38), Vector2(0.40, 0.08), pending == 0 and (uncertain or (enabled and plan_ready)), "refresh" if uncertain else "trash")
	# Confirmation is separate from either footer opener and requires a fresh press.
