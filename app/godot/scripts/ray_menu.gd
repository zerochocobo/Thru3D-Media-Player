extends Node3D

signal session_control_requested(operation: String)
signal placement_changed
signal composition_changed
signal composition_layout_changed

const PAGE_SIZE := 7
const NONE := -1
const PREVIOUS := -2
const NEXT := -3
const CLOSE := -4
const MAX_RAY_METRES := 5.0
var ray_max_distance := MAX_RAY_METRES
var scene_overlay := false
static var _overlay_shaders: Dictionary = {}
const FOLLOW := -1001
const TEMP_PASSTHROUGH := -1002
const FOOTER_DIAMETER := 0.09
const FOOTER_HIT_SIZE := 0.105
const FOOTER_GAP := 0.025
const STATUS_WIDTH := 0.30
const SURFACE := preload("res://shaders/menu_surface.gdshader")
const Icons := preload("res://scripts/menu_icons.gd")
const I18n := preload("res://scripts/i18n.gd")
const DeviceStatus := preload("res://scripts/device_status.gd")
const PANEL := Color(0.065, 0.075, 0.095, 0.98)
const TILE := Color(0.105, 0.12, 0.15, 1.0)
const ACCENT := Color(0.54, 0.93, 0.77)
const MUTED := Color(0.56, 0.62, 0.69)
## Rasterize twice as large, then prefilter when projected into an eye buffer. The logical
## typography and physical dimensions stay the same, including labels resized after creation.
const TEXT_RASTER_SCALE := 2
const TEXT_PIXEL_SIZE := 0.0012 / TEXT_RASTER_SCALE
const TEXT_BODY := 18
const TEXT_AUX := 16
const TEXT_TITLE := 20
const TEXT_PAGE_TITLE := 24
const BRACKET_FONT := preload("res://assets/fonts/cjk-brackets.otf")
const POINTER_LINE_PRIORITY := 126
const POINTER_DOT_PRIORITY := 127
# File names and the menu are often Chinese/Japanese: fall back to the system CJK font.
static var FONT: Font = _make_font()
static var _font_language := I18n.language
static var _bold_font: Font
static var _bold_font_language := ""
static var _title_cache := {}
static func _make_font(weight: int = 400) -> Font:
	var font := SystemFont.new()
	font.font_weight = weight
	var names := ["Noto Sans CJK SC", "Noto Sans SC", "Microsoft YaHei", "PingFang SC"]
	if I18n.language == "zh_Hant":
		names = ["Noto Sans CJK TC", "Noto Sans TC", "Microsoft JhengHei", "PingFang TC"]
	elif I18n.language == "ja":
		names = ["Noto Sans CJK JP", "Noto Sans JP", "Yu Gothic", "Meiryo", "Hiragino Sans"]
	font.font_names = PackedStringArray(names + ["sans-serif"])
	font.generate_mipmaps = true
	# Keep the engine's shared font untouched. Missing CJK/Latin characters must use the same
	# sampling policy as the chosen system font, including Android's theme/system fallback.
	var fallback := ThemeDB.fallback_font.duplicate() as FontFile
	fallback.generate_mipmaps = true
	font.fallbacks = [fallback]
	# Some headset system-font selections report CJK punctuation without drawable
	# glyphs. Give brackets an explicit, tiny OFL font before the system font chain.
	var brackets := BRACKET_FONT.duplicate() as FontFile
	brackets.generate_mipmaps = true
	brackets.fallbacks = [font]
	return brackets

static func ui_font() -> Font:
	if _font_language != I18n.language:
		_font_language = I18n.language
		FONT = _make_font()
	return FONT

static func ui_bold_font() -> Font:
	if _bold_font == null or _bold_font_language != I18n.language:
		_bold_font_language = I18n.language
		_bold_font = _make_font(700)
	return _bold_font

static func set_label_size(label: Label3D, logical_size: int) -> void:
	label.font_size = logical_size * TEXT_RASTER_SCALE
	label.pixel_size = TEXT_PIXEL_SIZE

static func text_width(text: String, logical_size: int) -> float:
	return ui_font().get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, logical_size * TEXT_RASTER_SCALE).x * TEXT_PIXEL_SIZE

