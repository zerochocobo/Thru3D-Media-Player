extends SceneTree
## External keyboard/gamepad mapping onto the standard controllers: the model, Main's routing
## without any tracked controller, and binding capture in Settings > Controls.
const External := preload("res://scripts/external_input.gd")
const Library := preload("res://scripts/library_menu.gd")
const Controls := preload("res://scripts/controls_page.gd")
const I18n := preload("res://scripts/i18n.gd")
var checks := 0
var failures: Array[String] = []
var output := ProjectSettings.globalize_path("res://../../build/output/external-input-mapping")

class InputMain extends "res://scripts/main.gd":
	var focused := true
	var head := Transform3D(Basis.IDENTITY, Vector3(0, 1.6, 0))
	func _input_focused() -> bool: return focused
	func _head_pose() -> Variant: return head

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok: failures.append(label)

func _initialize() -> void: _run.call_deferred()

static func key(code: Key, pressed: bool = true, echo: bool = false) -> InputEventKey:
	var event := InputEventKey.new(); event.keycode = code; event.pressed = pressed; event.echo = echo
	return event

static func pad(index: JoyButton, pressed: bool = true) -> InputEventJoypadButton:
	var event := InputEventJoypadButton.new(); event.button_index = index; event.pressed = pressed
	return event

static func axis(index: JoyAxis, value: float) -> InputEventJoypadMotion:
	var event := InputEventJoypadMotion.new(); event.axis = index; event.axis_value = value
	return event

func _run() -> void:
	DirAccess.make_dir_recursive_absolute(output)
	model()
	await integration()
	await capture()
	print("External input: %d checks, %d failures" % [checks, failures.size()])
	for failure in failures: print("FAIL: ", failure)
	quit(0 if failures.is_empty() else 1)

