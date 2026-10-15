extends SceneTree
const Move := preload("res://scripts/interface_move.gd")
const InputMain := preload("res://tests/test_controller_bindings.gd").InputMain
var checks := 0
var failures: Array[String] = []

class GalleryPhoto extends Node3D:
	var view_camera: Camera3D

func check(value: bool, message: String) -> void:
	checks += 1
	if not value: failures.append(message)

func _initialize() -> void: call_deferred("run")

func facing(menu: Node3D, head: Transform3D) -> bool:
	var centre: Vector3 = menu.to_global(menu.panel_centre())
	return menu.global_basis.z.normalized().dot((head.origin - centre).normalized()) > 0.99999 and absf(menu.global_basis.x.y) < 0.00001

func default_controls(menu: Node3D, head: Transform3D) -> bool:
	var centre: Vector3 = Move.menu_head(head) * (Vector3(0, -0.45, -1.4) + menu.panel_centre())
	return menu.to_global(menu.panel_centre()).is_equal_approx(centre) and facing(menu, head)

func run() -> void:
	depth_geometry()
	menu_inputs()
	gallery_memory()
	media_depth_limits()
	for failure in failures: push_error(failure)
	print("Interface depth: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)

func depth_geometry() -> void:
	var move := Move.new()
	var follow := preload("res://scripts/view_follow.gd").new(); follow.set_enabled(true)
	var head := Transform3D(Basis.IDENTITY, Vector3(0, 1.6, 0))
	var panel := Node3D.new(); root.add_child(panel); panel.position = Vector3(0, 1.6, -2)
	var child := Node3D.new(); panel.add_child(child); child.position = Vector3(0, 0.75, 0)
	var relative := child.transform
	var pose := Transform3D(Basis.IDENTITY, Vector3(0, 1.6, -0.5))
	var targets := [{"node": panel, "kind": "menu", "pose": panel.global_transform, "key": "panel"}]
	check(move.begin("left_hand", "grip_click", pose, targets, panel.global_position, head), "Capture panel for depth movement")
	check(not move.adjust_distance(Vector2(0, 1), 0.1), "A stick held on capture waits for centre")
	move.adjust_distance(Vector2.ZERO, 0.1)
	for sample in [Vector2(1, 0), Vector2(0.8, 0.7), Vector2(0, 0.15), Vector2(NAN, 0), Vector2(0, INF)]:
		check(not move.adjust_distance(sample, 0.1), "Sideways, diagonal, deadzone and invalid axes do not change depth")
	check(not move.adjust_distance(Vector2(0, 1), NAN), "Invalid frame time cannot move an interface")
	for step in 20:
		check(move.adjust_distance(Vector2(0, 1), 0.05) and move.update(pose, head, follow), "Grip plus up continuously pushes away")
		check(is_equal_approx(panel.global_position.distance_to(head.origin), 2.0 + (step + 1) * 0.075) and child.transform.is_equal_approx(relative) and panel.scale.is_equal_approx(Vector3.ONE), "Depth changes distance while preserving physical size and linked layout")
	for step in 20:
		move.adjust_distance(Vector2(0, -1), 0.05); move.update(pose, head, follow)
	check(is_equal_approx(panel.global_position.distance_to(head.origin), 2), "Down reverses the distance adjustment")
	var distance := panel.global_position.distance_to(head.origin)
	pose.origin += Vector3(0.12, 0.04, -0.2); pose.basis = Basis(Vector3.UP, 0.2)
	move.update(pose, head, follow)
	check(is_equal_approx(panel.global_position.distance_to(head.origin), distance), "Hand movement alone still preserves the selected depth")
	check(move.placement("panel", head).is_equal_approx(panel.global_transform) and follow.pose("panel", head).is_equal_approx(panel.global_transform), "Movement and view follow use the same head-relative pose")
	for direction in [1, -1]:
		for step in 120:
			move.adjust_distance(Vector2(0, direction), 0.1); move.update(pose, head, follow)
		check(is_equal_approx(move.capture.anchor.distance_to(head.origin), Move.DEPTH_LIMITS.y if direction > 0 else Move.DEPTH_LIMITS.x), "Depth adjustment clamps at its finite limit")
	move.reset(); check(move.placements.is_empty() and move.capture.is_empty(), "Explicit helper reset clears session-only movement")
	check(Move.new().placements.is_empty(), "A new runtime starts without remembered poses")
	panel.free()

func menu_inputs() -> void:
	var main := InputMain.new()
	main.settings_path = "user://interface-depth.cfg"
	var video := preload("res://scripts/mpv_video_display.gd").new(); video.history_enabled = false
	root.add_child(video); video.set_process(false); main.video = video
	video.local_uri = "file:///interface-depth.mp4"; video.media.begin(1); video.media.state = "playing"
	var host := preload("res://tests/test_player_menu.gd").Host.new(); video.platform = host
	var menu := preload("res://scripts/player_menu.gd").new(); menu.state_provider = main._menu_state
	root.add_child(menu); menu.set_process(false); main.player_menu = menu; main.video_menu = menu
	var library := preload("res://scripts/library_menu.gd").new(); root.add_child(library); library.set_process(false); library.dismiss(); main.recent_menu = library
	for hand in ["left_hand", "right_hand"]:
		main.head_pose.basis = Basis.from_euler(Vector3(0.15, -0.3, 0.2))
		main._show_player_menu()
		check(facing(menu, main.head_pose), "Standard controls face the eye without inheriting head roll")
		main.rays[hand] = [menu.to_global(Vector3(0, 0, 1)), -menu.global_basis.z]
		var start := menu.global_transform
		var radius := start.origin.distance_to(main.head_pose.origin)
		main._on_controller_button("grip_click", hand)
		main._process_sticks(Vector2.ZERO, Vector2.ZERO, 0.05)
		var same := Vector2(0, 1); var other := Vector2.ZERO
		main.controller_bindings.press(hand, "trigger_click")
		main._process_sticks(same, same, 0.05)
		check(menu.global_transform.is_equal_approx(start), "Pending grip plus trigger leaves axes for existing chords")
		main.controller_bindings.release(hand, "trigger_click")
		main._process_sticks(other if hand == "left_hand" else same, same if hand == "left_hand" else other, 0.05)
		check(menu.global_transform.is_equal_approx(start), "Other hand cannot change the gripping hand's depth: " + hand)
		for step in 4:
			main._process_sticks(same if hand == "left_hand" else other, other if hand == "left_hand" else same, 0.05)
		check(menu.global_position.distance_to(main.head_pose.origin) > radius + 0.2 and host.calls.is_empty(), "Either grip plus its own up pushes the menu away without playback shortcuts")
		main.head_pose.origin += Vector3(0.01, 0.02, 0.03)
		main._on_controller_release("grip_click", hand)
		check(main.interface_move.capture.is_empty(), "Release finishes depth movement")
		var offset: Transform3D = Move.menu_head(main.head_pose).affine_inverse() * menu.global_transform
		check(offset.is_equal_approx(main.interface_move.placements[main._menu_key(menu)]) and not main.view_follow.enabled, "Release snapshots the current head-relative pose without enabling follow")
		main.head_pose = Transform3D(Basis.from_euler(Vector3(0.15, -0.3, 0.1)), Vector3(0.3, 1.7, 0.2))
		var fixed := menu.global_transform; main._update_view_follow()
		check(menu.global_transform.is_equal_approx(fixed), "Follow off leaves the visible menu in place")
		menu.dismiss(); main._show_player_menu()
		var restored: Transform3D = Move.menu_head(main.head_pose) * offset
		check(menu.to_global(menu.panel_centre()).is_equal_approx(restored * menu.panel_centre()) and facing(menu, main.head_pose), "Reopening restores the remembered centre and faces the current eye")
		main._on_system_recentered()
		check(not main.interface_move.placements.has(main._menu_key(menu)) and default_controls(menu, main.head_pose), "System recenter restores the default centre and viewer-facing controls")
		main._on_session_control("follow")
		main.rays[hand] = [menu.to_global(Vector3(0, 0, 1)), -menu.global_basis.z]
		main._on_controller_button("grip_click", hand)
		main._process_sticks(Vector2.ZERO, Vector2.ZERO, 0.05)
		main._process_sticks(same if hand == "left_hand" else other, other if hand == "left_hand" else same, 0.05)
		main._on_controller_release("grip_click", hand)
		offset = main.head_pose.affine_inverse() * menu.global_transform
		check(main.view_follow.enabled and main.interface_move.capture.is_empty(), "Grip movement and release leave an enabled follow switch unchanged")
		for step in 8:
			main.head_pose = Transform3D(Basis.from_euler(Vector3(0.02 * step, 0.06 * step, -0.02 * step)), Vector3(0.02 * step, 1.6, 0.04 * step))
			main._update_view_follow()
			check((main.head_pose.affine_inverse() * menu.global_transform).is_equal_approx(offset), "View follow preserves the same remembered head-relative position and orientation")
		main._on_session_control("follow")
		check(absf(menu.global_basis.x.normalized().y) < 0.00001, "Disabling follow removes head roll from the menu")
		main._recenter()
		check(not main.interface_move.placements.has(main._menu_key(menu)) and default_controls(menu, main.head_pose), "In-app recenter also restores viewer-facing controls without roll")
	var rows := library.controls_page.items()
	check(rows.any(func(row): return row.get("fixed", "") == "Grip + stick ↑ / ↓") and rows.any(func(row): return row.get("fixed", "") == "Trigger + stick ↑ / ↓"), "Button guide includes both distance combinations")
	var saved := ConfigFile.new(); saved.load(main.settings_path)
	check(not saved.has_section("interface") and not saved.has_section("placements"), "Head-relative positions are never written to disk")
	library.free(); menu.free(); video.free(); main.free()

func gallery_memory() -> void:
	var camera := Camera3D.new(); root.add_child(camera); camera.position = Vector3(0, 1.6, 0)
	var photo := GalleryPhoto.new(); root.add_child(photo); photo.view_camera = camera
	var gallery := preload("res://scripts/photo_gallery.gd").new(); root.add_child(gallery); gallery.photo = photo; gallery.mode = 2
	gallery.recenter()
	gallery.transform_layout(Transform3D(Basis(Vector3.UP, 0.2), Vector3(0.3, 0.1, -0.2)))
	var local := camera.global_transform.affine_inverse() * gallery.anchor
	camera.transform = Transform3D(Basis.from_euler(Vector3(0.1, -0.3, 0.05)), Vector3(0.5, 1.7, 0.8))
	gallery.recenter(false)
	check(gallery.anchor.is_equal_approx(camera.global_transform * local), "Photo layout recenter retains its head-relative grip placement")
	var settings := ConfigFile.new(); gallery.save_settings(settings)
	var fresh := preload("res://scripts/photo_gallery.gd").new(); fresh.restore_settings(settings)
	check(fresh._layout_offsets.is_empty(), "A new photo layout never restores grip placement from settings")
	fresh.free(); gallery.free(); photo.free(); camera.free()

func media_depth_limits() -> void:
	var video := preload("res://scripts/mpv_video_display.gd").new(); video.history_enabled = false; root.add_child(video); video.set_process(false)
	var head := Transform3D(Basis.IDENTITY, Vector3(0, 1.6, 0))
	var pose := Transform3D(Basis.IDENTITY, Vector3(0, 1.5, -0.5))
	for limits in [Vector2(0.8, 8), Vector2(0.3, 10)]:
		var move := Move.new()
		video.set_flat_world_pose(Transform3D(Basis.IDENTITY, head.origin + Vector3(0, 0, -2)))
		var target := {"kind": "screen", "key": "video", "node": video, "pose": video.global_transform * video.flat_pose, "distance_limits": limits}
		move.begin("right_hand", "grip_click", pose, [target], target.pose.origin + Vector3(0.4, 0.1, 0), head)
		move.adjust_distance(Vector2.ZERO, 0.05)
		for direction in [1, -1]:
			for step in 300:
				move.adjust_distance(Vector2(0, direction), 0.1); move.update(pose, head, preload("res://scripts/view_follow.gd").new())
			var distance := video.panel.global_position.distance_to(head.origin)
			check(distance >= limits.x - 0.0001 and distance <= limits.y + 0.0001 and (is_equal_approx(distance, limits.y) if direction > 0 else distance < 2.0), "Off-centre grip respects actual video/photo centre distance limits: %s within %s" % [distance, limits])
	video.free()
