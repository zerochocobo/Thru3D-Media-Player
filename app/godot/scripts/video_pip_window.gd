extends "res://scripts/ray_menu.gd"
## A world-fixed crop of the current video. Controls use the same ray UI as playback.
signal requested(slot: int, operation: String, value: float)
const ZOOMS := [1.0, 1.5, 2.0, 3.0, 4.0, 6.0, 8.0]
const ASPECTS := [0.0, 16.0 / 9.0, 4.0 / 3.0, 1.0, 9.0 / 16.0]
const ASPECT_LABELS := ["Source aspect", "16:9", "4:3", "1:1", "9:16"]
var slot := 1
var zoom := 1.0
var size := Vector2(0.48, 0.27)
var crop_center := Vector2(0.5, 0.5)
var crop_basis := Basis.IDENTITY
var panorama := false
var controls := false
var zoom_open := false
var shape_open := false
var custom_shape := false
var source_aspect := 16.0 / 9.0
var selecting := false
var identified := false
var draw_order := 0
var hover_since := -1
var last_hover := -1
var frame: MeshInstance3D
var picture := ShaderMaterial.new()
var hole := ShaderMaterial.new()
var on_compositor := false
var image_mode := false
var image_loading := false
var image_error := false
var image_material := ShaderMaterial.new()
var _video_size := Vector2.ZERO

func show_image(texture: Texture2D) -> void:
	if not image_mode: _video_size = size
	image_mode = true; image_loading = false; image_error = false
	zoom_open = false; shape_open = false; selecting = false
	image_material.shader = preload("res://shaders/pip_image.gdshader")
	image_material.set_shader_parameter("image_texture", texture)
	var ratio := texture.get_width() / float(texture.get_height())
	# Start inside a comfortable envelope; corner dragging scales the complete image.
	var width := minf(0.48, 0.48 * ratio)
	size = Vector2(width, width / ratio)
	set_compositor(false); frame.visible = true; refresh()

func restore_video() -> void:
	image_loading = false; image_error = false
	if image_mode: size = _video_size
	image_mode = false
	image_material.set_shader_parameter("image_texture", null)
	set_compositor(false); refresh()

var controls_root: Node3D

func _ready() -> void:
	# Deliberately do not create ray_menu's full-size library backdrop.
	top_level = true
	frame = MeshInstance3D.new()
	frame.mesh = QuadMesh.new()
	picture.shader = preload("res://shaders/video_rvm_pair.gdshader")
	hole.shader = preload("res://shaders/video_layer_hole.gdshader")
	picture.render_priority = 2
	frame.material_override = picture
	frame.visible = false
	frame.set_meta("menu_eye_buffer", true)
	add_child(frame)
	controls_root = Node3D.new(); add_child(controls_root)
	refresh()

func composition_root() -> Node3D:
	return controls_root

func composition_visible() -> bool:
	return visible and is_instance_valid(controls_root) and controls_root.visible

func crop_span() -> Vector2:
	var span := Vector2(1.0, source_aspect * size.y / size.x) / (3.0 * zoom)
	return span / maxf(1.0, maxf(span.x, span.y))

func tangent() -> Vector2:
	return Vector2(1.0, size.y / size.x) * tan(deg_to_rad(30.0)) / zoom

func set_identified(value: bool) -> void:
	if identified != value: identified = value; refresh()

func aspect_index() -> int:
	var ratio := size.x / size.y
	if not custom_shape and absf(ratio / source_aspect - 1) < 0.005: return 0
	for i in range(1, ASPECTS.size()):
		if absf(ratio / ASPECTS[i] - 1) < 0.005: return i
	return -1

func _option(target: int, text: String, centre: Vector2, button_size: Vector2, selected: bool) -> void:
	_button(target, text, centre, button_size)
	var button: Dictionary = _buttons.back()
	button["selected"] = selected
	if not selected: return
	button.base_color = Color(0.12, 0.25, 0.23)
	button.node.material_override.set_shader_parameter("surface_color", button.base_color)
	for edge in [Vector4(0, button_size.y / 2, button_size.x, 0.003), Vector4(0, -button_size.y / 2, button_size.x, 0.003),
		Vector4(-button_size.x / 2, 0, 0.003, button_size.y), Vector4(button_size.x / 2, 0, 0.003, button_size.y)]:
		button.node.add_child(_quad(Vector2(edge.z, edge.w), Vector3(edge.x, edge.y, 0.002), ACCENT, 12))
	_icon("check", Vector3(button_size.x / 2 - 0.008, button_size.y / 2 - 0.008, 0.005), 0.015, Color.WHITE, button.node)

func set_aspect(index: int) -> void:
	if image_mode or index < 0 or index >= ASPECTS.size(): return
	custom_shape = index != 0
	var ratio: float = ASPECTS[index] if custom_shape else source_aspect
	var width := minf(size.x, 1.2 * ratio)
	set_size(Vector2(width, width / ratio)); crop_parameters()

