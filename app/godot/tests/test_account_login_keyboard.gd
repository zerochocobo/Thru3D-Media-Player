extends SceneTree

## The account login's in-app keyboard (QIYU 115, Q3FSFFM6): a newer editor connection on the same
## page replaces the popup without blurring it, and only the popup's own editor accepts its commands.
const Menu := preload("res://scripts/library_menu.gd")
const AccountFixture := preload("res://tests/account_platform_fixture.gd")
const LoginSurface := preload("res://scripts/account_login_surface.gd")
const Keys := preload("res://scripts/chinese_input.gd")
const Qiyu := preload("res://scripts/qiyu_controller.gd")
var checks := 0
var failures: Array[String] = []

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok: failures.append(label)

func _initialize() -> void: call_deferred("run")

func closes(platform: AccountFixture, since: int) -> int:
	return platform.web_calls.slice(since).filter(func(call): return call[1] == "keyboard_close").size()

func run() -> void:
	var platform := AccountFixture.new()
	var menu := Menu.new()
	root.add_child(menu)
	menu.attach_platform(platform)
	menu.visible = true
	menu.section = Menu.Section.CLOUD
	var panel: RefCounted = menu.account_panel
	var saved := [Keys.android, Keys.quest, Keys.pico, Qiyu.runtime, Keys.selected, Keys.browser_keyboard]
	Keys.android = true; Keys.quest = false; Keys.pico = false; Qiyu.runtime = true
	Keys.configure(true)
	panel.start("cloud", "115_open")
	var state: Dictionary = platform.account_sessions[panel.session]
	state.state = "web"
	state.web = {"renderer": "gecko", "surface_id": "fixture-A", "editing": true, "keyboard_epoch": 1, "keyboard_latin": true}
	panel.poll()
	var surface := LoginSurface.new()
	surface._keyboard_mode = 1 # Headless: no JNI; the Android mode is already applied.
	surface._sync_keyboard(menu, panel, panel.data.web)
	check(Keys.active() and Keys.popup.owner_id == "account_web", "The first editor opens the keyboard")
	var first: Callable = Keys.popup.dispatch
	check(first.call("text", "a") and platform.web_calls.back()[1] == "text", "The first editor takes text")

	var before: int = platform.web_calls.size()
	surface._sync_keyboard(menu, panel, panel.data.web)
	check(platform.web_calls.size() == before, "The same editor keeps its keyboard")
	for epoch in range(2, 5):
		state.web.keyboard_epoch = epoch
		panel.poll()
		before = platform.web_calls.size()
		surface._sync_keyboard(menu, panel, panel.data.web)
		check(closes(platform, before) == 0, "Editor %d replaces the keyboard without blurring the page" % epoch)
		check(Keys.active() and Keys.popup.owner_id == "account_web", "Editor %d keeps a keyboard open" % epoch)
	check(not first.call("text", "x") and not first.call("close", ""), "The replaced keyboard's commands are refused")
	var current: Callable = Keys.popup.dispatch
	before = platform.web_calls.size()
	check(current.call("text", "b") and platform.web_calls.back()[1] == "text", "The current editor takes text")

	# The app keyboard preference does not decide web pages on QIYU: the login popup stays.
	before = platform.web_calls.size()
	Keys.configure(false)
	check(Keys.active() and closes(platform, before) == 0, "Turning the app preference off keeps the QIYU login keyboard")
	Keys.configure(true)

	# Closing it yourself still blurs the current field.
	before = platform.web_calls.size()
	Keys.popup.close()
	check(closes(platform, before) == 1, "A user close reaches the current editor")
	surface._sync_keyboard(menu, panel, panel.data.web)
	check(Keys.active(), "The same editor can bring the keyboard back")

	state.web.editing = false
	panel.poll()
	before = platform.web_calls.size()
	surface._sync_keyboard(menu, panel, panel.data.web)
	check(not Keys.active() and closes(platform, before) == 0, "A page blur closes the keyboard quietly")

	panel.close()
	panel.start("cloud", "115_open")
	state = platform.account_sessions[panel.session]
	state.state = "web"
	state.web = {"renderer": "gecko", "surface_id": "fixture-B", "editing": true, "keyboard_epoch": 1}
	panel.poll()
	surface._sync_keyboard(menu, panel, panel.data.web)
	check(Keys.active() and not current.call("text", "x"), "A new login page refuses the previous page's keyboard")

	# Quest keeps its old rule: turning the preference off closes every app keyboard.
	Keys.quest = true; Qiyu.runtime = false
	Keys.configure(false)
	check(not Keys.active(), "On Quest the preference still closes the keyboard")

	Keys.close("account_web")
	Keys.android = saved[0]; Keys.quest = saved[1]; Keys.pico = saved[2]; Qiyu.runtime = saved[3]
	Keys.selected = saved[4]; Keys.browser_keyboard = saved[5]
	if is_instance_valid(Keys.popup): Keys.popup.queue_free()
	surface.free(); menu.free(); platform.free()
	await process_frame
	print("Account login keyboard: %d checks, %d failures" % [checks, failures.size()])
	for failure in failures: print("FAIL: " + failure)
	quit(1 if failures else 0)
