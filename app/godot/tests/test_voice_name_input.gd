extends SceneTree
const Library := preload("res://scripts/library_menu.gd")
const Player := preload("res://scripts/player_menu.gd")
var checks := 0
var failures: Array[String] = []
func check(value: bool, message: String) -> void:
	checks += 1
	if not value: failures.append(message); push_error(message)
func key(code: Key, unicode_value: int = 0) -> void:
	var event := InputEventKey.new(); event.keycode = code; event.unicode = unicode_value; event.pressed = true
	root.push_input(event); event = event.duplicate(); event.pressed = false; root.push_input(event)
func click(menu: Node3D, panel: RefCounted, operation: String) -> void:
	var ids: Array = panel.actions.keys().filter(func(id): return panel.actions[id].operation == operation)
	check(not ids.is_empty(), "Action exists: " + operation)
	if ids.is_empty(): return
	var button: Dictionary = menu._buttons.filter(func(b): return b.target == ids[0])[0]
	var ray: Vector3 = button.node.to_global(Vector3(0, 0, 1))
	check(menu.ray_hit(ray, -menu.global_basis.z).get("target", -1) == ids[0], "Ray reaches " + operation)
	menu.press_pointer("left_hand", ray, -menu.global_basis.z, true)
	menu.release_pointer("left_hand", ray, -menu.global_basis.z, true)
func _initialize() -> void: call_deferred("run")
func run() -> void:
	for global_manager in [true, false]:
		var state := {"source_uri": "global-voice-manager" if global_manager else "file:///fixture.mp4", "global_voice_manager": global_manager,
			"has_video": true, "narration_clone_supported": true, "narration_personal_voices": [],
			"narration_clone_state": {"state": "ready", "source_ready": true, "duration": 1200, "audio_id": 1, "ready_key": "a", "revision": 1,
				"candidates": [{"key": "a", "start": 10.0, "end": 16.0, "text": "中文字幕"}]}}
		var menu: Node3D = Library.new() if global_manager else Player.new()
		if global_manager: menu.settings_provider = func(): return {"voice_manager": state}
		else: menu.state_provider = func(): return state
		root.add_child(menu); menu.set_process(false); menu.visible = true; menu._state = state
		if not global_manager: menu.refresh(); menu._subtitle_open = true
		var panel: RefCounted = menu.voice_manager if global_manager else menu.clone_panel
		var commands: Array = []
		if global_manager: menu.setting_changed.connect(func(_k, v): commands.append(v))
		else: menu.setting_requested.connect(func(_k, v): commands.append(v))
		panel.open(false)
		if global_manager: panel.sample.active = true; panel.sample.page = "results"; menu.refresh()
		for submit_with_enter in [true, false]:
			click(menu, panel, "save_name")
			await process_frame
			var editor: LineEdit = panel.editor.editor
			check(panel.editor.active("voice-name") and root.gui_get_focus_owner() == editor and editor.virtual_keyboard_enabled, "Both flows focus the standard system IME editor")
			if editor == null: quit(1); return
			editor.select_all()
			for ch in "中文音色🙂": key(KEY_NONE, ch.unicode_at(0))
			await process_frame
			check(panel.draft == "中文音色🙂", "Actual Unicode GUI events reach the voice name")
			state.narration_clone_state.revision += 1; menu.refresh()
			check(editor.has_focus() and editor.text == panel.draft, "Backend redraw preserves the same editor and text focus")
			var before := commands.size()
			if submit_with_enter: key(KEY_ENTER)
			else: click(menu, panel, "submit_name")
			await process_frame
			check(commands.size() == before + 1 and commands.back().operation == "save" and commands.back().name == "中文音色🙂", "Enter and ray Save each send exactly one Unicode save command")
			check(not panel.editor.active() and not editor.has_focus() and not editor.visible, "Submission releases the IME and hides its editor")
			state.narration_clone_state.state = "saved"; menu.refresh()
			check(panel.naming.is_empty() and not panel.saving, "Saved response returns to candidate controls")
			state.narration_clone_state.state = "ready"; menu.refresh()
		click(menu, panel, "save_name"); await process_frame
		click(menu, panel, "back")
		check(not panel.editor.active() and not panel.naming.is_empty(), "Back dismisses system input first")
		click(menu, panel, "back")
		check(panel.naming.is_empty() and panel.opened, "Second Back returns to candidates")
		click(menu, panel, "save_name"); panel.close(); await process_frame
		check(not panel.editor.active() and root.gui_get_focus_owner() != panel.editor.editor, "Deferred input cannot reopen a closed voice panel")
		menu.free()
	print("Voice name system input checks=%d failures=%d" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
