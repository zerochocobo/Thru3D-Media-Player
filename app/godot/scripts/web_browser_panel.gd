extends RefCounted

const Distribution := preload("res://scripts/distribution_channel.gd")
const I18n := preload("res://scripts/i18n.gd")
const Methods := preload("res://scripts/platform_methods.gd")
const BASE := 986000
const WEB := BASE + 20
const KEY := BASE + 100
const KEY_CONTROL := BASE + 40
const RECT := Rect2(-0.59, -0.48, 1.44, 0.90)
var menu: Node
var opened := false
var data := {}
var draft := ""
var hand := ""
var point := Vector2(0.5, 0.5)
var windows := {}
var low_end := false
var window_created: Callable
var paired_layout := false
var focused_window := 1
var pointer_window := 1
var tabs_open := false
var handoff_tab := 0
var handoff_navigation := 0
var cinema_provider: Callable
var next_poll := 0
var handoff := false
var handoff_uri := ""
var pause_started := 0
var handoff_start_ms := 0
var handoff_auto := false
var handoff_started_ms := 0
var capture_started_ms := 0
var handoff_context := {}
# Background resolution of the video already playing on a supported page, so a later
# fullscreen hands off immediately instead of starting extraction from zero.
const PREFETCH_DELAY_MS := 3000
const PREFETCH_FRESH_MS := 600000
var prefetch_uri := ""
var prefetch_id := 0
var prefetch_result := {}
var prefetch_ms := 0
var playing_since := 0
var fullscreen_seen := {}
var playback_return := {}
var _signature := ""
var list_mode := ""
var saved := {}
var saved_poll := 0
var _saved_raw := ""
var _status_raw := ""
var library := preload("res://scripts/web_browser_library_panel.gd").new(self)

func _init(owner: Node) -> void: menu = owner
func supported() -> bool: return Distribution.web_browser_enabled() and Methods.supports(menu.platform, "web_browser_navigate")
func active() -> bool: return opened and menu.visible and menu.section == menu.Section.WEB

func open(url: String = "") -> void:
	if not supported(): return
	menu.browser_opened.emit()
	if menu.compact: menu.layout_requested.emit()
	opened = true
	menu.clear_pointer_visuals()
	ensure_window(1)
	if not url.is_empty():
		draft = url; menu.platform.web_browser_navigate(url)
	else: menu.platform.web_browser_action("resume")
	next_poll = 0; menu.refresh()

func close() -> void:
	cancel()
	library.reset()
	if handoff or (prefetch_id > 0 and menu.web_video.pending == prefetch_id): menu.web_video.close()
	prefetch_id = 0; playing_since = 0
	menu.system_text_input.cancel("web_browser")
	if opened and supported(): menu.platform.web_browser_action("hibernate")
	opened = false; handoff = false; pause_started = 0
	handoff_auto = false; handoff_context.clear()
	for item in windows.values(): item.save_layout(); item.dismiss()
	tabs_open = false

