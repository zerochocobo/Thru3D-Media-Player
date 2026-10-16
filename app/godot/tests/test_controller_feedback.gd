extends SceneTree
const Feedback := preload("res://scripts/controller_feedback.gd")
const Bindings := preload("res://scripts/controller_bindings.gd")
var checks := 0
var failures: Array[String] = []

class InputMain extends "res://scripts/main.gd":
	var pose := Transform3D(Basis.IDENTITY, Vector3(0.2, 1.4, -0.4))
	var rays := {}
	func _move_pose(_hand: String) -> Variant: return pose
	func _head_pose() -> Variant: return Transform3D(Basis.IDENTITY, Vector3(0, 1.6, 0))
	func _ray(hand: String) -> Variant: return rays.get(hand)

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func _initialize() -> void: call_deferred("run")

func activity() -> void:
	var feedback := Feedback.new(); root.add_child(feedback)
	var idle_frames := int(ceil((Feedback.IDLE_SECONDS + 0.1) / 0.01))
	var pose := Transform3D(Basis.IDENTITY, Vector3(0.2, 1.4, -0.4))
	var point := Vector3(0, 1.6, -2)
	var ray := [pose.origin, (point - pose.origin).normalized()]
	check(feedback.update_hand("right_hand", pose, ray, point, false, false, 0.01) == 1.0, "Tracking starts with visible world feedback")
	var nodes: Dictionary = feedback.hands.right_hand.nodes
	check(nodes.line.visible and nodes.dot.visible and nodes.dot.global_position.distance_to(point) < 0.01, "World ray terminates at the media hit without any menu")
	for frame in 350:
		var jitter := pose.translated(Vector3(sin(frame) * 0.001, 0, 0))
		feedback.update_hand("right_hand", jitter, ray, point, false, false, 0.01)
	check(feedback.opacity("right_hand") == 1.0 and nodes.dot.visible, "Controller feedback remains visible beyond the old three-second deadline")
	for frame in range(350, idle_frames): feedback.update_hand("right_hand", pose, ray, point, false, false, 0.01)
	check(feedback.opacity("right_hand") == 0.0 and not nodes.line.visible and not nodes.dot.visible, "Sub-threshold tracking jitter cannot prevent idle hiding")
	pose.origin.x += 0.02
	feedback.update_hand("right_hand", pose, ray, point, false, false, 0.01)
	check(nodes.line.visible and nodes.dot.visible, "Translation wakes the ray immediately")
	for frame in idle_frames: feedback.update_hand("right_hand", pose, ray, point, false, false, 0.01)
	pose.basis = Basis(Vector3.UP, 0.05)
	feedback.update_hand("right_hand", pose, ray, point, false, false, 0.01)
	check(nodes.line.visible, "Wrist rotation also wakes the ray")
	for frame in idle_frames: feedback.update_hand("right_hand", pose, ray, point, true, false, 0.01)
	check(nodes.line.visible and feedback.opacity("right_hand") == 1.0, "Held input/capture cannot time out")
	feedback.update_hand("right_hand", pose, ray, null, false, false, 0.01)
	check(nodes.line.visible and not nodes.dot.visible, "Empty space has a ray but no false hit dot")
	feedback.update_hand("right_hand", pose, ray, point, false, true, 10.0)
	check(not nodes.line.visible and feedback.opacity("right_hand") == 1.0, "Menus own the ray while keeping the controller awake")
	feedback.update_hand("right_hand", pose, ray, point, false, false, 0.0)
	check(feedback.opacity("right_hand") == 0.0 and not nodes.line.visible, "Closing an idle menu does not restart another controller hide countdown")
	feedback.update_hand("right_hand", null, null, null, false, false, 0.01)
	check(not nodes.line.visible and feedback.opacity("right_hand") == 0.0, "Tracking loss hides stale feedback")
	feedback.update_hand("right_hand", pose, ray, point, false, false, 0.01)
	feedback.update_hand("left_hand", pose, ray, point, false, false, 0.01)
	for frame in idle_frames: feedback.update_hand("left_hand", pose, ray, point, false, false, 0.01)
	check(feedback.opacity("right_hand") == 1.0 and feedback.opacity("left_hand") == 0.0, "Hands have separate idle clocks")
	feedback.wake("left_hand"); feedback.update_hand("left_hand", pose, ray, point, false, false, 0.01)
	check(feedback.opacity("left_hand") == 1.0, "Button activity wakes an unmoving hand")
	check(nodes.dot.material_override.no_depth_test and nodes.dot.material_override.render_priority > 100, "Reticle draws above video holes and masks")
	feedback.free()

func run() -> void:
	activity()
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
	var eye := Vector3(0, 1.6, 0)
	for curve in [0.0, 0.7]:
		video.geometry = 0; video.flat_pose = Transform3D(Basis.IDENTITY, eye + Vector3(0, 0, -2))
		video.screen_curve = curve; video.screen_scale = 1.0; video.screen_distance = 2.0
		video._apply_geometry(); video.panel.visible = true
		for hand in Bindings.HANDS:
			main.rays[hand] = [eye, Vector3.FORWARD]
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
				main._on_controller_button("trigger_click" if trigger_first else "grip_click", hand)
				main.pose.origin.x += 0.04; main._update_interface_move()
				if trigger_first:
					var plane: Vector3 = video.screen_point(eye, target - eye)
					main.rays[hand][1] = (video.panel.to_global(plane * 1.25) - eye).normalized(); main._update_grab()
				main._on_controller_button("grip_click" if trigger_first else "trigger_click", hand)
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
	main.pose.origin.x += 0.02; main._update_controller_feedback(0.01)
	check(Bindings.HANDS.all(func(hand): return main.controller_feedback.opacity(hand) == 1.0), "Movement still wakes controllers immediately after the shared hide deadline")
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
