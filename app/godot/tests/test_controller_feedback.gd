extends SceneTree
const Feedback := preload("res://scripts/controller_feedback.gd")
const Bindings := preload("res://scripts/controller_bindings.gd")
var checks := 0
var failures: Array[String] = []

class InputMain extends "res://scripts/main.gd":
	var pose := Transform3D(Basis.IDENTITY, Vector3(0.2, 1.4, -0.4))
	var rays := {}
	var activity_pose := Transform3D.IDENTITY
	func _controller_activity(_hand: String) -> Dictionary: return {"position": activity_pose.origin, "direction": -activity_pose.basis.z}
	func _move_pose(_hand: String) -> Variant: return pose
	func _head_pose() -> Variant: return Transform3D(Basis.IDENTITY, Vector3(0, 1.6, 0))
	func _ray(hand: String) -> Variant: return rays.get(hand)

class TrackedMain extends "res://scripts/main.gd":
	var world := Transform3D.IDENTITY
	func _move_pose(hand: String) -> Variant:
		if not _controller_allowed(hand): return null
		var tracker := XRServer.get_tracker(hand) as XRPositionalTracker
		if not tracker or not tracker.has_pose("aim") or not tracker.get_pose("aim").has_tracking_data: return null
		return world * tracker.get_pose("aim").get_adjusted_transform()
	func _ray(hand: String) -> Variant:
		var pose: Variant = _move_pose(hand)
		return [pose.origin, -pose.basis.z] if pose != null else null
	func _recenter(_restore_defaults: bool = true) -> void: pass

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func _initialize() -> void: call_deferred("run")

func tick(feedback: Node3D, pose: Transform3D, delta: float = 0.01, hand: String = "right_hand", menu: bool = false, held: bool = false) -> float:
	var point := Vector3(0, 1.6, -2)
	return feedback.update_hand(hand, pose, [pose.origin, (point - pose.origin).normalized()], point, held, menu, delta, true,
		{"position": pose.origin, "direction": -pose.basis.z})

func rest(feedback: Node3D, pose: Transform3D, seconds: float, hand: String = "right_hand") -> void:
	for frame in int(ceil(seconds / 0.01)): tick(feedback, pose, 0.01, hand)

