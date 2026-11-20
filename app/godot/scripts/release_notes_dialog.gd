extends RefCounted

const History := preload("res://scripts/version_history.gd")
const I18n := preload("res://scripts/i18n.gd")
const CLOSE := 96700
const LIST_UP := 96701
const LIST_DOWN := 96702
const BODY_UP := 96703
const BODY_DOWN := 96704
const VERSION_BASE := 96800
const LIST_SIZE := 8
const BODY_SIZE := 17
const DIVIDER := -0.29
const LINE_HEIGHT := 0.039

var opened := false
var capture := {}
var data_path := History.DATA
var _catalog: Array = []
var _projection_key := []
var entries: Array = []
var unread_versions := {}
var installed := ""
var missing_current := false
var selected := 0
var list_offset := 0
var body_offset := 0
var lines: Array[Dictionary] = []
var _body_focused := true
var _stick_fraction := 0.0

func prepare(version: String, language: String, context: Dictionary) -> bool:
	installed = version
	var key := [data_path, version, language, context]
	if key == _projection_key: return true
	entries.clear()
	missing_current = true
	if _projection_key.is_empty() or _projection_key[0] != data_path:
		_projection_key.clear()
		_catalog = []
		var file := FileAccess.open(data_path, FileAccess.READ)
		if file == null: return false
		var parser := JSON.new()
		if parser.parse(file.get_as_text()) != OK or not parser.data is Dictionary: return false
		if parser.data.get("schema") != 1 or not parser.data.get("entries") is Array or parser.data.entries.is_empty(): return false
		for row in parser.data.entries:
			if not row is Dictionary or not History.valid_version(str(row.get("version", ""))) or not row.get("date") is String or not row.get("title") is Dictionary: return false
		_catalog = parser.data.entries
	entries = History.visible_entries(_catalog, version, language, context)
	missing_current = not _catalog.any(func(row): return row.version == version and not History.localized_notes(row, History.locale(language)).is_empty())
	_projection_key = key
	return true

func newest_unread(lower: String) -> String:
	if not lower.is_empty() and not entries.is_empty() and History.unread(entries[0].version, lower):
		return entries[0].version
	return ""

func open(menu, lower: String) -> void:
	opened = true
	unread_versions.clear()
	for row in entries:
		if History.unread(row.version, lower): unread_versions[row.version] = true
	# The first applicable version is the newest and never exceeds the installed version.
	selected = 0
	list_offset = 0
	_body_focused = true
	_stick_fraction = 0.0
	_select(menu, 0)

func close(menu) -> void:
	opened = false
	capture.clear()
	unread_versions.clear()
	menu.refresh()

func _select(menu, index: int) -> void:
	selected = index
	body_offset = 0
	lines.clear()
	if not entries.is_empty():
		var row: Dictionary = entries[index]
		_wrap(menu, row.title, true)
		for note in row.notes: _wrap(menu, note, false)
	menu._draw()
	if not lines.is_empty() and unread_versions.has(entries[selected].version) and not menu.unread_from.is_empty():
		menu.unread_from = ""
		menu.version_history_opened.emit()

func _wrap(menu, value: String, heading: bool) -> void:
	var paragraph := TextParagraph.new()
	var size: int = menu.TEXT_TITLE if heading else menu.TEXT_BODY
	paragraph.width = 0.95 / menu.TEXT_PIXEL_SIZE
	paragraph.break_flags = TextServer.BREAK_MANDATORY | TextServer.BREAK_WORD_BOUND | TextServer.BREAK_ADAPTIVE
	paragraph.add_string(value, menu.ui_font(), size * menu.TEXT_RASTER_SCALE, I18n.language)
	for i in paragraph.get_line_count():
		var span := paragraph.get_line_range(i)
		lines.append({"text": value.substr(span.x, span.y - span.x).strip_edges(),
			"heading": heading, "bullet": not heading and i == 0})

func _label(menu, text: String, x: float, y: float, size: int) -> Label3D:
	var label: Label3D = menu._label(text, Vector3(x, y, 0.008), size)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	return label

