extends RefCounted
## Shared path controls for the full and compact media library.

const ROOT := 987200
const TOGGLE := 987201
const BACKGROUND := 987202
const EARLIER := 987203
const LATER := 987204
const ROW := 987210
const INLINE := 987220
const MIN_SEGMENTS := 3 # The source root is level zero.
const VISIBLE_ROWS := 6
const ROW_HEIGHT := 0.066
const OPEN_MS := 250
const CLOSE_MS := 450
const TOGGLE_WIDTH := 0.082
const SCROLL_SPEED := 9.0
const LEVEL_GUTTER := 0.063

var menu
var present := false
var open := false
var _crumbs: Array = []
var _scope := ""
var _anchor := Vector2.ZERO
var _offset := 0
var _scroll := 0.0
var _hover_since := -1
var _leave_at := -1
var _wait_for_leave := false

func _init(owner) -> void:
	menu = owner

func available(crumbs: Array) -> bool:
	return crumbs.size() >= MIN_SEGMENTS and (menu.archives.browsing or (not menu.cloud_search.active and menu.browser_content()))

func draw_header(crumbs: Array, left: float, y: float) -> float:
	var scope: String = menu._cloud_position_key() if menu.section == menu.Section.CLOUD and not menu.archives.browsing else menu._folder_key()
	var anchor := Vector2(left, y)
	if _scope != scope or _crumbs != crumbs or _anchor != anchor: reset()
	present = true
	_scope = scope
	_crumbs = crumbs
	_anchor = anchor
	menu._button(TOGGLE, "", Vector2(left + TOGGLE_WIDTH * 0.5, y), Vector2(TOGGLE_WIDTH, 0.065), true, "folder_tree", open)
	if not open: menu._tips[TOGGLE] = menu.I18n.t("Folders")
	return left + TOGGLE_WIDTH

func reset() -> void:
	open = false
	_offset = 0
	_scroll = 0.0
	_hover_since = -1
	_leave_at = -1
	_wait_for_leave = false

func contains(target: int) -> bool:
	return target in [ROOT, TOGGLE, BACKGROUND, EARLIER, LATER] or (target >= ROW and target < ROW + VISIBLE_ROWS)

func tick(now: int) -> void:
	if not present or not menu.is_visible_in_tree():
		reset()
		return
	var over_entry := false
	var over_popup := false
	for target: int in menu._hover.values():
		if target == TOGGLE: over_entry = true
		elif contains(target): over_popup = true
	if not over_entry and not menu._hover.is_empty():
		_hover_since = -1
		_wait_for_leave = false
	elif over_entry and _hover_since < 0:
		_hover_since = now
	if open:
		if over_entry or over_popup: _leave_at = now + CLOSE_MS
		elif now >= _leave_at: close()
	elif not _wait_for_leave and over_entry and now - _hover_since >= OPEN_MS and not menu.has_pointer_capture():
		_show(now)

func _show(now: int) -> void:
	open = true
	# Keep the root available and start the list at the current end of the path.
	_offset = maxi(0, _crumbs.size() - 1 - VISIBLE_ROWS)
	_scroll = float(_offset)
	_leave_at = now + CLOSE_MS
	menu._fling = 0.0
	menu._draw()

func close(redraw: bool = true) -> void:
	reset()
	_wait_for_leave = true
	if redraw: menu._draw()

func scroll(y: float, delta: float) -> void:
	if not is_finite(y) or absf(y) < menu.STICK_DEADZONE: return
	_set_offset(_scroll - y * delta * SCROLL_SPEED)

func _set_offset(value: float) -> void:
	_scroll = clampf(value, 0.0, maxf(0.0, _crumbs.size() - 1 - VISIBLE_ROWS))
	var offset := roundi(_scroll)
	if offset != _offset:
		_offset = offset
		_leave_at = Time.get_ticks_msec() + CLOSE_MS
		menu._draw()

func action(target: int) -> bool:
	if not present or not contains(target): return false
	if target == TOGGLE:
		if open: close()
		else: _show(Time.get_ticks_msec())
	elif open:
		if target == EARLIER or target == LATER:
			_set_offset(float(_offset + (-1 if target == EARLIER else 1)))
		elif target == ROOT or (target >= ROW and target < ROW + VISIBLE_ROWS):
			var level := 0 if target == ROOT else 1 + _offset + target - ROW
			if level < _crumbs.size() - 1:
				close(false)
				menu._go_to(level)
	return true