func activity() -> void:
	var feedback := Feedback.new(); root.add_child(feedback)
	var pose := Transform3D(Basis.IDENTITY, Vector3(0.2, 1.4, -0.4))
	check(tick(feedback, pose) == 0.0, "First tracking sample does not wake a hidden controller")
	rest(feedback, pose, 0.4)
	check(feedback.opacity("right_hand") == 0.0, "Settling establishes a baseline without showing feedback")
	feedback.wake("right_hand")
	check(tick(feedback, pose) == 1.0, "A real button wakes immediately without a motion delay")
	var nodes: Dictionary = feedback.hands.right_hand.nodes
	check(nodes.line.visible and nodes.dot.visible, "Explicit input shows the ray and media hit")
	for frame in 350: tick(feedback, pose.translated(Vector3(sin(frame) * 0.001, 0, 0)))
	check(feedback.opacity("right_hand") == 1.0, "Small tracking jitter does not change the five-second deadline")
	rest(feedback, pose, 1.6)
	check(feedback.opacity("right_hand") == 0.0 and not nodes.line.visible and not nodes.dot.visible, "Stationary feedback finishes fading at five seconds")
	pose.origin.x += 0.10
	tick(feedback, pose)
	check(feedback.opacity("right_hand") == 0.0, "Crossing eight centimetres starts confirmation rather than flashing")
	rest(feedback, pose, 0.12)
	check(nodes.line.visible and feedback.hands.right_hand.reason == "translation", "Obvious translation wakes after continuous confirmation")
	rest(feedback, pose, 5.1)
	pose.basis = Basis(Vector3.UP, deg_to_rad(22.0))
	tick(feedback, pose); rest(feedback, pose, 0.12)
	check(nodes.line.visible and feedback.hands.right_hand.reason == "aim_turn", "A seated twenty-degree aim turn also wakes")
	for frame in 600: tick(feedback, pose, 0.01, "right_hand", false, true)
	check(feedback.opacity("right_hand") == 1.0, "Held real input or a capture cannot time out")
	feedback.update_hand("right_hand", pose, [pose.origin, Vector3.FORWARD], null, false, false, 0.01)
	check(nodes.line.visible and not nodes.dot.visible, "A missed surface never leaves a false dot")
	tick(feedback, pose, 10.0, "right_hand", true)
	check(not nodes.line.visible and feedback.opacity("right_hand") == 1.0, "Menus retain controllers and own their rays")
	tick(feedback, pose, 0.0)
	check(feedback.opacity("right_hand") == 0.0 and not nodes.line.visible, "Closing an idle menu does not start a second countdown")
	feedback.update_hand("right_hand", null, null, null, false, false, 0.02)
	pose.origin.x += 0.3; tick(feedback, pose); rest(feedback, pose, 0.5)
	check(feedback.opacity("right_hand") == 0.0, "Tracking return at a different pose only establishes a new baseline")
	feedback.wake("right_hand"); tick(feedback, pose)
	feedback.update_hand("right_hand", null, null, null, false, false, 1.0)
	tick(feedback, pose)
	check(feedback.hands.right_hand.age > 1.0 and feedback.hands.right_hand.age < 1.1, "Tracking recovery preserves remaining visibility instead of granting five more seconds")
	feedback.wake("right_hand"); tick(feedback, pose)
	feedback.wake("left_hand"); tick(feedback, pose, 0.01, "left_hand")
	rest(feedback, pose, 5.1, "left_hand")
	check(feedback.opacity("right_hand") == 1.0 and feedback.opacity("left_hand") == 0.0, "Each hand has its own idle clock")
	feedback.wake("left_hand"); tick(feedback, pose, 0.01, "left_hand")
	check(feedback.opacity("left_hand") == 1.0, "A button bypasses the post-recovery settling interval")
	check(nodes.dot.material_override.no_depth_test and nodes.dot.material_override.render_priority > 100, "Reticle remains above video holes")
	feedback.free()

