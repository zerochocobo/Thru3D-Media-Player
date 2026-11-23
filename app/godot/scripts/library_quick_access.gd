extends RefCounted
## Narrow side list beside the playback file window: reopen a recent or favorite entry in one
## click. Removal, selection and the other management actions stay in the home page.
const TOGGLE := 13000
const TAB := 13001
const PREVIOUS := 13003
const NEXT := 13004
const ROW := 13010
const PAGE_SIZE := 6
const SIZE := Vector2(0.52, 0.84)
const GAP := 0.02
var menu: Node
var opened := false
var tab := 0
var pages := [0, 0]
var rows: Array[Dictionary] = []

func _init(owner: Node) -> void: menu = owner

## Every playback file window has the switch, in the same corner on every page.
func available() -> bool:
	return menu.compact and not menu.image_picker_mode and not menu.subtitle_picker_mode and not menu.audio_import_mode and not menu.voice_picker_mode

func shown() -> bool: return opened and available()

## Keep the file window where it was: only its own width centres it above the control bar.
func anchor(bounds: Rect2) -> Rect2:
	var right: float = menu.COMPACT_SIZE.x * 0.5
	return Rect2(bounds.position, Vector2(maxf(right - bounds.position.x, 0.01), bounds.size.y))

func _centre() -> Vector2: return Vector2(menu.COMPACT_SIZE.x * 0.5 + GAP + SIZE.x * 0.5, 0)

func _load() -> void:
	var collections: RefCounted = menu.collections
	var home_tab: int = collections.home_tab
	collections.home_tab = tab
	rows = collections.home_rows()
	collections.home_tab = home_tab
	rows.assign(rows.filter(func(row): return row.get("kind", "") not in ["audio", "scene"]))
	pages[tab] = clampi(int(pages[tab]), 0, _page_count() - 1)

func _page_count() -> int: return maxi(1, ceili(float(rows.size()) / PAGE_SIZE))

func draw_toggle(centre: Vector2) -> void:
	if not available(): return
	menu._button(TOGGLE, "", centre, Vector2(0.085, 0.065), true, "side_list", opened)
	menu._tips[TOGGLE] = menu.I18n.t("Recent and favorites")

func draw() -> void:
	if not shown(): return
	_load()
	var centre := _centre()
	var panel: MeshInstance3D = menu._quad(SIZE, Vector3(centre.x, centre.y, 0), menu.PANEL, 10)
	menu.add_child(panel); menu._decorations.append(panel)
	menu._block_rays(panel, SIZE); menu._pointer_panels.append(panel)
	for i in 2:
		menu._button(TAB + i, menu.I18n.t("Recent" if i == 0 else "Favorites"), Vector2(centre.x - 0.1225 + i * 0.245, 0.36), Vector2(0.235, 0.065))
		menu.set_label_size(menu._buttons.back().node.get_child(0), 17)
		menu._lit(tab == i)
	menu._decoration(Vector2(SIZE.x - 0.04, 0.002), Vector2(centre.x, 0.305), menu.UiTheme.color("divider"))
	var first: int = int(pages[tab]) * PAGE_SIZE
	for index in range(first, mini(rows.size(), first + PAGE_SIZE)):
		_draw_row(index - first, rows[index], Vector2(centre.x, 0.24 - (index - first) * 0.098))
	if rows.is_empty():
		var empty: Label3D = menu._label("—", Vector3(centre.x, 0, 0.004), 26)
		empty.modulate = menu.MUTED
	if _page_count() > 1:
		menu._button(PREVIOUS, "", Vector2(centre.x - 0.17, -0.365), Vector2(0.075, 0.065), int(pages[tab]) > 0, "previous")
		menu._label("%d / %d" % [int(pages[tab]) + 1, _page_count()], Vector3(centre.x, -0.365, 0.004), 16)
		menu._button(NEXT, "", Vector2(centre.x + 0.17, -0.365), Vector2(0.075, 0.065), int(pages[tab]) + 1 < _page_count(), "next")

func _draw_row(slot: int, row: Dictionary, centre: Vector2) -> void:
	var width := SIZE.x - 0.04
	menu._button(ROW + slot, "", centre, Vector2(width, 0.088))
	menu._lit(menu._is_current_row(row))
	var button: Dictionary = menu._buttons.back()
	var node: MeshInstance3D = button.node
	var left := -width * 0.5 + 0.075
	var title: Label3D = node.get_child(0)
	title.text = menu._fit_title(str(row.title), "", width - 0.095, 18)
	title.position = Vector3(left, 0.018, 0.004); title.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	menu.set_label_size(title, 18)
	if title.text != str(row.title): menu._tips[ROW + slot] = str(row.title)
	menu._icon(str(row.get("icon", "video")), Vector3(-width * 0.5 + 0.036, 0, 0.005), 0.036, menu.FOLDER if row.get("icon", "") == "folder" else menu.MUTED, node)
	if not row.has("uri"): return
	var info: Dictionary = menu.Presentation.info(row, menu.catalog, true)
	var source: String = menu.Presentation.source_icon(row)
	var inset := 0.032 if not source.is_empty() else 0.0
	if not source.is_empty(): menu._icon(source, Vector3(left + 0.012, -0.022, 0.005), 0.026, menu.UiTheme.color("label"), node)
	var available_width := width - 0.095 - inset
	var text: String = menu._fit_title(str(info.status) if not str(info.status).is_empty() else str(info.subtitle), "", available_width, 14)
	if row.has("source_label") and not str(info.status).is_empty():
		text = menu._fit_title(str(row.source_label), " · " + str(info.status), available_width, 14)
	var detail: Label3D = menu._label(text, Vector3(left + inset, -0.022, 0.004), 14, node)
	detail.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT; detail.modulate = menu.MUTED
	menu._progress_on(node, float(info.ratio), Vector2(0, -0.039), width - 0.03)

func action(id: int) -> bool:
	if id == TOGGLE:
		if not available(): return true
		opened = not opened; menu.setting_changed.emit("library_quick_access", opened); menu.refresh(); return true
	if id < TAB or id >= ROW + PAGE_SIZE or not shown(): return false
	if id == TAB or id == TAB + 1:
		tab = id - TAB; menu.refresh()
	elif id == PREVIOUS or id == NEXT:
		pages[tab] = clampi(int(pages[tab]) + (-1 if id == PREVIOUS else 1), 0, _page_count() - 1); menu.refresh()
	elif id >= ROW:
		var index: int = int(pages[tab]) * PAGE_SIZE + id - ROW
		if index < rows.size(): _open(rows[index].duplicate(true))
	return true

## The same path as choosing the entry on the home page, so resume, queue and context agree.
func _open(row: Dictionary) -> void:
	if row.get("unlock_favorites", false): menu.collections.open_password("unlock"); return
	if menu.archives.browsing: menu.archives.close()
	menu._activate(menu.NAV_BASE + menu.Section.RECENT)
	menu.collections.home_tab = tab
	menu.media_browse_intent = 0; menu.media_filter = 0
	menu.refresh()
	var index: int = menu._recent_all_rows.find_custom(func(item): return str(item.get("uri", "")) == str(row.get("uri", "")))
	if index >= 0: menu._recent_page = index / menu.RECENT_PAGE_SIZE; menu.refresh()
	menu._choose(row)
