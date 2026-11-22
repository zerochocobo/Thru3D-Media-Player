extends Node3D

signal status_changed

const Methods := preload("res://scripts/platform_methods.gd")
const Space := preload("res://scripts/danmaku_space.gd")
const SEGMENT_MS := 360000
const PREFETCH_MS := 20000
const FEED_BUDGET := 40
const SETTINGS := "danmaku"

var cid := ""
var enabled := false
var mode := 0
var density := 1
var cover_screen := true
var outside_only := false
var transparency := 0.0
var menu: Node3D
var _platform: Object
var _request := 0
var _requested_part := 0
var _segments: Dictionary = {}
var _failed: Dictionary = {}
var _poll_ms := 0
var _status := ""
var _clock := -1.0
var _observed := -1
var _since_observed := 0.0
var _was_running := false
var _hidden := false
var _feed_part := 0
var _feed_index := -1
var _feed_from := 0
var _space := Space.new()

func _init() -> void:
	add_child(_space)
	_space.top_level = true

func _exit_tree() -> void:
	_cancel()

func restore(config: ConfigFile) -> void:
	enabled = bool(config.get_value(SETTINGS, "enabled", false))
	mode = clampi(int(config.get_value(SETTINGS, "mode", 0)), 0, 1)
	density = clampi(int(config.get_value(SETTINGS, "density", 1)), 0, 2)
	cover_screen = bool(config.get_value(SETTINGS, "cover_screen", true))
	outside_only = bool(config.get_value(SETTINGS, "outside_only", false))
	transparency = clampf(float(config.get_value(SETTINGS, "transparency", 0.0)), 0.0, 90.0)
	_space.configure(mode, density, outside_only)
	_space.set_transparency(transparency)

func setting(key: String, value: Variant, config: ConfigFile) -> bool:
	if cid.is_empty(): return false
	match key:
		"danmaku_enabled":
			enabled = bool(value)
			config.set_value(SETTINGS, "enabled", enabled)
			if not enabled: _cancel()
			_failed.clear()
			_space.recenter()
			_reset_timeline()
		"danmaku_mode":
			mode = clampi(int(value), 0, 1)
			config.set_value(SETTINGS, "mode", mode)
			_space.configure(mode, density, outside_only)
			_reset_timeline()
		"danmaku_density":
			density = clampi(int(value), 0, 2)
			config.set_value(SETTINGS, "density", density)
			_space.configure(mode, density, outside_only)
			_reset_timeline()
		"danmaku_cover_screen", "danmaku_outside_only":
			if key == "danmaku_cover_screen":
				cover_screen = bool(value)
				config.set_value(SETTINGS, "cover_screen", cover_screen)
			else:
				outside_only = bool(value)
				config.set_value(SETTINGS, "outside_only", outside_only)
				_space.configure(mode, density, outside_only)
			# The lanes may change, and a paused frame also has to obey the new screen
			# bounds right away: lay the comments out again from those in flight.
			_reset_timeline()
		"danmaku_transparency":
			if not is_finite(float(value)): return false
			transparency = clampf(float(value), 0.0, 90.0)
			config.set_value(SETTINGS, "transparency", transparency)
			_space.set_transparency(transparency)
		_: return false
	return true

func snapshot() -> Dictionary:
	# Outside the picture only means something while a flat picture leaves room around it.
	var video := get_parent()
	var flat: bool = video != null and video.get("geometry") == Space.Geometry.Geometry.FLAT
	return {"available": not cid.is_empty(), "enabled": enabled, "mode": mode,
		"density": density, "cover_screen": cover_screen, "outside_only": outside_only,
		"outside_available": flat, "status": _status}

func open(platform: Object, media_cid: String) -> void:
	close()
	if media_cid.is_empty(): return
	if (Methods.supports(platform, "bilibili_danmaku_fetch")
			and Methods.supports(platform, "bilibili_danmaku_poll")
			and Methods.supports(platform, "bilibili_danmaku_cancel")):
		_platform = platform
		cid = media_cid

func close() -> void:
	_cancel()
	cid = ""
	_platform = null
	_segments.clear()
	_failed.clear()
	_space.recenter()
	_reset_timeline()
	_status = ""

func recenter() -> void:
	_space.recenter()
	_reset_timeline()

func suspend() -> void:
	_space.hide_labels()

func _cancel() -> void:
	if _request > 0 and is_instance_valid(_platform): _platform.bilibili_danmaku_cancel(_request)
	_request = 0

func _reset_timeline() -> void:
	_space.clear()
	_clock = -1.0
	_observed = -1
	_feed_part = 0