var _buttons: Array[Dictionary] = []
var _labels: Array[Label3D] = []
var _hover: Dictionary = {}
var _pointers: Dictionary = {}
var _decorations: Array[Node3D] = []
## Modal surfaces stop rays in the gaps between their controls.
var _ray_blockers: Array[Dictionary] = []
## Passive surfaces stop the visual pointer without becoming clickable controls.
var _pointer_panels: Array[MeshInstance3D] = []
var _backdrop: MeshInstance3D
## Hover names of icon-only buttons (target -> text), shown over the hovered button.
var _tips: Dictionary = {}
var _tooltip: MeshInstance3D
## Battery and clock pill under the panel; kept across redraws.
var device_status: Node3D
var session_controls_provider: Callable
var _footer_state := {}
var _footer_centre := Vector2.ZERO
const SurfaceLayout := preload("res://scripts/menu_surface_layout.gd")
var _layout_eye: Variant = null
var _layout_up := Vector3.UP
var layout_head_provider: Callable
var _layout_following := false
var music_quick: RefCounted

func panel_centre() -> Vector3:
	return _backdrop.position if is_instance_valid(_backdrop) else Vector3.ZERO

## Store the viewer in menu space so refreshes cannot chase head motion during a click.
func set_layout_viewer(head: Transform3D, following: bool = false, orient: bool = true) -> void:
	if not is_inside_tree() or space_locked(): return
	var up := head.basis.y.normalized() if following else Vector3.UP
	if orient: global_transform = SurfaceLayout.facing(global_transform, head.origin, panel_centre(), up)
	_layout_following = following
	_layout_eye = to_local(head.origin)
	_layout_up = global_basis.inverse() * up
	arrange_surfaces()

func space_locked() -> bool:
	var node: Node = self
	while node is Node3D:
		if node.get_meta("space_locked", false): return true
		node = node.get_parent()
	return false

## Only explicit opens/layout changes refresh this reference; ordinary redraws keep it frozen.
func refresh_layout_reference() -> void:
	if not layout_head_provider.is_valid(): return
	var head: Variant = layout_head_provider.call()
	if head is Transform3D: set_layout_viewer(head, _layout_following, false)

func arrange_surfaces() -> void:
	pass

func panel_bounds() -> Rect2:
	var nodes: Array = [_backdrop]
	nodes.append_array(_labels); nodes.append_array(_decorations)
	for button in _buttons: nodes.append(button.node)
	return SurfaceLayout.bounds(nodes, self)

## Captures use the actual pressed plane, including angled popups and raised choice lists.
func control_plane(target: int) -> Transform3D:
	for button in _buttons:
		if button.target == target: return global_transform.affine_inverse() * button.node.global_transform
	return Transform3D.IDENTITY

func control_point(hit: Dictionary) -> Vector3:
	return control_plane(int(hit.target)).affine_inverse() * Vector3(hit.point)

func project_pointer(origin: Vector3, direction: Vector3, plane: Transform3D) -> Variant:
	if not origin.is_finite() or not direction.is_finite() or direction.length_squared() < 0.000001: return null
	var inverse := (global_transform * plane).affine_inverse()
	var start := inverse * origin
	var delta := inverse.basis * direction.normalized()
	if delta.z >= -0.00001 or start.z <= 0: return null
	return start + delta * (-start.z / delta.z)

func _ready() -> void:
	position = Vector3(0, -0.03, -1.55)
	_backdrop = _quad(Vector2(1.55, 1.08), Vector3.ZERO, PANEL, 10)
	add_child(_backdrop)
	visible = false

func toggle() -> void:
	if visible:
		dismiss()
	else:
		visible = true
		_reset_navigation()
		refresh()

func dismiss() -> void:
	if music_quick: music_quick.reset()
	visible = false
	_hover.clear()
	_hide_tooltip()
	for pointer in _pointers.values():
		pointer.line.visible = false
		pointer.dot.visible = false

func _reset_navigation() -> void:
	pass

func refresh() -> void:
	_draw()

func refresh_music_quick_controls() -> void:
	refresh()

func _activate(_target: int) -> void:
	pass

func _draw() -> void:
	pass

# Origins/directions are in world space, including recenter/origin/menu transforms. Each button is
# tested on its own plane, so panels may be angled (the library's side column); the nearest wins.
# "point" is in this menu's space.
func ray_hit(origin: Vector3, direction: Vector3) -> Dictionary:
	return _nearest_hit(origin, direction, _buttons + _ray_blockers)