func draw_popup() -> void:
	if not present or not open: return
	var count := mini(_crumbs.size() - 1, VISIBLE_ROWS)
	var scrolling := _crumbs.size() - 1 > VISIBLE_ROWS
	var width := 0.53 if menu.compact else 0.61
	var hidden_gap := 0.032 if _offset > 0 else 0.0
	var height := 0.024 + (count + 1) * ROW_HEIGHT + hidden_gap
	var left := _anchor.x
	var top := _anchor.y - 0.0325
	var panel: MeshInstance3D = menu._quad(Vector2(width, height), Vector3(left + width * 0.5, top - height * 0.5, 0.018), Color(menu.PANEL, 1.0), 24)
	panel.material_override.set_shader_parameter("corner_radius", 0.016)
	menu.add_child(panel)
	menu._decorations.append(panel)
	menu._block_rays(panel, Vector2(width, height), 0.016)
	menu._ray_blockers.back().target = BACKGROUND
	var row_width := width - LEVEL_GUTTER - (0.064 if scrolling else 0.012)
	var spine_x := -width * 0.5 + 0.031
	var rows_x := -width * 0.5 + LEVEL_GUTTER
	var root_y := height * 0.5 - 0.012 - ROW_HEIGHT * 0.5
	var first_y := root_y - ROW_HEIGHT - hidden_gap
	var last_y := first_y - (count - 1) * ROW_HEIGHT
	var ink: Color = menu.MUTED.darkened(0.25)
	if hidden_gap > 0.0:
		var gap_y := (root_y + first_y) * 0.5
		_draw_track(panel, spine_x, root_y, gap_y + 0.019, ink)
		_draw_track(panel, spine_x, gap_y - 0.019, last_y, ink)
		for i in [-1, 0, 1]:
			_mark(panel, Vector2(spine_x, gap_y + i * 0.011), Vector2.ONE * 0.005, ink, 0.0025)
	else:
		_draw_track(panel, spine_x, root_y, last_y, ink)
	_draw_level(panel, ROOT, 0, Vector2(rows_x, root_y), row_width, spine_x, ink)
	for index in count:
		var level := 1 + _offset + index
		_draw_level(panel, ROW + index, level, Vector2(rows_x, first_y - index * ROW_HEIGHT), row_width, spine_x, ink)
	if scrolling:
		var x := width * 0.5 - 0.033
		_popup_button(EARLIER, Vector2(x, first_y), Vector2(0.048, 0.055), panel, "chevron_up", _offset > 0)
		_popup_button(LATER, Vector2(x, last_y), Vector2(0.048, 0.055), panel, "chevron_down", _offset + count < _crumbs.size() - 1)

func _draw_track(panel: Node3D, x: float, top: float, bottom: float, ink: Color) -> void:
	_mark(panel, Vector2(x, (top + bottom) * 0.5), Vector2(0.003, top - bottom), ink)

func _draw_level(panel: Node3D, target: int, level: int, left: Vector2, width: float, spine_x: float, ink: Color) -> void:
	var current := level == _crumbs.size() - 1
	var marker_size := 0.017 if level == 0 or current else 0.011
	var branch_width := left.x - spine_x
	_mark(panel, Vector2(spine_x + branch_width * 0.5, left.y), Vector2(branch_width, 0.003), ink)
	_mark(panel, Vector2(spine_x, left.y), Vector2.ONE * marker_size, menu.ACCENT if current else menu.MUTED,
		0.004 if level == 0 else marker_size * 0.5)
	_popup_button(target, left + Vector2(width * 0.5, 0.0), Vector2(width, ROW_HEIGHT - 0.005), panel, "", not current)
	var button: Dictionary = menu._buttons.back()
	if current:
		button.hover_disabled = true # Show the full name on hover without making this row actionable.
	var name := str(_crumbs[level])
	var text: String = menu._fit_title(name, "", width - 0.036, 19)
	var label: Label3D = menu._label(text, Vector3(-width * 0.5 + 0.018, 0.0, 0.005), 19, button.node)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	label.render_priority = 27
	if current: label.modulate = menu.ACCENT
	if text != name or _crumbs.count(name) > 1:
		menu._tips[target] = " › ".join(_crumbs.slice(0, level + 1))

func _mark(panel: Node3D, centre: Vector2, size: Vector2, ink: Color, radius: float = 0.0) -> void:
	var node: MeshInstance3D = menu._quad(size, Vector3(centre.x, centre.y, 0.003 if radius > 0.0 else 0.002), ink, 27 if radius > 0.0 else 26)
	node.material_override.set_shader_parameter("corner_radius", radius)
	panel.add_child(node)

func _popup_button(target: int, centre: Vector2, size: Vector2, panel: Node3D, icon: String = "", enabled: bool = true) -> void:
	menu._button(target, "", centre, size, enabled, icon, false, panel)
	var node: MeshInstance3D = menu._buttons.back().node
	node.material_override.render_priority = 25
	if not icon.is_empty(): node.get_child(1).material_override.render_priority = 26