func tick() -> void:
	if menu.visible and menu.section == menu.Section.WEB and supported() and Time.get_ticks_msec() >= saved_poll:
		saved_poll = Time.get_ticks_msec() + 1000
		# Up to 1000 bookmarks: skip parsing and deep comparison when nothing changed.
		var raw := str(menu.platform.web_browser_library())
		var library: Variant = null if raw == _saved_raw else JSON.parse_string(raw)
		_saved_raw = raw
		if library is Dictionary:
			var changed: bool = library != saved
			saved = library
			self.library.accept(saved)
			if not opened:
				var snapshot: Variant = JSON.parse_string(str(menu.platform.web_browser_status()))
				if snapshot is Dictionary and snapshot != data: data = snapshot; changed = true
			if changed and (not opened or hand.is_empty()): menu.refresh()
	if not active():
		if opened: close()
		return
	if Time.get_ticks_msec() < next_poll: return
	next_poll = Time.get_ticks_msec() + 250
	var raw := str(menu.platform.web_browser_status())
	if raw != _status_raw:
		var parsed: Variant = JSON.parse_string(raw)
		if not parsed is Dictionary: return
		_status_raw = raw; data = parsed
	focused_window = int(data.get("focused_window", 1))
	var paired: bool = data.get("tab_list", []).any(func(item): return int(item.window) == 2)
	var layout_changed := paired != paired_layout
	if layout_changed:
		for item in windows.values(): item.save_layout()
		paired_layout = paired
	for id in [1, 2]:
		var exists: bool = id == 1 or paired
		if exists: ensure_window(id)
		elif windows.has(id): windows[id].dismiss()
	if layout_changed:
		for item in windows.values():
			if item.visible: item.recenter(true)
	if handoff and (str(data.get("url", "")) != handoff_uri or int(data.get("tab_id", 0)) != handoff_tab or int(data.get("navigation", 0)) != handoff_navigation):
		_cancel_handoff()
	if not menu.system_text_input.active("web_browser"):
		draft = "" if data.get("url", "") == "about:blank" else str(data.get("url", ""))
	_poll_prefetch()
	_poll_fullscreen()
	if handoff and Time.get_ticks_msec() - handoff_started_ms > 90000: _handoff_failed()
	if handoff and menu.web_video.pending == 0:
		if menu.web_video.result.get("state", "") == "ready":
			if pause_started == 0:
				if not handoff_auto or _capture_ready():
					handoff_start_ms = _playhead()
					if handoff_auto: handoff_context.position_ms = handoff_start_ms
					pause_started = Time.get_ticks_msec(); menu.platform.web_browser_action("pause")
			elif not data.get("active", true) and not data.get("playing", true):
				var automatic := handoff_auto
				_keep_prefetch(handoff_uri, menu.web_video.result)
				playback_return = handoff_context.duplicate(true)
				playback_return.native_uri = str(menu.web_video.result.get("uri", ""))
				handoff = false; pause_started = 0
				handoff_auto = false
				menu.web_video.choose({"web_video": "play", "start_ms": handoff_start_ms, "web_fullscreen": automatic}); return
			elif Time.get_ticks_msec() - pause_started > 5000:
				_handoff_failed()
		else: _handoff_failed()
	# Only fields the chrome draws. Window states also carry each video's advancing time;
	# comparing those rebuilt every browser window four times a second during playback.
	var chrome: Array = data.get("windows", []).map(func(item): return [item.get("id"), item.get("tab_id"), item.get("url"),
		item.get("title"), item.get("back"), item.get("forward"), item.get("error"), item.get("editing"), int(item.get("progress", 0)) / 10])
	var signature := str([draft, data.get("back"), data.get("forward"), data.get("error"),
		chrome, data.get("tab_list", []), data.get("operation_error", ""), int(data.get("progress", 0)) / 10, data.get("videos", []).size(), handoff, data.get("editing", false), menu.web_video.result.get("state", "")])
	if signature != _signature:
		_signature = signature
		if hand.is_empty(): menu.refresh()

func _poll_fullscreen() -> void:
	if handoff:
		if handoff_auto and pause_started == 0 and (not data.get("fullscreen_video", false) or int(data.get("fullscreen_request", 0)) != int(handoff_context.get("request", 0))): _handoff_failed()
		return
	if not data.get("fullscreen_video", false) or not data.get("active", false): return
	if not Methods.supports(menu.platform, "web_browser_command"): return
	var id := int(data.get("tab_id", 0))
	var request := int(data.get("fullscreen_request", 0))
	if id <= 0 or request <= 0 or int(fullscreen_seen.get(id, 0)) == request: return
	fullscreen_seen[id] = request
	# Encrypted video stays in the website-owned playback path.
	if data.get("videos", []).any(func(item): return item.get("fullscreen", false) and item.get("protected", false)): return
	_begin_handoff(true)

func _begin_handoff(automatic: bool = false) -> void:
	if handoff: _cancel_handoff()
	handoff_auto = automatic
	handoff_started_ms = Time.get_ticks_msec(); pause_started = 0; capture_started_ms = 0
	handoff_uri = str(data.get("url", ""))
	handoff_tab = int(data.get("tab_id", 0)); handoff_navigation = int(data.get("navigation", 0))
	handoff_context = {"tab": handoff_tab, "window": focused_window, "navigation": handoff_navigation,
		"fullscreen": automatic,
		"origin": handoff_uri, "request": int(data.get("fullscreen_request", 0)), "position_ms": _playhead(),
		"was_playing": data.get("videos", []).any(func(item): return item.get("fullscreen", false) and item.get("playing", false))}
	menu.web_video.address = handoff_uri
	if prefetch_uri == handoff_uri and prefetch_id > 0 and menu.web_video.pending == prefetch_id:
		handoff = true # Adopt the extraction that is already running for this page.
		return
	if prefetch_uri == handoff_uri and not prefetch_result.is_empty() and Time.get_ticks_msec() - prefetch_ms < PREFETCH_FRESH_MS:
		if menu.web_video.pending > 0: menu.web_video.close()
		menu.web_video.result = prefetch_result.duplicate(true); handoff = true
		return
	menu.web_video.resolve(); handoff = menu.web_video.pending > 0
	prefetch_uri = handoff_uri; prefetch_id = 0; prefetch_result = {}
	if automatic and not handoff: _handoff_failed()