func _nearest_hit(origin: Vector3, direction: Vector3, surfaces: Array, best: Dictionary = {}) -> Dictionary:
	if not visible or not origin.is_finite() or not direction.is_finite() or direction.length_squared() < 0.000001:
		return {}
	var ray := direction.normalized()
	for button in surfaces:
		if (not button.enabled and not button.get("hover_disabled", false)) or not button.node.is_visible_in_tree():
			continue
		var inverse: Transform3D = button.node.global_transform.affine_inverse()
		var start: Vector3 = inverse * origin
		var delta: Vector3 = inverse.basis * ray
		# Only the front face accepts input; parallel, rear and behind-origin hits fail.
		if delta.z >= -0.00001 or start.z <= 0.0:
			continue
		var local := start + delta * (-start.z / delta.z)
		var half: Vector2 = button.rect.size * 0.5
		var radius := minf(float(button.get("radius", 0.012)), minf(half.x, half.y))
		var corner := Vector2(absf(local.x), absf(local.y)) - (half - Vector2.ONE * radius)
		if corner.x > radius or corner.y > radius or corner.max(Vector2.ZERO).length() > radius:
			continue
		var world: Vector3 = button.node.global_transform * Vector3(local.x, local.y, 0)
		var distance := origin.distance_to(world)
		if distance > ray_max_distance or (not best.is_empty() and distance >= float(best.distance)):
			continue
		best = {"target": button.target, "point": to_local(world), "distance": distance, "enabled": button.enabled}
	return best

## Use the current mesh size/radius: backgrounds can resize or move on every refresh.
func pointer_hit(origin: Vector3, direction: Vector3) -> Dictionary:
	var surfaces: Array = []
	var panels: Array = [_backdrop]
	panels.append_array(_pointer_panels)
	if is_instance_valid(device_status): panels.append(device_status._pill)
	for panel in panels:
		if not is_instance_valid(panel): continue
		var size: Vector2 = panel.mesh.size
		surfaces.append({"target": NONE, "rect": Rect2(-size / 2, size), "enabled": false,
			"hover_disabled": true, "node": panel,
			"radius": panel.material_override.get_shader_parameter("corner_radius")})
	return _nearest_hit(origin, direction, surfaces, ray_hit(origin, direction))

func _block_rays(panel: MeshInstance3D, size: Vector2, radius: float = 0.025) -> void:
	_ray_blockers.append({"target": NONE, "rect": Rect2(-size / 2, size), "enabled": false,
		"hover_disabled": true, "node": panel, "radius": radius})

## Grabbing includes the panel's empty background without making it a clickable control.
func grab_hit(origin: Vector3, direction: Vector3) -> Dictionary:
	var hit := ray_hit(origin, direction)
	if not visible or not origin.is_finite() or not direction.is_finite() or direction.length_squared() < 0.000001: return hit
	var inverse := _backdrop.global_transform.affine_inverse()
	var start: Vector3 = inverse * origin
	var delta: Vector3 = inverse.basis * direction.normalized()
	if delta.z >= -0.00001 or start.z <= 0: return hit
	var local: Vector3 = start + delta * (-start.z / delta.z)
	var half: Vector2 = _backdrop.mesh.size / 2
	if absf(local.x) > half.x or absf(local.y) > half.y: return hit
	var world: Vector3 = _backdrop.global_transform * Vector3(local.x, local.y, 0)
	var distance := origin.distance_to(world)
	if distance > ray_max_distance or (not hit.is_empty() and float(hit.distance) <= distance): return hit
	return {"target": NONE, "point": to_local(world), "distance": distance, "enabled": false}

func update_pointer(hand: String, origin: Vector3, direction: Vector3, tracked: bool) -> void:
	if not visible:
		return
	if music_quick: music_quick.update(hand, origin, direction, tracked)
	var hit := pointer_hit(origin, direction) if tracked else {}
	_hover[hand] = int(hit.get("target", NONE))
	var valid := tracked and origin.is_finite() and direction.is_finite() and direction.length_squared() > 0.000001
	var endpoint := Vector3.ZERO
	if valid: endpoint = to_global(hit.point) if not hit.is_empty() else origin + direction.normalized() * ray_max_distance
	_draw_pointer(hand, origin, endpoint, valid, not hit.is_empty())
	_update_highlights()

func update_move_pointer(hand: String, origin: Vector3, point: Vector3, tracked: bool) -> void:
	_hover[hand] = NONE
	_draw_pointer(hand, origin, point, tracked and visible and origin.is_finite() and point.is_finite(), true)
	_update_highlights()

