extends Node3D
## Controller activity and world rays are independent of menu nodes and input ownership.
## Shared with the transport's auto-hide deadline; finish fading at that deadline.
const IDLE_SECONDS := 5.0
const FADE_SECONDS := 0.25
const WAKE_METRES := 0.08
const WAKE_RADIANS := PI / 9.0 # 20 degrees of aim direction; roll never counts.
const RELEASE_METRES := 0.06
const RELEASE_RADIANS := PI / 12.0
const ACTIVE_METRES := 0.02
const ACTIVE_RADIANS := PI / 36.0
const WINDOW_SECONDS := 1.0
const CONFIRM_SECONDS := 0.1
const SETTLE_SECONDS := 0.3
const MAX_SAMPLE_GAP := 0.1
signal woken(hand: String, reason: String)
var hands := {}

func _state(hand: String) -> Dictionary:
	if not hands.has(hand):
		hands[hand] = {"age": IDLE_SECONDS, "opacity": 0.0, "nodes": {}, "clock": 0.0,
			"reference": {}, "samples": [], "candidate": {}, "settled": 0.0, "settle_frames": 0, "reason": ""}
	return hands[hand]

func wake(hand: String, reason: String = "button") -> void:
	var state := _state(hand)
	var was_idle: bool = state.age >= IDLE_SECONDS and state.opacity <= 0.0
	state.age = 0.0; state.candidate.clear(); state.reason = reason
	if was_idle: woken.emit(hand, reason)

## Tracking/focus/reference changes establish a new baseline, never an activity event.
func rebase() -> void:
	for state in hands.values(): _clear_motion(state)

func _clear_motion(state: Dictionary) -> void:
	state.reference = {}; state.samples.clear(); state.candidate.clear()
	state.settled = 0.0; state.settle_frames = 0

func _turn(a: Dictionary, b: Dictionary) -> float:
	return (a.direction as Vector3).angle_to(b.direction)

func _motion(hand: String, state: Dictionary, sample: Dictionary, menu_open: bool, step: float) -> void:
	var position: Variant = sample.get("position")
	var direction: Variant = sample.get("direction")
	if not position is Vector3 or not position.is_finite() or not direction is Vector3 \
		or not direction.is_finite() or direction.length_squared() < 0.00001 or step > MAX_SAMPLE_GAP:
		_clear_motion(state); return
	var current := {"position": position, "direction": direction.normalized(), "time": state.clock}
	if state.reference.is_empty():
		state.reference = current; state.settle_frames = 1; return
	if state.settled < SETTLE_SECONDS:
		if position.distance_to(state.reference.position) >= ACTIVE_METRES or _turn(current, state.reference) >= ACTIVE_RADIANS:
			state.reference = current; state.settled = 0.0; state.settle_frames = 1; return
		state.settled += step; state.settle_frames += 1
		if state.settled < SETTLE_SECONDS or state.settle_frames < 3: return
		state.reference = current; state.samples.assign([current]); return
	# Keep recent samples across the hide boundary so the start of a deliberate
	# gesture is not discarded on the very frame the idle deadline expires.
	state.samples.append(current)
	while not state.samples.is_empty() and state.clock - state.samples[0].time > WINDOW_SECONDS:
		state.samples.pop_front()
	if state.age < IDLE_SECONDS or menu_open:
		if position.distance_to(state.reference.position) >= ACTIVE_METRES or _turn(current, state.reference) >= ACTIVE_RADIANS:
			wake(hand, "motion_active"); state.reference = current
		state.candidate.clear(); return
	if not state.candidate.is_empty():
		var candidate: Dictionary = state.candidate
		var distance: float = position.distance_to(candidate.reference.position)
		var angle := _turn(current, candidate.reference)
		if distance < RELEASE_METRES and angle < RELEASE_RADIANS:
			state.candidate.clear(); return
		candidate.frames += 1
		if state.clock - candidate.time >= CONFIRM_SECONDS and candidate.frames >= 3:
			var reason: String = candidate.reason
			wake(hand, reason); state.reference = current; state.samples.clear()
		return
	var reference: Dictionary = state.samples[0]
	var distance: float = position.distance_to(reference.position)
	var angle := _turn(current, reference)
	if distance >= WAKE_METRES or angle >= WAKE_RADIANS:
		state.candidate = {"reference": reference, "time": state.clock, "frames": 1,
			"reason": "translation" if distance >= WAKE_METRES else "aim_turn"}