func _poll_prefetch() -> void:
	var uri := str(data.get("url", ""))
	if prefetch_id > 0:
		if menu.web_video.pending == prefetch_id:
			if uri != prefetch_uri and not handoff: menu.web_video.close(); prefetch_id = 0
			return
		var finished: Dictionary = menu.web_video.result
		if menu.web_video.pending == 0 and int(finished.get("id", 0)) == prefetch_id:
			_keep_prefetch(prefetch_uri, finished)
			# A background attempt never shows its result or error in the browser.
			if not handoff: menu.web_video.result = {}
		prefetch_id = 0
		return
	var playing: bool = data.get("videos", []).any(func(item): return item.get("playing", false) and not item.get("protected", false))
	var fresh: bool = uri == prefetch_uri and (prefetch_result.is_empty() or Time.get_ticks_msec() - prefetch_ms < PREFETCH_FRESH_MS)
	if handoff or fresh or not playing or menu.web_video.pending > 0 or not data.get("active", false) or not data.get("native_supported", false) or data.get("memory_tight", false):
		playing_since = 0; return
	if playing_since == 0: playing_since = Time.get_ticks_msec(); return
	if Time.get_ticks_msec() - playing_since < PREFETCH_DELAY_MS: return
	playing_since = 0
	menu.web_video.address = uri; menu.web_video.resolve()
	prefetch_uri = uri; prefetch_result = {}; prefetch_id = menu.web_video.pending

func _keep_prefetch(uri: String, result: Dictionary) -> void:
	prefetch_uri = uri
	prefetch_result = result.duplicate(true) if result.get("state", "") == "ready" else {}
	prefetch_ms = Time.get_ticks_msec()

func _capture_ready() -> bool:
	if int(data.get("captured_fullscreen_request", 0)) == int(handoff_context.request): return true
	if capture_started_ms == 0:
		capture_started_ms = Time.get_ticks_msec()
		handoff_context.was_playing = data.get("videos", []).any(func(item): return item.get("fullscreen", false) and item.get("playing", false))
		_video_command("capture_video", handoff_context)
	elif Time.get_ticks_msec() - capture_started_ms > 1500: _handoff_failed()
	return false

func _cancel_handoff() -> void:
	menu.web_video.close()
	if pause_started > 0: menu.platform.web_browser_action("resume")
	handoff = false; handoff_auto = false; pause_started = 0; handoff_context = {}

func _handoff_failed() -> void:
	var automatic := handoff_auto
	var paused := pause_started > 0
	var context := handoff_context.duplicate(true)
	_cancel_handoff()
	if automatic:
		menu.web_video.result = {}
		if paused:
			context.play = bool(context.get("was_playing", false)); context.exit_fullscreen = false
			_video_command("restore_video", context)
	elif paused:
		menu.web_video.result = {"state": "error"}

func _video_command(action: String, context: Dictionary) -> void:
	if not Methods.supports(menu.platform, "web_browser_command"): return
	var command := context.duplicate(true); command.action = action
	menu.platform.web_browser_command(JSON.stringify(command))

func has_playback_return(uri: String) -> bool:
	return not playback_return.is_empty() and (playback_return.get("opening", false) or str(playback_return.get("native_uri", "")) == uri)

func playback_selected(uri: String, browser_handoff: bool = false) -> void:
	if not browser_handoff or str(playback_return.get("native_uri", "")) != uri: playback_return.clear()

func restore_playback(failed: bool, position_ms: int = -1) -> void:
	if playback_return.is_empty(): return
	var context := playback_return.duplicate(true); playback_return.clear()
	if position_ms >= 0: context.position_ms = position_ms
	context.play = failed and bool(context.get("was_playing", false))
	context.exit_fullscreen = not failed
	menu.section = menu.Section.WEB; list_mode = ""; tabs_open = false
	open() # Restore displayed tabs; sleeping sessions recover their saved navigation.
	if context.get("fullscreen", false): _video_command("restore_video", context)
	else:
		# The button can hand off without a fullscreen video capture. Restore the
		# original tab/window without navigating again or addressing stale media.
		_video_command("select", context)
	menu.web_video.result = {}; next_poll = 0

