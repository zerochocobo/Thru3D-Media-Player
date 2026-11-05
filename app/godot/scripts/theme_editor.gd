extends RefCounted
## A draft-only editor, drawn in the existing library plane and ray capture system.
const Palette := preload("res://scripts/ui_theme.gd")
const Generator := preload("res://scripts/custom_palette.gd")
const PICKER := preload("res://shaders/color_picker.gdshader")
const BASE := 986600
const FIELD := BASE + 1
const HUE := BASE + 2
const APPLY := BASE + 3
const CANCEL := BASE + 4
const RESET := BASE + 5
const TABS := BASE + 10
const ACCENTS := BASE + 20
const TEXTS := BASE + 30
const FIELD_CENTRE := Vector2(-0.37, 0.0)
const FIELD_SIZE := Vector2(0.52, 0.40)
const HUE_CENTRE := Vector2(-0.37, -0.26)
const HUE_SIZE := Vector2(0.52, 0.07)
var menu: Node3D
var opened := false
var draft: Dictionary = {}
var role := "background"
var hue := 0.0
var harmony := -1
var capture: Dictionary = {}
var actions: Dictionary = {}
var preview: Array[Dictionary] = []
var wells: Dictionary = {}
var accent_wells: Array = []
var text_wells: Array = []
var accent_marks: Array = []
var field: MeshInstance3D
var field_marker: MeshInstance3D
var hue_marker: MeshInstance3D

func _init(owner: Node3D) -> void: menu = owner

func open() -> void:
	draft = Palette.custom_data.duplicate(true); role = "background"; capture.clear()
	harmony = 0 if draft.is_empty() else -1
	hue = Palette.custom_seeds(draft).background.h
	opened = true; menu.choices.reset(); menu._drag.clear(); menu._fling = 0.0
	menu.clear_pointer_visuals(); menu.refresh()

func close(redraw: bool = true) -> void:
	opened = false; capture.clear(); draft.clear(); actions.clear()
	if redraw: menu.refresh()

func _button(target: int, title: String, centre: Vector2, size: Vector2, action: Dictionary) -> Dictionary:
	actions[target] = action
	menu._button(target, menu.I18n.t(title), centre, size)
	return menu._buttons.back()

func _sample(parent: Node3D, centre: Vector2, size: Vector2, color: Color, priority: int = 14) -> MeshInstance3D:
	var node: MeshInstance3D = menu._quad(size, Vector3(centre.x, centre.y, 0.004), color, priority)
	parent.add_child(node)
	if parent == menu: menu._decorations.append(node)
	return node

func _label(title: String, point: Vector2, size: int = 18) -> Label3D:
	var label: Label3D = menu._label(menu.I18n.t(title), Vector3(point.x, point.y, 0.009), size)
	label.render_priority = 15
	return label

func _bind(node: Node, key: String) -> void: preview.append({"node": node, "key": key})

