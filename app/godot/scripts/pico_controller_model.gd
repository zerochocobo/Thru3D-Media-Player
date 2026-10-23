extends Node3D
## Visual fallback only. Poses, input routing and runtime models remain external.
const PROFILES := {
	"/interaction_profiles/bytedance/pico_neo3_controller": "pico-neo3",
	# PICO 4 / 4 Pro / 4 Enterprise share this controller family in the SDK.
	"/interaction_profiles/bytedance/pico4_controller": "pico-4",
	"/interaction_profiles/bytedance/pico4s_controller": "pico-4u",
}
const MATERIAL_SHADER := preload("res://shaders/controller_model.gdshader")
const INPUTS := ["trigger", "trigger_click", "grip", "grip_click", "primary",
	"primary_click", "ax_button", "by_button", "menu_button"]
var model_id := ""
var asset: Node3D
var responses: Array[Dictionary] = []

static func model_for_profile(profile: String) -> String:
	return PROFILES.get(profile, "")

func setup(id: String, left: bool) -> bool:
	if not id in PROFILES.values() or asset != null: return false
	var scene := load("res://models/controllers/pico/%s-%s.glb" % [id, "left" if left else "right"]) as PackedScene
	if scene == null: return false
	asset = scene.instantiate() as Node3D
	if asset == null: return false
	model_id = id
	name = "PicoController"
	add_child(asset)
	# WebXR assets are authored in metres relative to grip, with glTF/Godot axes.
	# Preserve the hierarchy: nested thumbstick responses combine tilt and click.
	_bind("xr_standard_trigger_pressed", "trigger")
	_bind("xr_standard_squeeze_pressed", "grip")
	_bind("xr_standard_thumbstick_pressed", "primary_click")
	_bind("xr_standard_thumbstick_xaxis_pressed", "stick_x")
	_bind("xr_standard_thumbstick_yaxis_pressed", "stick_y")
	_bind("x_button_pressed" if left else "a_button_pressed", "ax_button")
	_bind("y_button_pressed" if left else "b_button_pressed", "by_button")
	# Only Ultra has an animated app-menu node. The system/home button is reserved.
	if left and id == "pico-4u": _bind("LMenu_pressed", "menu_button")
	_prepare_materials(asset)
	update_inputs({})
	return true

func _prepare_materials(node: Node) -> void:
	if node is MeshInstance3D and node.mesh:
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		for surface in node.mesh.get_surface_count():
			var source := node.get_active_material(surface) as BaseMaterial3D
			if source == null: continue
			var material := ShaderMaterial.new()
			material.shader = MATERIAL_SHADER
			material.set_shader_parameter("albedo", source.albedo_color)
			material.set_shader_parameter("albedo_texture", source.albedo_texture)
			node.set_surface_override_material(surface, material)
	for child in node.get_children(): _prepare_materials(child)

func _bind(prefix: String, input: String) -> void:
	var value := asset.find_child(prefix + "_value", true, false) as Node3D
	var minimum := asset.find_child(prefix + "_min", true, false) as Node3D
	var maximum := asset.find_child(prefix + "_max", true, false) as Node3D
	if value == null or minimum == null or maximum == null: return
	responses.append({"node": value, "min": minimum.transform, "max": maximum.transform, "input": input})

func update_tracker(tracker: XRPositionalTracker, active: bool) -> void:
	var inputs := {}
	if active and tracker != null:
		for key in INPUTS: inputs[key] = tracker.get_input(key)
	update_inputs(inputs)

func update_inputs(inputs: Dictionary) -> void:
	var stick: Variant = inputs.get("primary")
	if not stick is Vector2 or not stick.is_finite(): stick = Vector2.ZERO
	stick = stick.limit_length(1.0)
	for response in responses:
		var weight := 0.0
		match response.input:
			"stick_x": weight = (stick.x + 1.0) * 0.5
			# WebXR gamepad Y points down; OpenXR thumbstick Y points up.
			"stick_y": weight = (1.0 - stick.y) * 0.5
			"trigger", "grip":
				var analog: Variant = inputs.get(response.input)
				weight = _amount(analog if analog != null else inputs.get(response.input + "_click"))
			_: weight = _amount(inputs.get(response.input))
		response.node.transform = response.min.interpolate_with(response.max, weight)

static func _amount(value: Variant) -> float:
	if value is bool: return 1.0 if value else 0.0
	if value is float or value is int:
		return clampf(float(value), 0.0, 1.0) if is_finite(float(value)) else 0.0
	return 0.0
