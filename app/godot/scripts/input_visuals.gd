extends Node3D
## Rendering only. Aim poses and menu input remain owned by Main.
const HandInput := preload("res://scripts/hand_pointer.gd")
const PicoModel := preload("res://scripts/pico_controller_model.gd")
const Log := preload("res://scripts/diagnostic_log.gd")
const LEFT_HAND := preload("res://models/hands/LeftHandHumanoid.gltf")
const RIGHT_HAND := preload("res://models/hands/RightHandHumanoid.gltf")
var use_runtime_models := true
var hands := {}
var _material: ShaderMaterial
var _diagnostics_enabled := false
var _diagnostics_at := 0
var _last_diagnostics := {}
var cinema_move_hint: Label3D

func set_cinema_move_hint(enabled: bool) -> void:
	if enabled and not cinema_move_hint and hands.has("right_hand"):
		cinema_move_hint = Label3D.new()
		cinema_move_hint.name = "CinemaMoveHint"
		cinema_move_hint.font = preload("res://scripts/ray_menu.gd").ui_font()
		cinema_move_hint.font_size = 32
		cinema_move_hint.pixel_size = .00065
		cinema_move_hint.position = Vector3(.075, .075, -.015)
		cinema_move_hint.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		cinema_move_hint.no_depth_test = true
		cinema_move_hint.modulate = Color(.54, .93, .77)
		cinema_move_hint.outline_size = 8
		hands.right_hand.grip.add_child(cinema_move_hint)
	if cinema_move_hint:
		cinema_move_hint.visible = enabled
		if enabled: cinema_move_hint.text = preload("res://scripts/i18n.gd").t("Hold A to move")

func _ready() -> void:
	_material = ShaderMaterial.new()
	var shader := Shader.new()
	# Readable in dark video environments without adding lights or disabling depth.
	shader.code = "shader_type spatial; render_mode unshaded; uniform vec4 tint : source_color = vec4(0.72,0.79,0.85,1.0); void fragment(){ float light = 0.55 + 0.45 * max(dot(normalize(NORMAL), normalize(vec3(-0.3,0.7,0.6))),0.0); ALBEDO=tint.rgb*light; }"
	_material.shader = shader
	var xr := XRServer.find_interface("OpenXR")
	var runtime := use_runtime_models and xr != null and xr.is_initialized()
	_diagnostics_enabled = xr != null and xr.is_initialized()
	for side in ["left", "right"]:
		var controller_gate := Node3D.new()
		controller_gate.name = side.capitalize() + "Controller"
		controller_gate.visible = false
		add_child(controller_gate)
		var grip := XRNode3D.new()
		grip.tracker = side + "_hand"
		grip.pose = "grip"
		grip.show_when_tracked = true
		controller_gate.add_child(grip)
		var fallback := _controller_model(side == "left")
		grip.add_child(fallback)
		var hand_gate := Node3D.new()
		hand_gate.name = side.capitalize() + "Hand"
		hand_gate.visible = false
		add_child(hand_gate)
		var tracked_hand := XRNode3D.new()
		tracked_hand.tracker = "/user/hand_tracker/" + side
		tracked_hand.pose = "default"
		tracked_hand.show_when_tracked = true
		hand_gate.add_child(tracked_hand)
		var hand_model: Node3D = (LEFT_HAND if side == "left" else RIGHT_HAND).instantiate()
		tracked_hand.add_child(hand_model)
		var skeleton := _find_skeleton(hand_model)
		assert(skeleton != null, "Fallback hand must contain a skeleton")
		_add_modifier(skeleton, tracked_hand.tracker)
		_prepare_meshes(hand_model, true)
		var entry := {"controller_gate": controller_gate, "grip": grip, "fallback": fallback,
			"hand_gate": hand_gate, "tracked_hand": tracked_hand, "hand_fallback": hand_model,
			"ext": null, "fb": null, "pico": null, "pico_id": "", "pico_attempted": false,
			"hand_mesh": null, "controller_model": "fallback", "hand_model": "fallback"}
		hands[side + "_hand"] = entry
		if runtime:
			var manager := OpenXRRenderModelManager.new()
			manager.tracker = OpenXRRenderModelManager.RENDER_MODEL_TRACKER_LEFT_HAND if side == "left" else OpenXRRenderModelManager.RENDER_MODEL_TRACKER_RIGHT_HAND
			manager.make_local_to_pose = "grip"
			manager.render_model_added.connect(func(model): _prepare_meshes.call_deferred(model, false))
			grip.add_child(manager)
			entry.ext = manager
			if Engine.has_singleton("OpenXRFbRenderModelExtension") and Engine.get_singleton("OpenXRFbRenderModelExtension").is_enabled():
				var model: Node3D = ClassDB.instantiate("OpenXRFbRenderModel")
				model.set("render_model_type", 0 if side == "left" else 1)
				model.connect("openxr_fb_render_model_loaded", func(): _prepare_meshes(model, false))
				grip.add_child(model)
				entry.fb = model
			if ClassDB.class_exists("OpenXRFbHandTrackingMesh"):
				var mesh: Skeleton3D = ClassDB.instantiate("OpenXRFbHandTrackingMesh")
				mesh.set("hand", 0 if side == "left" else 1)
				mesh.set("material", _material)
				_add_modifier(mesh, tracked_hand.tracker)
				tracked_hand.add_child(mesh)
				entry.hand_mesh = mesh

