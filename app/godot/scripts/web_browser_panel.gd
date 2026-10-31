extends RefCounted

const Distribution := preload("res://scripts/distribution_channel.gd")
const I18n := preload("res://scripts/i18n.gd")
const Methods := preload("res://scripts/platform_methods.gd")
const BASE := 986000
const WEB := BASE + 20
const KEY := BASE + 100
const KEY_CONTROL := BASE + 40
const WINDOW_TARGET := BASE + 300
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
var window_action := {}
var opening := false
var force_floating_on_open := false
var handoff_tab := 0
var handoff_navigation := 0
var cinema_provider: Callable
var cinema_video_provider: Callable
var next_poll := 0
var handoff := false
var handoff_uri := ""
var pause_started := 0
var last_pause_token := 0
var handoff_start_ms := 0
var handoff_auto := false
var handoff_beta := false
var handoff_waiting_pause := false
var handoff_started_ms := 0
var capture_started_ms := 0
var handoff_context := {}
var handoff_error := {}
# Background resolution of the video already playing on a supported page, so a later
# fullscreen hands off immediately instead of starting extraction from zero.
const PREFETCH_DELAY_MS := 3000
const PREFETCH_FRESH_MS := 600000
var prefetch_uri := ""
var prefetch_id := 0
var prefetch_result := {}
var prefetch_ms := 0
var prefetch_media_key := ""
var playing_since := 0
var fullscreen_seen := {}
var playback_return := {}
var _signature := ""
var list_mode := ""
var saved := {}
var saved_poll := 0
var _saved_raw := ""
var _status_raw := ""
var _beta_page := RegEx.create_from_string("^https://www\\.bilibili\\.com/(?:video/(?:BV[A-Za-z0-9]+|av[0-9]+)|bangumi/play/(?:ep|ss)[1-9][0-9]{0,19})/?(?:[?#].*)?$")
var library := preload("res://scripts/web_browser_library_panel.gd").new(self)
var start_page := preload("res://scripts/web_browser_start_page.gd").new(self)
var focus_regions := {} # Session-local, follows a tab when moved to another window.

func _init(owner: Node) -> void: menu = owner
func configure_quality(value: bool) -> void:
	low_end = value
	if OS.get_name() != "Android": return
	preload("res://scripts/web_browser_layer.gd").initialize()
	# Gecko's process-wide density must be selected before navigation or extraction
	# starts it. Reuse the selected tier after an Activity/runtime recreation.
	var bridge := JavaClassWrapper.wrap("org.vrpassthroughplayer.plugin.WebBrowserSurfaceBridge")
	if bridge and not JavaClassWrapper.get_exception():
		var selected: bool = bridge.configureViewport(value)
		if not JavaClassWrapper.get_exception(): low_end = selected
func supported() -> bool: return Distribution.web_browser_enabled() and Methods.supports(menu.platform, "web_browser_navigate")
func active() -> bool: return opened and menu.visible and menu.section == menu.Section.WEB
func cinema_video_active() -> bool:
	return cinema_video_provider.is_valid() and bool(cinema_video_provider.call())

func open(url: String = "") -> void:
	if not supported(): return
	menu.browser_opened.emit()
	if menu.compact: menu.layout_requested.emit()
	opened = true
	opening = true
	force_floating_on_open = cinema_video_active()
	menu.clear_pointer_visuals()
	# Keep a hidden input router while waiting for the native session snapshot.
	if windows.is_empty(): ensure_window(1, false)
	# An existing cinema movie keeps its screen, including when saved web layouts used it.
	if cinema_video_active():
		for item in windows.values(): item.set_mode("floating")
	if not url.is_empty():
		draft = url; menu.platform.web_browser_navigate(url)
	else: menu.platform.web_browser_action("resume")
	next_poll = 0; menu.refresh()