func ensure_window(id: int) -> void:
	if not menu.is_inside_tree(): return
	if not windows.has(id):
		var item := preload("res://scripts/web_browser_window.gd").new()
		item.configure(self, id); menu.get_tree().root.add_child(item); windows[id] = item
		if window_created.is_valid(): window_created.call(item)
		menu.tree_exiting.connect(item.queue_free, CONNECT_ONE_SHOT)
	if not windows[id].visible: windows[id].show_window()
func refresh_windows() -> void:
	for item in windows.values():
		if item.visible: item.refresh()
func window_state(id: int) -> Dictionary:
	for item in data.get("windows", []):
		if int(item.id) == id: return item
	return data if id == 1 else {}
func focus_window(id: int) -> void:
	if focused_window == id: return
	cancel(); menu.system_text_input.cancel("web_browser")
	if handoff: _cancel_handoff()
	focused_window = id
	if Methods.supports(menu.platform, "web_browser_command"):
		menu.platform.web_browser_command(JSON.stringify({"action": "focus", "window": id}))
	data.merge(window_state(id), true); _status_raw = ""; draft = str(data.get("url", "")); refresh_windows()
func tab_command(command: String, id: int = 0) -> void:
	cancel(); menu.system_text_input.cancel("web_browser")
	if handoff: _cancel_handoff()
	if Methods.supports(menu.platform, "web_browser_command"):
		menu.platform.web_browser_command(JSON.stringify({"action": command, "window": focused_window, "tab": id}))
	tabs_open = false; next_poll = 0
func draw() -> void: refresh_windows()
func draw_window(host: Node) -> void:
	var current := window_state(host.window_id)
	var address: String = draft if focused_window == host.window_id else str(current.get("url", ""))
	var on_screen: bool = host.on_screen()
	host._set_backdrop(Vector2(1.46, 0.17) if on_screen else Vector2(1.46, 1.09), Vector2(0.13, 0.505 if on_screen else 0.045))
	if tabs_open and focused_window == host.window_id:
		host._backdrop.visible = true; draw_tabs(host); return
	host._backdrop.visible = on_screen
	if not on_screen: host.draw_frame_panels()
	for button in [[0, -0.55, "previous", "Back"], [1, -0.455, "next", "Forward"], [2, -0.36, "refresh", "Reload"]]:
		host._button(BASE + int(button[0]), "", Vector2(button[1], 0.47), Vector2(0.08, 0.075), (button[0] == 2 or current.get("back" if button[0] == 0 else "forward", false)), button[2])
		host._tips[BASE + int(button[0])] = I18n.t(button[3])
	var title := str(current.get("title", ""))
	draw_tab_strip(host, current)
	var issue := str(data.get("operation_error", ""))
	var status := I18n.t("Finding video…") if handoff else ""
	if not str(current.get("error", "")).is_empty(): status = I18n.t("Unable to load page")
	elif menu.web_video.result.get("state", "") == "error" and (handoff or prefetch_id == 0 or int(menu.web_video.result.get("id", 0)) != prefetch_id): status = menu.web_video.error_hint()
	elif not issue.is_empty():
		var messages := {"tab_limit": "Maximum 4 tabs", "tabs_busy": "Close a tab to free memory", "window_limit": "Maximum 2 windows"}
		status = I18n.t(messages.get(issue, "Unable to open page"))
	var caption: String = status if not status.is_empty() else address if not address.is_empty() else I18n.t("Enter URL")
	host._button(BASE + 3, host._fit_title(caption, "", 0.46, host.TEXT_BODY), Vector2(-0.06, 0.47), Vector2(0.50, 0.075))
	host._tips[BASE + 3] = (title + "\n" if not title.is_empty() else "") + address
	for spec in [[4, 0.235, "star_filled" if saved.get("bookmarks", []).any(func(entry): return str(entry.url) == address) else "star", "Bookmark"],
		[8, 0.335, "screen", "Floating window" if on_screen else "Cinema screen"]]:
		var enabled: bool = (not host.cinema().is_empty()) if spec[0] == 8 else true
		host._button(BASE + int(spec[0]), "", Vector2(spec[1], 0.47), Vector2(0.08, 0.075), enabled, spec[2])
		host._tips[BASE + int(spec[0])] = I18n.t(spec[3])
	draw_play_button(host)
	if current.get("editing", false):
		host._button(KEY_CONTROL + 7, "", Vector2(0.725, 0.47), Vector2(0.08, 0.075), true, "keyboard_hide")
		host._tips[KEY_CONTROL + 7] = I18n.t("Close keyboard")
	host._button(WEB, "", RECT.get_center(), RECT.size)
	host._buttons.back().node.set_meta("menu_eye_buffer", true)
	var page: Dictionary = host.page_layout()
	host._buttons.back().node.global_transform = page.pose
	host._buttons.back().node.mesh.size = page.size
	host._buttons.back().rect.size = page.size
	if not on_screen: host.draw_resize_corners()

