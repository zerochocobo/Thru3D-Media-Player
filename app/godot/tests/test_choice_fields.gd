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

func video_group_target(menu: Node3D, group: String) -> int:
	var index: int = menu.rows.find_custom(func(row): return row.get("video_settings_group") == group)
	menu._set_scroll(float(index))
	return Library.ROW_BASE + menu._row_slot(index)

func setting_row(menu: Node3D, key: String) -> Dictionary:
	return menu.rows.filter(func(row): return row.get("key") == key)[0]

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
	check(menu.rows[0].key == "seek_mode" and menu.rows[0].choices.size() == 2 and menu.rows[1].key == "seek_step_seconds"
		and menu.rows.slice(2).map(func(row): return row.video_settings_group) == ["output", "depth", "alpha", "subtitles"],
		"Video starts with quick seek controls and four collapsed groups")
	check(menu.choices.targets.values().all(func(item): return item.get("key", "") in ["seek_mode", "seek_step_seconds"]),
		"Collapsed groups have no hidden ray controls")
	tap(menu, video_group_target(menu, "output"))
	check(setting_row(menu, "hdr_to_sdr").value == "on" and setting_row(menu, "output_width").compact
		and menu.rows.slice(3, 6).map(func(row): return row.key) == ["hdr_to_sdr", "output_width", "memory_mode"],
		"Output groups HDR, resolution and memory")
	tap(menu, video_group_target(menu, "output"))
	tap(menu, video_group_target(menu, "depth"))
	check(setting_row(menu, "depth_render").compact
		and menu.rows.slice(4, 10).map(func(row): return row.key) == ["video_auto_3d", "depth_render", "depth_edge_steady", "depth_edge_fade", "depth_position_default", "depth_foreground_default"],
		"2D to 3D groups automatic conversion, edge treatment, convergence and foreground scale")
	tap(menu, video_group_target(menu, "depth"))
	var alpha_point := origin(menu, video_group_target(menu, "alpha"))
	menu.press_pointer("left_hand", alpha_point, -menu.global_basis.z, true)
	check(menu.rows.size() == 6, "Group expansion waits for trigger release")
	menu.cancel_pointer("left_hand")
	menu.release_pointer("left_hand", alpha_point, -menu.global_basis.z, true)
	check(menu.rows.size() == 6, "Cancelled group click stays collapsed")

	tap(menu, video_group_target(menu, "alpha"))
	check(menu.rows.size() == 13 and menu.rows[4].icon == "chevron_down" and not menu.collections.privacy_expanded
		and menu.rows.slice(5, 7).map(func(row): return row.key) == ["alpha_auto_from_filename", "alpha_keep_background"],
		"Ray expands only the passthrough settings with both behavior controls at the top")
	var alpha_row := setting_row(menu, "alpha_profile")
	check(alpha_row.compact and alpha_row.value == "320x320"
		and alpha_row.choices.map(func(o): return o.value) == ["256x256", "320x320", "384x384", "512x512"]
		and str(alpha_row.get("hint", "")).is_empty() and not str(alpha_row.info).is_empty()
		and alpha_row.choices.all(func(o): return o.hint == alpha_row.info),
		"Alpha model size sits above the frame rate: four square sizes, 320 by default, larger slower and smaller rougher")
	state.alpha_cold = ["512x512"]; state.alpha_warming = ["384x384"]; menu.refresh()
	var warming_row := setting_row(menu, "alpha_profile")
	check(warming_row.choices[3].get("hint", "") == "First use prepares the model, about 1 minute"
		and warming_row.choices[2].get("hint", "") == "Preparing the model"
		and warming_row.choices[1].hint == warming_row.info, "A cold or compiling size says so on its own option; ready ones keep the trade-off tooltip")
	tap(menu, target(menu, "alpha_profile", "512x512"))
	check(events.back() == ["alpha_profile", "512x512"], "Choosing a size reports it")
	state.erase("alpha_cold"); state.erase("alpha_warming"); state.alpha_profile = "320x320"; menu.refresh()
	var fps := setting_row(menu, "alpha_fps")
	check(fps.slider and fps.span == Vector3(10, 40, 1) and fps.value == 30 and not str(fps.hint).is_empty(),
		"Alpha frame rate is a 10-40 FPS slider defaulting to 30 with a passthrough hint")
	var feather := setting_row(menu, "alpha_feather")
	var shrink := setting_row(menu, "alpha_shrink")
	check(feather.value == 100 and shrink.value == 40 and shrink.span == Vector3(0, 100, 1),
		"Alpha feather and edge shrink follow the frame rate, as in the player settings")
	var interpolation := setting_row(menu, "alpha_mask_blend")
	check(interpolation.value == true and interpolation.choices.size() == 2
		and not str(interpolation.choices[0].hint).is_empty() and interpolation.choices[0].hint != interpolation.choices[1].hint,
		"Cut-out interpolation follows the edge sliders: on by default, each choice explains its cost")
	check(not menu.rows.any(func(row): return row.get("key", "") == "alpha_precision"), "AI precision stays hidden")
	check(alpha_row.choices[1].label.begins_with("320 ") and alpha_row.choices.filter(func(o): return o.label.contains(" ")).size() == 1,
		"Only the 320 size is marked as the default")
	tap(menu, video_group_target(menu, "subtitles"))
	check(menu.rows.size() == 15 and menu._video_settings_expanded.get("alpha") and menu._video_settings_expanded.get("subtitles"),
		"Subtitle group opens with two collapsed categories beside Alpha")
	var saved_events := events.size()
	tap(menu, video_group_target(menu, "alpha"))
	check(menu.rows.size() == 8 and menu._video_settings_expanded.get("subtitles") and not menu._video_settings_expanded.get("alpha"),
		"Collapsing Alpha keeps the subtitle category entries visible")
	tap(menu, video_group_target(menu, "subtitles"))
	check(menu.rows.size() == 6 and menu.scroll <= menu._max_scroll() and is_instance_valid(menu._settings_scroll_hint) == (menu._max_scroll() > 0) and events.size() == saved_events,
		"Collapsing both groups clamps scrolling without changing preferences")
	menu.settings_provider = func(): return state.merged({"voice_manager": {"narration_clone_supported": true}})
	menu.refresh()
	check(not menu.rows.any(func(row): return row.get("voice_manager", false)), "Narration management stays inside collapsed subtitles")
	tap(menu, video_group_target(menu, "subtitles"))
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
	var catalog := preload("res://scripts/background_library.gd").new(); root.add_child(catalog)
	var scenery := preload("res://scripts/scenery_menu.gd").new(); scenery.library=catalog
	var previews: Array = []
	var adjusted_modes: Array = []
	scenery.state_provider=func(_mode): return {"selected":str(state.get("background","belfast")),"choice":str(state.get("background","belfast")),"yaw":state.background_yaw,"brightness":1.0}
	scenery.command.connect(func(operation,value):
		if operation=="adjust":
			state[value.key]=value.value; events.append([value.key,value.value]); adjusted_modes.append(value.mode)
		elif operation=="preview_yaw": previews.append(value.value)
		elif operation=="select": state.background=value.id)
	root.add_child(scenery); scenery.open("global"); scenery.view="adjust"; scenery.refresh()
	var nudges: Array = scenery.choices.targets.keys().filter(func(id): return scenery.choices.targets[id].kind == "nudge")
	tap(scenery, nudges[0])
	check(state.background_yaw == 359, "Minus one degree wraps from zero to 359")
	tap(scenery, nudges[1])
	check(state.background_yaw == 0, "Plus one degree wraps from 359 to zero")
	var before := events.size()
	var rail: Dictionary = scenery.choices.sliders[target(scenery, "background_yaw", null, "slider")]
	point = rail.node.to_global(Vector3(rail.left, 0, 1))
	scenery.press_pointer("left_hand", point, -scenery.global_basis.z, true)
	point = rail.node.to_global(Vector3(rail.left + rail.width * 137.0 / 359.0, 0, 1))
	scenery.update_pointer("left_hand", point, -scenery.global_basis.z, true)
	scenery.release_pointer("right_hand", point, -scenery.global_basis.z, true)
	check(previews.size() == 2 and previews[0] == 0 and previews[1] == 137, "Dragging previews the touched degrees: %s" % str(previews))
	check(rail.label.text == "137°", "Dragging shows the current angle: " + rail.label.text)
	check(events.size() == before, "Another hand cannot commit the direction")
	scenery.release_pointer("left_hand", point, -scenery.global_basis.z, true)
	check(state.background_yaw == 137 and events.size() == before + 1, "Owning release commits the preview once")
	scenery.press_pointer("left_hand", point, -scenery.global_basis.z, true)
	scenery.open("image")
	scenery.release_pointer("left_hand", point, -scenery.global_basis.z, true)
	check(adjusted_modes.back() == "global" and events.size() == before + 2 and scenery.mode == "image", "Switching modes finishes the drag in its original scope")
	scenery.open("global")
	var card: int=scenery._cards.find_custom(func(item): return item.id=="dark")
	point=origin(scenery,scenery.CARD+card)
	scenery.press_pointer("left_hand",point,-scenery.global_basis.z,true)
	scenery.update_pointer("left_hand",Vector3.ZERO,Vector3.ZERO,false)
	scenery.release_pointer("left_hand",point,-scenery.global_basis.z,true)
	check(state.background=="belfast","Tracking loss cancels pending scene selection")
	scenery.free(); catalog.free()
	menu._activate(Library.TAB_BASE + Library.DISPLAY_TAB)
	check(not is_instance_valid(menu._settings_scroll_hint), "Collapsed Display groups fit without scrolling")
	var interface_index: int = menu.rows.find_custom(func(row): return row.get("display_settings_group") == "interface")
	tap(menu, Library.ROW_BASE + menu._row_slot(interface_index))
	var render_index: int = menu.rows.find_custom(func(row): return row.get("display_settings_group") == "rendering")
	tap(menu, Library.ROW_BASE + menu._row_slot(render_index))
	menu._set_scroll(0.0)
	check(is_instance_valid(menu._settings_scroll_hint) and menu._settings_scroll_hint.visible,
		"Expanding Display groups shows a downward cue when the page overflows")
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
	check(state.watch_color == "violet" and menu._settings_scroll_hint.visible, "Top watch swatch remains operable while the page shows its scroll cue")
	menu._set_scroll(0)
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
	check(menu._display_settings_expanded.is_empty(), "Leaving Display resets group expansion")
	check(menu._max_scroll() == 0 and not is_instance_valid(menu._settings_scroll_hint), "Short settings pages have no scrolling cue")
	menu._activate(Library.TAB_BASE + Library.VIDEO_TAB)
	menu._set_scroll(menu._max_scroll())
	tap(menu, video_group_target(menu, "alpha"))
	menu.dismiss()
	check(menu.choices.opened.is_empty() and menu.choices.capture.is_empty(), "Closing settings clears popup and capture")
	menu.toggle()
	check(menu.rows.size() == 6 and menu._video_settings_expanded.is_empty(), "Reopening settings restores the collapsed groups and background preference")
	menu.queue_free()
	print("Choice field checks=%d failures=%d" % [checks, failures.size()])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)
