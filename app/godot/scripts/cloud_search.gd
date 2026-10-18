extends RefCounted

const I18n := preload("res://scripts/i18n.gd")
const Methods := preload("res://scripts/platform_methods.gd")
const OPEN := 9400
const BACK := 9401
const INPUT := 9402
const SUBMIT := 9403
const PREVIOUS := 9404
const NEXT := 9405
const REFRESH := 9406
const PASTE := 9414
const CLEAR := 9415
const SCOPE := 9500
const KIND := 9600
const KEY := 9700
const SCOPES := ["current", "tree", "all"]
const SCOPE_NAMES := ["This folder", "Include subfolders", "Entire cloud drive"]
const KINDS := ["all", "video", "image", "folder"]
const KIND_NAMES := ["All", "Videos", "Photos", "Folders"]
var menu: Node
var active := false
var editing := false
var query := ""
var scope := "current"
var kind := "all"
var scopes: Array = ["current"]
var path := ""
var entries: Array = []
var cursors: Array[String] = [""]
var page := 0
var next_cursor := ""
var pending := 0
var requested_page := 0
var request := {}
var committed_request := {}
var resolving := false
var resolve_token := ""
var limited := false

func _init(owner: Node) -> void: menu = owner
func supported() -> bool:
	return Methods.supports(menu.platform, "media_cloud_search") and Methods.supports(menu.platform, "media_cloud_search_resolve")
func observe(data: Dictionary) -> void:
	if data.get("search_scopes") is Array: scopes = data.search_scopes.duplicate()
func cancel() -> void:
	if pending > 0 and Methods.supports(menu.platform, "media_cloud_cancel"): menu.platform.media_cloud_cancel(pending)
	pending = 0; request = {}; resolving = false
func close(redraw: bool = false) -> void:
	menu.system_text_input.cancel("cloud_search")
	cancel(); active = false; editing = false; entries = []; query = ""; path = ""
	committed_request = {}
	page = 0; next_cursor = ""; cursors.assign([""]); limited = false
	if redraw: menu.status = ""; menu._reset_navigation(); menu.refresh()
func open() -> void:
	if not supported() or menu._cloud_stack.is_empty(): return
	menu.file_actions.reset(); menu._cancel_cloud()
	active = true; editing = true; path = menu._cloud_path(); query = ""; kind = "all"
	scope = "all" if menu._cloud_stack.size() == 1 and "all" in scopes else ("tree" if "tree" in scopes else "current")
	entries = []; cursors.assign([""]); page = 0; next_cursor = ""
	menu.status = ""; menu._reset_navigation(); menu.refresh()
	_begin_input()

func _begin_input() -> void:
	menu.system_text_input.begin("cloud_search", query, 128, _draft_changed, _input_submitted, _input_cancelled)

func _draft_changed(value: String) -> void:
	if not active or not editing: return
	query = value; menu.refresh()

func _input_submitted(value: String) -> void:
	if not active or not editing: return
	query = value; restart()

func _input_cancelled(value: String) -> void:
	if active and editing: query = value; menu.refresh()

func _set_draft(value: String) -> void:
	query = menu.SystemTextInput.clean(value, 128)
	if menu.system_text_input.active("cloud_search"): menu.system_text_input.set_text("cloud_search", query)
	else: _begin_input(); menu.refresh()

func submit(index: int = 0, force: bool = false) -> void:
	if not active: return
	query = menu.system_text_input.finish("cloud_search", query)
	if query.strip_edges().is_empty() or scope not in scopes or index < 0 or index >= cursors.size(): return
	cancel(); query = query.strip_edges(); editing = false; requested_page = index
	request = {"path": path, "query": query, "scope": scope, "kind": kind, "cursor": cursors[index]}
	if ["path", "query", "scope", "kind"].any(func(key): return request[key] != committed_request.get(key, "")):
		entries = []; page = 0; menu.scroll = 0.0
	pending = menu.platform.media_cloud_search(path, query, scope, kind, cursors[index], force)
	menu.status = "Loading…" if pending > 0 else "Cloud search failed"
	menu.refresh()
func restart(force: bool = false) -> void:
	cursors.assign([""]); next_cursor = ""; submit(0, force)
func action(target: int) -> bool:
	if target == OPEN: open(); return true
	if not active: return false
	if target == menu.BACK or target == BACK: close(true); return true
	if target == INPUT:
		cancel(); editing = true; menu.status = ""; menu.scroll = 0.0; menu.refresh(); _begin_input(); return true
	if target == SUBMIT: restart(); return true
	if target == REFRESH or target == menu.REFRESH: restart(true); return true
	if target in [PREVIOUS, NEXT]:
		if pending > 0: return true
		if target == PREVIOUS and page > 0: submit(page - 1)
		elif target == NEXT and not next_cursor.is_empty():
			if cursors.size() <= page + 1: cursors.append(next_cursor)
			else: cursors[page + 1] = next_cursor
			submit(page + 1)
		return true
	if target >= SCOPE and target < SCOPE + SCOPES.size():
		if SCOPES[target - SCOPE] in scopes:
			scope = SCOPES[target - SCOPE]
			if not editing and not query.is_empty(): restart()
			else: menu.refresh()
		return true
	if target >= KIND and target < KIND + KINDS.size():
		kind = KINDS[target - KIND]
		if not editing and not query.is_empty(): restart()
		else: menu.refresh()
		return true
	if editing:
		if target == CLEAR: _set_draft("")
		elif target == PASTE:
			var value: String = menu.platform.media_clipboard_text() if Methods.supports(menu.platform, "media_clipboard_text") else DisplayServer.clipboard_get()
			_set_draft(query + value)
		else: return target >= OPEN
		menu.refresh(); return true
	return target >= OPEN