func close(force_release: bool = false) -> void:
	cancel()
	if handoff: _cancel_handoff()
	library.reset()
	if handoff or (prefetch_id > 0 and menu.web_video.pending == prefetch_id): menu.web_video.close()
	prefetch_id = 0; playing_since = 0
	menu.system_text_input.cancel("web_browser")
	if (opened or force_release) and supported(): menu.platform.web_browser_action("hibernate")
	opened = false; handoff = false; handoff_waiting_pause = false; pause_started = 0
	opening = false; window_action.clear()
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
	var next_focus := int(data.get("focused_window", 1))
	if focused_window != next_focus:
		cancel(); menu.system_text_input.cancel("web_browser")
		tabs_open = false; window_action.clear(); _signature = ""
	focused_window = next_focus
	if window_action.get("command") == "move_tab" and not data.get("tab_list", []).any(func(item): return int(item.id) == int(window_action.get("tab", 0)) and int(item.window) == focused_window):
		window_action.clear()
	var ids := live_window_ids()
	var tabs: Array = data.get("tab_list", [])
	if not tabs.is_empty():
		for id in focus_regions.keys():
			if not tabs.any(func(item): return int(item.id) == id): focus_regions.erase(id)
	if opening and data.get("active", false) and not ids.is_empty(): opening = false
	if not opening and ids.is_empty():
		close(); list_mode = ""; menu.refresh(); return
	paired_layout = ids.size() > 1
	for item in windows.values():
		if item.visible and item.window_id not in ids:
			cancel(); item.save_layout(); item.dismiss(); item.placed = false
	for id in ids:
		var created: bool = not windows.has(id) or not windows[id].placed
		ensure_window(id)
		windows[id].sync_page_state()
		if (created and windows.values().any(func(item): return item.window_id != id and item.visible and item.on_screen())) or force_floating_on_open:
			windows[id].set_mode("floating")
	if not opening: force_floating_on_open = false
	if handoff and (str(data.get("url", "")) != handoff_uri or int(data.get("tab_id", 0)) != handoff_tab or int(data.get("navigation", 0)) != handoff_navigation):
		_cancel_handoff()
	if not menu.system_text_input.active("web_browser"):
		draft = "" if data.get("url", "") == "about:blank" else str(data.get("url", ""))
	_poll_prefetch()
	_poll_fullscreen()
	if handoff and Time.get_ticks_msec() - handoff_started_ms > (30000 if handoff_beta else 90000):
		menu.web_video.result = {"error_code": "timeout"}
		_handoff_failed()
	if handoff and handoff_waiting_pause:
		if _pause_confirmed():
			handoff_waiting_pause = false
			handoff_start_ms = _playhead()
			handoff_context.position_ms = handoff_start_ms
			menu.web_video.resolve(true)
			if menu.web_video.pending == 0: _handoff_failed()
		elif Time.get_ticks_msec() - pause_started > 5000:
			menu.web_video.result = {"error_code": "browser_pause_timeout"}
			_handoff_failed()
	if handoff and not handoff_waiting_pause and menu.web_video.pending == 0:
		if menu.web_video.result.get("state", "") == "ready":
			if pause_started == 0:
				if not handoff_auto or _capture_ready():
					handoff_start_ms = _playhead()
					if handoff_auto: handoff_context.position_ms = handoff_start_ms
					pause_started = Time.get_ticks_msec()
					handoff_context.pause_token = _next_pause_token()
					_video_command("pause_tab", handoff_context)
			elif _pause_confirmed():
				var automatic := handoff_auto
				if not handoff_beta: _keep_prefetch(handoff_uri, menu.web_video.result)
				playback_return = handoff_context.duplicate(true)
				playback_return.native_uri = str(menu.web_video.result.get("uri", ""))
				# Complete the hold without resuming; parked/peer pages must accept
				# later deliberate user playback after returning from the player.
				_video_command("resume_tab", handoff_context.merged({"was_playing": false}, true))
				handoff = false; pause_started = 0
				handoff_auto = false
				menu.web_video.choose({"web_video": "play", "start_ms": handoff_start_ms, "web_fullscreen": automatic, "keep_browser": live_window_ids().size() > 1}); return
			elif Time.get_ticks_msec() - pause_started > 5000:
				menu.web_video.result = {"error_code": "browser_pause_timeout"}
				_handoff_failed()
		else: _handoff_failed()
	# Only fields the chrome draws. Window states also carry each video's advancing time;
	# comparing those rebuilt every browser window four times a second during playback.
	var chrome: Array = data.get("windows", []).map(func(item): return [item.get("id"), item.get("tab_id"), item.get("url"),
		item.get("title"), item.get("back"), item.get("forward"), item.get("error"), item.get("editing"), item.get("loading"), item.get("start_page"), item.get("network_capture_available"), item.get("network_capture_enabled"), item.get("bilibili_beta_available"), beta_media_ready(item)])
	var signature := str([draft, data.get("back"), data.get("forward"), data.get("error"), handoff_error,
		chrome, not (cinema_provider.call() if cinema_provider.is_valid() else {}).is_empty(), data.get("tab_list", []), data.get("operation_error", ""), data.get("loading"), data.get("start_page"), data.get("videos", []).size(), handoff, handoff_beta, data.get("editing", false), data.get("network_capture_available"), data.get("network_capture_enabled"), data.get("bilibili_beta_available"), beta_media_ready(data), menu.web_video.result.get("state", "")])
	if signature != _signature and hand.is_empty():
		# Do not consume changes while the page owns the pointer: release must redraw
		# even if media readiness and the rest of the native snapshot stay unchanged.
		_signature = signature
		menu.refresh()

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
	# Browsing beside an existing cinema presentation must not replace it automatically.
	# The explicit Play in player action remains available.
	if cinema_video_active() or (paired_layout and windows.values().any(func(item): return item.visible and item.on_screen())): return
	# Encrypted video stays in the website-owned playback path.
	if data.get("videos", []).any(func(item): return item.get("fullscreen", false) and item.get("protected", false)): return
	_begin_handoff(true)

