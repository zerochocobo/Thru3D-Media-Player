extends RefCounted
## Local collections, source navigation and a ray-operated password dialog.
const Location := preload("res://scripts/media_location.gd")
const Privacy := preload("res://scripts/media_privacy.gd")
const HOME_TAB := 12000
const MORE := 12100
const OPEN_LOCATION := 12200
const REMOVE := 12300
const CANCEL := 12301
const UNLOCK := 12302
const SUBMIT := 12303
const ERASE := 12304
const SHIFT := 12305
const SYMBOLS := 12306
const SPACE := 12307
const LOCK := 12308
const FAVORITE_FOLDER := 12309
const RETURN_HOME := 12310
const UNDO := 12311
const RESET := 12312
const KEY := 12400
const PLAY_ROW := 12500
const DIRECTORY_ROW := 12600
const REMOVE_ROW := 12700
const SELECT_ROW := 12800
const BATCH_REMOVE := 12900
const CLEAR_SELECTION := 12901
const CONFIRM_BATCH := 12902
var menu: Node
var store: RefCounted:
	set(value):
		if store and store.lock_changed.is_connected(_store_lock_changed): store.lock_changed.disconnect(_store_lock_changed)
		store = value
		if store: store.lock_changed.connect(_store_lock_changed)
var home_tab := 0
var home_positions := [{"page": 0, "scroll": 0.0, "filter": 0}, {"page": 0, "scroll": 0.0, "filter": 0}]
var home_return := {}
var selected_location := {}
var selected_entry := {}
var modal := ""
var target := {}
var text := ""
var first := ""
var operation := ""
var stage := ""
var message := ""
var shift := false
var symbols := false
var after_unlock: Callable
var task := -1
var result := {}
var reveal_uri := ""
var reveal_pending := false
var selection := {}
var selection_scope := ""
var batch := []
var history_undo := {}
var pending_favorites := {}
var privacy_expanded := false
var task_started := 0

func reveal(rows: Array) -> void:
	if not reveal_pending: return
	for i in rows.size():
		if str(rows[i].get("uri", "")) == reveal_uri:
			menu.scroll = float(i / menu._cols()); menu.focus_index = i; reveal_pending = false; return

func _init(owner: Node) -> void: menu = owner
func _store_lock_changed() -> void:
	if not store or not store.locked: return
	if home_tab == 1: selection.clear(); batch.clear()
	pending_favorites.clear(); target.clear()
	selected_entry.clear(); selected_location.clear()
	if modal in ["item", "batch_remove"]: modal = ""; menu.refresh()
func active() -> bool: return not modal.is_empty()
func row_target(id: int) -> bool:
	for base in [MORE, PLAY_ROW, DIRECTORY_ROW, REMOVE_ROW, SELECT_ROW]:
		if id >= base and id < base + 64: return true
	return false
func row_index(id: int) -> int:
	if menu._row_target(id): return menu._first_line() * menu._cols() + id - menu.ROW_BASE
	for base in [MORE, PLAY_ROW, DIRECTORY_ROW, REMOVE_ROW, SELECT_ROW]:
		if id >= base and id < base + 64: return menu._first_line() * menu._cols() + id - base
	return -1

func home() -> bool: return menu.section == menu.Section.RECENT and not active()
func has_selection() -> bool: return home() and not selection.is_empty()
func managed(row: Dictionary) -> bool: return menu.section == menu.Section.RECENT and row.has("uri")
func location_for(row: Dictionary) -> Dictionary:
	var location := Location.clean(row.get("location", {}))
	return location if not location.is_empty() else Location.clean(Location.infer(str(row.get("uri", ""))))

func reconcile() -> void:
	if menu.section != menu.Section.RECENT or home_tab != 1 or menu.view_mode != "grid": pending_favorites.clear()
	if not history_undo.is_empty() and (not menu.catalog or not menu.catalog.can_undo() or menu.catalog.undo != history_undo.marker): history_undo.clear()
	var scope := str([menu.section, home_tab, menu.media_filter, menu._recent_page, menu.view_mode])
	if scope != selection_scope: selection.clear(); selection_scope = scope
	var present := {}
	for row in menu.rows: present[str(row.get("uri", ""))] = true
	for uri in selection.keys():
		if not present.has(uri) or (home_tab == 1 and store and store.locked): selection.erase(uri)