func _draw_pointer(hand: String, origin: Vector3, endpoint: Vector3, valid: bool, hit: bool) -> void:
	var pointer := _pointer(hand)
	pointer.line.visible = valid
	pointer.dot.visible = valid and hit
	if valid:
		var mesh: ImmediateMesh = pointer.line.mesh
		mesh.clear_surfaces()
		mesh.surface_begin(Mesh.PRIMITIVE_LINES)
		mesh.surface_add_vertex(to_local(origin))
		mesh.surface_add_vertex(to_local(endpoint) + Vector3(0, 0, 0.006))
		mesh.surface_end()
		if hit:
			pointer.dot.position = to_local(endpoint) + Vector3(0, 0, 0.008)

func cancel_pointer(hand: String) -> void:
	update_pointer(hand, Vector3.ZERO, Vector3.ZERO, false)

func press_pointer(hand: String, origin: Vector3, direction: Vector3, tracked: bool) -> bool:
	# Recompute at trigger time. A stale hover or the other hand cannot click.
	update_pointer(hand, origin, direction, tracked)
	var hit := ray_hit(origin, direction) if tracked else {}
	if hit.is_empty():
		return false
	_activate_hit(hit)
	return true

func _activate_hit(hit: Dictionary) -> void:
	if not hit.get("enabled", true): return
	if music_quick and music_quick.activate(int(hit.target)): return
	if _activate_footer(int(hit.target)): return
	_activate(int(hit.target))

func _activate_footer(target: int) -> bool:
	if target not in [FOLLOW, TEMP_PASSTHROUGH]: return false
	var state := _session_controls()
	if target == FOLLOW:
		session_control_requested.emit("follow")
	elif state.get("passthrough_visible", false) and not state.get("alpha", false):
		session_control_requested.emit("temporary_passthrough")
	refresh_session_controls(true)
	return true

func _set_backdrop(size: Vector2, centre: Vector2 = Vector2.ZERO) -> void:
	if _backdrop.get_meta("control_bar", false):
		_backdrop.remove_meta("control_bar"); _backdrop.remove_meta("menu_eye_buffer")
		_backdrop.material_override.render_priority = 10
		_backdrop.material_override.set_shader_parameter("keep_opacity", false)
		_backdrop.material_override.set_shader_parameter("surface_color", PANEL)
	_backdrop.mesh.size = size
	_backdrop.position = Vector3(centre.x, centre.y, 0)
	_backdrop.material_override.set_shader_parameter("surface_size", size)
	# All views, including modal/web/adjustment branches, get the same footer.
	_place_device_status(Vector2(centre.x, centre.y - size.y * 0.5 - 0.085))

func _clear_layout() -> void:
	if music_quick: music_quick.begin_layout()
	composition_layout_changed.emit()
	for button in _buttons:
		# A badge nested in another button's tile is freed with it.
		if is_instance_valid(button.node): button.node.free()
	_buttons.clear()
	_ray_blockers.clear()
	_pointer_panels.clear()
	for label in _labels:
		label.free()
	_labels.clear()
	for decoration in _decorations:
		decoration.free()
	_decorations.clear()
	_tips.clear()
	_footer_state.clear()
	if _tooltip:
		_tooltip.visible = false
	_hover.clear()
	for pointer in _pointers.values():
		pointer.dot.visible = false

func _button(target: int, text: String, centre: Vector2, size: Vector2, enabled: bool = true,
		icon: String = "", primary: bool = false, parent: Node3D = null) -> void:
	var base := ACCENT if primary else TILE
	var foreground := Color(0.045, 0.1, 0.085) if primary else Color(0.93, 0.95, 0.98)
	var node := _quad(size, Vector3(centre.x, centre.y, 0.002), base, 11)
	(parent if parent else self).add_child(node)
	var label := _label(text, Vector3(0, -size.y * 0.26 if not icon.is_empty() else 0, 0.004), TEXT_BODY, node)
	label.modulate = foreground if enabled else MUTED * Color(0.7, 0.7, 0.7)
	if not icon.is_empty():
		# Icon-only buttons centre a larger glyph; captioned buttons stack icon over text.
		var alone := text.is_empty()
		_icon(icon, Vector3(0, 0 if alone else size.y * 0.15, 0.004), minf(size.y * (0.55 if alone else 0.38), 0.05 if alone else 0.045),
			foreground if enabled else MUTED, node)
	_buttons.append({"target": target, "rect": Rect2(centre - size / 2, size), "enabled": enabled, "node": node,
		"base_color": base, "foreground": foreground})