func _begin_handoff(automatic: bool = false, beta: bool = false) -> void:
	if beta:
		# The button snapshot can be one poll behind a sidebar navigation or media change.
		# Revalidate before pausing or disturbing an existing resolver.
		var fresh: Variant = JSON.parse_string(menu.platform.web_browser_status())
		if not fresh is Dictionary or not fresh.get("bilibili_beta_available", false) or not beta_media_ready(fresh): return
		if int(fresh.get("focused_window", 1)) != focused_window: return
		for key in ["url", "tab_id", "navigation"]:
			if fresh.get(key) != data.get(key): return
		data = fresh; _status_raw = ""
	if handoff: _cancel_handoff()
	handoff_error.clear()
	handoff_auto = automatic
	handoff_beta = beta
	handoff_waiting_pause = false
	handoff_started_ms = Time.get_ticks_msec(); pause_started = 0; capture_started_ms = 0
	handoff_uri = str(data.get("url", ""))
	handoff_tab = int(data.get("tab_id", 0)); handoff_navigation = int(data.get("navigation", 0))
	handoff_context = {"tab": handoff_tab, "window": focused_window, "navigation": handoff_navigation,
		"fullscreen": automatic,
		"origin": handoff_uri, "request": int(data.get("fullscreen_request", 0)), "position_ms": _playhead(),
		"was_playing": data.get("videos", []).any(func(item): return (not automatic or item.get("fullscreen", false)) and item.get("playing", false))}
	menu.web_video.address = handoff_uri
	_refresh_media_key()
	if beta:
		# Never adopt an extractor result or pending legacy prefetch for the Beta button.
		if menu.web_video.pending > 0: menu.web_video.close()
		menu.web_video.result = {}
		prefetch_uri = ""; prefetch_result = {}; prefetch_id = 0; playing_since = 0
		handoff = true
		_begin_beta_pause()
		return
	# Media servers can advance episodes/versions without changing the page URL.
	if data.get("videos", []).any(func(item): return item.get("server_media", false) or item.get("server_play", false)):
		prefetch_uri = ""; prefetch_result = {}; prefetch_id = 0
	if prefetch_uri == handoff_uri and prefetch_id > 0 and menu.web_video.pending == prefetch_id:
		handoff = true # Adopt the extraction that is already running for this page.
		return
	if prefetch_uri == handoff_uri and not prefetch_result.is_empty() and Time.get_ticks_msec() - prefetch_ms < PREFETCH_FRESH_MS:
		if menu.web_video.pending > 0: menu.web_video.close()
		menu.web_video.result = prefetch_result.duplicate(true); handoff = true
		return
	menu.web_video.resolve(); handoff = menu.web_video.pending > 0
	prefetch_uri = handoff_uri; prefetch_id = 0; prefetch_result = {}
	if not handoff: _handoff_failed()

func _poll_prefetch() -> void:
	_refresh_media_key()
	if cinema_video_active(): return
	if data.get("videos", []).any(func(item): return item.get("server_media", false) or item.get("server_play", false)): return
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

func _refresh_media_key() -> void:
	# Feeds and SPA players can replace a video without changing the address. Never reuse
	# their previous representation; new network media or a quality change also invalidate it.
	var keys: Array[String] = []
	for item in data.get("videos", []):
		if item.has("media_epoch"):
			keys.append(str(item.media_epoch) + ":%dx%d" % [int(item.get("width", 0)), int(item.get("height", 0))] + (":network" if item.get("network_media", false) else ""))
	keys.sort()
	var key := "|".join(keys) + (":capture" if data.get("network_capture_enabled", false) else "")
	if key == prefetch_media_key: return
	prefetch_media_key = key
	if prefetch_id > 0 and menu.web_video.pending == prefetch_id: menu.web_video.close()
	prefetch_uri = ""; prefetch_result = {}; prefetch_id = 0; playing_since = 0

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

func beta_media_ready(current: Dictionary) -> bool:
	return current.get("videos", []).any(func(item): return item.get("bilibili_ready", false) and not item.get("protected", false))

func handoff_status() -> String:
	if handoff_waiting_pause: return I18n.t("Pausing web video…")
	return I18n.t("Finding video…")

func _begin_beta_pause() -> void:
	handoff_waiting_pause = true
	pause_started = maxi(1, Time.get_ticks_msec())
	handoff_context.pause_token = _next_pause_token()
	_video_command("pause_tab", handoff_context)

func _next_pause_token() -> int:
	last_pause_token = maxi(last_pause_token + 1, Time.get_ticks_msec() + 1)
	return last_pause_token

func _pause_confirmed() -> bool:
	var current := window_state(focused_window)
	return int(current.get("pause_token", 0)) == int(handoff_context.get("pause_token", -1)) and bool(current.get("pause_confirmed", not current.get("playing", true)))

func _cancel_handoff() -> void:
	menu.web_video.close()
	if pause_started > 0: _video_command("resume_tab", handoff_context.merged({"restore_paused": true}, true))
	handoff = false; handoff_auto = false; handoff_waiting_pause = false; pause_started = 0; handoff_context = {}

