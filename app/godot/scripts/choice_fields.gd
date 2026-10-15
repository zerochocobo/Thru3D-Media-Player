extends RefCounted
## One setting per field. Choice actions commit on the owning hand's release.
signal changed(key: String, value: Variant)
signal previewed(key: String, value: Variant)
var sliders: Dictionary = {}
const BASE := 8000
const POPUP_ROWS := 6
const PITCH := 0.071
var menu: Node3D
var targets: Dictionary = {}
var capture: Dictionary = {}
var scope := ""
var opened := ""
var offset := 0
var scroll := 0.0
var popup: Dictionary = {}
var anchor := Vector2.ZERO
var bounds := Vector2(-0.44, 0.35)

func _init(owner: Node3D) -> void: menu = owner

func reset() -> void:
	_finish_slider()
	opened = ""; offset = 0; scroll = 0.0; capture.clear(); popup.clear()

func begin(context: String, vertical_bounds: Vector2 = Vector2(-0.44, 0.35)) -> void:
	if scope != context: reset()
	scope = context; bounds = vertical_bounds; targets.clear(); sliders.clear(); popup.clear()

static func same(a: Variant, b: Variant) -> bool:
	if (a is int or a is float) and (b is int or b is float): return is_equal_approx(float(a), float(b))
	return a == b

func _button(item: Dictionary, label: String, centre: Vector2, size: Vector2, parent: Node3D = null, selected: bool = false, text_only: bool = false) -> int:
	var target := BASE + targets.size()
	targets[target] = item
	var field_z := 0.0
	if parent != null:
		# Registered buttons are siblings: clearing a container must not free
		# another registered button before RayMenu retires it.
		var container: Node3D = parent.get_parent()
		var local: Vector3 = container.to_local(parent.to_global(Vector3(centre.x, centre.y, 0)))
		centre = Vector2(local.x, local.y); field_z = local.z + 0.004; parent = container
	if text_only: menu._text_button(target, menu._fit_title(label, "", size.x - 0.025, 18), centre, size, true, parent)
	else: menu._button(target, menu._fit_title(label, "", size.x - 0.025, 18), centre, size, true, "", false, parent)
	var button: Dictionary = menu._buttons.back()
	if field_z > 0: button.node.position.z = field_z
	button.base_color = menu.SELECTED if selected else menu.TILE
	if not text_only:
		button.node.material_override.set_shader_parameter("surface_color", button.base_color)
		button.node.material_override.render_priority = 13
	menu.set_label_size(button.node.get_child(0), 18)
	(button.node.get_child(0) as Label3D).render_priority = 14
	return target

func _option_label(option: Dictionary) -> String:
	if option.has("text_color") and menu.I18n.language == "en": return "Aa"
	return menu.I18n.t(option.label)

func _appearance(option: Dictionary) -> void:
	if not option.has("text_color"): return
	var label: Label3D = menu._buttons.back().node.get_child(0)
	label.modulate = option.text_color
	label.outline_modulate = option.get("outline_color", Color.BLACK)
	label.outline_size = 4 * menu.TEXT_RASTER_SCALE
	label.outline_render_priority = label.render_priority
	label.render_priority += 1

func field(parent: Node3D, row: Dictionary, centre: Vector2, width: float, height: float = 0.06) -> void:
	if row.get("slider", false):
		_slider(parent, row, centre, width, height)
		return
	var options: Array = row.choices
	var key: String = row.key
	if options.size() <= 2 or row.get("compact", false):
		var cell := (width - 0.014 * (options.size() - 1)) / options.size()
		for index in options.size():
			var option: Dictionary = options[index]
			var target := _button({"kind": "choose", "key": key, "value": option.value}, _option_label(option),
				Vector2(centre.x - width/2 + cell/2 + index*(cell+0.014), centre.y), Vector2(cell, height), parent, same(row.value, option.value))
			_appearance(option)
			menu._tips[target] = menu.I18n.t(str(option.get("hint", row.get("hint", ""))))
	else:
		var label := ""
		var selected: Dictionary = {}
		for option in options:
			if same(row.value, option.value):
				label = _option_label(option); selected = option; break
		if label.is_empty(): label = str(row.get("display_value", row.value))
		var target := _button({"kind": "open", "key": key}, menu._fit_title(label, "  " + menu.CHOICE_MARK, width - 0.025, 18), centre, Vector2(width, height), parent, false, true)
		_appearance(selected)
		menu._buttons.back().foreground = (menu._buttons.back().node.get_child(0) as Label3D).modulate
		menu._tips[target] = menu.I18n.t(str(row.get("hint", "")))
		if opened == key:
			popup = row.duplicate(true)
			var point: Vector3 = menu.to_local(menu._buttons.back().node.global_position)
			anchor = Vector2(point.x, point.y)