## A ray hit area with no surface, material or empty caption. Only the supplied labels render.
func _text_button(target: int, text: String, centre: Vector2, size: Vector2, enabled: bool = true,
		parent: Node3D = null) -> void:
	var node := Node3D.new()
	node.position = Vector3(centre.x, centre.y, 0.006)
	(parent if parent else self).add_child(node)
	var foreground := Color(0.93, 0.95, 0.98)
	var hover_labels: Array[Label3D] = []
	if not text.is_empty():
		var caption := _label(text, Vector3.ZERO, TEXT_BODY, node)
		caption.modulate = foreground; hover_labels.append(caption)
	_buttons.append({"target": target, "rect": Rect2(centre - size / 2, size), "enabled": enabled,
		"node": node, "base_color": Color(TILE, 0), "foreground": foreground, "hover_labels": hover_labels})

## A select keeps one input target; its value and vector arrow share that target.
## Text-only table rows get a surface just behind the editable value column.
func _select_face(button: Dictionary, caption: Label3D, centre: Vector2, size: Vector2) -> void:
	set_label_size(caption, TEXT_BODY)
	caption.text = _fit_title(caption.text, "", maxf(0.01, size.x - 0.09), TEXT_BODY)
	caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	caption.position.x = centre.x - size.x / 2 + 0.018
	caption.position.y = centre.y
	if not button.node is MeshInstance3D:
		var surface := _quad(size, Vector3(centre.x, centre.y, caption.position.z - 0.003), TILE, caption.render_priority - 1)
		button.node.add_child(surface)
		button["select_surface"] = surface
	var arrow := _icon("chevron_down", Vector3(centre.x + size.x / 2 - 0.032, centre.y, caption.position.z), minf(0.040, size.y * 0.65), button.foreground, button.node)
	arrow.material_override.render_priority = caption.render_priority
	button["select_arrow"] = arrow
	button["select_caption"] = caption

## Icon-only round button (play, floating actions); [tip] names it while a ray hovers it.
func _round(target: int, icon: String, centre: Vector2, diameter: float, enabled: bool = true,
		primary: bool = false, tip: String = "") -> void:
	_button(target, "", centre, Vector2.ONE * diameter, enabled, icon, primary)
	_buttons.back().node.material_override.set_shader_parameter("corner_radius", diameter * 0.5)
	if not tip.is_empty():
		_tips[target] = tip

## Icon over the panel without a tile of its own: only hover lights it up.
func _glyph(target: int, icon: String, centre: Vector2, size: float, enabled: bool = true, tip: String = "") -> void:
	_button(target, "", centre, Vector2.ONE * size, enabled, icon)
	var button: Dictionary = _buttons.back()
	button.base_color = Color(TILE, 0.0)
	button.node.material_override.set_shader_parameter("corner_radius", size * 0.5)
	if not tip.is_empty():
		_tips[target] = tip

## Puts the battery and clock pill centred at [centre], under the panel like SKYBOX.
func _place_device_status(centre: Vector2) -> void:
	if not device_status:
		device_status = DeviceStatus.new()
		device_status.minimum_width = STATUS_WIDTH
		add_child(device_status)
	var bottom: float = _backdrop.position.y - _backdrop.mesh.size.y * 0.5
	_footer_centre = Vector2(centre.x, minf(centre.y - 0.025, bottom - 0.085))
	refresh_session_controls(true)
	if scene_overlay: _apply_overlay_node(device_status)

func _session_controls() -> Dictionary:
	return session_controls_provider.call() if session_controls_provider.is_valid() else {}

func refresh_session_controls(force: bool = false) -> void:
	if not device_status: return
	var state := _session_controls()
	if not force and state == _footer_state: return
	_footer_state = state.duplicate()
	for index in range(_buttons.size() - 1, -1, -1):
		if _buttons[index].target in [FOLLOW, TEMP_PASSTHROUGH]:
			_buttons[index].node.free()
			_buttons.remove_at(index)
	var show_passthrough: bool = state.get("passthrough_visible", false)
	var count := 2 if show_passthrough else 1
	var span := count * FOOTER_DIAMETER + (count - 1) * FOOTER_GAP
	var width := span + FOOTER_GAP + STATUS_WIDTH
	var left := _footer_centre.x - width * 0.5
	device_status.position = Vector3(left + span + FOOTER_GAP + STATUS_WIDTH * 0.5, _footer_centre.y, 0.002)
	_footer_button(FOLLOW, "head_follow", Vector2(left + FOOTER_DIAMETER * 0.5, _footer_centre.y),
		state.get("follow", false), true, I18n.t("Disable follow" if state.get("follow", false) else "Enable follow"))
	if show_passthrough:
		var alpha: bool = state.get("alpha", false)
		_footer_button(TEMP_PASSTHROUGH, "passthrough", Vector2(left + span - FOOTER_DIAMETER * 0.5, _footer_centre.y),
			state.get("passthrough", false), not alpha, I18n.t("Cannot switch during person passthrough" if alpha else
			("Disable temporary passthrough" if state.get("passthrough", false) else "Enable temporary passthrough")))
	_update_highlights()

