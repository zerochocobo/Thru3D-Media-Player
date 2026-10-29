extends RefCounted
## The browser's existing site catalogue and bookmarks, rendered inside each new tab.
const I18n := preload("res://scripts/i18n.gd")
const Sites := preload("res://scripts/web_video_sites.gd")
const BASE := 986400
const PAGE_SIZE := 6
var owner: WeakRef
var pages := {}
var links := {}
func _init(browser: RefCounted) -> void: owner = weakref(browser)
func active(id: int) -> bool:
	var browser: RefCounted = owner.get_ref()
	return browser.active() and str(browser.window_state(id).get("url", "")) in ["", "about:blank"]
func draw(host: Node) -> void:
	var browser: RefCounted = owner.get_ref()
	var bounds: Rect2 = browser.RECT if host.on_screen() else host.page_rect()
	var state: Dictionary = pages.get(host.window_id, {"sites": 0, "bookmarks": 0})
	pages[host.window_id] = state; links[host.window_id] = {}
	var sites: Array = []
	for index in Sites.ordered_indexes(I18n.language):
		var item: Dictionary = Sites.FEATURED[index]
		sites.append({"title": I18n.t(item.name), "url": item.url, "icon": item.icon, "color": item.color})
	var bookmarks: Array = browser.saved.get("bookmarks", [])
	for section in 2:
		var key := "sites" if section == 0 else "bookmarks"
		var entries: Array = sites if section == 0 else bookmarks
		var count := maxi(1, ceili(entries.size() / float(PAGE_SIZE)))
		state[key] = clampi(int(state[key]), 0, count - 1)
		var top: float = bounds.end.y - bounds.size.y * (0.08 + section * 0.49)
		var heading: Label3D = host._label(I18n.t("Featured sites" if section == 0 else "Bookmarks"), Vector3(bounds.position.x + 0.05, top, 0.008), 24)
		heading.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		if count > 1:
			for direction in 2:
				host._button(BASE + section * 2 + direction, "", Vector2(bounds.end.x - 0.25 + direction * 0.18, top), Vector2(0.07, 0.065), state[key] > 0 if direction == 0 else state[key] + 1 < count, "previous" if direction == 0 else "next")
			host._label("%d/%d" % [state[key] + 1, count], Vector3(bounds.end.x - 0.16, top, 0.008), 16).modulate = host.MUTED
		if entries.is_empty():
			host._label(I18n.t("No bookmarks"), Vector3(bounds.get_center().x, top - bounds.size.y * 0.2, 0.008), 22).modulate = host.MUTED
		var visible_entries := entries.slice(state[key] * PAGE_SIZE, (state[key] + 1) * PAGE_SIZE)
		var width := (bounds.size.x - 0.12) / 3.0
		for slot in visible_entries.size():
			var item: Dictionary = visible_entries[slot]
			var title := str(item.get("title", ""))
			if title.is_empty(): title = browser.library.display_address(str(item.url))
			var target := BASE + 10 + section * PAGE_SIZE + slot
			var point := Vector2(bounds.position.x + 0.04 + width * (0.5 + slot % 3) + 0.02 * (slot % 3), top - bounds.size.y * (0.16 + 0.16 * (slot / 3)))
			host._button(target, "", point, Vector2(width, minf(0.105, bounds.size.y * 0.14)))
			var card: Node3D = host._buttons.back().node
			host._icon(str(item.get("icon", "bookmark")), Vector3(-width * 0.5 + 0.035, 0, 0.006), 0.038, item.get("color", host.ACCENT), card)
			var label: Label3D = host._label(host._fit_title(title, "", width - 0.085, 20), Vector3(-width * 0.5 + 0.065, 0, 0.006), 20, card)
			label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
			host._tips[target] = str(item.url)
			links[host.window_id][target] = str(item.url)
func action(target: int) -> bool:
	if target < BASE or target >= BASE + 22: return false
	var browser: RefCounted = owner.get_ref()
	var id: int = browser.focused_window
	if not active(id) or browser.tabs_open: return true
	if target < BASE + 4:
		var state: Dictionary = pages.get(id, {"sites": 0, "bookmarks": 0})
		var key := "sites" if target < BASE + 2 else "bookmarks"
		state[key] += -1 if (target - BASE) % 2 == 0 else 1
		pages[id] = state; browser.refresh_windows()
	elif links.get(id, {}).has(target):
		browser._navigate(str(links[id][target]))
	return true
