extends RefCounted
## Layout and trigger ownership for timestamps. All requests carry the captured media scope.
const ADD := 2000
const LIST := 2001
const UNDO := 2002
const CLOSE := 2003
const UP := 2004
const DOWN := 2005
const MODE_GLOBAL := 2006
const MODE_SPEED := 2007
const MODE_EXACT := 2008
const NEW_LOOP := 2009
const ALL_MARKERS := 2010
const CANCEL_EDIT := 2012
const SAVE := 2014
const EDIT_A := 2016
const EDIT_B := 2017
const LOOP_UP := 2019
const LOOP_DOWN := 2020
const PANEL_UNDO := 2021
const ROW := 2100
const GROUP := 2300
const DELETE_ROW := 2900
const LOOP_ROW := 3000
const LOOP_EDIT := 3100
const LOOP_END := 3200
const LOOP_DELETE := 3300
const LOOP_BAND := 3500
const LOOP_EXPORT := 4100
const ROWS := 5
const LANE_Y := -0.142
const Timeline := preload("res://scripts/timeline_markers.gd")
const MIN_LOOP_MS := preload("res://scripts/bookmark_store.gd").MIN_LOOP_MS
const SeekPolicy := preload("res://scripts/seek_policy.gd")
var menu: Node3D
var opened := false
var offset := 0
var subset: Array = []
var targets: Dictionary = {}
var capture: Dictionary = {}
var scope := ""
var scroll := 0.0
var notice := ""
var notice_until := 0
var flash_id := ""
var loop_offset := 0
var scroll_column := "markers"
var picker := ""
var editing: Dictionary = {}

func _init(owner: Node3D) -> void:
	menu = owner

func reset() -> void:
	opened = false; offset = 0; subset.clear(); capture.clear(); scroll = 0.0
	loop_offset = 0; scroll_column = "markers"; picker = ""; editing.clear()

func notify(text: String, marker_id: String = "") -> void:
	notice = text
	flash_id = marker_id
	notice_until = Time.get_ticks_msec() + 3000
	menu.refresh()

func _markers() -> Array:
	var all: Array = menu._state.get("bookmarks", [])
	return all if subset.is_empty() else all.filter(func(item): return item.id in subset)

func _entries(column: String = "markers") -> Array:
	return menu._state.get("bookmark_loops", []) if column == "loops" else _markers()

func _rows(column: String) -> int:
	return 3 if column == "loops" and not editing.is_empty() else ROWS

func _marker(marker_id: String) -> Dictionary:
	for marker in menu._state.get("bookmarks", []):
		if marker.id == marker_id: return marker
	return {}

func _can_pick(marker: Dictionary, endpoint: String) -> bool:
	return _pick_error(marker, endpoint).is_empty()

func _pick_error(marker: Dictionary, endpoint: String) -> String:
	if not menu._state.get("bookmark_seekable", false) or int(marker.position_ms) >= int(menu._state.get("duration_ms", 0)): return "Loop unavailable"
	if endpoint == "a" and not _start_available(str(marker.id), str(editing.get("id", ""))): return "Start bookmark already used"
	var other := _marker(str(editing.get("b" if endpoint == "a" else "a", "")))
	if other.is_empty(): return ""
	var length_ms := int(other.position_ms) - int(marker.position_ms) if endpoint == "a" else int(marker.position_ms) - int(other.position_ms)
	return "" if length_ms >= MIN_LOOP_MS else "Invalid loop range"

func _valid_draft() -> bool:
	var a := _marker(str(editing.get("a", ""))); var b := _marker(str(editing.get("b", "")))
	return not a.is_empty() and not b.is_empty() and _can_pick(a, "a") and _can_pick(b, "b")

func _range(segment: Dictionary) -> String:
	return menu._time(int(segment.a_ms)) + " — " + menu._time(int(segment.b_ms))

func _starts(marker_id: String) -> Array:
	return menu._state.get("bookmark_loops", []).filter(func(item): return item.a == marker_id)