func _handoff_failed() -> void:
	var automatic := handoff_auto
	var paused := pause_started > 0
	var context := handoff_context.duplicate(true)
	if not automatic: handoff_error = context.merged({"message": menu.web_video.error_hint()})
	_cancel_handoff()
	menu.web_video.result = {}
	if automatic:
		menu.web_video.result = {}
		if paused:
			context.play = bool(context.get("was_playing", false)); context.exit_fullscreen = false
			_video_command("restore_video", context)

func owns_handoff(host: Node, context: Dictionary) -> bool:
	var current := window_state(host.window_id)
	return not context.is_empty() and int(context.get("window", 0)) == host.window_id and int(context.get("tab", 0)) == int(current.get("tab_id", 0)) and int(context.get("navigation", 0)) == int(current.get("navigation", 0)) and str(context.get("origin", "")) == str(current.get("url", ""))

func prepare_native_playback() -> void:
	# Explicit player takeover owns the cinema screen. Keep browser pages available
	# as floating windows; no second extraction or playback request is issued.
	for item in windows.values():
		if item.visible and item.on_screen(): item.set_mode("floating")
	refresh_windows()

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

func live_window_ids() -> Array:
	if data.has("windows"):
		return data.windows.filter(func(item): return int(item.get("tab_id", 0)) > 0).map(func(item): return int(item.id))
	return [int(data.get("focused_window", 1))] if not data.get("url", "").is_empty() else []
func max_windows() -> int: return int(data.get("max_windows", 2 if low_end else 4))
func default_window_offset(id: int) -> Vector3:
	var peers: Array = windows.values().filter(func(item): return item.window_id != id and item.visible)
	if peers.is_empty(): return Vector3(0, -0.05, -1.8)
	var frame: Transform3D = preload("res://scripts/interface_move.gd").menu_head(peers[0].head())
	var candidates := [Vector3(1.55, -0.05, -2.2), Vector3(-1.55, -0.05, -2.2), Vector3(0, 1.15, -2.2), Vector3(0, -1.25, -2.2)]
	var best: Vector3 = candidates[0]; var clearance := -1.0
	for candidate in candidates:
		var gap := INF
		for peer in peers: gap = minf(gap, (frame * candidate).distance_to(peer.to_global(peer.move_centre())))
		if gap > clearance: best = candidate; clearance = gap
	return best
func ensure_window(id: int, show: bool = true) -> void:
	if not menu.is_inside_tree(): return
	if not windows.has(id):
		var item := preload("res://scripts/web_browser_window.gd").new()
		item.configure(self, id); menu.get_tree().root.add_child(item); windows[id] = item
		if window_created.is_valid(): window_created.call(item)
		menu.tree_exiting.connect(item.queue_free, CONNECT_ONE_SHOT)
	if show and not windows[id].visible: windows[id].show_window()
func refresh_windows() -> void:
	for item in windows.values():
		if item.visible: item.refresh()
func window_state(id: int) -> Dictionary:
	for item in data.get("windows", []):
		if int(item.id) == id: return item
	return data if id == int(data.get("focused_window", 1)) else {}
func focus_window(id: int) -> void:
	if focused_window == id: return
	window_action.clear()
	cancel(); menu.system_text_input.cancel("web_browser")
	if handoff: _cancel_handoff()
	focused_window = id
	if Methods.supports(menu.platform, "web_browser_command"):
		menu.platform.web_browser_command(JSON.stringify({"action": "focus", "window": id}))
	data.merge(window_state(id), true); _status_raw = ""; draft = str(data.get("url", "")); refresh_windows()
func tab_command(command: String, id: int = 0, destination: int = 0) -> void:
	cancel(); menu.system_text_input.cancel("web_browser")
	for item in windows.values(): item.end_drag(); item.clear_pointer_visuals()
	if handoff: _cancel_handoff()
	if Methods.supports(menu.platform, "web_browser_command"):
		menu.platform.web_browser_command(JSON.stringify({"action": command, "window": focused_window, "tab": id, "destination": destination}))
	tabs_open = false; window_action.clear(); next_poll = 0
