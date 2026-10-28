extends RefCounted
## Browser-only library management. URLs identify records; no site data is touched.
const I18n := preload("res://scripts/i18n.gd")
const Methods := preload("res://scripts/platform_methods.gd")
const BASE := 987000
enum Action { BACK, MANAGE, ADD, SEARCH, CLEAR, ALL, EDIT, DELETE, CANCEL, CONFIRM, TITLE, URL, SAVE, PASTE, WIFI, START, STOP, SECURE }
var _browser: WeakRef
var browser: RefCounted:
	get: return _browser.get_ref()
var managing := false
var selection := {}
var query := ""
var modal := ""
var draft := {}
var removal := {}
var pending := 0
var error := ""
var require_code := false

func _init(owner: RefCounted) -> void: _browser = weakref(owner)
func menu() -> Node: return browser.menu
func active() -> bool:
	return menu().visible and menu().section == menu().Section.WEB and not browser.opened and not browser.list_mode.is_empty()
func supported() -> bool: return Methods.supports(menu().platform, "web_browser_library_edit")
func reset() -> void:
	menu().system_text_input.cancel("web_library_search")
	menu().system_text_input.cancel("web_library_title")
	menu().system_text_input.cancel("web_library_url")
	managing = false; selection.clear(); modal = ""; draft = {}; removal = {}; error = ""; query = ""
func title() -> String:
	return I18n.t("Bookmarks" if browser.list_mode == "bookmarks" else "Browsing history")
func entries() -> Array:
	var result: Array = browser.saved.get(browser.list_mode, [])
	if query.is_empty(): return result
	return result.filter(func(entry): return (str(entry.get("title", "")) + " " + str(entry.url)).to_lower().contains(query.to_lower()))
func accept(snapshot: Dictionary) -> void:
	var existing: Array = snapshot.get(browser.list_mode, []).map(func(entry): return str(entry.url))
	for url in selection.keys():
		if url not in existing: selection.erase(url)
	var operation: Dictionary = snapshot.get("operation", {})
	if pending <= 0 or int(operation.get("id", 0)) != pending: return
	pending = 0
	if operation.get("state") == "saved":
		if modal == "wifi_confirm": modal = "wifi"
		elif modal != "wifi": modal = ""
		error = ""; selection.clear(); browser.saved_poll = 0
	else:
		error = str(operation.get("error", "storage_failed"))
	menu().refresh()
func rows() -> Array:
	var result: Array = []
	for entry in entries():
		var url := str(entry.url)
		result.append({"title": str(entry.get("title", "")) if not str(entry.get("title", "")).is_empty() else url,
			"detail": display_address(url), "tip": url, "icon": ("check" if selection.has(url) else "checkbox") if managing else "globe",
			"selected": managing and selection.has(url), "web_browser": "select" if managing else "visit", "url": url})
	if result.is_empty(): result.append({"title": I18n.t("No items"), "enabled": false})
	return result
static func display_address(url: String) -> String:
	# Keep host + path visible; the complete destination is available on hover.
	return url.trim_prefix("https://").trim_prefix("http://")

func choose(url: String) -> void:
	if not active() or not managing or pending > 0: return
	if selection.has(url): selection.erase(url)
	else: selection[url] = true
	menu().refresh()
func _one() -> Dictionary:
	if selection.size() != 1: return {}
	for entry in entries():
		if selection.has(str(entry.url)): return entry
	return {}
func _button(action: int, text: String, x: float, y: float, width: float, enabled: bool = true, icon: String = "") -> void:
	menu()._button(BASE + action, text, Vector2(x, y), Vector2(width, 0.075), enabled and pending == 0, icon)