func _ends(marker_id: String) -> Array:
	return menu._state.get("bookmark_loops", []).filter(func(item): return item.b == marker_id)

func _start_available(marker_id: String, loop_id: String = "") -> bool:
	return not _starts(marker_id).any(func(item): return item.id != loop_id)

func _active(segment: Dictionary) -> bool:
	return menu._state.get("bookmark_loop_active", false) and menu._state.get("bookmark_loop", {}).get("id", "") == segment.id

func _endpoint(target: int, caption: String, centre: Vector2, size: Vector2, segment: Dictionary, at_start: bool, enabled: bool) -> void:
	menu._button(target, caption, centre, size, enabled or (not at_start and _active(segment)))
	menu.set_label_size(menu._buttons.back().node.get_child(0), 17)
	menu._buttons.back().base_color = menu.SELECTED if _active(segment) else menu.TILE
	menu._tips[target] = menu.I18n.t("Enable A-B loop" if at_start else "Disable A-B loop") + " · " + _range(segment)
	targets[target] = {"kind": "loop_start" if at_start else "loop_end", "id": segment.id, "marker": segment.a if at_start else segment.b, "range": segment.duplicate(true), "column": "loops"}

func _loop_action(operation: String, payload: Dictionary, media_scope: String) -> void:
	menu.bookmark_loop_requested.emit(operation, payload, media_scope)

func _scope() -> String:
	return str(menu._state.get("bookmark_scope", ""))

func draw() -> void:
	if scope != _scope():
		reset(); notice = ""; scope = _scope()
	# Validate before drawing the timeline as well as the inline editor.
	if not editing.is_empty() and not str(editing.id).is_empty() and not _entries("loops").any(func(item): return item.id == editing.id):
		editing.clear(); picker = ""
	targets.clear()
	var has_video: bool = menu._state.get("has_video", false)
	menu._glyph(ADD, "bookmark_add", Vector2(-0.22, 0.025), 0.06,
		menu._state.get("bookmark_ready", false) and menu._seek_hand.is_empty(), menu.I18n.t("Add bookmark"))
	var all: Array = menu._state.get("bookmarks", [])
	if not all.is_empty():
		menu._round(LIST, "bookmark", Vector2(-0.42, 0.215), 0.08, has_video, false, menu.I18n.t("Bookmarks"))
		menu._label(str(all.size()), Vector3(-0.375, 0.245, 0.004), 13)
	if menu._state.get("bookmark_undo", false):
		menu._round(UNDO, "undo", Vector2(0.42, 0.215), 0.08, true, false, menu.I18n.t("Undo delete"))
	if Time.get_ticks_msec() < notice_until:
		menu._label(notice, Vector3(0, 0.152, 0.005), 14)
	_draw_ranges()
	var groups := Timeline.groups(all, int(menu._state.get("duration_ms", 0)), menu.BAR_SEEK)
	for index in groups.size():
		var group: Dictionary = groups[index]
		var target := GROUP + index
		var ids: Array = group.markers.map(func(item): return item.id)
		var starts: Array = menu._state.get("bookmark_loops", []).filter(func(item): return item.a in ids)
		var ends: Array = menu._state.get("bookmark_loops", []).filter(func(item): return item.b in ids)
		var caption := ("B/A" if ids.size() == 1 else "A–B") if not starts.is_empty() and not ends.is_empty() else ("A" if not starts.is_empty() else ("B" if not ends.is_empty() else ""))
		if not picker.is_empty() and ids.size() == 1:
			if ids[0] == editing.a: caption = "A"
			elif ids[0] == editing.b: caption = "B"
		if caption.is_empty() and ids.size() > 1: caption = str(ids.size())
		var enabled: bool = menu._state.get("bookmark_seekable", false)
		if not picker.is_empty(): enabled = group.markers.any(func(marker): return _can_pick(marker, picker))
		menu._button(target, caption, Vector2(group.x, LANE_Y), Vector2.ONE * Timeline.MARKER_WIDTH, enabled, "bookmark" if caption.is_empty() else "")
		menu.set_label_size(menu._buttons.back().node.get_child(0), 11 if caption in ["A–B", "B/A"] else 18)
		var highlighted: bool = (starts + ends).any(func(item): return _active(item)) or (Time.get_ticks_msec() < notice_until and group.markers.any(func(item): return item.id == flash_id))
		if not editing.is_empty() and ids.any(func(id): return id in [editing.a, editing.b]):
			highlighted = true; menu._buttons.back()["fixed_current"] = true
		menu._buttons.back().base_color = menu.SELECTED if highlighted else Color(menu.TILE, 0)
		menu._decoration(Vector2(0.002, 0.024), Vector2(group.x, -0.105), menu.ACCENT)
		menu._tips[target] = menu._time(int(group.markers[0].position_ms)) if group.markers.size() == 1 else menu.I18n.t("Bookmarks") + " · " + str(group.markers.size())
		if ids.size() == 1 and starts.size() == 1 and ends.is_empty(): menu._tips[target] = menu.I18n.t("Enable A-B loop") + " · " + _range(starts[0])
		elif ids.size() == 1 and starts.is_empty() and not ends.is_empty(): menu._tips[target] = menu.I18n.t("Disable A-B loop") + " · " + menu._time(int(group.markers[0].position_ms))
		if not picker.is_empty():
			var choice_tip: String = menu.I18n.t("Choose start bookmark" if picker == "a" else "Choose end bookmark")
			var time_tip: String = menu._time(int(group.markers[0].position_ms)) if ids.size() == 1 else menu.I18n.t("Bookmarks") + " · " + str(ids.size())
			menu._tips[target] = choice_tip + " · " + time_tip
			if not enabled:
				menu._buttons.back()["hover_disabled"] = true
				menu._tips[target] = menu.I18n.t(_pick_error(group.markers[0], picker))
		targets[target] = {"kind": "group", "ids": ids, "starts": starts.duplicate(true), "ends": ends.duplicate(true), "end": picker, "draft": editing.duplicate(true)}
	if not opened: return
	menu._draw_popup(_draw_list)