func draw() -> void: refresh_windows()
func draw_window(host: Node) -> void:
	var current := window_state(host.window_id)
	var address: String = draft if focused_window == host.window_id else str(current.get("url", ""))
	var on_screen: bool = host.on_screen()
	var bounds: Rect2 = host.page_rect()
	host._set_backdrop(host.HEADER.size if on_screen else bounds.size + Vector2(0.02, host.HEADER.size.y + 0.02), host.HEADER.get_center() if on_screen else Vector2(bounds.get_center().x, bounds.get_center().y + (host.HEADER.size.y - 0.02) / 2))
	if tabs_open and focused_window == host.window_id:
		host._backdrop.visible = true; draw_tabs(host); return
	var home: bool = start_page.active(host.window_id)
	if home and on_screen: host._set_backdrop(Vector2(1.46, 1.356), Vector2(0.13, 0.158))
	host._backdrop.visible = on_screen or home
	if not on_screen: host.draw_frame_panels()
	for button in [[0, -0.53, "previous", "Back"], [1, -0.402, "next", "Forward"], [2, -0.274, "refresh", "Reload"]]:
		host._button(BASE + int(button[0]), "", Vector2(button[1], host.NAV_Y), host.TOOL_SIZE, (button[0] == 2 or current.get("back" if button[0] == 0 else "forward", false)), button[2])
		host._tips[BASE + int(button[0])] = I18n.t(button[3])
	var title := str(current.get("title", ""))
	draw_tab_strip(host, current)
	var issue := str(data.get("operation_error", "")) if host.window_id == focused_window else ""
	var status := handoff_status() if handoff and owns_handoff(host, handoff_context) else ""
	if host.selecting: status = I18n.t("Drag to select")
	if not str(current.get("error", "")).is_empty(): status = I18n.t("Unable to load page")
	elif owns_handoff(host, handoff_error): status = str(handoff_error.message)
	elif not issue.is_empty():
		var messages := {"tab_limit": "Maximum 4 tabs", "tabs_busy": "Close a tab to free memory", "window_limit": "Window limit reached",
			"invalid_address": "Invalid address", "bookmark_limit": "Bookmark limit reached", "storage_failed": "Unable to save changes"}
		status = I18n.t(messages.get(issue, "Unable to open page"))
	var caption: String = status if not status.is_empty() else address if not address.is_empty() else I18n.t("Enter URL")
	host._button(BASE + 3, host._fit_title(caption, "", 0.76, 22), Vector2(0.194, host.NAV_Y), Vector2(0.80, host.TOOL_SIZE.y))
	host._tips[BASE + 3] = (status + "\n" if not status.is_empty() else "") + (title + "\n" if not title.is_empty() else "") + address
	# Native canonicalisation matches storage (e.g. Emby's #!/home route), not the URL draft.
	var bookmark_url := str(current.get("bookmark_url", str(current.get("url", "")).split("#", true, 1)[0]))
	for spec in [[4, 0.662, "star_filled" if saved.get("bookmarks", []).any(func(entry): return str(entry.url) == bookmark_url) else "star", "Bookmark"],
		[7, 0.79, "chevron_down", "Tabs"]]:
		host._button(BASE + int(spec[0]), "", Vector2(spec[1], host.NAV_Y), host.TOOL_SIZE, not home if spec[0] == 4 else true, spec[2])
		host._tips[BASE + int(spec[0])] = I18n.t(spec[3])
	draw_play_button(host)
	draw_toolbar_tools(host, current)
	# One legible type size for toolbar captions; icon geometry already follows the larger tiles.
	for button in host._buttons:
		button.node.material_override.set_shader_parameter("corner_radius", 0.014)
		for label in button.node.get_children():
			if label is Label3D:
				host.set_label_size(label, 22)
				if not button.enabled: label.modulate = host.MUTED
	if not on_screen:
		var offset := (bounds.size.x - RECT.size.x) / 2
		for button in host._buttons:
			button.node.position.x += offset; button.rect.position.x += offset
		for label in host._labels: label.position.x += offset
		for decoration in host._decorations:
			if not host._pointer_panels.has(decoration): decoration.position.x += offset
	if home: start_page.draw(host)
	else:
		host._button(WEB, "", bounds.get_center(), bounds.size)
		host._buttons.back().node.set_meta("menu_eye_buffer", true)
		var page: Dictionary = host.page_layout()
		host._buttons.back().node.global_transform = page.pose
		host._buttons.back().node.mesh.size = page.size
		host._buttons.back().rect.size = page.size
	if not on_screen: host.draw_resize_handles()

## The native handoff is the browser's main action: an accent pill with icon and words,
## muted on pages the player cannot take over.
func beta_available(current: Dictionary) -> bool:
	# This is presentation capability, not permission/readiness to hand off. A known
	# Bilibili video keeps its action while transient native state is being rebuilt.
	return Methods.supports(menu.platform, "web_video_resolve_beta") and (current.get("bilibili_beta_available", false) or _beta_page.search(str(current.get("url", ""))) != null)

func toolbar_tools(host: Node, current: Dictionary) -> Array:
	var result: Array = []
	if not host.cinema().is_empty(): result.append(BASE + 8)
	result.append(BASE + 19)
	if current.get("editing", false): result.append(KEY_CONTROL + 7)
	elif current.get("network_capture_available", false): result.append(BASE + 15)
	result.append(host.MOVE)
	return result

