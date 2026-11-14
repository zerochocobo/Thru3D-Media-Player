extends RefCounted
signal effects_changed
var _effects_active := false

func person_passthrough_active() -> bool:
	return active() and windows.values().any(func(window): return window.visible and window.depth.matte and not window.selecting and not start_page.active(window.window_id))

func sync_effects() -> void:
	var current := person_passthrough_active()
	if current != _effects_active:
		_effects_active = current
		effects_changed.emit()
const UiTheme := preload("res://scripts/ui_theme.gd")
const Sites := preload("res://scripts/web_video_sites.gd")
const ChineseInput := preload("res://scripts/chinese_input.gd")
var _chinese_mode := -1
var _keyboard_seen := 0
var _keyboard_target := {}

func keyboard_visible(id: int) -> bool:
	if id != focused_window: return false
	if ChineseInput.browser_enabled():
		return ChineseInput.active() and ChineseInput.popup.owner_id == "browser" and int(_keyboard_target.get("window", 0)) == id
	return bool(window_state(id).get("keyboard_visible", false))

func toggle_keyboard(id: int) -> void:
	focus_window(id)
	if not Methods.supports(menu.platform, "web_browser_input"): return
	_sync_chinese_mode()
	var shown := keyboard_visible(id)
	if shown:
		ChineseInput.close("browser", true); _keyboard_target.clear()
	var current := window_state(id)
	menu.platform.web_browser_input("close" if shown else "show", JSON.stringify({"window":id,
		"tab":int(current.get("tab_id",0)),"navigation":int(current.get("navigation",0))}))

func _sync_chinese_mode() -> void:
	var mode := int(ChineseInput.browser_enabled())
	if mode == _chinese_mode or not is_instance_valid(menu.platform) or not Methods.supports(menu.platform, "web_browser_command"): return
	_chinese_mode = mode
	menu.platform.web_browser_command(JSON.stringify({"action": "keyboard_mode", "enabled": bool(mode)}))
	if not mode: ChineseInput.close("browser"); _keyboard_seen = 0; _keyboard_target.clear()

func _sync_chinese_keyboard() -> void:
	var epoch := int(data.get("keyboard_epoch", 0))
	if menu.system_text_input.active():
		ChineseInput.close("browser"); _keyboard_seen = epoch; _keyboard_target.clear(); return
	if not ChineseInput.browser_enabled() or not data.get("custom_keyboard", false) or epoch <= 0:
		ChineseInput.close("browser"); _keyboard_seen = 0; _keyboard_target.clear(); return
	if epoch == _keyboard_seen: return
	_keyboard_seen = epoch
	_keyboard_target = {"window": focused_window, "tab": int(data.get("tab_id", 0)), "navigation": int(data.get("navigation", 0)), "epoch": epoch}
	var target := _keyboard_target.duplicate()
	ChineseInput.open(menu, "browser", func(operation, value):
		if not active() or menu.system_text_input.active() or target != _keyboard_target: return false
		var request := target.merged({"command": operation, "text": value}, true)
		menu.platform.web_browser_input("custom", JSON.stringify(request))
		return true,
		func(): return active() and not menu.system_text_input.active() and ChineseInput.browser_enabled() and target == _keyboard_target,
		Callable(), bool(data.get("keyboard_latin", false)) or I18n.language != "zh")

const Distribution := preload("res://scripts/distribution_channel.gd")
const I18n := preload("res://scripts/i18n.gd")
const Methods := preload("res://scripts/platform_methods.gd")
const BASE := 986000
const PASTE := BASE + 27
const HISTORY := BASE + 28
const WEB := BASE + 20
const KEY := BASE + 100
const KEY_CONTROL := BASE + 40
const WINDOW_TARGET := BASE + 300
const RECT := Rect2(-0.59, -0.48, 1.44, 0.90)
# Resting-hand jitter and per-frame rays make desktop pages run mousemove/hover
# handlers (and hover video previews) every frame.
const HOVER_DEADZONE_CSS := 2.0
const HOVER_INTERVAL_MS := 33
const SCROLL_HOVER_HOLD_MS := 250
# Ray travel on the page before a press becomes a drag, matching the library
# list. Farther pages (the cinema screen) widen it with distance so the same
# hand jitter still taps.
const TAP_SLOP_METRES := 0.015
var menu: Node
var opened := false
var scene_suspended := false
var data := {}
var draft := ""
var hand := ""
var point := Vector2(0.5, 0.5)
var _pointer_button := ""
var _page_dragging := false
var _hover_sent_ms := -HOVER_INTERVAL_MS
var _scroll_hover_until := 0
var windows := {}
var low_end := false
# Page raster per CSS pixel, in thirds: 1440x900, 1920x1200 or 2400x1500 at the default size.
const CLARITY_UNITS := {"low": 3, "medium": 4, "high": 5}
var clarity := "high"
var pixel_units := 5
var window_created: Callable
var paired_layout := false
var focused_window := 1
var footer_window_id := 0 # Stable owner; pointer focus never moves the global controls.
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
var handoff_beta := false
var beta_button_seen := {}
var handoff_waiting_pause := false
var handoff_started_ms := 0
var handoff_context := {}
var handoff_error := {}
var playback_return := {}
var _signature := ""
var list_mode := ""
var saved := {}
var saved_poll := 0
var _saved_raw := ""
var _status_raw := ""
var library := preload("res://scripts/web_browser_library_panel.gd").new(self)
var start_page := preload("res://scripts/web_browser_start_page.gd").new(self)
var history := preload("res://scripts/web_browser_history_panel.gd").new(self)
var focus_regions := {} # Session-local, follows a tab when moved to another window.
var video_regions := {} # The focus region a tab got from "focus video", while it is still the one shown.
var video_locate_request := 0

func _init(owner: Node) -> void:
	menu = owner
	menu.tree_exited.connect(_owner_left_tree)

func _owner_left_tree() -> void:
	# Reparenting the resource library under the playback controls briefly exits
	# the tree too. Independent browser windows outlive that layout operation.
	_release_orphan_windows.call_deferred()

func _release_orphan_windows() -> void:
	if is_instance_valid(menu) and menu.is_inside_tree(): return
	for item in windows.values():
		if is_instance_valid(item): item.queue_free()
	windows.clear()
static func default_clarity(low: bool) -> String: return "low" if low else "high"