func _draw_ranges() -> void:
	var duration := int(menu._state.get("duration_ms", 0))
	if duration <= 0: return
	# Every saved range occupies the existing marker lane. Paint the active one last.
	var segments: Array = menu._state.get("bookmark_loops", []).duplicate()
	segments.sort_custom(func(a, b):
		if _active(a) != _active(b): return not _active(a)
		return int(a.b_ms) - int(a.a_ms) > int(b.b_ms) - int(b.a_ms))
	for index in segments.size():
		var segment: Dictionary = segments[index]
		if int(segment.a_ms) < 0 or int(segment.b_ms) >= duration: continue
		var left: float = -menu.BAR_SEEK / 2 + menu.BAR_SEEK * float(segment.a_ms) / duration
		var right: float = -menu.BAR_SEEK / 2 + menu.BAR_SEEK * float(segment.b_ms) / duration
		var active := _active(segment)
		var fill: Color = menu.TILE.lerp(menu.ACCENT, 0.32 if active else 0.09)
		var target := LOOP_BAND + index
		menu._button(target, "", Vector2((left + right) / 2, LANE_Y), Vector2(right - left, 0.032), picker.is_empty() and menu._state.get("bookmark_seekable", false))
		var button: Dictionary = menu._buttons.back()
		button.base_color = fill; button.hover_color = fill.lightened(0.18)
		var band: MeshInstance3D = button.node
		# Hit the visibly top range where ranges overlap, with endpoints in front.
		band.position.z = 0.001 + 0.0005 * float(index + 1) / segments.size()
		band.material_override.render_priority = 10
		band.set_meta("bookmark_loop_id", segment.id)
		menu._tips[target] = menu.I18n.t("Enable A-B loop") + " · " + _range(segment)
		targets[target] = {"kind": "loop_range", "id": segment.id, "range": segment.duplicate(true)}