func draw() -> void:
	actions.clear(); preview.clear(); wells.clear(); accent_wells.clear(); text_wells.clear(); accent_marks.clear()
	field = null; field_marker = null; hue_marker = null
	menu._set_backdrop(Vector2(1.52, 1.08))
	_label("Custom theme", Vector2(0, 0.44), 24)
	var titles := ["Background color", "Accent color", "Text color"]
	for index in 3:
		var key: String = ["background", "accent", "text"][index]
		var button := _button(TABS + index, titles[index], Vector2(-0.49 + index * 0.49, 0.32), Vector2(0.43, 0.075), {"kind": "tab", "role": key})
		var caption: Label3D = button.node.get_child(0); caption.position.x = -0.03
		if role == key:
			button.base_color = menu.UiTheme.color("selected")
			button.node.material_override.set_shader_parameter("surface_color", button.base_color)
		wells[key] = _sample(button.node, Vector2(0.17, 0), Vector2(0.035, 0.035), Color.WHITE)
		wells[key].material_override.set_shader_parameter("corner_radius", 0.018)
		wells[key].material_override.set_shader_parameter("marker_outline", menu.UiTheme.color("muted"))
	if role != "text":
		var button := _button(FIELD, "", FIELD_CENTRE, FIELD_SIZE, {"kind": "field"})
		field = button.node
		field.material_override.shader = PICKER
		field.material_override.set_shader_parameter("surface_size", FIELD_SIZE)
		menu._apply_overlay_node(field)
		button.hover_color = button.base_color
		field_marker = _sample(field, Vector2.ZERO, Vector2(0.025, 0.025), Color.WHITE)
		field_marker.name = "PickerMarker"
		field_marker.material_override.set_shader_parameter("corner_radius", 0.013)
		field_marker.material_override.set_shader_parameter("marker_outline", Color.BLACK)
		field_marker.material_override.set_shader_parameter("marker_outline_width", 0.002)
		var strip := _button(HUE, "", HUE_CENTRE, HUE_SIZE, {"kind": "hue"})
		strip.node.material_override.shader = PICKER
		strip.node.material_override.set_shader_parameter("hue_strip", true)
		strip.node.material_override.set_shader_parameter("surface_size", HUE_SIZE)
		menu._apply_overlay_node(strip.node)
		strip.hover_color = strip.base_color
		hue_marker = _sample(strip.node, Vector2.ZERO, Vector2(0.012, 0.080), Color.WHITE)
		hue_marker.material_override.set_shader_parameter("marker_outline", Color.BLACK)
		hue_marker.material_override.set_shader_parameter("marker_outline_width", 0.002)
		menu._tips[FIELD] = menu.I18n.t("Choose color saturation and brightness")
		menu._tips[HUE] = menu.I18n.t("Hue")
	else:
		_button(TEXTS, "Auto", Vector2(-0.37, 0.14), Vector2(0.32, 0.075), {"kind": "text_auto"})
		for index in 4:
			var button := _button(TEXTS + 1 + index, "", Vector2(-0.53 + (index % 2) * 0.30, -0.02 - (index / 2) * 0.14), Vector2(0.22, 0.095), {"kind": "text", "index": index})
			var surface := _sample(button.node, Vector2.ZERO, Vector2(0.20, 0.075), Color.WHITE)
			surface.material_override.set_shader_parameter("marker_outline", menu.UiTheme.color("muted"))
			var label: Label3D = menu._label("Aa", Vector3(0, 0, 0.009), 22, button.node)
			label.render_priority = 15
			text_wells.append({"surface": surface, "label": label})
			menu._tips[TEXTS + 1 + index] = menu.I18n.t("Text color")
	# The preview changes in place; editing never recolors the picker or global UI.
	_bind(_sample(menu, Vector2(0.32, 0.035), Vector2(0.64, 0.36), Color.WHITE, 11), "panel")
	_bind(_label("Preview", Vector2(0.32, 0.15), 20), "text")
	_bind(_label("Text", Vector2(0.32, 0.085), 18), "muted")
	for index in 2:
		var centre := Vector2(0.16 + index * 0.32, -0.015)
		_bind(_sample(menu, centre, Vector2(0.25, 0.065), Color.WHITE, 12), "tile" if index == 0 else "accent")
		_bind(_label("Button" if index == 0 else "Selected", centre), "text" if index == 0 else "primary_ink")
	_bind(_sample(menu, Vector2(0.32, -0.09), Vector2(0.50, 0.008), Color.WHITE, 12), "track")
	_bind(_sample(menu, Vector2(0.22, -0.09), Vector2(0.30, 0.008), Color.WHITE, 13), "accent")
	var knob := _sample(menu, Vector2(0.37, -0.09), Vector2(0.025, 0.029), Color.WHITE)
	knob.material_override.set_shader_parameter("marker_outline", Color("17232c"))
	_label("Accent color", Vector2(0.32, -0.19), 16)
	for index in 6:
		var button := _button(ACCENTS + index, "", Vector2(0.055 + index * 0.106, -0.27), Vector2(0.075, 0.075), {"kind": "accent", "index": index})
		button.node.material_override.set_shader_parameter("corner_radius", 0.038)
		var disc := _sample(button.node, Vector2.ZERO, Vector2(0.055, 0.055), Color.WHITE)
		disc.material_override.set_shader_parameter("corner_radius", 0.028)
		disc.material_override.set_shader_parameter("marker_outline", menu.UiTheme.color("muted"))
		accent_wells.append(disc)
		var mark: MeshInstance3D = menu._icon("check", Vector3(0, 0, 0.009), 0.030, Color.WHITE, button.node)
		mark.material_override.render_priority = 15
		accent_marks.append(mark)
		menu._tips[ACCENTS + index] = menu.I18n.t("Suggested accent color")
	_button(RESET, "Reset", Vector2(-0.52, -0.43), Vector2(0.20, 0.075), {"kind": "reset"})
	_button(CANCEL, "Cancel", Vector2(0.22, -0.43), Vector2(0.20, 0.075), {"kind": "cancel"})
	var apply := _button(APPLY, "Apply", Vector2(0.51, -0.43), Vector2(0.20, 0.075), {"kind": "apply"})
	apply.base_color = menu.ACCENT
	apply.foreground = menu.UiTheme.color("primary_ink")
	apply.node.get_child(0).modulate = apply.foreground
	_refresh_colors()

func _refresh_colors() -> void:
	var seeds := Palette.custom_seeds(draft)
	var colors := Palette.custom_palette(draft)
	for item in preview:
		if item.node is Label3D: item.node.modulate = colors[item.key]
		else: item.node.material_override.set_shader_parameter("surface_color", colors[item.key])
	for key in wells:
		wells[key].material_override.set_shader_parameter("surface_color", colors.panel if key == "background" else colors[key])
	var accents := Generator.accents(seeds.background)
	for index in accent_wells.size():
		accent_wells[index].material_override.set_shader_parameter("surface_color", accents[index])
		accent_marks[index].visible = seeds.accent.is_equal_approx(accents[index])
		accent_marks[index].material_override.albedo_color = Palette.swatch_ink(accents[index])
	var texts := Generator.texts(seeds)
	for index in text_wells.size():
		text_wells[index].surface.material_override.set_shader_parameter("surface_color", colors.panel)
		text_wells[index].label.modulate = texts[index]
		_selection(TEXTS + 1 + index, seeds.text is Color and seeds.text.is_equal_approx(texts[index]))
	_selection(TEXTS, seeds.text is String)
	if is_instance_valid(field):
		var sample: Color = colors.panel if role == "background" else colors.accent
		field.material_override.set_shader_parameter("hue", hue)
		field.material_override.set_shader_parameter("contrast_floor", 4.5 if role == "accent" else 0.0)
		field.material_override.set_shader_parameter("background_luminance", Vector4(Generator.luminance(colors.panel), Generator.luminance(colors.tile), Generator.luminance(colors.hover), Generator.luminance(colors.selected)))
		field_marker.position.x = (sample.s - 0.5) * FIELD_SIZE.x
		field_marker.position.y = (sample.v - 0.5) * FIELD_SIZE.y
		hue_marker.position.x = (hue - 0.5) * HUE_SIZE.x
	menu.composition_changed.emit()

