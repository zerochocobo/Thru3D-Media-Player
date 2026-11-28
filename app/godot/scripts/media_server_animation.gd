extends RefCounted

const Methods := preload("res://scripts/platform_methods.gd")
const Track := preload("res://scripts/media_artwork_track.gd")
const DWELL_MS := 250
const MAX_PLAYING := 3
const ROTATE_MS := 12000
var _owner: WeakRef
var focus := {}:
	set(value):
		if not is_same(focus, value) and (not focus.is_empty() or not value.is_empty()): _plan_at = 0
		focus = value
var autoplay := {}: # The current slideshow backdrop or the open picture.
	set(value):
		autoplay = value
		_plan_at = 0
var auto_covers := false:
	set(value):
		auto_covers = value
		_plan_at = 0
var foreground := true
var _cards := {}
var _tracks := {}
var _stills := {}
var _listings := {}
var _last_focus := ""
var _rebind_until := 0
var _rotation := 0
var _rotate_at := 0
var _plan_at := 0
var _scrolling := false

func _init(browser: RefCounted) -> void:
	_owner = weakref(browser)

func begin_layout() -> void:
	_last_focus = str(focus.get("key", _last_focus))
	focus = {}
	autoplay = {}
	_cards.clear()

func binding(node: Dictionary, surface: MeshInstance3D, poster: Texture2D, card := true) -> Dictionary:
	var browser = _owner.get_ref()
	var req: Dictionary = browser._image_request(node)
	if str(req.scene_id).is_empty(): return {}
	if req.has("max_width") and browser.server.get("provider") in ["emby", "jellyfin"]:
		req.max_width = 512
	var image_key: String = browser._request_image_key(req)
	var candidates := [{"key": image_key, "req": req}]
	var identity := image_key
	var lookup := ""
	if card:
		# Some compatible servers expose only the first tag in list summaries.
		if browser.view in ["scenes", "home"] and browser.server.get("provider") in ["emby", "jellyfin"] \
			and node.get("kind") == "video" and node.get("preview_backdrops", []).size() < 2:
			lookup = str(node.id)
			identity += "|lookup:" + lookup
		for image in node.get("preview_backdrops", []):
			var other: Dictionary = browser._image_request({"cover_image": image})
			var other_key: String = browser._request_image_key(other)
			if other_key == image_key: continue
			candidates.append({"key": other_key, "req": other})
			identity += "|" + other_key
		# A film may appear in two strips on the same page.
		var base := identity
		var copy := 1
		while _cards.has(identity):
			copy += 1
			identity = base + "#" + str(copy)
	else: identity = "background:" + image_key
	var edge := 640 if browser.view in ["detail", "metadata", "picture"] else 512
	var slot := {"key": identity, "req": req, "candidates": candidates, "lookup": lookup, "surface": surface,
		"poster": poster, "edge": edge, "footprint": surface.mesh.size}
	if card: _cards[identity] = slot
	return slot

func stop() -> void:
	var menu: Node = _owner.get_ref().menu
	for track in _tracks.values(): track.close(menu)
	_tracks.clear()
	_plan_at = 0

func clear() -> void:
	stop()
	begin_layout()
	_last_focus = ""
	_rebind_until = 0
	_rotation = 0
	_rotate_at = 0

func clear_cache() -> void:
	clear()
	_stills.clear()
	_listings.clear()

func _visible(slot: Dictionary) -> bool:
	return not slot.is_empty() and is_instance_valid(slot.surface) and slot.surface.is_visible_in_tree()

func _wanted(browser: RefCounted, now: int) -> Array:
	var pointed := focus
	# A redraw clears ray hits for one frame. Rebind only if the same card was drawn again.
	if pointed.is_empty() and not _last_focus.is_empty() and _cards.has(_last_focus) and _tracks.has(_last_focus):
		if _rebind_until == 0: _rebind_until = now + 40
		if now < _rebind_until: pointed = _cards[_last_focus]
	if not focus.is_empty() or pointed.is_empty():
		_last_focus = ""
		_rebind_until = 0
	if _scrolling or not _visible(pointed): pointed = {}
	var background := _visible(autoplay)
	if browser.view == "picture": return [autoplay] if background else []
	if not auto_covers:
		if _scrolling: return []
		if not pointed.is_empty(): return [pointed]
		return [autoplay] if background else []

	var wanted := []
	if background: wanted.append(autoplay)
	if not pointed.is_empty(): wanted.append(pointed)
	if _cards.is_empty(): return wanted
	if _rotate_at == 0: _rotate_at = now + ROTATE_MS
	if now >= _rotate_at:
		_rotation = (_rotation + 1) % _cards.size()
		_rotate_at = now + ROTATE_MS
	var cards := _cards.values()
	for i in cards.size():
		var card: Dictionary = cards[(i + _rotation) % cards.size()]
		if is_same(card, pointed) or not _visible(card): continue
		# Keep already playing visible cards while scrolling; probe new ones after settling.
		var track: Track = _tracks.get(card.key)
		if not _scrolling or (track != null and track.session > 0): wanted.append(card)
	return wanted

func tick(now: int) -> void:
	if focus.is_empty() and autoplay.is_empty() and _tracks.is_empty() and (not auto_covers or _cards.is_empty()): return
	var browser = _owner.get_ref()
	var menu: Node = browser.menu
	if not foreground or not menu.is_visible_in_tree() or menu.section != menu.Section.MEDIA_SERVER \
		or menu.release_notes.opened or menu.archives.browsing or browser.settings_open or browser.sources_open \
		or not browser.keyboard.is_empty() or not browser.detail_actions.is_empty() or browser.sorting():
		if not _tracks.is_empty(): stop()
		return

	var scrolling: bool = not browser.gallery.capture.is_empty() or absf(menu._fling) > 0.4
	if scrolling != _scrolling:
		_scrolling = scrolling
		_plan_at = 0
	if now >= _plan_at:
		_plan_at = now + 80
		_select(browser, now)
		if _rebind_until > now: _plan_at = mini(_plan_at, _rebind_until)
	for track in _tracks.values():
		if track.finished: continue
		track.tick(browser, _stills, _listings, now)
		if track.finished: _plan_at = 0

func _select(browser: RefCounted, now: int) -> void:
	var menu: Node = browser.menu
	var kept := {}
	var busy := 0
	for slot in _wanted(browser, now):
		var track: Track = _tracks.get(slot.key)
		if track == null or not track.finished:
			if busy >= MAX_PLAYING: continue
			busy += 1
		if track == null:
			if not Methods.supports(menu.platform, "media_artwork_start"): continue
			track = Track.new(slot, now if browser.view == "picture" else now + DWELL_MS)
		else: track.rebind(menu, slot)
		kept[slot.key] = track
	for key in _tracks:
		if not kept.has(key): _tracks[key].close(menu)
	_tracks = kept

func receive(id: int, payload: String) -> bool:
	if id <= 0: return false
	for track in _tracks.values():
		if track.request != id: continue
		# Focus, visibility or navigation may have changed since this request was sent.
		var now := Time.get_ticks_msec()
		_plan_at = 0
		tick(now)
		if track.request == id:
			track.receive(_owner.get_ref(), _stills, _listings, JSON.parse_string(payload), now)
			if track.finished: _plan_at = 0
		return true
	return false
