extends RefCounted
## The playing DVD/HDMV disc menu: its button plane (drawn like a bitmap cue), ray input
## at plane coordinates, and the moment a menu choice starts a real title.
const PlatformMethods := preload("res://scripts/platform_methods.gd")
const POINT := 0
const ACTIVATE := 1
const TOP_MENU := 7
## Hover selects a button only once the ray rests on it, so sweeping across a row
## on the way to a submenu does not move the focus (fractions of the plane width).
const DWELL_MS := 120
const STEADY := 0.012
## After a press the focus belongs to the disc (a submenu often takes it): pointing
## resumes only once the ray has left the pressed spot.
const HOLD := 0.03

var state := {}
## The plane's occupied crop as a bitmap cue (x, y, width, height, canvas size, version); empty when blank.
var bitmap := {}
var pixels := PackedByteArray()
var _version := -1
var _poll_ms := 0
var _point := Vector2i(-1, -1)
var _point_ms := 0
var _candidate := Vector2i(-1, -1)
var _candidate_ms := 0
var _hold := Vector2i(-1, -1)
var _handoff_since := 0
var handed_off := false

func reset() -> void:
	state = {}; bitmap = {}; pixels = PackedByteArray(); _version = -1; _poll_ms = 0
	_point = Vector2i(-1, -1); _handoff_since = 0; handed_off = false
	_candidate = Vector2i(-1, -1); _hold = Vector2i(-1, -1)

func active() -> bool:
	return bool(state.get("active", false))

## Polls navigation; returns true when the button plane changed.
func poll(platform: Object, now_ms: int) -> bool:
	if now_ms < _poll_ms or not PlatformMethods.supports(platform, "mpv_disc_menu_state"): return false
	_poll_ms = now_ms + 80
	var report: Variant = JSON.parse_string(str(platform.mpv_disc_menu_state()))
	if not report is Dictionary: return false
	state = report
	var version := int(state.get("version", 0)) if active() else -1
	if version == _version: return false
	_version = version
	bitmap = {}; pixels = PackedByteArray()
	if version < 0 or not state.get("buttons", false): return true
	var data := PackedByteArray(platform.mpv_disc_menu_overlay(version))
	if data.size() <= 24: return true
	var w := data.decode_s32(8); var h := data.decode_s32(12)
	if w <= 0 or h <= 0 or data.size() != 24 + w * h * 4: return true
	pixels = data.slice(24)
	bitmap = {"version": version, "x": data.decode_s32(0), "y": data.decode_s32(4), "width": w, "height": h,
		"canvas_width": data.decode_s32(16), "canvas_height": data.decode_s32(20)}
	return true

## A menu choice that started a listed title (not the menu's own loops):
## {playlist, position_ms} once it has held for a moment, else {}.
func handoff(titles: Array, now_ms: int) -> Dictionary:
	var title := int(state.get("title", -1))
	var playlist := int(state.get("playlist", -1))
	var listed := titles.any(func(row): return int(row.playlist) == playlist)
	if handed_off or not active() or not state.get("seen", false) or title < 1 or title == 0xffff or state.get("menu", false) or not listed:
		_handoff_since = 0
		return {}
	if _handoff_since == 0: _handoff_since = now_ms
	# The chapter follows the playlist event: wait briefly so a chapter jump starts there.
	if int(state.get("chapter", 0)) < 1 and now_ms - _handoff_since < 1000: return {}
	if now_ms - _handoff_since < 250: return {}
	handed_off = true
	# The disc's language choices: the stream's position among the title's tracks of
	# that type (-1 unknown; subtitles -2 off).
	return {"playlist": playlist, "position_ms": maxi(0, int(state.get("chapter_ms", 0))),
		"audio_index": int(state.get("audio_index", -1)), "subtitle_index": int(state.get("subtitle_index", -1))}

## Plane pixel under a screen UV (0..1, top left origin), or (-1, -1).
func plane_point(uv: Vector2) -> Vector2i:
	var size := Vector2i(int(state.get("width", 0)), int(state.get("height", 0)))
	if size.x <= 0 or size.y <= 0 or uv.x < 0 or uv.y < 0 or uv.x > 1 or uv.y > 1: return Vector2i(-1, -1)
	return Vector2i(mini(size.x - 1, int(uv.x * size.x)), mini(size.y - 1, int(uv.y * size.y)))

## Hover selects the button the ray rests on; repeated positions are not resent.
func point(platform: Object, uv: Vector2, now_ms: int) -> void:
	var at := plane_point(uv)
	if at.x < 0 or not PlatformMethods.supports(platform, "mpv_disc_menu_input"): return
	var width := float(state.get("width", 1920))
	if _hold.x >= 0:
		if Vector2(at - _hold).length() < HOLD * width: return
		_hold = Vector2i(-1, -1)
	if _candidate.x < 0 or Vector2(at - _candidate).length() > STEADY * width:
		_candidate = at; _candidate_ms = now_ms
		return
	if now_ms - _candidate_ms < DWELL_MS or now_ms - _point_ms < 33: return
	if _point.x >= 0 and Vector2(at - _point).length() <= STEADY * width: return # hand jitter on the same spot
	_point = at; _point_ms = now_ms
	platform.mpv_disc_menu_input(POINT, at.x, at.y)
	_poll_ms = 0

## Back to the disc's top menu (the remote's menu key).
func top_menu(platform: Object) -> bool:
	if not active() or not PlatformMethods.supports(platform, "mpv_disc_menu_input"): return false
	_hold = Vector2i(-1, -1); _candidate = Vector2i(-1, -1); _point = Vector2i(-1, -1)
	_poll_ms = 0
	return int(platform.mpv_disc_menu_input(TOP_MENU, 0, 0)) > 0

func activate(platform: Object, uv: Vector2) -> bool:
	var at := plane_point(uv)
	if at.x < 0 or not state.get("buttons", false) or not PlatformMethods.supports(platform, "mpv_disc_menu_input"): return false
	_point = at; _hold = at; _candidate = Vector2i(-1, -1)
	platform.mpv_disc_menu_input(ACTIVATE, at.x, at.y)
	_poll_ms = 0
	return true