func draw_list_row(slot: int, row: Dictionary, centre: Vector2, parent: Node3D) -> void:
	var compact: bool = menu.compact
	var width := 0.71 if compact else 0.90
	var body := Vector2(-0.05 if compact else 0.10, centre.y)
	if row.get("kind") == "folder":
		var extra := 0.10 if compact else 0.12
		width += extra; body.x += extra * 0.5
	menu._button(menu.ROW_BASE + slot, "", body, Vector2(width, 0.098), true, "", false, parent)
	menu._lit(selection.has(str(row.uri)) or str(row.uri) == reveal_uri)
	var node: MeshInstance3D = menu._buttons.back().node
	var info: Dictionary = menu.Presentation.info(row, menu.catalog, true)
	var left := -width * 0.5 + 0.085
	var title: Label3D = node.get_child(0)
	title.text = menu._fit_title(str(row.title), "", width - 0.10, 20)
	title.position = Vector3(left, 0.021, 0.004); title.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	menu.set_label_size(title, 20)
	menu._icon(str(row.get("icon", "video")), Vector3(-width * 0.5 + 0.038, 0, 0.005), 0.038, menu.MUTED, node)
	var detail: Label3D = menu._label(menu._fit_title(str(info.subtitle), "", width - 0.10, 15), Vector3(left, -0.025, 0.004), 15, node)
	detail.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT; detail.modulate = menu.MUTED
	menu._tips[menu.ROW_BASE + slot] = str(row.title)
	menu._progress_on(node, float(info.ratio), Vector2(0, -0.043), width - 0.03)

func update_hover() -> void:
	var hovered := {}
	if not home(): return
	for value in menu._hover.values():
		var id := int(value)
		if menu._row_target(id): hovered[id] = true
		for base in [PLAY_ROW, DIRECTORY_ROW, REMOVE_ROW]:
			if id >= base and id < base + 64: hovered[menu.ROW_BASE + id - base] = true
	for button in menu._buttons:
		if not button.has("collection_hover"): continue
		var row_id: int = button.collection_hover
		var line: float = float((row_id - menu.ROW_BASE) / menu._cols()) - (menu.scroll - menu._first_line())
		button.node.visible = hovered.has(row_id) and line > -0.35 and line < menu._lines() - 0.65

func _row_button(id: int, slot: int, point: Vector2, icon: String, tip: String, enabled: bool, parent: Node3D, hover_only: bool = false) -> void:
	menu._button(id + slot, "", point, Vector2.ONE * 0.075, enabled, icon, false, parent)
	var button: Dictionary = menu._buttons.back()
	button.list_row = menu.ROW_BASE + slot
	button.hover_disabled = not enabled
	button.node.position.z = 0.026
	button.node.material_override.render_priority = 14
	for child in button.node.get_children():
		if child is MeshInstance3D: child.material_override.render_priority = 15
	if hover_only: button.collection_hover = menu.ROW_BASE + slot; button.node.visible = false
	menu._tips[id + slot] = menu.I18n.t(tip if enabled else "Location unavailable")

func draw_footer() -> void:
	if not has_selection(): return
	var compact: bool = menu.compact
	var y := -0.285 if compact else -0.515
	var count: Label3D = menu._label(menu.I18n.t("%d selected") % selection.size(), Vector3(-0.49 if compact else 0.10, y, 0.004), 16)
	count.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	menu._button(BATCH_REMOVE, menu.I18n.t("Remove favorite" if home_tab == 1 else "Remove from recent"), Vector2(0.17 if compact else 0.49, y), Vector2(0.40, 0.065), true, "", false)
	menu.set_label_size(menu._buttons.back().node.get_child(0), 17)
	menu._button(CLEAR_SELECTION, "", Vector2(0.46 if compact else 0.77, y), Vector2(0.075, 0.065), true, "close")
	menu._tips[CLEAR_SELECTION] = menu.I18n.t("Cancel selection")