# A wide invisible hit target surrounds the rail; graphics follow the button's plane.
func _slider(parent: Node3D, row: Dictionary, centre: Vector2, width: float, height: float) -> void:
	var reset_width := 0.08 if row.has("reset_value") else 0.0
	var nudge_width := 0.12 if row.has("nudge_step") else 0.0
	var field_width := width - reset_width - nudge_width
	var field_centre := centre - Vector2((width - field_width) * 0.5, 0)
	var rail_width := field_width - 0.15
	var target := _button({"kind": "slider", "key": row.key, "span": row.span}, "", field_centre, Vector2(field_width, height), parent)
	if row.has("source_uri"): targets[target].source_uri = row.source_uri
	var button: Dictionary = menu._buttons.back()
	button.base_color = Color(menu.TILE, 0)
	button.node.material_override.set_shader_parameter("surface_color", button.base_color)
	var node: MeshInstance3D = button.node
	var left := -field_width / 2 + 0.015
	var y := -0.008 if row.get("midpoint", false) else 0.0
	var rail: MeshInstance3D = menu._quad(Vector2(rail_width, 0.007), Vector3(left + rail_width / 2, y, 0.004), menu.MUTED, 14)
	node.add_child(rail)
	var fill: MeshInstance3D = menu._quad(Vector2(rail_width, 0.007), rail.position, menu.ACCENT, 15)
	node.add_child(fill)
	if row.get("midpoint", false):
		var tick: MeshInstance3D = menu._quad(Vector2(0.003, 0.023), Vector3(left + rail_width / 2, y, 0.005), Color.WHITE, 16)
		node.add_child(tick)
		var middle: Label3D = menu._label(menu.I18n.t("Middle"), Vector3(left + rail_width / 2, 0.023, 0.006), 12, node)
		middle.render_priority = 16
	var knob: MeshInstance3D = menu._quad(Vector2(0.022, 0.022), Vector3(left, y, 0.006), Color.WHITE, 17)
	node.add_child(knob)
	var label: Label3D = node.get_child(0)
	label.position = Vector3(field_width / 2 - 0.005, 0, 0.006)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	sliders[target] = {"span": row.span, "left": left, "width": rail_width, "fill": fill, "knob": knob,
		"label": label, "unit": row.unit, "node": node, "signed": row.get("signed", false)}
	if row.has("nudge_step"):
		for index in 2:
			var step := float(row.nudge_step) * (-1 if index == 0 else 1)
			var item := {"kind": "nudge", "key": row.key, "value": row.value, "step": step, "span": row.span}
			if row.has("source_uri"): item.source_uri = row.source_uri
			_button(item, "−" if index == 0 else "+", centre + Vector2(width / 2 - reset_width - nudge_width + 0.03 + index * 0.06, 0), Vector2(0.055, height), parent)
			var nudge: Dictionary = menu._buttons.back()
			nudge.enabled = not same(clampf(float(row.value) + step, row.span.x, row.span.y), row.value)
			if not nudge.enabled: nudge.node.get_child(0).modulate = menu.MUTED
	if row.has("reset_value"):
		var reset_target := _button({"kind": "reset", "key": row.key, "value": row.reset_value}, "",
			centre + Vector2(width / 2 - 0.0325, 0), Vector2(0.065, height), parent)
		var reset: Dictionary = menu._buttons.back()
		if row.has("source_uri"): targets[reset_target].source_uri = row.source_uri
		reset.base_color = Color(menu.TILE, 0)
		reset.node.material_override.set_shader_parameter("surface_color", reset.base_color)
		menu._icon("refresh", Vector3(0, 0, 0.006), 0.032, menu.MUTED, reset.node)
		menu._tips[reset_target] = menu.I18n.t("Reset")
		sliders[target]["reset"] = reset
		sliders[target]["reset_value"] = row.reset_value
		sliders[target]["reset_when_changed"] = row.get("reset_when_changed", false)
	# Capture retains the last preview through ordinary menu redraws.
	var value := float(capture.value) if capture.get("item", {}).get("key", "") == row.key and capture.has("value") else float(row.value)
	_refresh_slider(target, value)

