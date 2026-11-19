extends SceneTree
## PICO enterprise mixed interaction reports an optical hand while it holds a controller.
const Presence := preload("res://scripts/controller_presence.gd")
var checks := 0
var failures: Array[String] = []

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok: failures.append(label)

func _initialize() -> void:
	var tracker := XRControllerTracker.new()
	tracker.type = XRServer.TRACKER_CONTROLLER
	tracker.name = "left_hand"
	tracker.profile = "/interaction_profiles/bytedance/pico4_controller"
	XRServer.add_tracker(tracker)
	var presence := Presence.new()
	var at := func(origin: Vector3, basis := Basis()) -> void:
		tracker.set_pose("aim", Transform3D(basis, origin), Vector3.ZERO, Vector3.ZERO, XRPose.XR_TRACKING_CONFIDENCE_HIGH)
	var step := func(frames: int) -> void:
		for i in frames: presence.update("left_hand", 0.1)

	at.call(Vector3(0, 1, 0)); step.call(40)
	check(not presence.engaged("left_hand"), "A tracked controller lying still leaves the hand to gestures")
	at.call(Vector3(0, 1.0005, 0)); step.call(1)
	check(not presence.engaged("left_hand"), "Tracking jitter does not engage")
	at.call(Vector3(0.03, 1, 0)); step.call(1)
	check(presence.engaged("left_hand"), "Picking the controller up engages it")
	step.call(25)
	check(presence.engaged("left_hand"), "A held controller stays engaged inside the idle window")
	step.call(10)
	check(not presence.engaged("left_hand"), "A controller set down hands the hand back after the idle window")
	at.call(Vector3(0.03, 1, 0), Basis(Vector3.UP, deg_to_rad(6))); step.call(1)
	check(presence.engaged("left_hand"), "Turning the controller engages it")
	step.call(40)
	tracker.set_input("trigger", 0.6); step.call(1)
	check(presence.engaged("left_hand"), "Pulling the trigger engages a still controller")
	tracker.set_input("trigger", 0.0); step.call(40)
	presence.touch("left_hand")
	check(presence.engaged("left_hand"), "A button press engages before the frame update")
	tracker.profile = "/interaction_profiles/ext/hand_interaction_ext"; step.call(1)
	check(not presence.engaged("left_hand"), "A hand interaction profile is never a controller")
	presence.touch("left_hand")
	check(not presence.engaged("left_hand"), "Buttons routed through a hand profile do not engage")
	tracker.profile = "/interaction_profiles/khr/simple_controller"; at.call(Vector3(0.2, 1, 0)); step.call(1)
	at.call(Vector3(0.4, 1, 0)); step.call(1)
	check(not presence.engaged("left_hand"), "The simple profile may carry a hand and does not engage")
	tracker.profile = "/interaction_profiles/bytedance/pico4_controller"; step.call(1)
	at.call(Vector3(0.6, 1, 0)); step.call(1)
	check(presence.engaged("left_hand"), "Back on the controller profile, movement engages")
	tracker.invalidate_pose("aim"); step.call(1)
	check(not presence.engaged("left_hand"), "A lost controller pose releases at once")
	XRServer.remove_tracker(tracker)
	print("controller presence checks: %d, failures: %d" % [checks, failures.size()])
	for failure in failures: push_error(failure)
	quit(1 if failures.size() > 0 else 0)