func tick(video: Node3D, delta: float) -> void:
	if cid.is_empty() or not enabled: return
	if video.browser_screen_owned or video.media.state in ["failed", "ended", "closed"]:
		_space.hide_labels()
		return
	var seeking: bool = video.control.pending or video.control.in_flight != 0
	var playable: bool = video.media.frame_counter > 0 and not video._waiting_first and not seeking
	var observed: int = video.control.observed_position_ms
	var position: int = video.control.target_ms if seeking else observed
	_fetch(position, video.control.duration_ms)
	if not playable:
		_reset_timeline()
		return
	var details: Dictionary = video.media.playback.get("details", {})
	var running: bool = video.requested_play and video.media.state == "playing" and details.get("paused_for_cache", "no") != "yes"
	# The confirmed position arrives in uneven steps (frame claims or state reports).
	# Extrapolate it between updates and let a free-running clock follow it gently.
	if observed != _observed or (running and not _was_running):
		_observed = observed
		_since_observed = 0.0
	elif running:
		_since_observed = minf(_since_observed + delta * 1000.0, 400.0)
	_was_running = running
	var predicted: float = float(observed) + (_since_observed * video.playback_speed if running else 0.0)
	if _clock < 0 or absf(predicted - _clock) > 1500.0:
		_space.clear()
		_clock = predicted
		_restart_feed()
	elif running:
		var step: float = delta * 1000.0 * video.playback_speed
		_clock += step + clampf((predicted - _clock) * 0.05, -step * 0.2, step * 0.2)
	if not _space.prepare(video, menu, cover_screen, delta):
		_space.hide_labels()
		_hidden = true
		return
	if _hidden:
		_hidden = false
		_space.clear()
		_restart_feed()
	_feed()
	_space.advance(_clock)

## Start from comments that are already part way through their path.
func _restart_feed() -> void:
	_feed_from = maxi(0, int(_clock - _space.lead_ms()))
	_feed_part = floori(float(_feed_from) / SEGMENT_MS) + 1
	_feed_index = -1

## Hand comments to the layout ahead of their timestamp, in time order and with a
## bounded amount of text measurement per frame.
func _feed() -> void:
	var horizon := int(_clock + _space.lead_ms())
	var budget := FEED_BUDGET
	while budget > 0 and _feed_part > 0:
		if _failed.has(_feed_part):
			if _feed_part * SEGMENT_MS > horizon: return
			_feed_part += 1
			_feed_index = 0
			continue
		var items: Array = _segments.get(_feed_part, [])
		if not _segments.has(_feed_part): return
		if _feed_index < 0: _feed_index = _lower_bound(items, _feed_from)
		if _feed_index >= items.size():
			if _feed_part * SEGMENT_MS > horizon: return
			_feed_part += 1
			_feed_index = 0
			continue
		var item: Array = items[_feed_index]
		if int(item[0]) > horizon: return
		_feed_index += 1
		budget -= 1
		_space.feed(item, _clock)

func _fetch(position: int, duration: int) -> void:
	var part := floori(float(position) / SEGMENT_MS) + 1
	var following := part + 1 if position % SEGMENT_MS >= SEGMENT_MS - PREFETCH_MS and duration > part * SEGMENT_MS else part
	for segment: int in _segments.keys():
		if segment < part - 1 or segment > following: _segments.erase(segment)
	for segment: int in _failed.keys():
		if segment < part - 1 or segment > following: _failed.erase(segment)
	if _request > 0 and (_requested_part < part or _requested_part > following
			or (_requested_part != part and not _segments.has(part) and not _failed.has(part))):
		_cancel()
	var now := Time.get_ticks_msec()
	if _request > 0 and now >= _poll_ms:
		_poll_ms = now + 80
		var reply := str(_platform.bilibili_danmaku_poll(_request))
		if not reply.is_empty():
			_request = 0
			var packet: Variant = JSON.parse_string(reply)
			if packet is Dictionary and packet.get("items") is Array: _segments[_requested_part] = packet.items
			else: _failed[_requested_part] = true
	if _request == 0:
		for segment in range(part, following + 1):
			if _segments.has(segment) or _failed.has(segment): continue
			_requested_part = segment
			_request = _platform.bilibili_danmaku_fetch(cid, segment)
			if _request == 0: _failed[segment] = true
			break
	var status := ""
	if _failed.has(part): status = "Danmaku unavailable"
	elif not _segments.has(part): status = "Loading danmaku…"
	elif _segments[part].is_empty(): status = "No danmaku in this segment"
	if status != _status:
		_status = status
		status_changed.emit()

static func _lower_bound(items: Array, time: int) -> int:
	var left := 0
	var right := items.size()
	while left < right:
		var middle := (left + right) >> 1
		if int(items[middle][0]) < time: left = middle + 1
		else: right = middle
	return left