func _footer_button(target: int, icon: String, centre: Vector2, active: bool, enabled: bool, tip: String) -> void:
	_round(target, icon, centre, FOOTER_DIAMETER, enabled, active, tip)
	var button: Dictionary = _buttons.back()
	button.rect = Rect2(centre - Vector2.ONE * FOOTER_HIT_SIZE * 0.5, Vector2.ONE * FOOTER_HIT_SIZE)
	button["hover_disabled"] = true
	button["tip_below"] = true
	if active:
		var marker := _quad(Vector2(0.014, 0.004), Vector3(0, -0.032, 0.005), button.foreground if enabled else MUTED, 12)
		button.node.add_child(marker)

func _decoration(size: Vector2, centre: Vector2, color: Color) -> MeshInstance3D:
	var node := _quad(size, Vector3(centre.x, centre.y, 0.003), color, 12)
	add_child(node)
	_decorations.append(node)
	return node

func _icon(key: String, location: Vector3, size: float, color: Color, parent: Node = self) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	var mesh := QuadMesh.new()
	mesh.size = Vector2.ONE * size
	node.mesh = mesh
	node.position = location
	var material := _material(color, 12)
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_texture = Icons.texture(key)
	node.material_override = material
	parent.add_child(node)
	if parent == self: _decorations.append(node)
	return node

func _quad(size: Vector2, location: Vector3, color: Color, priority: int) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	var mesh := QuadMesh.new()
	mesh.size = size
	node.mesh = mesh
	node.position = location
	var surface := ShaderMaterial.new()
	surface.shader = SURFACE
	surface.render_priority = priority
	surface.set_shader_parameter("surface_color", color)
	surface.set_shader_parameter("surface_size", size)
	surface.set_shader_parameter("corner_radius", 0.028 if priority == 10 else 0.012)
	node.material_override = surface
	_apply_overlay_node(node)
	return node

func _material(color: Color, priority: int, overlay: bool = false) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = color
	# Keep icons/thumbnails in the ordered UI pass without writing depth over other UI.
	# Only the interaction ray/reticle bypass the depth of tracked input models.
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	material.no_depth_test = overlay
	material.render_priority = priority
	material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	if scene_overlay:
		material.set_meta("menu_creation_depth", overlay)
		material.no_depth_test = true
	return material

func _label(text: String, location: Vector3, size: int, parent: Node = self) -> Label3D:
	var label := Label3D.new()
	label.text = text
	label.font = ui_font()
	label.language = I18n.language
	set_label_size(label, size)
	label.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	label.position = location
	label.no_depth_test = false
	label.render_priority = 12
	label.outline_size = 0
	parent.add_child(label)
	if parent == self:
		_labels.append(label)
	_apply_overlay_node(label)
	return label

## This opt-in policy belongs to one menu. Preserve each node's original depth
## setting and shader so leaving the cinema restores normal scene occlusion.
func set_scene_overlay(enabled: bool) -> void:
	scene_overlay = enabled
	apply_scene_overlay()

func apply_scene_overlay() -> void:
	_apply_overlay_node(self)

