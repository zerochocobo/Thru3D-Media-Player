extends RefCounted
const Bindings := preload("res://scripts/controller_bindings.gd")
const Demo := preload("res://scripts/gesture_demo.gd")
const I18n := preload("res://scripts/i18n.gd")
const INK := Color(0.93, 0.95, 0.98)
const MODE := 7000
const FILTER := 7010
const RESET_ALL := 7011
const SWAP := 7057
const CANCEL := 7058
const REPLAY := 7070
const BINDING_KEY := "control_binding/"
const SCOPE_KEY := "control_move_scope"
const GESTURES := [
	{"title": "Pinch to select", "kind": "select", "scope": "Menus", "hint": "Point, pinch, release"},
	{"title": "Show controls", "kind": "controls", "scope": "Menus hidden", "hint": "Pinch and release"},
	{"title": "Two-hand zoom", "kind": "zoom", "scope": "Flat photos", "hint": "Pinch with both hands and pull apart"},
	{"title": "Pinch to change photo", "kind": "swipe", "scope": "Single photo", "hint": "Pinch, slide sideways, release"},
	{"title": "Palm sweep", "kind": "palm", "scope": "Photo wall / shards", "hint": "Open palm, sweep sideways"},
	{"title": "Drag video picture", "kind": "drag", "scope": "Video", "hint": "Hold the pinch and move"}]
var menu: Node3D
var bindings := Bindings.new()
var mode := 0
var all_actions := false
var selected_gesture := 0
var pending: Dictionary = {}
var selection: Dictionary = {}
var notice := ""
var demo: Node3D

func _init(owner: Node3D) -> void: menu = owner

func active() -> bool:
	return menu.visible and menu.section == menu.Section.SETTINGS and menu.tab == menu.CONTROLS_TAB

func reset() -> void:
	pending.clear(); selection.clear(); notice = ""

func modal() -> bool:
	return not pending.is_empty() or not menu.choices.opened.is_empty()

func items() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if mode == 1:
		result.assign(GESTURES); return result
	if mode == 0:
		for fixed in [{"title": "Menu selection", "fixed": "Ray + trigger", "scope": "Menus"},
			{"title": "Show / hide controls", "fixed": "Menu / trigger tap", "scope": "All media"},
			{"title": "Hands / controllers", "fixed": "Shown with controls", "scope": "All media"},
			{"title": "Resize picture", "fixed": "Corner + trigger", "scope": "Flat media"},
			{"title": "Back", "fixed": "B / Y", "scope": "Menus"},
			{"title": "Close video and return", "fixed": "B / Y", "scope": "Video"}]: result.append(fixed)
	for item in bindings.definitions():
		if mode == 0 and not all_actions and item.defaults.is_empty() and not item.id.begins_with("move_"): continue
		if mode == 2 and (item.hold or not item.defaults.is_empty() or item.id in ["flat_volume_up", "flat_volume_down"]): continue
		var row: Dictionary = item.duplicate()
		if bindings.is_fixed(item.id): row["fixed"] = bindings.label(item.id)
		result.append(row)
	if mode == 0:
		result.append({"title": "Push away / pull closer", "fixed": "Grip + stick ↑ / ↓", "scope": "Interfaces / flat media"})
		result.append({"title": "Push away / pull closer", "fixed": "Trigger + stick ↑ / ↓", "scope": "Flat photos"})
		var ranks := {"play": 0, "Show / hide controls": 1, "Menu selection": 2, "Back": 3, "Close video and return": 4,
			"back10": 5, "forward10": 6, "flat_zoom_in": 7, "flat_zoom_out": 8, "zoom_in": 9, "zoom_out": 10,
			"volume_up": 11, "volume_down": 12, "Hands / controllers": 13, "Resize picture": 14}
		var order: Array = bindings.definitions().map(func(item): return item.id)
		result.sort_custom(func(a, b): return int(ranks.get(a.get("id", a.title), 20 + order.find(a.get("id", "")))) < int(ranks.get(b.get("id", b.title), 20 + order.find(b.get("id", "")))))
		result.append({"title": "Movement range", "move_scope": true, "scope": "All media"})
	return result