## low_end is the GPU tier (window count, 3D budget); clarity picks the page raster.
func configure_quality(value: bool, choice: String = "") -> void:
	low_end = value
	clarity = choice if CLARITY_UNITS.has(choice) else default_clarity(value)
	pixel_units = CLARITY_UNITS[clarity]
	if OS.get_name() != "Android": return
	preload("res://scripts/web_browser_layer.gd").initialize()
	# Gecko's process-wide density must be selected before navigation or extraction
	# starts it. Reuse the selected tier after an Activity/runtime recreation.
	var bridge := JavaClassWrapper.wrap("org.vrpassthroughplayer.plugin.WebBrowserSurfaceBridge")
	if bridge and not JavaClassWrapper.get_exception():
		var applied: int = bridge.configureViewport(value, pixel_units)
		if not JavaClassWrapper.get_exception() and applied in CLARITY_UNITS.values(): pixel_units = applied
## A changed choice waits for the next app start; Gecko keeps its first density.
func clarity_pending() -> bool: return CLARITY_UNITS[clarity] != pixel_units
func supported() -> bool: return Distribution.web_browser_enabled() and Methods.supports(menu.platform, "web_browser_navigate")
func active() -> bool: return opened and not scene_suspended and menu.visible and menu.section == menu.Section.WEB
func cinema_video_active() -> bool:
	return cinema_video_provider.is_valid() and bool(cinema_video_provider.call())

func open(url: String = "", retained: Dictionary = {}) -> void:
	if not supported(): return
	_sync_chinese_mode()
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
	elif not retained.is_empty(): _video_command("resume_retained_page", retained)
	else: menu.platform.web_browser_action("resume")
	next_poll = 0; menu.refresh()

func close(force_release: bool = false) -> void:
	# Scene selection (including its image picker) temporarily owns the library.
	# Ordinary menu polling/dismissal must not close or hibernate the original page.
	if scene_suspended and not force_release: return
	scene_suspended = false
	var retaining: bool = playback_return.get("retained", false) and playback_return.get("opening", false)
	ChineseInput.close("browser"); _keyboard_seen = 0; _keyboard_target.clear()
	cancel()
	if handoff: _cancel_handoff()
	library.reset()
	history.reset()
	menu.system_text_input.cancel("web_browser")
	if (opened or force_release) and supported() and not retaining: menu.platform.web_browser_action("hibernate")
	opened = false; handoff = false; handoff_waiting_pause = false; pause_started = 0
	opening = false; window_action.clear()
	handoff_context.clear()
	# Hidden windows hold a stale world pose relative to the current head.
	for item in windows.values():
		if item.visible: item.save_layout()
		item.dismiss()
	tabs_open = false

func set_scene_suspended(value: bool) -> void:
	if scene_suspended == value: return
	scene_suspended = value and opened
	if scene_suspended:
		if handoff: _cancel_handoff()
		cancel(); menu.system_text_input.cancel("web_browser"); ChineseInput.close("browser")
		for item in windows.values():
			item.effect_controls.finish_drag(); item.effect_controls._hide_controls(); item.dismiss()
	elif active():
		next_poll = 0; tick(); menu.refresh()

func tick() -> void:
	sync_effects()
	_sync_chinese_mode()
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
		if opened and not scene_suspended: close()
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
		history.reset()
		tabs_open = false; window_action.clear(); _signature = ""
	focused_window = next_focus
	_sync_chinese_keyboard()
	if window_action.get("command") == "move_tab" and not data.get("tab_list", []).any(func(item): return int(item.id) == int(window_action.get("tab", 0)) and int(item.window) == focused_window):
		window_action.clear()
	var ids := live_window_ids()
	var tabs: Array = data.get("tab_list", [])
	if not tabs.is_empty():
		for id in focus_regions.keys():
			if not tabs.any(func(item): return int(item.id) == id): focus_regions.erase(id); video_regions.erase(id)
	if opening and data.get("active", false) and not ids.is_empty(): opening = false
	if not opening and ids.is_empty():
		close(); list_mode = ""; menu.refresh(); return
	paired_layout = ids.size() > 1
	_sync_footer_window(ids)
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
	for id in ids:
		windows[id].sync_fullscreen(window_state(id))
	sync_effects()
	if handoff and (str(data.get("url", "")) != handoff_uri or int(data.get("tab_id", 0)) != handoff_tab or int(data.get("navigation", 0)) != handoff_navigation):
		_cancel_handoff()
	if handoff and not str(handoff_context.get("selection", "")).is_empty() and (direct_target(data, str(handoff_context.selection)).is_empty() if handoff_context.get("direct", false) else selected_beta_target(data, str(handoff_context.selection)).is_empty()):
		menu.web_video.result = {"error_code": "browser_page_changed"}; _handoff_failed()
	if not menu.system_text_input.active("web_browser"):
		draft = "" if data.get("url", "") == "about:blank" else str(data.get("url", ""))
	_poll_beta_button()
	if handoff and Time.get_ticks_msec() - handoff_started_ms > (30000 if handoff_beta else 90000):
		menu.web_video.result = {"error_code": "timeout"}
		_handoff_failed()
	if handoff and handoff_waiting_pause:
		if _pause_confirmed():
			handoff_waiting_pause = false
			handoff_start_ms = _playhead(true)
			handoff_context.position_ms = _playhead()
			if handoff_context.get("direct", false): menu.web_video.open_captured(str(handoff_context.selection))
			else: menu.web_video.resolve(true, str(handoff_context.get("selection", "")))
			if menu.web_video.pending == 0: _handoff_failed()
		elif Time.get_ticks_msec() - pause_started > 5000:
			menu.web_video.result = {"error_code": "browser_pause_timeout"}
			_handoff_failed()
	if handoff and not handoff_waiting_pause and menu.web_video.pending == 0:
		if menu.web_video.result.get("state", "") == "ready":
			if pause_started == 0:
				handoff_start_ms = _playhead(true)
				pause_started = Time.get_ticks_msec()
				handoff_context.pause_token = _next_pause_token()
				_video_command("pause_tab", handoff_context)
			elif _pause_confirmed():
				_discard_playback_return()
				playback_return = handoff_context.duplicate(true)
				playback_return.native_uri = str(menu.web_video.result.get("uri", ""))
				playback_return.retained = true
				var keep_browser := live_window_ids().size() > 1
				# Every browser handoff keeps its acknowledged pause and live document,
				# including explicit legacy media-server buttons.
				# Arm before choose(): menu dismissal and the main player both close.
				playback_return.opening = true
				_video_command("retain_page", playback_return.merged({"hide": not keep_browser}, true))
				handoff = false; pause_started = 0
				menu.web_video.choose({"web_video": "play", "start_ms": handoff_start_ms, "keep_browser": keep_browser}); return
			elif Time.get_ticks_msec() - pause_started > 5000:
				menu.web_video.result = {"error_code": "browser_pause_timeout"}
				_handoff_failed()
		else: _handoff_failed()
	# Only fields the chrome draws. Window states also carry each video's advancing time;
	# comparing those rebuilt every browser window four times a second during playback.
	var chrome: Array = data.get("windows", []).map(func(item): return [item.get("id"), item.get("tab_id"), item.get("url"),
		item.get("title"), item.get("back"), item.get("forward"), item.get("error"), item.get("editing"), item.get("loading"), item.get("start_page"), item.get("network_capture_available"), item.get("network_capture_enabled"), beta_site_available(item), beta_media_ready(item)])
	var signature := str([draft, data.get("back"), data.get("forward"), data.get("error"), handoff_error,
		chrome, not (cinema_provider.call() if cinema_provider.is_valid() else {}).is_empty(), data.get("tab_list", []), data.get("operation_error", ""), data.get("loading"), data.get("start_page"), data.get("videos", []).size(), data.get("direct_selection", ""), data.get("native_supported", false), handoff, handoff_beta, data.get("editing", false), data.get("network_capture_available"), data.get("network_capture_enabled"), beta_site_available(data), beta_media_ready(data), menu.web_video.result.get("state", "")])
	if signature != _signature and hand.is_empty():
		# Do not consume changes while the page owns the pointer: release must redraw
		# even if media readiness and the rest of the native snapshot stay unchanged.
		_signature = signature
		menu.refresh()