func _draw() -> void:
	_clear_layout()
	if not frame: return
	controls_root.visible = controls or selecting or zoom_open or shape_open
	frame.mesh.size = size
	var color := ACCENT if selecting or identified else Color(0.26, 0.32, 0.37)
	for edge in [Vector4(0, size.y / 2, size.x + 0.008, 0.004), Vector4(0, -size.y / 2, size.x + 0.008, 0.004),
		Vector4(-size.x / 2, 0, 0.004, size.y), Vector4(size.x / 2, 0, 0.004, size.y)]:
		var border := _quad(Vector2(edge.z, edge.w), Vector3(edge.x, edge.y, 0.001), color, 3)
		add_child(border); _decorations.append(border)
	if not controls_root.visible:
		set_draw_order(draw_order); return
	for corner in 4:
		var p := corner_point(corner)
		var handle := _quad(Vector2.ONE * 0.018, Vector3(p.x, p.y, 0.003), ACCENT, 4)
		add_child(handle); _decorations.append(handle)
	for edge in (0 if image_mode else 4):
		var p := edge_point(edge)
		var handle := _quad(Vector2(0.024, 0.008) if edge < 2 else Vector2(0.008, 0.024), Vector3(p.x, p.y, 0.003), ACCENT, 4)
		add_child(handle); _decorations.append(handle)
	var ui_start := _decorations.size()
	var y := -size.y / 2 - 0.048
	var bar_width := 0.28 if image_mode else 0.48
	var bar := _quad(Vector2(bar_width, 0.084), Vector3(0, y, 0.001), PANEL, 10)
	add_child(bar); _decorations.append(bar); _block_rays(bar, bar.mesh.size)
	controls_root.set_meta("menu_surface_bounds", Rect2(Vector2(-bar_width / 2, y - 0.045), Vector2(bar_width, 0.09)))
	var badge := _label(str(slot), Vector3(-bar_width / 2 - 0.025, y, 0.004), 20)
	# Glyph meshes can arrive after the initial capture bounds are measured.
	badge.set_meta("menu_capture_bounds", AABB(Vector3(-0.02,-0.02,0),Vector3(0.04,0.04,0.001)))
	_glyph(1, "close", Vector2(-0.09 if image_mode else -0.195, y), 0.064, true, I18n.t("Close window %d") % slot)
	# The mode switch stays at the same point when the toolbar changes mode.
	_glyph(6 if image_mode else 5, "video" if image_mode else "image", Vector2(0, y), 0.064,
		image_mode or not image_loading, I18n.t("Switch to video mode" if image_mode else "Switch to image mode"))
	if image_mode:
		_glyph(5, "image", Vector2(0.09, y), 0.064, not image_loading, I18n.t("Replace image"))
	elif image_loading:
		_glyph(6, "video", Vector2(0.10, y), 0.064, true, I18n.t("Switch to video mode"))
	else:
		_glyph(2, "pick_region", Vector2(-0.10, y), 0.064, true, I18n.t("Select region"))
		_glyph(4, "aspect", Vector2(0.10, y), 0.064, true, I18n.t("Aspect ratio"))
		_button(3, "%.1f×" % zoom, Vector2(0.19, y), Vector2(0.09, 0.055))
	if image_loading or image_error:
		_label(I18n.t("Loading…" if image_loading else "Image unavailable"), Vector3(0, y - 0.07, 0.004), 18)
	if zoom_open:
		var panel := _quad(Vector2(0.43, 0.072), Vector3(0, y - 0.082, 0.001), PANEL, 10)
		add_child(panel); _decorations.append(panel); _block_rays(panel, panel.mesh.size)
		for i in ZOOMS.size():
			_option(10 + i, str(ZOOMS[i]), Vector2((i - 3) * 0.06, y - 0.082), Vector2(0.055, 0.054), is_equal_approx(zoom, ZOOMS[i]))
	if shape_open:
		var panel := _quad(Vector2(0.52, 0.072), Vector3(0, y - 0.082, 0.001), PANEL, 10)
		add_child(panel); _decorations.append(panel); _block_rays(panel, panel.mesh.size)
		for i in ASPECTS.size():
			var caption := I18n.t(ASPECT_LABELS[i])
			if caption == "Source aspect": caption = "Source"
			_option(20 + i, caption, Vector2((i - 2) * 0.102, y - 0.082), Vector2(0.096, 0.054), aspect_index() == i)
	# Only controls enter the existing HD menu captures; video, frame and handles stay out.
	for node in _decorations.slice(ui_start) + _labels:
		node.reparent(controls_root, false)
	for button in _buttons: button.node.reparent(controls_root, false)
	set_draw_order(draw_order)

## Keep each window's picture and controls together, below the main ray menus (10+).
func set_draw_order(order: int) -> void:
	draw_order = clampi(order, 0, 2)
	picture.render_priority = draw_order * 3
	image_material.render_priority = draw_order * 3
	hole.render_priority = draw_order * 3
	for node in _decorations + _labels: _paint_order(node)
	for button in _buttons: _paint_order(button.node)