func draw_toolbar_tools(host: Node, current: Dictionary) -> void:
	var entries := toolbar_tools(host, current)
	var icons := {BASE + 8: "floating_window" if host.on_screen() else "cinema_screen",
		BASE + 19: "close" if host.selecting else "expand" if host.is_focused() else "region_focus",
		KEY_CONTROL + 7: "keyboard_hide", BASE + 15: "media_detect", host.MOVE: ""}
	var tips := {BASE + 8: "Floating window" if host.on_screen() else "Cinema screen",
		BASE + 19: "Cancel selection" if host.selecting else "Exit focus" if host.is_focused() else "Focus region",
		KEY_CONTROL + 7: "Close keyboard", BASE + 15: "Media detection on this site", host.MOVE: "Move window"}
	for i in entries.size():
		var target: int = entries[i]
		var selected: bool = (host.is_focused() or host.selecting) if target == BASE + 19 else current.get("network_capture_enabled", false) if target == BASE + 15 else false
		host._button(target, "", Vector2(0.79 - (entries.size() - 1 - i) * 0.128, host.PLAY_Y), host.TOOL_SIZE, not start_page.active(host.window_id) if target == BASE + 19 else true, icons[target], selected)
		host._tips[target] = I18n.t(tips[target])
		if target == BASE + 15: host._tips[target] += " · " + I18n.t("On" if selected else "Off") + "\n" + I18n.t("Replay the video after enabling")
		if target == host.MOVE:
			for x in [-0.012, 0.012]:
				for y in [-0.024, 0.0, 0.024]:
					host._buttons.back().node.add_child(host._quad(Vector2(0.008, 0.008), Vector3(x, y, 0.004), host.MUTED, 12))

func draw_play_button(host: Node) -> void:
	var own: bool = handoff and owns_handoff(host, handoff_context)
	var beta := beta_available(window_state(host.window_id))
	var cancel_old: bool = own and not handoff_beta
	var ready: bool = cancel_old or (not handoff and data.get("native_supported", false) and focused_window == host.window_id)
	var label := I18n.t("Cancel" if cancel_old else "Play in player")
	var space := 1.44 - toolbar_tools(host, window_state(host.window_id)).size() * 0.128
	var width := (space - 0.008) / 2 if beta else space
	host._button(BASE + 6, "", Vector2(-0.59 + width / 2, host.PLAY_Y), Vector2(width, host.TOOL_SIZE.y), ready, "", ready)
	var node: Node3D = host._buttons.back().node
	node.material_override.set_shader_parameter("corner_radius", 0.035)
	var color: Color = host._buttons.back().foreground if ready else host.MUTED
	host._icon("stop" if cancel_old else "play", Vector3(-width / 2 + 0.045, 0, 0.004), 0.05, color, node)
	var caption: Label3D = host._label(host._fit_title(label, "", width - 0.10, 22), Vector3(0.025, 0, 0.004), 22, node)
	caption.modulate = color
	host._tips[BASE + 6] = label
	if beta:
		var cancel_beta: bool = own and handoff_beta
		var current := window_state(host.window_id)
		var media_ready: bool = current.get("bilibili_beta_available", false) and beta_media_ready(current)
		var beta_ready: bool = cancel_beta or (not handoff and focused_window == host.window_id and media_ready)
		var beta_label := I18n.t("Cancel" if cancel_beta else "Play (Beta)")
		host._button(BASE + 18, beta_label, Vector2(-0.59 + width * 1.5 + 0.008, host.PLAY_Y), Vector2(width, host.TOOL_SIZE.y), beta_ready, "", beta_ready)
		host._tips[BASE + 18] = I18n.t("Cancel" if cancel_beta else ("Play in player (Beta)" if media_ready else "Video not ready"))

func draw_tab_strip(host: Node, current: Dictionary) -> void:
	var entries: Array = data.get("tab_list", []).filter(func(item): return int(item.window) == host.window_id)
	# An initial snapshot may arrive before Gecko's tab list. Keep its title visible.
	if entries.is_empty(): entries = [current]
	var width := (1.184 - (entries.size() - 1) * 0.008) / entries.size()
	for i in entries.size():
		var item: Dictionary = entries[i]
		var id := int(item.get("id", item.get("tab_id", 0)))
		var selected := id == int(current.get("tab_id", data.get("tab_id", 0)))
		var title := str(item.get("title", ""))
		if title.is_empty(): title = str(item.get("url", ""))
		if title.is_empty() or title == "about:blank": title = I18n.t("New tab")
		var left := -0.59 + i * (width + 0.008)
		var title_width := width - 0.128
		host._button(BASE + 200 + i, "", Vector2(left + title_width / 2, host.TABS_Y), Vector2(title_width, host.TOOL_SIZE.y), id > 0)
		var tab: Dictionary = host._buttons.back()
		tab.base_color = Color("294b42") if selected else Color("141a22")
		tab.node.position.z = 0.004
		tab.node.material_override.set_shader_parameter("surface_color", tab.base_color)
		var label: Label3D = host._label(host._fit_title(title, "", title_width - 0.024, 22), Vector3(-title_width / 2 + 0.012, 0, 0.004), 22, tab.node)
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		label.modulate = host.ACCENT if selected else tab.foreground
		host._tips[BASE + 200 + i] = title + "\n" + str(item.get("url", ""))
		host._button(BASE + 220 + i, "", Vector2(left + width - 0.06, host.TABS_Y), host.TOOL_SIZE, id > 0, "close")
		var close: Dictionary = host._buttons.back()
		close.node.position.z = 0.006
		close.base_color = tab.base_color
		close.node.material_override.set_shader_parameter("surface_color", close.base_color)
		host._tips[BASE + 220 + i] = I18n.t("Close tab") + " · " + title
	for item in [[14, 0.662, "plus", "New tab"], [5, 0.79, "close", "Close window"]]:
		var enabled: bool = item[0] != 14 or data.get("tab_list", []).size() < 4
		host._button(BASE + int(item[0]), "", Vector2(item[1], host.TABS_Y), host.TOOL_SIZE, enabled, item[2])
		host._tips[BASE + int(item[0])] = I18n.t(item[3])