func motion_rules() -> void:
	for fps in [72, 90, 120]:
		var feedback := Feedback.new(); root.add_child(feedback)
		var pose := Transform3D.IDENTITY
		for frame in fps: tick(feedback, pose, 1.0 / fps)
		for frame in fps:
			var jitter := pose.translated(Vector3(sin(frame) * 0.01, 0, 0))
			jitter.basis = Basis(Vector3.FORWARD, sin(frame) * 0.7)
			tick(feedback, jitter, 1.0 / fps)
		check(feedback.opacity("right_hand") == 0.0, "One-centimetre jitter and roll cannot wake at %d Hz" % fps)
		check(feedback.hands.right_hand.samples.size() <= fps + 2, "The motion history stays bounded to one second at %d Hz" % fps)
		pose.origin.x = 0.1; tick(feedback, pose, 1.0 / fps)
		for frame in int(ceil(0.14 * fps)): tick(feedback, pose, 1.0 / fps)
		check(feedback.opacity("right_hand") == 1.0, "Obvious motion confirms at %d Hz without frame-count timing" % fps)
		feedback.free()
	var feedback := Feedback.new(); root.add_child(feedback)
	var pose := Transform3D.IDENTITY
	rest(feedback, pose, 0.5)
	# Slowly walking the reference over many seconds must not accumulate wake distance.
	for frame in 1200: tick(feedback, pose.translated(Vector3(frame * 0.0001, 0, 0)))
	check(feedback.opacity("right_hand") == 0.0, "Twelve centimetres of slow drift never exceeds the one-second window")
	feedback.rebase(); rest(feedback, pose, 0.5)
	var below := Transform3D(Basis(Vector3.UP, deg_to_rad(19.0)), Vector3(0.079, 0, 0))
	rest(feedback, below, 0.2)
	check(feedback.opacity("right_hand") == 0.0, "Both motion components below eight centimetres and twenty degrees remain hidden")
	feedback.rebase(); rest(feedback, pose, 0.5)
	tick(feedback, pose.translated(Vector3(0.09, 0, 0)))
	tick(feedback, pose)
	rest(feedback, pose, 0.2)
	check(feedback.opacity("right_hand") == 0.0, "A one-frame tracking spike is rejected")
	tick(feedback, pose.translated(Vector3(0.09, 0, 0)))
	tick(feedback, pose.translated(Vector3(0.055, 0, 0)))
	rest(feedback, pose.translated(Vector3(0.055, 0, 0)), 0.15)
	check(feedback.opacity("right_hand") == 0.0, "Returning below six centimetres cancels a pending wake")
	feedback.rebase(); rest(feedback, pose, 0.5)
	tick(feedback, pose.translated(Vector3(0.09, 0, 0)))
	tick(feedback, pose.translated(Vector3(0.09, 0, 0)), 0.5)
	rest(feedback, pose.translated(Vector3(0.09, 0, 0)), 0.5)
	check(feedback.opacity("right_hand") == 0.0, "A long frame cannot satisfy confirmation or carry a pre-gap gesture")
	feedback.rebase(); rest(feedback, pose, 0.5)
	for frame in 100:
		var world := Transform3D(Basis(Vector3.UP, frame * 0.03), Vector3(frame * 0.1, 0, 0))
		feedback.update_hand("right_hand", world, [world.origin, -world.basis.z], world.origin + Vector3.FORWARD, false, false, 0.01, true,
			{"position": pose.origin, "direction": -pose.basis.z})
	check(feedback.opacity("right_hand") == 0.0, "World pose, ray and hit changes cannot wake a stationary raw controller")
	feedback.update_hand("right_hand", pose, null, null, false, false, 0.01, true, {})
	pose.origin.x = 0.4; rest(feedback, pose, 0.6)
	check(feedback.opacity("right_hand") == 0.0, "An invalid/low-confidence sample resets the motion baseline")
	feedback.wake("right_hand"); rest(feedback, pose, 0.4)
	for frame in 700:
		var active := pose.translated(Vector3(0.03 if frame % 100 < 50 else 0.0, 0, 0))
		tick(feedback, active)
	check(feedback.opacity("right_hand") == 1.0, "Once visible, smaller deliberate aiming motion keeps the ray available")
	feedback.free()