func _draw_list() -> void:
	# Both collections retain their identity and position throughout editing.
	var panel = menu._quad(Vector2(1.12, 0.57), Vector3(0, 0.565, 0.001), menu.PANEL, 10)
	menu._pointer_panels.append(panel)
	menu.add_child(panel); menu._decorations.append(panel)
	var marker_heading = menu._label(menu.I18n.t("Bookmarks"), Vector3(-0.36, 0.8, 0.01), 20)
	if not picker.is_empty(): marker_heading.modulate = menu.ACCENT
	menu._label(menu.I18n.t("Loop segments"), Vector3(0.12, 0.8, 0.01), 20)
	menu._glyph(NEW_LOOP, "plus", Vector2(0.4, 0.8), 0.055, editing.is_empty() and menu._state.get("bookmark_seekable", false) and menu._state.get("bookmarks", []).size() >= 2, menu.I18n.t("New loop segment"))
	menu._glyph(CLOSE, "close", Vector2(0.505, 0.8), 0.055, true, menu.I18n.t("Close"))
	menu._decoration(Vector2(0.001, 0.39), Vector2(-0.145, 0.57), Color(menu.MUTED, 0.25))
	_draw_markers()
	_draw_loops()
	_draw_seek_options()
	menu._glyph(PANEL_UNDO, "undo", Vector2(0.505, 0.315), 0.055, menu._state.get("bookmark_undo", false), menu.I18n.t("Undo delete"))

func _draw_markers() -> void:
	var entries := _entries()
	offset = clampi(offset, 0, maxi(0, entries.size() - ROWS))
	if not subset.is_empty():
		menu._glyph(ALL_MARKERS, "back", Vector2(-0.51, 0.8), 0.045, true, menu.I18n.t("All bookmarks"))
	if entries.is_empty(): menu._label(menu.I18n.t("No bookmarks"), Vector3(-0.35, 0.6, 0.01), 16).modulate = menu.MUTED
	for row in mini(ROWS, entries.size() - offset):
		var item: Dictionary = entries[offset + row]
		var y := 0.7 - row * 0.066
		var enabled: bool = menu._state.get("bookmark_seekable", false) and int(item.position_ms) < int(menu._state.get("duration_ms", 0))
		if not picker.is_empty(): enabled = _can_pick(item, picker)
		menu._button(ROW + row, menu._time(int(item.position_ms)), Vector2(-0.365, y), Vector2(0.265, 0.058), enabled)
		menu.set_label_size(menu._buttons.back().node.get_child(0), 17)
		# Keep both chosen endpoints visible, even when A is unavailable as a B candidate.
		if not editing.is_empty() and item.id in [editing.a, editing.b]:
			menu._buttons.back().base_color = menu.SELECTED
			menu._buttons.back()["fixed_current"] = true
		if not picker.is_empty() and not enabled:
			menu._buttons.back()["hover_disabled"] = true
			menu._tips[ROW + row] = menu.I18n.t(_pick_error(item, picker))
		targets[ROW + row] = {"kind": "seek" if picker.is_empty() else "pick", "id": item.id, "column": "markers", "end": picker}
		var count: int = _starts(str(item.id)).size() + _ends(str(item.id)).size()
		var deletion: String = menu.I18n.t("Delete bookmark") if count == 0 else menu.I18n.t("Delete bookmark and %d loops") % count
		menu._glyph(DELETE_ROW + row, "trash", Vector2(-0.2, y), 0.05, editing.is_empty(), deletion)
		targets[DELETE_ROW + row] = {"kind": "delete", "id": item.id, "column": "markers"}
	_draw_paging("markers", entries.size(), offset, ROWS)

