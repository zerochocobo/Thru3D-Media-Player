extends RefCounted
const ChineseInput := preload("res://scripts/chinese_input.gd")
const CUSTOM_CONTEXTS := ["cloud_search", "media_server_search", "web_library_search", "web_library_title", "subtitle_filter",
	"voice-name", "background_name", "file_rename", "playlist_name", "smb_name", "smb_user", "account_name", "account_username", "archive_password"]
const OPENXR_CUSTOM_CONTEXTS := ["smb_user", "file_rename", "playlist_name"]
const LATIN_CONTEXTS := ["smb_user", "account_username", "archive_password"]
## A standard engine editor supplies Unicode, selection and IME composition.
## Android's engine bridge opens the installed system keyboard; OpenXR has no
## portable keyboard API. The 3D menu displays the draft, not another key layout.
var host: Node
var editor: LineEdit
var context := ""
var generation := 0
var changed: Callable
var submitted: Callable
var cancelled: Callable
var custom := false
var current: Callable

static func uses_custom(tag: String) -> bool:
	if not ChineseInput.enabled(): return false
	return tag in (OPENXR_CUSTOM_CONTEXTS if ChineseInput.is_generic_openxr() else CUSTOM_CONTEXTS)

func keyboard_id() -> String: return "text:" + str(get_instance_id())

func _init(owner: Node) -> void: host = owner

func active(tag: String = "") -> bool:
	return not context.is_empty() and (tag.is_empty() or context == tag)

static func clean(value: String, limit: int) -> String:
	return value.replace("\r", " ").replace("\n", " ").strip_escapes().left(limit)

func begin(tag: String, value: String, limit: int, on_change: Callable, on_submit: Callable, on_cancel: Callable = Callable(), is_current: Callable = Callable(), force_system: bool = false, secret: bool = false) -> void:
	cancel()
	if not is_instance_valid(editor):
		editor = LineEdit.new()
		editor.name = "SystemSearchEditor"
		# Keep the native input connection visible/focusable without drawing a 2D
		# field over the XR view. The ray menu mirrors committed draft changes.
		editor.modulate.a = 0.0
		editor.mouse_filter = Control.MOUSE_FILTER_IGNORE
		editor.virtual_keyboard_show_on_focus = true
		editor.text_changed.connect(_changed)
		editor.text_submitted.connect(_submitted)
		editor.gui_input.connect(_gui_input)
		host.add_child(editor)
	context = tag; changed = on_change; submitted = on_submit; cancelled = on_cancel
	current = is_current
	custom = uses_custom(tag) and not force_system
	editor.secret = secret
	editor.virtual_keyboard_type = LineEdit.KEYBOARD_TYPE_PASSWORD if secret else LineEdit.KEYBOARD_TYPE_DEFAULT
	editor.focus_mode = Control.FOCUS_ALL
	editor.virtual_keyboard_enabled = not custom
	editor.virtual_keyboard_show_on_focus = not custom
	editor.show()
	editor.max_length = clampi(limit, 1, 4096)
	editor.text = clean(value, editor.max_length)
	editor.caret_column = editor.text.length()
	editor.size = Vector2(640, 56)
	editor.position = (host.get_viewport().get_visible_rect().size - editor.size) * 0.5
	generation += 1
	_focus.call_deferred(generation)

func _focus(id: int) -> void:
	if id != generation or not active() or not is_instance_valid(editor) or not host.is_inside_tree(): return
	if current.is_valid() and not current.call(): cancel(); return
	if custom:
		# The ray popup owns keys; retain the standard editor's caret/selection model.
		if not _custom_alive(id): return
		var start_latin := context in LATIN_CONTEXTS and not (context == "smb_user" and ChineseInput.is_generic_openxr())
		ChineseInput.open(host, keyboard_id(),
			func(operation, value): return _custom_action(operation, value) if _custom_alive(id) else false,
			func(): return _custom_alive(id),
			func(): return ("•".repeat(editor.text.length()) if editor.secret else editor.text).insert(editor.caret_column, "│"), start_latin, true)
		return
	editor.grab_focus()
	editor.edit()