func draw_tabs(host: Node) -> void:
	host._set_backdrop(Vector2(1.46, 1.12), Vector2(0.13, 0.04))
	host._label(I18n.t("Tabs" if window_action.is_empty() else "Merge into…" if window_action.command == "merge_window" else "Move tab to…"), Vector3(-0.32, 0.48, 0.006), 26)
	host._button(BASE + 7, I18n.t("Back"), Vector2(0.64, 0.48), Vector2(0.30, 0.07))
	if not window_action.is_empty():
		draw_window_targets(host); return
	var entries: Array = data.get("tab_list", []).filter(func(item): return int(item.window) == host.window_id)
	for i in entries.size():
		var item: Dictionary = entries[i]; var y := 0.31 - i * 0.15
		var title := str(item.get("title", "")) if not str(item.get("title", "")).is_empty() else str(item.url)
		host._button(BASE + 200 + i, "", Vector2(-0.05, y), Vector2(0.96, 0.12), true, "", int(item.id) == int(window_state(host.window_id).get("tab_id", 0)))
		var button: Dictionary = host._buttons.back()
		host._icon("pause" if item.get("sleeping", false) else "globe", Vector3(-0.41, 0, 0.004), 0.045, button.foreground, button.node)
		var label: Label3D = host._label(host._fit_title(title, "", 0.76, 26), Vector3(-0.35, 0, 0.004), 26, button.node)
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT; label.modulate = button.foreground
		host._button(BASE + 210 + i, "", Vector2(0.53, y), Vector2(0.10, 0.08), live_window_ids().size() > 1 or entries.size() > 1, "expand")
		host._tips[BASE + 210 + i] = I18n.t("Move tab to…")
		host._button(BASE + 220 + i, "", Vector2(0.73, y), Vector2(0.10, 0.08), true, "close")
		host._tips[BASE + 220 + i] = I18n.t("Close tab")
	var room: bool = data.get("tab_list", []).size() < 4
	host._button(BASE + 14, I18n.t("New tab"), Vector2(-0.34, -0.32), Vector2(0.44, 0.08), room)
	host._button(BASE + 17, I18n.t("New window"), Vector2(0.13, -0.32), Vector2(0.44, 0.08), room and live_window_ids().size() < max_windows())
	if live_window_ids().size() > 1:
		host._button(BASE + 16, I18n.t("Merge into…"), Vector2(0.60, -0.32), Vector2(0.44, 0.08))
	var current := window_state(host.window_id)
	if current.get("network_capture_available", false):
		var enabled: bool = current.get("network_capture_enabled", false)
		host._button(BASE + 15, I18n.t("Media detection on this site") + " · " + I18n.t("On" if enabled else "Off"), Vector2(0.13, -0.475), Vector2(0.86, 0.07), true, "", enabled)
		host._tips[BASE + 15] = I18n.t("Replay the video after enabling")

func draw_window_targets(host: Node) -> void:
	var targets := live_window_ids().filter(func(id): return id != focused_window)
	var entries: Array = data.get("tab_list", []).filter(func(item): return int(item.window) == focused_window)
	if window_action.command == "move_tab" and entries.size() > 1 and targets.size() + 1 < max_windows(): targets.push_front(0)
	for i in targets.size():
		var id: int = targets[i]
		var current := window_state(id) if id > 0 else {}
		var title := str(current.get("title", ""))
		if title.is_empty(): title = str(current.get("url", ""))
		if title.is_empty() or title == "about:blank": title = I18n.t("New window" if id == 0 else "New tab")
		var count: int = data.get("tab_list", []).filter(func(item): return int(item.window) == id).size()
		host._button(WINDOW_TARGET + id, "", Vector2(0.13, 0.29 - i * 0.19), Vector2(1.18, 0.15), true)
		var node: Node3D = host._buttons.back().node
		host._icon("plus" if id == 0 else "cinema_screen" if windows.has(id) and windows[id].on_screen() else "floating_window", Vector3(-0.50, 0, 0.004), 0.045, host.ACCENT, node)
		var label: Label3D = host._label(host._fit_title(title, "", 0.86, 24), Vector3(-0.43, 0, 0.004), 24, node)
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		if count > 1: host._label(str(count), Vector3(0.51, 0, 0.004), 20, node)
		host._tips[WINDOW_TARGET + id] = str(current.get("url", title))