func action(target: int) -> bool:
	if not active(): return false
	if target in range(MODE, MODE + 3):
		menu.choices.reset(); mode = target - MODE; menu.scroll = 0; reset(); menu.refresh(); return true
	if target == FILTER:
		menu.choices.reset(); all_actions = not all_actions; menu.scroll = 0; reset(); menu.refresh(); return true
	if target == RESET_ALL:
		menu.choices.reset()
		if notice != "Restore all bindings?": reset(); notice = "Restore all bindings?"; menu._draw(); return true
		bindings.restore_all(); save(); reset(); menu.refresh(); return true
	if target == CANCEL:
		menu.choices.reset(); reset(); menu.refresh(); return true
	if target == SWAP and not pending.is_empty() and pending.can_swap:
		if bindings.swap_binding(str(pending.id), pending.binding, mode == 2).ok: save(); reset()
		menu.refresh(); return true
	if target == REPLAY:
		if is_instance_valid(demo): demo.show_phase(0)
		return true
	if target >= menu.ROW_BASE and target < menu.ROW_BASE + menu._drawn_slots():
		if modal(): return true
		var index: int = menu._first_line() + target - menu.ROW_BASE
		var rows := items()
		if index >= rows.size(): return true
		if mode == 1:
			selected_gesture = index; menu._draw(); return true
		var row: Dictionary = rows[index]
		if row.has("fixed"): return true
		# Build only this row's choices, and keep just one dialog alive.
		selection = scope_field() if row.has("move_scope") else binding_field(row.id)
		menu.choices.opened = str(selection.key); menu.choices.offset = 0
		menu._fling = 0.0; menu.refresh(); return true
	return false

func choose(key: String, value: Variant) -> bool:
	if not active(): return false
	if not pending.is_empty(): return key == SCOPE_KEY or key.begins_with(BINDING_KEY)
	if key == SCOPE_KEY:
		if value in ["panel", "media", "all"]: bindings.move_scope = value; save()
		reset(); return true
	if not key.begins_with(BINDING_KEY): return false
	var id := key.trim_prefix(BINDING_KEY)
	if bindings.definition(id).is_empty() or bindings.is_fixed(id): return true
	reset()
	if not value is String: return true
	if value == "__clear":
		bindings.clear(id, mode == 2); save(); return true
	if value == "__default":
		if bindings.restore_one(id): save()
		else: notice = "Default binding is in use"
		return true
	var parts: PackedStringArray = value.split("/")
	if parts.size() != 2: return true
	commit(id, Bindings.bind(parts[0], parts[1], Bindings.MODIFIERS if mode == 2 else []))
	return true

func commit(id: String, candidate: Dictionary) -> void:
	var result := bindings.assign(id, candidate, mode == 2)
	if result.ok:
		# One selection replaces the chord; retain any independent basic binding.
		if mode == 2:
			bindings.overrides[id] = bindings.bindings(id).filter(func(binding): return binding.modifiers.is_empty() or binding == candidate)
		save(); reset()
	else:
		notice = result.get("error", "Binding in use")
		if result.has("conflicts"):
			pending = {"id": id, "binding": candidate, "conflicts": result.conflicts,
				"can_swap": bindings.swap_binding(id, candidate, mode == 2, false).ok}
			notice = "Binding in use"

func save() -> void: menu.setting_changed.emit("controller_bindings", bindings.snapshot())

func combination_hint() -> String:
	return I18n.t("Grip + trigger") + (" + ?" if I18n.language == "en" else "＋?")

func binding_summary(id: String) -> String:
	if mode != 2: return bindings.label(id, false)
	var current: Array = bindings.bindings(id).filter(func(binding): return not binding.modifiers.is_empty())
	return I18n.t("Unassigned") if current.is_empty() else " / ".join(current.map(func(binding): return I18n.t("Right hand" if binding.hand == "right_hand" else "Left hand") + " · " + Bindings.input_name(binding.input, binding.hand)))

func scope_field() -> Dictionary:
	return {"key": SCOPE_KEY, "value": bindings.move_scope, "choices": [
		{"value": "panel", "label": "This panel"}, {"value": "media", "label": "Picture + controls"}, {"value": "all", "label": "All interfaces"}], "heading": "Movement range", "all_visible": true}

