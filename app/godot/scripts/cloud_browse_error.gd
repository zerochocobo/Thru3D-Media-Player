extends RefCounted
## Keep the complete diagnostic apart from the narrow browser status line.
const OPEN := 9160
const BACK := 9161
const Log := preload("res://scripts/diagnostic_log.gd")
var menu: Node
var detail := ""
var code := ""
var opened := false
var saved_scroll := 0.0

func _init(owner: Node) -> void: menu = owner

func clear() -> void:
	if opened: close()
	detail = ""; code = ""

func receive(result: Dictionary) -> void:
	clear()
	var summary := str(result.get("error", "Cloud connection failed"))
	var reason := str(result.get("error_reason", "cloud_unavailable"))
	var original := str(result.get("error_detail", "")).left(4097)
	var names: Array[String] = []
	for entry in menu._cloud_stack: names.append(str(entry.title))
	# Only visible names reach diagnostics; cloud account IDs/mounts are omitted.
	detail = summary
	if not original.is_empty(): detail += "\n" + original
	detail += "\n" + "/".join(names) + "\ncloud.browse · offset=%d · %s" % [int(result.get("offset", 0)), reason]
	var match_code := RegEx.create_from_string("115 code: (-?[0-9]+)").search(original)
	if match_code: code = "115 " + match_code.get_string(1)
	Log.record("cloud_browse_failed", {"reason": reason, "detail": original, "offset": int(result.get("offset", 0))})

func summary_text() -> String:
	if menu.compact and not code.is_empty(): return code
	return menu.I18n.t(menu.status) + (" (" + code + ")" if not code.is_empty() else "")

func close() -> void:
	opened = false; menu.scroll = saved_scroll

func action(target: int) -> bool:
	if target == OPEN and not detail.is_empty():
		saved_scroll = menu.scroll; opened = true
		menu._reset_navigation(); menu.refresh(); return true
	if not opened: return false
	if target == BACK or target == menu.BACK:
		close(); menu.refresh()
	elif target == menu.CLOSE: menu.dismiss()
	return true

func rows() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var width := 0.98 if menu.compact else 1.14
	for original in detail.split("\n"):
		var line := ""
		for c in menu.I18n.t(original):
			if menu.text_width(line + c, 19) > width:
				result.append({"title": line}); line = ""
			line += c
		result.append({"title": line})
	return result

func draw() -> void:
	menu._side.visible = false
	menu._set_backdrop(menu.COMPACT_SIZE if menu.compact else Vector2(1.46, 1.12), Vector2.ZERO if menu.compact else Vector2(0.13, 0))
	var y := 0.36 if menu.compact else 0.46
	menu._button(BACK, "", Vector2(-0.51, y), Vector2(0.075, 0.065), true, "up")
	menu._tips[BACK] = menu.I18n.t("Back")
	menu._label(menu.I18n.t("Error details"), Vector3(0 if menu.compact else 0.13, y, 0.004), 22)
	menu._button(menu.CLOSE, "", Vector2(0.51 if menu.compact else 0.78, y), Vector2(0.075, 0.065), true, "close")
	menu._draw_rows()

func draw_rows() -> void:
	menu._list = Node3D.new(); menu.add_child(menu._list); menu._decorations.append(menu._list); menu._bar_thumb = null
	var first: int = menu._first_line()
	var top := 0.215 if menu.compact else 0.33
	for i in range(first, mini(menu.rows.size(), first + menu._drawn_slots())):
		var k := i - first
		menu._text_button(menu.ROW_BASE + k, "", Vector2(0 if menu.compact else 0.13, top - k * menu._pitch()), Vector2(1.03 if menu.compact else 1.24, 0.098), false, menu._list)
		var node: Node3D = menu._buttons.back().node
		var label: Label3D = menu._label(str(menu.rows[i].title), Vector3(-0.49 if menu.compact else -0.57, 0, 0.004), 19, node)
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	if menu._max_scroll() > 0:
		var span: Vector2 = menu._bar_span()
		var x := 0.55 if menu.compact else 0.835
		menu._button(menu.SCROLLBAR, "", Vector2(x, span.x - span.y * 0.5), Vector2(0.035, span.y))
		var thumb: float = span.y * float(menu._lines()) / menu._line_count()
		menu._bar_thumb = menu._decoration(Vector2(0.01, thumb), Vector2(x, span.x - thumb * 0.5), menu.MUTED)
	menu._place_list()