func use_system_keyboard() -> bool:
	if not active() or not is_instance_valid(editor): return false
	if current.is_valid() and not current.call(): cancel(); return false
	ChineseInput.close(keyboard_id())
	custom = false
	editor.apply_ime()
	editor.release_focus()
	editor.virtual_keyboard_enabled = true
	editor.virtual_keyboard_show_on_focus = true
	generation += 1
	_focus.call_deferred(generation)
	return true

func _custom_alive(id: int) -> bool:
	if id != generation or not active() or not custom: return false
	if not is_instance_valid(host) or not host.is_inside_tree() or not uses_custom(context) or (current.is_valid() and not current.call()):
		cancel(); return false
	return true

func set_text(tag: String, value: String) -> void:
	if not active(tag): return
	editor.cancel_ime()
	editor.text = clean(value, editor.max_length)
	editor.caret_column = editor.text.length()
	_changed(editor.text)
	if custom:
		if ChineseInput.active() and ChineseInput.popup.owner_id == keyboard_id(): ChineseInput.popup.ime.clear(); ChineseInput.popup.refresh()
		return
	# Explicit paste/clear must also replace the Android input connection's text.
	# Reopening on every edit would break the IME's composing/candidate state.
	editor.release_focus()
	generation += 1
	_focus.call_deferred(generation)

func finish(tag: String, fallback: String) -> String:
	if not active(tag): return fallback
	editor.apply_ime()
	var value := clean(editor.text, editor.max_length)
	_end()
	return value

func cancel(tag: String = "", notify: bool = false) -> void:
	if not active(tag): return
	var callback := cancelled
	var value := ""
	if notify and is_instance_valid(editor):
		editor.cancel_ime()
		value = clean(editor.text, editor.max_length)
	_end()
	if notify and callback.is_valid(): callback.call(value)

func _end() -> void:
	ChineseInput.close(keyboard_id())
	context = ""; generation += 1
	custom = false
	changed = Callable(); submitted = Callable(); cancelled = Callable()
	current = Callable()
	if is_instance_valid(editor):
		if editor.is_inside_tree():
			editor.cancel_ime()
			editor.release_focus()
		# Alpha alone leaves this editor in focus navigation after the session ends.
		editor.virtual_keyboard_enabled = false
		editor.focus_mode = Control.FOCUS_NONE
		editor.hide()
		editor.text = ""
	if DisplayServer.has_feature(DisplayServer.FEATURE_VIRTUAL_KEYBOARD): DisplayServer.virtual_keyboard_hide()

func _changed(value: String) -> void:
	if active() and value == editor.text and changed.is_valid(): changed.call(clean(value, editor.max_length))

func _submitted(_value: String) -> void:
	if not active(): return
	var callback := submitted
	var value := finish(context, editor.text)
	if callback.is_valid(): callback.call(value)

func _gui_input(event: InputEvent) -> void:
	if not active() or not event.is_action_pressed("ui_cancel"): return
	if editor.has_ime_text(): return # The first Escape belongs to composition.
	editor.accept_event()
	cancel("", true)

func _custom_action(operation: String, value: String) -> bool:
	if not active() or not custom: return false
	match operation:
		"close": cancel("", true); return true
		"system_keyboard": return use_system_keyboard()
		"enter": _submitted(editor.text); return true
		"text", "backspace":
			var start := editor.get_selection_from_column() if editor.has_selection() else editor.caret_column
			var end := editor.get_selection_to_column() if editor.has_selection() else editor.caret_column
			if operation == "text" and editor.text.length() - (end - start) + value.length() > editor.max_length: return false
			if operation == "backspace" and start == end: start = maxi(0, start - 1)
			var replacement := clean(value, editor.max_length) if operation == "text" else ""
			editor.text = editor.text.left(start) + replacement + editor.text.substr(end)
			editor.deselect(); editor.caret_column = start + replacement.length()
			_changed(editor.text)
		"left", "right":
			editor.caret_column = clampi(editor.caret_column + (-1 if operation == "left" else 1), 0, editor.text.length())
			editor.deselect()
	return true
