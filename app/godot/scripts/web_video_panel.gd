extends RefCounted

const I18n := preload("res://scripts/i18n.gd")
const Methods := preload("res://scripts/platform_methods.gd")
var menu: Node
var address := ""
var pending := 0
var result := {}
var next_poll := 0
var home := preload("res://scripts/web_video_home.gd").new(self)

func _init(owner: Node) -> void: menu = owner
func supported() -> bool: return Methods.supports(menu.platform, "web_video_resolve")
func active() -> bool: return menu.visible and menu.section == menu.Section.WEB
func error_hint() -> String:
	var messages := {
		"login_required": "Sign in on the website, then retry",
		"browser_session_required": "Play the video on the website, then retry",
		"browser_session_unavailable": "Play the video on the website, then retry",
		"protected_content": "Continue playing on the website",
		"browser_playback_required": "Continue playing on the website",
		"site_rejected": "Continue playing on the website",
		"region_restricted": "Unavailable in this region"}
	return I18n.t(messages.get(str(result.get("error_code", "")), "Video unavailable"))

func rows() -> Array:
	if not supported(): return [{"title": I18n.t("Headset only"), "enabled": false}]
	if not menu.web_browser.list_mode.is_empty(): return menu.web_browser.saved_rows()
	var items: Array = [
		{"title": I18n.t("Video URL"), "detail": address, "icon": "globe", "web_video": "edit"},
		{"title": I18n.t("Paste"), "icon": "paste", "web_video": "paste"}]
	if pending > 0:
		items.append({"title": I18n.t("Cancel"), "detail": I18n.t("Finding video…"), "icon": "stop", "web_video": "cancel"})
	else:
		items.append({"title": I18n.t("Open video"), "icon": "play", "web_video": "resolve", "enabled": not address.strip_edges().is_empty()})
	if result.get("state", "") == "ready":
		items.append({"title": str(result.get("title", "")), "detail": ("%dp · " % int(result.height) if int(result.get("height", 0)) > 0 else "") + I18n.t("Play"),
			"icon": "play", "web_video": "play"})
	elif result.get("state", "") == "error":
		items.append({"title": error_hint(), "enabled": false})
	if menu.web_browser.supported():
		items = [
			{"title": I18n.t("Browser"), "icon": "globe", "web_browser": "open"},
			{"title": I18n.t("Bookmarks"), "icon": "bookmark", "web_browser": "bookmarks"},
			{"title": I18n.t("Browsing history"), "icon": "history", "web_browser": "history"}] + items
	return items

func choose(row: Dictionary) -> bool:
	if not row.has("web_video"): return false
	match str(row.web_video):
		"edit":
			menu.system_text_input.begin("web_video", address, 200, _changed, _submitted)
		"paste":
			_changed(menu.SystemTextInput.clean(DisplayServer.clipboard_get(), 200))
			if menu.system_text_input.active("web_video"): menu.system_text_input.set_text("web_video", address)
		"resolve": resolve()
		"cancel": close(); menu.refresh()
		"play":
			if result.get("state", "") == "ready":
				var uri := str(result.uri)
				var title := str(result.title)
				menu.collections.selected_location = {}
				menu.collections.selected_entry = {"uri": uri, "title": title, "kind": "video"}
				if row.has("start_ms"):
					menu.collections.selected_entry.merge({"web_handoff": true, "start_ms": row.start_ms})
				if row.get("web_fullscreen", false): menu.collections.selected_entry.web_fullscreen = true
				var keep_browser: bool = row.get("keep_browser", false) and menu.web_browser.active()
				if keep_browser: menu.collections.selected_entry.keep_browser = true
				else: menu.dismiss()
				menu.chosen.emit(uri, title)
	return true

func _changed(value: String) -> void:
	address = value
	if pending > 0: close()
	result = {}; menu.refresh()
func _submitted(value: String) -> void:
	address = value; resolve()
func resolve(beta: bool = false) -> void:
	if not supported(): return
	if beta and not Methods.supports(menu.platform, "web_video_resolve_beta"): return
	address = menu.system_text_input.finish("web_video", address).strip_edges()
	if address.is_empty(): return
	result = {}
	pending = int(menu.platform.web_video_resolve_beta(address) if beta else menu.platform.web_video_resolve(address))
	next_poll = 0; menu.refresh()
func tick() -> void:
	if not active():
		if pending > 0: close()
		return
	if pending <= 0 or Time.get_ticks_msec() < next_poll: return
	next_poll = Time.get_ticks_msec() + 250
	var data: Variant = JSON.parse_string(str(menu.platform.web_video_status()))
	if not data is Dictionary or int(data.get("id", 0)) != pending: return
	if data.get("state", "") not in ["ready", "error"]: return
	result = data; pending = 0
	if data.get("state", "") == "ready": address = str(data.uri)
	menu.refresh()
func close() -> void:
	menu.system_text_input.cancel("web_home")
	menu.system_text_input.cancel("web_video")
	if pending > 0 and supported(): menu.platform.web_video_cancel()
	pending = 0