func binding_field(id: String) -> Dictionary:
	if bindings.is_fixed(id): return {}
	var item := bindings.definition(id)
	var advanced := mode == 2
	var options: Array = [{"value": "__clear", "label": "Unassigned"}]
	if not advanced: options.append({"value": "__default", "label": "Restore defaults"})
	var inputs: Array = ["trigger_click"] if item.hold else (Bindings.BUTTONS + Bindings.AXES)
	if advanced: inputs = ["ax_button", "by_button", "primary_click"] + Bindings.AXES
	for hand in ["right_hand", "left_hand"]:
		for input in inputs:
			# Reserved inputs (plain B/Y navigates back) are not offered; chords stay independent of ordinary buttons.
			var candidate := Bindings.bind(hand, input, Bindings.MODIFIERS if advanced else [])
			if bindings.clean_binding(candidate, id).is_empty(): continue
			var caption := Bindings.input_name(input, hand)
			if input in Bindings.AXES: caption = I18n.t("Stick direction") + " " + caption
			options.append({"value": hand + "/" + input, "label": caption, "hand": hand})
	var current: Array = bindings.bindings(id).filter(func(binding): return not binding.modifiers.is_empty() if advanced else binding.modifiers.is_empty())
	var value := "__clear" if current.is_empty() else "__multiple"
	if current.size() == 1: value = current[0].hand + "/" + current[0].input
	return {"key": BINDING_KEY + id, "value": value, "choices": options,
		"heading": item.title, "context": Bindings.scope_name(item.scope), "all_visible": true,
		"prefix": combination_hint() if advanced else ""}

func draw() -> void:
	demo = null
	menu.choices.begin("controls/" + str(mode), Vector2(-0.40, 0.20))
	if not selection.is_empty():
		if menu.choices.opened == str(selection.key):
			menu.choices.present(selection, Vector2.ZERO, Vector2(-0.55, 0.37))
			draw_selection(); menu._update_highlights(); return
		selection.clear()
	for i in 3:
		menu._button(MODE + i, I18n.t(["Controllers", "Gestures", "Combinations"][i]), Vector2(-0.31 + i * 0.29, 0.35), Vector2(0.275, 0.065), true, "", mode == i)
		menu.set_label_size(menu._buttons.back().node.get_child(0), 18)
	if mode != 1:
		menu._glyph(RESET_ALL, "refresh", Vector2(0.77, 0.35), 0.065, true, I18n.t("Restore defaults"))
		if mode == 0 and pending.is_empty():
			menu._button(FILTER, I18n.t("All actions" if not all_actions else "Common actions"), Vector2(0.59, -0.50), Vector2(0.36, 0.06))
			menu.set_label_size(menu._buttons.back().node.get_child(0), menu.TEXT_BODY)
		header("Context", Vector2(-0.48, 0.235))
		header("Action", Vector2(-0.245, 0.235))
		var binding_title := I18n.t("Binding") + (" · " + combination_hint() if mode == 2 else "")
		header(binding_title, Vector2(0.24, 0.235), 0.49, false)
	var rows := items()
	menu._list = Node3D.new(); menu.add_child(menu._list); menu._decorations.append(menu._list)
	for slot in mini(menu._drawn_slots(), rows.size() - menu._first_line()):
		var row: Dictionary = rows[menu._first_line() + slot]
		var target: int = menu.ROW_BASE + slot
		var y := 0.15 - slot * 0.10
		if mode == 1:
			menu._button(target, "", Vector2(-0.29, y), Vector2(0.46, 0.087), true, "", selected_gesture == menu._first_line() + slot, menu._list)
			var node: Node3D = menu._buttons.back().node
			var selected: bool = selected_gesture == menu._first_line() + slot
			label(row.title, Vector2(-0.205, 0.015), 18, menu._buttons.back().foreground if selected else INK, node, 0.41)
			label(row.scope, Vector2(-0.205, -0.020), 16, menu._buttons.back().foreground if selected else INK, node, 0.41)
		else:
			menu._text_button(target, "", Vector2(0.12, y), Vector2(1.28, 0.087), not row.has("fixed") and not modal(), menu._list)
			var button: Dictionary = menu._buttons.back()
			var node: Node3D = menu._buttons.back().node
			if row.has("scope"):
				label(Bindings.scope_name(row.scope) if row.has("id") else I18n.t(row.scope), Vector2(-0.60, 0), 18, INK, node, 0.19, false)
			label(row.title, Vector2(-0.365, 0), 18, INK, node, 0.39)
			if row.has("fixed"):
				label(row.fixed, Vector2(0.12, 0), 18, INK, node, 0.49)
			else:
				var text: String = I18n.t({"panel": "This panel", "media": "Picture + controls", "all": "All interfaces"}.get(bindings.move_scope, "This panel")) if row.has("move_scope") else binding_summary(row.id)
				var value := label(text, Vector2(0.12, 0), menu.TEXT_BODY, INK, node, 0.49, false)
				button.hover_labels.append(value)
				menu._select_face(button, value, Vector2(0.347, 0), Vector2(0.49, 0.059))
				if value.text != text: menu._tips[target] = text
				button["choice_key"] = SCOPE_KEY if row.has("move_scope") else BINDING_KEY + row.id
	if mode == 1: draw_gesture()
	elif not notice.is_empty() and pending.is_empty():
		label(notice, Vector2(-0.48, -0.50), menu.TEXT_AUX, menu.ACCENT, menu, 0.64)
	elif mode == 0 and pending.is_empty():
		label("While gripping: ↑ away · ↓ closer", Vector2(-0.48, -0.50), menu.TEXT_AUX, menu.MUTED, menu, 0.80)
	elif mode == 2 and pending.is_empty():
		label("Same hand · either order", Vector2(-0.48, -0.50), menu.TEXT_AUX, menu.MUTED, menu, 0.80)
	if menu._max_scroll() > 0:
		var span: Vector2 = menu._bar_span()
		menu._button(menu.SCROLLBAR, "", Vector2(0.82, span.x - span.y / 2), Vector2(0.035, span.y), not modal())
		var height: float = span.y * menu._lines() / menu._line_count()
		menu._bar_thumb = menu._decoration(Vector2(0.01, height), Vector2(0.82, span.x - height / 2), menu.MUTED)
	menu._place_list()
	menu.choices.finish()
	if not pending.is_empty(): draw_conflict()
	menu._update_highlights()

