extends SceneTree
const Library := preload("res://scripts/library_menu.gd")
const I18n := preload("res://scripts/i18n.gd")
var checks := 0
var failures: Array[String] = []
var events: Array = []

func check(ok: bool, text: String) -> void:
	checks += 1
	if not ok: failures.append(text)

func target(menu: Node3D, key: String, value: Variant = null, kind: String = "choose") -> int:
	for id in menu.choices.targets:
		var item: Dictionary = menu.choices.targets[id]
		if item.get("kind") == kind and item.get("key") == key and (kind == "open" or menu.choices.same(item.get("value"), value)): return id
	return -1

func origin(menu: Node3D, id: int) -> Vector3:
	for button in menu._buttons:
		if button.target == id: return button.node.to_global(Vector3(0, 0, 1))
	return Vector3.ZERO

func tap(menu: Node3D, id: int) -> void:
	var point := origin(menu, id)
	menu.press_pointer("left_hand", point, -menu.global_basis.z, true)
	menu.release_pointer("left_hand", point, -menu.global_basis.z, true)

func _initialize() -> void: call_deferred("_run")

func _run() -> void:
	I18n.use("en")
	var state := {"seek_mode": "speed", "background": "belfast", "background_yaw": 0, "background_brightness": 1.0, "privacy_mode": "all"}
	var menu := Library.new()
	menu.section = Library.Section.SETTINGS; menu.tab = Library.GENERAL_TAB
	menu.settings_provider = func(): return state
	menu.setting_changed.connect(func(key, value):
		events.append([key, value]); state[key] = value
		if key == "language": I18n.use(str(value)))
	root.add_child(menu); menu.toggle(); menu.set_process(false)
	check(menu.rows.filter(func(row): return row.get("key", "") == "language").size() == 1 and menu.rows.any(func(row): return row.get("group_header", false) and row.get("title", "") == I18n.t("Privacy settings")), "One language row and the current collapsible privacy group")
	var open_id := target(menu, "language", null, "open")
	var value_button: Dictionary = menu._buttons.filter(func(button): return button.target == open_id)[0]
	check(value_button.node is MeshInstance3D and value_button.has("select_arrow"), "Resting choice has a filled surface and a vector dropdown arrow")
	var point: Vector3 = value_button.node.to_global(Vector3(value_button.rect.size.x / 2 - 0.032, 0, 1))
	check(menu.ray_hit(point, -menu.global_basis.z).get("target", -1) == open_id, "Arrow and value use the same dropdown ray target")
	menu.press_pointer("left_hand", point, -menu.global_basis.z, true)
	check(menu.choices.opened.is_empty() and not menu.choices.capture.is_empty(), "Dropdown opens only on owning release")
	menu.release_pointer("right_hand", point, -menu.global_basis.z, true)
	check(menu.choices.opened.is_empty(), "Other hand cannot open a captured dropdown")
	menu.release_pointer("left_hand", point, -menu.global_basis.z, true)
	check(menu.choices.opened == "language" and menu.choices.popup.choices.size() == 5, "Opening reveals the five languages")
	menu.stick_scroll(-1.0, 0.5)
	check(events.is_empty(), "Stick scrolling never chooses a language")
	var language_id := target(menu, "language", "zh")
	point = origin(menu, language_id)
	menu.press_pointer("left_hand", point, -menu.global_basis.z, true)
	check(events.is_empty(), "Choice press does not apply immediately")
	menu.cancel_pointer("left_hand")
	menu.release_pointer("left_hand", point, -menu.global_basis.z, true)
	check(events.is_empty() and menu.choices.opened == "language", "Cancelled choice leaves setting unchanged")
	tap(menu, target(menu, "language", "zh"))
	check(events == [["language", "zh"]] and menu.choices.opened.is_empty() and I18n.choice == "zh", "Language selects directly and closes the list")
	tap(menu, target(menu, "language", null, "open"))
	point = origin(menu, target(menu, "language", "ja"))
	menu.press_pointer("left_hand", point, -menu.global_basis.z, true)
	menu._activate(Library.TAB_BASE + Library.VIDEO_TAB)
	menu.release_pointer("left_hand", point, -menu.global_basis.z, true)
	check(events.size() == 1 and menu.choices.capture.is_empty() and menu.choices.opened.is_empty(), "Tab switch cancels old dropdown ownership and stale release")
	check(menu.rows[0].key == "seek_mode" and menu.rows[0].choices.size() == 2 and menu.rows[1].key == "depth_render" and menu.rows[1].compact
		and menu.rows[2].key == "output_width" and menu.rows[2].compact
		and menu.rows[3].key == "memory_mode" and menu.rows.size() == 6 and menu.rows[4].video_settings_group == "alpha" and menu.rows[5].video_settings_group == "subtitles",
		"Video starts with common choices and two collapsed groups")
	check(menu.choices.targets.values().all(func(item): return item.get("key", "") in ["seek_mode", "depth_render", "output_width", "memory_mode"]), "Collapsed groups have no hidden ray controls")
	var alpha_point := origin(menu, Library.ROW_BASE + 4)
	menu.press_pointer("left_hand", alpha_point, -menu.global_basis.z, true)
	check(menu.rows.size() == 6, "Group expansion waits for trigger release")
	menu.cancel_pointer("left_hand")
	menu.release_pointer("left_hand", alpha_point, -menu.global_basis.z, true)
	check(menu.rows.size() == 6, "Cancelled group click stays collapsed")
	tap(menu, Library.ROW_BASE + 4)
	check(menu.rows.size() == 10 and menu.rows[4].icon == "chevron_down" and not menu.collections.privacy_expanded,
		"Ray expands only Alpha without changing the privacy group")
	var alpha_row: Dictionary = menu.rows[5]
	check(alpha_row.key == "alpha_profile" and alpha_row.compact and alpha_row.value == "320x320"
		and alpha_row.choices.map(func(o): return o.value) == ["256x256", "320x320", "384x384", "512x512"]
		and str(alpha_row.get("hint", "")).is_empty() and not str(alpha_row.info).is_empty()
		and alpha_row.choices.all(func(o): return o.hint == alpha_row.info),
		"Alpha model size sits above the frame rate: four square sizes, 320 by default, larger slower and smaller rougher")
	state.alpha_cold = ["512x512"]; state.alpha_warming = ["384x384"]; menu.refresh()
	check(menu.rows[5].choices[3].get("hint", "") == "First use prepares the model, about 1 minute" and menu.rows[5].choices[2].get("hint", "") == "Preparing the model"
		and menu.rows[5].choices[1].hint == menu.rows[5].info, "A cold or compiling size says so on its own option; ready ones keep the trade-off tooltip")
	tap(menu, target(menu, "alpha_profile", "512x512"))
	check(events.back() == ["alpha_profile", "512x512"], "Choosing a size reports it")
	state.erase("alpha_cold"); state.erase("alpha_warming"); state.alpha_profile = "320x320"; menu.refresh()
	check(menu.rows[6].key == "alpha_fps" and menu.rows[6].slider and menu.rows[6].span == Vector3(10, 40, 1) and menu.rows[6].value == 30 and not str(menu.rows[6].hint).is_empty(), "Alpha frame rate is a 10-40 FPS slider defaulting to 30 with a passthrough hint")
	check(menu.rows[7].key == "alpha_feather" and menu.rows[7].value == 100 and menu.rows[8].key == "alpha_shrink" and menu.rows[8].value == 40
		and menu.rows[8].span == Vector3(0, 100, 1), "Alpha feather and edge shrink follow the frame rate, as in the player settings")
	check(not menu.rows.any(func(row): return row.get("key", "") == "alpha_precision"), "AI precision stays hidden")
	check(alpha_row.choices[1].label.begins_with("320 ") and alpha_row.choices.filter(func(o): return o.label.contains(" ")).size() == 1,
		"Only the 320 size is marked as the default")
	menu._set_scroll(menu._max_scroll())
	tap(menu, Library.ROW_BASE + 9 - menu._first_line())
	check(menu.rows.size() == 12 and menu._video_settings_expanded.get("alpha") and menu._video_settings_expanded.get("subtitles"), "Subtitle group opens with two collapsed categories beside Alpha")
	var saved_events := events.size()
	menu._set_scroll(2.0); tap(menu, Library.ROW_BASE + 4 - menu._first_line())
	check(menu.rows.size() == 8 and menu._video_settings_expanded.get("subtitles") and not menu._video_settings_expanded.get("alpha"), "Collapsing Alpha keeps the subtitle category entries visible")
	menu._set_scroll(3.0); tap(menu, Library.ROW_BASE + 5 - menu._first_line())
	check(menu.rows.size() == 6 and menu.scroll == 0 and not is_instance_valid(menu._settings_scroll_hint) and events.size() == saved_events,
		"Collapsing both groups removes scrolling without changing preferences")
	menu.settings_provider = func(): return state.merged({"voice_manager": {"narration_clone_supported": true}})
	menu.refresh()
	check(not menu.rows.any(func(row): return row.get("voice_manager", false)), "Narration management stays inside collapsed subtitles")
	tap(menu, Library.ROW_BASE + 5)
	check(menu.rows.any(func(row): return row.get("subtitle_settings_group", "") == "narration"), "Expanding subtitles exposes the narration category")
	menu._choose(menu.rows.filter(func(row): return row.get("subtitle_settings_group", "") == "narration")[0])
	check(menu.rows.any(func(row): return row.get("voice_manager", false)), "Expanding narration exposes its unchanged voice manager")
	menu.settings_provider = func(): return state
	menu._set_scroll(0)
	tap(menu, target(menu, "seek_mode", "exact"))
	check(state.seek_mode == "exact" and events.back() == ["seek_mode", "exact"], "Radio selection chooses precision directly")
	var selected := 0
	for button in menu._buttons:
		if menu.choices.targets.has(button.target) and menu.choices.targets[button.target].get("key") == "seek_mode" and button.base_color == menu.SELECTED: selected += 1
	check(selected == 1, "Exactly one radio is visibly selected")
	menu._activate(Library.TAB_BASE + Library.BACKGROUND_TAB)
	check(menu._video_settings_expanded.is_empty(), "Leaving the tab resets group expansion")
	tap(menu, target(menu, "background_yaw", null, "open"))
	check(menu.choices.opened == "background_yaw" and menu.choices.popup.choices.size() == 8, "Longer direction list uses a dropdown")
	var before := events.size()
	menu.stick_scroll(-1.0, 0.4)
	check(menu.choices.offset > 0 and events.size() == before and state.background_yaw == 0, "Joystick moves only dropdown rows, preserving the current value")
	tap(menu, target(menu, "background_yaw", 315))
	check(state.background_yaw == 315 and events.back() == ["background_yaw", 315], "Scrolled dropdown exposes and selects its final option")
	tap(menu, target(menu, "background", null, "open"))
	point = origin(menu, target(menu, "background", "dark"))
	menu.press_pointer("left_hand", point, -menu.global_basis.z, true)
	menu.update_pointer("left_hand", Vector3.ZERO, Vector3.ZERO, false)
	menu.release_pointer("left_hand", point, -menu.global_basis.z, true)
	check(state.background == "belfast", "Tracking loss cancels a pending background choice")
	menu._activate(Library.TAB_BASE + Library.DISPLAY_TAB)
	check(is_instance_valid(menu._settings_scroll_hint) and menu._settings_scroll_hint.visible,
		"Overflowing settings show a downward cue on first opening")
	for position in [0.0, 0.34, 0.66, menu._max_scroll()]:
		menu._set_scroll(position)
		var hint: MeshInstance3D = menu._settings_scroll_hint
		check(hint.visible == (position < menu._max_scroll()), "Down cue disappears exactly at the end")
		if not hint.visible:
			var stopped := hint.position.y
			menu._animate_settings_scroll_hint(1.0)
			check(hint.position.y == stopped and menu._settings_scroll_hint_time == 0, "At the end the hidden cue stops animating")
			continue
		var positions: Array[float] = []
		menu._settings_scroll_hint_time = 0.0
		for phase in 4:
			menu._animate_settings_scroll_hint(Library.SCROLL_HINT_PERIOD / 4)
			positions.append(hint.position.y)
			var top: float = hint.position.y + hint.mesh.size.y / 2
			var hint_bottom: float = hint.position.y - hint.mesh.size.y / 2
			for button in menu._buttons:
				if not button.node.visible: continue
				if menu._row_target(int(button.get("list_row", button.target))):
					var bottom: float = menu.to_local(button.node.global_position).y - button.rect.size.y / 2
					check(bottom - top >= Library.SCROLL_HINT_GAP - 0.0001, "Floating cue stays clear of every fractional last-row control")
				elif button.target in [Library.RESTART_APP, Library.QUIT_APP]:
					check(hint_bottom > button.rect.end.y, "Lowest animation position also clears the footer buttons")
		check(is_equal_approx(positions.max() - positions.min(), 0.005), "Floating is limited to 5 mm total travel")
		if position == 0:
			check(positions.min() > -0.43, "The cue stays closer to the settings than the previous -0.451 m position")
		var ray := hint.to_global(Vector3(0, 0, 1))
		var with_hint: Dictionary = menu.ray_hit(ray, -menu.global_basis.z)
		hint.visible = false
		check(menu.ray_hit(ray, -menu.global_basis.z).get("target", -1) == with_hint.get("target", -1), "Scroll cue never captures a ray")
		hint.visible = true
	menu._set_scroll(0)
	tap(menu, target(menu, "watch_color", "violet"))
	check(state.watch_color == "violet" and menu._settings_scroll_hint.visible, "Last visible row remains operable beside the scroll cue")
	menu._set_scroll(menu._max_scroll())
	point = origin(menu, target(menu, "watch_color", "blue"))
	before = events.size()
	menu.press_pointer("right_hand", point, -menu.global_basis.z, true)
	menu.release_pointer("left_hand", point, -menu.global_basis.z, true)
	check(events.size() == before, "Watch swatch waits for its owning hand to release")
	menu.cancel_pointer("right_hand")
	menu.release_pointer("right_hand", point, -menu.global_basis.z, true)
	check(events.size() == before, "Cancelled swatch leaves the watch unchanged")
	for option in Library.WatchPalette.OPTIONS:
		tap(menu, target(menu, "watch_color", option.value))
		check(events.back() == ["watch_color", option.value] and state.watch_color == option.value,
			"Ray selects watch color: " + option.value)
		var chosen := 0
		for button in menu._buttons:
			if menu.choices.targets.get(button.target, {}).get("key") != "watch_color": continue
			if button.base_color == Color.WHITE: chosen += 1
		check(chosen == 1, "Exactly one watch swatch is selected")
	menu._activate(Library.TAB_BASE + Library.BACKGROUND_TAB)
	check(menu._max_scroll() == 0 and not is_instance_valid(menu._settings_scroll_hint), "Short settings pages have no scrolling cue")
	menu._activate(Library.TAB_BASE + Library.VIDEO_TAB)
	tap(menu, Library.ROW_BASE + 4)
	menu.dismiss()
	check(menu.choices.opened.is_empty() and menu.choices.capture.is_empty(), "Closing settings clears popup and capture")
	menu.toggle()
	check(menu.rows.size() == 6 and menu._video_settings_expanded.is_empty(), "Reopening settings restores the collapsed groups")
	menu.queue_free()
	print("Choice field checks=%d failures=%d" % [checks, failures.size()])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)