func choose(row: Dictionary) -> bool:
	if row.get("group_header", false):
		privacy_expanded = not privacy_expanded
		if privacy_expanded: menu.scroll = float(maxi(0, menu.rows.find(row)))
		menu.choices.reset(); menu.refresh(); return true
	if row.get("unlock_favorites", false): open_password("unlock"); return true
	if row.has("privacy_action"):
		var action_name: String = row.privacy_action
		if action_name == "lock": store.lock()
		elif action_name == "reset": modal = "reset"; menu.refresh()
		else: open_password(action_name)
		return true
	if row.get("kind", "") == "folder" and row.has("location"):
		open_location(row); return true
	return false

func home_rows() -> Array[Dictionary]:
	var rows: Array[Dictionary] = []
	if home_tab != 1 or menu.view_mode != "grid": pending_favorites.clear()
	_expire_pending(Time.get_ticks_msec())
	if home_tab == 1 and store and store.locked:
		rows.append({"title": menu.I18n.t("Unlock favorites"), "icon": "lock", "unlock_favorites": true}); return rows
	var entries: Array = store.list_favorites() if home_tab == 1 and store else (menu.catalog.list_recent() if menu.catalog else [])
	if home_tab == 1 and not pending_favorites.is_empty():
		for pending in pending_favorites.values():
			var entry: Dictionary = pending.entry.duplicate(true); entry.pending_unfavorite = true; entries.append(entry)
		entries.sort_custom(func(a, b):return float(a.added) > float(b.added) if a.added != b.added else str(a.uri) < str(b.uri))
	for entry in entries:
		var row: Dictionary = entry.duplicate(true)
		row.kind = str(entry.get("kind", "image" if menu.ImageInfo.is_image(str(entry.get("uri", "")), str(entry.get("title", ""))) else "video"))
		if row.kind == "folder": row.title = Location.folder_title(location_for(row), str(entry.get("title", "")))
		row.icon = "folder" if row.kind == "folder" else ("image" if row.kind == "image" else "video")
		row.detail = ""; row.position_ms = int(entry.get("position_ms", 0)); row.duration_ms = int(entry.get("duration_ms", -1))
		if home_tab == 1 and store.protected:
			var recent: Dictionary = entry.get("private", {}).get("recent", {})
			row.position_ms = int(recent.get("position_ms", 0)); row.duration_ms = int(recent.get("duration_ms", -1))
		rows.append(row)
	return rows

func switch_tab(value: int) -> void:
	selection.clear(); history_undo.clear(); pending_favorites.clear()
	home_positions[home_tab] = {"page": menu._recent_page, "scroll": menu.scroll, "filter": menu.media_filter}
	home_tab = clampi(value, 0, 1)
	menu._recent_page = int(home_positions[home_tab].page); menu.scroll = float(home_positions[home_tab].scroll); menu.media_filter = int(home_positions[home_tab].filter)
	menu._confirm = ""; menu.refresh()

func draw_header() -> void:
	if menu.section == menu.Section.RECENT:
		for i in 2:
			menu._button(HOME_TAB + i, menu.I18n.t("Recent" if i == 0 else "Favorites"), Vector2(-0.35 + i * 0.30, menu._header_y()), Vector2(0.28, 0.07))
			menu._lit(home_tab == i)
		if store and store.protected and not store.locked:
			menu._button(LOCK, "", menu._action_position(0.58), Vector2(0.08, 0.065), true, "lock")
			menu._tips[LOCK] = menu.I18n.t("Lock favorites")
		var catalog: RefCounted = store if home_tab == 1 else menu.catalog
		var undo_available: bool = catalog != null and catalog.has_method("can_undo") and catalog.can_undo()
		if undo_available:
			menu._button(UNDO, "", menu._action_position(0.47), Vector2(0.08, 0.065), true, "undo")
			menu._tips[UNDO] = menu.I18n.t("Undo")
	else:
		draw_folder_header(false)