## The native handoff is the browser's main action: an accent pill with icon and words,
## muted on pages the player cannot take over.
func draw_play_button(host: Node) -> void:
	var ready: bool = handoff or (data.get("native_supported", false) and focused_window == host.window_id)
	var label := I18n.t("Cancel" if handoff else "Play in player")
	host._button(BASE + 6, "", Vector2(0.545, 0.47), Vector2(0.26, 0.075), ready, "", ready)
	var node: Node3D = host._buttons.back().node
	node.material_override.set_shader_parameter("corner_radius", 0.0375)
	var color: Color = host._buttons.back().foreground if ready else host.MUTED
	host._icon("stop" if handoff else "play", Vector3(-0.095, 0, 0.004), 0.036, color, node)
	var caption: Label3D = host._label(host._fit_title(label, "", 0.18, host.TEXT_BODY), Vector3(0.02, 0, 0.004), host.TEXT_BODY, node)
	caption.modulate = color
	host._tips[BASE + 6] = label

func draw_tab_strip(host: Node, current: Dictionary) -> void:
	var entries: Array = data.get("tab_list", []).filter(func(item): return int(item.window) == host.window_id)
	# An initial snapshot may arrive before Gecko's tab list. Keep its title visible.
	if entries.is_empty(): entries = [current]
	var width := minf(0.48, 1.01 / entries.size())
	for i in entries.size():
		var item: Dictionary = entries[i]
		var id := int(item.get("id", item.get("tab_id", 0)))
		var selected := id == int(current.get("tab_id", data.get("tab_id", 0)))
		var title := str(item.get("title", ""))
		if title.is_empty(): title = str(item.get("url", ""))
		if title.is_empty() or title == "about:blank": title = I18n.t("New tab")
		var left := -0.59 + i * width
		host._button(BASE + 200 + i, "", Vector2(left + (width - 0.01) / 2, 0.555), Vector2(width - 0.01, 0.065), id > 0)
		var tab: Dictionary = host._buttons.back()
		tab.base_color = Color("294b42") if selected else Color("141a22")
		tab.node.position.z = 0.004
		tab.node.material_override.set_shader_parameter("surface_color", tab.base_color)
		var label: Label3D = host._label(host._fit_title(title, "", width - 0.075, 22), Vector3(-width / 2 + 0.018, 0, 0.004), 22, tab.node)
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		label.modulate = host.ACCENT if selected else tab.foreground
		host._tips[BASE + 200 + i] = title + "\n" + str(item.get("url", ""))
		host._button(BASE + 220 + i, "", Vector2(left + width - 0.035, 0.555), Vector2(0.045, 0.05), id > 0, "close")
		var close: Dictionary = host._buttons.back()
		close.node.position.z = 0.006
		close.base_color = Color(0, 0, 0, 0)
		close.node.material_override.set_shader_parameter("surface_color", close.base_color)
		host._tips[BASE + 220 + i] = I18n.t("Close") + " · " + title
	for item in [[14, 0.46, "plus", "New tab"], [7, 0.54, "chevron_down", "Tabs"], [5, 0.80, "close", "Close"]]:
		host._button(BASE + int(item[0]), "", Vector2(item[1], 0.555), Vector2(0.065, 0.055), item[0] != 14 or data.get("tab_list", []).size() < 4, item[2])
		host._tips[BASE + int(item[0])] = I18n.t(item[3])
	# Reserve a visible drag target even with four tabs; grip can still grab anywhere.
	host._button(host.MOVE, "", Vector2(0.655, 0.555), Vector2(0.14, 0.055), not host.on_screen())
	var drag: Dictionary = host._buttons.back()
	drag.base_color = Color(0, 0, 0, 0)
	drag.node.material_override.set_shader_parameter("surface_color", drag.base_color)
	for x in [-0.007, 0.007]:
		for y in [-0.012, 0.0, 0.012]:
			drag.node.add_child(host._quad(Vector2(0.004, 0.004), Vector3(x, y, 0.004), host.MUTED, 12))
	host._tips[host.MOVE] = I18n.t("Move window")

