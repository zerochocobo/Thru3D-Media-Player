extends SceneTree
const Main := preload("res://scripts/main.gd")
const Lock := preload("res://scripts/viewing_hand_lock.gd")
const Gesture := preload("res://scripts/hand_lock_gesture.gd")
const Watch := preload("res://scripts/wrist_watch_logic.gd")
const Menu := preload("res://scripts/player_menu.gd")
const Hand := preload("res://scripts/hand_pointer.gd")
var checks := 0
var failures: Array[String] = []

class Harness extends Main:
	var focus := true
	var force_action_route := false
	var polled_sticks := []
	var test_menu: Node3D
	func _input_focused() -> bool: return focus
	func _head_tracked() -> bool: return true
	func _active_menu() -> Node3D: return test_menu if test_menu else (player_menu if player_menu and player_menu.visible else null)
	func _vr_passthrough_active() -> bool: return false
	func _controller_allowed(hand: String) -> bool: return force_action_route or super(hand)
	func _process_stick_input(left: Vector2, right: Vector2, _delta: float) -> void: polled_sticks = [left, right]

class Pip extends RefCounted:
	var cancels := 0
	func cancel_pointer(_hand: String) -> void: cancels += 1

class Cinema extends RefCounted:
	func active(_viewer: Node) -> bool: return false
	func show_guide(_viewer: Node, _head: Variant, _shown: bool) -> void: pass

class Beach extends Node3D:
	var restored := {}
	var ends := 0
	func request_screen(parameters: Dictionary) -> bool: restored = parameters; return true
	func show_screen_marks(_marks: Dictionary) -> void: pass
	func set_scene_highlight(_body: bool, _control: bool) -> void: pass
	func end_drag() -> void: ends += 1
	func release_firework(_hand: String) -> void: pass

class Viewer extends Node3D:
	var local_uri := "content://test/hand-lock"
	var media := {"state": "playing", "session_id": 1}
	var geometry := 1
	var pip := Pip.new()
	var cinema := Cinema.new()
	var plays := 0
	var seeks := 0
	func set_corner_hover(_corner: int) -> void: pass
	func toggle_play() -> void: plays += 1
	func seek_absolute(_position: int) -> void: seeks += 1

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok: failures.append(label)

func _initialize() -> void: _run.call_deferred()

func sample(g: RefCounted, down: bool = false, hand: String = "right_hand") -> Dictionary:
	var point := Vector3(0.2 if hand == "right_hand" else -0.2, 0.04, -0.35)
	var target: Vector3 = g.target.origin if g.shown else Vector3(0.16, 0.03, -0.58)
	return {"hand": hand, "tracked": true, "point": point, "ray": [point, (target - point).normalized()], "down": down}

func advance(g: RefCounted, down: bool, frames: int, hand: String = "right_hand") -> bool:
	var unlocked := false
	for i in frames: unlocked = g.update(sample(g, down, hand), Transform3D.IDENTITY, 1.0, 0.02) or unlocked
	return unlocked

## Same synthetic joint geometry as test_hand_pointer.gd, using the production pivot.
func joint_frame(main: Node, tracker: XRHandTracker, target: Vector3, ratio: float, count: int) -> void:
	var head: Transform3D = main.xr_camera.global_transform
	var knuckle := head.origin.lerp(target, 0.3)
	for i in 12:
		var pivot := Hand.ray_pivot("right_hand", head, knuckle, 1)
		knuckle = pivot + (target - pivot).normalized() * 0.4
	var center := knuckle - Vector3(0, 0, 0.07)
	var index := center + Vector3(0.035 * ratio, 0, 0)
	var points := [center - Vector3(0.035 * ratio, 0, 0), index, knuckle, knuckle.lerp(index, 0.36), knuckle.lerp(index, 0.7)]
	for i in Hand.JOINTS.size():
		tracker.set_hand_joint_flags(Hand.JOINTS[i], Hand.POSITION_FLAGS)
		tracker.set_hand_joint_transform(Hand.JOINTS[i], Transform3D(Basis.IDENTITY, points[i]))
	for i in count: main._update_hand_input(0.02)