func model() -> void:
	var map := External.new()
	var slots := External.slots()
	check(slots.size() == 21 and "left_hand/menu_button" in slots and "right_hand/menu_button" not in slots, "Every standard input has one slot; only the left controller has a menu button")
	for slot in External.defaults():
		check(slot in slots, "Default names a real slot: " + slot)
		for source in External.defaults()[slot]: check(External.accepts(slot, source), "Default fits its slot: %s %s" % [slot, source])
	var all_defaults: Array = []
	for list in External.defaults().values(): all_defaults.append_array(list)
	check(all_defaults.size() == Array(all_defaults).reduce(func(seen, source): return seen if source in seen else seen + [source], []).size(), "No default source drives two slots")
	check(map.feed(key(KEY_SPACE)) == [{"slot": "right_hand/ax_button", "pressed": true}], "Space presses A")
	check(map.feed(key(KEY_SPACE, true, true)).is_empty(), "Key repeat is not another press")
	check(map.feed(key(KEY_SPACE, false)) == [{"slot": "right_hand/ax_button", "pressed": false}], "Releasing Space releases A")
	check(map.feed(key(KEY_K)).is_empty() and map.feed(key(KEY_K, false)).is_empty(), "An unmapped key stays with its normal handlers")
	check(map.feed(key(KEY_VOLUMEUP)).is_empty(), "Volume keys keep their system meaning")
	# Two sources on one slot: the slot is held until both let go.
	map.feed(pad(JOY_BUTTON_A)); map.feed(key(KEY_SPACE))
	check(map.held.values().count("right_hand/ax_button") == 2, "Gamepad A and Space both hold A")
	map.feed(pad(JOY_BUTTON_A, false))
	check(map.slot_held("right_hand/ax_button"), "Releasing one of two sources keeps A held")
	map.feed(key(KEY_SPACE, false))
	check(not map.slot_held("right_hand/ax_button"), "Releasing the second source releases A")
	# Trigger axis with hysteresis.
	var trigger: Array = []
	for value in [0.2, 0.7, 0.5, 0.45, 0.3, 0.9]: trigger.append_array(map.feed(axis(JOY_AXIS_TRIGGER_RIGHT, value)))
	check(trigger.map(func(change): return change.pressed) == [true, false, true], "RT presses at 0.6 and releases below 0.4: %s" % [trigger])
	map.feed(axis(JOY_AXIS_TRIGGER_RIGHT, 0.0))
	# Analog stick with Godot's down-positive Y turned into controller up-positive.
	map.feed(axis(JOY_AXIS_LEFT_X, 0.5)); map.feed(axis(JOY_AXIS_LEFT_Y, -0.8))
	check(map.stick("left_hand").is_equal_approx(Vector2(0.5, 0.8).limit_length(1.0)), "Left gamepad stick drives the left controller stick upward: %s" % map.stick("left_hand"))
	map.feed(axis(JOY_AXIS_LEFT_X, 0.05)); map.feed(axis(JOY_AXIS_LEFT_Y, -0.05))
	check(map.stick("left_hand") == Vector2.ZERO, "A resting stick inside the dead zone is centred")
	map.feed(key(KEY_RIGHT))
	check(map.stick("right_hand") == Vector2.RIGHT, "Right arrow holds the right stick to the right")
	map.feed(key(KEY_RIGHT, false))
	check(map.stick("right_hand") == Vector2.ZERO, "Releasing the arrow centres the stick")
	check(map.feed_android(85, true) == [{"slot": "right_hand/ax_button", "pressed": true}] and map.feed_android(85, false).size() == 1, "Android media play/pause presses A")
	check(map.feed_android(1001, true) == [{"slot": "right_hand/trigger_click", "pressed": true}], "PICO head control key presses the right trigger")
	map.feed_android(1001, false)
	check(map.feed_android(24, true).is_empty(), "Android keys Godot can name are not doubled")
	# Assigning moves a source; restore filters invalid data.
	check(map.assign("left_hand/ax_button", "key:%d" % KEY_SPACE), "Space can move to X")
	check(map.slot_for("key:%d" % KEY_SPACE) == "left_hand/ax_button" and "key:%d" % KEY_SPACE not in map.sources("right_hand/ax_button"), "A source drives only its new slot")
	check(not map.assign("left_hand/stick", "key:%d" % KEY_Q) and not map.assign("left_hand/ax_button", "stick:right"), "Sticks bind only to stick slots")
	map.clear("right_hand/by_button")
	check(map.sources("right_hand/by_button").is_empty() and map.feed(key(KEY_ESCAPE)).is_empty(), "A cleared slot ignores its former keys")
	var restored := External.new(); restored.restore(map.snapshot())
	check(restored.snapshot() == map.snapshot(), "Mappings survive a settings reload")
	restored.restore({"left_hand/ax_button": ["key:1", 3, "stick:left", "key:1"], "bogus": ["key:2"], "right_hand/stick": "x"})
	check(restored.snapshot() == {"left_hand/ax_button": ["key:1"]}, "Corrupt saved mappings are filtered: %s" % [restored.snapshot()])
	map.restore_all()
	check(map.snapshot().is_empty() and map.slot_for("key:%d" % KEY_SPACE) == "right_hand/ax_button", "Restore defaults")
	check(map.capture_source(key(KEY_VOLUMEDOWN)).is_empty() and map.capture_source(key(KEY_F5)) == "key:%d" % KEY_F5, "Capture names usable keys only")
	check(map.capture_source(axis(JOY_AXIS_RIGHT_Y, 0.8)) == "stick:right" and map.capture_source(axis(JOY_AXIS_TRIGGER_LEFT, 0.9)) == "axis:%d+" % JOY_AXIS_TRIGGER_LEFT, "Capture names sticks and trigger axes")
	# Connected devices, as the Android probe reports them on the Quest 2 (11-18 keyboard run).
	var devices := External.new()
	check(not devices.note_device({"kind": "device", "event": "present", "device": 5, "source": ["joystick", "mouse", "rotary"], "external": false, "virtual": false, "keyboard": "non_alphabetic"}), "The headset's own controllers are not an external device")
	check(not devices.note_device({"kind": "device", "event": "present", "device": -1, "source": ["keyboard", "dpad"], "external": false, "virtual": true, "keyboard": "alphabetic"}), "adb's virtual keyboard does not count")
	check(not devices.connected("keyboard") and not devices.connected("gamepad"), "Nothing connected at first")
	check(devices.note_device({"kind": "device", "event": "added", "device": 7, "source": ["keyboard", "stylus"], "external": true, "virtual": false, "keyboard": "alphabetic"}) and devices.connected("keyboard") and not devices.connected("gamepad"), "A Bluetooth keyboard lights the keyboard state")
	check(not devices.note_device({"kind": "device", "event": "changed", "device": 7, "source": ["keyboard", "stylus"], "external": true, "virtual": false, "keyboard": "alphabetic"}), "A changed record keeps the state")
	check(devices.note_device({"kind": "device", "event": "added", "device": 9, "source": ["keyboard", "gamepad", "joystick"], "external": true, "virtual": false, "keyboard": "non_alphabetic"}) and devices.connected("gamepad"), "A gamepad lights the gamepad state without counting as a keyboard")
	check(devices.note_device({"kind": "device", "event": "removed", "device": 7}) and not devices.connected("keyboard") and devices.connected("gamepad"), "Removing the keyboard dims only the keyboard")
	check(External.source_name("joy:%d" % JOY_BUTTON_DPAD_UP).ends_with("▲") and External.source_name("key:%d" % KEY_SPACE) == "Space", "Readable source names")

