extends RefCounted

const I18n := preload("res://scripts/i18n.gd")
const Sites := preload("res://scripts/web_video_sites.gd")
const BASE := 985000
const SITE_BASE := BASE + 100
const PAGE_SIZE := 9
var owner_ref: WeakRef
var panel: RefCounted:
	get: return owner_ref.get_ref()
var expanded := true # Featured sites are the main entry; most people never open a folded list.
var site_page := 0
var site_language := ""

func visible_sites() -> Array[int]:
	if site_language != I18n.language:
		site_page = 0; site_language = I18n.language
	var order := Sites.ordered_indexes(I18n.language)
	site_page = clampi(site_page, 0, maxi(0, ceili(order.size() / float(PAGE_SIZE)) - 1))
	return order.slice(site_page * PAGE_SIZE, (site_page + 1) * PAGE_SIZE)

func _init(owner: RefCounted) -> void: owner_ref = weakref(owner)
func active() -> bool:
	return panel.active() and panel.menu.web_browser.supported() and not panel.menu.web_browser.opened and panel.menu.web_browser.list_mode.is_empty()

func _caption(text: String, point: Vector2, size: int, color: Color, parent: Node = null) -> Label3D:
	var menu: Node = panel.menu
	var label: Label3D = menu._label(text, Vector3(point.x, point.y, 0.009), size, parent if parent else menu)
	label.modulate = color
	return label

func backdrop() -> Array:
	return [Vector2(1.46, 1.24 if expanded else 0.64), Vector2(0.13, -0.06 if expanded else 0.24)]
## Shared footer row (music, collapse) just below this home's own panel.
func footer_y() -> float:
	var frame := backdrop()
	# Same relation as the default footer: 0.025 below the device-status anchor (bottom - 0.085).
	return frame[1].y - frame[0].y * 0.5 - 0.11

