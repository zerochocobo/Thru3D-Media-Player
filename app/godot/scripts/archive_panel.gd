extends RefCounted
signal opening
signal closing
## One foreground comic session; password book shares the library's ray surface and IME.
const BASE := 960000
const CLOSE := BASE
const INPUT := BASE + 1
const SUBMIT := BASE + 2
const SAVE := BASE + 3
const HISTORY := BASE + 4
const PREVIOUS := BASE + 5
const NEXT := BASE + 6
const SELECT := BASE + 20
const DELETE := BASE + 30
const CRUMB := BASE + 1000
const EXTENSIONS := ["zip", "cbz", "rar", "cbr", "7z", "tar", "gz", "tgz", "xz", "bz2", "zipx", "001"]
var menu: Node
var opened := false
var managing := false
var history := false
var persist := false
var password := ""
var passwords: Array = []
var page := 0
var pending := 0
var result := ""
var message := ""
var target := {}
var entries: Array[Dictionary] = []
var connected: Object
var ready_data := {}
var warning := ""
var _browsing := false
var suspended := false
var browser_section := -1
var browsing: bool:
	get: return _browsing and not suspended and menu.section == browser_section and not menu.image_picker_mode and not menu.audio_import_mode and not menu.subtitle_picker_mode
var parent_context := {}
var directory := ""
var remembered_filter := 0
var parent_position := {}
var parent_status := ""
var session := ""

func _init(owner: Node) -> void: menu = owner

static func named(uri: String, title: String = "") -> bool:
	return title.get_extension().to_lower() in EXTENSIONS or uri.get_slice("?", 0).get_extension().to_lower() in EXTENSIONS

func book(operation: String = "list", value: String = "") -> bool:
	if not menu.PlatformMethods.supports(menu.platform, "archive_passwords"):
		book_error(); return false
	var response: Variant = JSON.parse_string(menu.platform.archive_passwords(operation, value))
	if not response is Dictionary or response.has("error"):
		book_error(); return false
	passwords = response.get("passwords", []); page = clampi(page, 0, maxi(0, (passwords.size()-1)/5))
	warning = ""
	if message == "Archive password book unavailable": message = ""
	return true

func book_error() -> void:
	if managing: message = "Archive password book unavailable"
	else: warning = "Archive password book unavailable"

func manage() -> void:
	close(); opened = true; managing = true; history = true; password = ""; message = ""; warning = ""; page = 0
	book(); menu.refresh()

func open(row: Dictionary) -> void:
	if _browsing and str(target.get("uri", "")) == str(row.get("uri", "")):
		resume()
		menu.refresh(); return
	opening.emit()
	var replacing := browsing
	close()
	if replacing: menu.refresh()
	opened = true; managing = false; history = false; persist = false; password = ""; message = ""; warning = ""
	parent_position = menu.capture_position(); parent_status = menu.status
	menu._cancel_cloud()
	parent_context = {"paging": menu.cloud_pagination.snapshot(), "search": {}, "crumbs": menu._crumbs()}
	for key in menu.CONTEXT_FIELDS:
		var value: Variant = menu.get(key)
		parent_context[key] = value.duplicate(true) if value is Array or value is Dictionary else value
	if menu.cloud_search.active:
		for key in menu.SEARCH_FIELDS:
			var value: Variant = menu.cloud_search.get(key)
			parent_context.search[key] = value.duplicate(true) if value is Array or value is Dictionary else value
	target = row.duplicate(true); entries.clear()
	if not menu.PlatformMethods.supports(menu.platform, "archive_open"):
		message = "Archive reading unavailable"; menu.refresh(); return
	if connected != menu.platform:
		if is_instance_valid(connected) and connected.is_connected("archive_ready", receive): connected.disconnect("archive_ready", receive)
		connected = menu.platform
		if connected.has_signal("archive_ready"): connected.connect("archive_ready", receive)
	submit()

func submit() -> void:
	if pending > 0: return
	if not ready_data.is_empty(): finish_open(); return
	password = menu.system_text_input.finish("archive_password", password)
	if managing:
		if not password.is_empty() and book("add", password): password = ""; message = ""
		menu.refresh(); return
	pending = menu.platform.archive_open(str(target.get("uri", "")), str(target.get("title", "")), password, persist)
	message = "Loading…" if pending > 0 else "Archive could not be opened"; menu.refresh()

func receive(id: int, payload: String) -> void:
	accept_result.call_deferred(id, payload)