func draw_header() -> void:
	if not active(): return
	_button(Action.BACK, "", -0.52, 0.46, 0.085, true, "previous")
	_button(Action.SEARCH, "", 0.43, 0.46, 0.085, true, "search")
	menu()._tips[BASE + Action.SEARCH] = query if not query.is_empty() else I18n.t("Search")
	if not managing:
		var bookmarks: bool = browser.list_mode == "bookmarks"
		_button(Action.ADD if bookmarks else Action.CLEAR, "", 0.54, 0.46, 0.085,
			supported() and (bookmarks or not browser.saved.get("history", []).is_empty()), "plus" if bookmarks else "trash")
		menu()._tips[BASE + (Action.ADD if bookmarks else Action.CLEAR)] = I18n.t("Add bookmark" if bookmarks else "Clear history")
	_button(Action.MANAGE, I18n.t("Done" if managing else "Manage"), 0.73, 0.46, 0.23, supported())
func draw_footer() -> void:
	if not active(): return
	if not managing:
		_button(Action.WIFI, I18n.t("Manage over Wi-Fi"), 0.13, -0.49, 0.65, supported(), "globe")
		return
	menu()._label(I18n.t("%d selected") % selection.size(), Vector3(-0.43, -0.49, 0.004), 15).modulate = menu().MUTED
	_button(Action.ALL, I18n.t("Clear selection" if _all_selected() else "Select all"), -0.12, -0.49, 0.30, not entries().is_empty())
	_button(Action.EDIT, I18n.t("Edit" if browser.list_mode == "bookmarks" else "Bookmark"), 0.30, -0.49, 0.28, selection.size() == 1, "edit" if browser.list_mode == "bookmarks" else "star")
	_button(Action.DELETE, I18n.t("Delete"), 0.66, -0.49, 0.28, not selection.is_empty(), "trash")
func _all_selected() -> bool:
	return not entries().is_empty() and entries().all(func(entry): return selection.has(str(entry.url)))
func back() -> bool:
	if not active(): return false
	if pending > 0: return true
	if modal == "wifi_confirm": modal = "wifi"; error = ""
	elif not modal.is_empty(): _cancel_editor(); modal = ""; error = ""
	elif managing: managing = false; selection.clear()
	elif not query.is_empty(): query = ""
	else: reset(); browser.list_mode = ""
	menu().scroll = 0; menu().refresh(); return true
func action(target: int) -> bool:
	if not active() or target < BASE or target >= BASE + Action.size(): return false
	if pending > 0: return true
	var kind := target - BASE
	# Modal buttons cannot be reached through stale list targets.
	if not modal.is_empty() and kind not in [Action.CANCEL, Action.CONFIRM, Action.TITLE, Action.URL, Action.SAVE, Action.PASTE, Action.START, Action.STOP, Action.SECURE]: return true
	match kind:
		Action.WIFI:
			modal = "wifi"; error = ""; menu().refresh()
		Action.START:
			if modal == "wifi": _send({"action": "share_start", "require_code": require_code, "language": I18n.language})
		Action.STOP:
			if modal == "wifi": modal = "wifi_confirm"; error = ""; menu().refresh()
		Action.SECURE:
			if modal == "wifi" and not browser.saved.get("share", {}).get("active", false):
				require_code = not require_code; menu().refresh()
		Action.BACK, Action.CANCEL: back()
		Action.MANAGE: managing = not managing; selection.clear(); menu().refresh()
		Action.ADD: _edit({})
		Action.SEARCH:
			menu().system_text_input.begin("web_library_search", query, 256, _search, _search_done)
		Action.ALL:
			if _all_selected(): selection.clear()
			else:
				for entry in entries(): selection[str(entry.url)] = true
			menu().refresh()
		Action.EDIT:
			var item := _one()
			if not item.is_empty(): _edit(item)
		Action.DELETE:
			if not selection.is_empty():
				removal = {"action": "remove", "collection": browser.list_mode, "urls": selection.keys().duplicate()}
				modal = "delete"; error = ""; menu().refresh()
		Action.CLEAR:
			if browser.list_mode == "history" and not browser.saved.get("history", []).is_empty():
				removal = {"action": "clear_history"}; modal = "delete"; error = ""; menu().refresh()
		Action.CONFIRM:
			if modal == "delete": _send(removal)
			elif modal == "wifi_confirm": _send({"action": "share_stop"})
		Action.TITLE, Action.URL:
			if modal == "edit": _field("title" if kind == Action.TITLE else "url")
		Action.SAVE:
			if modal == "edit":
				_finish_editor(); _send(draft.merged({"action": "save_bookmark"}))
		Action.PASTE:
			if modal == "edit":
				_finish_editor(); draft.url = menu().SystemTextInput.clean(DisplayServer.clipboard_get(), 4096); menu().refresh()
	return true