func tracked_input(video: Node3D, menu: Node3D, library: Node3D) -> void:
	var main := TrackedMain.new(); main.video = video; main.player_menu = menu; main.video_menu = menu; main.recent_menu = library
	main.controller_feedback = Feedback.new(); root.add_child(main.controller_feedback)
	main.settings_path = "user://tracked-feedback.cfg"
	var tracker := XRControllerTracker.new(); tracker.name = "right_hand"
	var pose := Transform3D(Basis.IDENTITY, Vector3(0.2, 1.3, -0.5))
	for key in ["aim", "grip"]: tracker.set_pose(key, pose, Vector3.ZERO, Vector3.ZERO, XRPose.XR_TRACKING_CONFIDENCE_HIGH)
	XRServer.add_tracker(tracker)
	var head := XRPositionalTracker.new(); head.type = XRServer.TRACKER_HEAD; head.name = "head"
	head.set_pose("default", Transform3D.IDENTITY, Vector3.ZERO, Vector3.ZERO, XRPose.XR_TRACKING_CONFIDENCE_HIGH)
	XRServer.add_tracker(head)
	main.display.preview = false; main.display.session_state = "session_focussed"
	for frame in 50: main._update_controller_feedback(0.01)
	for frame in 100:
		head.set_pose("default", Transform3D(Basis(Vector3.UP, frame * 0.03), Vector3(frame * 0.01, 1.6, 0)), Vector3.ZERO, Vector3.ZERO, XRPose.XR_TRACKING_CONFIDENCE_HIGH)
		main.world = Transform3D(Basis(Vector3.UP, frame * 0.02), Vector3(frame * 0.02, 0, 0))
		main._update_controller_feedback(0.01)
	check(main.controller_feedback.opacity("right_hand") == 0.0, "Production raw sampling ignores head motion and world-origin motion")
	var saved_scale := XRServer.world_scale; XRServer.world_scale = 2.0
	for frame in 30: main._update_controller_feedback(0.01)
	check(main._controller_activity("right_hand").position == pose.origin and main.controller_feedback.opacity("right_hand") == 0.0, "World scale is not mistaken for physical controller displacement")
	XRServer.world_scale = saved_scale
	for touch in ["trigger_touch", "primary_touch", "ax_touch", "by_touch"]:
		main._on_controller_button(touch, "right_hand"); main._update_controller_feedback(0.01)
		check(main.controller_feedback.opacity("right_hand") == 0.0 and main.controller_bindings.down.right_hand.is_empty(), "Touch is neither wake nor a click: " + touch)
	tracker.invalidate_pose("aim"); tracker.invalidate_pose("grip"); main._update_controller_feedback(0.01)
	pose.origin.x += 0.4
	for key in ["aim", "grip"]: tracker.set_pose(key, pose, Vector3.ZERO, Vector3.ZERO, XRPose.XR_TRACKING_CONFIDENCE_HIGH)
	for frame in 60: main._update_controller_feedback(0.01)
	check(main.controller_feedback.opacity("right_hand") == 0.0, "Runtime tracking loss and recovery do not wake a hidden controller")
	pose.origin.x += 0.4
	tracker.set_pose("grip", pose, Vector3.ZERO, Vector3.ZERO, XRPose.XR_TRACKING_CONFIDENCE_LOW)
	check(main._controller_activity("right_hand").is_empty(), "Estimated grip data cannot supply motion evidence")
	main._update_controller_feedback(0.01)
	tracker.set_pose("grip", pose, Vector3.ZERO, Vector3.ZERO, XRPose.XR_TRACKING_CONFIDENCE_HIGH)
	for frame in 60: main._update_controller_feedback(0.01)
	check(main.controller_feedback.opacity("right_hand") == 0.0, "Confidence recovery rebases instead of accepting the corrected position")
	main._on_system_recentered(); pose.origin.x += 0.4
	for key in ["aim", "grip"]: tracker.set_pose(key, pose, Vector3.ZERO, Vector3.ZERO, XRPose.XR_TRACKING_CONFIDENCE_HIGH)
	for frame in 60: main._update_controller_feedback(0.01)
	check(main.controller_feedback.opacity("right_hand") == 0.0, "A system recenter rebases raw pose changes")
	head.invalidate_pose("default"); main._update_controller_feedback(0.01)
	head.set_pose("default", Transform3D.IDENTITY, Vector3.ZERO, Vector3.ZERO, XRPose.XR_TRACKING_CONFIDENCE_HIGH)
	for frame in 60: main._update_controller_feedback(0.01)
	check(main.controller_feedback.opacity("right_hand") == 0.0, "Head tracking recovery does not revive stationary controllers")
	main.display.session_state = "session_visible"; main._on_input_session_changed(); main._update_controller_feedback(0.01)
	main.display.session_state = "session_focussed"; main._on_input_session_changed()
	for frame in 60: main._update_controller_feedback(0.01)
	check(main.controller_feedback.opacity("right_hand") == 0.0, "Regaining input focus does not wake an idle controller")
	main.controller_feedback.rebase()
	var playing: bool = video.requested_play
	main._on_controller_button("ax_button", "right_hand"); main._update_controller_feedback(0.0)
	check(main.controller_feedback.opacity("right_hand") == 1.0 and video.requested_play != playing, "First A press during tracking settling wakes and toggles playback in that same event")
	main._on_controller_release("ax_button", "right_hand")
	for frame in 510: main._update_controller_feedback(0.01)
	main._process_sticks(Vector2.ZERO, Vector2.ZERO, 0.01)
	main._process_sticks(Vector2(0.6, 0.6), Vector2.ZERO, 0.01); main._update_controller_feedback(0.01)
	check(main.controller_feedback.opacity("left_hand") == 0.0 and main.stick_controls.active_hands.is_empty(), "A diagonal with no dispatched action cannot wake feedback")
	var before: float = video.screen_scale
	main._process_sticks(Vector2.ZERO, Vector2(0, 0.8), 0.1); main._update_controller_feedback(0.0)
	check(main.controller_feedback.opacity("right_hand") == 1.0 and video.screen_scale > before, "Accepted right-stick input wakes and scales without an extra threshold")
	main.stick_controls.suspend()
	check(main.stick_controls.active_hands.is_empty(), "Suspended input cannot hold feedback awake")
	XRServer.remove_tracker(tracker); XRServer.remove_tracker(head)
	main.controller_feedback.free(); main.free()