func _selection(target: int, selected: bool) -> void:
	for button in menu._buttons:
		if button.target != target: continue
		button.base_color = menu.UiTheme.color("selected" if target == TEXTS else "swatch_ring") if selected else menu.TILE
		button.node.material_override.set_shader_parameter("surface_color", button.base_color)

func _pick(point: Vector3, kind: String) -> void:
	var seeds := Palette.custom_seeds(draft)
	var sample: Color = seeds[role]
	if kind == "hue":
		hue = clampf(point.x / HUE_SIZE.x + 0.5, 0, 0.9999)
		# White and black carry no visible hue; moving the hue bar should show one.
		sample = Color.from_hsv(hue, maxf(sample.s, 0.18), maxf(sample.v, 0.12))
	else:
		sample = Color.from_hsv(hue, clampf(point.x / FIELD_SIZE.x + 0.5, 0, 1), clampf(point.y / FIELD_SIZE.y + 0.5, 0, 1))
	if seeds[role].is_equal_approx(sample): return
	seeds[role] = sample
	if role == "background" and harmony >= 0: seeds.accent = Generator.accents(sample)[harmony]
	if role == "accent": harmony = -1
	draft = seeds
	_refresh_colors()

func activate(target: int) -> bool:
	if not actions.has(target): return false
	var action: Dictionary = actions[target]
	match action.kind:
		"tab":
			role = action.role
			if role != "text":
				var seeds := Palette.custom_seeds(draft)
				hue = seeds[role].h
			menu.refresh()
		"accent":
			var seeds := Palette.custom_seeds(draft); harmony = int(action.index)
			seeds.accent = Generator.accents(seeds.background)[harmony]; draft = seeds
			if role == "accent": hue = seeds.accent.h
			_refresh_colors()
		"text", "text_auto":
			var seeds := Palette.custom_seeds(draft)
			seeds.text = "auto" if action.kind == "text_auto" else Generator.texts(seeds)[int(action.index)]
			draft = seeds; _refresh_colors()
		"reset":
			draft = {}; hue = Palette.ORIGINAL.panel.h; harmony = 0; _refresh_colors()
		"cancel": close()
		"apply":
			var saved := draft.duplicate(true)
			close(false); menu.setting_changed.emit(Palette.CUSTOM_KEY, saved); menu.refresh()
	return true

func press(hand: String, origin: Vector3, direction: Vector3, tracked: bool) -> bool:
	if not opened: return false
	if not capture.is_empty(): return true
	menu.update_pointer(hand, origin, direction, tracked)
	var hit: Dictionary = menu.ray_hit(origin, direction) if tracked else {}
	var target := int(hit.get("target", -1))
	if not hit.get("enabled", false) or not actions.has(target): return true
	capture = {"hand": hand, "target": target, "plane": menu.control_plane(target), "kind": actions[target].kind,
		"start": menu.control_point(hit), "draft": draft.duplicate(true), "hue": hue, "harmony": harmony}
	if capture.kind in ["field", "hue"]: _pick(menu.control_point(hit), capture.kind)
	return true

func update(hand: String, origin: Vector3, direction: Vector3, tracked: bool) -> void:
	if capture.get("hand", "") != hand: return
	var point: Variant = menu.project_pointer(origin, direction, capture.plane) if tracked else null
	if point == null: cancel(hand); return
	if capture.kind in ["field", "hue"]: _pick(point, capture.kind)

func release(hand: String, origin: Vector3, direction: Vector3, tracked: bool) -> void:
	if capture.get("hand", "") != hand: return
	if not tracked: cancel(hand); return
	var request := capture.duplicate(true)
	if request.kind in ["field", "hue"]:
		update(hand, origin, direction, tracked); capture.clear(); return
	capture.clear()
	var hit: Dictionary = menu.ray_hit(origin, direction)
	if int(hit.get("target", -1)) == int(request.target) and Vector2(menu.control_point(hit).x - request.start.x, menu.control_point(hit).y - request.start.y).length() <= 0.018:
		activate(int(request.target))

func cancel(hand: String) -> void:
	if capture.get("hand", "") != hand: return
	draft = capture.draft; hue = capture.hue; harmony = capture.harmony; capture.clear()
	_refresh_colors()