func _search(value: String) -> void:
	query = value.strip_edges(); selection.clear(); menu().scroll = 0; menu().refresh()
func _search_done(value: String) -> void:
	_search(menu().system_text_input.finish("web_library_search", value))
func _edit(entry: Dictionary) -> void:
	draft = {"previous": str(entry.get("url", "")) if browser.list_mode == "bookmarks" else "",
		"title": str(entry.get("title", "")), "url": str(entry.get("url", ""))}
	modal = "edit"; error = ""; menu().refresh()
func _field(key: String) -> void:
	_finish_editor()
	menu().system_text_input.begin("web_library_" + key, str(draft.get(key, "")), 512 if key == "title" else 4096,
		func(value): draft[key] = value; error = ""; menu().refresh(),
		func(value): draft[key] = menu().system_text_input.finish("web_library_" + key, value); menu().refresh())
func _finish_editor() -> void:
	for key in ["title", "url"]:
		draft[key] = menu().system_text_input.finish("web_library_" + key, str(draft.get(key, "")))
func _cancel_editor() -> void:
	menu().system_text_input.cancel("web_library_title"); menu().system_text_input.cancel("web_library_url")
func _send(command: Dictionary) -> void:
	if not supported() or pending > 0: return
	pending = int(menu().platform.web_browser_library_edit(JSON.stringify(command)))
	error = "storage_failed" if pending <= 0 else ""
	browser.saved_poll = 0; menu().refresh()
func draw_modal() -> bool:
	if not active() or modal.is_empty(): return false
	menu()._side.visible = false
	menu()._set_backdrop(Vector2(1.28, 0.86), Vector2(0.13, 0.03))
	if modal == "wifi":
		_draw_wifi(); return true
	if modal == "wifi_confirm":
		menu()._label(I18n.t("Close remote access?"), Vector3(0.13, 0.30, 0.004), 24)
		menu()._label(I18n.t("All devices will be disconnected"), Vector3(0.13, 0.14, 0.004), 20)
		menu()._label(I18n.t("Reopen access from your headset"), Vector3(0.13, 0.01, 0.004), 18).modulate = menu().MUTED
		if not error.is_empty(): menu()._label(I18n.t("Unable to save changes"), Vector3(0.13, -0.13, 0.004), 16)
		_button(Action.CANCEL, I18n.t("Cancel"), -0.15, -0.28, 0.42)
		_button(Action.CONFIRM, I18n.t("Confirm close"), 0.41, -0.28, 0.42)
		return true
	if modal == "edit":
		menu()._label(I18n.t("Add bookmark" if str(draft.get("previous", "")).is_empty() else "Edit bookmark"), Vector3(0.13, 0.36, 0.004), 24)
		for spec in [[Action.TITLE, "title", "Name", 0.18], [Action.URL, "url", "Address", -0.01]]:
			var label: Label3D = menu()._label(I18n.t(spec[2]), Vector3(-0.40, spec[3] + 0.075, 0.004), 16)
			label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT; label.modulate = menu().MUTED
			_button(spec[0], menu()._fit_title(str(draft.get(spec[1], "")), "", 0.97, 18), 0.08, spec[3], 1.02)
		_button(Action.PASTE, "", 0.70, -0.01, 0.10, true, "paste")
		_button(Action.SAVE, I18n.t("Save"), 0.41, -0.28, 0.42, not str(draft.get("url", "")).strip_edges().is_empty())
	else:
		var clear: bool = removal.get("action") == "clear_history"
		menu()._label(I18n.t("Clear browsing history?") if clear else I18n.t("Delete %d items?") % removal.get("urls", []).size(), Vector3(0.13, 0.29, 0.004), 24)
		menu()._label(title(), Vector3(0.13, 0.15, 0.004), 20).modulate = menu().MUTED
		if browser.list_mode == "history": menu()._label(I18n.t("Website logins are kept"), Vector3(0.13, 0.02, 0.004), 18)
		_button(Action.CONFIRM, I18n.t("Delete"), 0.41, -0.28, 0.42, true, "trash")
	var messages := {"invalid_address": "Invalid address", "bookmark_exists": "Bookmark already exists", "bookmark_missing": "Bookmark no longer exists", "bookmark_limit": "Bookmark limit reached"}
	menu()._label(I18n.t("Saving…") if pending > 0 else I18n.t(messages.get(error, "Unable to save changes")) if not error.is_empty() else "", Vector3(0.13, -0.15, 0.004), 16).modulate = menu().MUTED
	_button(Action.CANCEL, I18n.t("Cancel"), -0.15, -0.28, 0.42)
	return true