func draw() -> bool:
	if not active(): return false
	var menu: Node = panel.menu
	var frame := backdrop()
	menu._set_backdrop(frame[0], frame[1])
	_caption(I18n.t("Browser"), Vector2(-0.49, 0.435), 29, Color("f0f5fa")).horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	menu._icon("globe", Vector3(0.73, 0.435, 0.009), 0.054, Color("77bba9"))
	menu._button(BASE, "", Vector2(0.055, 0.27), Vector2(1.13, 0.115))
	var field: Dictionary = menu._buttons.back()
	field.base_color = Color("172535")
	field.node.material_override.set_shader_parameter("surface_color", field.base_color)
	menu._icon("search", Vector3(-0.505, 0, 0.006), 0.04, Color("8fa4b8"), field.node)
	var text: String = panel.address if not panel.address.is_empty() else I18n.t("Website or video link")
	var input := _caption(menu._fit_title(text, "", 0.95, 21), Vector2(-0.46, 0), 21, Color("dce9f2") if not panel.address.is_empty() else Color("91a4b7"), field.node)
	input.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	menu._button(BASE + 1, "", Vector2(0.725, 0.27), Vector2(0.12, 0.115), not panel.address.strip_edges().is_empty(), "next", true)
	menu._tips[BASE + 1] = I18n.t("Open")
	var destination: Dictionary = menu.web_browser.data
	var url: String = str(destination.get("url", "about:blank"))
	var title: String = str(destination.get("title", "")).strip_edges()
	# One compact row: resume on the left, bookmarks/history as icons aligned with Open.
	menu._button(BASE + 2, "", Vector2(-0.01, 0.135), Vector2(1.0, 0.10))
	var resume: Node3D = menu._buttons.back().node
	menu._icon("globe", Vector3(-0.455, 0, 0.006), 0.036, menu.MUTED, resume)
	var page_name: String = title if not title.is_empty() else (I18n.t("New tab") if url in ["", "about:blank"] else menu.web_browser.library.display_address(url))
	_caption(menu._fit_title(I18n.t("Continue browsing") + " · " + page_name, "", 0.86, 19), Vector2(-0.41, 0), 19, Color("d9e1eb"), resume).horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	menu._tips[BASE + 2] = url if not url.is_empty() else I18n.t("New tab")
	menu._button(BASE + 3, "", Vector2(0.585, 0.135), Vector2(0.12, 0.10), true, "bookmark")
	menu._tips[BASE + 3] = I18n.t("Bookmarks")
	menu._button(BASE + 4, "", Vector2(0.725, 0.135), Vector2(0.12, 0.10), true, "history")
	menu._tips[BASE + 4] = I18n.t("Browsing history")
	var pages := ceili(Sites.FEATURED.size() / float(PAGE_SIZE))
	var order := visible_sites()
	var paged := expanded and pages > 1
	menu._text_button(BASE + 5, "", Vector2(-0.10 if paged else 0.13, 0.0), Vector2(0.83 if paged else 1.29, 0.095))
	var fold: Node3D = menu._buttons.back().node
	var fold_caption := _caption(I18n.t("Featured sites"), Vector2(-0.38 if paged else -0.61, 0), 21, Color("c7d5e3"), fold)
	fold_caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	menu._buttons.back().hover_labels.append(fold_caption)
	menu._buttons.back().select_arrow = menu._icon("chevron_up" if expanded else "chevron_down", Vector3(0.36 if paged else 0.60, 0, 0.009), 0.032, Color("8da5b7"), fold)
	if paged:
		menu._button(BASE + 6, "", Vector2(0.43, 0.0), Vector2(0.075, 0.07), site_page > 0, "previous")
		_caption("%d / %d" % [site_page + 1, pages], Vector2(0.585, 0.0), 16, Color("91a4b7"))
		menu._button(BASE + 7, "", Vector2(0.74, 0.0), Vector2(0.075, 0.07), site_page + 1 < pages, "next")
	if expanded:
		for slot in order.size():
			var index: int = order[slot]
			var site: Dictionary = Sites.FEATURED[index]
			var center := Vector2(-0.30 + (slot % 3) * 0.435, -0.14 - floori(slot / 3.0) * 0.20)
			menu._button(SITE_BASE + index, "", center, Vector2(0.40, 0.18))
			var card: Dictionary = menu._buttons.back()
			card.base_color = Color("15212e"); card.hover_color = Color("253e4a")
			card.node.material_override.set_shader_parameter("surface_color", card.base_color)
			card.node.material_override.set_shader_parameter("corner_radius", 0.018)
			menu._icon(str(site.icon), Vector3(0, 0.028, 0.009), 0.073, site.color, card.node)
			_caption(menu._fit_title(I18n.t(site.name), "", 0.35, 18), Vector2(0, -0.055), 18, Color("dbe6ef"), card.node)
	menu._update_highlights()
	return true

func action(target: int) -> bool:
	if not active(): return false
	var menu: Node = panel.menu
	if target >= SITE_BASE and target < SITE_BASE + Sites.FEATURED.size():
		if expanded and visible_sites().has(target - SITE_BASE): menu.web_browser.open(Sites.FEATURED[target - SITE_BASE].url)
		return true
	if target < BASE or target > BASE + 7: return false
	match target - BASE:
		0: menu.system_text_input.begin("web_home", panel.address, 4096, _edited, _open)
		1: _open(panel.address)
		2: menu.web_browser.open()
		3: menu.web_browser.choose({"web_browser": "bookmarks"})
		4: menu.web_browser.choose({"web_browser": "history"})
		5: expanded = not expanded; menu.scroll = 0.0; menu.refresh()
		6, 7:
			if expanded:
				site_page += -1 if target == BASE + 6 else 1
				visible_sites(); menu.refresh()
	return true

func _edited(value: String) -> void:
	panel.address = value; panel.menu.refresh()
func _open(value: String) -> void:
	panel.address = panel.menu.system_text_input.finish("web_home", value).strip_edges()
	if not panel.address.is_empty(): panel.menu.web_browser.open(panel.address)