func integration() -> void:
	var config := ConfigFile.new()
	config.set_value("ui", "language", "en"); config.set_value("appearance", "background", "dark")
	config.save(output.path_join("settings.cfg"))
	var viewport := SubViewport.new(); viewport.own_world_3d = true; root.add_child(viewport)
	var main := InputMain.new(); main.settings_path = output.path_join("settings.cfg")
	viewport.add_child(main)
	main.set_process(false); main.video.set_process(false); main.photo.set_process(false); main.report_timer.stop()
	await process_frame
	# No XR controller is tracked at all: external keys still reach the controller routing.
	main.controller_diagnostics.clear()
	main._apply_external(main.external_input.feed(key(KEY_SPACE)))
	var press: Dictionary = main.controller_diagnostics.recent.back() if not main.controller_diagnostics.recent.is_empty() else {}
	check(press.get("input") == "ax_button" and press.get("hand") == "right_hand" and press.get("pressed") == true, "Space reaches the right A routing")
	# Past the controller gates; with no video playing, play itself reports no_active_video.
	check(str(press.get("route", "")) not in ["blocked.not_focused", "blocked.hand_tracking_owns_input", "blocked.hand_lock", "ignored.invalid_hand", ""], "No tracked controller is required: %s" % press.get("route"))
	check(not main._external_press, "The external flag never outlives its call")
	main._apply_external(main.external_input.feed(key(KEY_SPACE, false)))
	check(main.controller_diagnostics.recent.back().get("pressed") == false, "Space release reaches the A release routing")
	main.focused = false
	main._apply_external(main.external_input.feed(key(KEY_SPACE)))
	check(str(main.controller_diagnostics.recent.back().get("route")).begins_with("blocked.not_focused"), "An unfocused app ignores external keys like controllers")
	main._release_external()
	check(main.external_input.held.is_empty() and main.controller_diagnostics.recent.back().get("pressed") == false, "Pause releases every held external input")
	main.focused = true
	main.external_input.feed(key(KEY_UP))
	check(main._stick(main.left_controller) == Vector2(0, 1), "Up arrow drives the left stick without a tracked controller")
	main.external_input.feed(key(KEY_UP, false))
	main.focused = false
	main.external_input.feed(key(KEY_UP))
	check(main._stick(main.left_controller) == Vector2.ZERO, "An unfocused app ignores external sticks")
	main.external_input.release_all()
	main.focused = true
	await head_pointer(main)
	main._on_setting_changed("external_bindings", {"left_hand/ax_button": ["key:%d" % KEY_SPACE]})
	var saved := ConfigFile.new(); saved.load(main.settings_path)
	check(saved.get_value("input", "external_bindings", {}) == {"left_hand/ax_button": ["key:%d" % KEY_SPACE]}, "Mappings persist in the player settings")
	check(main.external_input.slot_for("key:%d" % KEY_SPACE) == "left_hand/ax_button", "Saved mappings drive input immediately")
	viewport.queue_free()
	await process_frame