func _draw_wifi() -> void:
	var share: Dictionary = browser.saved.get("share", {})
	menu()._set_backdrop(Vector2(1.46, 1.02), Vector2(0.13, 0.03))
	menu()._label(I18n.t("Bookmarks & history"), Vector3(0.13, 0.43, 0.004), 26)
	menu()._label(I18n.t("Phone or PC on the same Wi-Fi"), Vector3(0.13, 0.32, 0.004), 18).modulate = menu().MUTED
	if share.get("active", false):
		menu()._label(str(share.get("url", "")), Vector3(0.13, 0.17, 0.004), 28)
		if share.get("requires_code", false):
			menu()._label(I18n.t("Pairing code") + "  " + str(share.get("code", "")), Vector3(0.13, 0.02, 0.004), 26)
		else:
			menu()._label(I18n.t("Open the address. No code needed."), Vector3(0.13, 0.02, 0.004), 20)
		var minutes := maxi(1, ceili(float(share.get("seconds", 0)) / 60.0))
		menu()._label(I18n.t("Closes in %d min") % minutes, Vector3(0.13, -0.12, 0.004), 18).modulate = menu().MUTED
		_button(Action.STOP, I18n.t("Close remote access"), 0.42, -0.35, 0.56)
		menu()._tips[BASE + Action.STOP] = I18n.t("All devices will be disconnected")
	else:
		menu()._label(I18n.t("Auto-closes after 30 minutes"), Vector3(0.13, 0.16, 0.004), 18).modulate = menu().MUTED
		_button(Action.SECURE, "", 0.13, 0.02, 0.90)
		var row: Node3D = menu()._buttons.back().node
		menu()._icon("check" if require_code else "checkbox", Vector3(-0.37, 0, 0.004), 0.045, menu().ACCENT, row)
		var caption: Label3D = menu()._label(menu()._fit_title(I18n.t("Require pairing code"), "", 0.70, 20), Vector3(-0.31, 0, 0.004), 20, row)
		caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		menu()._tips[BASE + Action.SECURE] = I18n.t("Enter the pairing code on your phone or PC to connect.")
		_button(Action.START, I18n.t("Start sharing"), 0.42, -0.35, 0.48)
		menu()._tips[BASE + Action.START] = I18n.t("Phone or PC on the same Wi-Fi") if require_code else I18n.t("When off, anyone on this Wi-Fi can manage bookmarks and history while access is open.")
	if not error.is_empty():
		menu()._label(I18n.t("Unable to share. Check Wi-Fi and retry."), Vector3(0.13, -0.22, 0.004), 17)
	elif pending > 0:
		menu()._label(I18n.t("Please wait…"), Vector3(0.13, -0.22, 0.004), 17)
	_button(Action.CANCEL, I18n.t("Back"), -0.17, -0.35, 0.48)