func _poll_beta_button() -> void:
	var serial := int(data.get("beta_request", data.get("weibo_request", 0)))
	var tab := int(data.get("tab_id", 0))
	if serial <= int(beta_button_seen.get(tab, 0)) or not data.get("active", false): return
	beta_button_seen[tab] = serial
	var selection := str(data.get("beta_selection", data.get("weibo_selection", "")))
	if not selection.is_empty() and not selected_beta_target(data, selection).is_empty(): _begin_handoff(true, selection)

func selected_beta_target(current: Dictionary, selection: String) -> Dictionary:
	var candidates: Array = current.get("videos", []).filter(func(item): return (item.get("weibo_ready", false) or item.get("bilibili_ready", false) or item.get("douyin_ready", false) or item.get("tencent_ready", false) or item.get("mango_ready", false) or item.get("youku_ready", false) or item.get("iqiyi_ready", false) or item.get("niconico_ready", false) or item.get("twitch_ready", false) or item.get("tiktok_ready", false) or item.get("instagram_ready", false) or item.get("odysee_ready", false) or item.get("archive_ready", false) or item.get("naver_ready", false) or item.get("reddit_ready", false) or item.get("streamable_ready", false) or item.get("redbull_ready", false) or item.get("ted_ready", false) or item.get("dailymotion_ready", false)) and not item.get("protected", false) and str(item.get("selection", "")) == selection)
	return candidates[0] if not selection.is_empty() and candidates.size() == 1 else {}

func weibo_target(current: Dictionary, selection: String = "") -> Dictionary:
	var candidates: Array = current.get("videos", []).filter(func(item): return item.get("weibo_ready", false) and not item.get("protected", false) and not str(item.get("selection", "")).is_empty())
	if not selection.is_empty():
		candidates = candidates.filter(func(item): return str(item.get("selection", "")) == selection)
	else:
		var selected: Array = candidates.filter(func(item): return item.get("weibo_selected", false))
		if not selected.is_empty(): candidates = selected
	return candidates[0] if candidates.size() == 1 else {}

func tencent_target(current: Dictionary, selection: String = "") -> Dictionary:
	var candidates: Array = current.get("videos", []).filter(func(item): return item.get("tencent_ready", false) and not item.get("protected", false) and not str(item.get("selection", "")).is_empty() and (selection.is_empty() or str(item.selection) == selection))
	return candidates[0] if candidates.size() == 1 else {}

func mango_target(current: Dictionary, selection: String = "") -> Dictionary:
	var candidates: Array = current.get("videos", []).filter(func(item): return item.get("mango_ready", false) and not item.get("protected", false) and not str(item.get("selection", "")).is_empty() and (selection.is_empty() or str(item.selection) == selection))
	return candidates[0] if candidates.size() == 1 else {}

func youku_target(current: Dictionary, selection: String = "") -> Dictionary:
	var candidates: Array = current.get("videos", []).filter(func(item): return item.get("youku_ready", false) and not item.get("protected", false) and not str(item.get("selection", "")).is_empty() and (selection.is_empty() or str(item.selection) == selection))
	return candidates[0] if candidates.size() == 1 else {}

func niconico_target(current: Dictionary, selection: String = "") -> Dictionary:
	var candidates: Array = current.get("videos", []).filter(func(item): return item.get("niconico_ready", false) and not item.get("protected", false) and not str(item.get("selection", "")).is_empty() and (selection.is_empty() or str(item.selection) == selection))
	return candidates[0] if candidates.size() == 1 else {}

func twitch_target(current: Dictionary, selection: String = "") -> Dictionary:
	var candidates: Array = current.get("videos", []).filter(func(item): return item.get("twitch_ready", false) and not item.get("protected", false) and not str(item.get("selection", "")).is_empty() and (selection.is_empty() or str(item.selection) == selection))
	return candidates[0] if candidates.size() == 1 else {}

func tiktok_target(current: Dictionary, selection: String = "") -> Dictionary:
	var candidates: Array = current.get("videos", []).filter(func(item): return item.get("tiktok_ready", false) and not item.get("protected", false) and not str(item.get("selection", "")).is_empty() and (selection.is_empty() or str(item.selection) == selection))
	return candidates[0] if candidates.size() == 1 else {}

func instagram_target(current: Dictionary, selection: String = "") -> Dictionary:
	var candidates: Array = current.get("videos", []).filter(func(item): return item.get("instagram_ready", false) and not item.get("protected", false) and not str(item.get("selection", "")).is_empty() and (selection.is_empty() or str(item.selection) == selection))
	return candidates[0] if candidates.size() == 1 else {}

func ted_target(current: Dictionary, selection: String = "") -> Dictionary:
	var candidates: Array = current.get("videos", []).filter(func(item): return item.get("ted_ready", false) and not item.get("protected", false) and not str(item.get("selection", "")).is_empty() and (selection.is_empty() or str(item.selection) == selection))
	return candidates[0] if candidates.size() == 1 else {}