func gesture_cases() -> void:
	var g := Gesture.new()
	advance(g, true, 100)
	check(g.shown and not g.armed and g.progress == 0, "Pre-existing held pinch cannot arm or unlock")
	advance(g, false, 1)
	check(g.armed, "Target-visible open sample arms recovery")
	advance(g, true, 55)
	check(g.complete and g.progress == 1, "New held pinch completes but still waits for release")
	check(advance(g, false, 1) and not g.shown, "Valid release completes recovery and hides target")
	check(not advance(g, false, 1), "Completion cannot repeat")
	g.reset(); advance(g, false, 10)
	check(not g.shown, "Quick pass cannot show target")
	g.reset()
	var mouth := {"hand": "right_hand", "tracked": true, "point": Vector3(0, -0.16, -0.30), "ray": [Vector3.ZERO, Vector3.FORWARD], "down": false}
	for i in 80: g.update(mouth, Transform3D.IDENTITY, 1, 0.02)
	check(not g.shown, "Stable mouth-region hand still cannot show target")
	for point in [Vector3(0.01, 0, -0.1), Vector3(0.6, 0, -0.4), Vector3(0, 0, 0.2)]:
		check(not Gesture.eligible(point, Transform3D.IDENTITY, 1), "Near head / out of field / behind head rejected")
	var reclined := Transform3D(Basis(Vector3.RIGHT, PI / 3), Vector3(2, 1, 3))
	check(Gesture.eligible(reclined * Vector3(0.2, 0.04, -0.35), reclined, 1), "Eligibility works when reclined")
	check(Gesture.eligible(Vector3(0.4, 0.08, -0.7), Transform3D.IDENTITY, 2), "Eligibility respects XR world scale")
	for fault in ["tracked", "blocked", "off_target", "switch_hand"]:
		g.reset(); advance(g, false, 25); advance(g, true, 55)
		var s := sample(g, true)
		if fault == "tracked": s.tracked = false
		elif fault == "blocked": s.blocked = true
		elif fault == "off_target": s.ray[1] = Vector3.RIGHT
		else: s.hand = "left_hand"
		check(not g.update(s, Transform3D.IDENTITY, 1, 0.02) and not g.complete, "Cancel completed hold on " + fault)
		check(not advance(g, false, 1), "Failure is never interpreted as successful release: " + fault)
	g.reset(); advance(g, false, 25, "left_hand"); advance(g, true, 55, "left_hand")
	check(advance(g, false, 1, "left_hand"), "Left hand can recover independently")
	check(Lock.classify(true, false, false, true, false, true) == Lock.Source.BARE, "Optical hands gate native action profiles")
	check(Lock.classify(false, true, false, true, true, true) == Lock.Source.CONTROLLER, "Controller skeleton through hand profile remains controller")
	check(Lock.classify(false, false, false, true, true, true) == Lock.Source.UNKNOWN, "No optical data is not proof of a controller")
	check(Lock.classify(false, false, false, true, true, false) == Lock.Source.CONTROLLER, "Hand interaction profile alone never identifies a bare hand")
	check(Lock.classify(false, false, true, false, false, true) == Lock.Source.BARE, "Dedicated native hand aim survives missing joints")
	check(Lock.classify(false, false, false, false, true, true) == Lock.Source.CONTROLLER, "Positive controller route replaces stale hand state")

func wrist_cases() -> void:
	var w := Watch.new()
	# Exercise the existing near-touch detector with a fixed expanded disc.
	w.phase = Watch.Phase.EXPANDED; w.tip_valid = true
	w.media = {"has_video": true, "hand_lock_available": true, "hand_locked": false}
	var point := Watch.button_position("hand_lock")
	var events: Array[Dictionary] = []
	w.tip_local = Vector3(point.x, point.y, 0.045); w._update_expanded(0.02, events)
	w.tip_local.z = 0.005; w._update_expanded(0.02, events)
	for i in 55: w._update_expanded(0.02, events)
	check(events.size() == 1 and events[0] == {"op": "hand_lock", "locked": true}, "Wrist long press locks once")
	w.media.hand_locked = true
	for i in 100: w._update_expanded(0.02, events)
	check(events.size() == 1, "Same prolonged touch never unlocks after locking")
	w.tip_local.z = 0.045; w._update_expanded(0.02, events); w._update_expanded(0.02, events)
	w.tip_local.z = 0.005; w._update_expanded(0.02, events)
	for i in 55: w._update_expanded(0.02, events)
	check(events.size() == 1 and w.hand_lock_progress == 1, "Wrist unlock waits for lift")
	w.tip_local.z = 0.045; w._update_expanded(0.02, events)
	check(events.size() == 2 and not events[1].locked, "Wrist lift unlocks exactly once")
	check(w._target(Watch.button_position("play")).is_empty(), "Locked watch has no play target")
	check(w._target(Watch.arc_point(0.5)).is_empty(), "Locked watch has no seek target")
	w._update_expanded(0.02, events); w.tip_local.z = 0.005; w._update_expanded(0.02, events)
	for i in 55: w._update_expanded(0.02, events)
	w.tip_valid = false; w._update_expanded(0.02, events)
	check(events.size() == 2 and w.hand_lock_progress == 0, "Lost finger cannot commit wrist unlock")

