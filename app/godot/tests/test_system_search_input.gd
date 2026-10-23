extends SceneTree
const Menu := preload("res://scripts/library_menu.gd")
const Cloud := preload("res://tests/test_cloud_search.gd")
const Search := preload("res://scripts/cloud_search.gd")
const Browser := preload("res://scripts/media_server_browser.gd")
const SystemInput := preload("res://scripts/system_text_input.gd")
var checks := 0
var failures: Array[String] = []

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok: failures.append(label)

func key(code: Key, unicode_value: int = 0) -> void:
	var event := InputEventKey.new()
	event.keycode = code; event.unicode = unicode_value; event.pressed = true
	root.push_input(event)
	event = event.duplicate(); event.pressed = false; root.push_input(event)

func type_text(value: String) -> void:
	for index in value.length(): key(KEY_NONE, value.unicode_at(index))

func _initialize() -> void: call_deferred("run")

func run() -> void:
	var platform := Cloud.Platform.new()
	var menu := Menu.new(); root.add_child(menu); menu.attach_platform(platform); menu.toggle()
	menu._activate(Menu.NAV_BASE + Menu.Section.CLOUD); platform.browse_reply(1)
	menu._choose(menu.rows[0]); platform.browse_reply(2)
	menu.cloud_search.open()
	await process_frame
	var input: RefCounted = menu.system_text_input
	check(input.active("cloud_search") and root.gui_get_focus_owner() == input.editor, "Ray search opens a focused standard engine text editor")
	check(input.editor.virtual_keyboard_enabled and input.editor.virtual_keyboard_type == LineEdit.KEYBOARD_TYPE_DEFAULT, "System keyboard uses unrestricted text input rather than ASCII or number input")
	var before := platform.requests.size()
	type_text("中文电影")
	await process_frame
	check(menu.cloud_search.query == "中文电影", "Actual Unicode GUI key events reach the search draft")
	check(platform.requests.size() == before, "Typing never submits partial/composing search requests")
	input.editor.caret_column = 0
	input.editor.select(0, 2)
	type_text("旅行")
	await process_frame
	check(menu.cloud_search.query == "旅行电影", "Chinese selection replacement uses the standard editor")
	key(KEY_BACKSPACE)
	await process_frame
	check(menu.cloud_search.query == "旅电影", "Backspace edits a Chinese character at the caret")
	key(KEY_ENTER)
	await process_frame
	check(platform.requests.size() == before + 1 and platform.requests.back().query == "旅电影", "Keyboard submit sends the completed Chinese query once")
	check(not input.active() and root.gui_get_focus_owner() != input.editor, "Submitting releases text focus and the keyboard")
	check(not input.editor.visible and input.editor.focus_mode == Control.FOCUS_NONE and not input.editor.virtual_keyboard_enabled, "Inactive transparent editor cannot reopen the system keyboard")
	key(KEY_TAB)
	check(root.gui_get_focus_owner() != input.editor, "Focus navigation cannot revive a completed input session")
	platform.search_reply(platform.requests.size(), [platform.result("中文:0")])
	menu._activate(Search.INPUT)
	await process_frame
	key(KEY_ESCAPE)
	check(not input.active() and menu.cloud_search.active and menu.cloud_search.query == "旅电影", "Escape closes text input without submitting or losing the search")
	menu._activate(Search.INPUT)
	await process_frame
	check(input.editor.text == "旅电影", "Reopening preserves the existing query")
	type_text("新")
	check(menu.navigate_back() and menu.cloud_search.active and menu.cloud_search.editing and not input.active(), "First Back closes system input while keeping the search draft")
	check(menu.cloud_search.query == "旅电影新", "Back preserves the latest draft even before deferred text_changed is delivered")
	check(menu.navigate_back() and not menu.cloud_search.active, "Second Back returns to the directory")
	menu.cloud_search.open(); menu.dismiss()
	await process_frame
	check(not input.active() and root.gui_get_focus_owner() != input.editor, "Deferred focus cannot reopen a dismissed search")
	menu.toggle(); menu.cloud_search.open()
	input.set_text("cloud_search", "中".repeat(130))
	check(menu.cloud_search.query.length() == 128, "Cloud query limit preserves 128 Unicode characters")
	input.set_text("cloud_search", "旅行\n影片\r测试\t")
	check(menu.cloud_search.query == "旅行 影片 测试", "Pasted line breaks and control characters cannot create multiline queries")
	menu.cloud_search.close()
	menu.section = Menu.Section.MEDIA_SERVER
	var browser: RefCounted = menu.server_browser
	browser.server = {"id": "fixture"}; browser.view = "scenes"
	browser.action(Browser.ACTION + 2)
	await process_frame
	check(input.active("media_server_search") and input.editor.max_length == 200, "Media server search shares the system editor with its own bound")
	type_text("中文剧集")
	await process_frame
	check(browser.text == "中文剧集", "Media server search accepts real Chinese GUI input")
	check(not menu._buttons.any(func(button): return button.target >= Browser.KEY and button.target < Browser.KEY + 40), "Media server input has no custom letter keyboard")
	# Cancel before submission: the cloud-only fixture must never receive a server request.
	browser.action(Browser.ACTION + 25)
	check(not input.active() and browser.keyboard.is_empty(), "Media server cancel closes the input session")
	var first: int = input.generation
	input.begin("stale", "old", 128, Callable(), Callable())
	input.cancel(); input._focus(first)
	check(not input.active() and not input.editor.has_focus(), "Obsolete deferred focus cannot steal input")
	input.begin("before_smb", "draft", 128, Callable(), Callable())
	menu.section = Menu.Section.SMB
	menu._open_editor({})
	await process_frame
	check(not input.active() and not input.editor.has_focus(), "Opening the built-in server keyboard cancels pending system input")
	menu._editor = {}
	check(SystemInput.clean("中文🙂日本語", 4) == "中文🙂日", "Sanitization truncates by Unicode character without splitting a supplementary character")
	input.begin("teardown", "关闭测试", 128, Callable(), Callable())
	await process_frame
	menu.queue_free(); platform.free()
	await process_frame
	check(not input.active() and not is_instance_valid(input.editor), "Freeing an active menu releases its editor without an out-of-tree focus call")
	print("system search input checks=%d failures=%d" % [checks, failures.size()])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)
