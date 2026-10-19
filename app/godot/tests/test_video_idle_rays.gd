extends SceneTree
const Video := preload("res://scripts/mpv_video_display.gd")
const Menu := preload("res://scripts/player_menu.gd")
const Feedback := preload("res://scripts/controller_feedback.gd")
var checks := 0
var failures: Array[String] = []

class PointerMain extends "res://scripts/main.gd":
	var rays := {}
	var pose := Transform3D(Basis.IDENTITY, Vector3(0.2, 1.4, -0.4))
	func _move_pose(_hand: String) -> Variant: return pose
	func _head_pose() -> Variant: return Transform3D.IDENTITY
	func _ray(hand: String) -> Variant: return rays.get(hand)
	func _controller_activity(_hand: String) -> Dictionary: return {"position": pose.origin, "direction": -pose.basis.z}

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func _initialize() -> void: call_deferred("run")

func run() -> void:
	var main := PointerMain.new(); main.settings_path = "user://video-idle-rays.cfg"
	var video := Video.new(); video.history_enabled = false; root.add_child(video); video.set_process(false)
	video.local_uri = "file:///ray-test.mp4"; video.media.begin(7); video.media.state = "playing"; video.control.observe(1000, 60000)
	video.platform = preload("res://tests/test_player_menu.gd").Host.new(); main.video = video
	var menu := Menu.new(); menu.state_provider = main._menu_state; root.add_child(menu); menu.set_process(false)
	main.video_menu = menu; main.player_menu = menu
	menu.seek_requested.connect(video.seek_absolute)
	var library := preload("res://scripts/library_menu.gd").new(); root.add_child(library); library.dismiss(); library.set_process(false); main.recent_menu = library
	main.controller_feedback = Feedback.new(); root.add_child(main.controller_feedback)
	menu.visible = true; menu.refresh()
	var timeline: Dictionary = menu._buttons.filter(func(button): return button.target == Menu.SEEK)[0]
	var origin: Vector3 = timeline.node.to_global(Vector3(0, 0, 1))
	main.rays = {"left_hand": [origin, -timeline.node.global_basis.z], "right_hand": [origin, -timeline.node.global_basis.z]}
	main.controller_feedback.wake("right_hand"); main._update_controller_feedback(0.01)
	for hand in main.ControllerBindings.HANDS: main._update_menu_pointer(hand)
	check(menu._pointers.right_hand.line.visible and menu._pointers.left_hand.line.visible, "A visible panel shows both tracked controller rays")
	check(menu._hover.right_hand == Menu.SEEK, "Active ray still precisely targets the timeline")
	main._menu_touched_ms = Time.get_ticks_msec() - main.CONTROLS_HIDE_MS - 1
	main._update_controls_visibility(menu)
	check(not menu.visible, "Stationary hover cannot keep an ordinary transport open indefinitely")
	menu.visible = true; menu.refresh()
	for frame in 510:
		main._update_controller_feedback(0.01)
		for hand in main.ControllerBindings.HANDS: main._update_menu_pointer(hand)
	check(menu._pointers.right_hand.line.visible and menu._pointers.left_hand.line.visible and menu.visible, "Pointers stay visible for as long as the panel is visible")
	main._on_controller_button("trigger_click", "right_hand")
	check(menu._seek_hand == "right_hand", "First click on a visible timeline acquires it without a wake-only click")
	for frame in 700:
		main._update_controller_feedback(0.01)
		main._update_menu_pointer("right_hand")
	check(menu._seek_hand == "right_hand" and menu._pointers.right_hand.line.visible and main.controller_feedback.opacity("left_hand") == 1.0, "A long timeline drag retains both tracked inputs while the panel is visible")
	var before: int = video.control.sequence
	main._process_sticks(Vector2(1, 0), Vector2(0, 1), 0.1)
	check(video.control.sequence == before and main.stick_controls.active_hands.is_empty(), "Timeline capture preserves shortcut isolation")
	main.playback_mode = "sequence"
	main.video_queue.assign([{"uri": video.local_uri, "title": "current"}, {"uri": "file:///next.mp4", "title": "next"}])
	video.media.state = "ended"
	video.media.last_pair = {"slot_token": 9, "source_epoch": 7, "frame_id": 179, "pts_us": 5966667, "inference_ran": true}
	video.media.playback = {"eof_source_resolved": true, "eof_pair_post_draw": true, "eof_presented_slot": 9,
		"eof_source_ticket": {"source_epoch": 7, "frame_id": 179, "pts_us": 5966667}}
	var ended_session: int = video.media.session_id
	main._advance_completed_video(video.local_uri, ended_session, before)
	check(not main._pending_video_end.is_empty() and menu._seek_hand == "right_hand", "Reaching EOF during a real timeline drag defers automatic next")
	main._on_controller_release("trigger_click", "right_hand")
	main._advance_completed_video(video.local_uri, ended_session, before)
	check(main._pending_video_end.is_empty() and video.local_uri == "file:///ray-test.mp4" and video.control.sequence > before, "Releasing the timeline submits its seek and cancels the old EOF transition")
	main.playback_mode = "single"; video.control.reject(); video._pending_revision.clear(); video.media.state = "playing"
	menu.dismiss(); main.controller_bindings.reset_inputs(); main.stick_controls.suspend()
	for projection in [0, 1, 2, 3]:
		video.geometry = projection; video._apply_geometry()
		main.controller_feedback.wake("right_hand")
		for frame in 50:
			main.pose.origin.x += 0.04; main.pose.basis = Basis(Vector3.UP, frame * 0.1)
			main._update_controller_feedback(0.01)
		check(main.controller_feedback.opacity("right_hand") == 0.0, "Movement and explicit wake cannot show models with no panel: %d" % projection)
		check(main.controller_feedback.hands.right_hand.nodes.values().all(func(node): return not node.visible), "No-panel rays and dots stay hidden: %d" % projection)
		main._grab = {"hand": "right_hand"}; main._update_controller_feedback(0.01)
		check(main.controller_feedback.opacity("right_hand") == 0.0, "A hidden-panel grip capture cannot show an input model")
		main._grab.clear()
		main.stick_controls.active_hands = {"right": true}; main._update_controller_feedback(0.01)
		check(main.controller_feedback.opacity("right_hand") == 0.0, "Playback shortcuts keep both model and ray hidden")
		main.stick_controls.active_hands.clear()
	menu.visible = true; menu.section = 1; menu.refresh()
	main.controller_feedback.wake("right_hand"); main._update_controller_feedback(0.01)
	for frame in 510: main._update_controller_feedback(0.01)
	main._update_menu_pointer("right_hand"); main._menu_touched_ms = 0; main._update_controls_visibility(menu)
	check(menu.visible and menu._pointers.right_hand.line.visible, "Settings keep their pointer visible without an idle deadline")
	main.pose.basis = Basis(Vector3.UP, deg_to_rad(8)); main._update_controller_feedback(0.01); main._update_menu_pointer("right_hand")
	check(menu._pointers.right_hand.line.visible, "Aim adjustments keep an already visible settings pointer usable")
	main._cancel_pointer("right_hand"); main.rays.erase("right_hand"); main._update_menu_pointer("right_hand")
	check(not menu._pointers.right_hand.line.visible and menu._seek_hand.is_empty(), "Tracking loss clears both pointer visuals and capture")
	for projection in [0, 1, 2, 3]:
		menu.dismiss(); video.geometry = projection; video._apply_geometry(); video.panel.visible = true
		main.controller_bindings.restore_all()
		var direction: Vector3 = (video.panel.to_global(video.screen_corner(1)) - Vector3(0, 1.6, 0)).normalized() if projection == 0 else Vector3.FORWARD
		main.rays.right_hand = [Vector3(0, 1.6, 0), direction]
		main._on_controller_button("trigger_click", "right_hand"); main._update_controller_feedback(0.01)
		check(not menu.visible and main._grab.is_empty() and main.controller_feedback.opacity("right_hand") == 0.0, "Trigger down does not flash feedback before a complete single click")
		main._on_controller_release("trigger_click", "right_hand"); main._update_controller_feedback(0.01)
		check(menu.visible and main.controller_feedback.opacity("right_hand") == 1.0, "Trigger release opens panel and feedback together")
		main.rays.right_hand = [Vector3(0, 1.6, 0), Vector3.UP]
		main._on_controller_button("trigger_click", "right_hand"); main._on_controller_release("trigger_click", "right_hand")
		main._update_controller_feedback(0.0)
		check(not menu.visible and main.controller_feedback.opacity("right_hand") == 0.0, "Outside click hides panel and feedback without a residual five seconds")
	for hand in main.ControllerBindings.HANDS:
		main.controller_bindings.assign("follow_video", main.ControllerBindings.bind(hand, "by_button", main.ControllerBindings.MODIFIERS), true)
		main.rays[hand] = [Vector3(0, 1.6, 0), Vector3.FORWARD]
		for trigger_first in [false, true]:
			var before_follow: bool = main.view_follow.enabled
			for input in ["trigger_click" if trigger_first else "grip_click", "grip_click" if trigger_first else "trigger_click", "by_button"]:
				main._on_controller_button(input, hand); main._update_controller_feedback(0.01)
				check(not menu.visible and main.controller_feedback.opacity(hand) == 0.0, "Every chord key stays invisible in either modifier order")
			check(main.view_follow.enabled != before_follow, "Hidden chord still executes normally")
			for input in ["by_button", "trigger_click", "grip_click"]: main._on_controller_release(input, hand)
			check(not menu.visible, "Releasing a hidden chord cannot open the controls")
	main.controller_bindings.restore_all()
	# Gesture recognition uses its existing input route while presentation is hidden.
	var pointer := main.HandPointer.new(); pointer.source = "hand"; pointer.ray = main.rays.right_hand
	main.hand_pointers.right_hand = pointer
	main._dispatch_hand_input({"right_hand": {"source": "hand", "pressed": true, "down": true, "tracked": true}}, 0.01)
	main._update_controller_feedback(0.01)
	check(not menu.visible and main.controller_feedback.opacity("right_hand") == 0.0, "Pinch down is recognized without showing the hand before its panel")
	main._dispatch_hand_input({"right_hand": {"source": "hand", "released": true, "down": false, "tracked": true}}, 0.01)
	check(menu.visible and main._input_feedback_visible(), "A completed pinch still opens controls while models were hidden")
	main.controller_feedback.free(); library.free(); menu.free(); main.free(); video.free()
	for failure in failures: push_error(failure)
	print("Video idle rays: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