func _draw_loops() -> void:
	var entries := _entries("loops")
	var rows := _rows("loops")
	loop_offset = clampi(loop_offset, 0, maxi(0, entries.size() - rows))
	if entries.is_empty() and editing.is_empty(): menu._label(menu.I18n.t("No loop segments"), Vector3(0.17, 0.6, 0.01), 17).modulate = menu.MUTED
	for row in mini(rows, entries.size() - loop_offset):
		var item: Dictionary = entries[loop_offset + row]
		var y := 0.7 - row * 0.066
		var enabled: bool = menu._state.get("bookmark_seekable", false) and int(item.b_ms) < int(menu._state.get("duration_ms", 0))
		var capture_state: Dictionary = menu._state.get("capture", {})
		var exports: Dictionary = capture_state.get("loop_exports", {})
		var exporting: bool = exports.has(item.id)
		_endpoint(LOOP_ROW + row, "A  " + menu._time(int(item.a_ms)), Vector2(-0.015, y), Vector2(0.205, 0.058), item, true, enabled)
		_endpoint(LOOP_END + row, "B  " + menu._time(int(item.b_ms)), Vector2(0.205, y), Vector2(0.205, 0.058), item, false, enabled)
		menu._glyph(LOOP_EDIT + row, "edit", Vector2(0.345, y), 0.05, editing.is_empty() and not exporting, menu.I18n.t("Edit"))
		if editing.get("id", "") == item.id: menu._buttons.back().base_color = menu.SELECTED
		targets[LOOP_EDIT + row] = {"kind": "edit", "item": item.duplicate(true), "column": "loops"}
		menu._glyph(LOOP_DELETE + row, "trash", Vector2(0.41, y), 0.05, editing.is_empty() and not exporting, menu.I18n.t("Delete loop segment"))
		targets[LOOP_DELETE + row] = {"kind": "loop_delete", "id": item.id, "column": "loops"}
		if exporting:
			menu._button(LOOP_EXPORT + row, str(exports[item.id]) + "%", Vector2(0.475, y), Vector2.ONE * 0.05, false)
			menu.set_label_size(menu._buttons.back().node.get_child(0), 12)
			menu._buttons.back().node.get_child(0).modulate = menu.ACCENT
		else:
			menu._glyph(LOOP_EXPORT + row, "film_cut", Vector2(0.475, y), 0.05, enabled and editing.is_empty() and capture_state.get("loop_available", false) and not capture_state.get("clip_busy", false), menu.I18n.t("Save loop clip") + " · " + _range(item))
		targets[LOOP_EXPORT + row] = {"kind": "loop_export", "id": item.id, "column": "loops"}
	_draw_paging("loops", entries.size(), loop_offset, rows)
	if not editing.is_empty(): _draw_editor()

func _draw_paging(column: String, count: int, current: int, rows: int) -> void:
	if count <= rows: return
	var is_loop := column == "loops"
	for option in [[LOOP_UP if is_loop else UP, -1], [LOOP_DOWN if is_loop else DOWN, 1]]:
		var target: int = option[0]
		var centre := Vector2(0.53, 0.66 if option[1] == -1 else 0.54) if is_loop else Vector2(-0.46 if option[1] == -1 else -0.24, 0.367)
		menu._button(target, "↑" if option[1] == -1 else "↓", centre, Vector2.ONE * 0.05, current > 0 if option[1] == -1 else current + rows < count)
		targets[target] = {"kind": "page", "column": column, "step": option[1] * rows}

