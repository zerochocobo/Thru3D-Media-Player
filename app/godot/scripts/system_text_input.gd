extends RefCounted
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

func _init(owner: Node) -> void: host = owner

func active(tag: String = "") -> bool:
	return not context.is_empty() and (tag.is_empty() or context == tag)

static func clean(value: String, limit: int) -> String:
	return value.replace("\r", " ").replace("\n", " ").strip_escapes().left(limit)

func begin(tag: String, value: String, limit: int, on_change: Callable, on_submit: Callable, on_cancel: Callable = Callable()) -> void:
	cancel()
	if not is_instance_valid(editor):
		editor = LineEdit.new()
		editor.name = "SystemSearchEditor"
		# Keep the native input connection visible/focusable without drawing a 2D
		# field over the XR view. The ray menu mirrors committed draft changes.
		editor.modulate.a = 0.0
		editor.mouse_filter = Control.MOUSE_FILTER_IGNORE
		editor.virtual_keyboard_type = LineEdit.KEYBOARD_TYPE_DEFAULT
		editor.virtual_keyboard_show_on_focus = true
		editor.text_changed.connect(_changed)
		editor.text_submitted.connect(_submitted)
		editor.gui_input.connect(_gui_input)
		host.add_child(editor)
	context = tag; changed = on_change; submitted = on_submit; cancelled = on_cancel
	editor.focus_mode = Control.FOCUS_ALL
	editor.virtual_keyboard_enabled = true
	editor.show()
	editor.max_length = clampi(limit, 1, 200)
	editor.text = clean(value, editor.max_length)
	editor.caret_column = editor.text.length()
	editor.size = Vector2(640, 56)
	editor.position = (host.get_viewport().get_visible_rect().size - editor.size) * 0.5
	generation += 1
	_focus.call_deferred(generation)

func _focus(id: int) -> void:
	if id != generation or not active() or not is_instance_valid(editor) or not host.is_inside_tree(): return
	editor.grab_focus()
	editor.edit()

func set_text(tag: String, value: String) -> void:
	if not active(tag): return
	editor.cancel_ime()
	editor.text = clean(value, editor.max_length)
	editor.caret_column = editor.text.length()
	_changed(editor.text)
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
	context = ""; generation += 1
	changed = Callable(); submitted = Callable(); cancelled = Callable()
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
