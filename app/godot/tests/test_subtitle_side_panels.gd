extends SceneTree
const Player := preload("res://scripts/player_menu.gd")
const Library := preload("res://scripts/library_menu.gd")
const I18n := preload("res://scripts/i18n.gd")
const Capture := preload("res://scripts/menu_composition.gd")
var failures: Array[String] = []
var checks := 0

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func button(menu: Node3D, id: int) -> Dictionary:
	for entry in menu._buttons:
		if entry.target == id: return entry
	return {}

func tap(menu: Node3D, id: int) -> bool:
	var entry := button(menu, id)
	if entry.is_empty() or not entry.enabled: return false
	var node: Node3D = entry.node
	var origin := node.to_global(Vector3(0, 0, 0.4))
	var direction := -node.global_basis.z
	if int(menu.ray_hit(origin, direction).get("target", -1)) != id: return false
	menu.press_pointer("right_hand", origin, direction, true)
	menu.release_pointer("right_hand", origin, direction, true)
	return true

func field(menu: Node3D, key: String, kind: String = "") -> int:
	for id in menu.choices.targets:
		var item: Dictionary = menu.choices.targets[id]
		if item.get("key", "") == key and (kind.is_empty() or item.kind == kind): return id
	return -1

func _initialize() -> void: run.call_deferred()