func draw_folder_header(compact: bool) -> void:
	var location := Location.capture(menu, {})
	var toolbar_left := Vector2(-0.40, 0.445)
	if not location.is_empty() and not menu._crumbs().is_empty():
		var selected: bool = store != null and store.contains(Location.folder_uri(location))
		var locked: bool = store != null and store.locked
		var favorite_position := toolbar_left + Vector2(0.11 if not home_return.is_empty() else 0.0, 0)
		menu._button(FAVORITE_FOLDER, "", Vector2(0.39, 0.36) if compact else favorite_position, Vector2(0.075, 0.065), store != null and not store.busy, "lock" if locked else "star_filled" if selected else "star")
		menu._tips[FAVORITE_FOLDER] = menu.I18n.t("Unlock favorites" if locked else "Remove favorite" if selected else "Favorite this location")
	if not home_return.is_empty():
		menu._button(RETURN_HOME, "", Vector2(0.12, -0.365) if compact else toolbar_left, Vector2(0.075, 0.065), true, "history")
		menu._tips[RETURN_HOME] = menu.I18n.t("Back to recent and favorites")

func decorate_row(slot: int, row: Dictionary, centre: Vector2, grid: bool, parent: Node3D) -> void:
	if not managed(row): return
	var location := location_for(row)
	var folder: bool = row.get("kind") == "folder"
	if grid:
		var spacing := 0.05 if folder else 0.085
		_row_button(PLAY_ROW, slot, centre + Vector2(-spacing, 0.04), "folder" if folder else "play", "Open" if folder else "Play", not location.is_empty() if folder else true, parent, true)
		if not folder: _row_button(DIRECTORY_ROW, slot, centre + Vector2(0, 0.04), "folder", "Open location", not location.is_empty(), parent, true)
		_row_button(REMOVE_ROW, slot, centre + Vector2(spacing, 0.04), ("star" if row.get("pending_unfavorite", false) else "star_filled") if home_tab == 1 else "trash", ("Restore favorite" if row.get("pending_unfavorite", false) else "Remove favorite") if home_tab == 1 else "Remove from recent", true, parent, true)
	else:
		_row_button(SELECT_ROW, slot, Vector2(-0.48 if menu.compact else -0.405, centre.y), "check" if selection.has(str(row.uri)) else "checkbox", "Select", true, parent)
		if not folder: _row_button(DIRECTORY_ROW, slot, Vector2(0.37 if menu.compact else 0.65, centre.y), "folder", "Open location", not location.is_empty(), parent)
		_row_button(REMOVE_ROW, slot, Vector2(0.46 if menu.compact else 0.745, centre.y), "star_filled" if home_tab == 1 else "trash", "Remove favorite" if home_tab == 1 else "Remove from recent", true, parent)

func open_password(value: String, callback: Callable = Callable()) -> void:
	if not store: return
	if store.busy: modal = "password"; menu.refresh(); return
	menu.choices.reset(); menu._drag.clear(); menu._fling = 0.0; menu._hover.clear()
	modal = "password"; operation = value; stage = "new" if value == "enable" else "verify"
	text = ""; first = ""; message = ""; after_unlock = callback
	menu.refresh()

func close() -> void:
	modal = ""; text = ""; first = ""; batch.clear(); after_unlock = Callable(); menu.refresh()

func poll() -> void:
	var pending_count := pending_favorites.size()
	_expire_pending(Time.get_ticks_msec())
	if pending_count != pending_favorites.size() and home() and menu.visible: menu.refresh()
	if task < 0: return
	result = store.password_result(task)
	if result.get("pending", false):
		if Time.get_ticks_msec() - task_started > 15000 and message != "Still processing. You can return.":
			message = "Still processing. You can return."
			if active(): menu.refresh()
		return
	task = -1
	var was_open := modal == "password"
	var success: bool = store.finish_password(operation, result)
	result.clear()
	if not success:
		if operation in ["enable", "change"]: stage = "new"; first = ""
		message = store.last_error
		if not was_open: menu.status = message
		menu.refresh(); return
	if operation == "disable":
		if not store.disable_password(): message = store.last_error; menu.refresh(); return
	elif operation == "change_verify":
		if was_open: operation = "change"; stage = "new"; text = ""; message = ""; menu.refresh(); return
	var callback := after_unlock
	modal = ""; first = ""; text = ""; after_unlock = Callable()
	menu.setting_changed.emit("favorites_security_changed", true)
	store.tick(Time.get_ticks_msec())
	if callback.is_valid() and not store.locked: callback.call()
	menu.refresh()