func update_visibility(focused: bool, controller_opacity: Dictionary = {}, interaction_visible: bool = true) -> void:
	for hand in hands:
		var entry: Dictionary = hands[hand]
		var tracker := XRServer.get_tracker("/user/hand_tracker/" + hand.trim_suffix("_hand")) as XRHandTracker
		var optical := HandInput.is_optical(tracker)
		entry["focused"] = focused
		entry["interaction_visible"] = interaction_visible
		entry["optical"] = optical
		entry["opacity_visible"] = float(controller_opacity.get(hand, 1.0)) > 0.0
		entry.hand_gate.visible = focused and interaction_visible and optical
		entry.controller_gate.visible = focused and interaction_visible and not optical and _pose_tracked(entry.grip) and float(controller_opacity.get(hand, 1.0)) > 0.0
		# A runtime container may exist before its drawable model, or retain hidden
		# meshes. Neither condition may suppress the bundled controller fallback.
		var ext_ready := entry.ext != null and _has_drawable_mesh(entry.ext, true)
		var fb_ready: bool = entry.fb != null and entry.fb.has_render_model_node() and _has_drawable_mesh(entry.fb, true)
		entry["ext_ready"] = ext_ready
		entry["fb_ready"] = fb_ready
		if entry.ext: entry.ext.visible = ext_ready
		if entry.fb: entry.fb.visible = not ext_ready and fb_ready
		var controller := XRServer.get_tracker(hand) as XRPositionalTracker
		var pico_id := PicoModel.model_for_profile(str(controller.get_tracker_profile())) if controller else ""
		_update_pico_model(entry, pico_id, hand == "left_hand", not ext_ready and not fb_ready)
		var pico_ready: bool = entry.pico != null
		if pico_ready:
			entry.pico.visible = not ext_ready and not fb_ready
			entry.pico.update_tracker(controller, entry.controller_gate.visible and entry.pico.visible)
		entry.fallback.visible = not ext_ready and not fb_ready and not pico_ready
		entry.controller_model = "openxr" if ext_ready else ("meta" if fb_ready else (pico_id if pico_ready else "fallback"))
		var mesh_ready: bool = entry.hand_mesh != null and entry.hand_mesh.get_mesh_instance() != null
		if entry.hand_mesh: entry.hand_mesh.visible = mesh_ready
		entry.hand_fallback.visible = not mesh_ready
		entry.hand_model = "meta" if mesh_ready else "fallback"
	if _diagnostics_enabled and Time.get_ticks_msec() >= _diagnostics_at:
		_diagnostics_at = Time.get_ticks_msec() + 1000
		var state := snapshot()
		if state != _last_diagnostics:
			_last_diagnostics = state.duplicate(true)
			Log.record("input_visual_state", state)

func _update_pico_model(entry: Dictionary, id: String, left: bool, needed: bool) -> void:
	if entry.pico_id != id:
		if entry.pico != null:
			entry.grip.remove_child(entry.pico)
			entry.pico.queue_free()
		entry.pico = null
		entry.pico_id = id
		entry.pico_attempted = false
	# Only load the active family if this hand has no runtime model.
	if id.is_empty() or not needed or entry.pico_attempted: return
	entry.pico_attempted = true
	var model := PicoModel.new()
	if not model.setup(id, left):
		model.free()
		return
	_prepare_meshes(model, false)
	entry.grip.add_child(model)
	entry.pico = model

func snapshot() -> Dictionary:
	var result := {}
	for hand in hands:
		var entry: Dictionary = hands[hand]
		var controller := XRServer.get_tracker(hand) as XRPositionalTracker
		var optical := XRServer.get_tracker("/user/hand_tracker/" + hand.trim_suffix("_hand")) as XRHandTracker
		var reason := "visible"
		if not entry.get("focused", false): reason = "not_focused_or_head_untracked"
		elif not entry.get("interaction_visible", false): reason = "interaction_hidden"
		elif entry.get("optical", false): reason = "optical_hand"
		elif not _pose_tracked(entry.grip): reason = "grip_untracked"
		elif not entry.get("opacity_visible", false): reason = "feedback_hidden"
		elif not entry.grip.is_visible_in_tree(): reason = "ancestor_hidden"
		result[hand] = {"controller_model": entry.controller_model, "hand_model": entry.hand_model,
			"profile": str(controller.get_tracker_profile()) if controller else "",
			"tracker_registered": controller != null, "controller_hidden_reason": reason,
			"grip": _pose_snapshot(controller, "grip"), "aim": _pose_snapshot(controller, "aim"),
			"head": _pose_snapshot(XRServer.get_tracker("head") as XRPositionalTracker, "default"),
			"optical_tracked": HandInput.is_optical(optical), "hand_source": optical.hand_tracking_source if optical else -1,
			"interaction_visible": entry.get("interaction_visible", false),
			"trigger_click": controller.get_input("trigger_click") if controller else null,
			"grip_click": controller.get_input("grip_click") if controller else null,
			"pico_attempted": entry.pico_attempted, "pico_loaded": entry.pico != null,
			"ext_ready": entry.get("ext_ready", false), "fb_ready": entry.get("fb_ready", false),
			"controller_visible": entry.controller_gate.visible and entry.grip.is_visible_in_tree(),
			"hand_visible": entry.hand_gate.visible and entry.tracked_hand.is_visible_in_tree()}
	return result