func head_pointer(main: Node) -> void:
	main.display.preview = false
	main._external_used_ms = -main.HEAD_POINTER_IDLE_MS
	check(main._ray("right_hand") == null and not main._head_rays.get("right_hand", true), "No head pointer before any external input")
	main._external_used_ms = Time.get_ticks_msec()
	var ray: Variant = main._ray("right_hand")
	check(ray is Array and ray[0] == Vector3(0, 1.6, 0) and ray[1].is_equal_approx(Vector3.FORWARD) and main._head_rays.right_hand, "Recent external input aims the right hand from the view centre")
	check(main._ray("left_hand") == null and not main._head_rays.left_hand, "Only one head pointer is drawn")
	main._external_used_ms = Time.get_ticks_msec() - main.HEAD_POINTER_IDLE_MS - 1
	check(main._ray("right_hand") == null, "The head pointer ends after the external input has been idle")
	main._external_used_ms = Time.get_ticks_msec()
	main.focused = false
	check(main._ray("right_hand") == null, "An unfocused app has no head pointer")
	main.focused = true
	# Either trigger clicks where the head pointer aims; its release follows the press.
	main.controller_diagnostics.clear()
	main._apply_external(main.external_input.feed(axis(JOY_AXIS_TRIGGER_LEFT, 0.9)))
	var press: Dictionary = main.controller_diagnostics.recent.back()
	check(press.input == "trigger_click" and press.hand == "right_hand" and press.pressed, "LT clicks with the head pointer")
	main._external_used_ms = -main.HEAD_POINTER_IDLE_MS
	main._apply_external(main.external_input.feed(axis(JOY_AXIS_TRIGGER_LEFT, 0.0)))
	var release: Dictionary = main.controller_diagnostics.recent.back()
	check(release.input == "trigger_click" and release.hand == "right_hand" and not release.pressed, "The LT release reaches the hand that saw the press")
	main._external_used_ms = Time.get_ticks_msec()
	main._on_controller_button("ax_button", "left_hand")
	check(not main._head_pointer_active(), "A real controller click hands aiming back to the controllers")
	main._on_controller_release("ax_button", "left_hand")
	# Menus draw the head pointer as a reticle: no beam, a dot at the menu's depth on a miss.
	var library := Library.new(); root.add_child(library); library.set_process(false)
	library.visible = true; library.global_position = Vector3(0, 1.6, -2)
	library.head_pointers["right_hand"] = true
	library.update_pointer("right_hand", Vector3(0, 1.6, 0), Vector3(1, 0, 0), true)
	var pointer: Dictionary = library._pointer("right_hand")
	check(not pointer.line.visible and pointer.dot.visible, "A head pointer shows a dot, not a beam")
	check(is_equal_approx(pointer.dot.global_position.distance_to(Vector3(0, 1.6, 0)), 2.0), "A missed head pointer stays at the menu's depth: %s" % pointer.dot.global_position)
	library.head_pointers["right_hand"] = false
	library.update_pointer("right_hand", Vector3(0, 1.6, 0), Vector3(1, 0, 0), true)
	check(pointer.line.visible and not pointer.dot.visible, "A controller ray keeps its beam and shows no dot on a miss")
	library.queue_free()
	await head_fading()
	main.display.preview = true
	await process_frame