func _submit() -> void:
	if store.busy: return
	if stage == "new":
		if text.length() != 4: message = "Use a 4-digit PIN"; menu.refresh(); return
		first = text; text = ""; stage = "confirm"; menu.refresh(); return
	if stage == "confirm" and first != text:
		message = "Passwords do not match"; text = ""; first = ""; stage = "new"; menu.refresh(); return
	var password := text; text = ""; first = ""; message = ""
	task = store.begin_password(operation, password); task_started = Time.get_ticks_msec()
	if task < 0:
		message = store.last_error
		if operation in ["enable", "change"]: stage = "new"
	menu.refresh()

func action(id: int) -> bool:
	if not active() and home():
		for base in [PLAY_ROW, DIRECTORY_ROW, REMOVE_ROW, SELECT_ROW]:
			if id < base or id >= base + 64: continue
			var index: int = menu._first_line() * menu._cols() + id - base
			if index >= menu.rows.size(): return true
			var row: Dictionary = menu.rows[index].duplicate(true)
			if base == PLAY_ROW: menu._choose(row)
			elif base == DIRECTORY_ROW: open_location(row)
			elif base == REMOVE_ROW:
				if home_tab == 1 and menu.view_mode == "grid": _toggle_card_favorite(row)
				else: _remove_rows([row])
			else: _toggle_selection(row)
			return true
		if id == BATCH_REMOVE:
			if home_tab == 0: _remove_rows(selection.values().duplicate(true))
			else: batch = selection.values().duplicate(true); message = ""; modal = "batch_remove"; menu.refresh()
			return true
		if id == CLEAR_SELECTION: selection.clear(); menu.refresh(); return true
	if id >= HOME_TAB and id < HOME_TAB + 2: switch_tab(id - HOME_TAB); return true
	if id == LOCK: store.lock(); return true
	if id == RETURN_HOME:
		if home_return.is_empty(): return true
		reveal_uri = ""; reveal_pending = false
		menu.section = menu.Section.RECENT; home_tab = int(home_return.tab); menu._recent_page = int(home_return.page); menu.scroll = float(home_return.scroll)
		home_return.clear(); menu.refresh(); return true
	if id == UNDO:
		var catalog: RefCounted = store if home_tab == 1 else menu.catalog
		if catalog:
			if home_tab == 0 and not history_undo.is_empty() and catalog.can_undo() and catalog.undo == history_undo.marker:
				for entry in history_undo.entries:
					catalog.undo = {"entry":entry, "until":history_undo.until}; catalog.restore()
				history_undo.clear()
			else: catalog.restore()
		menu.refresh(); return true
	if id == FAVORITE_FOLDER:
		var location := Location.capture(menu, {})
		if location.is_empty(): menu.status = "Location unavailable"; menu.refresh(); return true
		var uri := Location.folder_uri(location)
		var title := Location.folder_title(location, menu._header_title())
		var callback := func():
			if not store.toggle(uri, title, "folder", location): menu.status = store.last_error
			menu.refresh()
		if store.locked: open_password("unlock", callback)
		else: callback.call()
		return true
	if id >= MORE and id < MORE + 64 and not active():
		var index: int = menu._first_line() * menu._cols() + id - MORE
		if index < menu.rows.size(): target = menu.rows[index].duplicate(true); modal = "item"; menu.refresh()
		return true
	if not active(): return false
	if id == CANCEL: close(); return true
	if modal == "batch_remove":
		if id == CONFIRM_BATCH: _remove_rows(batch.duplicate(true))
		return true
	if modal == "reset":
		if id == RESET and store.reset_locked(): close()
		return true
	if modal == "item":
		if id == OPEN_LOCATION: var item := target.duplicate(true); modal = ""; open_location(item)
		elif id == REMOVE:
			var catalog: RefCounted = store if home_tab == 1 else menu.catalog
			var success: bool = catalog.remove(str(target.uri)) if home_tab == 1 else catalog.forget(str(target.uri))
			if success and home_tab == 0: success = catalog.purge_keys([])
			if success: modal = ""
			else: menu.status = "Favorites save failed"
			menu.refresh()
		return true
	if modal == "password":
		if store.busy: return true
		if id == SUBMIT: _submit()
		elif id == ERASE: text = text.left(-1); menu.refresh()
		elif id == SHIFT: shift = not shift; menu.refresh()
		elif id == SYMBOLS: symbols = not symbols; menu.refresh()
		elif id == SPACE: text += " "; menu.refresh()
		elif id >= KEY and id < KEY + 10:
			var character := str(id - KEY)
			if text.length() < 4: text += character
			menu.refresh()
		return true
	return true

