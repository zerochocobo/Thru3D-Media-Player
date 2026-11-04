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
	Chinese.quest = true; I18n.use("zh"); Chinese.configure(true)
	var platform := Fixture.Platform.new()
	platform.browser.merge({"tab_id": 10, "navigation": 3, "focused_window": 1, "editing": true, "custom_keyboard": true, "keyboard_epoch": 1}, true)
	var menu := Menu.new(); root.add_child(menu); menu.attach_platform(platform); menu.toggle()
	menu._activate(Menu.NAV_BASE + Menu.Section.WEB)
	var browser: RefCounted = menu.web_browser
	browser.open("https://example.test/input"); browser.next_poll = 0; browser.tick()
	await process_frame
	check(platform.browser_commands.any(func(item): return item.action == "keyboard_mode" and item.enabled), "Enable mode reaches existing native command interface")
	check(Chinese.active() and Chinese.popup.owner_id == "browser", "Focused webpage opens one app keyboard")
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
	check(Chinese.active() and not Chinese.popup.english, "A new focus lease can reopen Chinese input")
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
	check(not Chinese.active() and platform.browser_commands.back().action == "keyboard_mode" and not platform.browser_commands.back().enabled, "Leaving Simplified Chinese restores native system mode")
	Chinese.configure(false); browser.close(); menu.queue_free()
	if is_instance_valid(Chinese.popup): Chinese.popup.queue_free()
	await process_frame
	platform.free()
	print("Chinese browser input checks=%d failures=%d" % [checks, failures.size()])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)