## The world reticle from the head: no beam, and head turns keep it awake like controller motion.
func head_fading() -> void:
	var feedback := preload("res://scripts/controller_feedback.gd").new(); root.add_child(feedback)
	feedback.beamless["right_hand"] = true
	var aim := func(yaw: float) -> Transform3D: return Transform3D(Basis(Vector3.UP, yaw), Vector3(0, 1.6, 0))
	var step := func(pose: Transform3D, delta: float) -> float:
		return feedback.update_hand("right_hand", pose, [pose.origin, -pose.basis.z], null, false, false, delta, true,
			{"position": pose.origin, "direction": -pose.basis.z})
	feedback.wake("right_hand", "button")
	step.call(aim.call(0.0), 0.016)
	var nodes: Dictionary = feedback.hands.right_hand.nodes
	check(not nodes.line.visible and nodes.dot.visible, "The head's world pointer is a reticle without a beam")
	# Look around for eight seconds: each turn past the activity angle keeps the reticle.
	var yaw := 0.0
	for frame in 480:
		if frame % 30 == 0: yaw += 0.12
		step.call(aim.call(yaw), 1.0 / 60.0)
	check(nodes.dot.visible, "Turning the head keeps the reticle past the five-second idle fade")
	for frame in 420: step.call(aim.call(yaw), 1.0 / 60.0)
	check(not nodes.dot.visible, "A still head lets the reticle fade like a resting controller")
	feedback.queue_free()
	await process_frame

func capture() -> void:
	var library := Library.new(); root.add_child(library); library.set_process(false)
	var page: Controls = library.controls_page
	var emitted: Array = []
	library.setting_changed.connect(func(key, value): emitted.append([key, value]))
	library.section = library.Section.SETTINGS; library.tab = library.CONTROLS_TAB; library.visible = true
	check(page.action(Controls.MODE + Controls.MAPPING) and page.mode == Controls.MAPPING, "The fourth Controls tab opens key mapping")
	var rows := page.items()
	check(rows.size() == External.slots().size() and rows[0].slot == "left_hand/ax_button" and rows[0].scope == "Left hand", "One row per standard controller input")
	library.refresh()
	check(page.action(library.ROW_BASE) and page.capture_slot == "left_hand/ax_button" and page.capturing() and page.modal(), "Choosing a row waits for an external key")
	var texts := func(): return library.find_children("*", "Label3D", true, false).map(func(label): return label.text)
	check(I18n.t("No external device detected") in texts.call(), "Without a detected device the dialog says so")
	page.external.note_device({"kind": "device", "event": "added", "device": 7, "source": ["keyboard"], "external": true, "virtual": false, "keyboard": "alphabetic"})
	library.refresh()
	check(I18n.t("Press a key or button") in texts.call(), "With a keyboard the dialog asks for a key")
	check(not page.capture("stick:left") and page.capturing(), "A button slot keeps waiting through a stick move")
	check(page.capture("key:%d" % KEY_F5) and not page.capturing(), "The next key binds")
	check(page.external.slot_for("key:%d" % KEY_F5) == "left_hand/ax_button" and emitted.back() == ["external_bindings", page.external.snapshot()], "The binding is saved as external_bindings")
	page.action(library.ROW_BASE)
	check(page.action(Controls.CLEAR_KEY) and page.external.sources("left_hand/ax_button").is_empty(), "Clear empties the slot")
	page.action(library.ROW_BASE)
	check(page.action(Controls.CANCEL) and not page.capturing(), "Cancel stops waiting")
	page.action(Controls.RESET_ALL); page.action(Controls.RESET_ALL)
	check(page.external.snapshot().is_empty() and emitted.back()[0] == "external_bindings", "Restore defaults resets only the key mapping on its tab")
	page.action(Controls.MODE)
	check(page.mode == 0 and not page.capturing(), "Leaving the tab ends any capture")
	library.queue_free()
	await process_frame