func _toggle_selection(row: Dictionary) -> void:
	var uri := str(row.get("uri", ""))
	if uri.is_empty(): return
	if selection.has(uri): selection.erase(uri)
	else: selection[uri] = row.duplicate(true)
	menu.refresh()

func _expire_pending(now: int) -> void:
	for uri in pending_favorites.keys():
		if not store or store.locked or store.contains(str(uri)) or now >= int(pending_favorites[uri].until): pending_favorites.erase(uri)

func _toggle_card_favorite(row: Dictionary) -> void:
	var uri := str(row.uri)
	var success := false
	if store.contains(uri):
		var entry := {}
		for field in ["uri", "title", "kind", "location", "added"]:
			if row.has(field): entry[field] = row[field]
		pending_favorites[uri] = {"entry":entry, "until":Time.get_ticks_msec() + 8000}
		success = store.remove(uri)
		if not success: pending_favorites.erase(uri)
	elif pending_favorites.has(uri):
		success = store.restore_favorite(pending_favorites[uri].entry)
		if success: pending_favorites.erase(uri)
	if not success: menu.status = "Favorites save failed"
	menu.refresh()

func _remove_rows(items: Array, clear_all: bool = false) -> void:
	var success := false
	if home_tab == 1:
		success = store.remove_many(items.map(func(row):return str(row.uri)))
	else:
		var removed := []
		for row in items:
			var entry: Dictionary = menu.catalog.lookup(str(row.uri))
			if menu.catalog.forget(str(row.uri)): removed.append(entry)
		if clear_all:
			var undo: Dictionary = menu.catalog.undo.duplicate(true)
			menu.catalog.clear_all(); menu.catalog.undo = undo
		var persisted: bool = menu.catalog.purge_keys([]) if not removed.is_empty() else false
		success = removed.size() == items.size() and persisted
		if not removed.is_empty(): history_undo = {"entries":removed, "until":Time.get_ticks_msec() + 8000, "marker":menu.catalog.undo.duplicate(true)}
	if success: selection.clear(); batch.clear(); modal = ""
	else:
		menu.status = "Unable to remove items"; message = "Unable to remove items"
		if home_tab == 0: batch = items.filter(func(row):return not menu.catalog.lookup(str(row.uri)).is_empty())
	menu.refresh()