func redbull_target(current: Dictionary, selection: String = "") -> Dictionary:
	var candidates: Array = current.get("videos", []).filter(func(item): return item.get("redbull_ready", false) and not item.get("protected", false) and not str(item.get("selection", "")).is_empty() and (selection.is_empty() or str(item.selection) == selection))
	return candidates[0] if candidates.size() == 1 else {}

func streamable_target(current: Dictionary, selection: String = "") -> Dictionary:
	var candidates: Array = current.get("videos", []).filter(func(item): return item.get("streamable_ready", false) and not item.get("protected", false) and not str(item.get("selection", "")).is_empty() and (selection.is_empty() or str(item.selection) == selection))
	return candidates[0] if candidates.size() == 1 else {}

func reddit_target(current: Dictionary, selection: String = "") -> Dictionary:
	var candidates: Array = current.get("videos", []).filter(func(item): return item.get("reddit_ready", false) and not item.get("protected", false) and not str(item.get("selection", "")).is_empty() and (selection.is_empty() or str(item.selection) == selection))
	return candidates[0] if candidates.size() == 1 else {}

func naver_target(current: Dictionary, selection: String = "") -> Dictionary:
	var candidates: Array = current.get("videos", []).filter(func(item): return item.get("naver_ready", false) and not item.get("protected", false) and not str(item.get("selection", "")).is_empty() and (selection.is_empty() or str(item.selection) == selection))
	return candidates[0] if candidates.size() == 1 else {}

func archive_target(current: Dictionary, selection: String = "") -> Dictionary:
	var candidates: Array = current.get("videos", []).filter(func(item): return item.get("archive_ready", false) and not item.get("protected", false) and not str(item.get("selection", "")).is_empty() and (selection.is_empty() or str(item.selection) == selection))
	return candidates[0] if candidates.size() == 1 else {}

func odysee_target(current: Dictionary, selection: String = "") -> Dictionary:
	var candidates: Array = current.get("videos", []).filter(func(item): return item.get("odysee_ready", false) and not item.get("protected", false) and not str(item.get("selection", "")).is_empty() and (selection.is_empty() or str(item.selection) == selection))
	return candidates[0] if candidates.size() == 1 else {}

func dailymotion_target(current: Dictionary, selection: String = "") -> Dictionary:
	var candidates: Array = current.get("videos", []).filter(func(item): return item.get("dailymotion_ready", false) and not item.get("protected", false) and not str(item.get("selection", "")).is_empty() and (selection.is_empty() or str(item.selection) == selection))
	return candidates[0] if candidates.size() == 1 else {}

func iqiyi_target(current: Dictionary, selection: String = "") -> Dictionary:
	var candidates: Array = current.get("videos", []).filter(func(item): return item.get("iqiyi_ready", false) and not item.get("protected", false) and not str(item.get("selection", "")).is_empty() and (selection.is_empty() or str(item.selection) == selection))
	return candidates[0] if candidates.size() == 1 else {}

func douyin_target(current: Dictionary, selection: String = "") -> Dictionary:
	var candidates: Array = current.get("videos", []).filter(func(item): return item.get("douyin_ready", false) and not item.get("protected", false) and not str(item.get("selection", "")).is_empty() and (selection.is_empty() or str(item.selection) == selection))
	return candidates[0] if candidates.size() == 1 else {}

func bilibili_target(current: Dictionary, selection: String = "") -> Dictionary:
	var candidates: Array = current.get("videos", []).filter(func(item): return item.get("bilibili_ready", false) and not item.get("protected", false) and not str(item.get("selection", "")).is_empty() and (selection.is_empty() or str(item.selection) == selection))
	return candidates[0] if candidates.size() == 1 else {}

func direct_target(current: Dictionary, selection: String) -> Dictionary:
	var candidates: Array = current.get("videos", []).filter(func(item): return item.get("direct_ready", false) and not item.get("protected", false) and str(item.get("selection", "")) == selection)
	return candidates[0] if not selection.is_empty() and candidates.size() == 1 else {}