static func _pose_snapshot(tracker: XRPositionalTracker, name: String) -> Dictionary:
	var pose := tracker.get_pose(name) if tracker != null and tracker.has_pose(name) else null
	return {"present": pose != null, "tracked": pose.has_tracking_data if pose else false,
		"confidence": int(pose.tracking_confidence) if pose else 0}

static func _pose_tracked(node: XRNode3D) -> bool:
	var pose := node.get_pose()
	return pose != null and pose.has_tracking_data and pose.tracking_confidence != XRPose.XR_TRACKING_CONFIDENCE_NONE

static func _find_skeleton(node: Node) -> Skeleton3D:
	if node is Skeleton3D: return node
	for child in node.get_children():
		var found := _find_skeleton(child)
		if found: return found
	return null

static func _add_modifier(skeleton: Skeleton3D, tracker: StringName) -> void:
	# The official fallback asset predates the optional palm bone. Append an
	# unweighted bone so the current modifier can map all 26 joints; keep skin IDs.
	var side := "Left" if str(tracker).ends_with("left") else "Right"
	if skeleton.find_bone(side + "Palm") < 0:
		var palm := skeleton.get_bone_count()
		skeleton.add_bone(side + "Palm")
		skeleton.set_bone_parent(palm, skeleton.find_bone(side + "Hand"))
		skeleton.set_bone_rest(palm, Transform3D(Basis.IDENTITY, Vector3(0, 0.06, 0)))
	var modifier := XRHandModifier3D.new()
	modifier.hand_tracker = tracker
	modifier.bone_update = XRHandModifier3D.BONE_UPDATE_FULL
	skeleton.add_child(modifier)

static func _has_mesh(node: Node) -> bool:
	if node is MeshInstance3D and node.mesh != null: return true
	for child in node.get_children():
		if _has_mesh(child): return true
	return false

static func _has_drawable_mesh(node: Node, container: bool = false) -> bool:
	if node.is_queued_for_deletion(): return false
	# Ignore the selection gate we control, but respect visibility inside the
	# runtime scene. is_visible_in_tree() would latch a deselected model off forever.
	if node is Node3D:
		if not container and not node.visible: return false
		if not node.transform.is_finite() or node.basis.determinant() == 0.0: return false
	if node is MeshInstance3D and node.mesh != null and node.mesh.get_surface_count() > 0:
		return true
	for child in node.get_children():
		if _has_drawable_mesh(child): return true
	return false

func _prepare_meshes(node: Node, replace_material: bool) -> void:
	if not is_instance_valid(node): return
	if node is MeshInstance3D:
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		if replace_material:
			node.material_override = _material
		elif node.mesh:
			for surface in node.mesh.get_surface_count():
				var material: Material = node.get_active_material(surface)
				if material is BaseMaterial3D:
					material = material.duplicate()
					material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
					node.set_surface_override_material(surface, material)
	for child in node.get_children(): _prepare_meshes(child, replace_material)

func _controller_model(left: bool) -> Node3D:
	# Generic grip geometry, deliberately independent of vendor/model identification.
	var model := Node3D.new()
	model.name = "GenericController"
	var body := CapsuleMesh.new()
	body.radius = 0.018
	body.height = 0.105
	body.radial_segments = 16
	body.rings = 4
	_mesh_part(model, body, Vector3(0, -0.025, 0.012))
	var top := SphereMesh.new()
	top.radius = 1
	top.height = 2
	top.radial_segments = 16
	top.rings = 8
	var face := _mesh_part(model, top, Vector3(0, 0.021, -0.008))
	face.scale = Vector3(0.032, 0.013, 0.034)
	var dark := _material.duplicate() as ShaderMaterial
	dark.set_shader_parameter("tint", Color(0.08, 0.11, 0.14))
	for offset in [Vector3(-0.011 if left else 0.011, 0.034, -0.009), Vector3(0.012 if left else -0.012, 0.032, -0.017)]:
		var button := _mesh_part(model, top, offset)
		button.scale = Vector3(0.007, 0.004, 0.007)
		button.material_override = dark
	return model

func _mesh_part(parent: Node3D, mesh: Mesh, offset: Vector3) -> MeshInstance3D:
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	instance.material_override = _material
	instance.position = offset
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(instance)
	return instance