func draw_selection() -> void:
	var scope := str(selection.key) == SCOPE_KEY
	var count: int = maxi(selection.choices.filter(func(option): return option.get("hand", "") == "left_hand").size(), selection.choices.filter(func(option): return option.get("hand", "") == "right_hand").size())
	var prefix := str(selection.get("prefix", ""))
	var body_top := 0.187 - (0.055 if not prefix.is_empty() else 0.0)
	var footer_y := body_top - count * 0.069 - 0.035
	var bottom := 0.0 if scope else footer_y - 0.057
	var width := 0.66 if scope else 1.20
	var panel: MeshInstance3D = menu._decoration(Vector2(width, 0.37 - bottom), Vector2(0.12, (0.37 + bottom) / 2), menu.PANEL)
	panel.position.z = 0.028; panel.material_override.render_priority = 30
	var title := I18n.t(selection.heading)
	if not scope: title = str(selection.context) + " · " + title
	selection_label(title, Vector2(0.12, 0.323), width - 0.15, menu.TEXT_TITLE, true)
	if scope:
		for index in selection.choices.size():
			menu.choices.option(selection.choices[index], Vector2(0.12, 0.235 - index * 0.075), Vector2(0.56, 0.06))
	else:
		if not prefix.is_empty(): selection_label(prefix, Vector2(0.12, 0.268), 1.04, 18)
		for column in 2:
			var hand: String = Bindings.HANDS[column]
			var x := -0.185 + column * 0.61
			selection_label(I18n.t("Left hand" if column == 0 else "Right hand"), Vector2(x, body_top + 0.068), 0.50, 18)
			var options: Array = selection.choices.filter(func(option): return option.get("hand", "") == hand)
			for index in options.size():
				menu.choices.option(options[index], Vector2(x, body_top - index * 0.069), Vector2(0.53, 0.059))
		var footer: Array = selection.choices.filter(func(option): return not option.has("hand"))
		for index in footer.size():
			menu.choices.option(footer[index], Vector2(0.12 + (index - (footer.size() - 1) / 2.0) * 0.55, footer_y), Vector2(0.51, 0.059))
	menu._glyph(CANCEL, "close", Vector2(0.12 + width / 2 - 0.04, 0.323), 0.045, true, I18n.t("Cancel"))
	var close: Dictionary = menu._buttons.back()
	close.node.position.z = 0.045; close.node.material_override.render_priority = 33
	close.node.get_child(1).material_override.render_priority = 34