func draw_tabs(host: Node) -> void:
	host._set_backdrop(Vector2(1.46, 1.12), Vector2(0.13, 0.04))
	host._label(I18n.t("Tabs"), Vector3(-0.43, 0.48, 0.006), 28)
	host._button(BASE + 7, I18n.t("Back"), Vector2(0.64, 0.48), Vector2(0.30, 0.07))
	var entries: Array = data.get("tab_list", []).filter(func(item): return int(item.window) == host.window_id)
	for i in entries.size():
		var item: Dictionary = entries[i]; var y := 0.31 - i * 0.15
		var title := str(item.get("title", "")) if not str(item.get("title", "")).is_empty() else str(item.url)
		host._button(BASE + 200 + i, "", Vector2(-0.05, y), Vector2(0.96, 0.12), true, "", int(item.id) == int(window_state(host.window_id).get("tab_id", 0)))
		var button: Dictionary = host._buttons.back()
		host._icon("pause" if item.get("sleeping", false) else "globe", Vector3(-0.41, 0, 0.004), 0.045, button.foreground, button.node)
		var label: Label3D = host._label(host._fit_title(title, "", 0.76, 26), Vector3(-0.35, 0, 0.004), 26, button.node)
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT; label.modulate = button.foreground
		host._button(BASE + 210 + i, "", Vector2(0.53, y), Vector2(0.10, 0.08), true, "expand" if host.window_id == 1 else "collapse")
		host._tips[BASE + 210 + i] = I18n.t("Move to new window" if host.window_id == 1 else "Move to main window")
		host._button(BASE + 220 + i, "", Vector2(0.73, y), Vector2(0.10, 0.08), true, "close")
	host._button(BASE + 14, I18n.t("New tab"), Vector2(0.13, -0.38), Vector2(0.45, 0.07), data.get("tab_list", []).size() < 4, "plus")

func action(target: int) -> bool:
	if not Distribution.web_browser_enabled(): return false
	if library.action(target): return true
	if active() and target == KEY_CONTROL + 7:
		menu.platform.web_browser_input("close", ""); refresh_windows(); return true
	if active() and target >= BASE + 200 and target < BASE + 224:
		var entries: Array = data.get("tab_list", []).filter(func(item): return int(item.window) == focused_window)
		var index := (target - BASE - 200) % 10
		if index < entries.size():
			var operation := "select" if target < BASE + 210 else ("detach" if focused_window == 1 else "merge") if target < BASE + 220 else "close"
			tab_command(operation, int(entries[index].id))
		return true
	if not active() or target < BASE or target > WEB: return false
	match target - BASE:
		0: menu.platform.web_browser_action("back"); refresh_windows()
		1: menu.platform.web_browser_action("forward"); refresh_windows()
		2: menu.platform.web_browser_action("reload"); refresh_windows()
		3:
			refresh_windows()
			menu.platform.web_browser_action("blur")
			menu.system_text_input.begin("web_browser", draft, 4096, _edited, _navigate)
		4: menu.platform.web_browser_action("bookmark"); saved_poll = 0; refresh_windows()
		5:
			if focused_window == 2:
				for item in data.get("tab_list", []).filter(func(entry): return int(entry.window) == 2): tab_command("merge", int(item.id))
			else: close(); menu.refresh()
		7:
			menu.system_text_input.cancel("web_browser")
			menu.platform.web_browser_action("blur")
			tabs_open = not tabs_open; refresh_windows()
		8:
			if windows.has(focused_window):
				var host: Node = windows[focused_window]
				host.set_mode("floating" if host.on_screen() else "cinema")
				if host.mode == "cinema":
					for other in windows.values():
						if other != host: other.set_mode("floating"); other.save_layout()
				host.save_layout(); refresh_windows()
		14: tab_command("new")
		6:
			if handoff:
				_handoff_failed(); menu.refresh()
			else:
				if not data.get("native_supported", false): return true
				_begin_handoff()
				menu.refresh()
	return true