func _begin_handoff(beta: bool = false, selection: String = "") -> void:
	var direct := false
	if not beta and not str(data.get("direct_selection", "")).is_empty() and Methods.supports(menu.platform, "web_video_open_captured"):
		var fresh: Variant = JSON.parse_string(menu.platform.web_browser_status())
		if not fresh is Dictionary or int(fresh.get("focused_window", 1)) != focused_window: return
		for key in ["url", "tab_id", "navigation", "direct_selection"]:
			if fresh.get(key) != data.get(key): return
		selection = str(fresh.get("direct_selection", ""))
		if direct_target(fresh, selection).is_empty(): return
		direct = true
	if beta:
		# The button snapshot can be one poll behind a sidebar navigation or media change.
		# Revalidate before pausing or disturbing an existing resolver.
		var fresh: Variant = JSON.parse_string(menu.platform.web_browser_status())
		if not fresh is Dictionary or not beta_site_available(fresh) or not beta_media_ready(fresh, selection): return
		if int(fresh.get("focused_window", 1)) != focused_window: return
		for key in ["url", "tab_id", "navigation"]:
			if fresh.get(key) != data.get(key): return
		if not selection.is_empty() and selected_beta_target(fresh, selection).is_empty(): return
		if fresh.get("bilibili_beta_available", false):
			var target := bilibili_target(fresh, selection)
			if target.is_empty(): return
			selection = str(target.selection)
		if fresh.get("weibo_beta_available", false):
			var target := weibo_target(fresh, selection)
			if target.is_empty(): return
			selection = str(target.selection)
		if fresh.get("tencent_beta_available", false):
			var target := tencent_target(fresh, selection)
			if target.is_empty(): return
			selection = str(target.selection)
		if fresh.get("mango_beta_available", false):
			var target := mango_target(fresh, selection)
			if target.is_empty(): return
			selection = str(target.selection)
		if fresh.get("youku_beta_available", false):
			var target := youku_target(fresh, selection)
			if target.is_empty(): return
			selection = str(target.selection)
		if fresh.get("niconico_beta_available", false):
			var target := niconico_target(fresh, selection)
			if target.is_empty(): return
			selection = str(target.selection)
		if fresh.get("twitch_beta_available", false):
			var target := twitch_target(fresh, selection)
			if target.is_empty(): return
			selection = str(target.selection)
		if fresh.get("tiktok_beta_available", false):
			var target := tiktok_target(fresh, selection)
			if target.is_empty(): return
			selection = str(target.selection)
		if fresh.get("instagram_beta_available", false):
			var target := instagram_target(fresh, selection)
			if target.is_empty(): return
			selection = str(target.selection)
		if fresh.get("ted_beta_available", false):
			var target := ted_target(fresh, selection)
			if target.is_empty(): return
			selection = str(target.selection)
		if fresh.get("redbull_beta_available", false):
			var target := redbull_target(fresh, selection)
			if target.is_empty(): return
			selection = str(target.selection)
		if fresh.get("streamable_beta_available", false):
			var target := streamable_target(fresh, selection)
			if target.is_empty(): return
			selection = str(target.selection)
		if fresh.get("reddit_beta_available", false):
			var target := reddit_target(fresh, selection)
			if target.is_empty(): return
			selection = str(target.selection)
		if fresh.get("naver_beta_available", false):
			var target := naver_target(fresh, selection)
			if target.is_empty(): return
			selection = str(target.selection)
		if fresh.get("archive_beta_available", false):
			var target := archive_target(fresh, selection)
			if target.is_empty(): return
			selection = str(target.selection)
		if fresh.get("odysee_beta_available", false):
			var target := odysee_target(fresh, selection)
			if target.is_empty(): return
			selection = str(target.selection)
		if fresh.get("dailymotion_beta_available", false):
			var target := dailymotion_target(fresh, selection)
			if target.is_empty(): return
			selection = str(target.selection)
		if fresh.get("iqiyi_beta_available", false):
			var target := iqiyi_target(fresh, selection)
			if target.is_empty(): return
			selection = str(target.selection)
		if fresh.get("douyin_beta_available", false):
			var target := douyin_target(fresh, selection)
			if target.is_empty(): return
			selection = str(target.selection)
		data = fresh; _status_raw = ""
	if handoff: _cancel_handoff()
	handoff_error.clear()
	handoff_beta = beta
	handoff_waiting_pause = false
	handoff_started_ms = Time.get_ticks_msec(); pause_started = 0
	handoff_uri = str(data.get("url", ""))
	handoff_tab = int(data.get("tab_id", 0)); handoff_navigation = int(data.get("navigation", 0))
	handoff_context = {"direct": direct, "bilibili": beta and data.get("bilibili_beta_available", false), "tab": handoff_tab, "window": focused_window, "navigation": handoff_navigation,
		"douyin": data.get("douyin_beta_available", false), "iqiyi": data.get("iqiyi_beta_available", false), "youku": data.get("youku_beta_available", false), "niconico": data.get("niconico_beta_available", false), "twitch": data.get("twitch_beta_available", false), "tiktok": data.get("tiktok_beta_available", false), "instagram": data.get("instagram_beta_available", false), "ted": data.get("ted_beta_available", false), "redbull": data.get("redbull_beta_available", false), "naver": data.get("naver_beta_available", false), "reddit": data.get("reddit_beta_available", false), "streamable": data.get("streamable_beta_available", false), "archive": data.get("archive_beta_available", false), "odysee": data.get("odysee_beta_available", false), "dailymotion": data.get("dailymotion_beta_available", false), "mango": data.get("mango_beta_available", false), "origin": handoff_uri, "request": int(data.get("fullscreen_request", 0)), "selection": selection,
		"was_playing": data.get("videos", []).any(func(item): return (selection.is_empty() or str(item.get("selection", "")) == selection) and item.get("playing", false))}
	handoff_context.position_ms = _playhead()
	menu.web_video.address = handoff_uri
	if beta or direct:
		# The selected button always uses its current, explicitly selected source.
		if menu.web_video.pending > 0: menu.web_video.close()
		menu.web_video.result = {}
		handoff = true
		_begin_beta_pause()
		return
	menu.web_video.resolve(); handoff = menu.web_video.pending > 0
	if not handoff: _handoff_failed()

func beta_media_ready(current: Dictionary, selection: String = "") -> bool:
	if not selection.is_empty(): return not selected_beta_target(current, selection).is_empty()
	return not douyin_target(current).is_empty() or not weibo_target(current).is_empty() or not tencent_target(current).is_empty() or not mango_target(current).is_empty() or not youku_target(current).is_empty() or not iqiyi_target(current).is_empty() or not niconico_target(current).is_empty() or not twitch_target(current).is_empty() or not tiktok_target(current).is_empty() or not instagram_target(current).is_empty() or not odysee_target(current).is_empty() or not archive_target(current).is_empty() or not naver_target(current).is_empty() or not reddit_target(current).is_empty() or not streamable_target(current).is_empty() or not redbull_target(current).is_empty() or not ted_target(current).is_empty() or not dailymotion_target(current).is_empty() or not bilibili_target(current).is_empty()

func beta_site_available(current: Dictionary) -> bool:
	return current.get("bilibili_beta_available", false) or current.get("douyin_beta_available", false) or current.get("weibo_beta_available", false) or current.get("tencent_beta_available", false) or current.get("mango_beta_available", false) or current.get("youku_beta_available", false) or current.get("iqiyi_beta_available", false) or current.get("niconico_beta_available", false) or current.get("twitch_beta_available", false) or current.get("tiktok_beta_available", false) or current.get("instagram_beta_available", false) or current.get("odysee_beta_available", false) or current.get("archive_beta_available", false) or current.get("naver_beta_available", false) or current.get("reddit_beta_available", false) or current.get("streamable_beta_available", false) or current.get("redbull_beta_available", false) or current.get("ted_beta_available", false) or current.get("dailymotion_beta_available", false)

func handoff_status() -> String:
	if handoff_waiting_pause: return I18n.t("Pausing web video…")
	if handoff_context.get("direct", false): return I18n.t("Loading…")
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
	handoff = false; handoff_waiting_pause = false; pause_started = 0; handoff_context = {}

func _handoff_failed() -> void:
	handoff_error = handoff_context.merged({"message": menu.web_video.error_hint()})
	_cancel_handoff()
	menu.web_video.result = {}

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
	if not browser_handoff or str(playback_return.get("native_uri", "")) != uri: _discard_playback_return()

func _discard_playback_return() -> void:
	if playback_return.get("retained", false): _video_command("release_retained_page", playback_return)
	playback_return.clear()

