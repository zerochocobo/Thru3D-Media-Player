extends RefCounted
## Invoked only by the existing Debug seek_policy_ui command. Uses synthetic fixtures and
## production pointer/movement methods on the headset, without physical controller injection.
const Library := preload("res://scripts/library_menu.gd")

static func tap(host: Node, target: int) -> bool:
	for button in host.recent_menu._buttons:
		if button.target != target or not button.enabled or not button.node.is_visible_in_tree(): continue
		var origin: Vector3 = button.node.global_position + button.node.global_basis.z * 0.3
		var direction: Vector3 = -button.node.global_basis.z
		if not host.player_menu.ray_hit(origin, direction).get("library", false): return false
		if not host.player_menu.press_pointer("right_hand", origin, direction, true): return false
		host.player_menu.release_pointer("right_hand", origin, direction, true)
		return true
	return false

func run(host: Node, step: String) -> Dictionary:
	# Production save/reset calls write only the probe's disposable settings copy.
	var original_settings: ConfigFile = host.settings
	var original_path: String = host.settings_path
	var scratch := ConfigFile.new()
	for section in original_settings.get_sections():
		for key in original_settings.get_section_keys(section): scratch.set_value(section, key, original_settings.get_value(section, key))
	host.settings = scratch; host.settings_path = "user://diagnostics/playback-recovery-settings.cfg"
	var result := _run(host, step)
	host.settings = original_settings; host.settings_path = original_path
	result["step"] = step
	result["scope"] = "Production MPV/XR and software pointer/grip route; physical controller acceptance pending"
	result["library_visible"] = host.recent_menu.is_visible_in_tree()
	result["player_visible"] = host.player_menu.is_visible_in_tree()
	result["pointer_capture"] = host.player_menu.has_pointer_capture()
	result["source_uri"] = host.video.local_uri
	result["distance"] = host.video.screen_distance
	result["grip_placement"] = host.interface_move.placements.has(&"video")
	result["compositor"] = host.menu_composition.snapshot()
	result["captured_library_nodes"] = host.menu_composition.originals.filter(func(item): return is_instance_valid(item.node) and host.recent_menu.is_ancestor_of(item.node)).size()
	return result

func _run(host: Node, step: String) -> Dictionary:
	var library: Node3D = host.recent_menu
	var video: Node3D = host.video
	match step:
		"recovery_setup":
			host._show_full_library()
			library.section = Library.Section.LOCAL
			var folder := OS.get_user_data_dir().path_join("fixtures")
			library._local_stack = [{"id": folder, "title": "Recovery"}]
			library._local_entries = []
			for name in ["playback_recovery_a_2D.mp4", "playback_recovery_b_2D.mp4"]:
				library._local_entries.append({"uri": "file://" + folder.path_join(name), "title": name})
			library.refresh(); library.remember_playback_context()
			video.history_enabled = false
			host._on_library_chosen(str(library._local_entries[0].uri), str(library._local_entries[0].title))
			return {"accepted": video.geometry == 0 and not video.local_uri.is_empty()}
		"recovery_open":
			if not library.visible: host._show_recent_menu()
			return {"accepted": host.player_menu.has_expanded_library()}
		"recovery_expand":
			host._toggle_library_layout()
			return {"accepted": library.visible and library.playback_expanded}
		"recovery_choose":
			for index in library.rows.size():
				var row: Dictionary = library.rows[index]
				if str(row.get("uri", "")) != video.local_uri and row.has("uri"):
					var expected := str(row.uri)
					var accepted := tap(host, Library.ROW_BASE + index - library._first_line() * library._cols())
					return {"accepted": accepted and video.local_uri == expected and not library.visible}
		"recovery_close":
			return {"accepted": tap(host, Library.CLOSE) and not library.visible}
		"recovery_hide":
			host.player_menu.dismiss()
			return {"accepted": not library.visible and not host.player_menu.visible}
		"recovery_reopen":
			host._show_player_menu()
			return {"accepted": host.player_menu.visible and not library.visible}
		"recovery_drag", "recovery_pull", "recovery_follow_pull":
			if step == "recovery_follow_pull": host.view_follow.set_enabled(true)
			host._recenter(); host.player_menu.dismiss()
			var head: Variant = host._head_pose()
			if not head is Transform3D: return {"accepted": false, "reason": "head_untracked"}
			var pose: Transform3D = head * Transform3D(Basis.IDENTITY, Vector3(0, 0, -0.3))
			var world: Transform3D = video.global_transform * video.flat_pose
			var targets := [{"node": video, "kind": "screen", "pose": world, "key": &"video", "distance_limits": video.DISTANCE_LIMITS}]
			if not host.interface_move.begin("right_hand", "grip_click", pose, targets, world.origin, head): return {"accepted": false}
			if step == "recovery_drag":
				pose.origin += head.basis * Vector3(0.15, 0.18, 0)
				host.interface_move.update(pose, head, host.view_follow)
			else:
				host.interface_move.adjust_distance(Vector2.ZERO, 0.1)
				for i in 14:
					host.interface_move.adjust_distance(Vector2(0, -1), 0.1)
					host.interface_move.update(pose, head, host.view_follow)
			host._finish_interface_move()
			return {"accepted": host.interface_move.placements.has(&"video") and not (video.global_transform * video.flat_pose).is_equal_approx(world)}
		"recovery_recenter", "recovery_system_recenter":
			if step == "recovery_system_recenter": host._on_system_recentered()
			else: host._recenter()
			var expected: Variant = host._head_pose() * Transform3D(Basis.IDENTITY, Vector3(0, 0, -video.SCREEN_DISTANCE)) if host.view_follow.enabled else host._view_pose(video.SCREEN_DISTANCE, 0)
			return {"accepted": expected is Transform3D and (video.global_transform * video.flat_pose).is_equal_approx(expected) and not host.interface_move.placements.has(&"video") and is_equal_approx(video.screen_distance, video.SCREEN_DISTANCE)}
		"recovery_finish":
			host.view_follow.set_enabled(false); host._close_current_media()
			video.history_enabled = bool(host.settings.get_value("library", "history", true))
			library.section = Library.Section.RECENT; library._local_entries = []; library.refresh()
			return {"accepted": true}
		"recovery_snapshot": return {"accepted": true}
	return {"accepted": false, "reason": "unknown_step"}