func _draw_editor() -> void:
	var can_save := _valid_draft()
	if picker.is_empty():
		menu._label(menu.I18n.t("New loop segment" if str(editing.id).is_empty() else "Edit"), Vector3(0.165, 0.49, 0.01), 15).modulate = menu.MUTED
	else:
		var hint = menu._label("← " + menu.I18n.t("Choose start bookmark" if picker == "a" else "Choose end bookmark"), Vector3(-0.115, 0.49, 0.01), 15)
		hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		hint.modulate = menu.ACCENT
	for option in [[EDIT_A, "a", -0.015], [EDIT_B, "b", 0.205]]:
		var endpoint: String = option[1]
		var marker := _marker(str(editing.get(endpoint, "")))
		var caption: String = endpoint.to_upper() + "  " + ("—" if marker.is_empty() else menu._time(int(marker.position_ms)))
		menu._button(option[0], caption, Vector2(option[2], 0.425), Vector2(0.205, 0.058))
		menu.set_label_size(menu._buttons.back().node.get_child(0), 17)
		menu._buttons.back().base_color = menu.SELECTED if picker == endpoint or not marker.is_empty() else menu.TILE
		menu._tips[option[0]] = menu.I18n.t("Choose start bookmark" if endpoint == "a" else "Choose end bookmark")
		targets[option[0]] = {"kind": "endpoint", "end": endpoint}
	var save_tip := "Save"
	if not can_save:
		var a := _marker(str(editing.a)); var b := _marker(str(editing.b))
		if a.is_empty(): save_tip = "Choose start bookmark"
		elif b.is_empty(): save_tip = "Choose end bookmark"
		else:
			save_tip = _pick_error(a, "a")
			if save_tip.is_empty(): save_tip = _pick_error(b, "b")
	menu._round(SAVE, "check", Vector2(0.35, 0.425), 0.05, can_save, can_save, menu.I18n.t(save_tip))
	menu._buttons.back()["hover_disabled"] = true
	menu._glyph(CANCEL_EDIT, "close", Vector2(0.425, 0.425), 0.05, true, menu.I18n.t("Cancel"))
	# Snapshot the draft to prevent a held trigger saving a subsequently changed pair.
	targets[SAVE] = {"kind": "save", "draft": editing.duplicate(true)}

func _draw_seek_options() -> void:
	menu._label(menu.I18n.t("Video time positioning"), Vector3(-0.355, 0.315, 0.01), 13).modulate = menu.MUTED
	var choice := SeekPolicy.bookmark_override(menu._state.get("bookmark_seek_mode", SeekPolicy.GLOBAL))
	for option in [[MODE_GLOBAL, SeekPolicy.GLOBAL, "Follow global", -0.07, 0.22],
		[MODE_SPEED, SeekPolicy.SPEED, "Speed", 0.135, 0.16], [MODE_EXACT, SeekPolicy.EXACT, "Precise", 0.315, 0.16]]:
		var target: int = option[0]
		menu._button(target, menu.I18n.t(option[2]), Vector2(option[3], 0.315), Vector2(option[4], 0.048))
		menu.set_label_size(menu._buttons.back().node.get_child(0), 13)
		menu._buttons.back().base_color = menu.SELECTED if choice == option[1] else menu.TILE
		targets[target] = {"kind": "seek_mode", "mode": option[1]}
		menu._tips[target] = menu.I18n.t("Follow global setting") + " · " + menu.I18n.t(SeekPolicy.caption(menu._state.get("seek_mode", SeekPolicy.SPEED))) \
			if option[1] == SeekPolicy.GLOBAL else menu.I18n.t("Faster jumps, less precise" if option[1] == SeekPolicy.SPEED else "Accurate jumps, may take longer")

func _belongs(target: int) -> bool:
	return target in [ADD, LIST, UNDO, CLOSE, NEW_LOOP, ALL_MARKERS, CANCEL_EDIT, PANEL_UNDO] or targets.has(target)

func press(hand: String, hit: Dictionary) -> bool:
	if not capture.is_empty(): return true
	var target := int(hit.get("target", -1))
	if not _belongs(target): return false
	if not hit.get("enabled", false): return true
	capture = {"hand": hand, "target": target, "scope": scope, "item": targets.get(target, {}).duplicate(true),
		"start": menu.control_point(hit), "plane": menu.control_plane(target), "offset": loop_offset if targets.get(target, {}).get("column") == "loops" else offset, "moved": false}
	return true