func _apply_overlay_node(node: Node) -> void:
	if node is Label3D:
		if scene_overlay:
			if not node.has_meta("menu_original_label_depth"): node.set_meta("menu_original_label_depth", node.no_depth_test)
			node.no_depth_test = true
		elif node.has_meta("menu_original_label_depth"):
			node.no_depth_test = node.get_meta("menu_original_label_depth")
			node.remove_meta("menu_original_label_depth")
	elif node is GeometryInstance3D and node.material_override:
		var material: Material = node.material_override
		if material is ShaderMaterial:
			if scene_overlay and material.shader and not node.has_meta("menu_original_shader"):
				var original: Shader = material.shader
				var key := original.get_instance_id()
				if not _overlay_shaders.has(key):
					var shader := Shader.new()
					shader.code = original.code if "depth_test_disabled" in original.code else original.code.replace("render_mode ", "render_mode depth_test_disabled, ")
					_overlay_shaders[key] = shader
				node.set_meta("menu_original_shader", original)
				var copy := material.duplicate() as ShaderMaterial
				copy.shader = _overlay_shaders[key]
				node.material_override = copy
			elif not scene_overlay and node.has_meta("menu_original_shader"):
				material.shader = node.get_meta("menu_original_shader")
				node.remove_meta("menu_original_shader")
		elif material is BaseMaterial3D:
			if scene_overlay:
				if not node.has_meta("menu_original_material_depth"):
					node.set_meta("menu_original_material_depth", material.get_meta("menu_creation_depth", material.no_depth_test))
					node.material_override = material.duplicate()
				node.material_override.no_depth_test = true
			elif node.has_meta("menu_original_material_depth"):
				material.no_depth_test = node.get_meta("menu_original_material_depth")
				node.remove_meta("menu_original_material_depth")
			elif material.has_meta("menu_creation_depth"):
				material.no_depth_test = material.get_meta("menu_creation_depth")
			if not scene_overlay and material.has_meta("menu_creation_depth"): material.remove_meta("menu_creation_depth")
	for child in node.get_children():
		_apply_overlay_node(child)

func _pointer(hand: String) -> Dictionary:
	if _pointers.has(hand):
		return _pointers[hand]
	var color := Color(0.15, 0.9, 1.0) if hand == "left_hand" else Color(1.0, 0.65, 0.15)
	var line := MeshInstance3D.new()
	line.mesh = ImmediateMesh.new()
	# Interaction feedback must draw after every popup, label and tooltip in the menu.
	line.material_override = _material(color, POINTER_LINE_PRIORITY, true)
	line.set_meta("menu_pointer", true)
	add_child(line)
	var dot := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.009
	sphere.height = 0.018
	dot.mesh = sphere
	dot.material_override = _material(color, POINTER_DOT_PRIORITY, true)
	dot.set_meta("menu_pointer", true)
	add_child(dot)
	_pointers[hand] = {"line": line, "dot": dot}
	return _pointers[hand]

func _update_highlights() -> void:
	var changed := false
	for button in _buttons:
		var hovered: bool = button.enabled and _hover.values().has(button.target)
		if button.has("select_arrow"):
			var ink: Color = (ACCENT if hovered and button.has("hover_labels") else button.foreground) if button.enabled else MUTED
			if button.select_arrow.material_override.albedo_color != ink:
				button.select_arrow.material_override.albedo_color = ink; changed = true
		if button.has("select_surface"):
			var fill := Color(0.23, 0.43, 0.38) if hovered else TILE
			if not button.enabled: fill = Color(0.085, 0.095, 0.115)
			if button.select_surface.material_override.get_shader_parameter("surface_color") != fill:
				button.select_surface.material_override.set_shader_parameter("surface_color", fill); changed = true
		if button.has("hover_labels"):
			var ink: Color = ACCENT if hovered else button.foreground
			if not button.enabled: ink = button.get("disabled_ink", MUTED)
			for caption: Label3D in button.hover_labels:
				if caption.modulate != ink: caption.modulate = ink; changed = true
			continue
		var color: Color = button.base_color
		if not button.enabled: color = Color(0.26, 0.44, 0.38) if button.get("hover_disabled", false) and button.base_color == ACCENT else Color(0.085, 0.095, 0.115, button.base_color.a)
		elif hovered: color = button.get("hover_color", Color(0.67, 1.0, 0.86) if button.base_color == ACCENT else Color(0.23, 0.43, 0.38))
		if button.node.material_override.get_shader_parameter("surface_color") != color:
			button.node.material_override.set_shader_parameter("surface_color", color)
			changed = true
	_update_tooltip()
	if changed: composition_changed.emit()

