extends RefCounted
## Opt-in list checkboxes and serial confirmed mutations. Requests outlive dismissal.
const Order := preload("res://scripts/library_order.gd")
const SORT := 9100
const EDIT_MODE := 9101
const DELETE_FILE := 9102
const CANCEL := 9103
const CONFIRM := 9104
const CHECK_STATUS := 9105
const SELECT_BASE := 9200
const ORDER_BASE := 9120
var menu: Node3D
var editing := false
var enabled := false
var selection := {}
var selected: String:
	get: return str(selection.values()[0].get("uri", "")) if selection.size() == 1 else ""
	set(value):
		selection.clear()
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
	return str(menu.section)

func folder() -> bool:
	return (menu.section == menu.Section.LOCAL and not menu._local_stack.is_empty()) or \
		(menu.section == menu.Section.SMB and not menu._smb_server.is_empty() and not menu._smb_path.is_empty()) or \
		(menu.section == menu.Section.CLOUD and not menu._cloud_stack.is_empty() and menu.cloud_accounts.mode.is_empty())

func order() -> String:
	var value := Order.normalize(orders.get(scope(), "name_asc"))
	return value if supports_order(value) else "name_asc"

func sortable() -> bool:
	return folder() or (menu.section == menu.Section.DLNA and not menu._dlna_server.is_empty())

func supports_order(value: String) -> bool:
	if menu.section == menu.Section.DLNA: return value in ["name_asc", "name_desc"]
	return value in Order.ORDERS and (value != "source" or menu.section == menu.Section.CLOUD)

func load(value: Dictionary) -> void:
	orders = value.duplicate(true)

func reset() -> void:
	editing = false; selection.clear(); modal = ""
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
	for row in menu.rows:
		if not selection.has(row_key(row)): continue
		var copy: Dictionary = row.duplicate(true); copy.uri = row_uri(row)
		result.append(copy)
	return result

func list_management() -> bool:
	return enabled and menu.view_mode == "list" and folder() and not menu.cloud_search.active

func has_selection() -> bool:
	return not selected_rows().is_empty()

func needs_footer() -> bool:
	return has_selection() or pending > 0 or uncertain

func is_selected(row: Dictionary) -> bool:
	return selection.has(row_key(row))

func reconcile() -> void:
	var context := str([menu.section, menu._local_path(), menu._smb_server, menu._smb_path, menu._cloud_path(), menu._cloud_page, menu.media_filter, menu.cloud_search.active])
	if selection_scope != context:
		selection.clear(); selection_scope = context
	var present := {}
	for row in menu.rows: present[row_key(row)] = true
	for key in selection.keys():
		if not present.has(key): selection.erase(key)

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
	if not idle() or not selectable(row): return
	var key := row_key(row)
	if selection.has(key): selection.erase(key)
	else:
		var copy: Dictionary = row.duplicate(true); copy.uri = row_uri(row)
		selection[key] = copy
	menu.status = ""; menu.refresh()

func sort_rows() -> void:
	if not sortable() or menu.section == menu.Section.CLOUD: return
	menu.rows.sort_custom(func(a, b): return Order.before(a, b, order()))

func choose_order(value: String) -> void:
	if not sortable() or not supports_order(value): return
	if menu.section == menu.Section.CLOUD:
		if not menu.PlatformMethods.supports(menu.platform, "media_cloud_sorted_page"): return
		cloud_requested_order = value
		cloud_rollback = {"offsets": menu._cloud_offsets.duplicate(), "page": menu._cloud_page}
		menu._cloud_positions.clear()
		menu._cloud_offsets.assign([0])
		menu._load_cloud(false, false, 0)
	else:
		orders[scope()] = value
		menu.setting_changed.emit("library_orders", orders.duplicate(true))
		menu.scroll = 0.0
	modal = ""; selected = ""
	menu.refresh()

func commit_cloud(value: String) -> void:
	cloud_committed_order = value; cloud_requested_order = ""
	cloud_rollback = {}
	if not value.is_empty():
		orders[scope()] = value
		menu.setting_changed.emit("library_orders", orders.duplicate(true))

func cloud_order() -> String:
	return cloud_requested_order if not cloud_requested_order.is_empty() else Order.normalize(orders.get(str(menu.Section.CLOUD), "name_asc"))

func cloud_failed() -> void:
	if not cloud_rollback.is_empty():
		menu._cloud_offsets.assign(cloud_rollback.offsets)
		menu._cloud_requested_page = int(cloud_rollback.page)
	cloud_requested_order = ""; cloud_rollback = {}