func restore_playback(failed: bool, position_ms: int = -1) -> void:
	if playback_return.is_empty(): return
	var context := playback_return.duplicate(true); playback_return.clear()
	if position_ms >= 0: context.position_ms = position_ms
	context.play = failed and bool(context.get("was_playing", false))
	context.exit_fullscreen = not failed
	menu.section = menu.Section.WEB; list_mode = ""; tabs_open = false
	# Retained returns never wake a replacement session after a crash/navigation.
	open("", context if context.get("retained", false) else {})
	if context.get("retained", false):
		_video_command("resume_tab", context.merged({"was_playing": false, "restore_paused": failed}, true))
	if context.get("fullscreen", false): _video_command("restore_video", context)
	else:
		# The button can hand off without a fullscreen video capture. Restore the
		# original tab/window without navigating again or addressing stale media.
		if not context.get("retained", false): _video_command("select", context)
		if context.get("direct", false): _video_command("restore_direct", context)
		elif not str(context.get("selection", "")).is_empty(): _video_command("restore_bilibili" if context.get("bilibili", false) else "restore_douyin" if context.get("douyin", false) else "restore_iqiyi" if context.get("iqiyi", false) else "restore_dailymotion" if context.get("dailymotion", false) else "restore_odysee" if context.get("odysee", false) else "restore_archive" if context.get("archive", false) else "restore_naver" if context.get("naver", false) else "restore_reddit" if context.get("reddit", false) else "restore_streamable" if context.get("streamable", false) else "restore_redbull" if context.get("redbull", false) else "restore_ted" if context.get("ted", false) else "restore_instagram" if context.get("instagram", false) else "restore_tiktok" if context.get("tiktok", false) else "restore_twitch" if context.get("twitch", false) else "restore_niconico" if context.get("niconico", false) else "restore_youku" if context.get("youku", false) else "restore_mango" if context.get("mango", false) else "restore_weibo", context)
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
	if footer_window_id == 0: footer_window_id = id
	if not windows.has(id):
		var item := preload("res://scripts/web_browser_window.gd").new()
		item.configure(self, id); menu.get_tree().root.add_child(item); windows[id] = item
		if window_created.is_valid(): window_created.call(item)
	if show and not windows[id].visible: windows[id].show_window()

func _sync_footer_window(ids: Array) -> void:
	if ids.has(footer_window_id): return
	var ordered := ids.duplicate(); ordered.sort()
	footer_window_id = focused_window if ids.has(focused_window) else int(ordered[0]) if not ordered.is_empty() else 0
	for item in windows.values():
		item.effect_controls.set_global_footer(item.window_id == footer_window_id)

func sync_follow(follow: RefCounted, head: Transform3D, allowed: bool) -> void:
	for item in windows.values(): item.sync_follow(follow, head, allowed and active())

func refresh_windows() -> void:
	for item in windows.values():
		if item.visible: item.refresh()
func relocate_view(previous: Transform3D, current: Transform3D) -> void:
	if previous.is_equal_approx(current): return
	cancel()
	var delta := current * previous.affine_inverse()
	for item in windows.values():
		if item.placed: item.relocate_view(delta)
func window_state(id: int) -> Dictionary:
	for item in data.get("windows", []):
		if int(item.id) == id: return item
	return data if id == int(data.get("focused_window", 1)) else {}
func focus_window(id: int) -> void:
	if focused_window == id: return
	history.reset()
	window_action.clear()
	cancel(); menu.system_text_input.cancel("web_browser")
	if handoff: _cancel_handoff()
	focused_window = id
	if Methods.supports(menu.platform, "web_browser_command"):
		menu.platform.web_browser_command(JSON.stringify({"action": "focus", "window": id}))
	data.merge(window_state(id), true); _status_raw = ""; draft = str(data.get("url", "")); refresh_windows()
func tab_command(command: String, id: int = 0, destination: int = 0) -> void:
	history.reset()
	cancel(); menu.system_text_input.cancel("web_browser")
	for item in windows.values(): item.end_drag(); item.clear_pointer_visuals()
	if handoff: _cancel_handoff()
	if Methods.supports(menu.platform, "web_browser_command"):
		menu.platform.web_browser_command(JSON.stringify({"action": command, "window": focused_window, "tab": id, "destination": destination}))
	tabs_open = false; window_action.clear(); next_poll = 0
func draw() -> void: refresh_windows()
func overlay_open(id: int) -> bool:
	return (tabs_open and focused_window == id) or history.active(id)
func draw_window(host: Node) -> void:
	var current := window_state(host.window_id)
	var address: String = draft if focused_window == host.window_id else str(current.get("url", ""))
	var on_screen: bool = host.on_screen()
	var bounds: Rect2 = host.page_rect()
	if host.chrome_hidden():
		host._backdrop.visible = false
		draw_page_content(host,bounds)
		# A frameless page keeps its resize targets; the grips appear on ray hover.
		if not on_screen and not host.page_input_blocked(): host.draw_resize_handles(true)
		return
	host._set_backdrop(host.HEADER.size if on_screen else bounds.size + Vector2(0.02, host.HEADER.size.y + 0.02), host.HEADER.get_center() if on_screen else Vector2(bounds.get_center().x, bounds.get_center().y + (host.HEADER.size.y - 0.02) / 2))
	if history.active(host.window_id):
		host._backdrop.visible = true; history.draw(host); return
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
	host._button(BASE + 3, host._fit_title(caption, "", 0.504, 22), Vector2(0.066, host.NAV_Y), Vector2(0.544, host.TOOL_SIZE.y))
	host._tips[BASE + 3] = (status + "\n" if not status.is_empty() else "") + (title + "\n" if not title.is_empty() else "") + address
	host._button(PASTE, "", Vector2(0.406, host.NAV_Y), host.TOOL_SIZE, true, "paste")
	host._tips[PASTE] = I18n.t("Paste")
	host._button(HISTORY, "", Vector2(0.534, host.NAV_Y), host.TOOL_SIZE, true, "history")
	host._tips[HISTORY] = I18n.t("Browsing history")
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
		# Centre the fixed-width controls over the toolbar, which follows a focused page.
		var offset: float = host.toolbar_bounds().get_center().x - RECT.get_center().x
		for button in host._buttons:
			button.node.position.x += offset; button.rect.position.x += offset
		for label in host._labels: label.position.x += offset
		for decoration in host._decorations:
			if not host._pointer_panels.has(decoration): decoration.position.x += offset
	draw_page_content(host,bounds)
	if not on_screen: host.draw_resize_handles()

func draw_page_content(host: Node, bounds: Rect2) -> void:
	if host.page_input_blocked(): return
	if start_page.active(host.window_id): start_page.draw(host)
	else:
		host._button(WEB, "", bounds.get_center(), bounds.size)
		host._buttons.back().node.set_meta("menu_eye_buffer", true)
		host._buttons.back().node.set_meta("browser_world_pointer", true)
		var page: Dictionary = host.page_layout()
		host._buttons.back().node.global_transform = page.pose
		host._buttons.back().node.mesh.size = page.size
		host._buttons.back().rect.size = page.size