func _update_tooltip() -> void:
	var shown := {}
	var tip := ""
	for button in _buttons:
		if not button.node.is_visible_in_tree(): continue
		var candidate := tooltip_text(_tips.get(button.target))
		if not candidate.is_empty() and (button.enabled or button.get("hover_disabled", false)) and _hover.values().has(button.target):
			shown = button
			tip = candidate
			break
	if shown.is_empty():
		_hide_tooltip()
		return
	if not _tooltip:
		_tooltip = _quad(Vector2(0.2, 0.05), Vector3.ZERO, Color(0.02, 0.025, 0.03, 0.92), 40)
		_tooltip.set_meta("menu_tooltip", true)
		add_child(_tooltip)
		var text := _label("", Vector3(0, 0, 0.002), TEXT_BODY, _tooltip)
		text.render_priority = 41
	var label: Label3D = _tooltip.get_child(0)
	var changed := not _tooltip.visible or label.text != tip
	if changed:
		label.text = tip; label.font = ui_font()
		var width := minf(text_width(tip, TEXT_BODY) + 0.006, 0.86)
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		label.width = width / label.pixel_size
		var measured := ui_font().get_multiline_string_size(tip, HORIZONTAL_ALIGNMENT_CENTER, label.width, label.font_size, -1, TextServer.BREAK_MANDATORY | TextServer.BREAK_WORD_BOUND | TextServer.BREAK_ADAPTIVE)
		_tooltip.mesh.size = Vector2(width + 0.04, maxf(0.046, measured.y * label.pixel_size + 0.02))
		_tooltip.material_override.set_shader_parameter("surface_size", _tooltip.mesh.size)
	var size: Vector2 = _tooltip.mesh.size
	var rect: Rect2 = shown.rect
	# List tiles move with their scrolling parent; use their actual menu-space centre.
	var surface: Node3D = self
	var parent: Node = shown.node.get_parent()
	while parent != self and parent is Node3D:
		if parent.has_meta("menu_surface_bounds"): surface = parent; break
		parent = parent.get_parent()
	if _tooltip.get_parent() != surface: _tooltip.reparent(surface, false)
	_tooltip.basis = Basis.IDENTITY
	var centre := surface.to_local(shown.node.global_position)
	var bounds: Rect2 = surface.get_meta("menu_surface_bounds") if surface != self else Rect2(Vector2(_backdrop.position.x, _backdrop.position.y) - _backdrop.mesh.size / 2, _backdrop.mesh.size)
	var x := clampf(centre.x, bounds.position.x + size.x * 0.5, bounds.end.x - size.x * 0.5) if bounds.size.x >= size.x else bounds.get_center().x
	_tooltip.position = Vector3(x, centre.y + (-1 if shown.get("tip_below", false) else 1) * (rect.size.y * 0.5 + size.y * 0.5 + 0.017), 0.012)
	_tooltip.visible = true
	if changed: composition_layout_changed.emit()

## Dynamic filenames and optional metadata can bypass _round/_glyph's empty-string guard.
## Decide in the shared renderer so no menu can draw an empty background or stale caption.
static func tooltip_text(value: Variant) -> String:
	if not value is String and not value is StringName: return ""
	var text := str(value).replace("\u200b", "").replace("\ufeff", "").strip_edges()
	if text.replace("\u00a0", " ").replace("\u3000", " ").strip_edges().is_empty(): return ""
	return text

func _hide_tooltip() -> void:
	if _tooltip:
		var changed := _tooltip.visible
		_tooltip.visible = false
		(_tooltip.get_child(0) as Label3D).text = ""
		if changed: composition_changed.emit()

func _fit_title(title: String, suffix: String, width: float = 1.32, font_size: int = 26) -> String:
	var key := str([ui_font().get_instance_id(), I18n.language, title, suffix, width, font_size])
	if _title_cache.has(key): return _title_cache[key]
	var fits := func(text: String) -> bool:
		return text_width(text, font_size) <= width
	if title.is_empty() or fits.call(title + suffix):
		return _cache_title(key, title + suffix)
	# Longest prefix that fits with the ellipsis, by bisection: every measure shapes the text.
	var low := 0
	var high := title.length() - 1
	while low < high:
		var middle := (low + high + 1) / 2
		if fits.call(title.left(middle) + "…" + suffix):
			low = middle
		else:
			high = middle - 1
	return _cache_title(key, title.left(low) + "…" + suffix)

static func _cache_title(key: String, text: String) -> String:
	_title_cache[key] = text
	while _title_cache.size() > 256: _title_cache.erase(_title_cache.keys()[0])
	return text

func text_snapshot() -> String:
	var lines := PackedStringArray()
	for label in _labels:
		lines.append(label.text)
	for button in _buttons:
		lines.append(button.node.get_child(0).text)
	return "\n".join(lines)
