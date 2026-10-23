extends RefCounted
## Blu-ray title list from the control bar's upper-right button. It opens by
## itself once per disc; the main title keeps playing until a row is chosen.
const BUTTON := 998100
const CLOSE := 998101
const UP := 998102
const DOWN := 998103
const ROW := 998200
const MENU_ROW := 998199
const ROWS := 5
const PITCH := 0.075
const WIDTH := 0.68
const RIGHT := 0.58
const I18n := preload("res://scripts/i18n.gd")
const DiscTitles := preload("res://scripts/disc_titles.gd")
var opened := false
var offset := 0
var _menu: WeakRef
## Discs whose list opened by itself in this run: a reopen never covers the picture again.
static var _shown := {}
var _disc := ""
var _rows := {}

func _init(menu: Node3D) -> void: _menu = weakref(menu)

static func titles(state: Dictionary) -> Array:
	return state.get("disc_titles", []) if state.get("has_video", false) else []

func available() -> bool:
	var menu: Node3D = _menu.get_ref()
	return menu != null and (titles(menu._state).size() > 1 or menu._state.get("disc_menu_available", false) \
		or menu._state.get("disc_menu_unsupported", false))

func reset() -> void:
	opened = false; offset = 0

## Floating action above the bar's right end. The list opens by itself only for
## a disc's first viewing (no playback record), once per run.
func draw_button(centre: Vector2) -> void:
	var menu: Node3D = _menu.get_ref()
	if not available():
		opened = false
		return
	var disc := str(menu._state.get("source_uri", ""))
	if disc != _disc:
		_disc = disc; offset = 0
		if menu._state.get("disc_first_view", false) and not _shown.has(disc) and menu._capture_popup_allowed():
			opened = true
		_shown[disc] = true
	menu._round(BUTTON, "disc", centre, 0.08, true, opened, I18n.t("Disc titles"))