func run() -> void:
	activity(); motion_rules()
	var video := preload("res://scripts/mpv_video_display.gd").new(); video.history_enabled = false
	root.add_child(video); video.set_process(false)
	video.platform = preload("res://tests/test_player_menu.gd").Host.new()
	video.local_uri = "file:///feedback.mp4"; video.media.begin(7); video.media.state = "playing"
	var main := InputMain.new(); main.video = video
	main.settings_path = "user://controller-feedback.cfg"
	var menu := preload("res://scripts/player_menu.gd").new(); menu.state_provider = main._menu_state
	root.add_child(menu); menu.set_process(false); menu.dismiss(); main.player_menu = menu; main.video_menu = menu
	var library := preload("res://scripts/library_menu.gd").new(); root.add_child(library)
	library.set_process(false); library.dismiss(); main.recent_menu = library
	main.controller_feedback = Feedback.new(); root.add_child(main.controller_feedback)
	tracked_input(video, menu, library)
	var eye := Vector3(0, 1.6, 0)
	for curve in [0.0, 0.7]:
		video.geometry = 0; video.flat_pose = Transform3D(Basis.IDENTITY, eye + Vector3(0, 0, -2))
		video.screen_curve = curve; video.screen_scale = 1.0; video.screen_distance = 2.0
		video._apply_geometry(); video.panel.visible = true
		for hand in Bindings.HANDS:
			main.rays[hand] = [eye, Vector3.FORWARD]
			main.controller_feedback.wake(hand)
			main._update_controller_feedback(0.01)
			check(main.controller_feedback.hands[hand].nodes.dot.visible, "Production route shows a hit without a panel")
			for corner in 4:
				video.set_screen_scale(1.0)
				var target: Vector3 = video.panel.to_global(video.screen_corner(corner))
				check(video.screen_hit(eye, target - eye) != null, "Actual flat/curved corner intersects: %s/%d" % [str(curve), corner])
				main.rays[hand] = [eye, (target - eye).normalized()]
				main._update_corner_hover()
				check(video._handles[corner].visible, "Either controller highlights every corner")
				main._on_controller_button("trigger_click", hand)
				check(main._grab.get("resize_only", false), "Physical trigger locks corner resizing")
				var centre: Vector3 = video.panel.global_position
				var plane: Variant = video.screen_point(eye, target - eye)
				main.rays[hand][1] = (video.panel.to_global(plane * 1.4) - eye).normalized()
				main._update_grab()
				check(video.screen_scale > 1.0 and video.panel.global_position == centre and video.screen_distance == 2.0, "All four corners scale without moving centre or depth")
				main._on_controller_release("trigger_click", hand)
				check(main._grab.is_empty() and not menu.visible, "Resize release never opens controls")
			# A same-hand chord takes over either a grip move or an already changing corner.
			main.controller_bindings.assign("follow_video", Bindings.bind(hand, "by_button", Bindings.MODIFIERS), true)
			for trigger_first in [false, true]:
				video.set_screen_scale(1.0)
				var target: Vector3 = video.panel.to_global(video.screen_corner(1))
				main.rays[hand] = [eye, (target - eye).normalized()]
				main.controller_feedback.hands[hand].age = Feedback.IDLE_SECONDS
				main._on_controller_button("trigger_click" if trigger_first else "grip_click", hand)
				check(main.controller_feedback.hands[hand].age == 0.0, "Either first modifier wakes immediately without consuming its operation")
				main.pose.origin.x += 0.04; main._update_interface_move()
				if trigger_first:
					var plane: Vector3 = video.screen_point(eye, target - eye)
					main.rays[hand][1] = (video.panel.to_global(plane * 1.25) - eye).normalized(); main._update_grab()
				main._on_controller_button("grip_click" if trigger_first else "trigger_click", hand)
				check(main.controller_feedback.hands[hand].age == 0.0, "Second modifier preserves immediate feedback in either order")
				var scale: float = video.screen_scale
				main.rays[hand][1] = Vector3(0.6, 0, -1).normalized(); main._update_grab()
				check(main._grab.is_empty() and main.interface_move.capture.is_empty() and video.screen_scale == scale, "Both modifier orders stop corner/move ownership without a jump")
				var following: bool = main.view_follow.enabled
				main._on_controller_button("by_button", hand)
				check(main.view_follow.enabled != following, "Chord executes after takeover in either order")
				for input in ["by_button", "trigger_click", "grip_click"]: main._on_controller_release(input, hand)
				check(not menu.visible, "Chord releases do not resurrect deferred controls")
			main.controller_bindings.restore_all()
		# Test actual curved hit points inside the panel and clear misses outside it.
		var x: float = video._flat.size.x * 0.25
		var local := Vector3(x, 0, 0)
		if curve > 0:
			var radius: float = video._curve_radius(); local = Vector3(sin(x / radius) * radius, 0, (1.0 - cos(x / radius)) * radius)
		var target: Vector3 = video.panel.to_global(local)
		var hit: Variant = video.screen_hit(eye, target - eye)
		check(hit != null and hit.distance_to(target) < 0.0001, "Reticle lies on the curved surface rather than the drag plane")
		check(video.screen_hit(eye, Vector3.UP) == null, "Outside rays cannot hit a curved/flat screen")
	# Default and mapped dispatch must both scale flat video; explicit old volume maps survive.
	video.screen_curve = 0.0; video.flat_pose = Transform3D(Basis.IDENTITY, eye + Vector3(0, 0, -2)); video._apply_geometry()
	for hand in Bindings.HANDS:
		main.rays[hand] = [eye, (video.panel.global_position - eye).normalized()]
		main._on_controller_button("grip_click", hand)
		check(main.interface_move.pending(), "Picture body uses grip movement rather than resizing")
		main._process_sticks(Vector2.ZERO, Vector2.ZERO, 0.1)
		var distance: float = video.screen_distance; var scale: float = video.screen_scale
		var other := Vector2(0, 1); var centre := Vector2.ZERO
		main._process_sticks(centre if hand == "left_hand" else other, other if hand == "left_hand" else centre, 0.1)
		check(is_equal_approx(video.screen_distance, distance), "Other hand's stick cannot push a gripped picture")
		main._process_sticks(other if hand == "left_hand" else centre, centre if hand == "left_hand" else other, 0.1)
		main._on_controller_release("grip_click", hand)
		check(video.screen_distance > distance and video.screen_scale == scale, "Grip plus own stick pushes the picture without scaling")
	for mapped in [false, true]:
		main.controller_bindings.restore_all()
		if mapped: main.controller_bindings.assign("subtitles", Bindings.bind("right_hand", "by_button", Bindings.MODIFIERS), true)
		video.set_screen_scale(1.0); var distance: float = video.screen_distance
		main._process_sticks(Vector2.ZERO, Vector2.ZERO, 0.1)
		main._process_sticks(Vector2.ZERO, Vector2(0, 1), 0.1)
		check(video.screen_scale > 1.0 and video.screen_distance == distance, "Default/mapped right up scales flat video without changing distance")
		main._process_sticks(Vector2.ZERO, Vector2.ZERO, 0.1)
		var saved := ConfigFile.new(); saved.load(main.settings_path)
		check(is_equal_approx(saved.get_value("screen", "scale", 0.0), video.screen_scale), "Stick release saves scale")
		var before: float = video.screen_scale
		library.visible = true
		main._process_sticks(Vector2.ZERO, Vector2(0, 1), 0.1)
		check(video.screen_scale == before, "Library list owns the stick and blocks picture scaling")
		library.dismiss(); main._process_sticks(Vector2.ZERO, Vector2(0, 1), 0.1)
		check(video.screen_scale == before, "Leaving a list requires the stick to recenter")
	# A saved chord switches dispatch to mapped input. Each centered deflection must
	# release the previous continuous direction, including across media projections.
	main.controller_bindings.restore({"version": 1, "bindings": {
		"alpha": [Bindings.bind("right_hand", "by_button", Bindings.MODIFIERS)],
		"next_video": [Bindings.bind("right_hand", "stick_right", Bindings.MODIFIERS)],
		"play": [Bindings.bind("right_hand", "ax_button")], "subtitles": []}})
	var layer := preload("res://scripts/video_layer.gd").new(null)
	var origin := XROrigin3D.new(); root.add_child(origin)
	for projection in [0, 1, 2, 3]:
		video.geometry = projection; video._apply_geometry()
		video.set_screen_scale(1.0); video.view_zoom = 0.0
		main.stick_controls.suspend()
		for direction in [1.0, -1.0, 1.0, -1.0]:
			main._process_sticks(Vector2.ZERO, Vector2.ZERO, 0.1)
			var before: float = video.screen_scale if projection == 0 else video.view_zoom
			var width: float = layer.layer_values(video, origin)[13] if projection == 0 else 0.0
			for frame in 3: main._process_sticks(Vector2.ZERO, Vector2(0, direction), 0.1)
			var after: float = video.screen_scale if projection == 0 else video.view_zoom
			check((after - before) * direction > 0.0, "Mapped zoom changes direction after recenter: %d / %s" % [projection, str(direction)])
			if projection == 0:
				check((layer.layer_values(video, origin)[13] - width) * direction > 0.0 and video.panel.mesh.size == video._flat.size, "Flat zoom updates both rendered mesh and compositor width")
	video.geometry = 0; video._apply_geometry(); origin.free()
	main.controller_bindings.restore_all()
	main.rays.right_hand = [eye, (video.panel.to_global(video.screen_corner(1)) - eye).normalized()]
	main.rays.left_hand = [eye, (video.panel.to_global(video.screen_corner(0)) - eye).normalized()]
	main._on_controller_button("trigger_click", "right_hand")
	var locked_scale: float = video.screen_scale
	main._process_sticks(Vector2.ZERO, Vector2.ZERO, 0.1)
	main._process_sticks(Vector2(0, 1), Vector2(0, 1), 0.1)
	check(video.screen_scale == locked_scale, "Corner capture blocks ordinary stick scaling and volume")
	main._on_controller_button("trigger_click", "left_hand")
	main._on_controller_button("grip_click", "left_hand")
	check(main._grab.get("hand", "") == "right_hand" and main.interface_move.capture.is_empty(), "Another hand cannot steal a corner resize")
	main._on_controller_release("trigger_click", "left_hand"); main._on_controller_release("grip_click", "left_hand")
	check(main._grab.get("hand", "") == "right_hand" and not menu.visible, "Other-hand release cannot finish resizing or show controls")
	main._cancel_pointer("right_hand"); main._on_controller_release("trigger_click", "right_hand")
	check(main._grab.is_empty() and not menu.visible, "Tracking cancellation of a resize cannot become a controls tap")
	# A normal video transport shares the zoom mapping and the controller idle deadline.
	menu.visible = true; video.requested_play = true
	menu.refresh()
	main.rays.clear(); main._menu_touched_ms = Time.get_ticks_msec()
	main.controller_bindings.assign("alpha", Bindings.bind("right_hand", "by_button", Bindings.MODIFIERS), true)
	video.set_screen_scale(1.0)
	for direction in [1.0, -1.0]:
		main._process_sticks(Vector2.ZERO, Vector2.ZERO, 0.1)
		var before: float = video.screen_scale
		main._process_sticks(Vector2.ZERO, Vector2(0, direction), 0.2)
		check((video.screen_scale - before) * direction > 0.0 and menu.visible, "Visible transport allows mapped flat zoom in both directions")
	main._process_sticks(Vector2.ZERO, Vector2.ZERO, 0.1)
	check(main.CONTROLS_HIDE_MS == int(Feedback.IDLE_SECONDS * 1000.0), "Transport and controllers use one five-second idle setting")
	main.pose.origin.x += 0.05; main._update_controller_feedback(0.0)
	main._update_controller_feedback(4.0)
	main._menu_touched_ms = Time.get_ticks_msec() - 4000; main._update_controls_visibility(menu)
	check(menu.visible and Bindings.HANDS.all(func(hand): return main.controller_feedback.opacity(hand) == 1.0), "Stationary controllers stay visible while the transport waits to hide")
	main._update_controller_feedback(1.1)
	main._menu_touched_ms = Time.get_ticks_msec() - main.CONTROLS_HIDE_MS - 1; main._update_controls_visibility(menu)
	main._update_controller_feedback(0.0)
	check(not menu.visible and Bindings.HANDS.all(func(hand): return main.controller_feedback.opacity(hand) == 0.0), "Idle transport and stationary controllers hide together without a world-ray flash")
	for frame in 40: main._update_controller_feedback(0.01)
	main.activity_pose.origin.x += 0.1
	for frame in 14: main._update_controller_feedback(0.01)
	check(Bindings.HANDS.all(func(hand): return main.controller_feedback.opacity(hand) == 1.0), "Obvious movement wakes controllers after confirmation following the shared hide deadline")
	var bindings := Bindings.new()
	bindings.restore({"version":1,"bindings":{"flat_volume_up":[Bindings.bind("right_hand","stick_up")]}})
	check(bindings.resolve("right_hand", "stick_up", "video_flat") == "flat_volume_up" and bindings.bindings("flat_zoom_in").is_empty(), "Explicit saved volume wins over the new default")
	bindings.restore({"version":1,"bindings":{"flat_volume_up":[]}})
	check(bindings.resolve("right_hand", "stick_up", "video_flat").is_empty(), "An explicitly disabled old right-up binding stays disabled")
	var page := preload("res://scripts/controls_page.gd").new(library)
	check(page.items().any(func(row): return row.title == "Resize picture" and row.fixed == "Corner + trigger"), "Controls include fixed corner resizing")
	check(page.items().any(func(row): return row.title == "Controller / ray"), "Controls include wake and idle visibility")
	var action_ids := page.items().map(func(row): return row.get("id", ""))
	check(action_ids.find("flat_zoom_in") + 1 == action_ids.find("flat_zoom_out") and action_ids.find("flat_zoom_out") < action_ids.find("volume_up"), "Controls place both flat zoom directions together near playback shortcuts")
	main.controller_feedback.free(); library.free(); menu.free(); main.free(); video.free()
	for failure in failures: push_error(failure)
	print("Controller feedback: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
