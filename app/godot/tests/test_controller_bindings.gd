extends SceneTree
const Bindings := preload("res://scripts/controller_bindings.gd")
const Main := preload("res://scripts/main.gd")
const Move := preload("res://scripts/interface_move.gd")
var checks := 0
var failures: Array[String] = []

class InputMain extends "res://scripts/main.gd":
	var pose := Transform3D(Basis.IDENTITY, Vector3(0, 1.5, -0.5))
	var pose_available := true
	var head_pose := Transform3D(Basis.IDENTITY, Vector3(0, 1.6, 0))
	var rays := {}
	func _move_pose(_hand: String) -> Variant: return pose if pose_available else null
	func _ray(hand: String) -> Variant: return rays.get(hand)
	func _head_pose() -> Variant: return head_pose

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func _initialize() -> void: call_deferred("run")

func run() -> void:
	var bindings := Bindings.new()
	var page_menu := Node3D.new()
	var page := preload("res://scripts/controls_page.gd").new(page_menu)
	var ordinary := page.items().filter(func(item): return item.has("id")).map(func(item): return item.id)
	check("drag_video" not in ordinary and "drag_photo" in ordinary, "Video trigger dragging is removed while photo dragging remains configurable")
	check(page.items().filter(func(item): return item.get("fixed", "") == "Trigger + stick ↑ / ↓").all(func(item): return item.scope == "Flat photos"), "Trigger movement help applies only to photos")
	check(page.items().any(func(item): return item.title == "Close video and return" and item.get("fixed", "") == "B / Y" and item.scope == "Video"), "Controls explain the fixed video Back shortcut")
	page.mode = 2
	var combinations := page.items().map(func(item): return item.id)
	check(not combinations.is_empty() and combinations.all(func(id): return id not in ordinary), "Combinations omit the ordinary controller operations")
	check(["play", "back10", "forward10", "volume_up", "zoom_in", "reset_video", "projection_video", "photo_next"].all(func(id): return id not in combinations), "Playback, navigation and other standard operations are absent from combinations")
	check(["subtitles", "passthrough_video", "grade_next", "subtitle_next", "audio_next"].all(func(id): return id in combinations), "Combinations retain the supplementary operations")
	check(["turn_180_video", "turn_180_photo", "previous_video", "next_video"].all(func(id): return id in combinations and bindings.bindings(id).is_empty()), "360 turns and video navigation are optional combinations without new defaults")
	page.bindings.clear("play")
	check(not page.items().any(func(item): return item.id == "play"), "Clearing a standard binding does not reinsert it in combinations")
	page.bindings.restore_all()
	page.bindings.assign("play", Bindings.bind("right_hand", "by_button", Bindings.MODIFIERS), true)
	var prior := page.bindings.snapshot()
	page.items()
	check(page.bindings.snapshot() == prior, "Filtering leaves existing custom bindings intact")
	page_menu.free()
	check(bindings.resolve("right_hand", "ax_button", "video_flat") == "play", "Quest/PICO semantic A preserves play")
	check(bindings.resolve("left_hand", "ax_button", "video_flat") == "library_video", "Left X stays the library")
	check(bindings.resolve("right_hand", "ax_button", "photo") == "photo_close" and bindings.resolve("left_hand", "ax_button", "photo") == "library_photo", "Photo A closes the expanded view and left X opens the library")
	check("photo_close" in ordinary and "photo_close" not in combinations, "The new close key appears in ordinary global controller settings")
	check(bindings.resolve("right_hand", "stick_up", "video_flat") == "flat_zoom_in", "Flat right up scales the screen")
	check(bindings.resolve("right_hand", "stick_up", "video_immersive") == "zoom_in", "Immersive right up is zoom")
	for hand in Bindings.HANDS:
		for context in ["video_flat", "video_immersive", "photo"]:
			check(bindings.resolve(hand, "grip_click", context) == ("move_photo" if context == "photo" else "move_video"), "Both grips default to movement in " + context)
	var fixed_before := bindings.snapshot()
	for item in bindings.definitions():
		if bindings.is_fixed(item.id):
			bindings.clear(item.id)
			check(not bindings.assign(item.id, Bindings.bind("right_hand", "trigger_click"), false, true).ok and not bindings.swap_binding(item.id, Bindings.bind("right_hand", "trigger_click")).ok, "Fixed movement cannot be cleared, reassigned or swapped")
		else:
			for hand in Bindings.HANDS:
				check(not bindings.assign(item.id, Bindings.bind(hand, "grip_click"), false, true).ok, "Reserved grip rejects " + item.id)
	check(bindings.snapshot() == fixed_before, "Rejected assignments leave the entire map intact")
	page_menu = Node3D.new(); page = preload("res://scripts/controls_page.gd").new(page_menu)
	check(page.items().filter(func(item): return item.get("id", "") in Bindings.FIXED_ACTIONS).all(func(item): return item.has("fixed") and item.fixed == page.bindings.label(item.id)), "Settings display both movement bindings as fixed rows")
	page.all_actions = true
	for item in page.items():
		if not item.has("id"): continue
		var field := page.binding_field(item.id)
		check(field.is_empty() if bindings.is_fixed(item.id) else field.choices.all(func(option): return not str(option.value).ends_with("/grip_click")), "Grip is unavailable to other action editors")
	page_menu.free()
	for language in ["zh", "zh_Hant", "ja"]:
		var catalog: Dictionary = preload("res://scripts/i18n.gd").translations[language]
		for item in bindings.definitions(): check(catalog.has(item.title), "Translated action: " + language + "/" + item.title)
		for item in preload("res://scripts/controls_page.gd").GESTURES:
			for field in ["title", "scope", "hint"]: check(catalog.has(item[field]), "Translated gesture: " + language + "/" + item[field])
		for text in ["Restore defaults", "Grip + trigger", "Target button", "Stick direction", "Controllers", "Gestures", "Combinations", "Movement range", "Unassigned", "Cancel"]:
			check(catalog.has(text), "Translated editor: " + language + "/" + text)
	check(not bindings.assign("play", Bindings.bind("right_hand", "menu_button")).ok, "System/menu recovery key cannot be rebound")
	check(not bindings.assign("play", Bindings.bind("right_hand", "ax_button", ["trigger_click"]), true).ok, "Chords require both grip and trigger")
	var choice := Bindings.bind("right_hand", "by_button", ["grip_click", "trigger_click"])
	var collision := bindings.assign("subtitles", choice, true)
	check(collision.ok and bindings.resolve("right_hand", "trigger_click", "video_flat").is_empty(), "Grip-first chords leave the fixed video UI trigger independent of shortcuts")
	var duplicate := bindings.assign("mute", choice, true)
	check(not duplicate.ok and "subtitles" in duplicate.conflicts, "An identical chord requires explicit conflict replacement")
	bindings.press("right_hand", "grip_click")
	check(bindings.resolve("right_hand", "ax_button", "video_flat").is_empty(), "Modifier cannot leak basic A while held")
	bindings.press("right_hand", "trigger_click")
	check(bindings.resolve("right_hand", "by_button", "video_flat") == "subtitles", "Grip then trigger then B resolves only the chord")
	bindings.release("right_hand", "trigger_click")
	check(bindings.resolve("right_hand", "by_button", "video_flat").is_empty(), "Partial chord cannot run")
	bindings.release("right_hand", "grip_click")
	check(bindings.resolve("right_hand", "ax_button", "video_flat") == "play", "Base A recovers after modifier release")
	bindings.press("right_hand", "trigger_click"); bindings.press("right_hand", "grip_click")
	check(bindings.resolve("right_hand", "by_button", "video_flat") == "subtitles", "Trigger then grip then B resolves the same chord")
	bindings.release("right_hand", "trigger_click"); bindings.release("right_hand", "grip_click")
	check(bindings.bindings("move_video").size() == 2, "Fixed grip movement can share a chord's starting grip")
	bindings.press("right_hand", "grip_click")
	check(bindings.resolve("right_hand", "grip_click", "video_flat") == "move_video", "Grip can arm movement without requiring delay")
	var data := bindings.snapshot()
	var restored := Bindings.new(); restored.restore(data)
	check(restored.snapshot() == data, "Map survives serialization/restart")
	var legacy := Bindings.new()
	legacy.restore({"version":1,"bindings":{"inspect":[Bindings.bind("right_hand","ax_button")]}})
	check(legacy.resolve("right_hand","ax_button","photo") == "inspect" and legacy.bindings("photo_close").is_empty(), "An existing custom photo A mapping survives addition of the new default")
	legacy.restore({"version":1,"bindings":{"play":[Bindings.bind("right_hand","grip_click")]}})
	check(legacy.resolve("right_hand","ax_button","photo") == "photo_close" and legacy.resolve("right_hand","grip_click","video_flat") == "move_video" and legacy.bindings("play").is_empty(), "Old grip playback yields to fixed movement")
	legacy.restore({"version":1,"move_scope":"all","bindings":{"play":[Bindings.bind("right_hand","by_button"), Bindings.bind("right_hand","grip_click"), Bindings.bind("right_hand","ax_button")], "mute":[Bindings.bind("left_hand","by_button")], "inspect":[Bindings.bind("left_hand","grip_click"), Bindings.bind("right_hand","grip_click")], "move_video":[], "move_photo":[Bindings.bind("right_hand","trigger_click")], "subtitles":[choice]}})
	check(legacy.bindings("play") == [Bindings.bind("right_hand","ax_button")] and legacy.bindings("mute").is_empty() and legacy.bindings("inspect").is_empty() and legacy.resolve("right_hand","by_button","video_flat").is_empty(), "Saved reserved grips/B/Y are dropped while other choices survive")
	check(legacy.move_scope == "all" and legacy.bindings("subtitles") == [choice] and Bindings.FIXED_ACTIONS.all(func(id): return legacy.bindings(id).size() == 2 and not legacy.overrides.has(id)), "Old cleared/reassigned movement restores both grips without losing scope or chords")
	var migrated := Bindings.new(); migrated.restore(legacy.snapshot())
	check(migrated.snapshot() == legacy.snapshot(), "Migrated binding data remains stable after restart")
	for previous_drag in [[], [Bindings.bind("left_hand", "trigger_click")], [Bindings.bind("right_hand", "trigger_click")]]:
		legacy.restore({"version": 1, "move_scope": "all", "bindings": {"drag_video": previous_drag,
			"play": [Bindings.bind("right_hand", "trigger_click"), Bindings.bind("right_hand", "ax_button")],
			"drag_photo": [], "subtitles": [choice]}})
		check(not legacy.overrides.has("drag_video") and legacy.move_scope == "all" and legacy.bindings("subtitles") == [choice]
			and legacy.bindings("drag_photo").is_empty() and legacy.bindings("play") == [Bindings.bind("right_hand", "ax_button")],
			"Legacy cleared/rebound video drag and trigger shortcuts retire without resetting other preferences")
		var round_trip := Bindings.new(); round_trip.restore(legacy.snapshot())
		check(round_trip.snapshot() == legacy.snapshot(), "Retired video drag migration survives restart")
	check(not bindings.assign("play", Bindings.bind("right_hand", "trigger_click"), false, true).ok,
		"Video shortcuts cannot take the plain UI trigger")
	check(bindings.resolve("right_hand", "trigger_click", "photo") == "drag_photo", "Photo trigger dragging retains its default")
	check(not legacy.assign("play", Bindings.bind("right_hand","by_button")).ok and legacy.assign("subtitles", Bindings.bind("left_hand","by_button",Bindings.MODIFIERS), true).ok, "Plain B/Y stays reserved for closing menus while chords may use it")
	check(not restored.press("right_hand", "ax_button") or restored.down.right_hand.has("ax_button"), "Pressed state is bounded by input names")
	restored.reset_inputs()
	check(not restored.press("right_hand", "ax_button"), "Focus/reset waits for physical release")
	restored.release("right_hand", "ax_button")
	check(restored.press("right_hand", "ax_button"), "Released input can activate again")
	restored.restore({"version": 1, "bindings": {"play": [{"hand": "bad", "input": "ax_button"}]}})
	check(restored.overrides.is_empty() and restored.resolve("right_hand", "ax_button", "video_flat") == "play", "Malformed settings restore usable defaults")
	var exchange := Bindings.new()
	var exchange_before := exchange.snapshot()
	check(not exchange.assign("play", Bindings.bind("left_hand", "ax_button")).ok and exchange.snapshot() == exchange_before, "Same active video context cannot save a duplicate")
	check(exchange.swap_binding("play", Bindings.bind("left_hand", "ax_button"), false, false).ok and exchange.snapshot() == exchange_before, "Swap preview is read-only")
	check(exchange.swap_binding("play", Bindings.bind("left_hand", "ax_button")).ok, "Valid simple swap commits")
	check(exchange.resolve("left_hand", "ax_button", "video_flat") == "play" and exchange.resolve("right_hand", "ax_button", "video_flat") == "library_video", "Swap updates both runtime mappings")
	var exchanged := Bindings.new(); exchanged.restore(exchange.snapshot())
	check(exchanged.snapshot() == exchange.snapshot(), "Swapped map survives restart")
	exchange.restore_all()
	exchange.clear("reset_video"); exchange.clear("reset_photo")
	check(exchange.assign("play", Bindings.bind("right_hand", "primary_click")).ok and exchange.assign("photo_next", Bindings.bind("right_hand", "primary_click")).ok, "Non-overlapping video/photo scenes may reuse the same physical key")
	exchange_before = exchange.snapshot()
	check(not exchange.assign("volume_up", Bindings.bind("right_hand", "stick_up")).ok and exchange.snapshot() == exchange_before, "Generic video rejects both flat and immersive overlaps")
	check(not exchange.swap_binding("volume_up", Bindings.bind("right_hand", "stick_up")).ok and exchange.snapshot() == exchange_before, "Ambiguous multi-action swap changes neither side")
	check(not exchange.swap_binding("play", Bindings.bind("right_hand", "trigger_click")).ok and exchange.snapshot() == exchange_before, "The fixed video UI trigger cannot enter a shortcut swap")
	exchange.restore_all()
	exchange.assign("subtitles", Bindings.bind("right_hand", "by_button", Bindings.MODIFIERS), true)
	exchange.assign("mute", Bindings.bind("right_hand", "ax_button", Bindings.MODIFIERS), true)
	check(exchange.swap_binding("subtitles", Bindings.bind("right_hand", "ax_button", Bindings.MODIFIERS), true).ok, "Combinations exchange the complete same-hand chord")
	exchange.press("right_hand", "grip_click"); exchange.press("right_hand", "trigger_click")
	check(exchange.resolve("right_hand", "ax_button", "video_flat") == "subtitles" and exchange.resolve("right_hand", "by_button", "video_flat") == "mute", "Swapped combinations resolve independently")
	var movement := Move.new()
	var panel := Node3D.new(); root.add_child(panel)
	var pose := Transform3D(Basis.IDENTITY, Vector3(0, 1, -1))
	check(movement.begin("right_hand", "grip_click", pose, [{"node": panel, "kind": "menu", "pose": panel.global_transform, "key": "panel"}]), "Movement arms")
	check(not movement.update(pose.translated(Vector3(0.01, 0, 0)), null, preload("res://scripts/view_follow.gd").new()) and panel.position == Vector3.ZERO, "Small grip jitter never moves interface")
	var twisted := pose; twisted.basis = Basis(Vector3.UP, 0.1)
	check(not movement.update(twisted, null, preload("res://scripts/view_follow.gd").new()) and movement.pending(), "Wrist rotation alone does not commit flat-panel movement")
	movement.cancel()
	check(panel.position == Vector3.ZERO, "Chord cancels pending movement without visual jump")
	movement.begin("right_hand", "grip_click", pose, [{"node": panel, "kind": "menu", "pose": panel.global_transform, "key": "panel"}])
	check(movement.update(pose.translated(Vector3(0.15, 0.12, -0.08)), Transform3D.IDENTITY, preload("res://scripts/view_follow.gd").new()) and panel.position.is_equal_approx(Vector3(0.15, 0.12, -0.08)), "Committed grip translates interface in XYZ")
	check(movement.placement("panel", Transform3D.IDENTITY).origin.is_equal_approx(panel.position), "Moved menu retains session placement")
	movement.cancel(); panel.free()
	ray_anchored_movement()
	spherical_movement()
	var main := Main.new()
	main.settings_path = ProjectSettings.globalize_path("res://../../build/output/controller-controls/settings.cfg")
	DirAccess.make_dir_recursive_absolute(main.settings_path.get_base_dir())
	main._on_setting_changed("controller_bindings", data)
	var saved := ConfigFile.new(); saved.load(main.settings_path)
	check(saved.get_value("input", "controller_bindings") == data, "Main persists actual binding data")
	main.free()
	runtime()
	combination_media_actions()
	combination_media_actions(true)
	grip_chord_arbitration()
	await tracked_grip_drag()
	await video_triggers()
	await back_navigation()
	for failure in failures: push_error(failure)
	print("Controller bindings: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)

func ray_anchored_movement() -> void:
	var movement := Move.new()
	var panel := Node3D.new(); root.add_child(panel)
	panel.position = Vector3(0, 1.4, -2)
	var start := Transform3D(Basis.IDENTITY, Vector3(0, 1.4, -0.4))
	var anchor := panel.global_position + Vector3(0.3, 0.1, 0)
	var relative := start.affine_inverse() * anchor
	var target := {"node": panel, "kind": "menu", "pose": panel.global_transform, "key": "panel"}
	check(movement.begin("left_hand", "grip_click", start, [target], anchor), "Ray grab records the exact point on the panel")
	var pose := start; pose.basis = Basis(Vector3.UP, 0.01)
	check(not movement.update(pose, null, preload("res://scripts/view_follow.gd").new()) and movement.pending(), "Small wrist jitter leaves grip-first chords available")
	pose.basis = Basis(Vector3.UP, 0.7) * Basis(Vector3.RIGHT, -0.2)
	var expected: Vector3 = pose * relative - anchor
	check(movement.update(pose, null, preload("res://scripts/view_follow.gd").new()) and panel.position.is_equal_approx(target.pose.origin + expected), "Wrist yaw/pitch moves the remote grab point without requiring hand translation")
	check(panel.basis == target.pose.basis and movement.capture.anchor.is_equal_approx(pose * relative), "Ray dragging preserves panel orientation and moves its captured point")
	for step in range(1, 16):
		pose.origin = start.origin + Vector3(step * 0.1, 0, 0)
		check(movement.update(pose, null, preload("res://scripts/view_follow.gd").new()), "Continuous grip dragging can exceed the old total 0.8 metre limit")
	check(not movement.capture.is_empty() and panel.position.is_equal_approx(target.pose.origin + pose * relative - anchor), "Long drag remains captured at its exact final position")
	pose.origin += Vector3(2, 0, 0)
	check(not movement.update(pose, null, preload("res://scripts/view_follow.gd").new()) and movement.capture.is_empty(), "An actual one-frame tracking teleport still cancels safely")
	panel.free()

func spherical_movement() -> void:
	var movement := Move.new()
	var follow := preload("res://scripts/view_follow.gd").new(); follow.set_enabled(true)
	var head := Transform3D(Basis.IDENTITY, Vector3(0, 1.6, 0))
	var panel := Node3D.new(); root.add_child(panel); panel.position = Vector3(0, 1.45, -2)
	panel.basis = Basis(Vector3.UP, 0.1).scaled(Vector3(1.1, 0.9, 1))
	var child := Node3D.new(); panel.add_child(child); child.position = Vector3(0, 0.72, 0)
	var child_local := child.transform
	var other := Node3D.new(); root.add_child(other); other.position = Vector3(0.9, 1.8, -2.4)
	var screen := preload("res://scripts/mpv_video_display.gd").new(); screen.history_enabled = false; root.add_child(screen); screen.set_process(false)
	screen.set_flat_world_pose(Transform3D(Basis.IDENTITY, Vector3(-0.4, 1.5, -3)))
	var gallery := preload("res://scripts/photo_gallery.gd").new(); root.add_child(gallery)
	gallery.anchor = head
	var card := Node3D.new(); gallery.add_child(card); card.global_position = Vector3(1, 1.6, -3)
	gallery.cards[1] = {"node": card, "pose": card.global_transform}
	var worlds: Array[Transform3D] = [panel.global_transform, other.global_transform, screen.global_transform * screen.flat_pose, child.global_transform, card.global_transform]
	var targets := [{"node": panel, "kind": "menu", "pose": worlds[0], "key": "panel"},
		{"node": other, "kind": "menu", "pose": worlds[1], "key": "other"},
		{"node": screen, "kind": "screen", "pose": worlds[2], "key": "screen"},
		{"node": gallery, "kind": "gallery", "pose": gallery.anchor, "key": "gallery"}]
	var anchor := panel.to_global(Vector3(0.4, 0.1, 0))
	var start := Transform3D(Basis.IDENTITY, anchor + Vector3(0, 0, 1))
	check(movement.begin("left_hand", "grip_click", start, targets, anchor, head), "Spherical grip captures a linked group, a screen and a photo layout")
	var local_grab := panel.to_local(anchor)
	var scale_before := panel.global_basis.get_scale()
	var head_start := head.origin
	var pose := start
	for step in 36:
		pose.origin = start.origin + Vector3(0.1 * sin(step * 0.2), 0.06 * cos(step * 0.3), 0.15 * sin(step * 0.4))
		pose.basis = Basis(Vector3.UP, -0.7 + step * 0.04) * Basis(Vector3.RIGHT, 0.2 * sin(step * 0.1))
		head.origin = head_start + Vector3(0.05 * sin(step * 0.2), 0.03 * cos(step * 0.3), 0.02 * sin(step * 0.4))
		check(movement.update(pose, head, follow), "Spherical grip tracks hand translation, wrist rotation and head motion")
		var positions: Array[Vector3] = [panel.global_position, other.global_position, (screen.global_transform * screen.flat_pose).origin, child.global_position, card.global_position]
		for index in positions.size():
			check(absf(positions[index].distance_to(head.origin) - worlds[index].origin.distance_to(head_start)) < 0.0001, "Each panel, screen and card retains its own original viewing distance")
		check(child.transform.is_equal_approx(child_local) and panel.global_basis.get_scale().is_equal_approx(scale_before), "Spherical dragging preserves attached layout and physical scale")
		check(panel.to_global(local_grab).distance_to(movement.capture.anchor) < 0.0001, "Live marker remains on the original grabbed point")
		check((movement.capture.anchor - pose.origin).normalized().dot((pose.basis * (start.affine_inverse() * anchor)).normalized()) > 0.99999, "Captured point stays collinear with the controller ray")
		check(movement.placement("panel", head).is_equal_approx(panel.global_transform) and follow.pose("screen", head).is_equal_approx(screen.global_transform * screen.flat_pose), "Session placement and follow remember the constrained poses")
	check(not movement.update(pose, null, follow) and movement.capture.is_empty(), "Losing the head pose cancels rather than returning to free-depth dragging")
	panel.global_transform = Transform3D(Basis.IDENTITY, Vector3(0, 1.6, -2)); head.origin = head_start
	pose = Transform3D(Basis.IDENTITY, Vector3(0, 1.6, -0.4))
	var fixed := panel.global_transform
	movement.begin("right_hand", "grip_click", pose, [{"node": panel, "kind": "menu", "pose": fixed, "key": "panel"}], panel.global_position, head)
	for offset in [-0.2, 0.2, -0.1, 0.1]:
		pose.origin.z = -0.4 + offset
		check(movement.update(pose, head, follow) and panel.global_transform.is_equal_approx(fixed), "Pushing or pulling along the ray cannot change panel depth")
	check(Move._sphere_point(Vector3(3, 0, 0), Vector3.RIGHT, Vector3.ZERO, 2, Vector3(2, 0, 0)).is_equal_approx(Vector3(2, 0, 0)), "A hand outside a missed sphere clamps without a depth jump")
	check(Move._sphere_point(Vector3(2, 0, 3), Vector3.FORWARD, Vector3.ZERO, 2, Vector3(2, 0, 0)).is_equal_approx(Vector3(2, 0, 0)), "Tangent rays remain finite on the viewing sphere")
	check(Move._sphere_point(Vector3(0, 0, 3), Vector3.FORWARD, Vector3.ZERO, 2, Vector3(0, 0, 2)).is_equal_approx(Vector3(0, 0, 2)), "Outside intersections retain the near surface instead of flipping across the head")
	movement.cancel(); gallery.cards.clear(); gallery.free(); screen.free(); other.free(); panel.free()

func tracked_grip_drag() -> void:
	# Exercise the real XRController3D pose, button signals and per-frame pointer dispatch.
	var main := Main.new()
	main.settings_path = "user://grip-ray-regression.cfg"
	var video := preload("res://scripts/mpv_video_display.gd").new(); root.add_child(video); video.set_process(false)
	main.video = video
	var photo := preload("res://scripts/photo_display.gd").new(); root.add_child(photo); photo.set_process(false); photo.auto_depth = false
	main.photo = photo
	var player := preload("res://scripts/player_menu.gd").new(); root.add_child(player); player.set_process(false)
	player.state_provider = func(): return {"has_video": true, "playing": false}
	main.video_menu = player; main.player_menu = player
	var photo_menu := preload("res://scripts/photo_menu.gd").new(); root.add_child(photo_menu); photo_menu.set_process(false)
	photo_menu.state_provider = photo.snapshot; main.photo_menu = photo_menu
	var library := preload("res://scripts/library_menu.gd").new(); root.add_child(library); library.set_process(false); main.recent_menu = library
	player.expanded_library = library
	var origin := XROrigin3D.new(); root.add_child(origin)
	var camera := XRCamera3D.new(); origin.add_child(camera); camera.position = Vector3(0, 1.6, 0); main.xr_camera = camera
	for hand in Bindings.HANDS:
		var tracker := XRControllerTracker.new(); tracker.type = XRServer.TRACKER_CONTROLLER; tracker.name = hand
		XRServer.add_tracker(tracker)
		var controller := XRController3D.new(); controller.tracker = hand; controller.pose = "aim"; origin.add_child(controller)
		controller.button_pressed.connect(main._on_controller_button.bind(hand))
		controller.button_released.connect(main._on_controller_release.bind(hand))
		if hand == "left_hand": main.left_controller = controller
		else: main.right_controller = controller
		for kind in ["video", "photo", "library", "compact"]:
			player.dismiss(); photo_menu.dismiss(); library.dismiss()
			if library.get_parent() != root: library.reparent(root)
			library.set_compact(kind == "compact")
			main.photo_active = kind == "photo"; main.player_menu = photo_menu if main.photo_active else player
			var menu: Node3D = library if kind == "library" else main.player_menu
			menu.toggle(); menu.global_transform = Transform3D(Basis.IDENTITY, Vector3(0, 1.4, -1.8))
			var hit_menu := menu
			if kind == "compact":
				library.reparent(player); library.transform = Transform3D(Basis.IDENTITY, Vector3(0, 0.72, 0)); library.visible = true; library.refresh()
				hit_menu = library
			var half: Vector2 = hit_menu._backdrop.mesh.size / 2
			var anchor: Vector3 = hit_menu._backdrop.to_global(Vector3(half.x - 0.01, 0, 0))
			var start := Transform3D(Basis.IDENTITY, anchor + Vector3(0, 0, 1.2))
			tracker.set_pose("aim", start, Vector3.ZERO, Vector3.ZERO, XRPose.XR_TRACKING_CONFIDENCE_HIGH)
			await process_frame
			anchor = menu.to_global(menu.grab_hit(start.origin, -start.basis.z).point)
			check(main._move_pose(hand) != null, "Real controller pose is tracked: " + hand + "/" + kind)
			tracker.set_input("grip_click", true)
			check(main.interface_move.pending() and main.interface_move.capture.targets[0].node == menu, "Real grip captures the aimed menu group: " + kind)
			var menu_start: Transform3D = menu.global_transform
			var head: Vector3 = main._head_pose().origin
			var radius := menu_start.origin.distance_to(head)
			var grab_local := menu.to_local(anchor)
			var pose := start; pose.basis = Basis(Vector3.UP, 0.6) * Basis(Vector3.RIGHT, 0.15)
			tracker.set_pose("aim", pose, Vector3.ZERO, Vector3.ZERO, XRPose.XR_TRACKING_CONFIDENCE_HIGH)
			await process_frame
			main._update_interface_move(); main._process_sticks(Vector2.ZERO, Vector2.ZERO, 0.014)
			var expected: Vector3 = menu.to_global(grab_local)
			check(absf(menu.global_position.distance_to(head) - radius) < 0.0001 and menu.global_position.distance_to(menu_start.origin) > 0.1, "Tracked wrist turning moves the panel on its head sphere: " + kind)
			check((expected - pose.origin).normalized().dot(-pose.basis.z) > 0.99999, "Spherical grab stays on the real controller ray: " + kind)
			check(menu._pointers.has(hand) and menu._pointers[hand].line.visible and menu._pointers[hand].dot.visible and menu._pointers[hand].dot.global_position.distance_to(expected) < 0.009,
				"Moving grip ray ends on the panel instead of at a stale far point: " + kind)
			var point_before: Vector3 = menu._pointers[hand].dot.global_position
			pose.basis = Basis(Vector3.UP, -0.3) * Basis(Vector3.RIGHT, -0.12)
			tracker.set_pose("aim", pose, Vector3.ZERO, Vector3.ZERO, XRPose.XR_TRACKING_CONFIDENCE_HIGH)
			await process_frame
			main._update_interface_move(); main._process_sticks(Vector2.ZERO, Vector2.ZERO, 0.014)
			check(menu._pointers[hand].dot.global_position.distance_to(point_before) > 0.5 and menu._hover.get(hand) == menu.NONE, "Grip pointer refreshes each frame without hovering or selecting controls")
			for step in 25:
				var turn := Basis(Vector3.UP, step * TAU / 24.0)
				pose = Transform3D(turn * start.basis, head + turn * (start.origin - head))
				tracker.set_pose("aim", pose, Vector3.ZERO, Vector3.ZERO, XRPose.XR_TRACKING_CONFIDENCE_HIGH)
				await process_frame
				main._update_interface_move(); main._process_sticks(Vector2.ZERO, Vector2.ZERO, 0.014)
				check(menu.global_basis.y.normalized().dot(menu_start.basis.y.normalized()) > 0.99999, "Tracked grip keeps the real menu upright all the way around the head: " + hand + "/" + kind)
				check(menu.to_global(grab_local).distance_to(menu._pointers[hand].dot.global_position) < 0.009 and absf(menu.global_position.distance_to(head) - radius) < 0.0001,
					"Tracked front/side/rear grips retain the exact point, depth and linked layout: " + kind)
			var menu_end: Transform3D = menu.global_transform
			tracker.set_input("grip_click", false)
			pose.origin += Vector3(0.1, 0, 0); tracker.set_pose("aim", pose, Vector3.ZERO, Vector3.ZERO, XRPose.XR_TRACKING_CONFIDENCE_HIGH)
			await process_frame
			main._update_interface_move()
			check(main.interface_move.capture.is_empty() and menu.global_transform == menu_end, "Release leaves the panel at its dragged position")
			if kind == "compact": check(library.global_position.is_equal_approx(player.to_global(Vector3(0, 0.72, 0))), "Ray dragging preserves the attached file panel's local transform")
			if kind == "video":
				var aim: Vector3 = menu._backdrop.global_position
				pose = Transform3D(Basis.IDENTITY, aim + Vector3(0, 0, 1.2))
				tracker.set_pose("aim", pose, Vector3.ZERO, Vector3.ZERO, XRPose.XR_TRACKING_CONFIDENCE_HIGH)
				await process_frame
				tracker.set_input("grip_click", true)
				pose.origin.x += 0.05; tracker.set_pose("aim", pose, Vector3.ZERO, Vector3.ZERO, XRPose.XR_TRACKING_CONFIDENCE_HIGH)
				await process_frame
				main._update_interface_move(); main._process_sticks(Vector2.ZERO, Vector2.ZERO, 0.014)
				tracker.invalidate_pose("aim")
				await process_frame
				main._update_interface_move(); main._process_sticks(Vector2.ZERO, Vector2.ZERO, 0.014)
				check(main.interface_move.capture.is_empty() and not menu._pointers[hand].line.visible and not menu._pointers[hand].dot.visible, "Actual tracking loss cancels the grab and removes its stale ray")
				tracker.set_input("grip_click", false)
		XRServer.remove_tracker(tracker); controller.free()
	if library.get_parent() != root: library.reparent(root)
	origin.free(); library.free(); photo_menu.free(); player.free(); photo.free(); video.free(); main.free()

func tap(main: Node3D, input: String, hand: String = "right_hand") -> void:
	main._on_controller_button(input, hand); main._on_controller_release(input, hand)

func media_chord(main: Node3D, hand: String, input: String = "by_button") -> void:
	var trigger_first: bool = main.get_meta("trigger_first", false)
	main._on_controller_button("trigger_click" if trigger_first else "grip_click", hand)
	# Production updates run between presses, including natural hand/head movement.
	main.pose.origin.x += 0.04; main._update_interface_move(); main._update_grab()
	main._on_controller_button("grip_click" if trigger_first else "trigger_click", hand)
	main.pose.origin.y += 0.03; main._update_interface_move()
	# Duplicate press events must not flip twice or skip two files.
	main._on_controller_button(input, hand); main._on_controller_button(input, hand)
	main._on_controller_release(input, hand)
	main._on_controller_release("trigger_click", hand)
	main._on_controller_release("grip_click", hand)

func grip_chord_arbitration() -> void:
	var directory := ProjectSettings.globalize_path("res://../../build/output/controller-controls/grip-chords")
	DirAccess.make_dir_recursive_absolute(directory)
	var video := preload("res://scripts/mpv_video_display.gd").new(); video.history_enabled = false
	root.add_child(video); video.set_process(false)
	video.platform = preload("res://tests/test_player_menu.gd").Host.new()
	video.local_uri = "file:///grip.mp4"; video.media.begin(7); video.media.state = "playing"
	var photo := preload("res://scripts/photo_display.gd").new(); photo.auto_depth = false
	root.add_child(photo); photo.set_process(false); photo.local_uri = "file:///grip.jpg"
	var main := InputMain.new(); main.video = video; main.photo = photo; main.settings_path = directory.path_join("settings.cfg")
	var menu := preload("res://scripts/player_menu.gd").new(); menu.state_provider = main._menu_state
	root.add_child(menu); menu.set_process(false); menu.dismiss(); main.player_menu = menu; main.video_menu = menu
	var library := preload("res://scripts/library_menu.gd").new()
	root.add_child(library); library.set_process(false); library.dismiss(); main.recent_menu = library
	for hand in Bindings.HANDS:
		for is_photo in [false, true]:
			main.photo_active = is_photo
			var surface: Node3D = photo if is_photo else video
			surface.geometry = 0; surface.flat_pose = Transform3D(Basis.IDENTITY, Vector3(0, 1.6, -2))
			surface._apply_geometry(); surface.panel.visible = true
			var id := "follow_photo" if is_photo else "follow_video"
			for scope in ["panel", "media", "all"]:
				main.controller_bindings.restore_all(); main.controller_bindings.move_scope = scope
				main.controller_bindings.assign(id, Bindings.bind(hand, "by_button", Bindings.MODIFIERS), true)
				for ray in [null, [Vector3(0, 1.6, 0), Vector3(3, 0, -1).normalized()]]:
					main.rays[hand] = ray
					var before: Transform3D = surface.flat_pose
					main._on_controller_button("grip_click", hand)
					main.pose.origin.x += 0.05; main._update_interface_move()
					check(main.interface_move.capture.is_empty() and surface.flat_pose == before, "Blank/untracked grip never captures flat media or hidden interfaces: %s/%s/%s" % [hand, str(is_photo), scope])
					main._on_controller_button("trigger_click", hand)
					var following: bool = main.view_follow.enabled
					tap(main, "by_button", hand)
					check(main.view_follow.enabled != following, "Blank-space grip chord survives a tracked update before trigger")
					main._on_controller_release("trigger_click", hand); main._on_controller_release("grip_click", hand)
			# A real picture grab may already have moved before the second modifier arrives.
			main.controller_bindings.restore_all()
			for input in ["by_button", "stick_right"]:
				main.controller_bindings.assign(id, Bindings.bind(hand, input, Bindings.MODIFIERS), true)
			main.rays[hand] = [Vector3(0, 1.6, 0), (surface.panel.global_position - Vector3(0, 1.6, 0)).normalized()]
			for input in ["by_button", "stick_right"]:
				main.pose = Transform3D(Basis.IDENTITY, Vector3(0, 1.5, -0.5))
				main._on_controller_button("grip_click", hand)
				main.pose.origin.x += 0.05; main._update_interface_move()
				check(main.interface_move.capture.get("moved", false), "Aimed grip still moves flat video/photo before chord takeover")
				main._on_controller_button("trigger_click", hand)
				var frozen: Transform3D = surface.flat_pose
				main.pose.origin.y += 0.05; main.head_pose.origin.x += 0.04; main._update_interface_move()
				check(main.interface_move.capture.is_empty() and surface.flat_pose == frozen, "Same-hand trigger ends committed movement and freezes it throughout the chord")
				var following: bool = main.view_follow.enabled
				if input == "by_button": tap(main, input, hand)
				else:
					main._process_sticks(Vector2.ZERO, Vector2.ZERO, 0.1)
					for repeat in 3: main._process_sticks(Vector2(1, 0) if hand == "left_hand" else Vector2.ZERO, Vector2(1, 0) if hand == "right_hand" else Vector2.ZERO, 0.1)
				check(main.view_follow.enabled != following, "Button/stick chord executes once after committed movement: " + input)
				main._on_controller_release("trigger_click", hand)
				main.pose.origin.x += 0.05; main._update_interface_move()
				check(main.interface_move.capture.is_empty(), "Releasing trigger cannot resume movement with the original grip still held")
				main._on_controller_release("grip_click", hand)
				main._process_sticks(Vector2.ZERO, Vector2.ZERO, 0.1)
			# Reverse order must also take over a photo drag that already committed.
			main.rays[hand] = [Vector3(0, 1.6, 0), Vector3.FORWARD]
			main._on_controller_button("trigger_click", hand)
			main.rays[hand][1] = Basis(Vector3.UP, 0.15) * Vector3.FORWARD; main._update_grab()
			check(main._grab.get("moved", false) if is_photo else not main._video_control_tap.is_empty(), "Trigger-first begins the existing photo drag/video controls tap")
			main._on_controller_button("grip_click", hand)
			var frozen: Transform3D = surface.flat_pose
			main.rays[hand][1] = Basis(Vector3.UP, 0.3) * Vector3.FORWARD; main._update_grab(); main._update_interface_move()
			check(main._grab.is_empty() and main.interface_move.capture.is_empty() and surface.flat_pose == frozen and main._video_control_tap.is_empty(), "Grip takes over a committed trigger drag without a jump or deferred popup")
			var following: bool = main.view_follow.enabled
			tap(main, "by_button", hand)
			check(main.view_follow.enabled != following, "Trigger-first chord executes after real photo drag/video tap takeover")
			main._on_controller_release("grip_click", hand); main._on_controller_release("trigger_click", hand)
			check(not menu.visible, "Either modifier release order avoids a late controls popup")
			# With chords assigned, a plain blank trigger click still dismisses a library.
			main.rays[hand] = [Vector3(0, 1.6, 0), Vector3(3, 0, -1).normalized()]
			library.visible = true
			main._on_controller_button("trigger_click", hand)
			check(library.visible, "A chord-capable blank trigger waits for release")
			main._on_controller_release("trigger_click", hand)
			check(not library.visible, "A plain trigger release still dismisses video/photo library")
			if is_photo:
				photo.gallery.mode = 2; photo.gallery.visible = true
				main._on_controller_button("grip_click", hand)
				check(main.interface_move.capture.is_empty(), "Blank space between gallery cards cannot grab the whole layout")
				main._on_controller_release("grip_click", hand); photo.gallery.mode = 0
			else:
				video.geometry = 1; video._apply_geometry(); video.panel.visible = true
				main.rays[hand] = [video.panel.global_position, video.panel.global_basis.z]
				main._on_controller_button("grip_click", hand)
				check(main.interface_move.capture.is_empty(), "The empty rear of VR180 cannot capture the picture")
				main._on_controller_release("grip_click", hand); video.geometry = 0; video._apply_geometry()
		# A blank press over a visible transport must not fall back to the video either.
		main.photo_active = false; main._show_player_menu()
		main.rays[hand] = [Vector3(0, 1.6, 0), Vector3(3, 0, -1).normalized()]
		main._on_controller_button("grip_click", hand)
		check(main.interface_move.capture.is_empty(), "Visible controls do not turn an empty-space grip into a picture capture")
		main._on_controller_release("grip_click", hand); menu.dismiss()
	library.free(); menu.free(); photo.free(); video.free(); main.free()

func combination_media_actions(trigger_first: bool = false) -> void:
	var directory := ProjectSettings.globalize_path("res://../../build/output/controller-controls/media-actions")
	DirAccess.make_dir_recursive_absolute(directory)
	var video := preload("res://scripts/mpv_video_display.gd").new(); video.history_enabled = false
	video.mode_memory = preload("res://scripts/file_mode_memory.gd").new(directory.path_join("video-modes"))
	root.add_child(video); video.set_process(false)
	var host := preload("res://tests/test_player_menu.gd").Host.new(); video.platform = host
	var photo := preload("res://scripts/photo_display.gd").new(); photo.auto_depth = false
	root.add_child(photo); photo.set_process(false)
	var main := InputMain.new(); main.video = video; main.photo = photo
	main.set_meta("trigger_first", trigger_first)
	main.settings_path = directory.path_join("settings.cfg")
	var menu := preload("res://scripts/player_menu.gd").new(); menu.state_provider = main._menu_state
	root.add_child(menu); menu.set_process(false); main.player_menu = menu; main.video_menu = menu
	var photo_menu := preload("res://scripts/photo_menu.gd").new(); photo_menu.state_provider = photo.snapshot
	root.add_child(photo_menu); photo_menu.set_process(false); main.photo_menu = photo_menu
	var library := preload("res://scripts/library_menu.gd").new()
	root.add_child(library); library.set_process(false); main.recent_menu = library
	for hand in Bindings.HANDS:
		main.rays[hand] = [Vector3(0, 1.6, 0), Vector3(3, 0, -1).normalized()]
		main.controller_bindings.restore_all()
		for id in ["turn_180_video", "turn_180_photo"]:
			check(main.controller_bindings.assign(id, Bindings.bind(hand, "by_button", Bindings.MODIFIERS), true).ok, "Video and photo turn bindings can share one chord: " + hand)
		var restored := Bindings.new(); restored.restore(main.controller_bindings.snapshot())
		check(restored.snapshot() == main.controller_bindings.snapshot(), "New optional actions survive saving and restoring")
		for is_photo in [false, true]:
			main.photo_active = is_photo; main.player_menu = photo_menu if is_photo else menu
			var surface: Node3D = photo if is_photo else video
			surface.local_uri = "file:///turn.jpg" if is_photo else "file:///turn.mp4"
			video.media.begin(7); video.media.state = "playing"
			for projection in [0, 1, 2, 3]:
				menu.dismiss(); photo_menu.dismiss(); library.dismiss()
				surface.geometry = projection; surface._apply_geometry()
				surface.view_yaw = 0.3; surface.view_pitch = 0.2; surface.view_zoom = 0.1; surface._center_on_view()
				var basis_before: Basis = surface.panel.global_basis
				var id := "turn_180_photo" if is_photo else "turn_180_video"
				check(main._shortcut_allowed(id, true) == (projection == 3), "Turn is enabled only in 360 media: %s/%s/%d" % [hand, str(is_photo), projection])
				media_chord(main, hand)
				check(is_equal_approx(surface.view_yaw, wrapf(0.3 + (PI if projection == 3 else 0.0), -PI, PI)), "Turn chord rotates once only for 360 and cannot fall through to Back")
				check(is_equal_approx(surface.view_pitch, 0.2) and is_equal_approx(surface.view_zoom, 0.1) and not library.visible and not main.player_menu.visible, "Turning preserves pitch, zoom and hidden controls")
				if projection == 3:
					media_chord(main, hand)
					check(surface.panel.global_basis.is_equal_approx(basis_before), "Two 180-degree turns restore the video/photo orientation")
			library.toggle(); library.refresh()
			var yaw: float = surface.view_yaw
			media_chord(main, hand)
			check(surface.view_yaw == yaw and library.visible, "Library blocks 360 chords without invoking ordinary Back")
			library.dismiss()
		main.photo_active = false; main.player_menu = menu
		main.controller_bindings.restore_all()
		check(main.controller_bindings.assign("next_video", Bindings.bind(hand, "ax_button", Bindings.MODIFIERS), true).ok
			and main.controller_bindings.assign("previous_video", Bindings.bind(hand, "by_button", Bindings.MODIFIERS), true).ok, "Both video navigation chords can be assigned")
		restored.restore(main.controller_bindings.snapshot())
		check(restored.snapshot() == main.controller_bindings.snapshot(), "Video navigation combinations survive restart")
		var collision := main.controller_bindings.assign("turn_180_video", Bindings.bind(hand, "by_button", Bindings.MODIFIERS), true)
		check(not collision.ok and "previous_video" in collision.conflicts, "New combinations retain conflict detection")
		main.video_queue = [{"uri": "file:///first.mp4", "title": "First"}, {"uri": "smb://fixture/second.mp4", "title": "Second", "metadata": {"duration_ms": 120000}}, {"uri": "https://fixture/third.mp4", "title": "Third"}]
		video.open_library("file:///first.mp4", "First")
		var count_before: int = host.calls.size()
		media_chord(main, hand)
		check(video.local_uri == "file:///first.mp4" and host.calls.size() == count_before and not library.visible, "Previous at the first video does nothing without falling through to exit")
		media_chord(main, hand, "ax_button")
		check(video.local_uri == "smb://fixture/second.mp4" and video.requested_play and not menu.visible, "Next chord opens exactly the next queued video and keeps controls hidden")
		main._show_player_menu(); menu.refresh()
		media_chord(main, hand, "ax_button")
		check(video.local_uri == "https://fixture/third.mp4" and menu.visible and video.requested_play, "Next chord also works with ordinary video controls visible")
		count_before = host.calls.size(); media_chord(main, hand, "ax_button")
		check(video.local_uri == "https://fixture/third.mp4" and host.calls.size() == count_before, "Last video does not wrap or reopen")
		menu.section = 1; menu.refresh(); media_chord(main, hand)
		check(video.local_uri == "https://fixture/third.mp4" and menu.section == 1, "Video settings block navigation chords")
		var capture_hand := "left_hand" if hand == "right_hand" else "right_hand"
		menu._reset_navigation(); menu.refresh(); menu._seek_hand = capture_hand
		media_chord(main, hand)
		check(video.local_uri == "https://fixture/third.mp4" and menu._seek_hand == capture_hand, "Other-hand timeline capture owns input and blocks video navigation")
		menu._seek_hand = ""; menu.dismiss()
		media_chord(main, hand)
		check(video.local_uri == "smb://fixture/second.mp4" and not library.visible and video.requested_play, "Previous chord opens the previous queued video without closing playback: %s/%s/%s" % [video.local_uri, str(library.visible), str(video.requested_play)])
		main.video_queue.clear(); count_before = host.calls.size()
		media_chord(main, hand, "ax_button"); media_chord(main, hand)
		check(host.calls.size() == count_before, "Missing browse queue leaves both skip actions inactive")
		main.controller_bindings.restore_all()
		main.controller_bindings.assign("turn_180_video", Bindings.bind(hand, "stick_up", Bindings.MODIFIERS), true)
		video.geometry = 3; video._apply_geometry(); video.view_yaw = 0.3
		main._on_controller_button("trigger_click" if trigger_first else "grip_click", hand)
		main.pose.origin.x += 0.04; main._update_interface_move()
		main._on_controller_button("grip_click" if trigger_first else "trigger_click", hand)
		main.pose.origin.y += 0.03; main._update_interface_move()
		main._process_sticks(Vector2.ZERO, Vector2.ZERO, 0.1)
		for repeat in 3: main._process_sticks(Vector2(0, 0.99) if hand == "left_hand" else Vector2.ZERO, Vector2(0, 0.99) if hand == "right_hand" else Vector2.ZERO, 0.1)
		check(is_equal_approx(video.view_yaw, wrapf(0.3 + PI, -PI, PI)), "A held stick combination turns only once until recentered")
		main._process_sticks(Vector2.ZERO, Vector2.ZERO, 0.1)
		main._process_sticks(Vector2(0, 0.99) if hand == "left_hand" else Vector2.ZERO, Vector2(0, 0.99) if hand == "right_hand" else Vector2.ZERO, 0.1)
		check(is_equal_approx(video.view_yaw, 0.3), "Centering the stick permits another 180-degree turn")
		main._on_controller_release("trigger_click", hand); main._on_controller_release("grip_click", hand)
		video.close_video()
		check(not main._shortcut_allowed("turn_180_video", true) and not main._shortcut_allowed("next_video", true), "Retained URI after close cannot enable the new actions")
		main.video_queue = [{"uri": video.local_uri, "title": "Closed"}, {"uri": "file:///next.mp4", "title": "Next"}]
		count_before = host.calls.size(); var closed_yaw: float = video.view_yaw
		main._execute_shortcut("next_video"); main._execute_shortcut("turn_180_video")
		check(host.calls.size() == count_before and is_equal_approx(video.view_yaw, closed_yaw), "Mapped action dispatch also ignores a closed media session with a retained queue")
	video.free(); photo.free(); menu.free(); photo_menu.free(); library.free(); main.free()

## The production physical-controller route, including legacy settings and realistic ray drift.
func video_triggers() -> void:
	var Video := preload("res://scripts/mpv_video_display.gd")
	var Player := preload("res://scripts/player_menu.gd")
	var directory := ProjectSettings.globalize_path("res://../../build/output/video-trigger-host/" + str(Time.get_ticks_usec()))
	DirAccess.make_dir_recursive_absolute(directory)
	var video := Video.new(); video.history_enabled = false
	video.mode_memory = preload("res://scripts/file_mode_memory.gd").new(directory.path_join("modes"))
	root.add_child(video); video.set_process(false)
	video.platform = preload("res://tests/test_player_menu.gd").Host.new()
	var main := InputMain.new(); main.video = video; main.settings_path = directory.path_join("settings.cfg")
	var menu := Player.new(); menu.state_provider = main._menu_state
	menu.seek_requested.connect(main._on_menu_seek)
	root.add_child(menu); menu.set_process(false); main.player_menu = menu; main.video_menu = menu
	var library := preload("res://scripts/library_menu.gd").new()
	root.add_child(library); library.set_process(false); main.recent_menu = library; library.dismiss()
	for legacy in [{}, {"drag_video": []}, {"drag_video": [Bindings.bind("right_hand", "trigger_click")]}]:
		for projection in [0, 1, 2, 3]:
			for hand in Bindings.HANDS:
				main.controller_bindings.restore({"version": 1, "bindings": legacy})
				menu.dismiss(); video.media.begin(7); video.media.state = "playing"
				video.local_uri = "file:///trigger.mp4"; video.geometry = projection
				video.view_yaw = 0; video.view_pitch = 0; video.screen_scale = 1
				video.flat_pose = Transform3D(Basis(), Vector3(0, 1.6, -2)); video._apply_geometry(); video.panel.visible = true
				var before: Transform3D = video.flat_pose
				main.rays[hand] = [Vector3(0, 1.6, 0), Vector3.FORWARD]
				main._on_controller_button("trigger_click", hand)
				check(main._grab.is_empty() and not menu.visible, "Trigger waits for release without arming a picture grab")
				main.rays[hand] = [Vector3(0, 1.6, 0), Basis(Vector3.UP, 0.3) * Vector3.FORWARD]
				main._update_grab(); main._update_corner_hover()
				main._on_controller_release("trigger_click", hand)
				check(menu.visible and main._grab.is_empty() and video.flat_pose == before and video.view_yaw == 0 and video.view_pitch == 0,
					"Either trigger opens controls despite drift and old bindings: projection=%d hand=%s" % [projection, hand])
				main.rays[hand] = [Vector3(0, 1.6, 0), Vector3(3, 0, -1).normalized()]
				main._on_controller_button("trigger_click", hand)
				check(not menu.visible and main._grab.is_empty(), "Blank press dismisses controls without arming movement")
				main.rays[hand][1] = Vector3(-3, 0, -1).normalized(); main._update_grab()
				main._on_controller_release("trigger_click", hand)
				check(not menu.visible and video.flat_pose == before and video.screen_scale == 1 and video.view_yaw == 0 and video.view_pitch == 0,
					"Closing controls tolerates large ray drift without moving, resizing or reopening")
	# A real seek capture still belongs to the pressing hand and commits on release.
	for hand in Bindings.HANDS:
		video.control.close(); video.control.observe(40000, 120000); main._show_player_menu(); menu.refresh()
		var origin: Vector3 = menu.to_global(Vector3(-Player.BAR_SEEK / 4, -0.08, 1))
		main.rays[hand] = [origin, -menu.global_basis.z]
		main._on_controller_button("trigger_click", hand)
		check(menu._seek_hand == hand and main._grab.is_empty(), "Physical trigger captures the timeline without moving the picture")
		var other := "left_hand" if hand == "right_hand" else "right_hand"
		main.rays[other] = [Vector3(0, 1.6, 0), Vector3(3, 0, -1).normalized()]
		tap(main, "trigger_click", other)
		check(menu.visible and menu._seek_hand == hand, "Other-hand blank press cannot dismiss an owned timeline")
		main.rays[hand][0] = menu.to_global(Vector3(Player.BAR_SEEK / 4, -0.08, 1)); main._update_menu_pointer(hand)
		main._on_controller_release("trigger_click", hand)
		check(menu.visible and menu._seek_hand.is_empty() and video.control.target_ms > 40000, "Timeline trigger release still seeks and leaves controls open")
		menu.dismiss()
	# Grip routes both kinds of video through the existing movement owner and locks its targets.
	for projection in [0, 1, 2, 3]:
		for hand in Bindings.HANDS:
			video.geometry = projection; video.view_yaw = 0; video.view_pitch = 0
			video.flat_pose = Transform3D(Basis(), Vector3(0, 1.6, -2)); video._apply_geometry()
			var before: Transform3D = video.flat_pose
			main.pose = Transform3D(Basis(), Vector3(0, 1.5, -0.5))
			main.rays[hand] = [Vector3(0, 1.6, 0), Vector3.FORWARD]
			main._on_controller_button("grip_click", hand)
			check(main.interface_move.capture.targets[0].kind == ("screen" if projection == 0 else "immersive"), "Either grip owns the selected video projection")
			main.pose.basis = Basis(Vector3.UP, 0.2); main.pose.origin.x += 0.2; main._update_interface_move()
			check(video.flat_pose != before if projection == 0 else absf(video.view_yaw) > 0.1, "Grip moves 2D screens and turns immersive video")
			main._on_controller_release("grip_click", hand)
			check(main.interface_move.capture.is_empty() and not menu.visible, "Releasing a grip finishes movement without opening controls")
	main._show_player_menu(); main.rays.right_hand = [menu.to_global(Vector3(0, 0, 1)), -menu.global_basis.z]
	main.pose = Transform3D(Basis(), Vector3(0, 1.5, -0.5)); var before_yaw: float = video.view_yaw
	main._on_controller_button("grip_click", "right_hand")
	main.rays.right_hand = [Vector3.ZERO, Vector3(3, 0, -1).normalized()]
	main.pose.origin.x += 0.15; main._update_interface_move()
	check(main.interface_move.capture.targets[0].node == menu and video.view_yaw == before_yaw, "A grip on controls keeps its original target when the ray leaves")
	main._on_controller_release("grip_click", "right_hand"); menu.dismiss()
	main.rays.right_hand = [Vector3(0, 1.6, 0), Vector3.FORWARD]
	main._on_controller_button("trigger_click", "right_hand"); main._cancel_pointer("right_hand"); main._on_controller_release("trigger_click", "right_hand")
	check(not menu.visible, "Tracking cancellation cannot complete a deferred controls tap")
	main._on_controller_button("trigger_click", "right_hand"); video.local_uri = "file:///different.mp4"; main._on_controller_release("trigger_click", "right_hand")
	check(not menu.visible, "A deferred trigger tap cannot open controls for another file")
	main._on_controller_button("trigger_click", "right_hand")
	main.display.preview = false; main.display.session_state = "session_visible"; main._on_input_session_changed()
	main.display.preview = true; main._on_controller_release("trigger_click", "right_hand")
	check(not menu.visible and main._video_control_tap.is_empty(), "Losing XR focus cancels the tap even when focus returns before release")
	main._on_controller_button("trigger_click", "right_hand"); main._on_controller_button("grip_click", "right_hand")
	main.pose.basis = Basis(Vector3.UP, 0.4); main._update_interface_move()
	main._on_controller_release("trigger_click", "right_hand"); main._on_controller_release("grip_click", "right_hand")
	check(not menu.visible and main._video_control_tap.is_empty(), "Starting a grip consumes any earlier trigger tap without a delayed controls popup")
	video.geometry = 0; video._apply_geometry(); video.panel.visible = true
	var eye := Vector3(0, 1.6, 0)
	main.rays.right_hand = [eye, (video.panel.to_global(video.screen_corner(1)) - eye).normalized()]
	main._update_corner_hover()
	check(video._handles[1].visible, "Video controller rays advertise trigger corner resizing")
	library.free(); menu.free(); video.free(); main.free()

func choice_target(menu: Node3D, key: String, value: Variant = null, kind: String = "choose") -> int:
	if kind == "open":
		for button in menu._buttons:
			if button.get("choice_key", "") == key: return button.target
	for target in menu.choices.targets:
		var item: Dictionary = menu.choices.targets[target]
		if item.get("kind") == kind and item.get("key") == key and (kind == "open" or item.get("value") == value): return target
	return -1

func tap_ui(main: Node3D, menu: Node3D, target: int) -> bool:
	for button in menu._buttons:
		if button.target != target or not button.enabled or not button.node.visible: continue
		main.rays.right_hand = [button.node.to_global(Vector3(0, 0, 1)), -menu.global_basis.z]
		tap(main, "trigger_click")
		return true
	return false

func dropdown(main: Node3D, menu: Node3D, key: String, value: String) -> bool:
	if not tap_ui(main, menu, choice_target(menu, key, null, "open")): return false
	if menu.choices.opened != key: return false
	if menu.choices.popup.get("all_visible", false): return tap_ui(main, menu, choice_target(menu, key, value))
	for index in menu.choices.popup.choices.size():
		if menu.choices.popup.choices[index].value != value: continue
		menu.choices.offset = index
		menu._draw()
		return tap_ui(main, menu, choice_target(menu, key, value))
	return false

## Back uses the same production dispatch on either hand; no left controller is required.
func back_navigation() -> void:
	var Library := preload("res://scripts/library_menu.gd")
	var Player := preload("res://scripts/player_menu.gd")
	var video := preload("res://scripts/mpv_video_display.gd").new()
	video.history_enabled = false; root.add_child(video); video.set_process(false)
	var host := preload("res://tests/test_player_menu.gd").Host.new(); video.platform = host
	var main := InputMain.new(); main.video = video
	main.settings_path = ProjectSettings.globalize_path("res://../../build/output/controller-controls/back-settings.cfg")
	var library := Library.new(); root.add_child(library); library.set_process(false)
	var platform := preload("res://tests/test_library_menu.gd").FakePlatform.new(); library.attach_platform(platform)
	main.recent_menu = library
	var menu := Player.new(); menu.state_provider = main._menu_state
	menu.seek_requested.connect(main._on_menu_seek)
	root.add_child(menu); menu.set_process(false); main.player_menu = menu; main.video_menu = menu
	# Finish initial asynchronous volume discovery before arranging synthetic folder stacks.
	await process_frame
	for hand in Bindings.HANDS:
		video.close_video(); menu.dismiss(); library.dismiss(); main._show_full_library()
		main.controller_bindings.restore({"version": 1, "bindings": {"drag_video": []}})
		for source in [Library.Section.LOCAL, Library.Section.SMB, Library.Section.DLNA, Library.Section.CLOUD]:
			library.section = source
			library._local_stack = [{"id": "/disk", "title": "Disk"}, {"id": "/disk/child", "title": "Child"}]
			library._smb_server = "srv1"; library._smb_path = "share/child"
			library._dlna_server = "dlna1"; library._dlna_stack = [{"id": "root", "title": "Root"}, {"id": "child", "title": "Child"}]
			library._cloud_stack = [{"id": "/mount1", "title": "Mount"}, {"id": "/mount1/child", "title": "Child"}]
			library.refresh()
			var depth: int = library._crumbs().size()
			main._on_controller_button("by_button", hand)
			main._on_controller_button("by_button", hand)
			main._on_controller_release("by_button", hand)
			await process_frame
			check(library.visible and library._crumbs().size() == depth - 1, "Each B/Y press returns exactly one folder level: %s/%d" % [hand, source])
			for step in 4: tap(main, "by_button", hand); await process_frame
			check(library.visible and library._crumbs().is_empty(), "Repeated Back at the source root retains the last library: %s/%d" % [hand, source])
		# A stale child error must not overwrite the newly requested parent.
		library.section = Library.Section.SMB; library._smb_server = "srv1"; library._smb_path = "share/child"
		library._pending[90000] = "smb_browse"; library.refresh(); tap(main, "by_button", hand); await process_frame
		var parent_rows: Array = library.rows.duplicate(true); var parent_status: String = library.status
		library._on_media_list(90000, JSON.stringify({"state": "error", "error": "old child failed"}))
		check(library.rows == parent_rows and library.status == parent_status, "Late child responses cannot replace parent results or errors")
		# Server discovery only refreshes the server list; leaving a server keeps its result.
		library.section = Library.Section.DLNA; library._dlna_server = "dlna1"; library._dlna_stack = []; library._dlna_servers = []
		library._pending[90001] = "dlna_discover"; library.refresh(); tap(main, "by_button", hand); await process_frame
		check(library._dlna_server.is_empty() and library._pending.get(90001, "") == "dlna_discover", "Back keeps pending DLNA discovery")
		library._on_media_list(90001, JSON.stringify({"state": "ready", "servers": [{"id": "found1", "name": "Found"}]}))
		check(library._dlna_servers.any(func(server): return str(server.id) == "found1"), "Discovery finishing after Back fills the server list")
		# Layered settings and file operations return without confirming or cancelling committed I/O.
		library.section = Library.Section.SETTINGS; library.tab = Library.CONTROLS_TAB; library.refresh()
		library.controls_page.selection = library.controls_page.binding_field("play")
		library.choices.opened = "control_binding/play"; library.refresh()
		tap(main, "by_button", hand)
		check(library.visible and library.section == Library.Section.SETTINGS and library.choices.opened.is_empty(), "Back closes the dropdown and retains settings")
		var bindings_before: Dictionary = library.controls_page.bindings.snapshot()
		library.controls_page.commit("play", Bindings.bind("left_hand", "ax_button")); library.refresh()
		check(not library.controls_page.pending.is_empty(), "A real binding conflict is available for Back cancellation")
		tap(main, "by_button", hand)
		check(library.controls_page.pending.is_empty() and library.controls_page.bindings.snapshot() == bindings_before
			and library.visible and library.section == Library.Section.SETTINGS, "Back cancels a binding swap without accepting it or leaving settings")
		tap(main, "by_button", hand)
		check(library.visible and library.section == Library.Section.RECENT, "Back from settings retains the main library")
		library.section = Library.Section.LOCAL; library._local_stack = [{"id": "/disk", "title": "Disk"}]
		library.file_actions.modal = "delete"; library.file_actions.pending = 777
		library.file_actions.target = {"title": "movie.mp4", "uri": "file:///disk/movie.mp4"}; library.refresh()
		tap(main, "by_button", hand)
		check(library.file_actions.modal.is_empty() and library.file_actions.pending == 777 and library._local_stack.size() == 1 and library.visible,
			"Back hides a file-operation dialog without cancelling its committed job or navigating folders")
		library.file_actions.pending = 0; library.file_actions.reset()
		library.file_actions.editing = true; library.refresh(); tap(main, "by_button", hand)
		check(not library.file_actions.editing and library._local_stack.size() == 1, "Back leaves file-selection mode before navigating a folder")
		library.cloud_error.detail = "test"; library.cloud_error.opened = true; library.refresh(); tap(main, "by_button", hand)
		check(not library.cloud_error.opened and library.visible and library._local_stack.size() == 1, "Error details close without leaving the folder")
		library.account_panel.view = "choose"; library.refresh(); tap(main, "by_button", hand); await process_frame
		check(not library.account_panel.active() and library.visible, "Account forms return to their containing browser")
		library.section = Library.Section.CLOUD
		library._cloud_stack = [{"id": "/mount1", "title": "Mount"}]
		library.cloud_search.active = true; library.refresh(); tap(main, "by_button", hand); await process_frame
		check(not library.cloud_search.active and library.visible and library._cloud_stack.size() == 1, "Back exits search before moving up the cloud directory")
		library._cloud_stack = []; library.cloud_accounts.mode = "confirm"
		library.cloud_accounts.removing = {"id": "mount1", "title": "Mount"}; library.refresh()
		tap(main, "by_button", hand)
		check(library.cloud_accounts.mode == "remove" and library.visible, "Back cancels account-removal confirmation before its account list")
		tap(main, "by_button", hand); check(library.cloud_accounts.mode.is_empty() and library.visible, "Back then exits account removal without removing an account")
		# Media servers have their own navigation history and source-menu overlay.
		library.platform = null; library.section = Library.Section.MEDIA_SERVER
		var browser: RefCounted = library.server_browser; browser.view = "home"
		browser.history = [browser.context_state()]; browser.view = "scenes"; browser.sources_open = true; library.refresh()
		tap(main, "by_button", hand)
		check(not browser.sources_open and browser.view == "scenes", "Back closes the media-server source overlay before history")
		browser._remember(); browser.keyboard = "search"; browser.sources_open = true; library.refresh()
		tap(main, "by_button", hand)
		check(browser.keyboard.is_empty() and browser.sources_open and browser.view == "scenes", "Server keyboard Back does not skip its containing view or a hidden overlay")
		tap(main, "by_button", hand)
		tap(main, "by_button", hand); check(browser.view == "home", "Media-server Back restores its previous view")
		tap(main, "by_button", hand); check(browser.view == "servers", "Media-server home returns to the server list")
		tap(main, "by_button", hand); check(library.visible and browser.view == "servers", "Media-server root does not disappear")
		library.platform = platform; library.section = Library.Section.RECENT; library.refresh()
		# Right-only recovery works with no media, and also with a retained closed-file URI.
		for closed_uri in ["", "file:///closed.mp4"]:
			video.local_uri = closed_uri; library.dismiss(); menu.dismiss(); tap(main, "by_button", hand)
			check(library.visible, "B/Y alone can recover a hidden library without a video")
			library.dismiss(); main.rays[hand] = [Vector3(0, 1.6, 0), Vector3.FORWARD]; tap(main, "trigger_click", hand)
			check(library.visible, "Trigger alone can recover the library even with an old cancelled drag binding")
		# Attached compact/full libraries take precedence over their parent transport.
		video.local_uri = "file:///playing.mp4"; video.media.begin(7); video.media.state = "playing"; video.requested_play = true
		for expanded in [false, true]:
			video.local_uri = "file:///playing.mp4"; video.media.begin(7); video.media.state = "playing"; video.requested_play = true
			main._show_recent_menu()
			if library.compact == expanded: main._toggle_library_layout()
			library.section = Library.Section.LOCAL; library._local_stack = [{"id": "/disk", "title": "Disk"}]; library.refresh()
			tap(main, "by_button", hand); await process_frame
			check(library.visible and menu.visible and library._local_stack.is_empty(), "Attached browser returns to its source list before collapsing")
			tap(main, "by_button", hand)
			check(not library.visible and menu.visible and video.requested_play, "At either playback library root Back retains the transport and playback")
			tap(main, "by_button", hand)
			check(not menu.visible and library.visible and video.media.state == "closed" and not video.panel.visible, "Plain video transport Back closes playback and returns to the full library")
			await process_frame
			library.dismiss()
		# The same shortcut works without first opening controls, in flat and immersive playback.
		for geometry in [0, 1]:
			for playback in ["playing", "buffering", "opening", "paused"]:
				video.local_uri = "smb://fixture/Share/playing.mp4"; video.media.begin(7)
				video.media.state = "opening" if playback == "opening" else "playing"
				video.geometry = geometry; video.requested_play = playback != "paused"; video._waiting_first = playback == "opening"
				video.media.playback = {"details": {"paused_for_cache": "yes" if playback == "buffering" else "no"}}
				menu.dismiss(); library.dismiss()
				var before_close := host.calls.filter(func(call): return call[0] == "close").size()
				main._on_controller_button("by_button", hand); main._on_controller_button("by_button", hand)
				main._on_controller_release("by_button", hand)
				check(library.visible and not library.compact and not menu.visible and not video.panel.visible, "Hidden video Back returns directly to the full library: %s/%d/%s" % [hand, geometry, playback])
				check(video.media.state == "closed" and video.media.session_id == 0 and video.control.in_flight == 0, "Back closes the old session and pending playback work")
				check(host.calls.filter(func(call): return call[0] == "close").size() == before_close + 1, "Holding Back closes the native session exactly once")
				await process_frame
				library.dismiss()
		video.local_uri = "file:///playing.mp4"; video.media.begin(7); video.media.state = "playing"; video.requested_play = true; video._waiting_first = false
		main._show_player_menu(); menu.section = 1; menu._adjustment = "color_grade"; menu.refresh()
		tap(main, "by_button", hand); check(menu.visible and menu.section == 1 and menu._adjustment.is_empty(), "Back leaves color adjustments for playback settings")
		tap(main, "by_button", hand); check(menu.visible and menu.section == 0, "Back leaves settings for the transport")
		# Captured timeline cancellation cannot seek, pause, or click the newly exposed UI.
		video.control.close(); video.control.observe(40000, 120000); menu.refresh()
		main.rays[hand] = [menu.to_global(Vector3(-Player.BAR_SEEK / 4, -0.08, 1)), -menu.global_basis.z]
		main._on_controller_button("trigger_click", hand); var before: int = host.calls.size()
		tap(main, "by_button", hand); main._on_controller_release("trigger_click", hand)
		check(menu.visible and menu._seek_hand.is_empty() and host.calls.size() == before and video.requested_play, "Back cancels timeline capture without submitting playback commands")
		main._process_sticks(Vector2.ZERO, Vector2(0.99, 0), 0.1)
		check(host.calls.size() == before, "A stick held across Back cannot leak a playback action")
		main._process_sticks(Vector2.ZERO, Vector2.ZERO, 0.1); main._process_sticks(Vector2.ZERO, Vector2(0.99, 0), 0.1)
		check(host.calls.size() == before and main.seek_feedback.phase == "preview", "Ordinary playback stick seeking previews after recentering")
		main._process_sticks(Vector2.ZERO, Vector2.ZERO, 0.1)
		check(host.calls.size() > before, "Releasing the recentered playback stick commits its preview")
		# Grip-first B/Y chords retain priority, including no ordinary Back fallback when blocked.
		video.control.reject(); menu._reset_navigation(); menu.refresh(); main.controller_bindings.restore_all()
		main.controller_bindings.assign("subtitles", Bindings.bind(hand, "by_button", Bindings.MODIFIERS), true)
		main.rays[hand] = [Vector3(0, 1.6, 0), Vector3(3, 0, -1).normalized()]
		main._on_controller_button("grip_click", hand); main._on_controller_button("trigger_click", hand); main._on_controller_button("by_button", hand)
		check(menu.visible and menu._subtitle_open, "Configured B/Y chord opens subtitles without ordinary Back")
		main._on_controller_release("by_button", hand); main._on_controller_release("trigger_click", hand); main._on_controller_release("grip_click", hand)
		main._show_recent_menu(); library.section = Library.Section.LOCAL; library._local_stack = [{"id": "/disk", "title": "Disk"}]; library.refresh()
		main._on_controller_button("grip_click", hand); main._on_controller_button("trigger_click", hand); main._on_controller_button("by_button", hand)
		check(library.visible and library._local_stack.size() == 1, "A chord unavailable in a browser cannot become a directory Back")
		main._on_controller_release("by_button", hand); main._on_controller_release("trigger_click", hand); main._on_controller_release("grip_click", hand)
		main.pose_available = false
		main._on_controller_button("grip_click", hand); tap(main, "by_button", hand)
		check(library.visible and library._local_stack.size() == 1, "A partial configured chord cannot become Back when no grip pose is available")
		main._on_controller_release("grip_click", hand); main.pose_available = true
		main.controller_bindings.restore_all()
	# Photo child panels also return one layer, retaining their existing image interaction.
	library.dismiss(); menu.dismiss()
	var photo := preload("res://scripts/photo_display.gd").new(); root.add_child(photo); photo.set_process(false)
	photo.local_uri = "file:///photo.jpg"; main.photo = photo; main.photo_active = true
	var photo_menu := preload("res://scripts/photo_menu.gd").new(); photo_menu.state_provider = photo.snapshot
	root.add_child(photo_menu); photo_menu.set_process(false); main.photo_menu = photo_menu; main.player_menu = photo_menu
	photo_menu.visible = true; photo_menu._layout_open = true; photo_menu._wall_rows_open = true; photo_menu.refresh()
	tap(main, "by_button")
	check(photo_menu.visible and photo_menu._layout_open and not photo_menu._wall_rows_open, "Photo Back closes row selection before the layout picker")
	tap(main, "by_button"); check(photo_menu.visible and not photo_menu._layout_open, "Photo layout Back returns to its transport")
	photo_menu._adjustment = "photo_view"; photo_menu.refresh(); tap(main, "by_button")
	check(photo_menu.visible and photo_menu._adjustment.is_empty(), "Photo appearance Back retains the image and transport")
	tap(main, "by_button"); check(not photo_menu.visible and photo.local_uri == "file:///photo.jpg", "Plain photo transport Back hides controls without closing the image")
	photo_menu.free(); photo.free(); main.player_menu = menu; main.photo_active = false
	await process_frame # Drain fake-platform replies before releasing their signal owner.
	if library.get_parent() != root: library.reparent(root)
	library.free(); menu.free(); video.free(); main.free(); platform.free()

func runtime() -> void:
	var video := preload("res://scripts/mpv_video_display.gd").new()
	video.history_enabled = false; root.add_child(video); video.set_process(false)
	var host := preload("res://tests/test_player_menu.gd").Host.new()
	video.platform = host; video.local_uri = "file:///bindings.mp4"; video.media.begin(7)
	video._waiting_first = false; video.media.state = "playing"; video.requested_play = true
	var main := InputMain.new(); main.video = video
	main.settings_path = ProjectSettings.globalize_path("res://../../build/output/controller-controls/runtime-settings.cfg")
	var menu := preload("res://scripts/player_menu.gd").new()
	menu.state_provider = main._menu_state; root.add_child(menu); menu.set_process(false)
	main.player_menu = menu; main.video_menu = menu
	var library := preload("res://scripts/library_menu.gd").new()
	library.controls_page.bindings = main.controller_bindings
	library.setting_changed.connect(main._on_setting_changed)
	root.add_child(library); library.set_process(false); main.recent_menu = library
	tap(main, "ax_button")
	check(not video.requested_play and host.calls.back() == ["play", 7, false], "Production default A pauses native backend")
	check(not main.controller_bindings.assign("play", Bindings.bind("right_hand", "grip_click")).ok, "Playback cannot take a fixed grip")
	main.controller_bindings.clear("reset_video")
	check(main.controller_bindings.assign("play", Bindings.bind("right_hand", "primary_click")).ok, "Playback can move to an available button")
	var before: int = host.calls.size()
	tap(main, "ax_button")
	check(host.calls.size() == before, "Old A does not fire after remapping")
	tap(main, "primary_click")
	check(video.requested_play and host.calls.back() == ["play", 7, true], "Remapped button resumes native backend")
	main.controller_bindings.restore_all()
	video.panel.visible = true
	main.rays.right_hand = [Vector3(0, 1.6, 0), (video.panel.global_position - Vector3(0, 1.6, 0)).normalized()]
	main._on_controller_button("grip_click", "right_hand")
	before = host.calls.size()
	main._process_sticks(Vector2.ZERO, Vector2.ZERO, 0.1)
	main._process_sticks(Vector2(0, 0.99), Vector2(0.99, 0), 0.1)
	check(main.interface_move.pending() and host.calls.size() == before, "Default grip movement also blocks playback sticks before displacement")
	main._on_controller_release("grip_click", "right_hand")
	main._process_sticks(Vector2(0, 0.99), Vector2(0.99, 0), 0.1)
	check(host.calls.size() == before, "Releasing default grip still requires stick recentering")
	main.controller_bindings.assign("subtitles", Bindings.bind("right_hand", "by_button", ["grip_click", "trigger_click"]), true, true)
	main._show_player_menu()
	main.rays.right_hand = [menu.to_global(Vector3(0, 0, 1)), -menu.global_basis.z]
	var start: Transform3D = menu.global_transform
	main._on_controller_button("grip_click", "right_hand")
	check(main.interface_move.pending(), "Grip first arms movement while controls are open")
	main._on_controller_button("trigger_click", "right_hand")
	check(not menu.has_pointer_capture() and menu.global_transform == start, "Second modifier does not click or move UI")
	main._on_controller_button("by_button", "right_hand")
	check(menu._subtitle_open and main.interface_move.capture.is_empty(), "Grip+trigger+B opens subtitle panel and cancels pending move")
	main._on_controller_release("by_button", "right_hand")
	main._on_controller_release("trigger_click", "right_hand")
	main._on_controller_release("grip_click", "right_hand")
	check(menu._subtitle_open and video.requested_play, "Chord release neither closes subtitle panel nor pauses")
	menu.dismiss()
	main._show_player_menu()
	main._on_controller_button("grip_click", "right_hand")
	main.pose.origin += Vector3(0.1, 0.06, 0)
	main._update_interface_move()
	check(main.interface_move.capture.moved and menu.global_position.distance_to(start.origin) > 0.05 and absf(menu.global_position.distance_to(main.head_pose.origin) - start.origin.distance_to(main.head_pose.origin)) < 0.0001, "Main moves the aimed interface while preserving head distance")
	before = host.calls.size(); tap(main, "ax_button")
	check(host.calls.size() == before, "Committed movement owns A until release")
	main._on_pointer_button("trigger_click", "left_hand")
	check(main._grab.is_empty() and menu.visible, "Other hand's pointer/pinch cannot steal committed movement")
	main._on_controller_release("grip_click", "right_hand")
	var moved: Transform3D = menu.global_transform
	menu.dismiss(); main._show_player_menu()
	check(menu.global_transform.is_equal_approx(moved), "Reopening a moved menu preserves its session placement")
	main._recenter()
	check(not menu.global_transform.is_equal_approx(moved) and not main.interface_move.placements.has(main._menu_key(menu)), "Recenter restores defaults and clears the saved menu placement")
	start = menu.global_transform
	main.rays.left_hand = [menu.to_global(Vector3(0, 0, 1)), -menu.global_basis.z]
	main._on_controller_button("grip_click", "left_hand")
	check(main.interface_move.pending() and main.interface_move.capture.hand == "left_hand", "Left grip arms the same default menu movement")
	main.pose.origin += Vector3(-0.06, 0.02, 0.03); main._update_interface_move()
	check(menu.global_position.distance_to(start.origin) > 0.02 and absf(menu.global_position.distance_to(main.head_pose.origin) - start.origin.distance_to(main.head_pose.origin)) < 0.0001, "Left grip moves the aimed menu on the same head sphere")
	main._on_controller_release("grip_click", "left_hand")
	main.controller_bindings.move_scope = "all"
	main._on_controller_button("grip_click", "right_hand")
	check(main.interface_move.capture.targets.any(func(target): return target.node == library) and main.interface_move.capture.targets.any(func(target): return target.node == video), "All interfaces includes hidden library placement and the media surface")
	main.pose.origin += Vector3(-0.05, 0.03, 0.02); main._update_interface_move()
	main._on_controller_release("grip_click", "right_hand")
	var screen: Transform3D = video.global_transform * video.flat_pose
	main._place_screen()
	check((video.global_transform * video.flat_pose).is_equal_approx(screen), "Media replacement retains the moved screen placement")
	menu.dismiss(); library.section = library.Section.SETTINGS; library.tab = library.CONTROLS_TAB; library.visible = true; library.refresh()
	library.controls_page.mode = 0; library.refresh()
	check(not library.text_snapshot().contains("Press to record") and not library.controls_page.action(7052), "Removed recording entry cannot arm input interception")
	check(library.choices.targets.is_empty() and library.choices.popup.is_empty() and library.controls_page.selection.is_empty(), "Resting controller list allocates no choice controls or option data")
	check(library._buttons.filter(func(button): return library._row_target(button.target)).all(func(button): return not button.node is MeshInstance3D and button.node.get_children().all(func(child): return child is Label3D and not child.text.is_empty())), "Controller rows contain only the three text columns without meshes or blank labels")
	check(library._buttons.filter(func(button): return button.has("choice_key")).all(func(button): return button.hover_labels.size() == 1 and button.hover_labels[0].text.ends_with(library.CHOICE_MARK)), "Every editable value includes a chevron in its existing label")
	check(library._buttons.filter(func(button): return library._row_target(button.target) and not button.has("choice_key")).all(func(button): return button.node.get_children().all(func(child): return not child.text.contains(library.CHOICE_MARK))), "Fixed menu bindings have no choice chevron")
	var play_row := choice_target(library, "control_binding/play", null, "open")
	main.rays.right_hand = [library._buttons.filter(func(button): return button.target == play_row)[0].node.to_global(Vector3(0, 0, 1)), -library.global_basis.z]
	library.update_pointer("right_hand", main.rays.right_hand[0], main.rays.right_hand[1], true)
	check(library._buttons.filter(func(button): return button.target == play_row)[0].hover_labels[0].modulate == library.ACCENT and library.choices.targets.is_empty(), "Hover highlights the editable value without creating a popup or background")
	main._on_controller_button("trigger_click", "right_hand")
	check(library.choices.opened.is_empty() and not library._drag.is_empty(), "Text row waits for trigger release so a drag can scroll")
	main._on_controller_release("trigger_click", "left_hand")
	check(library.choices.opened.is_empty(), "Other hand cannot open a pressed text row")
	main._on_controller_release("trigger_click", "right_hand")
	check(library.choices.opened == "control_binding/play" and library.choices.targets.values().all(func(item): return item.get("kind") != "open"), "Release creates only the selected action's choices")
	check(library.choices.targets.values().filter(func(item): return item.get("kind") == "choose").size() == library.choices.popup.choices.size()
		and library.choices.targets.values().all(func(item): return item.get("kind") != "scroll"), "Every physical button and both utility options are visible together")
	var frozen_scroll: float = library.scroll
	library.stick_scroll(-0.99, 0.3)
	check(library.scroll == frozen_scroll and library._buttons.filter(func(button): return library._row_target(button.target)).all(func(button): return not button.enabled), "Dialog scroll cannot move or activate the underlying function list")
	check(tap_ui(main, library, library.ControlsPage.CANCEL) and library.choices.targets.is_empty() and library.controls_page.selection.is_empty(), "Dialog close releases its option controls and data")
	before = host.calls.size()
	main.controller_bindings.clear("projection_video")
	check(dropdown(main, library, "control_binding/play", "left_hand/primary_click"), "Ray dropdown selects a free physical button")
	check(main.controller_bindings.resolve("left_hand", "primary_click", "video_flat") == "play" and host.calls.size() == before, "Dropdown saves a free binding without executing playback")
	var persisted := ConfigFile.new(); persisted.load(main.settings_path)
	check(persisted.get_value("input", "controller_bindings") == main.controller_bindings.snapshot(), "Dropdown binding is persisted")
	check(tap_ui(main, library, choice_target(library, "control_binding/play", null, "open")), "Binding options reopen")
	check(choice_target(library, "control_binding/play", "left_hand/ax_button") != -1 and choice_target(library, "control_binding/play", "right_hand/by_button") == -1 and choice_target(library, "control_binding/play", "left_hand/by_button") == -1, "Remappable occupied X remains selectable while fixed B/Y are absent")
	check(choice_target(library, "control_binding/play", "left_hand/grip_click") == -1 and choice_target(library, "control_binding/play", "right_hand/grip_click") == -1, "Both reserved grips are absent from the dropdown")
	check(main.controller_bindings.resolve("left_hand", "primary_click", "video_flat") == "play", "Filtering keeps the current mapping")
	check(tap_ui(main, library, library.ControlsPage.CANCEL), "Ray cancellation returns to the same list")
	check(dropdown(main, library, "control_binding/play", "left_hand/ax_button") and not library.controls_page.pending.is_empty(), "Occupied editable binding still requires confirmation")
	check(main.controller_bindings.resolve("left_hand", "primary_click", "video_flat") == "play", "Pending swap preserves both mappings")
	check(tap_ui(main, library, library.ControlsPage.CANCEL) and library.controls_page.pending.is_empty(), "Ray cancellation leaves the mappings intact")
	check(dropdown(main, library, "control_binding/play", "left_hand/ax_button") and library.text_snapshot().contains(preload("res://scripts/i18n.gd").t("Swap these bindings?")), "Editable X opens the existing swap prompt")
	check(tap_ui(main, library, library.ControlsPage.SWAP), "Ray confirms the exchange")
	check(main.controller_bindings.resolve("left_hand", "ax_button", "video_flat") == "play" and main.controller_bindings.resolve("left_hand", "primary_click", "video_flat") == "library_video", "Confirmed swap gives each action the other's key")
	check(dropdown(main, library, "control_binding/play", "__default") and main.controller_bindings.resolve("right_hand", "ax_button", "video_flat") == "play", "Dropdown restores an individual default")
	check(dropdown(main, library, "control_binding/play", "__clear") and main.controller_bindings.bindings("play").is_empty(), "Dropdown can clear the binding")
	dropdown(main, library, "control_binding/play", "__default")
	check(main.controller_bindings.restore_one("library_video"), "Restore the library's ordinary X before combination checks")
	library.controls_page.mode = 2; library.scroll = 0; library.refresh()
	check(library.choices.targets.is_empty() and library.controls_page.selection.is_empty(), "Resting combinations also allocate no option controls")
	check(dropdown(main, library, "control_binding/subtitles", "right_hand/by_button"), "Combinations open one choice dialog from their text row")
	check(dropdown(main, library, "control_binding/subtitles", "left_hand/ax_button"), "A second choice replaces the previous combination")
	var chords: Array = main.controller_bindings.bindings("subtitles").filter(func(binding): return not binding.modifiers.is_empty())
	check(chords.size() == 1 and chords[0] == Bindings.bind("left_hand", "ax_button", Bindings.MODIFIERS), "Single dropdown keeps one grip+trigger combination")
	check(dropdown(main, library, "control_binding/subtitles", "__clear"), "Combination dropdown clears without affecting base controls")
	library.controls_page.mode = 0; library.refresh(); library.scroll = library._max_scroll(); library.refresh()
	check(dropdown(main, library, "control_move_scope", "all") and main.controller_bindings.move_scope == "all", "Movement range uses its own compact list dropdown")
	library.scroll = 0; library.refresh()
	var opener := choice_target(library, "control_binding/play", null, "open")
	check(tap_ui(main, library, opener) and library.choices.opened == "control_binding/play", "Dropdown still opens after repeated changes")
	var list_scroll: float = library.scroll
	main._process_sticks(Vector2.ZERO, Vector2(0, -0.99), 0.3)
	check(library.scroll == list_scroll and library.choices.offset == 0, "All-visible dialog consumes sticks without scrolling, selecting or moving the function list")
	before = host.calls.size(); tap(main, "ax_button")
	check(host.calls.size() == before, "Settings retain playback input isolation")
	tap(main, "by_button")
	check(library.visible and library.choices.opened.is_empty(), "Physical B closes only the settings dropdown")
	tap(main, "by_button")
	check(library.visible and library.section == library.Section.RECENT, "A second B returns from settings to the library")
	tap(main, "by_button")
	check(not library.visible and menu.visible, "At the playback library root B returns to the transport")
	library.dismiss(); menu.dismiss(); main.controller_bindings.restore_all()
	main.controller_bindings.assign("volume_up", Bindings.bind("right_hand", "stick_up", ["grip_click", "trigger_click"]), true, true)
	main._on_controller_button("grip_click", "right_hand"); main._on_controller_button("trigger_click", "right_hand")
	main._process_sticks(Vector2.ZERO, Vector2.ZERO, 0.1)
	before = host.calls.size()
	main._process_sticks(Vector2.ZERO, Vector2(0, 0.99), 0.1)
	check(host.calls.size() == before + 1 and host.calls.back()[0] == "audio", "Grip+trigger+stick reaches only configured volume")
	main._on_controller_release("trigger_click", "right_hand"); main._on_controller_release("grip_click", "right_hand")
	before = host.calls.size(); main._process_sticks(Vector2.ZERO, Vector2(0, 0.99), 0.1)
	check(host.calls.size() == before, "Modifier release cannot leak into a still-held basic stick action")
	main._on_controller_release("ax_button", "right_hand")
	var gallery := preload("res://scripts/photo_gallery.gd").new(); root.add_child(gallery)
	var card := Node3D.new(); gallery.add_child(card)
	gallery.cards[1] = {"node": card, "pose": Transform3D.IDENTITY}
	gallery.translate_layout(Vector3(0.1, 0.2, -0.1))
	check(card.global_position.is_equal_approx(Vector3(0.1, 0.2, -0.1)) and gallery.cards[1].pose.origin.is_equal_approx(card.global_position), "Gallery movement updates both visible and stored card positions")
	gallery.cards.clear(); gallery.free()
	library.free(); menu.free(); video.free(); main.free()
