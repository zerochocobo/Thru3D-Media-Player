extends SceneTree
const Visuals := preload("res://scripts/input_visuals.gd")
const Pico := preload("res://scripts/pico_controller_model.gd")
var checks := 0
var failures: Array[String] = []

class FbModel extends Node3D:
	var loaded := false
	func has_render_model_node() -> bool: return loaded

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func _initialize() -> void: run.call_deferred()

func bounds(node: Node3D, relative: Transform3D = Transform3D.IDENTITY) -> AABB:
	var result := AABB()
	var transform := relative * node.transform
	if node is MeshInstance3D and node.mesh: result = transform * node.get_aabb()
	for child in node.get_children():
		if child is Node3D:
			var box := bounds(child, transform)
			if box.has_volume(): result = result.merge(box) if result.has_volume() else box
	return result

func run() -> void:
	for profile in Pico.PROFILES:
		for left in [true, false]:
			var id: String = Pico.PROFILES[profile]
			var label := id + (" left" if left else " right")
			var model := Pico.new(); root.add_child(model)
			check(model.setup(id, left), label + " loads a real bundled scene")
			check(model.responses.size() == (8 if left and id == "pico-4u" else 7), label + " all controls have animation endpoints")
			var box := bounds(model)
			check(box.size[box.size.min_axis_index()] > 0.03 and box.size.length() < 0.4, label + " dimensions are in metres: " + str(box))
			print(label + " bounds " + str(box))
			check(model.transform == Transform3D.IDENTITY, label + " preserves the authored grip origin")
			var neutral := {}
			for response in model.responses: neutral[response.input] = response.node.transform
			for response in model.responses:
				check(not response.min.is_equal_approx(response.max), label + " movable control " + response.input)
				var inputs := {response.input: 0.37}
				var weight := 0.37
				if response.input == "stick_x": inputs = {"primary": Vector2(-1, 0)}; weight = 0
				if response.input == "stick_y": inputs = {"primary": Vector2(0, 1)}; weight = 0
				model.update_inputs(inputs)
				check(response.node.transform.is_equal_approx(response.min.interpolate_with(response.max, weight)), label + " continuous movement / axis sign " + response.input)
				check(not response.node.transform.is_equal_approx(neutral[response.input]), label + " input changes the loaded node " + response.input)
			model.update_inputs({"trigger": 1.0, "grip": 1.0, "primary": Vector2(0.5, -0.5), "primary_click": true, "ax_button": true, "by_button": true, "menu_button": true})
			for response in model.responses:
				if not response.input.begins_with("stick_"): check(response.node.transform.is_equal_approx(response.max), label + " simultaneous pressed " + response.input)
			model.update_inputs({})
			for response in model.responses: check(response.node.transform.is_equal_approx(neutral[response.input]), label + " released / disconnected returns neutral " + response.input)
			model.update_inputs({"trigger_click": true, "grip_click": true, "primary": Vector2(NAN, 0)})
			for response in model.responses:
				if response.input in ["trigger", "grip"]: check(response.node.transform.is_equal_approx(response.max), label + " boolean fallback " + response.input)
				if response.input.begins_with("stick_"): check(response.node.transform.is_equal_approx(neutral[response.input]), label + " invalid axis resets safely")
			model.update_inputs({"trigger": NAN, "grip": -5.0})
			for response in model.responses:
				if response.input in ["trigger", "grip"]: check(response.node.transform.is_equal_approx(response.min), label + " malformed analog is bounded")
			model.free()
	var invalid := Pico.new()
	check(not invalid.setup("../unknown", true), "Unknown model cannot select an arbitrary asset")
	invalid.free()
	var origin := XROrigin3D.new(); root.add_child(origin)
	var visuals := Visuals.new(); visuals.use_runtime_models = false; origin.add_child(visuals)
	var controllers := []
	for side in ["left", "right"]:
		var tracker := XRControllerTracker.new(); tracker.name = side + "_hand"
		tracker.set_pose("grip", Transform3D.IDENTITY, Vector3.ZERO, Vector3.ZERO, XRPose.XR_TRACKING_CONFIDENCE_HIGH)
		XRServer.add_tracker(tracker); controllers.append(tracker)
	await process_frame
	# Four headset products, three controller families; Pro must not be omitted
	# or assigned Ultra's ringless asset. Runtime selection is by controller profile.
	for product in [
		["PICO Neo3", "/interaction_profiles/bytedance/pico_neo3_controller", "pico-neo3"],
		["PICO 4", "/interaction_profiles/bytedance/pico4_controller", "pico-4"],
		["PICO 4 Pro", "/interaction_profiles/bytedance/pico4_controller", "pico-4"],
		["PICO 4 Ultra", "/interaction_profiles/bytedance/pico4s_controller", "pico-4u"],
	]:
		controllers[0].set_tracker_profile(product[1]); visuals.update_visibility(true)
		check(visuals.hands.left_hand.controller_model == product[2], product[0] + " uses its controller family")
	for profile in Pico.PROFILES:
		for tracker in controllers: tracker.set_tracker_profile(profile)
		visuals.update_visibility(true)
		for hand in visuals.hands:
			var entry: Dictionary = visuals.hands[hand]
			check(entry.pico != null and entry.pico.visible and not entry.fallback.visible, hand + " GLB replaces procedural geometry: " + profile)
			check(entry.pico.get_parent() == entry.grip and entry.grip.pose == "grip", hand + " GLB uses existing grip tracking")
			check(visuals.snapshot()[hand].controller_model == Pico.PROFILES[profile], hand + " diagnostic identifies exact GLB source")
		var existing: Node3D = visuals.hands.left_hand.pico
		visuals.update_visibility(true)
		check(visuals.hands.left_hand.pico == existing, "Stable profile does not reload its GLB")
	# Independent hands and late / missing runtime meshes.
	controllers[1].set_tracker_profile("/interaction_profiles/oculus/touch_controller")
	visuals.update_visibility(true)
	check(visuals.hands.right_hand.pico == null and visuals.hands.right_hand.fallback.visible, "Quest never receives a PICO model")
	var entry: Dictionary = visuals.hands.left_hand
	var ext := Node3D.new(); entry.grip.add_child(ext); entry.ext = ext
	var fb := FbModel.new(); entry.grip.add_child(fb); entry.fb = fb
	visuals.update_visibility(true)
	check(entry.pico.visible, "Empty runtime models retain GLB")
	fb.loaded = true; visuals.update_visibility(true)
	check(entry.pico.visible and not fb.visible, "FB loaded container without geometry retains GLB")
	var fb_mesh := MeshInstance3D.new(); fb_mesh.mesh = BoxMesh.new(); fb.add_child(fb_mesh)
	visuals.update_visibility(true)
	check(fb.visible and not entry.pico.visible and not entry.fallback.visible and entry.controller_model == "meta", "FB runtime model wins over GLB")
	var mesh := MeshInstance3D.new(); mesh.mesh = BoxMesh.new(); ext.add_child(mesh)
	visuals.update_visibility(true)
	check(ext.visible and not fb.visible and not entry.pico.visible and entry.controller_model == "openxr", "Late EXT model wins over FB and GLB")
	mesh.visible = false; visuals.update_visibility(true)
	check(fb.visible and not ext.visible, "Hidden EXT mesh cannot suppress drawable FB model")
	fb_mesh.visible = false; visuals.update_visibility(true)
	check(entry.pico.visible and not ext.visible and not fb.visible, "Hidden runtime meshes restore PICO GLB")
	mesh.visible = true; visuals.update_visibility(true)
	check(ext.visible and not entry.pico.visible, "Runtime visibility recovery regains priority despite its hidden selection gate")
	mesh.mesh = ArrayMesh.new(); visuals.update_visibility(true)
	check(entry.pico.visible, "Empty runtime mesh resource cannot suppress GLB")
	mesh.mesh = BoxMesh.new(); mesh.scale = Vector3.ZERO; visuals.update_visibility(true)
	check(entry.pico.visible, "Collapsed runtime geometry cannot suppress GLB")
	mesh.scale = Vector3.ONE * 0.001; visuals.update_visibility(true)
	check(ext.visible and not entry.pico.visible, "Runtime assets with millimetre unit conversion remain eligible")
	mesh.scale = Vector3.ONE
	var runtime_branch := Node3D.new(); ext.add_child(runtime_branch); mesh.reparent(runtime_branch)
	runtime_branch.visible = false; visuals.update_visibility(true)
	check(entry.pico.visible, "Hidden runtime ancestor cannot suppress GLB")
	runtime_branch.visible = true; fb_mesh.visible = true
	mesh.free(); visuals.update_visibility(true)
	check(fb.visible and not entry.pico.visible, "EXT removal falls back to FB first")
	fb.loaded = false; visuals.update_visibility(true)
	check(entry.pico.visible and not entry.fallback.visible, "Runtime removal restores GLB")
	controllers[0].set_input("trigger", 0.6); visuals.update_visibility(true)
	var trigger: Dictionary = entry.pico.responses[0]
	check(trigger.node.transform.is_equal_approx(trigger.min.interpolate_with(trigger.max, 0.6)), "Animation reads the registered OpenXR action value")
	visuals.update_visibility(false)
	check(not entry.controller_gate.visible and trigger.node.transform.is_equal_approx(trigger.min), "Focus loss hides model and clears stale animation")
	visuals.update_visibility(true, {}, false)
	check(not entry.controller_gate.visible, "Panel visibility gate also applies to GLB")
	visuals.update_visibility(true)
	check(trigger.node.transform.is_equal_approx(trigger.min.interpolate_with(trigger.max, 0.6)), "Showing controls refreshes current input without a new press event")
	var optical := XRHandTracker.new(); optical.name = "/user/hand_tracker/left"
	optical.hand = XRPositionalTracker.TRACKER_HAND_LEFT
	optical.has_tracking_data = true; optical.hand_tracking_source = XRHandTracker.HAND_TRACKING_SOURCE_UNOBSTRUCTED
	XRServer.add_tracker(optical); visuals.update_visibility(true)
	check(entry.hand_gate.visible and not entry.controller_gate.visible and trigger.node.transform.is_equal_approx(trigger.min), "Optical hand tracking hides and resets the PICO GLB")
	XRServer.remove_tracker(optical); visuals.update_visibility(true)
	check(entry.controller_gate.visible and not entry.hand_gate.visible, "Returning to controller restores GLB ownership")
	controllers[0].invalidate_pose("grip"); visuals.update_visibility(true)
	check(not entry.controller_gate.visible and trigger.node.transform.is_equal_approx(trigger.min), "Tracking loss hides and resets GLB")
	controllers[0].set_tracker_profile("/interaction_profiles/khr/simple_controller"); visuals.update_visibility(true)
	check(entry.pico == null and entry.fallback.visible and entry.controller_model == "fallback", "Unknown physical hardware does not masquerade as PICO")
	# If a runtime model already exists, the bundled model is not loaded needlessly.
	mesh = MeshInstance3D.new(); mesh.mesh = BoxMesh.new(); ext.add_child(mesh)
	controllers[0].set_tracker_profile("/interaction_profiles/bytedance/pico4_controller"); visuals.update_visibility(true)
	check(entry.pico == null and not entry.pico_attempted, "Available runtime model avoids loading GLB")
	for tracker in controllers: XRServer.remove_tracker(tracker)
	origin.queue_free(); await process_frame
	for failure in failures: push_error(failure)
	print("PICO controller models: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
