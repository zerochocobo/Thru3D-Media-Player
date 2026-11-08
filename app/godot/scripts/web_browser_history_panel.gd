extends RefCounted
## Reuse the saved browser history without leaving or navigating the live document.
const I18n := preload("res://scripts/i18n.gd")
const BASE := 986500
const PAGE_SIZE := 5
var owner: WeakRef
var opened := false
var page := 0
var links := {}
var scroll_step := 0.0

func _init(browser: RefCounted) -> void: owner = weakref(browser)
func active(id: int) -> bool:
	var browser: RefCounted = owner.get_ref()
	return opened and browser.active() and browser.focused_window == id
func reset() -> void:
	opened = false; page = 0; links.clear(); scroll_step = 0.0
func page_count() -> int:
	var browser: RefCounted = owner.get_ref()
	return maxi(1, ceili(browser.saved.get("history", []).size() / float(PAGE_SIZE)))
func turn(amount: int) -> void:
	page = clampi(page + amount, 0, page_count() - 1)
	owner.get_ref().refresh_windows()
func scroll(amount: float, delta: float) -> void:
	if not is_finite(amount) or not is_finite(delta) or absf(amount) <= 0.2:
		scroll_step = 0.0; return
	if scroll_step * amount > 0: scroll_step = 0.0
	scroll_step -= amount * delta * 4.0
	if absf(scroll_step) >= 1.0:
		turn(1 if scroll_step > 0 else -1); scroll_step = 0.0
func draw(host: Node) -> void:
	var browser: RefCounted = owner.get_ref()
	page = clampi(page, 0, page_count() - 1); links.clear()
	host._set_backdrop(Vector2(1.46, 1.12), Vector2(0.13, 0.04))
	var heading: Label3D = host._label(I18n.t("Browsing history"), Vector3(-0.51, 0.48, 0.008), 26)
	heading.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	host._button(browser.HISTORY, "", Vector2(0.73, 0.48), host.TOOL_SIZE, true, "close")
	host._tips[browser.HISTORY] = I18n.t("Back")
	var entries: Array = browser.saved.get("history", [])
	if entries.is_empty():
		host._label(I18n.t("No items"), Vector3(0.13, 0.03, 0.008), 24).modulate = host.MUTED
	for index in mini(PAGE_SIZE, entries.size() - page * PAGE_SIZE):
		var entry: Dictionary = entries[page * PAGE_SIZE + index]
		var url := str(entry.url)
		var title := str(entry.get("title", ""))
		if title.is_empty(): title = browser.library.display_address(url)
		var target := BASE + 10 + index
		host._button(target, "", Vector2(0.13, 0.28 - index * 0.15), Vector2(1.28, 0.12))
		var row: Node3D = host._buttons.back().node
		host._icon("history", Vector3(-0.59, 0, 0.006), 0.045, host.ACCENT, row)
		for line in [[title, 0.022, 22], [browser.library.display_address(url), -0.028, 17]]:
			var label: Label3D = host._label(host._fit_title(line[0], "", 1.10, line[2]), Vector3(-0.54, line[1], 0.006), line[2], row)
			label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
			if line[2] == 17: label.modulate = host.MUTED
		host._tips[target] = url; links[target] = url
	if page_count() > 1:
		host._button(BASE, "", Vector2(-0.10, -0.45), host.TOOL_SIZE, page > 0, "previous")
		host._button(BASE + 1, "", Vector2(0.36, -0.45), host.TOOL_SIZE, page + 1 < page_count(), "next")
		host._label("%d/%d" % [page + 1, page_count()], Vector3(0.13, -0.45, 0.008), 20)
func action(target: int) -> bool:
	if target < BASE or target >= BASE + 10 + PAGE_SIZE: return false
	var browser: RefCounted = owner.get_ref()
	if not active(browser.focused_window): return true
	if target in [BASE, BASE + 1]: turn(-1 if target == BASE else 1)
	elif links.has(target):
		var url: String = links[target]
		reset(); browser._navigate(url)
	return true