func _playhead() -> int:
	var best := {}; var score := -1.0
	for item in data.get("videos", []):
		var area := float(item.get("width", 0)) * float(item.get("height", 0))
		var candidate := area + (1.0e12 if item.get("playing", false) else 0.0) + (1.0e15 if item.get("fullscreen", false) else 0.0)
		if candidate > score: score = candidate; best = item
	var seconds := float(best.get("time", 0.0))
	return int(clampf(seconds, 0.0, 604800.0) * 1000.0) if is_finite(seconds) else 0

func _edited(text: String) -> void: draft = text; menu.refresh()
func _navigate(text: String) -> void:
	if handoff: _cancel_handoff()
	draft = text.strip_edges()
	if not draft.is_empty(): menu.platform.web_browser_navigate(draft)
	menu.refresh()

func choose(row: Dictionary) -> bool:
	if not row.has("web_browser"): return false
	match str(row.web_browser):
		"open": open()
		"visit": open(str(row.get("url", "")))
		"bookmarks", "history": library.reset(); list_mode = str(row.web_browser); saved_poll = 0; menu.scroll = 0; menu.refresh()
		"home": library.reset(); list_mode = ""; menu.scroll = 0; menu.refresh()
		"select": library.choose(str(row.get("url", "")))
	return true

func saved_rows() -> Array:
	return library.rows()
func uv(p: Vector3) -> Vector2:
	return Vector2((p.x - RECT.position.x) / RECT.size.x, 1.0 - (p.y - RECT.position.y) / RECT.size.y)
func input_host() -> Node: return windows.get(1, menu)
func _pointer(command: String, location: Vector2, scroll: float = 0.0) -> void:
	if Methods.supports(menu.platform, "web_browser_window_pointer"):
		menu.platform.web_browser_window_pointer(pointer_window, command, location.x, location.y, scroll)
	else: menu.platform.web_browser_pointer(command, location.x, location.y, scroll)
func press(owner: String, origin: Vector3, direction: Vector3, tracked: bool) -> bool:
	if not active(): return false
	if not hand.is_empty(): return true
	var hit: Dictionary = input_host().ray_hit(origin, direction) if tracked else {}
	if int(hit.get("target", -1)) != WEB: return false
	pointer_window = int(hit.get("window", 1)); focus_window(pointer_window)
	var location: Variant = windows[pointer_window].page_point(origin, direction)
	if location == null: return false
	hand = owner; point = location; _pointer("down", point); return true
func move(owner: String, origin: Vector3, direction: Vector3, tracked: bool) -> void:
	if not active(): return
	if hand == owner:
		var projected: Variant = windows[pointer_window].page_point(origin, direction) if tracked else null
		if projected == null: cancel(); return
		if projected.distance_squared_to(point) < 1.0e-8: return
		point = projected; _pointer("move", point)
	elif hand.is_empty() and tracked:
		var hit: Dictionary = input_host().ray_hit(origin, direction)
		if int(hit.get("target", -1)) == WEB:
			var id := int(hit.get("window", 1))
			if id == focused_window:
				# A resting ray must not make Gecko hit-test the page every frame.
				var hover: Variant = windows[id].page_point(origin, direction)
				if hover == null or (id == pointer_window and hover.distance_squared_to(point) < 1.0e-8): return
				pointer_window = id; point = hover; _pointer("move", point)
func release(owner: String, origin: Vector3, direction: Vector3, tracked: bool) -> bool:
	if hand != owner: return false
	var projected: Variant = windows[pointer_window].page_point(origin, direction) if tracked else null
	if projected == null or not Rect2(Vector2.ZERO, Vector2.ONE).has_point(projected): cancel()
	else: _pointer("up", projected); hand = ""
	return true
func cancel() -> void:
	if not hand.is_empty() and supported(): _pointer("cancel", point)
	hand = ""
func scroll(amount: float, delta: float) -> bool:
	if library.active() and not library.modal.is_empty(): return true
	if not active(): return false
	if tabs_open: return true
	if hand.is_empty() and is_finite(amount) and absf(amount) > 0.2:
		pointer_window = focused_window; _pointer("scroll", point, amount * delta * 8.0)
	return true