func draw(menu) -> void:
	menu._set_backdrop(Vector2(1.53, 1.04))
	if is_instance_valid(menu.device_status): menu.device_status.visible = false
	_label(menu, I18n.t("Version history"), -0.71, 0.445, menu.TEXT_PAGE_TITLE)
	menu._button(CLOSE, "", Vector2(0.68, 0.445), Vector2(0.083, 0.066), true, "close")
	menu._decoration(Vector2(0.002, 0.83), Vector2(DIVIDER, -0.035), menu.MUTED)
	for i in mini(LIST_SIZE, entries.size() - list_offset):
		var index := list_offset + i
		var row: Dictionary = entries[index]
		var y := 0.322 - i * 0.092
		menu._button(VERSION_BASE + index, "", Vector2(-0.528, y), Vector2(0.395, 0.081), true, "", index == selected)
		var ink: Color = menu.UiTheme.color("primary_ink" if index == selected else "text")
		_label(menu, row.version, -0.665, y + 0.015, menu.TEXT_BODY).modulate = ink
		_label(menu, row.date, -0.665, y - 0.016, menu.TEXT_AUX).modulate = ink
		if unread_versions.has(row.version):
			_label(menu, "•", -0.703, y + 0.013, menu.TEXT_TITLE).modulate = ink
	if missing_current:
		_label(menu, installed + " · " + I18n.t("No notes for this version"), -0.26, 0.445, menu.TEXT_AUX)
	if entries.is_empty():
		if not missing_current:
			_label(menu, I18n.t("No applicable updates"), -0.246, 0.326, menu.TEXT_BODY)
		return
	var row: Dictionary = entries[selected]
	_label(menu, row.version + "   ·   " + row.date, -0.246, 0.344, menu.TEXT_TITLE)
	for i in mini(BODY_SIZE, lines.size() - body_offset):
		var line := lines[body_offset + i]
		var y := 0.279 - i * LINE_HEIGHT
		if line.bullet: _label(menu, "•", -0.246, y, menu.TEXT_BODY)
		_label(menu, line.text, -0.246 if line.heading else -0.218, y, menu.TEXT_TITLE if line.heading else menu.TEXT_BODY)
	_pager(menu, -0.528, list_offset, LIST_SIZE, entries.size(), LIST_UP, LIST_DOWN)
	_pager(menu, 0.23, body_offset, BODY_SIZE, lines.size(), BODY_UP, BODY_DOWN)

func _pager(menu, x: float, offset: int, count: int, total: int, up: int, down: int) -> void:
	if total <= count: return
	menu._button(up, "", Vector2(x - 0.139, -0.441), Vector2(0.081, 0.061), offset > 0, "chevron_up")
	menu._label("%d–%d / %d" % [offset + 1, mini(total, offset + count), total], Vector3(x, -0.441, 0.008), menu.TEXT_AUX)
	menu._button(down, "", Vector2(x + 0.139, -0.441), Vector2(0.081, 0.061), offset + count < total, "chevron_down")

func scroll_to(menu, body: bool, value: int) -> void:
	var old := body_offset if body else list_offset
	var next := clampi(value, 0, maxi(0, lines.size() - BODY_SIZE if body else entries.size() - LIST_SIZE))
	if next == old: return
	if body: body_offset = next
	else: list_offset = next
	menu._draw()

func action(menu, target: int) -> void:
	match target:
		CLOSE: close(menu)
		LIST_UP: scroll_to(menu, false, list_offset - LIST_SIZE)
		LIST_DOWN: scroll_to(menu, false, list_offset + LIST_SIZE)
		BODY_UP: scroll_to(menu, true, body_offset - BODY_SIZE)
		BODY_DOWN: scroll_to(menu, true, body_offset + BODY_SIZE)
		_:
			var index := target - VERSION_BASE
			if index >= 0 and index < entries.size(): _select(menu, index)

func press(menu, hand: String, point: Variant, hit: Dictionary) -> bool:
	if not capture.is_empty(): return true
	if point == null or absf(point.x) > 0.765 or absf(point.y) > 0.52: return false
	_body_focused = point.x > DIVIDER
	capture = {"hand": hand, "target": hit.get("target", -1) if hit.get("enabled", false) else -1,
		"start": point.y, "body": _body_focused, "offset": body_offset if _body_focused else list_offset, "moved": false}
	return true

func move(menu, hand: String, point: Variant) -> void:
	if point == null: return
	if capture.is_empty():
		if absf(point.x) < 0.765 and absf(point.y) < 0.52: _body_focused = point.x > DIVIDER
	elif capture.hand == hand:
		var distance := float(point.y) - float(capture.start)
		if absf(distance) > 0.016: capture.moved = true
		if capture.moved:
			scroll_to(menu, capture.body, capture.offset + roundi(distance / (LINE_HEIGHT if capture.body else 0.092)))

func release(menu, hand: String, hit: Dictionary) -> void:
	if capture.get("hand") != hand: return
	var drag := capture
	capture = {}
	if not drag.moved and hit.get("enabled", false) and hit.target == drag.target: action(menu, drag.target)

func stick(menu, axis: float, delta: float) -> void:
	if not capture.is_empty() or not is_finite(axis) or absf(axis) < menu.STICK_DEADZONE:
		_stick_fraction = 0.0
		return
	_stick_fraction -= axis * delta * (16.0 if _body_focused else 10.0)
	var steps := int(_stick_fraction)
	if steps != 0:
		_stick_fraction -= steps
		scroll_to(menu, _body_focused, (body_offset if _body_focused else list_offset) + steps)