func rows() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if editing: return result
	for item in entries:
		var location := str(item.get("relative_path", "")).get_base_dir().trim_prefix("/")
		result.append({"title": str(item.title), "detail": location, "icon": "folder" if item.get("container", false) else ("image" if item.get("kind") == "image" else "video"), "kind": item.get("kind", "video"), "folder": item.get("container", false), "search_result": item})
	return result
func choose(row: Dictionary) -> bool:
	if not active or not row.has("search_result"): return false
	if pending > 0: return true
	var item: Dictionary = row.search_result
	resolve_token = str(item.search_token); resolving = true
	pending = menu.platform.media_cloud_search_resolve(path, resolve_token)
	menu.status = "Loading…" if pending > 0 else "Cloud search failed"; menu.refresh(); return true
func receive(id: int, payload: String) -> bool:
	if id != pending or pending <= 0: return false
	pending = 0
	var parsed: Variant = JSON.parse_string(payload)
	if not active or menu.section != menu.Section.CLOUD or path != menu._cloud_path(): return true
	if not parsed is Dictionary:
		menu.status = "Cloud search failed"; menu.refresh(); return true
	var data: Dictionary = parsed
	var valid := str(data.get("path", "")) == path
	if resolving: valid = valid and str(data.get("token", "")) == resolve_token and str(data.get("source", "")) == "cloud_search_resolve"
	else:
		valid = valid and str(data.get("source", "")) == "cloud_search"
		for key in ["query", "scope", "kind", "cursor"]: valid = valid and str(data.get(key, "")) == str(request.get(key, ""))
	if not valid or data.get("state") != "ready":
		menu.status = str(data.get("error", "Cloud search failed")) if valid else "Cloud search failed"
		resolving = false; menu.refresh(); return true
	if resolving:
		if not data.get("entry") is Dictionary: menu.status = "Cloud search failed"; resolving = false; menu.refresh(); return true
		var entry: Dictionary = data.entry
		var account_name := str(menu._cloud_stack[0].title)
		var account_entry: Dictionary = menu._cloud_stack[0].duplicate(true)
		close()
		var destination := str(entry.id) if entry.get("container", false) else str(entry.id).get_base_dir()
		if destination != menu._cloud_path():
			var parts: PackedStringArray = destination.split("/", false)
			menu._cloud_stack = []
			var current := ""
			for index in parts.size():
				current += "/" + parts[index]
				var location: Dictionary = account_entry.duplicate(true) if index == 0 else {}
				location.merge({"id": current, "title": account_name if index == 0 else parts[index]}, true)
				menu._cloud_stack.append(location)
			menu._cloud_entries = []
		if entry.get("container", false):
			if entry.has("cloud_id"): menu._cloud_stack.back()["cloud_id"] = entry.cloud_id
			menu._load_cloud(); menu.refresh()
		else: menu._choose(menu._entry_row(entry))
		return true
	if not data.get("entries") is Array: menu.status = "Cloud search failed"; menu.refresh(); return true
	entries = data.entries; page = requested_page; next_cursor = str(data.get("next_cursor", "")); limited = bool(data.get("limited", false))
	committed_request = request.duplicate()
	menu.status = "Too many results. Refine your search" if limited else ("No matching files" if entries.is_empty() and next_cursor.is_empty() else "")
	menu._reset_navigation(); menu.refresh(); return true
func draw() -> void:
	menu._button(BACK, "", Vector2(-0.52, 0.46), Vector2(0.09, 0.07), true, "up")
	menu._button(INPUT, menu._fit_title(query if not query.is_empty() else I18n.t("Search files"), "", 1.12 if editing else 0.9, 21), Vector2(0.19 if editing else 0.065, 0.46), Vector2(1.20 if editing else 0.95, 0.075), true, "", editing)
	if not editing: menu.draw_view_modes(0.46)
	var available_scopes: Array = SCOPES.filter(func(value): return value in scopes)
	for index in available_scopes.size():
		var value: String = available_scopes[index]; var width := 1.24 / available_scopes.size()
		menu._button(SCOPE + SCOPES.find(value), I18n.t(SCOPE_NAMES[SCOPES.find(value)]), Vector2(-0.45 + width * (index + 0.5), 0.31), Vector2(width - 0.02, 0.072), true, "", scope == value)
	for index in KINDS.size():
		menu._button(KIND + index, I18n.t(KIND_NAMES[index]), Vector2(-0.295 + index * 0.31, 0.20), Vector2(0.29, 0.068), true, "", kind == KINDS[index])
	if editing:
		menu._button(CLEAR, "", Vector2(-0.39, 0.055), Vector2(0.11, 0.075), not query.is_empty(), "close")
		menu._button(PASTE, I18n.t("Paste"), Vector2(-0.13, 0.055), Vector2(0.30, 0.075))
		menu._button(SUBMIT, I18n.t("Search"), Vector2(0.51, 0.055), Vector2(0.48, 0.075), not query.strip_edges().is_empty(), "search", true)
	else:
		menu._draw_rows()
		menu._button(PREVIOUS, "‹", Vector2(-0.39, -0.51), Vector2(0.10, 0.07), pending == 0 and page > 0)
		menu._label(str(page + 1), Vector3(-0.19, -0.51, 0.004), 18)
		menu._button(NEXT, "›", Vector2(0.01, -0.51), Vector2(0.10, 0.07), pending == 0 and not next_cursor.is_empty())
		menu._button(REFRESH, "", Vector2(0.73, -0.51), Vector2(0.10, 0.07), pending == 0, "refresh")
	if not menu.status.is_empty(): menu._label(menu._fit_title(I18n.t(menu.status), "", 1.2, 17), Vector3(0.16, -0.59, 0.004), 17)