func update(hand: String, origin: Vector3, direction: Vector3, tracked: bool) -> void:
	if tracked:
		var hovered: int = int(menu._hover.get(hand, -1))
		if targets.get(hovered, {}).has("column"): scroll_column = targets[hovered].column
	if capture.is_empty() or capture.hand != hand: return
	if not tracked or not menu.visible or capture.scope != _scope():
		capture.clear(); return
	var point: Variant = menu.project_pointer(origin, direction, capture.plane)
	if point == null: capture.clear(); return
	var delta: Vector2 = Vector2(point.x - capture.start.x, point.y - capture.start.y)
	if delta.length() > 0.018: capture.moved = true
	if capture.moved and capture.item.has("column") and capture.item.get("kind") != "page":
		var column: String = capture.item.column
		var next := clampi(int(capture.offset) + roundi(delta.y / 0.066), 0, maxi(0, _entries(column).size() - _rows(column)))
		if next != (loop_offset if column == "loops" else offset):
			if column == "loops": loop_offset = next
			else: offset = next
			menu.refresh()

func cancel() -> void:
	capture.clear()

func release(hand: String, origin: Vector3, direction: Vector3, tracked: bool) -> void:
	if capture.is_empty() or capture.hand != hand: return
	var pressed := capture.duplicate(true)
	capture.clear()
	if not tracked or not menu.visible or pressed.scope != _scope() or pressed.moved: return
	var hit: Dictionary = menu.ray_hit(origin, direction)
	if not hit.get("enabled", false): return
	if int(hit.get("target", -1)) != int(pressed.target) or targets.get(pressed.target, {}) != pressed.item: return
	var point: Vector3 = menu.control_point(hit)
	if Vector2(point.x - pressed.start.x, point.y - pressed.start.y).length() > 0.018: return
	_activate(int(pressed.target), pressed.item, str(pressed.scope))

func _activate(target: int, item: Dictionary, media_scope: String) -> void:
	if target == ADD:
		if menu._state.get("bookmark_ready", false): menu.bookmark_requested.emit("add", "", media_scope)
	elif target in [UNDO, PANEL_UNDO]:
		menu.bookmark_requested.emit("undo", "", media_scope); menu.refresh()
	elif target == LIST:
		var show_list := not opened
		reset(); opened = show_list; _close_other_popups(); menu.refresh()
	elif target == CLOSE:
		reset(); menu.refresh()
	elif target == ALL_MARKERS:
		subset.clear(); offset = 0; menu.refresh()
	elif target == NEW_LOOP:
		editing = {"id": "", "a": "", "b": ""}; picker = "a"; subset.clear(); scroll_column = "markers"; menu.refresh()
	elif target == CANCEL_EDIT:
		picker = ""; editing.clear(); menu.refresh()
	elif item.get("kind") == "page":
		if item.column == "loops": loop_offset += int(item.step)
		else: offset += int(item.step)
		menu.refresh()
	elif item.get("kind") == "seek_mode":
		menu.bookmark_mode_requested.emit(str(item.mode), media_scope); menu.refresh()
	elif item.get("kind") == "delete":
		menu.bookmark_requested.emit("delete", str(item.id), media_scope); menu.refresh()
	elif item.get("kind") in ["loop_start", "loop_end", "loop_delete", "loop_export"]:
		_loop_action(str(item.kind).trim_prefix("loop_"), item, media_scope); menu.refresh()
	elif item.get("kind") == "loop_range":
		_loop_action("start", {"id": item.id}, media_scope); menu.refresh()
	elif item.get("kind") == "edit":
		editing = {"id": item.item.id, "a": item.item.a, "b": item.item.b}; picker = "b"; subset.clear(); scroll_column = "markers"
		var entries := _entries("loops")
		for index in entries.size():
			if entries[index].id == editing.id:
				loop_offset = clampi(loop_offset, index - _rows("loops") + 1, index); break
		menu.refresh()
	elif item.get("kind") == "endpoint":
		picker = str(item.end); scroll_column = "markers"; menu.refresh()
	elif item.get("kind") == "pick":
		_pick_marker(str(item.id), str(item.end))
	elif item.get("kind") == "save" and _valid_draft():
		var draft: Dictionary = item.draft
		_loop_action("save", draft, media_scope); menu.refresh()
		# Keep the editor open if the controller rejects a stale or conflicting draft.
		var entries := _entries("loops")
		for index in entries.size():
			var segment: Dictionary = entries[index]
			if segment.a == draft.a and segment.b == draft.b and (str(draft.id).is_empty() or segment.id == draft.id):
				picker = ""; editing.clear()
				loop_offset = clampi(loop_offset, index - ROWS + 1, index)
				menu.refresh(); break
	elif item.get("kind") == "seek":
		menu.bookmark_requested.emit("seek", str(item.id), media_scope)
	elif item.get("kind") == "group":
		if not picker.is_empty():
			if item.ids.size() == 1: _pick_marker(str(item.ids[0]), picker)
			else:
				# Disambiguate the group in the same editor; keep the selected endpoint.
				subset = item.ids.duplicate(); offset = 0; scroll_column = "markers"
				opened = true; _close_other_popups(); menu.refresh()
			return
		if item.ids.size() == 1 and item.starts.size() == 1 and item.ends.is_empty():
			_loop_action("start", {"id": item.starts[0].id}, media_scope); menu.refresh()
		elif item.ids.size() == 1 and item.starts.is_empty() and not item.ends.is_empty():
			_loop_action("end", {"marker": item.ids[0]}, media_scope); menu.refresh()
		elif item.ids.size() == 1 and item.starts.is_empty() and item.ends.is_empty(): menu.bookmark_requested.emit("seek", str(item.ids[0]), media_scope)
		else:
			reset(); opened = true; subset = item.ids.duplicate()
			var related: Array = item.starts + item.ends
			var entries := _entries("loops")
			for index in entries.size():
				if related.any(func(segment): return segment.id == entries[index].id): loop_offset = index; break
			_close_other_popups(); menu.refresh()