func cancellation_cases() -> void:
	var commits := []
	var menu := Menu.new(); root.add_child(menu); menu.set_process(false)
	menu.adjustment_committed.connect(func(): commits.append("adjust"))
	menu.depth_strength_committed.connect(func(): commits.append("depth"))
	menu._adjust_hand = "right_hand"; menu._adjust_target = 1; menu._depth_hand = "right_hand"
	menu._seek_hand = "right_hand"; menu._seek_preview = 8000
	menu.cancel_for_hand_lock("left_hand")
	check(menu._adjust_hand == "right_hand", "Other hand cancellation leaves current controller capture untouched")
	menu.cancel_for_hand_lock("right_hand")
	check(commits.is_empty() and menu._adjust_hand.is_empty() and menu._depth_hand.is_empty() and menu._seek_hand.is_empty(), "Lock cancels sliders/seek without final commit")
	menu.free()
	var scene := preload("res://scripts/environments/private_beach_interaction.gd").new()
	var beach := Beach.new(); scene.beach = beach
	scene.screen_committed.connect(func(_parameters): commits.append("screen"))
	scene.hours_committed.connect(func(_hours): commits.append("hours"))
	scene._scene_hand = "right_hand"; scene._scene_kind = "screen_move"
	scene._screen_drag = {"before": {"width": 10.0}}
	scene._capture_hand = "right_hand"; scene._capture = {"kind": "floor"}
	scene.cancel_for_hand_lock("right_hand")
	check(beach.restored == {"width": 10.0} and scene._capture.is_empty() and scene._scene_hand.is_empty() and commits.is_empty(), "Lock discards pending beach screen and teleport commits")
	scene._scene_hand = "right_hand"; scene._scene_kind = "drag"
	scene.cancel_for_hand_lock("right_hand")
	check(beach.ends == 1 and commits.is_empty(), "Lock stops celestial dragging without hours commit")
	scene.free(); beach.free()