func draw() -> void:
	var menu: Node3D = _menu.get_ref()
	var rows := titles(menu._state)
	var disc_menu: bool = menu._state.get("disc_menu_available", false)
	# A Java menu stays named in its place, quietly marked as not supported.
	var java_menu: bool = not disc_menu and menu._state.get("disc_menu_unsupported", false)
	offset = clampi(offset, 0, maxi(0, rows.size() - ROWS))
	var scrolling := rows.size() > ROWS
	var height := 0.10 + (mini(ROWS, rows.size()) + int(disc_menu or java_menu)) * PITCH + (0.06 if scrolling else 0.0)
	var bottom: float = menu.POPUP_BOTTOM
	var top := bottom + height
	var centre_x := RIGHT - WIDTH / 2
	var panel: MeshInstance3D = menu._quad(Vector2(WIDTH, height), Vector3(centre_x, bottom + height / 2, 0.001), Color(menu.PANEL, 0.96), 10)
	panel.material_override.set_shader_parameter("corner_radius", 0.025)
	menu.add_child(panel); menu._decorations.append(panel); menu._block_rays(panel, Vector2(WIDTH, height))
	menu._icon("disc", Vector3(centre_x - WIDTH / 2 + 0.05, top - 0.05, 0.004), 0.036, menu.MUTED)
	menu._glyph(CLOSE, "close", Vector2(centre_x + WIDTH / 2 - 0.045, top - 0.05), 0.055, true, I18n.t("Close"))
	_rows.clear()
	var main := int(menu._state.get("disc_main", -1))
	var main_index := rows.find_custom(func(row): return int(row.playlist) == main)
	var playing := int(menu._state.get("disc_playlist", -1))
	var y := top - 0.115
	if disc_menu:
		# The disc's own full-screen menu leads the list; checked while it plays.
		var in_menu: bool = menu._state.get("disc_menu_session", false)
		menu._button(MENU_ROW, "", Vector2(centre_x, y), Vector2(WIDTH - 0.06, 0.065))
		var entry: Dictionary = menu._buttons.back()
		var caption: Label3D = menu._label(I18n.t("Disc menu"), Vector3(-(WIDTH - 0.06) / 2 + 0.02, 0, 0.004), menu.TEXT_BODY, entry.node)
		caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		menu._icon("menu", Vector3((WIDTH - 0.06) / 2 - 0.10, 0, 0.004), 0.03, menu.MUTED, entry.node)
		if in_menu:
			entry.base_color = menu.SELECTED
			menu._icon("check", Vector3((WIDTH - 0.06) / 2 - 0.03, 0, 0.004), 0.029, menu.ACCENT, entry.node)
		y -= PITCH
	elif java_menu:
		menu._button(MENU_ROW, "", Vector2(centre_x, y), Vector2(WIDTH - 0.06, 0.065), false)
		var entry: Dictionary = menu._buttons.back()
		entry.base_color = Color(menu.TILE, 0.45)
		var caption: Label3D = menu._label(I18n.t("BD-J menu"), Vector3(-(WIDTH - 0.06) / 2 + 0.02, 0, 0.004), menu.TEXT_BODY, entry.node)
		caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		caption.modulate = menu.MUTED
		var note: Label3D = menu._label(I18n.t("Not supported yet"), Vector3((WIDTH - 0.06) / 2 - 0.03, 0, 0.004), menu.TEXT_AUX, entry.node)
		note.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		note.modulate = menu.MUTED
		y -= PITCH
	for index in range(offset, mini(rows.size(), offset + ROWS)):
		var row: Dictionary = rows[index]
		var target := ROW + index
		var playlist := int(row.playlist)
		_rows[target] = playlist
		menu._button(target, "", Vector2(centre_x, y), Vector2(WIDTH - 0.06, 0.065))
		var button: Dictionary = menu._buttons.back()
		var name := I18n.t("Main title") if playlist == main else I18n.t("Extra %d") % (index + (0 if main_index >= 0 and main_index < index else 1))
		if row.get("stereo", false): name += "  3D"
		var caption: Label3D = menu._label(name, Vector3(-(WIDTH - 0.06) / 2 + 0.02, 0, 0.004), menu.TEXT_BODY, button.node)
		caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		var time: Label3D = menu._label(DiscTitles.duration_text(int(row.get("duration_ms", 0))), Vector3((WIDTH - 0.06) / 2 - 0.07, 0, 0.004), menu.TEXT_AUX, button.node)
		time.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		time.modulate = menu.MUTED
		if playlist == playing and not menu._state.get("disc_menu_session", false):
			button.base_color = menu.SELECTED
			menu._icon("check", Vector3((WIDTH - 0.06) / 2 - 0.03, 0, 0.004), 0.029, menu.ACCENT, button.node)
		y -= PITCH
	if scrolling:
		menu._button(UP, "↑", Vector2(centre_x - 0.07, y + 0.015), Vector2(0.10, 0.05), offset > 0)
		menu._button(DOWN, "↓", Vector2(centre_x + 0.07, y + 0.015), Vector2(0.10, 0.05), offset + ROWS < rows.size())

func has_row(target: int) -> bool:
	return opened and _rows.has(target)

func scroll(rows: int) -> void:
	var menu: Node3D = _menu.get_ref()
	var next := clampi(offset + rows, 0, maxi(0, titles(menu._state).size() - ROWS))
	if next != offset: offset = next; menu.refresh()

## True when the target belonged to the button or the list.
func activate(target: int) -> bool:
	var menu: Node3D = _menu.get_ref()
	if target == BUTTON:
		opened = not opened
		menu.refresh()
		return true
	if not opened: return false
	if target == CLOSE: opened = false; menu.refresh(); return true
	if target == MENU_ROW:
		if not menu._state.get("disc_menu_session", false): menu.setting_requested.emit("disc_menu", true)
		opened = false
		menu.refresh()
		return true
	if target in [UP, DOWN]: scroll(-ROWS if target == UP else ROWS); return true
	if _rows.has(target):
		if int(_rows[target]) == int(menu._state.get("disc_playlist", -1)) and not menu._state.get("disc_menu_session", false): return true
		menu.setting_requested.emit("disc_title", int(_rows[target]))
		opened = false
		menu.refresh()
		return true
	return false