func _pick_marker(marker_id: String, endpoint: String) -> void:
	if editing.is_empty() or endpoint not in ["a", "b"]: return
	var marker := _marker(marker_id)
	if marker.is_empty() or not _can_pick(marker, endpoint): return
	editing[endpoint] = marker_id
	if endpoint == "a" and str(editing.b).is_empty(): picker = "b"
	# A timeline choice may be outside the currently visible page or group.
	if not subset.is_empty() and marker_id not in subset: subset.clear()
	var entries := _markers()
	for index in entries.size():
		if entries[index].id == marker_id:
			offset = clampi(offset, index - ROWS + 1, index); break
	menu.refresh()

func _close_other_popups() -> void:
	menu.choices.reset()
	menu._subtitle_open = false; menu._mode_open = false; menu._volume_open = false
	menu._close_depth_slider()
	menu._pip_open = false
	menu.disc_titles.reset()

func stick_scroll(y: float, delta: float) -> void:
	if not opened or not capture.is_empty() or not is_finite(y) or absf(y) < 0.3: return
	scroll -= y * delta * 8
	if absf(scroll) >= 1:
		if scroll_column == "loops": loop_offset += int(scroll)
		else: offset += int(scroll)
		scroll -= int(scroll); menu.refresh()

func key() -> Array:
	return [menu._state.get("bookmark_scope", ""), menu._state.get("bookmark_revision", 0),
		menu._state.get("bookmark_undo", false), menu._state.get("bookmark_ready", false),
		menu._state.get("bookmark_seekable", false), menu._state.get("duration_ms", 0),
		menu._state.get("seek_mode", SeekPolicy.SPEED), menu._state.get("bookmark_seek_mode", SeekPolicy.GLOBAL),
		menu._state.get("bookmark_loop", {}), menu._state.get("bookmark_loop_active", false),
		menu._state.get("capture", {}).get("loop_available", false), menu._state.get("capture", {}).get("clip_busy", false), menu._state.get("capture", {}).get("loop_exports", {}),
		Time.get_ticks_msec() < notice_until]
