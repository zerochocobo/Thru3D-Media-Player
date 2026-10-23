extends RefCounted
## Blu-ray ISO titles of the playing disc. The longest title still plays first;
## the list lets the viewer switch to another playlist (extras, other cuts).
const PlatformMethods := preload("res://scripts/platform_methods.gd")

## Disc whose titles are known, the title that disc plays by default and the playing one.
var uri := ""
var titles: Array = []
var main := -1
## No playback record when this disc was opened: its list may open by itself.
var first_view := false
var playing := -1
## The disc's top menu kind from its preflight ("hdmv" can be shown) and whether it is 3D.
var menu_kind := ""
var stereo := false
## This open plays the disc's own HDMV menu instead of a title.
var menu_session := false
const MENU := -2
var _next := -1
var _next_uri := ""
var _sent := -1
var _poll_ms := 0
var _session := 0
var _polls := 0

func reset() -> void:
	uri = ""; titles = []; main = -1; first_view = false; playing = -1; _next = -1; _next_uri = ""; _sent = -1
	menu_kind = ""; stereo = false; menu_session = false

## Unlike the main title, an extra or the menu must not overwrite the disc's resume position.
func extra() -> bool:
	return menu_session or (playing >= 0 and main >= 0 and playing != main)

## The disc's own interactive menu can be played (HDMV top menu, not 3D).
func menu_available() -> bool:
	return menu_kind == "hdmv" and not stereo and not uri.is_empty()

## The disc has a Java (BD-J) menu, or an HDMV one that turned out to need it.
func menu_unsupported() -> bool:
	return menu_kind in ["bdj", "unsupported"] and not uri.is_empty()

func available() -> bool:
	return titles.size() > 1

## The next open of uri plays the disc's menu.
func menu_requested(target_uri: String) -> bool:
	return _next_uri == target_uri and _next == MENU

## The next open of uri plays this playlist (-1: the disc's longest title).
func request(target_uri: String, playlist: int) -> void:
	_next_uri = target_uri; _next = playlist

## Before open_mpv_video. Another file forgets this disc; a request is used once.
## An internal reopen (layer, Alpha, recovery) stays on the title it replaces.
func before_open(platform: Object, target_uri: String, internal: bool, unseen: bool = false) -> void:
	var playlist := -1
	if _next_uri == target_uri: playlist = _next
	elif internal and target_uri == uri: playlist = playing if playing >= 0 else _sent
	_next = -1; _next_uri = ""; _sent = playlist
	if target_uri != uri:
		reset()
		uri = target_uri
		first_view = unseen
	playing = -1 # this open's title arrives with its preflight
	menu_session = playlist == MENU
	_polls = 0; _poll_ms = 0
	if PlatformMethods.supports(platform, "set_mpv_disc_title"): platform.set_mpv_disc_title(playlist)

## Reads the preflight's title list once per open; cheap until it arrives.
func poll(platform: Object, session_id: int, now_ms: int) -> bool:
	if session_id != _session: _session = session_id; _polls = 0
	# Other media never report titles: stop asking after the opening minute.
	if session_id <= 0 or _polls < 0 or _polls >= 120 or now_ms < _poll_ms or uri.is_empty() or not PlatformMethods.supports(platform, "mpv_disc_titles"): return false
	_poll_ms = now_ms + 500; _polls += 1
	var text := str(platform.mpv_disc_titles(session_id))
	if text.is_empty(): return false
	var report: Variant = JSON.parse_string(text)
	if not report is Dictionary: return false
	var current := int(report.get("playlist", -1))
	if current < 0: return false
	_polls = -1 # one report per open
	# A menu that failed to run stays unavailable for this disc.
	if menu_kind != "unsupported": menu_kind = str(report.get("menu", ""))
	stereo = bool(report.get("mvc", false))
	if main < 0: main = current # the disc's default title, also known from a menu session's preflight
	if menu_session:
		titles = ordered(report.get("titles", []), main)
		return true
	if current == playing: return false
	playing = current
	titles = ordered(report.get("titles", []), main)
	return true

## Main title first, then longer titles first; identical copies (obfuscation
## playlists, duplicate cuts) are listed once.
static func ordered(rows: Array, main_playlist: int) -> Array:
	var valid := rows.filter(func(row): return row is Dictionary and int(row.get("playlist", -1)) >= 0)
	valid.sort_custom(func(a, b):
		if (int(a.playlist) == main_playlist) != (int(b.playlist) == main_playlist): return int(a.playlist) == main_playlist
		if int(a.get("duration_ms", 0)) != int(b.get("duration_ms", 0)): return int(a.get("duration_ms", 0)) > int(b.get("duration_ms", 0))
		return int(a.playlist) < int(b.playlist))
	var seen := {}
	var result: Array = []
	for row in valid:
		var key := str([int(int(row.get("duration_ms", 0)) / 1000), int(row.get("chapters", 0)), int(row.get("audio", 0)), int(row.get("subtitles", 0)), int(row.get("height", 0))])
		if seen.has(key): continue
		seen[key] = true
		result.append(row)
	return result

static func duration_text(milliseconds: int) -> String:
	var seconds := maxi(0, int(milliseconds / 1000))
	if seconds >= 3600: return "%d:%02d:%02d" % [seconds / 3600, seconds / 60 % 60, seconds % 60]
	return "%d:%02d" % [seconds / 60, seconds % 60]