func accept_result(id: int, payload: String) -> void:
	if opened and id == pending: result = payload

func tick() -> void:
	if result.is_empty(): return
	var parsed: Variant = JSON.parse_string(result); result = ""; pending = 0
	if not opened: return
	if not parsed is Dictionary or parsed.get("state") != "ready":
		message = str(parsed.get("error", "Archive could not be opened")) if parsed is Dictionary else "Archive could not be opened"
		if message == "Archive password required or incorrect":
			book()
			message = "Archive password required or incorrect"
		menu.refresh(); return
	entries.assign(parsed.get("entries", []))
	ready_data = parsed
	if parsed.get("password_save_error", false):
		message = "Archive password was not saved"; menu.refresh(); return
	finish_open()

func finish_open() -> void:
	session = str(ready_data.get("session", ""))
	ready_data.clear()
	password = ""; passwords.clear(); opened = false; history = false
	_browsing = true; suspended = false; browser_section = menu.section; directory = ""; remembered_filter = menu.media_filter
	if menu.restore_directory_position:
		var route: Dictionary = menu.browse_memory.lookup(route_scope(), network())
		var saved := str(route.get("archive_directory", ""))
		if directory_exists(saved): directory = saved
	menu.file_actions.reset(); menu.collections.selection.clear(); menu.scroll = 0.0; menu.status = ""
	menu._browse_activity()
	menu._position_to_restore = menu.browse_memory.lookup(position_scope(), network()) if menu.restore_directory_position else {}
	menu.refresh()

func source_key() -> String:
	return JSON.stringify(["archive", target.get("uri", "")])

func position_scope() -> String: return source_key() + JSON.stringify([directory, menu.media_filter])
func route_scope() -> String: return source_key() + JSON.stringify(["last-folder", menu.media_filter])
func network() -> bool: return not preload("res://scripts/media_privacy.gd").is_local(str(target.get("uri", "")))

func directory_exists(value: String) -> bool:
	if value.is_empty(): return true
	for entry in entries:
		var path := str(entry.get("path", entry.get("title", ""))).trim_suffix("/")
		if path.begins_with(value+"/") or (path == value and entry.get("kind", "") == "folder"): return true
	return false

func save_position(folder: Dictionary = {}) -> void:
	if not browsing: return
	remembered_filter = menu.media_filter
	var anchor: Dictionary = menu.capture_position() if folder.is_empty() else menu.Presentation.folder_anchor(menu.rows, menu.scroll, menu._cols(), folder)
	menu.browse_memory.remember(position_scope(), network(), anchor, menu._browse_revision)
	menu.browse_memory.remember(route_scope(), network(), {"archive_directory": directory, "filter": menu.media_filter}, menu._browse_revision)

## The index is already local. Folder traversal never resolves the source again.
func directory_rows() -> Array[Dictionary]:
	var children := {}
	var prefix := directory + "/" if not directory.is_empty() else ""
	for entry in entries:
		var path := str(entry.get("path", entry.get("title", ""))).trim_suffix("/")
		if not path.begins_with(prefix) or path == directory: continue
		var relative := path.substr(prefix.length())
		if relative.is_empty(): continue
		var name := relative.get_slice("/", 0)
		var folder: bool = relative.contains("/") or entry.get("kind", "") == "folder"
		if children.has(name) and children[name].get("folder", false): continue
		var row: Dictionary = entry.duplicate(true) if not folder else {}
		row.title = name; row.archive_path = prefix + name; row.folder = folder
		row.archive_key = "archive-image://" + str(target.get("uri", "")).uri_encode() + "/" + source_key().sha256_text() + "/" + str(row.archive_path).uri_encode()
		if not folder and row.get("kind", "image") == "image": row.thumbnail_key = row.archive_key
		if folder: row.container = {"id": row.archive_path, "title": name}
		row.kind = "folder" if folder else str(entry.get("kind", "image"))
		row.icon = "folder" if folder else "image" if row.kind == "image" else "info"
		row.enabled = folder or (row.kind == "image" and not str(row.get("uri", "")).is_empty())
		if not row.enabled: row.detail = menu.I18n.t("Unsupported file type")
		children[name] = row
	var result_rows: Array[Dictionary] = []
	result_rows.assign(children.values())
	if menu.media_filter > 0:
		result_rows.assign(result_rows.filter(func(row): return row.folder or row.kind == ("image" if menu.media_filter == 2 else "video")))
	var order: String = menu.file_actions.order()
	var grouped: bool = menu.file_actions.folders_first()
	result_rows.sort_custom(func(a, b): return menu.file_actions.Order.before(a, b, order, grouped))
	return result_rows

