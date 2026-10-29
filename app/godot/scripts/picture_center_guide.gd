extends Node3D
## Passive picture/head centre references. Reuses Main's capture and world-space media pose.
## Nothing here writes a picture transform, captures input or reserves a compositor layer.
signal aligned(hand: String)
const MARKER := preload("res://shaders/picture_center_guide.gdshader")
const ENTER_ANGLE := deg_to_rad(0.20)
const EXIT_ANGLE := deg_to_rad(0.50)
const SETTLE_MS := 160
const REARM_MS := 200
const COOLDOWN_MS := 750
const PULSE_MS := 280
const FADE_MS := 180
const HALF_SIZE := deg_to_rad(1.70)
const HAPTIC_AMPLITUDE := 0.10
const HAPTIC_DURATION := 0.018
var source: Callable
var ring: MeshInstance3D
var cross: MeshInstance3D
var identity := ""
var hand := ""
var holding := false
var joined := false
var opacity := 0.0
var _released_at := -1
var _near_at := -1
var _far_at := -1
var _pulse_at := -COOLDOWN_MS
var _last_sample := -1
var _armed := true

func _ready() -> void:
	ring = _marker(false); cross = _marker(true)
	clear()

func _process(_delta: float) -> void:
	sync(source.call() if source.is_valid() else {})

func _marker(is_cross: bool) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	var quad := QuadMesh.new(); quad.size = Vector2.ONE * 2.0 * tan(HALF_SIZE)
	node.mesh = quad; node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	node.extra_cull_margin = 1.0 # CPU culling must not clip the angular shader at an eye edge.
	# Layer 1 stays in the eye buffer, outside menu/subtitle capture worlds.
	node.layers = 1
	var material := ShaderMaterial.new(); material.shader = MARKER
	material.render_priority = 123 if is_cross else 122
	material.set_shader_parameter("cross_shape", is_cross)
	material.set_shader_parameter("ink_alpha", 0.84 if is_cross else 0.72)
	node.material_override = material; add_child(node)
	return node

func clear() -> void:
	visible = false; opacity = 0.0; holding = false; joined = false
	identity = ""; hand = ""; _released_at = -1; _near_at = -1; _far_at = -1
	_pulse_at = -COOLDOWN_MS; _last_sample = -1; _armed = true

## Only a normal release fades. Capture cancellation/ownership loss clears immediately.
func release(owner: String, now: int = Time.get_ticks_msec()) -> void:
	if not holding or owner != hand: return
	holding = false; _released_at = now; _near_at = -1

static func placement(head: Transform3D, centre: Vector3) -> Dictionary:
	if not head.is_finite() or absf(head.basis.determinant()) < 0.00001 or not centre.is_finite(): return {}
	var offset := centre - head.origin
	var distance := offset.length()
	if not is_finite(distance) or distance < 0.1: return {}
	var basis := head.basis.orthonormalized()
	# Unit-radius geometry only bounds angular directions. The shader projects
	# them without eye translation, so these references never acquire near depth.
	return {"ring": Transform3D(basis, head.origin - basis.z),
		"cross": Transform3D(basis, head.origin + offset / distance),
		"angle": (-basis.z).angle_to(offset), "front": offset.dot(-basis.z) > 0.0}

func sync(sample: Dictionary, now: int = Time.get_ticks_msec()) -> void:
	if not is_instance_valid(ring): return
	if sample.is_empty() or not sample.get("head") is Transform3D or not sample.get("centre") is Vector3:
		clear(); return
	var pose := placement(sample.head, sample.centre)
	if pose.is_empty(): clear(); return
	var current_identity := str(sample.get("identity", ""))
	var current_hand := str(sample.get("hand", ""))
	var held := bool(sample.get("held", false))
	if current_identity.is_empty() or (held and current_hand not in ["left_hand", "right_hand"]): clear(); return
	if current_identity != identity or (held and current_hand != hand): clear()
	if held:
		if not holding:
			clear(); identity = current_identity; hand = current_hand; holding = true
		opacity = 1.0
		# A long frame/focus gap cannot count as continuous alignment confirmation.
		if _last_sample >= 0 and now - _last_sample > 250: _near_at = -1; _far_at = -1
		_update_alignment(float(pose.angle), now)
	elif holding or _released_at < 0:
		clear(); return
	else:
		opacity = clampf(1.0 - float(now - _released_at) / FADE_MS, 0.0, 1.0)
		if opacity <= 0.0: clear(); return
	_last_sample = now
	visible = true
	ring.global_transform = pose.ring; cross.global_transform = pose.cross
	cross.visible = bool(pose.front)
	var phase := clampf(float(now - _pulse_at) / PULSE_MS, 0.0, 1.0)
	var contraction := sin(phase * PI) if joined else 0.0
	for node in [ring, cross]:
		node.material_override.set_shader_parameter("head_origin", sample.head.origin)
		node.material_override.set_shader_parameter("opacity", opacity)
		node.material_override.set_shader_parameter("shape_scale", 1.0 - contraction * (0.045 if node == cross else 0.08))

func _update_alignment(angle: float, now: int) -> void:
	if angle > EXIT_ANGLE:
		joined = false; _near_at = -1
		if _far_at < 0: _far_at = now
		if now - _far_at >= REARM_MS: _armed = true
		return
	_far_at = -1
	if joined: return
	if angle > ENTER_ANGLE: _near_at = -1; return
	if _near_at < 0: _near_at = now
	if now - _near_at < SETTLE_MS: return
	joined = true; _near_at = -1
	if _armed and now - _pulse_at >= COOLDOWN_MS:
		_armed = false; _pulse_at = now
		aligned.emit(hand)