## The native handoff is the browser's main action: an accent pill with icon and words,
## muted on pages the player cannot take over.
func beta_available(current: Dictionary) -> bool:
	# Foreign adapters remain available only through their actual webpage test
	# buttons. A sample passing does not advertise a site-wide toolbar action.
	var url := str(current.get("url", ""))
	return Methods.supports(menu.platform, "web_video_resolve_beta") and Sites.beta_replaces_legacy_url(url) and (beta_site_available(current) or Sites.supports_beta_url(url))

func toolbar_tools(host: Node, current: Dictionary) -> Array:
	var result: Array = []
	if not host.cinema().is_empty(): result.append(BASE + 8)
	result.append(BASE + 17)
	if current.get("editing", false): result.append(KEY_CONTROL + 7)
	elif current.get("network_capture_available", false): result.append(BASE + 15)
	result.append(host.MOVE)
	return result

func draw_toolbar_tools(host: Node, current: Dictionary) -> void:
	var entries := toolbar_tools(host, current)
	var icons := {BASE + 8: "floating_window" if host.on_screen() else "cinema_screen",
		BASE + 19: "close" if host.selecting else "expand" if host.is_focused() else "region_focus",
		BASE + 16: "depth", BASE + 17: "settings",
		KEY_CONTROL + 7: "keyboard_hide", BASE + 15: "media_detect", host.MOVE: ""}
	var tips := {BASE + 8: "Floating window" if host.on_screen() else "Cinema screen",
		BASE + 19: "Cancel selection" if host.selecting else "Exit focus" if host.is_focused() else "Focus free region",
		BASE + 16: "2D to 3D effect", BASE + 17: "Settings",
		KEY_CONTROL + 7: "Close keyboard", BASE + 15: "Media detection on this site", host.MOVE: "Move window"}
	for i in entries.size():
		var target: int = entries[i]
		var selected: bool = host.depth.enabled if target == BASE + 16 else host.depth_settings if target == BASE + 17 else (host.is_focused() or host.selecting) if target == BASE + 19 else current.get("network_capture_enabled", false) if target == BASE + 15 else false
		host._button(target, "", Vector2(0.79 - (entries.size() - 1 - i) * 0.128, host.PLAY_Y), host.TOOL_SIZE, not start_page.active(host.window_id) if target == BASE + 19 else true, icons[target], selected)
		host._tips[target] = I18n.t(tips[target])
		if target == BASE + 16:
			if not host.depth.error.is_empty(): host._tips[target] += "\n" + I18n.t(host.depth.error)
			elif host.depth.enabled: host._tips[target] += "\n" + I18n.t("3D on" if host.depth.state == "ready" else "Preparing 3D")
		if target == BASE + 15: host._tips[target] += " · " + I18n.t("On" if selected else "Off") + "\n" + I18n.t("Replay the video after enabling")
		if target == host.MOVE:
			for x in [-0.012, 0.012]:
				for y in [-0.024, 0.0, 0.024]:
					host._buttons.back().node.add_child(host._quad(Vector2(0.008, 0.008), Vector3(x, y, 0.004), host.MUTED, 12))

func draw_play_button(host: Node) -> void:
	var own: bool = handoff and owns_handoff(host, handoff_context)
	var current := window_state(host.window_id)
	var beta := beta_available(current)
	var cancel_old: bool = own and not handoff_beta
	var ready: bool = cancel_old or (not handoff and data.get("native_supported", false) and focused_window == host.window_id)
	var label := I18n.t("Cancel" if cancel_old else "Play in player")
	var space := 1.44 - toolbar_tools(host, current).size() * 0.128
	var show_beta: bool = (beta or (own and handoff_beta)) and not cancel_old
	var show_legacy: bool = not show_beta or not Sites.beta_replaces_legacy_url(str(current.get("url", "")))
	var width := (space - 0.016) / 2 if show_beta and show_legacy else space
	if show_beta:
		var cancel_beta: bool = own and handoff_beta
		var media_ready: bool = beta_site_available(current) and beta_media_ready(current)
		var beta_ready: bool = cancel_beta or (not handoff and focused_window == host.window_id and media_ready)
		var beta_label := I18n.t("Cancel" if cancel_beta else "Play (Beta)")
		var left := -0.59 + (width + 0.016 if show_legacy else 0.0)
		host._button(BASE + 18, "", Vector2(left + width / 2, host.PLAY_Y), Vector2(width, host.TOOL_SIZE.y), beta_ready, "", beta_ready)
		var button: Node3D = host._buttons.back().node
		button.material_override.set_shader_parameter("corner_radius", 0.035)
		var ink: Color = host._buttons.back().foreground if beta_ready else host.MUTED
		host._icon("stop" if cancel_beta else Sites.BETA_ICON, Vector3(-width / 2 + 0.045, 0, 0.004), 0.05, ink, button)
		var text: Label3D = host._label(host._fit_title(beta_label, "", width - 0.10, 22), Vector3(0.025, 0, 0.004), 22, button)
		text.modulate = ink
		host._tips[BASE + 18] = I18n.t("Cancel" if cancel_beta else ("Play in player (Beta)" if media_ready else "Video not ready"))
		if not show_legacy: return
	host._button(BASE + 6, "", Vector2(-0.59 + width / 2, host.PLAY_Y), Vector2(width, host.TOOL_SIZE.y), ready, "", ready)
	var node: Node3D = host._buttons.back().node
	node.material_override.set_shader_parameter("corner_radius", 0.035)
	var color: Color = host._buttons.back().foreground if ready else host.MUTED
	host._icon("stop" if cancel_old else "play", Vector3(-width / 2 + 0.045, 0, 0.004), 0.05, color, node)
	var caption: Label3D = host._label(host._fit_title(label, "", width - 0.10, 22), Vector3(0.025, 0, 0.004), 22, node)
	caption.modulate = color
	host._tips[BASE + 6] = label

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
		tab.base_color = UiTheme.color("browser_tab_selected") if selected else UiTheme.color("browser_tab")
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
	if history.action(target): return true
	if start_page.action(target): return true
	if active() and target == HISTORY:
		cancel(); menu.system_text_input.cancel("web_browser")
		ChineseInput.close("browser"); _keyboard_target.clear()
		menu.platform.web_browser_action("blur")
		if handoff: _cancel_handoff()
		history.opened = not history.opened; history.page = 0; history.scroll_step = 0.0
		tabs_open = false; window_action.clear(); saved_poll = 0
		refresh_windows(); return true
	if active() and target == PASTE:
		var text := clipboard_address()
		if not text.is_empty():
			if menu.system_text_input.active("web_browser"): menu.system_text_input.set_text("web_browser", text)
			else: _edit_address(text)
		return true
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
			_edit_address(draft)
		4: menu.platform.web_browser_action("bookmark"); saved_poll = 0; refresh_windows()
		5: tab_command("close_window")
		7:
			history.reset()
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
			if handoff:
				# A page-only experiment still needs a working Cancel while pending.
				if not handoff_beta or int(handoff_context.get("window", 0)) != focused_window: return true
				_handoff_failed(); menu.refresh()
			else:
				if not beta_available(window_state(focused_window)): return true
				_begin_handoff(true); menu.refresh()
	return true

