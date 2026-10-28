extends Node3D
## Passive gauges using the existing seek HUD's materials and text. No pointer targets.
const Controls := preload("res://scripts/immersive_adjustments.gd")
var source: Callable
var rows: Array[Node3D] = []

class Gauge extends "res://scripts/seek_overlay.gd":
	const I18n := preload("res://scripts/i18n.gd")
	var sample := {}
	var minimum: Label3D
	var maximum: Label3D

	func _ready() -> void:
		super()
		for fraction in [0.0, 0.25, 0.5, 0.75, 1.0]:
			_quad(Vector2(0.002, 0.010), Vector3(WIDTH * (fraction - 0.5), 0, 0.003), Color(0.55, 0.62, 0.68, 0.85), 122)
		clock.font_size = 30; detail.font_size = 22
		minimum = _label(-0.036, 22); minimum.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		maximum = _label(-0.036, 22); maximum.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		minimum.position.x = -WIDTH * 0.5; maximum.position.x = WIDTH * 0.5
		refresh()

	func refresh() -> void:
		if not is_instance_valid(minimum): return
		visible = not sample.is_empty()
		if not visible: return
		var span: Vector2 = sample.span
		var fraction := clampf(inverse_lerp(span.x, span.y, float(sample.value)), 0.0, 1.0)
		var zero := inverse_lerp(span.x, span.y, 0.0)
		fill.mesh.size.x = maxf(0.001, WIDTH * absf(fraction - zero))
		fill.position.x = WIDTH * ((fraction + zero) * 0.5 - 0.5)
		fill.visible = not is_equal_approx(fraction, zero)
		origin.position.x = WIDTH * (zero - 0.5); detail.position.x = origin.position.x
		thumb.position.x = WIDTH * (fraction - 0.5)
		clock.text = I18n.t(sample.title) + "  " + Controls.value_text(sample.key, sample.value)
		minimum.text = "%+.0f%%" % span.x; maximum.text = "%+.0f%%" % span.y; detail.text = "0"
		var alpha: float = sample.alpha
		for i in _surfaces.size():
			var tint := _colors[i]; tint.a *= alpha
			if _surfaces[i].material_override is ShaderMaterial: _surfaces[i].material_override.set_shader_parameter("tint", tint)
			else: _surfaces[i].material_override.albedo_color = tint
		for label in [clock, detail, minimum, maximum]:
			label.font = Ui.ui_font()
			label.modulate = Color(0.9, 0.95, 0.97, alpha)
			label.outline_modulate = Color(0.015, 0.02, 0.03, alpha * 0.7)
		clock.pixel_size = minf(0.0008, WIDTH / maxf(1.0, clock.font.get_string_size(clock.text, HORIZONTAL_ALIGNMENT_LEFT, -1, clock.font_size).x))

func _ready() -> void:
	# Above the gaze leaves the transport, seek strip and subtitles available below.
	position = Vector3(0, 0.23, -1.2)
	basis = Basis.looking_at(position.normalized(), Vector3.UP)
	for index in 2:
		var gauge := Gauge.new(); add_child(gauge); gauge.set_process(false); rows.append(gauge)
	refresh()

func _process(_delta: float) -> void: refresh()

func refresh() -> void:
	var samples: Array = source.call() if source.is_valid() else []
	visible = not samples.is_empty()
	for index in rows.size():
		rows[index].sample = samples[index] if index < samples.size() else {}
		rows[index].position.y = (float(mini(samples.size(), 2) - 1) * 0.5 - index) * 0.155
		rows[index].refresh()
