extends SceneTree
const Menu := preload("res://scripts/library_menu.gd")
const Chinese := preload("res://scripts/chinese_input.gd")
const I18n := preload("res://scripts/i18n.gd")
var checks := 0
var failures: Array[String] = []

class Platform extends "res://tests/account_platform_fixture.gd":
	var saves: Array = []
	func media_smb_save(json: String) -> int:
		saves.append(JSON.parse_string(json)); return saves.size()

func _initialize() -> void: run.call_deferred()
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message); push_error(message)
func key(code: Key, character: int = 0) -> void:
	var event := InputEventKey.new()
	event.keycode = code; event.unicode = character; event.pressed = true; root.push_input(event)
	event = event.duplicate(); event.pressed = false; root.push_input(event)
func type_text(value: String) -> void:
	for index in value.length(): key(KEY_NONE, value.unicode_at(index))
func has_key(menu: Node, id: int) -> bool:
	return menu._buttons.any(func(button): return button.target == id)
func run() -> void:
	for profile in [[true, "zh", false], [false, "zh", true], [true, "en", true], [true, "zh", true]]:
		Chinese.quest = profile[0]; I18n.use(profile[1]); Chinese.configure(profile[2])
		var platform := Platform.new()
		var menu := Menu.new(); root.add_child(menu); menu.platform = platform; menu.visible = true; menu.set_process(false)
		menu.section = Menu.Section.SMB
		menu._open_editor({"id": "saved", "host": "nas", "name": "客厅NAS", "user": "old-user", "has_password": true})
		await process_frame
		var editor: RefCounted = menu.system_text_input
		var switch_button: Dictionary = menu._buttons.filter(func(button): return button.target == Menu.EDITOR_SYSTEM_KEYBOARD)[0]
		check(switch_button.enabled and switch_button.rect.size.x >= 0.5, "System input has a large visible ray button in every profile")
		var overlap: Array = menu._buttons.filter(func(button): return button.node.get_parent() == menu and button.target != switch_button.target and switch_button.rect.intersects(button.rect))
		check(overlap.is_empty(), "System input button avoids adjacent targets: %s" % [overlap.map(func(button): return button.target)])
		var point: Vector3 = switch_button.node.global_position
		var normal: Vector3 = switch_button.node.global_basis.z.normalized()
		check(int(menu.ray_hit(point + normal, -normal).get("target", -1)) == Menu.EDITOR_SYSTEM_KEYBOARD, "Ray reaches the system input button")
		menu.press_pointer("right_hand", point + normal, -normal, true)
		menu.release_pointer("right_hand", point + normal, -normal, true)
		await process_frame
		check(editor.active("smb_user") and not editor.custom and not Chinese.active(), "SMB username switches to the standard system editor")
		check(editor.editor.has_focus() and editor.editor.virtual_keyboard_enabled and not editor.editor.secret, "Username requests an unrestricted visible system IME connection")
		check(editor.editor.text == "old-user" and not has_key(menu, Menu.KEY_BASE), "Switch retains the draft and removes duplicate letter keys")
		type_text("张三🙂"); await process_frame
		check(menu._editor.user == "张三🙂", "Real Unicode GUI events replace the selected SMB username")
		editor.editor.caret_column = 0; editor.editor.select(0, 1); type_text("李"); await process_frame
		check(menu._editor.user == "李三🙂" and platform.saves.is_empty(), "Chinese selection edits never submit a partial login")
		menu._activate(Menu.FIELD_BASE + 3); await process_frame
		check(editor.active("smb_password") and editor.editor.secret and editor.editor.virtual_keyboard_type == LineEdit.KEYBOARD_TYPE_PASSWORD and menu._editor.user == "李三🙂", "Switching fields commits username and requests a masked password editor")
		type_text("密码Ab9"); await process_frame
		check(menu._editor.password == "密码Ab9" and not menu.text_snapshot().contains("密码Ab9"), "Unicode password is kept out of all VR labels")
		menu._activate(Menu.FIELD_BASE); await process_frame
		check(not editor.editor.secret and editor.editor.text == "客厅NAS", "Non-secret field resets the reused editor's password mode")
		type_text("家庭共享")
		# Save in the same frame: finish must read the editor even before text_changed.
		menu._activate(Menu.SAVE); await process_frame
		check(platform.saves.size() == 1 and platform.saves[0].name == "家庭共享" and platform.saves[0].user == "李三🙂" and platform.saves[0].password == "密码Ab9", "Explicit save receives exact Unicode drafts once")
		check(not editor.active() and not editor.editor.has_focus() and not editor.editor.virtual_keyboard_enabled, "Save retires system input and deferred focus")
		menu._open_editor({"host": "nas", "user": "retained"}); menu._activate(Menu.EDITOR_SYSTEM_KEYBOARD)
		menu._activate(Menu.CANCEL); await process_frame
		check(menu._editor.is_empty() and not editor.active() and not editor.editor.has_focus(), "Cancel before deferred focus cannot reopen the keyboard")
		menu._open_editor({"host": "nas", "user": "retained"}); menu._activate(Menu.EDITOR_SYSTEM_KEYBOARD); await process_frame
		type_text("暂存用户")
		check(menu.navigate_back() and menu._editor.user == "暂存用户" and not editor.active(), "Back dismisses only the IME and keeps the latest username")
		menu._activate(Menu.FIELD_BASE + 2); await process_frame
		check(editor.editor.text == "暂存用户" and not editor.custom, "Field click reopens the chosen system backend with the retained draft")
		menu._activate(Menu.CANCEL)
		menu._open_editor({"id": "saved", "host": "nas", "user": "old-user", "has_password": true})
		menu._activate(Menu.EDITOR_SYSTEM_KEYBOARD); await process_frame
		type_text("新用户名"); menu._activate(Menu.SAVE)
		check(platform.saves.size() == 2 and platform.saves.back().user == "新用户名" and platform.saves.back().password.is_empty(), "Changing just the username preserves the existing saved password contract")
		menu.section = Menu.Section.DLNA; menu._open_editor({})
		menu._activate(Menu.EDITOR_SYSTEM_KEYBOARD); await process_frame
		check(editor.active("dlna_host") and not editor.custom and not has_key(menu, Menu.KEY_BASE), "Shared DLNA editor also offers system input")
		menu._activate(Menu.CANCEL)
		menu.section = Menu.Section.SMB; menu._open_editor({"host": "nas"})
		menu._editor.request_id = 99; menu._pending[99] = "smb_save"; menu.refresh()
		menu._activate(Menu.EDITOR_SYSTEM_KEYBOARD); await process_frame
		check(not menu._buttons.filter(func(button): return button.target == Menu.EDITOR_SYSTEM_KEYBOARD)[0].enabled and not menu._editor_system_keyboard, "Busy requests reject a backend switch")
		menu._pending.clear(); menu._activate(Menu.CANCEL)
		menu.free(); platform.free()
	# The shared optional Chinese popup has a direct escape to system IME too.
	Chinese.quest = true; I18n.use("zh"); Chinese.configure(true)
	var host := Node3D.new(); root.add_child(host)
	var input := preload("res://scripts/system_text_input.gd").new(host)
	input.begin("cloud_search", "已有内容", 128, Callable(), Callable()); await process_frame
	check(Chinese.active() and Chinese.popup.allow_system, "Built-in app keyboard exposes the system input action")
	var stale: Callable = Chinese.popup.dispatch
	input.editor.caret_column = 2
	Chinese.popup.ime.composing = "zhang"
	Chinese.popup._activate(Chinese.Keyboard.SYSTEM_KEYBOARD); await process_frame
	check(not Chinese.active() and input.active() and input.editor.has_focus() and input.editor.text == "已有内容" and input.editor.caret_column == 2, "Popup switch preserves committed text and caret without saving unfinished Pinyin")
	check(not stale.call("text", "过期"), "Retired popup cannot type after switching backend")
	type_text("中文"); await process_frame
	check(input.editor.text == "已有中文内容", "System editor continues from the same Chinese caret")
	input.cancel(); host.free(); Chinese.configure(false)
	if is_instance_valid(Chinese.popup): Chinese.popup.free()
	print("SMB system input checks=%d failures=%d" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