func image_queue() -> Array[Dictionary]:
	var images: Array[Dictionary] = []
	for row in directory_rows():
		if row.get("kind", "") == "image": images.append(row)
	return images

func change_directory(value: String, returning: bool = false, folder: Dictionary = {}) -> void:
	save_position(folder)
	directory = value; menu.scroll = 0.0
	menu._browse_activity()
	menu._position_to_restore = menu.browse_memory.lookup(position_scope(), network()) if returning or menu.restore_directory_position else {}
	menu.refresh()

func back() -> void:
	if directory.is_empty(): close(); menu.refresh()
	else: change_directory(directory.get_base_dir() if directory.contains("/") else "", true)

func choose(row: Dictionary) -> void:
	if not row.get("enabled", true): return
	if row.get("folder", false): change_directory(str(row.archive_path), false, row); return
	if row.get("kind", "") != "image" or str(row.get("uri", "")).is_empty(): return
	menu.collections.selected_location = preload("res://scripts/media_location.gd").capture(menu, target)
	menu.collections.selected_entry = target.duplicate(true)
	save_position()
	menu.dismiss()
	menu.chosen.emit(str(row.uri), str(row.title))

func browser_action(id: int) -> bool:
	if id >= menu.NAV_BASE and id < menu.NAV_BASE + menu.NAV.size():
		return false
	if menu.file_actions.modal == "sort" or id == menu.FileActions.SORT: return menu.file_actions.action(id)
	if id == menu.BACK: back()
	elif id == CLOSE: close(); menu.refresh()
	elif id == menu.CLOSE: menu.dismiss()
	elif id in [menu.VIEW_LIST, menu.VIEW_GRID]: menu.set_view_mode("list" if id == menu.VIEW_LIST else "grid")
	elif id == menu.EXPAND_LIBRARY: menu.layout_requested.emit()
	elif id >= menu.FILTER_BASE and id < menu.FILTER_BASE + menu.MEDIA_FILTERS.size(): menu._change_media_filter(id-menu.FILTER_BASE)
	elif id == menu.REFRESH:
		var row := target.duplicate(true); close(); menu.refresh(); open(row)
	elif id >= CRUMB and id < CRUMB + crumbs().size(): go_to(id-CRUMB)
	elif menu._row_target(id):
		var index: int = menu._first_line() * menu._cols() + id - menu.ROW_BASE
		if index < menu.rows.size(): choose(menu.rows[index])
	else: menu._activate_footer(id)
	return true

func crumbs() -> Array:
	return parent_context.get("crumbs", []) + [str(target.get("title", ""))] + Array(directory.split("/", false))

func go_to(level: int) -> void:
	var parents: int = parent_context.get("crumbs", []).size()
	if level < parents:
		close(); menu._go_to(level); menu.refresh(); return
	var parts := Array(directory.split("/", false)); parts.resize(mini(level-parents, parts.size()))
	change_directory("/".join(parts), true)

func hide() -> void:
	# Playback hides the library but retains the foreground index and its password.
	if opened: close()
	elif browsing: save_position()

func restore_parent() -> void:
	for key in menu.CONTEXT_FIELDS:
		if not parent_context.has(key): continue
		var value: Variant = parent_context[key]
		menu.set(key, value.duplicate(true) if value is Array or value is Dictionary else value)
	menu.cloud_search.close()
	for key in parent_context.get("search", {}):
		var value: Variant = parent_context.search[key]
		menu.cloud_search.set(key, value.duplicate(true) if value is Array or value is Dictionary else value)
	if not parent_context.is_empty(): menu.cloud_pagination.restore(parent_context.get("paging", {}))

func resume(uri: String = "") -> void:
	if not _browsing or (not uri.is_empty() and not uri.begins_with("comic://" + session + "/")): return
	restore_parent(); suspended = false
	menu.media_filter = remembered_filter
	menu._position_to_restore = menu.browse_memory.lookup(position_scope(), network())