func set_compositor(value: bool) -> void:
	on_compositor = value and not image_mode
	if frame: frame.material_override = image_material if image_mode else (hole if value else picture)

func _paint_order(node: Node3D) -> void:
	if node is Label3D: node.render_priority = draw_order * 3 + 2
	elif node is MeshInstance3D and node.material_override:
		node.material_override.render_priority = draw_order * 3 + (2 if node.material_override is StandardMaterial3D else 1)
	for child in node.get_children():
		if child is Node3D: _paint_order(child)

func _activate(target: int) -> void:
	if image_mode and target not in [1, 5, 6]: return
	match target:
		5: requested.emit(slot, "image", 0)
		6: requested.emit(slot, "video", 0)
		1: requested.emit(slot, "close", 0)
		2: requested.emit(slot, "select", 0)
		3: zoom_open = not zoom_open; shape_open = false; refresh()
		4: shape_open = not shape_open; zoom_open = false; refresh()
		_:
			if target >= 10 and target < 10 + ZOOMS.size():
				zoom_open = false
				requested.emit(slot, "zoom", ZOOMS[target - 10])
			elif target >= 20 and target < 20 + ASPECTS.size():
				shape_open = false; set_aspect(target - 20); refresh(); requested.emit(slot, "shape", 0)

func corner_point(index: int) -> Vector2:
	return size * Vector2(-0.5 if index % 2 == 0 else 0.5, 0.5 if index < 2 else -0.5)

func edge_point(index: int) -> Vector2:
	return [Vector2(0, size.y / 2), Vector2(0, -size.y / 2), Vector2(-size.x / 2, 0), Vector2(size.x / 2, 0)][index]

func plane_point(origin: Vector3, direction: Vector3) -> Variant:
	if not origin.is_finite() or not direction.is_finite(): return null
	var inverse := global_transform.affine_inverse()
	var start := inverse * origin
	var ray := inverse.basis * direction
	if ray.z >= -0.00001: return null
	var distance := -start.z / ray.z
	return start + ray * distance if distance > 0 and distance * direction.length() <= ray_max_distance else null

func window_hit(origin: Vector3, direction: Vector3) -> Dictionary:
	if not visible: return {}
	var p: Variant = plane_point(origin, direction)
	if p == null: return {}
	var point := Vector2(p.x, p.y)
	var corner := -1
	for i in 4:
		if point.distance_to(corner_point(i)) < 0.027: corner = i
	var edge := -1
	if not image_mode and controls and corner < 0:
		for i in 4:
			if point.distance_to(edge_point(i)) < 0.027: edge = i
	# Includes the invisible corridor between picture, toolbar and zoom choices.
	var below := 0.18 if zoom_open or shape_open else 0.095
	var width := maxf(size.x, 0.55)
	if corner < 0 and edge < 0 and not Rect2(Vector2(-width / 2, -size.y / 2 - below), Vector2(width, size.y + below)).has_point(point): return {}
	return {"point": p, "corner": corner, "edge": edge, "body": absf(p.x) <= size.x / 2 and absf(p.y) <= size.y / 2,
		"distance": origin.distance_to(to_global(p))}

func hover(active: bool, now: int) -> void:
	if active:
		last_hover = now
		if hover_since < 0: hover_since = now
	else: hover_since = -1
	var wanted := image_loading or image_error or selecting or zoom_open or shape_open or (active and now - hover_since >= 150) or (controls and now - last_hover < 600)
	if wanted != controls:
		controls = wanted; refresh()

func set_size(value: Vector2) -> void:
	if size.is_equal_approx(value): return
	size = value; refresh()

func pointer_hit(origin: Vector3, direction: Vector3) -> Dictionary:
	var button := ray_hit(origin, direction)
	if not button.is_empty(): return button
	var body := window_hit(origin, direction)
	if not body.is_empty(): body["target"] = NONE
	return body

func crop_parameters(candidate: Dictionary = {}) -> void:
	var center: Vector2 = candidate.get("center", crop_center)
	var basis: Basis = candidate.get("basis", crop_basis)
	var span := crop_span()
	center = center.clamp(span / 2, Vector2.ONE - span / 2)
	picture.set_shader_parameter("pip_enabled", true)
	picture.set_shader_parameter("pip_center", center)
	picture.set_shader_parameter("pip_span", span)
	picture.set_shader_parameter("pip_forward", -basis.z)
	picture.set_shader_parameter("pip_right", basis.x)
	picture.set_shader_parameter("pip_up", basis.y)
	picture.set_shader_parameter("pip_tangent", tangent())
	var eye: Variant = picture.get_shader_parameter("viewing_eye")
	picture.set_shader_parameter("pip_viewing_eye", maxi(1, int(eye) if eye != null else 0))
	picture.set_shader_parameter("separate_subtitles", true)
