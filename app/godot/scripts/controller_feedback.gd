extends Node3D
## Controller activity and world rays are independent of menu nodes and input ownership.
## Shared with the transport's auto-hide deadline; finish fading at that deadline.
const IDLE_SECONDS := 5.0
const FADE_SECONDS := 0.25
const MOVE_METRES := 0.01
const TURN_RADIANS := 0.035
var hands := {}

func wake(hand: String) -> void:
	if not hands.has(hand): hands[hand] = {"reference": null, "age": 0.0, "opacity": 0.0, "nodes": {}}
	hands[hand].age = 0.0

func update_hand(hand: String, pose: Variant, ray: Variant, point: Variant, engaged: bool, menu_open: bool, delta: float, world_enabled: bool = true) -> float:
	wake_if_new(hand)
	var state: Dictionary = hands[hand]
	if not pose is Transform3D or not pose.is_finite():
		state.reference = null; state.opacity = 0.0
		_hide(state); return 0.0
	state.age += maxf(0.0, delta) if is_finite(delta) else 0.0
	var reference: Variant = state.reference
	if reference == null or pose.origin.distance_to(reference.origin) >= MOVE_METRES \
		or pose.basis.get_rotation_quaternion().angle_to(reference.basis.get_rotation_quaternion()) >= TURN_RADIANS:
		state.reference = pose; state.age = 0.0
	if engaged: state.age = 0.0
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

func wake_if_new(hand: String) -> void:
	if not hands.has(hand): wake(hand)

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