func run() -> void:
	for locale in ["zh", "zh_Hant", "en", "ja"]:
		I18n.use(locale)
		for mode in 4:
			var cinema := mode % 2 == 1
			var low_end := mode >= 2
			var state := {"has_video": true, "source_uri": "file:///side-panel.mkv", "duration_ms": 120000,
				"subtitle_options": [{"id": 1, "title": "中文", "codec": "subrip"}, {"id": 2, "title": "English", "codec": "subrip"}], "subtitle_track": 1,
				"subtitle_files_available": true, "subtitle_files_state": "ready", "subtitle_files": ["movie.ja.srt"],
				"narration_available": true, "narration_enabled": true, "narration_status": "speaking", "narration_language": "zh", "narration_voice": "Yuewen",
				"narration_volume": 75.0, "narration_duck": 50.0, "listening_available": true, "listening_enabled": false,
				"subtitle_delay": 1.2, "subtitle_timing_key": "track:1"}
			var events: Array = []
			var world := Node3D.new(); root.add_child(world)
			var camera := Camera3D.new(); world.add_child(camera)
			var menu := Player.new(); world.add_child(menu); menu.set_process(false)
			menu.state_provider = func(): return state
			menu.setting_requested.connect(func(key, value): state[key] = value.value if value is Dictionary else value; events.append([key, value]))
			menu.subtitle_requested.connect(func(id): state.subtitle_track = id; events.append(["track", id]))
			menu.position = Vector3(-0.25, -0.45, -1.7)
			menu.layout_head_provider = func(): return Transform3D.IDENTITY
			menu.set_layout_viewer(Transform3D.IDENTITY)
			menu.set_cinema_world_anchor(cinema)
			menu.toggle(); menu._activate(110)
			check(menu._subtitle_detail_group().is_empty() and menu.choices.targets.is_empty(), "Details initially collapsed " + locale)
			check(menu._subtitle_groups().map(func(group): return group.group) == ["listening", "narration", "appearance"], "Approved entry order")
			check(menu._subtitle_group_states.listening.text == I18n.t("Off") and menu._subtitle_group_states.narration.text == I18n.t("On"), "Both states visible on the left before expanding")
			var footer_position: Vector3 = menu._subtitle_status_label.global_position
			var main_size: Vector2 = menu._subtitle_main_bounds.size
			var entry_x: float = button(menu, Player.SUBTITLE_LISTENING).node.global_position.x
			var heights := []
			for group in [Player.SUBTITLE_LISTENING, Player.SUBTITLE_NARRATION, Player.SUBTITLE_APPEARANCE]:
				check(tap(menu, group), "Ray opens connected detail " + str(group))
				heights.append(menu._subtitle_panel_bounds.size.y)
				check(is_equal_approx(button(menu, Player.SUBTITLE_ROW + 1).node.position.x, menu._subtitle_main_bounds.get_center().x) and menu._subtitle_main_bounds.size.x == main_size.x and main_size.x < 0.5, "Left column stays narrow while details switch")
				check(menu._subtitle_status_label.position.is_equal_approx(Vector3(menu._subtitle_main_bounds.get_center().x, 0.325, 0.004)) and menu._subtitle_status_label.text == I18n.t("Reading subtitles…"), "Narration status remains at left column bottom")
				check(is_zero_approx(menu._subtitle_panel_bounds.get_center().x), "The whole two-column plate is centered above transport")
				check(absf(button(menu, group).node.global_position.x - entry_x) < 0.01, "Opening details leaves the pointed entry in place")
				check(button(menu, group).node.get_child(0).horizontal_alignment == HORIZONTAL_ALIGNMENT_LEFT, "Left entries use left-aligned labels")
				check(events.is_empty() and state.narration_enabled and not state.listening_enabled, "Opening a group never changes options or starts/stops a feature")
				check(menu.choices.targets.keys().all(func(id): return button(menu, id).node.position.x > menu._subtitle_main_bounds.end.x), "Existing fields are in the right pane")
				check(not menu.allows_playback_sticks(), "Submenus retain playback shortcut isolation")
				var controls: Array = menu._buttons.filter(func(entry): return entry.enabled and entry.node.position.y > 0.285)
				var overlaps: Array = []
				for i in controls.size():
					for j in range(i + 1, controls.size()):
						if controls[i].rect.grow(-0.001).intersects(controls[j].rect.grow(-0.001)):
							overlaps.append([controls[i].target, controls[j].target])
				check(overlaps.is_empty(), "Narrow columns keep distinct ray hit areas: " + str(overlaps))
				if group == Player.SUBTITLE_APPEARANCE:
					var minus := -1; var plus := -1
					for id in menu.choices.targets:
						var item: Dictionary = menu.choices.targets[id]
						if item.get("key") == "subtitle_delay" and item.kind == "nudge":
							if item.step < 0: minus = id
							else: plus = id
					var sync: Dictionary = menu.choices.sliders[field(menu, "subtitle_delay", "slider")]
					check(button(menu, minus).rect.end.x < sync.node.position.x + sync.left and button(menu, plus).rect.position.x > sync.node.position.x + sync.left + sync.width, "Sync minus and plus flank the full-width rail")
					check(sync.label.position.y > 0.03 and sync.width > 0.4, "Sync time is above the rail without stealing its width")
				var divider: Node3D = menu._decorations.filter(func(node): return node is MeshInstance3D and node.mesh is QuadMesh and is_equal_approx(node.mesh.size.x, 0.003))[0]
				for edge in [-1, 1]:
					var seam_hit: Dictionary = menu.ray_hit(divider.to_global(Vector3(0, edge * (menu._subtitle_panel_bounds.size.y / 2 - 0.005), 0.4)), -divider.global_basis.z)
					check(not seam_hit.is_empty() and seam_hit.target == menu.NONE, "Inside seam consumes rays through both square corners")
			check(heights.max() > heights.min(), "Whole plate grows and shrinks with the active detail contents")
			check(tap(menu, Player.SUBTITLE_NARRATION), "Return to narration")
			check(tap(menu, field(menu, "narration_language", "open")), "Open original reading-language chooser by ray")
			check(not menu.choices.opened.is_empty() and menu.choices.targets.keys().filter(func(id): return menu.choices.targets[id].kind == "choose").all(func(id): return button(menu, id).node.position.x > menu._subtitle_main_bounds.end.x), "Raised dropdown options also stay on the right")
			check(is_equal_approx(Player.SUBTITLE_MAIN_WIDTH + Player.SUBTITLE_DETAIL_WIDTH, 1.10), "Both columns together retain the original subtitle panel width")
			var capture := Capture.new(); world.add_child(capture)
			capture.configure(world, camera, null, [menu], low_end, true); capture.set_process(false); capture.update()
			check(capture.layer_reservation() == 5, "Two columns preserve the existing five-provider budget")
			var items: Array[Dictionary] = []
			capture._gather(capture.active, items, capture._root_pose().affine_inverse(), false)
			var missed: Array[String] = []
			for item in items:
				if item.shown and not capture.slots.any(func(slot): return slot.used and slot.nodes.has(item.node)):
					missed.append(item.node.text if item.node is Label3D else str(item.node.get_class()))
			check(missed.is_empty(), "VR composition captures both panels, footer and raised dropdown: " + str(missed))
			for slot in capture.slots:
				if slot.used and not slot.empty:
					check(float(slot.raw.size.x) / slot.layer.quad_size.x >= Capture.DENSITY * capture._scale() * 0.9, "Connected panels preserve compositor density")
			capture.shutdown("test_complete"); capture.free()
			var language_choice := -1
			for id in menu.choices.targets:
				if menu.choices.targets[id].get("key") == "narration_language" and menu.choices.targets[id].get("value") == "zh": language_choice = id
			check(tap(menu, language_choice) and events.back() == ["narration_language", "zh"], "Existing choice signal survives translated layout")
			var before := events.size()
			check(tap(menu, Player.SUBTITLE_DETAIL_CLOSE) and menu._subtitle_detail_group().is_empty() and menu.choices.targets.is_empty(), "Right close removes all detail hit targets")
			check(events.size() == before and state.narration_enabled and not menu._subtitle_status_label.text.is_empty(), "Collapsing does not stop narration or hide its status")
			state.narration_status = "preparing"; state.narration_progress = 50; menu.refresh_values()
			check(menu._subtitle_status_label.text.contains("50%") and menu._subtitle_status_label.global_position.is_equal_approx(footer_position), "Collapsed footer updates progress without moving")
			check(tap(menu, Player.SUBTITLE_FILES) and menu._subtitle_file_ids.size() == 1, "Original external subtitle disclosure still works")
			var file_id: int = menu._subtitle_file_ids.keys()[0]
			check(button(menu, file_id).node.position.x < 0.55, "External file list stays in the original panel")
			var long_name := "A very long subtitle filename with the complete language and release information.zh-Hans.srt"
			state.subtitle_files = [long_name]; menu.refresh()
			var file_button := button(menu, file_id)
			check(file_button.node.get_child(0).text != long_name and menu._tips[file_id] == long_name, "Long filenames are abbreviated with the complete name on hover")
			menu.update_pointer("right_hand", file_button.node.to_global(Vector3(0, 0, 0.4)), -file_button.node.global_basis.z, true)
			check(menu._tooltip.visible and menu._tooltip.get_child(0).text == long_name, "Ray hover displays the entire filename")
			menu.update_pointer("right_hand", Vector3.ZERO, Vector3.ZERO, false)
			check(tap(menu, Player.SUBTITLE_FILES) and tap(menu, Player.SUBTITLE_ROW + 2) and state.subtitle_track == 2, "Track selection remains directly available")
			check(tap(menu, Player.SUBTITLE_LISTENING), "Listening opens without toggling it")
			check(tap(menu, field(menu, "listening_enabled", "choose")) and state.listening_enabled, "Original listening switch still emits its existing setting")
			state.narration_enabled = false; state.narration_available = false; state.listening_state = "ready"; state.listening_caption = "Listening status"; menu.refresh()
			check(menu._subtitle_group_states.listening.text == I18n.t("On") and menu._subtitle_group_states.narration.text == I18n.t("Off"), "Left states reflect real capability transitions")
			check(not button(menu, Player.SUBTITLE_NARRATION).enabled and not tap(menu, Player.SUBTITLE_NARRATION), "Live subtitles never enable unsupported TTS")
			check(tap(menu, Player.SUBTITLE_DETAIL_CLOSE) and menu._subtitle_status_label.text == "Listening status", "Listening status remains visible after folding")
			world.free()
	var settings := {"subtitle_size": 125.0, "voice_manager": {"narration_clone_supported": true}, "subtitle_defaults": {"listening_source": "ja", "listening_target": "zh-Hans"}}
	var library := Library.new(); root.add_child(library); library.set_process(false)
	library.settings_provider = func(): return settings
	var changes: Array = []
	library.setting_changed.connect(func(key, value): changes.append([key, value]))
	library.visible = true; library.section = library.Section.SETTINGS; library.tab = library.VIDEO_TAB; library.refresh()
	library._choose(library.rows.filter(func(row): return row.get("video_settings_group") == "subtitles")[0])
	check(library.rows.filter(func(row): return row.has("subtitle_settings_group")).map(func(row): return row.subtitle_settings_group) == ["listening", "narration", "appearance"], "Global categories follow the same order")
	for group in ["listening", "narration", "appearance", "listening"]:
		library._choose(library.rows.filter(func(row): return row.get("subtitle_settings_group", "") == group)[0])
		check(library._subtitle_settings_expanded == group and changes.is_empty(), "Opening a global category changes only expansion")
		check(library.rows.any(func(row): return row.get("key") == "listening_source") == (group == "listening"), "Listening defaults are exclusive")
		check(library.rows.any(func(row): return row.get("key") == "subtitle_size") == (group == "appearance"), "Appearance defaults are exclusive")
		check(library.rows.any(func(row): return row.get("voice_manager", false)) == (group == "narration"), "Original voice manager entry remains in its category")
	check(settings.subtitle_size == 125.0 and settings.subtitle_defaults.listening_source == "ja", "Grouping preserves global defaults")
	library.free()
	for failure in failures: push_error(failure)
	print("Subtitle side panels: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