func _refresh_slider(target: int, value: float) -> void:
	if not sliders.has(target): return
	var slider: Dictionary = sliders[target]
	var fraction := clampf(inverse_lerp(slider.span.x, slider.span.y, value), 0, 1)
	slider.fill.visible = fraction > 0
	slider.fill.mesh.size.x = maxf(0.001, fraction * slider.width)
	slider.fill.position.x = slider.left + fraction * slider.width / 2
	slider.fill.material_override.set_shader_parameter("surface_size", slider.fill.mesh.size)
	slider.knob.position.x = slider.left + fraction * slider.width
	slider.label.text = ("%.0f" % value if slider.unit in ["%", " FPS"] else ("%+.0f" % value if slider.unit == "°" and value != 0 else ("%.0f" % value if slider.unit == "°" else "%.1f" % value))) + slider.unit
	if slider.get("signed", false): slider.label.text = (("%+.1f" if not is_zero_approx(value) else "%.1f") % value) + slider.unit
	if slider.has("reset"):
		slider.reset.enabled = not same(value, slider.reset_value)
		if slider.get("reset_when_changed", false): slider.reset.node.visible = slider.reset.enabled
		slider.reset.node.get_child(1).material_override.albedo_color = menu.ACCENT if slider.reset.enabled else menu.MUTED

func _preview_slider(point: Vector3) -> void:
	var span: Vector3 = capture.item.span
	var fraction := clampf((point.x - float(capture.left)) / float(capture.width), 0, 1)
	var value := clampf(snappedf(lerpf(span.x, span.y, fraction), span.z), span.x, span.y)
	if capture.has("value") and is_equal_approx(capture.value, value): return
	capture.value = value
	_refresh_slider(int(capture.target), value)
	previewed.emit(str(capture.item.key), _scoped_value(capture.item, value))

func _finish_slider() -> bool:
	if capture.get("item", {}).get("kind", "") != "slider": return false
	var request := capture.duplicate(true)
	capture.clear()
	if request.has("value"): changed.emit(str(request.item.key), _scoped_value(request.item, request.value))
	return true

static func _scoped_value(item: Dictionary, value: Variant) -> Variant:
	return {"value": value, "source_uri": item.source_uri} if item.has("source_uri") else value

## Icon-triggered lists share the same ownership, scrolling and selection as settings fields.
func present(row: Dictionary, centre: Vector2, vertical_bounds: Vector2) -> void:
	if opened != str(row.key): return
	popup = row.duplicate(true); anchor = centre; bounds = vertical_bounds

## An owner can lay out a complete dialog while retaining ordinary release/cancel ownership.
func option(option: Dictionary, centre: Vector2, size: Vector2) -> void:
	var target := _button({"kind": "choose", "key": opened, "value": option.value}, _option_label(option),
		centre, size, null, same(popup.value, option.value))
	var node: MeshInstance3D = menu._buttons.back().node
	node.position.z = 0.036; node.material_override.render_priority = 31
	(node.get_child(0) as Label3D).render_priority = 32
	_appearance(option)
	menu._tips[target] = menu.I18n.t(str(option.get("hint", "")))

func finish() -> void:
	if opened.is_empty(): return
	if popup.is_empty(): reset(); return
	# Fields behind the open list cannot consume its gaps or selection presses.
	for button in menu._buttons:
		if targets.has(button.target):
			var item: Dictionary = targets[button.target]
			button.enabled = item.kind == "open" and item.key == opened
	var options: Array = popup.choices
	var capacity := clampi(int(popup.get("rows", POPUP_ROWS)), 1, POPUP_ROWS)
	offset = clampi(offset, 0, maxi(0, options.size() - capacity))
	var count := mini(capacity, options.size())
	var header: String = str(popup.get("heading", ""))
	var footer: String = str(popup.get("footer", ""))
	var header_height := 0.065 if not header.is_empty() else 0.0
	var footer_height := (0.085 + 0.035 * footer.count("\n")) if not footer.is_empty() else 0.0
	var width := float(popup.get("width", 0.72))
	var height := count * PITCH + 0.055 + header_height + footer_height
	var top := anchor.y - 0.04
	if top - height < bounds.x: top = anchor.y + 0.04 + height
	top = clampf(top, bounds.x + height, bounds.y)
	var x := clampf(anchor.x, -0.39, 0.46)
	var panel: MeshInstance3D = menu._quad(Vector2(width, height), Vector3(x, top-height/2, 0.028), menu.PANEL, 30)
	menu.add_child(panel); menu._decorations.append(panel)
	if not header.is_empty():
		var heading: Label3D = menu._label(menu.I18n.t(header), Vector3(x, top - 0.032, 0.039), 20)
		heading.render_priority = 32
	for row_index in count:
		option(options[offset + row_index], Vector2(x, top - header_height - 0.039 - row_index*PITCH), Vector2(width - 0.07, 0.061))
	if not footer.is_empty():
		var hint: Label3D = menu._label(menu.I18n.t(footer), Vector3(x, top-height + footer_height / 2, 0.039), 16)
		hint.modulate = menu.MUTED; hint.render_priority = 32
	if options.size() > capacity:
		_button({"kind": "scroll", "step": -1}, "↑", Vector2(x-width/2+0.07, top-height+footer_height+0.016), Vector2(0.07, 0.03))
		menu._buttons.back().node.position.z = 0.038
		menu._buttons.back().node.material_override.render_priority = 31
		(menu._buttons.back().node.get_child(0) as Label3D).render_priority = 32
		_button({"kind": "scroll", "step": 1}, "↓", Vector2(x+width/2-0.07, top-height+footer_height+0.016), Vector2(0.07, 0.03))
		menu._buttons.back().node.position.z = 0.038
		menu._buttons.back().node.material_override.render_priority = 31
		(menu._buttons.back().node.get_child(0) as Label3D).render_priority = 32

