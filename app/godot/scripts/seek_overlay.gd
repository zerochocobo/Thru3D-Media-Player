extends Node3D
## Passive, camera-relative seek feedback. It never captures rays or opens the transport.
const Feedback := preload("res://scripts/seek_feedback.gd")
const Ui := preload("res://scripts/ray_menu.gd")
const BACKGROUND := preload("res://shaders/seek_overlay.gdshader")
const DEPTH := 1.2
const WIDTH := 0.60
var source: Callable
var clock: Label3D
var detail: Label3D
var fill: MeshInstance3D
var origin: MeshInstance3D
var thumb: MeshInstance3D
var _surfaces: Array[MeshInstance3D] = []
var _colors: Array[Color] = []

func _ready() -> void:
	var plate := _quad(Vector2(0.67, 0.135), Vector3.ZERO, Color(0.025, 0.035, 0.045, 0.78), 120)
	plate.material_override = ShaderMaterial.new(); plate.material_override.shader = BACKGROUND
	plate.material_override.render_priority = 120
	_quad(Vector2(WIDTH, 0.004), Vector3(0, 0, 0.001), Color(0.42, 0.47, 0.52, 0.85), 121)
	fill = _quad(Vector2(WIDTH, 0.004), Vector3(0, 0, 0.002), Ui.ACCENT, 122)
	origin = _quad(Vector2(0.005, 0.014), Vector3(0, 0, 0.003), Color(0.75, 0.78, 0.82, 0.8), 123)
	thumb = _quad(Vector2(0.012, 0.018), Vector3(0, 0, 0.004), Ui.ACCENT, 124)
	clock = _label(0.035, 36)
	detail = _label(-0.036, 30)
	refresh()

func _process(_delta: float) -> void: refresh()

func refresh() -> void:
	if not is_instance_valid(clock): return
	var sample: Dictionary = source.call() if source.is_valid() else {}
	visible = not sample.is_empty()
	if not visible: return
	position = placement(sample)
	# Face the binocular viewing centre, including when below a flat screen.
	basis = Basis.looking_at(position.normalized(), Vector3.UP)
	var duration := maxi(1, int(sample.duration_ms))
	var fraction := clampf(float(sample.target_ms) / duration, 0.0, 1.0)
	fill.mesh.size.x = maxf(0.001, WIDTH * fraction)
	fill.position.x = -WIDTH * 0.5 + WIDTH * fraction * 0.5
	fill.visible = fraction > 0.0
	origin.position.x = -WIDTH * 0.5 + WIDTH * clampf(float(sample.origin_ms) / duration, 0.0, 1.0)
	thumb.position.x = -WIDTH * 0.5 + WIDTH * fraction
	clock.text = "%s  →  %s / %s" % [Feedback.time(sample.origin_ms), Feedback.time(sample.target_ms), Feedback.time(duration)]
	detail.text = Feedback.offset(sample.delta_ms)
	if sample.phase == "waiting":
		var caption := str(sample.get("caption", ""))
		detail.text += "  ·  " + (caption if not caption.is_empty() else "…")
	var alpha := float(sample.alpha)
	for i in _surfaces.size():
		var tint := _colors[i]; tint.a *= alpha
		if _surfaces[i].material_override is ShaderMaterial:
			_surfaces[i].material_override.set_shader_parameter("tint", tint)
		else:
			_surfaces[i].material_override.albedo_color = tint
	for label in [clock, detail]:
		label.font = Ui.ui_font()
		label.modulate = Color(0.9, 0.95, 0.97, alpha)
		label.outline_modulate = Color(0.015, 0.02, 0.03, alpha * 0.7)
		# Keep long-hour counters and localized network feedback inside the strip.
		label.pixel_size = minf(0.0008, WIDTH / maxf(1.0, label.font.get_string_size(label.text, HORIZONTAL_ALIGNMENT_LEFT, -1, label.font_size).x))

static func placement(sample: Dictionary) -> Vector3:
	var result := Vector3(0, -0.28, -DEPTH)
	if sample.has("flat_anchor"):
		var anchor: Vector3 = sample.flat_anchor
		if anchor.is_finite() and anchor.z < -0.1:
			# A distant/huge/moved screen must not hide the HUD outside the current view.
			result.x = clampf(anchor.x * DEPTH / -anchor.z, -0.22, 0.22)
			result.y = clampf(anchor.y * DEPTH / -anchor.z, -0.40, -0.20)
	if sample.has("subtitle_y") and absf(result.y - float(sample.subtitle_y)) < 0.16:
		result.y = -0.44 if absf(-0.44 - float(sample.subtitle_y)) > absf(-0.16 - float(sample.subtitle_y)) else -0.16
	return result

func _quad(size: Vector2, location: Vector3, tint: Color, priority: int) -> MeshInstance3D:
	var node := MeshInstance3D.new(); node.mesh = QuadMesh.new(); node.mesh.size = size
	node.position = location
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.no_depth_test = true; material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.render_priority = priority; material.albedo_color = tint
	node.material_override = material
	add_child(node); _surfaces.append(node); _colors.append(tint)
	return node

func _label(y: float, size: int) -> Label3D:
	var label := Label3D.new(); label.position = Vector3(0, y, 0.006)
	label.font = Ui.ui_font(); label.font_size = size; label.pixel_size = 0.0008
	label.outline_size = 4; label.no_depth_test = true; label.render_priority = 125; label.outline_render_priority = 124
	add_child(label)
	return label
