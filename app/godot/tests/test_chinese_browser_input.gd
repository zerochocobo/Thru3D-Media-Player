extends SceneTree
const Chinese := preload("res://scripts/chinese_input.gd")
const I18n := preload("res://scripts/i18n.gd")
const Menu := preload("res://scripts/library_menu.gd")
const Fixture := preload("res://tests/test_web_browser_panel.gd")
var checks := 0
var failures: Array[String] = []
func _initialize() -> void: call_deferred("run")
func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok: failures.append(label)
func run() -> void:
	# Export features are injected here; no device or Android IME is required.
	for profile in [[true, true, false, "quest"], [true, false, true, "pico"], [true, false, false, "openxr"], [false, false, false, "desktop"]]:
		Chinese.android = profile[0]; Chinese.quest = profile[1]; Chinese.pico = profile[2]
		for language in ["zh", "zh_Hant", "en", "ja", "auto"]:
			for selected in [false, true]:
				I18n.use(language); Chinese.configure(selected)
				var quest_input: bool = profile[1] and selected and I18n.language == "zh"
				var openxr: bool = profile[3] == "openxr"
				check(Chinese.enabled() == (quest_input or (openxr and selected)), "App input policy: %s/%s/%s" % [profile[3], language, selected])
				check(Chinese.browser_enabled() == (quest_input or openxr), "Browser input policy: %s/%s/%s" % [profile[3], language, selected])
				Chinese.configure_browser("system")
				check(Chinese.browser_enabled() == quest_input, "System web choice is independent of the OpenXR app preference")
				Chinese.configure_browser("invalid")
				check(Chinese.browser_keyboard == "builtin", "Unknown setting safely defaults to built-in")
		var settings_menu := Menu.new(); root.add_child(settings_menu)
		settings_menu.section = Menu.Section.SETTINGS; settings_menu.tab = Menu.GENERAL_TAB; settings_menu.refresh()
		check(settings_menu.rows.any(func(row): return row.get("key", "") == "web_keyboard") == (profile[3] == "openxr"), "Web keyboard setting is restricted to generic Android/OpenXR")
		check(settings_menu.rows.any(func(row): return row.get("key", "") == "openxr_chinese_keyboard") == (profile[3] == "openxr"), "OpenXR app switch is restricted to the generic Android export")
		settings_menu.queue_free()
		await process_frame
	await check_saved_choice()
	await exercise_browser(true, "zh", true)
	await exercise_browser(false, "zh", false)
	await exercise_browser(false, "en", false)
	await exercise_browser(false, "ja", true)
	if is_instance_valid(Chinese.popup): Chinese.popup.queue_free()
	await process_frame
	print("Chinese browser input checks=%d failures=%d" % [checks, failures.size()])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)

