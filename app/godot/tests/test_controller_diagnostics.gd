extends SceneTree
## Real controller signals through Main, plus bounded logging and privacy at the export boundary.
const Diagnostics := preload("res://scripts/controller_diagnostics.gd")
const Log := preload("res://scripts/diagnostic_log.gd")
const Privacy := preload("res://scripts/media_privacy.gd")
const Bindings := preload("res://scripts/controller_bindings.gd")
const Sticks := preload("res://scripts/player_stick_controls.gd")
var checks := 0
var failures: Array[String] = []
var output := ProjectSettings.globalize_path("res://../../build/output/controller-diagnostics-20261111")

class InputMain extends "res://scripts/main.gd":
	var focused := true
	var moving := false
	func _input_focused() -> bool: return focused
	func _cinema_interaction_owns() -> bool: return moving or super._cinema_interaction_owns()

class Protected extends RefCounted:
	var protected := true

func expect(ok: bool, label: String) -> void:
	checks += 1
	if not ok: failures.append(label)

func _initialize() -> void: _run.call_deferred()

func _run() -> void:
	DirAccess.make_dir_recursive_absolute(output)
	var saved_path := Log.path
	var saved_rotated := Log.rotated_path
	var saved_mode := Privacy.mode
	var saved_vault := Privacy.vault
	Log.path = output.path_join("events.jsonl"); Log.rotated_path = output.path_join("events.1.jsonl")
	Privacy.mode = Privacy.ALL; Privacy.vault = null
	var trace := Diagnostics.new()
	var context := {"profile": "/interaction_profiles/bytedance/pico4_controller", "focused": true}
	for hand in Bindings.HANDS:
		for input in Diagnostics.BUTTONS:
			trace.button(0, hand, input, true, "blocked.test", context)
			trace.button(1, hand, input, false, "routed.release", context)
			expect(trace.buttons_seen.get(hand + "/" + input) == 1, hand + " records " + input)
	expect(trace.recent.size() == Diagnostics.BUTTONS.size() * 4, "Both edges of every physical button are kept")
	context.focused = false
	expect(trace.recent[0].context.focused, "An event retains its original input context")
	trace.clear()
	var sampler := func(_hand): return context
	trace.stick(0, "left_hand", Vector2.ZERO, Vector2.ZERO, "idle.centered", sampler)
	trace.stick(16, "left_hand", Vector2.RIGHT, Vector2.ZERO, "blocked.not_focused", sampler)
	trace.stick(32, "left_hand", Vector2.ZERO, Vector2.ZERO, "blocked.not_focused", sampler)
	expect(trace.recent.size() == 3, "A 16 ms flick and return are not lost to analogue throttling")
	expect(trace.recent[1].raw == [1.0, 0.0] and trace.recent[1].effective == [0.0, 0.0], "Raw input remains visible when playback receives zero")
	expect(trace.recent[1].route == "blocked.not_focused", "The actual block reason accompanies the raw deflection")
	trace.clear()
	for frame in 720:
		trace.stick(frame * 14, "right_hand", Vector2.RIGHT, Vector2.RIGHT, "blocked.wait_for_center", sampler)
	expect(trace.recent.size() <= 6 and trace.recent.size() >= 5, "Held sticks log once every two seconds, not every XR frame")
	trace.stick(11000, "right_hand", Vector2(NAN, INF), Vector2.ZERO, "blocked.non_finite_stick", sampler)
	expect(trace.recent.back().raw == "non_finite" and JSON.parse_string(JSON.stringify(trace.snapshot())) is Dictionary, "Invalid axes remain valid export JSON")
	trace.clear()
	for index in 200: trace.button(index, "left_hand", "ax_button", true, "ignored.duplicate_press", {})
	expect(trace.recent.size() == Diagnostics.EVENTS_PER_SECOND and trace.suppressed == 160, "An event storm is bounded and its dropped count is explicit")
	for index in 80: trace.button(2000 + index * 1001, "right_hand", "by_button", true, "routed.back", {})
	expect(trace.recent.size() == Diagnostics.RECENT_LIMIT, "The exported recent ring has a fixed capacity")
	var exported := trace.snapshot()
	exported.recent.clear()
	expect(not trace.recent.is_empty(), "Exporting cannot mutate the recorder")
	for mode in [Privacy.LOCAL, Privacy.NONE]:
		Privacy.mode = mode
		trace.button(100000, "left_hand", "grip_click", true, "blocked.test", {})
		expect(trace.snapshot() == {"recording": false, "reason": "privacy"} and trace.recent.is_empty(), "Private history mode clears input evidence: " + mode)
	Privacy.mode = Privacy.ALL
	trace.button(100001, "left_hand", "grip_click", true, "blocked.test", {})
	Privacy.vault = Protected.new()
	expect(trace.snapshot().recording == false and trace.recent.is_empty(), "Protected viewing does not expose an earlier input ring")
	Privacy.vault = null
	var controls := Sticks.new()
	controls.suspend(); controls.poll(Vector2.RIGHT, Vector2.ZERO)
	expect(controls.diagnostic_routes.left == "blocked.wait_for_center", "Suspension reports the required return to centre")
	controls.poll(Vector2.ZERO, Vector2.ZERO)
	controls.poll(Vector2.RIGHT, Vector2.ZERO)
	expect(controls.diagnostic_routes.left == "routed.seek", "The same stick is routed after recentering")
	controls.poll_mapped(Vector2.UP, Vector2.ZERO, func(_hand, _input): return {})
	expect(controls.diagnostic_routes.left == "ignored.unbound", "An unbound mapped direction is distinguished from a latch")

	# Actual XRControllerTracker signals, before Main's focus and capture filters.
	var config := ConfigFile.new()
	config.set_value("appearance", "background", "dark")
	config.set_value("ui", "language", "en")
	config.save(output.path_join("settings.cfg"))
	var viewport := SubViewport.new()
	viewport.own_world_3d = true; root.add_child(viewport)
	var main := InputMain.new()
	main.settings_path = output.path_join("settings.cfg")
	viewport.add_child(main)
	main.set_process(false); main.video.set_process(false); main.photo.set_process(false); main.report_timer.stop()
	var trackers := {}
	for hand in Bindings.HANDS:
		var tracker := XRControllerTracker.new()
		tracker.name = hand
		tracker.set_tracker_profile("/interaction_profiles/bytedance/pico4_controller")
		for pose in ["aim", "grip"]:
			tracker.set_pose(pose, Transform3D(Basis.IDENTITY, Vector3(0, 1.5, -0.5)), Vector3.ZERO, Vector3.ZERO, XRPose.XR_TRACKING_CONFIDENCE_HIGH)
		XRServer.add_tracker(tracker); trackers[hand] = tracker
	await process_frame
	main.focused = false; main.controller_diagnostics.clear()
	for hand in Bindings.HANDS:
		for input in Bindings.BUTTONS + ["menu_button"]:
			trackers[hand].set_input(input, true)
			var event: Dictionary = main.controller_diagnostics.recent.back() if not main.controller_diagnostics.recent.is_empty() else {}
			expect(event.get("route") == "blocked.not_focused" and event.get("input") == input and event.get("pressed") == true, "Raw press is logged before the focus guard: " + hand + "/" + input)
			trackers[hand].set_input(input, false)
			expect(main.controller_diagnostics.recent.back().pressed == false, "Raw release is logged: " + hand + "/" + input)
	expect(main.controller_bindings.down.left_hand.is_empty() and main.controller_bindings.down.right_hand.is_empty(), "Logging does not let blocked buttons reach playback")
	main.controller_diagnostics.clear()
	trackers.left_hand.set_input("primary", Vector2(0.9, 0))
	var left := main._stick(main.left_controller)
	var right := main._stick(main.right_controller)
	main._process_sticks(left, right, 1.0 / 72.0)
	var axes: Dictionary = main.controller_diagnostics.snapshot().sticks.left_hand
	expect(axes.raw == [0.9, 0.0] and axes.effective == [0.0, 0.0] and axes.route == "blocked.not_focused", "Actual tracker axes survive the focus zeroing gate")
	main.focused = true; main._watch_owned = true
	main.controller_diagnostics.clear()
	trackers.right_hand.set_input("ax_button", true)
	expect(main.controller_diagnostics.recent.back().route == "blocked.wrist_watch", "The wrist watch reports its actual button ownership")
	trackers.right_hand.set_input("ax_button", false)
	main._watch_owned = false
	main.controller_diagnostics.clear()
	main._on_controller_button("grip_click", "right_hand")
	var grip: Dictionary = main.controller_diagnostics.recent.back()
	expect(grip.route == "ignored.no_move_target" or grip.route == "blocked.no_move_or_head_pose", "Grip misses are diagnosed without claiming movement succeeded")
	main._on_controller_release("grip_click", "right_hand")
	main.controller_diagnostics.clear()
	main.moving = true
	trackers.right_hand.set_input("ax_button", true)
	expect(main.controller_diagnostics.recent.back().route == "blocked.cinema_movement", "Cinema movement reports why A is inactive")
	trackers.right_hand.set_input("ax_button", false)
	main.moving = false
	main.video.local_uri = "file:///controller-diagnostics-fixture.mp4"
	main.video.media.begin(93); main.video.media.state = "playing"
	main.video.media.format.width = 1920; main.video.media.format.height = 1080
	main.video._apply_geometry(); main.video.history_enabled = false
	main.recent_menu.toggle()
	main.controller_diagnostics.clear()
	trackers.right_hand.set_input("ax_button", true)
	expect(main.controller_diagnostics.recent.back().route == "blocked.menu_owns_playback", "A library panel reports its playback shortcut guard")
	trackers.right_hand.set_input("ax_button", false)
	main.recent_menu.dismiss()
	main.screen_edit_lock.capture = {"hand": "right_hand"}
	main.controller_diagnostics.clear()
	main._controller_raw_sticks.clear(); main._controller_stick_blocks.clear()
	main._process_sticks(Vector2.RIGHT, Vector2.ZERO, 1.0 / 72.0)
	expect(main.controller_diagnostics.snapshot().sticks.left_hand.route == "blocked.screen_edit_capture", "A captured screen control reports stick ownership")
	main.screen_edit_lock.capture.clear()
	main.settings.set_value("screen", "edit_locked", true)
	main._stick_diagnostic_routes.clear()
	main._zoom_video(0.1)
	expect(main._stick_diagnostic_routes.get("right_hand") == "blocked.screen_locked", "A zoom blocked by the screen lock reports the actual denial")
	main.settings.set_value("screen", "edit_locked", false)
	trackers.right_hand.set_tracker_profile("/interaction_profiles/khr/simple_controller")
	var report: Dictionary = main._controller_input_report()
	expect(report.current.right_hand.profile.ends_with("simple_controller") and report.current.left_hand.profile.ends_with("pico4_controller"), "Export reports the current mapping independently for each hand")
	var header: String = main._diagnostic_header()
	expect(header.contains('"controller_input"') and header.contains('"buttons_seen"') and header.contains('"bindings"'), "The ordinary user log export includes input history and configured bindings")
	expect(not header.contains("file://") and not header.contains("http://"), "Input evidence contains no media identity")
	Privacy.mode = Privacy.NONE
	expect(not main._diagnostic_header().contains("buttons_seen"), "User log export obeys the existing privacy policy")
	for tracker in trackers.values(): XRServer.remove_tracker(tracker)
	viewport.queue_free(); await process_frame
	Privacy.mode = saved_mode; Privacy.vault = saved_vault
	Log.path = saved_path; Log.rotated_path = saved_rotated
	print("Controller diagnostics: %d checks, %d failures" % [checks, failures.size()])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)