func action(id: int) -> bool:
	if not modal.is_empty():
		if modal == "rename": rename.action(id); return true
		if id == CANCEL: modal = ""; menu.refresh()
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
		modal = "sort"; menu.refresh(); return true
	if id == EDIT_MODE and enabled and folder() and not list_management() and pending == 0:
		editing = not editing; selection.clear(); menu.refresh(); return true
	if id == DELETE_FILE:
		if can_delete_selection():
			deletions = selected_rows().duplicate(true); delete_index = 0; prepare_index = 0
			deleted_count = 0; batch_running = false; failed = false; plan_ready = false; modal = "delete"
			prepare_folder()
			menu.refresh()
		return true
	if id == Rename.OPEN:
		var row := selected_row()
		if rename.can_rename(row): rename.open(row)
		return true
	if id == CHECK_STATUS and uncertain:
		modal = "delete"; menu.refresh(); return true
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
	menu.refresh()

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
		for entries in [menu._local_entries, menu._smb_entries, menu._cloud_entries]:
			for i in range(entries.size() - 1, -1, -1):
				var entry: Dictionary = entries[i]
				if str(entry.get("uri", entry.get("delete_uri", ""))) == uri and str(entry.get("cloud_id", "")) == str(target.get("cloud_id", "")): entries.remove_at(i)
		menu.file_deleted.emit(uri)
		deleted_count += 1; delete_index += 1; checking = false
		if batch_running and enabled and delete_index < deletions.size():
			target = deletions[delete_index]; dispatch(false); return true
		batch_running = false; modal = ""; target = {}; deletions.clear()
		menu.status = "File deleted" if deleted_count == 1 else menu.I18n.t("%d items deleted") % deleted_count
		# Refresh cloud pages after the entire batch; do not disturb snapshots mid-batch.
		if menu.section == menu.Section.CLOUD and enabled:
			menu._cloud_positions.clear(); menu._cloud_offsets.assign([0]); menu._load_cloud(false, true, 0)
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
	if menu.visible: menu.refresh()
	return true

func draw_header() -> void:
	if not sortable(): return
	menu._button(SORT, "", menu._action_position(0.25), Vector2(0.09, 0.065), not editing and pending == 0 and not menu._cloud_busy, "sort")
	menu._tips[SORT] = menu.I18n.t("Sort")
	if enabled and folder() and not list_management():
		menu._button(EDIT_MODE, "", menu._action_position(0.36), Vector2(0.09, 0.065), pending == 0, "check" if editing else "select", editing)
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
	var row := selected_row()
	if rename.supported(row) and rows.size() == 1:
		menu._button(Rename.OPEN, menu.I18n.t("Rename"), Vector2(0.09 if compact else 0.38, y), Vector2(0.23, 0.065), rename.can_rename(row), "edit")
	if rows.all(func(item): return delete_supported(item)):
		menu._button(DELETE_FILE, menu.I18n.t("Delete"), Vector2(0.37 if compact else 0.68, y), Vector2(0.24 if compact else 0.28, 0.065), can_delete_selection(), "trash")

func pending_text() -> String:
	if uncertain: return "Check status"
	if rename.request_id > 0: return "Checking…" if rename.phase == "input" else "Renaming…"
	return "Reading folder contents…" if preparing else "Checking…" if checking else "Deleting…"

func draw_modal() -> void:
	if modal == "rename": rename.draw(); return
	var names_only: bool = modal == "sort" and menu.section == menu.Section.DLNA
	menu._set_backdrop(Vector2(1.12, 0.46 if names_only else 0.94 if modal == "delete" else 0.86), Vector2(0.13, 0))
	var remaining := maxi(1, deletions.size() - delete_index)
	var heading := "Sort" if modal == "sort" else "Delete folder" if target.get("folder", false) else "Delete file"
	menu._label(menu.I18n.t("Delete %d items?") % remaining if modal == "delete" and remaining > 1 else menu.I18n.t(heading), Vector3(0.13, 0.14 if names_only else 0.34, 0.004), 25)
	if modal == "sort":
		for i in Order.ORDERS.size():
			if not supports_order(Order.ORDERS[i]): continue
			var field: String = Order.ORDERS[i].get_slice("_", 0)
			var available: bool = field in ["name", "source"] or menu.rows.any(func(row): return (field == "modified" or row.has("uri")) and int(row.get(field, -1)) >= 0)
			if menu.section == menu.Section.CLOUD: available = available and menu.PlatformMethods.supports(menu.platform, "media_cloud_sorted_page")
			menu._button(ORDER_BASE + i, menu.I18n.t(Order.LABELS[i]), Vector2(-0.12 + (i % 2) * 0.50, 0.01 if names_only else 0.19 - (i / 2) * 0.135), Vector2(0.46, 0.095), available, "", order() == Order.ORDERS[i])
		menu._button(CANCEL, menu.I18n.t("Close"), Vector2(0.13, -0.13 if names_only else -0.32), Vector2(0.38, 0.08))
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