func draw() -> void:
	menu._set_backdrop(Vector2(1.55, 1.14))
	if modal == "batch_remove":
		menu._label(menu.I18n.t("Remove %d favorites?" if home_tab == 1 else "Remove %d recent items?") % batch.size(), Vector3(0, 0.18, 0.004), 24)
		if not message.is_empty(): menu._label(menu.I18n.t(message), Vector3(0, 0.02, 0.004), 17)
		menu._button(CANCEL, menu.I18n.t("Cancel"), Vector2(-0.24, -0.18), Vector2(0.35, 0.09))
		menu._button(CONFIRM_BATCH, menu.I18n.t("Confirm"), Vector2(0.24, -0.18), Vector2(0.35, 0.09)); return
	if modal == "reset":
		menu._label(menu.I18n.t("Reset favorites?"), Vector3(0, 0.22, 0.004), 24)
		menu._label(menu.I18n.t("Encrypted favorites will be deleted. Media files are kept."), Vector3(0, 0.04, 0.004), 18)
		menu._button(CANCEL, menu.I18n.t("Cancel"), Vector2(-0.24, -0.20), Vector2(0.35, 0.09))
		menu._button(RESET, menu.I18n.t("Confirm"), Vector2(0.24, -0.20), Vector2(0.35, 0.09)); return
	if modal == "item":
		menu._label(menu._fit_title(str(target.get("title", "")), "", 1.3, 23), Vector3(0, 0.34, 0.004), 23)
		var location: Dictionary = location_for(target)
		menu._button(OPEN_LOCATION, menu.I18n.t("Open location"), Vector2(0, 0.12), Vector2(1.1, 0.1), not location.is_empty(), "folder")
		menu._button(REMOVE, menu.I18n.t("Remove favorite" if home_tab == 1 else "Remove from recent"), Vector2(0, -0.03), Vector2(1.1, 0.1), true, "star" if home_tab == 1 else "trash")
		menu._button(CANCEL, menu.I18n.t("Close"), Vector2(0, -0.30), Vector2(0.35, 0.08)); return
	var title := "Enter PIN again" if stage == "confirm" else ("Set favorites password" if stage == "new" else "Unlock favorites")
	var title_text: String = menu.I18n.t(title)
	if stage in ["new", "confirm"]: title_text += " · " + ("2/2" if stage == "confirm" else "1/2")
	menu._label(title_text, Vector3(0, 0.46, 0.004), 26)
	var dots := PackedStringArray()
	for i in 4: dots.append("●" if i < text.length() else "○")
	menu._label(" ".join(dots), Vector3(0, 0.34, 0.004), 24)
	for digit in range(1, 10):
		menu._button(KEY + digit, str(digit), Vector2(-0.17 + ((digit - 1) % 3) * 0.17, 0.18 - ((digit - 1) / 3) * 0.12), Vector2(0.14, 0.10), not store.busy and text.length() < 4)
	menu._button(KEY, "0", Vector2(0, -0.18), Vector2(0.14, 0.10), not store.busy and text.length() < 4)
	menu._button(ERASE, "", Vector2(0.17, -0.18), Vector2(0.14, 0.10), not store.busy, "backspace")
	menu._button(CANCEL, menu.I18n.t("Return" if store.busy else "Cancel"), Vector2(-0.2, -0.39), Vector2(0.30, 0.08), true)
	var submit_text := "Next step" if stage == "new" else ("Save password" if stage == "confirm" else "Confirm")
	menu._button(SUBMIT, menu.I18n.t("Loading…" if store.busy else submit_text), Vector2(0.2, -0.39), Vector2(0.30, 0.08), not store.busy and text.length() == 4)
	if not message.is_empty(): menu._label(menu.I18n.t(message), Vector3(0, -0.49, 0.004), 16)

func open_location(row: Dictionary) -> void:
	var location: Dictionary = location_for(row)
	if location.is_empty(): menu.status = "Location unavailable"; menu.refresh(); return
	reveal_uri = str(row.get("uri", "")); reveal_pending = true
	if menu.section == menu.Section.RECENT: home_return = {"tab": home_tab, "page": menu._recent_page, "scroll": menu.scroll}
	menu.file_actions.reset(); menu.cloud_search.close(); menu._cancel_cloud(); menu.scroll = 0; menu.media_filter = 0
	match location.type:
		"local":
			menu.section = menu.Section.LOCAL; menu._local_stack = location.get("stack", [{"id": location.get("path", ""), "title": location.get("title", "")}]).duplicate(true)
			menu._local_entries = []; menu._load_section()
		"smb":
			menu.section = menu.Section.SMB; menu._smb_server = str(location.server_id); menu._smb_path = str(location.path); menu._smb_entries = []
			if menu.platform: menu._request("smb_browse", menu.platform.media_smb_browse(menu._smb_server, menu._smb_path))
		"cloud":
			menu.section = menu.Section.CLOUD; menu._cloud_stack = location.get("stack", []).duplicate(true); menu._cloud_entries = []; menu._load_cloud()
		"dlna":
			menu.section = menu.Section.DLNA; menu._dlna_server = str(location.server_id); menu._dlna_stack = location.get("stack", []).duplicate(true); menu._dlna_entries = []
			if menu.platform and menu.PlatformMethods.supports(menu.platform, "media_dlna_discover"): menu._request("dlna_discover", menu.platform.media_dlna_discover())
			if menu.platform: menu._request("dlna_browse", menu.platform.media_dlna_browse(menu._dlna_server, str(menu._dlna_stack.back().id) if not menu._dlna_stack.is_empty() else "0"))
		"server":
			menu.section = menu.Section.MEDIA_SERVER
			menu.server_browser.open_location(location)
	menu._position_to_restore = {"key": str(row.get("uri", "")), "index": 0, "fraction": 0.0}
	menu.refresh()