func _playhead(native_start: bool = false) -> int:
	var best := {}; var score := -1.0
	var selection := str(handoff_context.get("selection", ""))
	for item in data.get("videos", []):
		if not selection.is_empty() and str(item.get("selection", "")) != selection: continue
		var area := float(item.get("width", 0)) * float(item.get("height", 0))
		var candidate := area + (1.0e12 if item.get("playing", false) else 0.0) + (1.0e15 if item.get("fullscreen", false) else 0.0) + (1.0e18 if handoff_beta and (item.get("bilibili_ready", false) or item.get("douyin_ready", false)) else 0.0)
		if candidate > score: score = candidate; best = item
	var seconds := float(best.get("beta_time", best.get("time", 0.0))) if native_start and handoff_beta else float(best.get("time", 0.0))
	return int(clampf(seconds, 0.0, 604800.0) * 1000.0) if is_finite(seconds) else 0

func clipboard_address() -> String:
	# Read only on the explicit paste action, including clipboard changes since the last draw.
	var text: String = menu.platform.media_clipboard_text() if Methods.supports(menu.platform, "media_clipboard_text") else DisplayServer.clipboard_get()
	return menu.SystemTextInput.clean(text, 4096).strip_edges()

func _edit_address(value: String) -> void:
	ChineseInput.close("browser"); _keyboard_target.clear()
	menu.platform.web_browser_action("blur")
	draft = value
	menu.system_text_input.begin("web_browser", draft, 4096, _edited, _navigate)
	refresh_windows()

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
func press(owner: String, origin: Vector3, direction: Vector3, tracked: bool, button: String = "trigger_click") -> bool:
	if not active(): return false
	if button == "trigger_click" and not hand.is_empty(): return true
	var host := input_host()
	var hit: Dictionary = host.ray_hit(origin, direction) if tracked else {}
	if int(hit.get("target", -1)) != WEB: return false
	var id := int(hit.get("window", 1))
	var page: Node = windows.get(id)
	if page == null: return false
	if button == "ax_button":
		# Leave browser chrome, including focus selection and choice popups, on the trigger.
		if not hit.get("enabled", true) or page.selecting or not page.depth_choices.opened.is_empty(): return false
		if host.has_pointer_capture(): return true
	pointer_window = id; focus_window(id)
	var location: Variant = page.page_point(origin, direction)
	if location == null: return false
	hand = owner; point = location
	_pointer_button = button
	_page_dragging = false
	page.show_press(point)
	_pointer("down", point); return true
func _within_tap_slop(origin: Vector3, location: Vector2) -> bool:
	# Until a drag starts, point is the original touch-down position.
	var page: Node = windows[pointer_window]
	var start: Vector3 = page.page_world_point(point)
	return start.distance_to(page.page_world_point(location)) <= TAP_SLOP_METRES * maxf(1.0, origin.distance_to(start))
func move(owner: String, origin: Vector3, direction: Vector3, tracked: bool) -> void:
	if not active(): return
	if hand == owner:
		var projected: Variant = windows[pointer_window].page_point(origin, direction) if tracked else null
		if projected == null: cancel(); return
		if not _page_dragging and _within_tap_slop(origin, projected): return
		if projected.distance_squared_to(point) < 1.0e-8: return
		_page_dragging = true
		point = projected; _pointer("move", point)
	elif hand.is_empty() and tracked:
		var hit: Dictionary = input_host().ray_hit(origin, direction)
		if int(hit.get("target", -1)) == WEB:
			var id := int(hit.get("window", 1))
			if windows[id].selecting: return
			if id == focused_window:
				# A resting ray must not make Gecko hit-test the page every frame.
				var now := Time.get_ticks_msec()
				if now < _scroll_hover_until: return
				var hover: Variant = windows[id].page_point(origin, direction)
				if hover == null: return
				if id == pointer_window and (((hover - point) * windows[id].page_css_scale()).length() < HOVER_DEADZONE_CSS
						or now - _hover_sent_ms < HOVER_INTERVAL_MS): return
				pointer_window = id; point = hover; _hover_sent_ms = now; _pointer("move", point)
func owns_pointer(owner: String, button: String) -> bool:
	return hand == owner and _pointer_button == button
func release(owner: String, origin: Vector3, direction: Vector3, tracked: bool, button: String = "trigger_click") -> bool:
	if not owns_pointer(owner, button): return false
	var projected: Variant = windows[pointer_window].page_point(origin, direction) if tracked else null
	if projected == null:
		cancel(); return true
	if not _page_dragging and _within_tap_slop(origin, projected):
		projected = point
	elif not Rect2(Vector2.ZERO, Vector2.ONE).has_point(projected):
		cancel(); return true
	elif not _page_dragging:
		# A fast drag can cross the threshold on the release frame itself.
		_pointer("move", projected)
	point = projected
	_pointer("up", point); hand = ""; _pointer_button = ""
	return true
func cancel() -> void:
	if not hand.is_empty() and supported(): _pointer("cancel", point)
	hand = ""; _pointer_button = ""
func scroll(amount: float, delta: float) -> bool:
	if library.active() and not library.modal.is_empty(): return true
	if not active(): return false
	if history.active(focused_window): history.scroll(amount, delta); return true
	if tabs_open: return true
	if windows.has(focused_window) and windows[focused_window].selecting: return true
	if hand.is_empty() and is_finite(amount) and absf(amount) > 0.2:
		pointer_window = focused_window; _pointer("scroll", point, amount * delta * 8.0)
		_scroll_hover_until = Time.get_ticks_msec() + SCROLL_HOVER_HOLD_MS
	return true
