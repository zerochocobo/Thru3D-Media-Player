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
	check(not value_button.node is MeshInstance3D and value_button.node.get_child_count() == 1, "Resting choice value uses one label and no dropdown surface")
	var point := origin(menu, open_id)
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
	check(menu.rows.size() == 11 and menu.rows[0].choices.size() == 2 and menu.rows[1].compact
		and menu.rows.any(func(row): return row.get("key", "") == "subtitle_direction"), "Video groups compact playback choices and subtitle controls")
	check(menu.rows[2].key == "alpha_profile" and menu.rows[2].compact and menu.rows[2].value == "320x320"
		and menu.rows[2].choices.map(func(o): return o.value) == ["256x256", "320x320", "384x384", "512x512"]
		and str(menu.rows[2].get("hint", "")).is_empty() and not str(menu.rows[2].info).is_empty()
		and menu.rows[2].choices.all(func(o): return o.hint == menu.rows[2].info),
		"Alpha model size sits above the frame rate: four square sizes, 320 by default, larger slower and smaller rougher")
	state.alpha_cold = ["512x512"]; state.alpha_warming = ["384x384"]; menu.refresh()
	check(menu.rows[2].choices[3].get("hint", "") == "First use prepares the model, about 1 minute" and menu.rows[2].choices[2].get("hint", "") == "Preparing the model"
		and menu.rows[2].choices[1].hint == menu.rows[2].info, "A cold or compiling size says so on its own option; ready ones keep the trade-off tooltip")
	tap(menu, target(menu, "alpha_profile", "512x512"))
	check(events.back() == ["alpha_profile", "512x512"], "Choosing a size reports it")
	state.erase("alpha_cold"); state.erase("alpha_warming"); state.alpha_profile = "320x320"; menu.refresh()
	check(menu.rows[3].key == "alpha_fps" and menu.rows[3].slider and menu.rows[3].span == Vector3(10, 40, 1) and menu.rows[3].value == 30 and not str(menu.rows[3].hint).is_empty(), "Alpha frame rate is a 10-40 FPS slider defaulting to 30 with a passthrough hint")
	check(menu.rows[4].key == "alpha_feather" and menu.rows[4].value == 100 and menu.rows[5].key == "alpha_shrink" and menu.rows[5].value == 40
		and menu.rows[5].span == Vector3(0, 100, 1), "Alpha feather and edge shrink follow the frame rate, as in the player settings")
	tap(menu, target(menu, "seek_mode", "exact"))
	check(state.seek_mode == "exact" and events.back() == ["seek_mode", "exact"], "Radio selection chooses precision directly")
	var selected := 0
	for button in menu._buttons:
		if menu.choices.targets.has(button.target) and menu.choices.targets[button.target].get("key") == "seek_mode" and button.base_color == menu.SELECTED: selected += 1
	check(selected == 1, "Exactly one radio is visibly selected")
	menu._activate(Library.TAB_BASE + Library.BACKGROUND_TAB)
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
	menu.dismiss()
	check(menu.choices.opened.is_empty() and menu.choices.capture.is_empty(), "Closing settings clears popup and capture")
	menu.free()
	print("Choice field checks=%d failures=%d" % [checks, failures.size()])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)