func action(target: int) -> bool:
	if not Distribution.web_browser_enabled(): return false
	if library.action(target): return true
	if start_page.action(target): return true
	if active() and target >= WINDOW_TARGET and target <= WINDOW_TARGET + 4:
		if window_action.is_empty(): return true
		var destination := target - WINDOW_TARGET
		if destination == focused_window or (destination > 0 and destination not in live_window_ids()): return true
		tab_command(str(window_action.command), int(window_action.get("tab", 0)), destination)
		refresh_windows(); return true
	if active() and target == KEY_CONTROL + 7:
		menu.platform.web_browser_input("close", ""); refresh_windows(); return true
	if active() and target >= BASE + 200 and target < BASE + 224:
		var entries: Array = data.get("tab_list", []).filter(func(item): return int(item.window) == focused_window)
		var index := (target - BASE - 200) % 10
		if index < entries.size():
			if target >= BASE + 210 and target < BASE + 220:
				window_action = {"command": "move_tab", "tab": int(entries[index].id)}; tabs_open = true; refresh_windows()
			else: tab_command("select" if target < BASE + 210 else "close", int(entries[index].id))
		return true
	if not active() or target < BASE or target > WEB: return false
	match target - BASE:
		19:
			if windows.has(focused_window) and not start_page.active(focused_window):
				cancel(); windows[focused_window].toggle_focus()
		0: menu.platform.web_browser_action("back"); refresh_windows()
		1: menu.platform.web_browser_action("forward"); refresh_windows()
		2: menu.platform.web_browser_action("reload"); refresh_windows()
		3:
			refresh_windows()
			menu.platform.web_browser_action("blur")
			menu.system_text_input.begin("web_browser", draft, 4096, _edited, _navigate)
		4: menu.platform.web_browser_action("bookmark"); saved_poll = 0; refresh_windows()
		5: tab_command("close_window")
		7:
			menu.system_text_input.cancel("web_browser")
			menu.platform.web_browser_action("blur")
			if not window_action.is_empty(): window_action.clear()
			else: tabs_open = not tabs_open
			refresh_windows()
		8:
			if windows.has(focused_window):
				var host: Node = windows[focused_window]
				if host.cinema().is_empty(): return true
				host.set_mode("floating" if host.on_screen() else "cinema")
				if host.mode == "cinema":
					for other in windows.values():
						if other != host: other.set_mode("floating"); other.save_layout()
				host.save_layout(); refresh_windows()
		14: tab_command("new")
		16:
			if live_window_ids().size() > 1:
				window_action = {"command": "merge_window"}; tabs_open = true; refresh_windows()
		17:
			if live_window_ids().size() < max_windows() and data.get("tab_list", []).size() < 4: tab_command("new_window")
		15:
			if not data.get("network_capture_available", false) or not Methods.supports(menu.platform, "web_browser_command"): return true
			_cancel_handoff()
			if menu.web_video.pending > 0: menu.web_video.close()
			menu.web_video.result = {}
			prefetch_uri = ""; prefetch_result = {}; prefetch_id = 0; playing_since = 0
			menu.platform.web_browser_command(JSON.stringify({"action": "network_capture", "window": focused_window, "enabled": not data.get("network_capture_enabled", false)}))
			next_poll = 0
		6:
			if handoff and handoff_beta: return true
			if handoff:
				_handoff_failed(); menu.refresh()
			else:
				if not data.get("native_supported", false): return true
				_begin_handoff()
				menu.refresh()
		18:
			if not beta_available(window_state(focused_window)): return true
			if handoff:
				if not handoff_beta: return true
				_handoff_failed(); menu.refresh()
			else:
				_begin_handoff(false, true); menu.refresh()
	return true

func _playhead() -> int:
	var best := {}; var score := -1.0
	for item in data.get("videos", []):
		var area := float(item.get("width", 0)) * float(item.get("height", 0))
		var candidate := area + (1.0e12 if item.get("playing", false) else 0.0) + (1.0e15 if item.get("fullscreen", false) else 0.0) + (1.0e18 if handoff_beta and item.get("bilibili_ready", false) else 0.0)
		if candidate > score: score = candidate; best = item
	var seconds := float(best.get("time", 0.0))
	return int(clampf(seconds, 0.0, 604800.0) * 1000.0) if is_finite(seconds) else 0

func _edited(text: String) -> void: draft = text; menu.refresh()
func _navigate(text: String) -> void:
	if handoff: _cancel_handoff()
	draft = text.strip_edges()
	if not draft.is_empty():
		start_page.leave(focused_window)
		menu.platform.web_browser_navigate(draft)
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
func input_host() -> Node:
	for item in windows.values():
		if item.visible: return item
	return windows.values()[0] if not windows.is_empty() else menu
func _pointer(command: String, location: Vector2, scroll: float = 0.0) -> void:
	if windows.has(pointer_window): location = windows[pointer_window].source_point(location)
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
	hand = owner; point = location
	windows[pointer_window].show_press(point)
	_pointer("down", point); return true
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
			if windows[id].selecting: return
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
	if windows.has(focused_window) and windows[focused_window].selecting: return true
	if hand.is_empty() and is_finite(amount) and absf(amount) > 0.2:
		pointer_window = focused_window; _pointer("scroll", point, amount * delta * 8.0)
	return true