func exercise_browser(quest: bool, language: String, selected: bool) -> void:
	Chinese.android = true; Chinese.quest = quest; Chinese.pico = false
	Chinese.configure_browser("builtin")
	I18n.use(language); Chinese.configure(selected)
	var latin := I18n.language != "zh"
	var platform := Fixture.Platform.new()
	platform.browser.merge({"tab_id": 10, "navigation": 3, "focused_window": 1, "editing": true, "custom_keyboard": true, "keyboard_epoch": 1}, true)
	var menu := Menu.new(); root.add_child(menu); menu.attach_platform(platform); menu.toggle()
	menu._activate(Menu.NAV_BASE + Menu.Section.WEB)
	var browser: RefCounted = menu.web_browser
	browser.open("https://example.test/input"); browser.next_poll = 0; browser.tick()
	await process_frame
	check(platform.browser_commands.any(func(item): return item.action == "keyboard_mode" and item.enabled), "Enable mode reaches existing native command interface")
	check(Chinese.active() and Chinese.popup.owner_id == "browser", "Focused webpage opens one app keyboard")
	check(Chinese.popup.english == latin and browser.keyboard_visible(1), "Initial layout and visible control match the actual popup")
	Chinese.popup._activate(Chinese.Keyboard.KEY)
	check(JSON.parse_string(platform.inputs.back()[1]).text == "1", "Phone number digit reaches the native editor")
	var old_action: Callable = Chinese.popup.dispatch
	Chinese.popup._send("text", "中文🙂")
	var request: Dictionary = JSON.parse_string(platform.inputs.back()[1])
	check(platform.inputs.back()[0] == "custom" and request.text == "中文🙂" and request.tab == 10 and request.window == 1 and request.navigation == 3 and request.epoch == 1, "Commit carries text and original complete editor identity")
	check(not Chinese.popup.preview.is_valid(), "Web input values and passwords are never mirrored into popup")
	platform.browser.keyboard_epoch = 2; platform.browser.keyboard_latin = true
	browser.next_poll = 0; browser.tick()
	check(Chinese.popup.english and Chinese.popup.ime.composing.is_empty(), "New password/URL field resets preedit and starts Latin")
	var count: int = platform.inputs.size()
	check(not old_action.call("text", "过期") and platform.inputs.size() == count, "Old same-page callback cannot send into replacement field")
	Chinese.popup._activate(9)
	check(not Chinese.active() and JSON.parse_string(platform.inputs.back()[1]).command == "close", "Closing popup notifies native editor")
	browser.next_poll = 0; browser.tick()
	check(not Chinese.active(), "Stale polled snapshot cannot reopen a manually closed keyboard")
	platform.browser.keyboard_epoch = 3; platform.browser.keyboard_latin = false
	browser.next_poll = 0; browser.tick()
	check(Chinese.active() and Chinese.popup.english == latin, "A new focus lease reopens the appropriate layout")
	old_action = Chinese.popup.dispatch
	platform.browser.custom_keyboard = false; platform.browser.editing = false; platform.browser.keyboard_epoch = 0
	browser.next_poll = 0; browser.tick()
	check(not Chinese.active() and not old_action.call("text", "旧页"), "Blur/navigation invalidates popup and its callbacks")
	platform.browser.custom_keyboard = true; platform.browser.editing = true; platform.browser.keyboard_epoch = 4
	browser.next_poll = 0; browser.tick()
	old_action = Chinese.popup.dispatch
	browser.action(browser.BASE + 3); await process_frame
	check(menu.system_text_input.active("web_browser") and not menu.system_text_input.custom and menu.system_text_input.editor.virtual_keyboard_enabled and not Chinese.active(), "Browser address bar opens only the original system keyboard")
	count = platform.inputs.size()
	check(not old_action.call("text", "过期") and platform.inputs.size() == count, "Address editing immediately revokes webpage input callbacks")
	platform.browser.keyboard_epoch = 5; browser.next_poll = 0; browser.tick()
	check(not Chinese.active(), "Delayed webpage focus cannot cover the browser address editor")
	menu.system_text_input.cancel("web_browser"); browser.next_poll = 0; browser.tick()
	check(not Chinese.active(), "Ending address editing does not reopen stale webpage focus")
	platform.browser.keyboard_epoch = 6; browser.next_poll = 0; browser.tick()
	check(Chinese.active() and Chinese.popup.owner_id == "browser", "New webpage field still opens the Chinese keyboard")
	I18n.use("en"); Chinese.configure(Chinese.selected); browser.tick()
	if quest:
		check(not Chinese.active() and platform.browser_commands.back().action == "keyboard_mode" and not platform.browser_commands.back().enabled, "Quest leaving Simplified Chinese restores native system mode")
	else:
		check(Chinese.active() and platform.browser_commands.back().enabled, "Generic OpenXR retains its visible fallback after language/configuration changes")
		Chinese.configure(false); browser.tick()
		check(Chinese.active(), "Turning Chinese preference off does not strand the browser focus lease")
		old_action = Chinese.popup.dispatch
		Chinese.configure_browser("system"); browser.tick()
		check(not Chinese.active() and not platform.browser_commands.back().enabled, "System choice closes the popup and disables native custom input")
		count = platform.inputs.size()
		check(not old_action.call("text", "stale") and platform.inputs.size() == count, "Switching backend rejects the old editing callback")
		platform.browser.custom_keyboard = false; platform.browser.keyboard_epoch = 0; platform.browser.keyboard_visible = true
		browser.next_poll = 0; browser.tick()
		check(browser.keyboard_visible(1) and not Chinese.active(), "System mode follows native visibility without opening an app popup")
		Chinese.configure_browser("builtin"); browser.tick()
		check(platform.browser_commands.back().enabled and not Chinese.active(), "Returning to built-in requests native custom mode before opening a popup")
		platform.browser.custom_keyboard = true; platform.browser.keyboard_epoch = 7
		browser.next_poll = 0; browser.tick()
		check(Chinese.active(), "Fresh native focus after returning to built-in opens the keyboard")
		browser.toggle_keyboard(1)
		check(not Chinese.active() and not browser.keyboard_visible(1) and platform.inputs.back()[0] == "close", "Generic OpenXR keyboard toggle closes the real popup")
	Chinese.configure(false); browser.close(); menu.queue_free()
	await process_frame
	platform.free()

func check_saved_choice() -> void:
	Chinese.android = true; Chinese.quest = false; Chinese.pico = false
	var main := preload("res://scripts/main.gd").new()
	var directory := ProjectSettings.globalize_path("res://../../build/output/qiyu-keyboard-choice-20261108")
	DirAccess.make_dir_recursive_absolute(directory)
	main.settings_path = directory.path_join("settings-%s.cfg" % Time.get_ticks_usec())
	var menu := Menu.new(); root.add_child(menu)
	menu.setting_changed.connect(main._on_setting_changed)
	for value in ["system", "builtin"]:
		menu._on_choice_changed("web_keyboard", value)
		var saved := ConfigFile.new()
		check(saved.load(main.settings_path) == OK and saved.get_value("ui", "web_keyboard", "missing") == value, "UI choice persists: " + value)
		Chinese.configure_browser("builtin" if value == "system" else "system")
		Chinese.configure_browser(str(saved.get_value("ui", "web_keyboard", "builtin")))
		check(Chinese.browser_enabled() == (value == "builtin"), "Saved selection restores the browser backend: " + value)
	menu._on_choice_changed("web_keyboard", "system")
	for enabled in [true, false]:
		menu._on_choice_changed("openxr_chinese_keyboard", enabled)
		var saved := ConfigFile.new()
		check(saved.load(main.settings_path) == OK and saved.get_value("ui", "openxr_chinese_keyboard") == enabled, "OpenXR app setting persists independently")
		check(Chinese.enabled() == enabled and not Chinese.browser_enabled() and saved.get_value("ui", "web_keyboard") == "system", "App toggle preserves the chosen system web keyboard")
		check(not saved.has_section_key("ui", "quest_chinese_keyboard"), "OpenXR does not write the Quest app preference")
	menu.queue_free(); main.free()
	await process_frame