func close() -> void:
	if not opened and not _browsing: return
	var was_browsing := browsing
	if was_browsing: save_position()
	if _browsing: closing.emit()
	menu.system_text_input.cancel("archive_password")
	if not managing and menu.PlatformMethods.supports(menu.platform, "archive_close"): menu.platform.archive_close("")
	if was_browsing:
		restore_parent()
		menu._position_to_restore = parent_position.duplicate(true); menu.status = parent_status
	_browsing = false; suspended = false; directory = ""; entries.clear(); session = ""; parent_context.clear()
	opened = false; pending = 0; result = ""; password = ""; passwords.clear(); target.clear(); message = ""; warning = ""; ready_data.clear()

func action(id: int) -> bool:
	if browsing: return browser_action(id)
	if not opened: return false
	if id == CLOSE or id == menu.BACK: close(); menu.refresh(); return true
	if pending > 0: return true
	if id == INPUT:
		menu.system_text_input.begin("archive_password", password, 512,
			func(value): password = value; menu.refresh(), func(value): password = value; submit())
	elif id == SUBMIT: submit()
	elif id == SAVE: persist = not persist
	elif id == HISTORY: history = not history; page = 0; book()
	elif id == PREVIOUS: page = maxi(0, page - 1)
	elif id == NEXT: page = mini(maxi(0, (passwords.size()-1)/5), page + 1)
	elif id >= SELECT and id < SELECT + 5:
		var index := page*5 + id-SELECT
		if index < passwords.size():
			password = str(passwords[index]); menu.system_text_input.cancel("archive_password")
	elif id >= DELETE and id < DELETE + 5:
		var index := page*5 + id-DELETE
		if index < passwords.size(): book("delete", str(passwords[index]))
	menu.refresh(); return true

func draw() -> void:
	menu._label(menu.I18n.t("Archive password book" if managing else "Comic archive"), Vector3(0, 0.49, 0.004), 25)
	menu._button(CLOSE, "", Vector2(0.58, 0.49), Vector2(0.08, 0.08), true, "close")
	if not managing and pending > 0:
		menu._label(menu.I18n.t("Loading…"), Vector3(0, 0.1, 0.004), 22); return
	if not ready_data.is_empty():
		menu._label(menu.I18n.t(message), Vector3(0, 0.15, 0.004), 19)
		menu._button(SUBMIT, menu.I18n.t("Open"), Vector2(0, -0.03), Vector2(0.25, 0.085), true); return
	var can_enter := managing or message == "Archive password required or incorrect"
	if not can_enter:
		menu._label(menu.I18n.t(message), Vector3(0, 0.08, 0.004), 16); return
	menu._button(INPUT, menu._fit_title(password if not password.is_empty() else menu.I18n.t("Password"), "", 0.78, 20), Vector2(-0.10, 0.34), Vector2(0.88, 0.085), true)
	menu._tips[INPUT] = password
	menu._button(SUBMIT, menu.I18n.t("Add" if managing else "Open"), Vector2(0.46, 0.34), Vector2(0.20, 0.085), not password.is_empty())
	if not managing:
		menu._button(SAVE, menu.I18n.t("Save password"), Vector2(-0.23, 0.23), Vector2(0.53, 0.07), true, "check" if persist else "", persist)
		menu._button(HISTORY, menu.I18n.t("Password book"), Vector2(0.34, 0.23), Vector2(0.40, 0.07), true, "", history)
	if history:
		for i in mini(5, passwords.size()-page*5):
			var value := str(passwords[page*5+i]); var y := 0.105 - i*0.10
			menu._button(SELECT+i, menu._fit_title(value, "", 0.83, 20), Vector2(-0.08, y), Vector2(0.94, 0.085), true)
			menu._tips[SELECT+i] = value
			if managing: menu._button(DELETE+i, "", Vector2(0.48, y), Vector2(0.085, 0.085), true, "trash")
		menu._button(PREVIOUS, "", Vector2(-0.12, -0.43), Vector2(0.10, 0.07), page>0, "previous")
		menu._label("%d / %d" % [page+1, maxi(1, ceili(passwords.size()/5.0))], Vector3(0, -0.43, 0.004), 16)
		menu._button(NEXT, "", Vector2(0.12, -0.43), Vector2(0.10, 0.07), (page+1)*5<passwords.size(), "next")
	if message != "Archive password required or incorrect" and not message.is_empty(): menu._label(menu.I18n.t(message), Vector3(0,-0.53,0.004),16)
	elif not warning.is_empty(): menu._label(menu.I18n.t(warning), Vector3(0,-0.53,0.004),16)