func update_hand(hand: String, pose: Variant, ray: Variant, point: Variant, engaged: bool, menu_open: bool, delta: float, world_enabled: bool = true, activity: Dictionary = {}) -> float:
	var state := _state(hand)
	var step := maxf(0.0, delta) if is_finite(delta) else 0.0
	state.age += step; state.clock += step
	if not pose is Transform3D or not pose.is_finite():
		_clear_motion(state); state.opacity = 0.0
		_hide(state); return 0.0
	_motion(hand, state, activity, menu_open, step)
	if engaged: wake(hand, "input_held")
	# Menus keep models visible, but do not restart the physical activity clock.
	# When an idle transport closes, its stationary controllers hide with it.
	state.opacity = 1.0 if menu_open else clampf((IDLE_SECONDS - state.age) / FADE_SECONDS, 0.0, 1.0)
	var valid: bool = world_enabled and not menu_open and state.opacity > 0.0 and ray != null \
		and ray[0].is_finite() and ray[1].is_finite() and ray[1].length_squared() > 0.00001
	if not valid: _hide(state); return state.opacity
	if state.nodes.is_empty(): state.nodes = _make_pointer()
	var nodes: Dictionary = state.nodes
	var origin: Vector3 = ray[0]
	var hit: bool = point is Vector3 and point.is_finite()
	var endpoint: Vector3 = point if hit else origin + ray[1].normalized() * 3.0
	var offset := endpoint - origin
	var length := offset.length()
	if length < 0.001: _hide(state); return state.opacity
	nodes.line.visible = true
	nodes.line.global_transform = Transform3D(Basis(Quaternion(Vector3.UP, offset / length)), (origin + endpoint) * 0.5)
	nodes.line.scale = Vector3(1, length, 1)
	var color := Color(1.0, 0.73, 0.24) if engaged else Color(0.85, 0.94, 1.0)
	nodes.line.material_override.albedo_color = Color(color, state.opacity * 0.65)
	for key in ["rim", "dot"]:
		nodes[key].visible = hit
		if hit:
			nodes[key].global_position = endpoint - offset / length * 0.008
			nodes[key].scale = Vector3.ONE * clampf(length * 0.0055, 0.006, 0.4) * (1.65 if key == "rim" else 1.0)
			nodes[key].material_override.albedo_color = Color(Color(0.025, 0.035, 0.045) if key == "rim" else color, state.opacity)
	return state.opacity

func opacity(hand: String) -> float:
	return float(hands.get(hand, {}).get("opacity", 0.0))

func _hide(state: Dictionary) -> void:
	for node in state.nodes.values(): node.visible = false

func _make_pointer() -> Dictionary:
	var result := {}
	for key in ["line", "rim", "dot"]:
		var node := MeshInstance3D.new()
		if key == "line":
			var mesh := CylinderMesh.new(); mesh.top_radius = 0.0007; mesh.bottom_radius = 0.0007
			mesh.height = 1.0; mesh.radial_segments = 8; mesh.rings = 1
			node.mesh = mesh
		else:
			var mesh := SphereMesh.new(); mesh.radius = 1.0; mesh.height = 2.0
			mesh.radial_segments = 16; mesh.rings = 8; node.mesh = mesh
		var material := StandardMaterial3D.new()
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		material.no_depth_test = true
		# Video layers are underlays. Draw after their eye-buffer holes and menu masks.
		material.render_priority = 120 + result.size()
		node.material_override = material
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		node.visible = false; add_child(node); result[key] = node
	return result
