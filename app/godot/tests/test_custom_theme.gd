extends SceneTree
const Palette := preload("res://scripts/ui_theme.gd")
const Library := preload("res://scripts/library_menu.gd")
const Editor := preload("res://scripts/theme_editor.gd")
const Main := preload("res://scripts/main.gd")
var failures: Array[String] = []
var checks := 0
var library: Node3D
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)
func _initialize() -> void: _run.call_deferred()
func frames() -> void:
	for index in 3: await process_frame
func button(target: int) -> Dictionary:
	for item in library._buttons:
		if item.target == target: return item
	return {}
func choice(key: String, value: Variant) -> int:
	for target in library.choices.targets:
		var item: Dictionary = library.choices.targets[target]
		if item.get("key") == key and item.get("value") == value: return target
	return -1
func point(target: int, local: Vector2 = Vector2.ZERO) -> Vector3:
	return button(target).node.to_global(Vector3(local.x, local.y, 0.4))
func tap(target: int) -> void:
	check(not button(target).is_empty(), "Reachable target: %d" % target)
	if button(target).is_empty(): return
	var start := point(target); var direction: Vector3 = -button(target).node.global_basis.z
	library.press_pointer("right_hand", start, direction, true)
	library.release_pointer("right_hand", start, direction, true)
	await frames()

func _run() -> void:
	Palette.use("default"); Palette.set_custom({})
	var path := ProjectSettings.globalize_path("res://../../build/output/ui-themes/custom-theme/settings.cfg")
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var app := Main.new(); app.settings_path = path
	library = Library.new(); library.settings_provider = func(): return {Palette.KEY: Palette.current}
	library.setting_changed.connect(app._on_setting_changed)
	root.add_child(library); library.toggle(); library.section = Library.Section.SETTINGS; library.tab = Library.DISPLAY_TAB; library.refresh()
	check(library.rows[0].key == Palette.KEY and library.rows[1].key == "watch_color", "Theme and watch controls stay at top of Display")
	var custom := choice(Palette.KEY, Palette.CUSTOM)
	var edit := choice(Palette.EDIT_CUSTOM, true)
	check(custom >= 0 and edit >= 0 and custom != edit, "Quick custom swatch and editor are separate targets")
	check(library._tips[custom] == library.I18n.t("Custom theme"), "Custom quick swatch tooltip")
	# The seven circles and edit button cannot overlap.
	var targets: Array = library._buttons.filter(func(item): return library.choices.targets.get(item.target, {}).get("key") in [Palette.KEY, Palette.EDIT_CUSTOM])
	for index in targets.size() - 1:
		var left: Dictionary = targets[index]; var right: Dictionary = targets[index + 1]
		check(left.node.global_position.x + left.rect.size.x / 2 <= right.node.global_position.x - right.rect.size.x / 2, "Theme actions have distinct hit areas")
	await tap(custom)
	check(Palette.current == Palette.CUSTOM and Palette.original() and not library.theme_editor.opened, "Quick swatch applies classic custom without opening editor")
	await tap(choice(Palette.EDIT_CUSTOM, true))
	check(library.theme_editor.opened and library._side.visible == false, "Editor replaces library controls")
	var original := Palette.palette(Palette.current)
	var saved_before := FileAccess.get_file_as_bytes(path)
	var field_id: int = library.theme_editor.field.get_instance_id()
	var start := point(Editor.FIELD, Vector2(-0.12, -0.10))
	var direction: Vector3 = -library.global_basis.z
	library.press_pointer("right_hand", start, direction, true)
	library.update_pointer("right_hand", point(Editor.FIELD, Vector2(0.18, 0.11)), direction, true)
	check(library.has_pointer_capture() and not library.theme_editor.draft.is_empty(), "Ray captures and drags the color area")
	check(library.theme_editor.field.get_instance_id() == field_id, "Preview changes in place without rebuilding captured controls")
	check(Palette.palette(Palette.current) == original and FileAccess.get_file_as_bytes(path) == saved_before, "Draft preview does not alter live palette or stored settings")
	library.release_pointer("left_hand", start, direction, true)
	check(library.has_pointer_capture(), "Other hand cannot release color drag")
	library.cancel_pointer("left_hand")
	check(library.has_pointer_capture(), "Other hand cannot cancel color drag")
	library.cancel_pointer("right_hand")
	check(not library.has_pointer_capture() and library.theme_editor.draft.is_empty(), "Owner cancellation restores pre-drag draft")
	library.press_pointer("right_hand", start, direction, true)
	library.update_pointer("right_hand", start, direction, false)
	check(not library.has_pointer_capture() and library.theme_editor.draft.is_empty(), "Tracking loss restores drag without committing")
	# Cancel and back discard all edits, not just the most recent drag.
	await tap(Editor.HUE)
	check(not library.theme_editor.draft.is_empty(), "Hue tap modifies draft")
	await tap(Editor.CANCEL)
	check(not library.theme_editor.opened and FileAccess.get_file_as_bytes(path) == saved_before, "Cancel discards draft and keeps saved custom")
	await tap(choice(Palette.EDIT_CUSTOM, true)); await tap(Editor.HUE)
	library.navigate_back()
	check(not library.theme_editor.opened and FileAccess.get_file_as_bytes(path) == saved_before, "Back discards draft")
	await tap(choice(Palette.EDIT_CUSTOM, true)); await tap(Editor.HUE)
	await tap(Editor.TABS + 1); await tap(Editor.ACCENTS + 2)
	await tap(Editor.TABS + 2); await tap(Editor.TEXTS + 2)
	var expected: Dictionary = library.theme_editor.draft.duplicate(true)
	await tap(Editor.APPLY)
	check(not library.theme_editor.opened and Palette.current == Palette.CUSTOM and Palette.custom_data == expected, "Apply stores and activates the complete custom palette")
	var stored := ConfigFile.new()
	check(stored.load(path) == OK and stored.get_value("ui", Palette.CUSTOM_KEY) == expected, "Custom data saved by production Main handler")
	Palette.use("default"); Palette.set_custom({}); Palette.use(Palette.load_choice(stored))
	check(Palette.current == Palette.CUSTOM and Palette.custom_data == expected, "Startup restores custom data before applying selected ID")
	await frames()
	await tap(choice(Palette.KEY, "pearl")); await tap(choice(Palette.KEY, Palette.CUSTOM))
	check(Palette.custom_data == expected and not library.theme_editor.opened, "Quick switching preserves last custom and opens no dialog")
	await tap(choice(Palette.EDIT_CUSTOM, true)); await tap(Editor.RESET)
	check(library.theme_editor.draft.is_empty() and Palette.custom_data == expected, "Reset remains a draft until Apply")
	await tap(Editor.APPLY)
	check(Palette.current == Palette.CUSTOM and Palette.custom_data.is_empty() and Palette.palette(Palette.CUSTOM) == Palette.ORIGINAL, "Apply reset returns custom to exact original palette")
	await tap(choice(Palette.EDIT_CUSTOM, true)); await tap(Editor.HUE)
	library.dismiss(); library.toggle()
	check(not library.theme_editor.opened and Palette.custom_data.is_empty(), "Dismiss and reopen discard unsaved edits")
	stored.set_value("ui", Palette.CUSTOM_KEY, {"background": "broken", "accent": 6})
	Palette.use(Palette.load_choice(stored))
	check(Palette.palette(Palette.current) == Palette.ORIGINAL, "Corrupt custom settings safely fall back to original")
	library.free(); app.free(); Palette.use("default"); Palette.set_custom({}); await frames()
	for failure in failures: push_error(failure)
	print("Custom theme interactions: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