func action(target: int) -> bool:
	if not targets.has(target): return false
	var item: Dictionary = targets[target]
	match item.kind:
		"nudge":
			if not menu._buttons.any(func(button): return button.target == target and button.enabled): return true
			var value := clampf(snappedf(float(item.value) + float(item.step), item.span.z), item.span.x, item.span.y)
			changed.emit(str(item.key), _scoped_value(item, value))
			menu.refresh()
		"reset":
			if not menu._buttons.any(func(button): return button.target == target and button.enabled): return true
			changed.emit(str(item.key), _scoped_value(item, item.value))
			menu.refresh()
		"open":
			opened = "" if opened == item.key else str(item.key)
			offset = 0; menu.refresh()
		"choose":
			var key: String = item.key
			var value: Variant = item.value
			reset(); changed.emit(key, value); menu.refresh()
		"scroll":
			offset = clampi(offset + int(item.step), 0, maxi(0, popup.choices.size() - int(popup.get("rows", POPUP_ROWS)))); menu.refresh()
	return true

func press(hand: String, origin: Vector3, direction: Vector3, tracked: bool) -> bool:
	if not capture.is_empty(): return true
	var hit: Dictionary = menu.ray_hit(origin, direction) if tracked else {}
	var target := int(hit.get("target", -1))
	if not targets.has(target):
		if not opened.is_empty():
			reset(); menu.refresh()
			return target >= 100 or target < 0 # Consume outside content presses; navigation can proceed.
		return false
	capture = {"hand": hand, "target": target, "scope": scope, "item": targets[target].duplicate(true),
		"point": menu.control_point(hit), "plane": menu.control_plane(target), "offset": offset, "moved": false}
	if capture.item.kind == "slider":
		var slider: Dictionary = sliders[target]
		capture.left = slider.left
		capture.width = slider.width
		_preview_slider(capture.point)
	return true

func update(hand: String, origin: Vector3, direction: Vector3, tracked: bool) -> void:
	if capture.is_empty() or capture.hand != hand: return
	if not tracked or not menu.visible or capture.scope != scope:
		if not _finish_slider(): capture.clear()
		return
	var point: Variant = _capture_point(origin, direction)
	if point == null:
		if not _finish_slider(): capture.clear()
		return
	if capture.item.kind == "slider":
		_preview_slider(point)
		return
	var delta: Vector2 = Vector2(point.x-capture.point.x, point.y-capture.point.y)
	if delta.length() > 0.018: capture.moved = true
	if capture.moved and not opened.is_empty() and not popup.get("all_visible", false):
		var next := clampi(int(capture.offset) + roundi(delta.y / PITCH), 0, maxi(0, popup.choices.size()-int(popup.get("rows", POPUP_ROWS))))
		if next != offset: offset = next; menu.refresh()

func _capture_point(origin: Vector3, direction: Vector3) -> Variant:
	return menu.project_pointer(origin, direction, capture.plane)

func release(hand: String, origin: Vector3, direction: Vector3, tracked: bool) -> void:
	if capture.is_empty() or capture.hand != hand: return
	if _finish_slider(): return
	var request := capture.duplicate(true)
	capture.clear()
	if not tracked or not menu.visible or request.scope != scope or request.moved: return
	var hit: Dictionary = menu.ray_hit(origin, direction)
	if int(hit.get("target", -1)) != request.target or targets.get(request.target, {}) != request.item: return
	var point: Vector3 = menu.control_point(hit)
	if Vector2(point.x-request.point.x, point.y-request.point.y).length() > 0.018: return
	action(int(request.target))

func cancel(hand: String) -> void:
	if capture.get("hand", "") == hand:
		if not _finish_slider(): capture.clear()

func stick_scroll(y: float, delta: float) -> bool:
	if opened.is_empty(): return false
	if popup.get("all_visible", false): return true
	if not capture.is_empty() or not is_finite(y) or absf(y) < 0.3: return true
	scroll -= y*delta*7
	if absf(scroll) >= 1:
		offset = clampi(offset + int(scroll), 0, maxi(0, popup.choices.size()-int(popup.get("rows", POPUP_ROWS)))); scroll -= int(scroll); menu.refresh()
	return true