func selection_label(text: String, point: Vector2, width: float, size: int, bold: bool = false) -> void:
	var font: Font = menu.ui_bold_font() if bold else menu.ui_font()
	var value: String = fit_bold(text, width, size) if bold else menu._fit_title(text, "", width, size)
	var caption: Label3D = menu._label(value, Vector3(point.x, point.y, 0.039), size)
	caption.font = font
	caption.render_priority = 32; caption.modulate = INK

func fit_bold(text: String, width: float, size: int) -> String:
	var font: Font = menu.ui_bold_font()
	if font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size * menu.TEXT_RASTER_SCALE).x * menu.TEXT_PIXEL_SIZE <= width: return text
	var end := text.length()
	while end > 0:
		end -= 1
		var value := text.substr(0, end) + "…"
		if font.get_string_size(value, HORIZONTAL_ALIGNMENT_LEFT, -1, size * menu.TEXT_RASTER_SCALE).x * menu.TEXT_PIXEL_SIZE <= width: return value
	return ""

func header(text: String, point: Vector2, width: float = 0.6, translate: bool = true) -> void:
	var value := I18n.t(text) if translate else text
	var caption := label(fit_bold(value, width, menu.TEXT_TITLE), point, menu.TEXT_TITLE, INK, menu, width, false)
	caption.font = menu.ui_bold_font()

func draw_conflict() -> void:
	for button in menu._buttons:
		if menu.choices.targets.has(button.target) or menu._row_target(button.target): button.enabled = false
	var panel: MeshInstance3D = menu._decoration(Vector2(1.12, 0.54), Vector2(0.12, -0.04), menu.PANEL)
	panel.position.z = 0.034; panel.material_override.render_priority = 30
	conflict_label(I18n.t("Binding conflict"), 0.16, menu.TEXT_TITLE)
	conflict_label(I18n.t(bindings.definition(pending.id).title) + " · " + bindings.label(pending.id, mode == 2), 0.09, 18)
	var occupied: String = " / ".join(pending.conflicts.map(func(id): return I18n.t(bindings.definition(id).title)))
	conflict_label(occupied + " · " + Bindings.describe(pending.binding), 0.025, 18)
	conflict_label(I18n.t("Swap these bindings?" if pending.can_swap else "Choose another button"), -0.07, 18)
	for index in 2:
		menu._button([CANCEL, SWAP][index], I18n.t(["Cancel", "Swap bindings"][index]), Vector2(-0.09 + index * 0.42, -0.205), Vector2(0.38, 0.065), index == 0 or pending.can_swap)
		var button: Dictionary = menu._buttons.back()
		button.node.position.z = 0.045; button.node.material_override.render_priority = 31
		var text: Label3D = button.node.get_child(0)
		menu.set_label_size(text, 18); text.render_priority = 32

func conflict_label(text: String, y: float, size: int) -> void:
	var node: Label3D = menu._label(menu._fit_title(text, "", 1.02, size), Vector3(0.12, y, 0.049), size)
	node.render_priority = 32; node.modulate = INK

func label(text: String, point: Vector2, size: int, color: Color, parent: Node3D = null, width: float = 0.6, translate: bool = true) -> Label3D:
	var value: String = I18n.t(text) if translate else text
	var result: Label3D = menu._label(menu._fit_title(value, "", width, size), Vector3(point.x, point.y, 0.008), size, parent if parent else menu)
	result.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT; result.modulate = color
	return result

func draw_gesture() -> void:
	var row: Dictionary = GESTURES[selected_gesture]
	menu._decoration(Vector2(0.68, 0.49), Vector2(0.38, -0.02), Color(0.045, 0.075, 0.085))
	demo = Demo.new(); demo.kind = row.kind; demo.position = Vector3(0.38, 0.0, 0.015)
	menu.add_child(demo); menu._decorations.append(demo)
	label(row.title, Vector2(0.07, 0.18), 20, INK, menu, 0.60)
	label(row.hint, Vector2(0.07, -0.20), 18, INK, menu, 0.60)
	label(row.scope, Vector2(0.07, -0.32), 18, menu.ACCENT, menu, 0.60)
	menu._glyph(REPLAY, "play", Vector2(0.71, -0.32), 0.065, true, I18n.t("Replay"))