func integration_cases() -> void:
	var main := Harness.new()
	var viewer := Viewer.new(); main.video = viewer
	var menu := Menu.new(); root.add_child(menu); menu.set_process(false)
	main.player_menu = menu; main.video_menu = menu
	menu.state_provider = func(): return {"has_video": true, "title": "Lock test", "duration_ms": 10000, "position_ms": 1000, "hand_lock_available": true, "hand_locked": main.hand_lock.locked, "watch_available": true, "watch_enabled": false}
	menu.action_requested.connect(main._on_menu_action)
	menu.toggle(); menu.position = Vector3(0, 1.6, -1)
	main.xr_origin = XROrigin3D.new(); root.add_child(main.xr_origin)
	main.xr_camera = XRCamera3D.new(); main.xr_origin.add_child(main.xr_camera); main.xr_camera.position.y = 1.6
	main.hand_pointers["right_hand"] = preload("res://scripts/hand_pointer.gd").new()
	main.hand_pointers["left_hand"] = preload("res://scripts/hand_pointer.gd").new()
	var optical := XRHandTracker.new(); optical.name = "/user/hand_tracker/right"
	optical.has_tracking_data = true; optical.hand_tracking_source = XRHandTracker.HAND_TRACKING_SOURCE_UNOBSTRUCTED
	XRServer.add_tracker(optical)
	var aim := XRControllerTracker.new(); aim.name = "/user/fbhandaim/right"
	aim.set_input("index_pinch", false); XRServer.add_tracker(aim)
	var button: Dictionary = menu._buttons.filter(func(b): return b.target == Menu.HAND_LOCK)[0]
	var origin: Vector3 = button.node.global_position + Vector3(0, 0, 0.5)
	aim.set_pose("default", Transform3D(Basis.IDENTITY, origin), Vector3.ZERO, Vector3.ZERO, XRPose.XR_TRACKING_CONFIDENCE_HIGH)
	for i in 3: main._update_hand_input(0.02)
	check(not main.hand_lock.locked and main._ray("right_hand") != null, "Default input remains available")
	aim.set_input("index_pinch", true)
	for i in 25: main._update_hand_input(0.02)
	check(not main.hand_lock.locked and not main.hand_lock.panel_capture.is_empty(), "Panel pinch is held without immediate toggle")
	aim.set_input("index_pinch", false); main._update_hand_input(0.02)
	check(not main.hand_lock.locked, "Short panel pinch cannot lock")
	main._update_hand_input(0.02)
	aim.set_input("index_pinch", true)
	for i in 60: main._update_hand_input(0.02)
	check(main.hand_lock.locked and not menu.visible, "Production sampler long pinch locks and dismisses controls")
	check(main._ray("right_hand") == null and viewer.pip.cancels > 0, "Lock hides business ray and cancels PiP capture")
	main._apply_watch_action({"op": "play"}); main._apply_watch_action({"op": "seek", "position_ms": 8000})
	check(viewer.plays == 0 and viewer.seeks == 0, "Independent watch path cannot play or seek while locked")
	check(not main._cinema_pointer_press("right_hand") and not main._pip_pointer_press("trigger_click", "right_hand"), "Movement and PiP entry points reject locked hand")
	check(not main._beach_prop_press("right_hand"), "Direct beach entry rejects locked hand")
	main.force_action_route = true
	main._on_controller_button("ax_button", "right_hand")
	check(main.controller_bindings.down.right_hand.is_empty(), "Native action callback cannot bypass lock into controller bindings")
	main.force_action_route = false
	main._process_sticks(Vector2.UP, Vector2.UP, 0.02)
	check(main.polled_sticks == [Vector2.UP, Vector2.ZERO], "Synthetic stick on locked hand is suppressed without stopping the other controller")
	main._on_pointer_button("menu_button", "right_hand")
	check(not menu.visible, "Menu action cannot reopen locked controls")
	main.settings.set_value("watch", "enabled", false)
	main.wrist_watch = preload("res://scripts/wrist_watch.gd").new(); root.add_child(main.wrist_watch)
	main._update_wrist_watch(0.02)
	check(not main.wrist_watch.visible, "Hidden watch stays hidden under lock")
	# The hand that just locked is still raised in front; it must not be offered an unlock target.
	aim.set_input("index_pinch", false)
	for i in 40: main._update_hand_input(0.02)
	check(main.hand_lock.locked and not main.hand_lock.recovery.shown, "Locking hand cannot raise a recovery target before leaving")
	aim.set_pose("default", Transform3D(Basis.IDENTITY, Vector3(0.1, 1.0, -0.3)), Vector3.ZERO, Vector3.ZERO, XRPose.XR_TRACKING_CONFIDENCE_HIGH)
	main._update_hand_input(0.02)
	check(main.hand_lock.locked and not main.hand_lock.recovery.shown, "Lowering the hand stays locked")
	# Full single-hand recovery through production sampling; no valid joint stream is required for Meta aim.
	var p := Vector3(0.2, 1.64, -0.35)
	var target := Vector3(0.16, 1.63, -0.58)
	var pose := Transform3D(Basis.looking_at((target - p).normalized()), p)
	aim.set_pose("default", pose, Vector3.ZERO, Vector3.ZERO, XRPose.XR_TRACKING_CONFIDENCE_HIGH)
	aim.set_input("index_pinch", false)
	for i in 30: main._update_hand_input(0.02)
	check(main.hand_lock.recovery.shown and main.hand_lock.recovery.armed, "Hidden watch does not disable independent recovery")
	aim.set_input("index_pinch", true)
	for i in 55: main._update_hand_input(0.02)
	check(main.hand_lock.locked and main.hand_lock.recovery.complete, "Production recovery waits for release")
	aim.set_input("index_pinch", false); main._update_hand_input(0.02)
	check(not main.hand_lock.locked and not menu.visible and not main._video_control_tap.size(), "Release recovers without clicking through or opening controls")
	check(not main.settings.get_value("watch", "enabled") and not main.wrist_watch.visible, "Recovery preserves hidden watch preference")
	main.hand_lock.set_locked(true)
	var left := XRHandTracker.new(); left.name = "/user/hand_tracker/left"
	left.has_tracking_data = true; left.hand_tracking_source = XRHandTracker.HAND_TRACKING_SOURCE_UNOBSTRUCTED
	XRServer.add_tracker(left)
	main.hand_pointers.left_hand.ray = [Vector3(-0.2, 1.64, -0.35), Vector3.FORWARD]
	var raw := {"left_hand": {"tracked": true, "sample_valid": true, "down": false, "position": Vector3(-0.2, 1.64, -0.35)}}
	main.settings.set_value("watch", "enabled", true); main.wrist_watch.visible = true
	main.hand_lock.recovery.reset()
	for i in 30: main.hand_lock.filter(raw, 0.02)
	check(not main.hand_lock.recovery.shown, "Visible wrist suppresses the left independent target")
	main.wrist_watch.visible = false
	for i in 30: main.hand_lock.filter(raw, 0.02)
	check(main.hand_lock.recovery.shown and main.hand_lock.recovery.hand == "left_hand", "Left independent target returns when wrist is hidden")
	main.hand_lock.recovery.reset(); main.wrist_watch.visible = true
	raw = {"right_hand": {"tracked": true, "sample_valid": true, "down": false, "position": p}}
	for i in 30: main.hand_lock.filter(raw, 0.02)
	check(main.hand_lock.recovery.shown and main.hand_lock.recovery.hand == "right_hand", "Visible wrist leaves right independent recovery available")
	raw.right_hand.sample_valid = false
	main.hand_lock.filter(raw, 0.02)
	check(not main.hand_lock.recovery.shown, "Debounced stale ray cannot continue a recovery candidate")
	main.wrist_watch.visible = false; XRServer.remove_tracker(left)
	main.photo_active = true
	check(not main.hand_lock.effective(), "Photo context is not locked")
	main.photo_active = false
	var library := Node3D.new(); main.test_menu = library
	check(not main.hand_lock.effective(), "Library/browser primary context leaves PiP input available")
	main.test_menu = null; library.free()
	check(main.hand_lock.effective(), "Returning to viewing reapplies session choice")
	main.focus = false; main.hand_lock.sync_context(); main.focus = true
	check(main.hand_lock.locked and not main.hand_lock.recovery.shown, "Focus loss cancels candidate but retains lock")
	viewer.media.state = "paused"
	check(main.hand_lock.effective(), "Paused viewing remains locked")
	viewer.media.state = "buffering"
	check(main.hand_lock.effective(), "Buffering remains locked")
	optical.has_tracking_data = false
	check(main.hand_lock.blocked("right_hand"), "Native hand provider still gated without optical data")
	XRServer.remove_tracker(aim)
	optical.has_tracking_data = true
	main.hand_lock.cancel_candidates(); main.hand_pointers.right_hand = Hand.new()
	joint_frame(main, optical, target, 0.8, 35)
	check(main.hand_pointers.right_hand.provider == "joints" and main.hand_lock.recovery.shown and main.hand_lock.recovery.armed, "Joint-only production sampler can aim and arm recovery")
	joint_frame(main, optical, target, 0.1, 60)
	check(main.hand_lock.locked and main.hand_lock.recovery.complete, "Joint pinch counts hold without clicking content")
	joint_frame(main, optical, target, 0.8, 4)
	check(not main.hand_lock.locked and not menu.visible, "Joint release unlocks without opening controls")
	main.hand_lock.set_locked(true)
	var controller := XRControllerTracker.new(); controller.name = "right_hand"
	controller.set_tracker_profile("/interaction_profiles/ext/hand_interaction_ext")
	controller.set_pose("aim", pose, Vector3.ZERO, Vector3.ZERO, XRPose.XR_TRACKING_CONFIDENCE_HIGH)
	XRServer.add_tracker(controller)
	optical.has_tracking_data = true; optical.hand_tracking_source = XRHandTracker.HAND_TRACKING_SOURCE_CONTROLLER
	check(main.hand_lock.source("right_hand") == Lock.Source.CONTROLLER and not main.hand_lock.blocked("right_hand"), "Positive physical controller via hand profile remains usable")
	main._process_sticks(Vector2.ZERO, Vector2.UP, 0.02)
	check(main.polled_sticks == [Vector2.ZERO, Vector2.UP], "Physical controller movement passes while session remains locked")
	menu.visible = true; menu._activate(Menu.HAND_LOCK)
	check(not main.hand_lock.locked and menu.visible, "Controller click unlocks without hiding the control bar")
	menu.section = 1; menu.refresh()
	main._apply_watch_action({"op": "hand_lock", "locked": true})
	check(main.hand_lock.locked and not menu.visible, "Wrist lock closes controls left on a settings page")
	main.hand_lock.set_locked(false)
	check(not main.settings.has_section_key("hand_lock", "locked"), "No persistent lock preference is written")
	var fresh := Harness.new(); check(not fresh.hand_lock.locked, "New app instance starts unlocked"); fresh.free()
	XRServer.remove_tracker(optical); XRServer.remove_tracker(controller)
	main.wrist_watch.free(); main.xr_origin.free(); menu.free(); viewer.free(); main.free()

func _run() -> void:
	gesture_cases(); wrist_cases(); cancellation_cases(); integration_cases()
	for failure in failures: push_error(failure)
	print("Viewing hand lock: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
