extends RefCounted
## External keyboards and gamepads drive the standard left/right controllers. A source (key,
## gamepad button, trigger axis, analog stick, or an Android-only key code) maps to one controller
## input, which then runs through the ordinary controller routing and the user's action bindings.
const I18n := preload("res://scripts/i18n.gd")
const Bindings := preload("res://scripts/controller_bindings.gd")
const HANDS := ["left_hand", "right_hand"]
const BUTTONS := ["ax_button", "by_button", "trigger_click", "grip_click", "primary_click"]
## Controller stick space: +y is up, as OpenXR reports it.
const DIRECTIONS := {"stick_up": Vector2(0, 1), "stick_down": Vector2(0, -1), "stick_left": Vector2(-1, 0), "stick_right": Vector2(1, 0)}
const PRESS := 0.6
const RELEASE := 0.4
## Godot reports these Android key codes as unknown keys; the plugin forwards them instead.
const ANDROID_KEYS := {85: "Play / pause", 126: "Play", 127: "Pause", 86: "Stop", 1001: "Head control key"}
## Volume and system keys keep their system meaning: a binding would act twice.
const RESERVED_KEYS := [KEY_VOLUMEUP, KEY_VOLUMEDOWN, KEY_VOLUMEMUTE, KEY_META, KEY_UNKNOWN, KEY_NONE]
const JOY_NAMES := {JOY_BUTTON_A: "A", JOY_BUTTON_B: "B", JOY_BUTTON_X: "X", JOY_BUTTON_Y: "Y",
	JOY_BUTTON_BACK: "Back", JOY_BUTTON_GUIDE: "Home", JOY_BUTTON_START: "Start",
	JOY_BUTTON_LEFT_STICK: "LS", JOY_BUTTON_RIGHT_STICK: "RS", JOY_BUTTON_LEFT_SHOULDER: "LB",
	JOY_BUTTON_RIGHT_SHOULDER: "RB"}
const DPAD := {JOY_BUTTON_DPAD_UP: "▲", JOY_BUTTON_DPAD_DOWN: "▼", JOY_BUTTON_DPAD_LEFT: "◀", JOY_BUTTON_DPAD_RIGHT: "▶"}

var overrides := {}
## External devices the Android probe reports: id -> {"keyboard": bool, "gamepad": bool}.
## The headset's own controllers are internal and adb's injector is virtual; neither counts.
var devices := {}
## source -> slot it pressed, so a release always reaches the slot that saw the press.
var held := {}
var _axes := {}
var _sticks := {"stick:left": Vector2.ZERO, "stick:right": Vector2.ZERO}

## Applies one device record from the plugin's external_input; true when the shown state changed.
func note_device(data: Dictionary) -> bool:
	var before := [connected("keyboard"), connected("gamepad")]
	var id := int(data.get("device", -1))
	if data.get("event") == "removed" or not bool(data.get("external", false)) or bool(data.get("virtual", false)):
		devices.erase(id)
	else:
		var sources: Array = data.get("source", [])
		devices[id] = {"keyboard": data.get("keyboard") == "alphabetic", "gamepad": "gamepad" in sources or "joystick" in sources}
	return before != [connected("keyboard"), connected("gamepad")]

func connected(kind: String) -> bool:
	return devices.values().any(func(device): return device.get(kind, false))

static func slots() -> Array[String]:
	var result: Array[String] = []
	for hand in HANDS:
		for input in BUTTONS + ["stick"] + DIRECTIONS.keys(): result.append(hand + "/" + input)
	result.insert(BUTTONS.size(), "left_hand/menu_button")
	return result

static func defaults() -> Dictionary:
	return {
		"right_hand/ax_button": ["joy:%d" % JOY_BUTTON_A, "key:%d" % KEY_SPACE, "android:85"],
		"right_hand/by_button": ["joy:%d" % JOY_BUTTON_B, "key:%d" % KEY_ESCAPE, "key:%d" % KEY_BACKSPACE],
		"left_hand/ax_button": ["joy:%d" % JOY_BUTTON_X],
		"left_hand/by_button": ["joy:%d" % JOY_BUTTON_Y],
		"left_hand/trigger_click": ["axis:%d+" % JOY_AXIS_TRIGGER_LEFT],
		"right_hand/trigger_click": ["axis:%d+" % JOY_AXIS_TRIGGER_RIGHT, "key:%d" % KEY_ENTER, "android:1001"],
		"left_hand/grip_click": ["joy:%d" % JOY_BUTTON_LEFT_SHOULDER],
		"right_hand/grip_click": ["joy:%d" % JOY_BUTTON_RIGHT_SHOULDER],
		"left_hand/primary_click": ["joy:%d" % JOY_BUTTON_LEFT_STICK],
		"right_hand/primary_click": ["joy:%d" % JOY_BUTTON_RIGHT_STICK],
		"left_hand/menu_button": ["joy:%d" % JOY_BUTTON_START, "key:%d" % KEY_TAB],
		"left_hand/stick": ["stick:left"],
		"right_hand/stick": ["stick:right"],
		"left_hand/stick_up": ["key:%d" % KEY_UP],
		"left_hand/stick_down": ["key:%d" % KEY_DOWN],
		"right_hand/stick_up": ["joy:%d" % JOY_BUTTON_DPAD_UP],
		"right_hand/stick_down": ["joy:%d" % JOY_BUTTON_DPAD_DOWN],
		"right_hand/stick_left": ["joy:%d" % JOY_BUTTON_DPAD_LEFT, "key:%d" % KEY_LEFT, "key:%d" % KEY_MEDIAPREVIOUS],
		"right_hand/stick_right": ["joy:%d" % JOY_BUTTON_DPAD_RIGHT, "key:%d" % KEY_RIGHT, "key:%d" % KEY_MEDIANEXT]}

func sources(slot: String) -> Array:
	return (overrides[slot] if overrides.has(slot) else defaults().get(slot, [])).duplicate()

func slot_for(source: String) -> String:
	for slot in slots():
		if source in sources(slot): return slot
	return ""

static func accepts(slot: String, source: String) -> bool:
	return slot.ends_with("/stick") == source.begins_with("stick:")

## One source drives one slot: assigning moves it away from any other slot.
func assign(slot: String, source: String) -> bool:
	if slot not in slots() or source.is_empty() or not accepts(slot, source): return false
	for other in slots():
		var current := sources(other)
		if other != slot and source in current:
			current.erase(source); overrides[other] = current
	var list := sources(slot)
	if source not in list: list.append(source)
	overrides[slot] = list
	release_all()
	return true

func clear(slot: String) -> void:
	overrides[slot] = []; release_all()

func restore_all() -> void:
	overrides.clear(); release_all()

func snapshot() -> Dictionary:
	return overrides.duplicate(true)

func restore(data: Variant) -> void:
	overrides.clear()
	if not data is Dictionary: return
	for slot in data:
		if str(slot) not in slots() or not data[slot] is Array: continue
		var list: Array = []
		for source in data[slot]:
			if source is String and accepts(str(slot), source) and source not in list: list.append(source)
		overrides[str(slot)] = list
	release_all()

func release_all() -> void:
	held.clear(); _axes.clear()
	for stick in _sticks: _sticks[stick] = Vector2.ZERO

## The source an event names, for capturing a binding; "" when it names nothing usable.
func capture_source(event: InputEvent) -> String:
	if event is InputEventKey and event.pressed and not event.echo:
		var code := key_code(event)
		return "" if code in RESERVED_KEYS else "key:%d" % code
	if event is InputEventJoypadButton and event.pressed: return "joy:%d" % event.button_index
	if event is InputEventJoypadMotion:
		if event.axis in [JOY_AXIS_LEFT_X, JOY_AXIS_LEFT_Y] and absf(event.axis_value) > PRESS: return "stick:left"
		if event.axis in [JOY_AXIS_RIGHT_X, JOY_AXIS_RIGHT_Y] and absf(event.axis_value) > PRESS: return "stick:right"
		if absf(event.axis_value) > PRESS: return "axis:%d%s" % [event.axis, "+" if event.axis_value > 0 else "-"]
	return ""

static func key_code(event: InputEventKey) -> int:
	return int(event.keycode) if event.keycode != KEY_NONE else int(event.physical_keycode)

## Turns an input event into slot transitions: [{slot, pressed}]. Analog sticks only update the
## stick value. An unmapped source yields nothing, so the event stays with its normal handlers.
func feed(event: InputEvent) -> Array[Dictionary]:
	var changes: Array[Dictionary] = []
	if event is InputEventKey:
		if event.echo: return changes
		var code := key_code(event)
		if code not in RESERVED_KEYS: _transition("key:%d" % code, event.pressed, changes)
	elif event is InputEventJoypadButton:
		_transition("joy:%d" % event.button_index, event.pressed, changes)
	elif event is InputEventJoypadMotion:
		var value: float = event.axis_value if is_finite(event.axis_value) else 0.0
		match event.axis:
			JOY_AXIS_LEFT_X: _sticks["stick:left"].x = value
			JOY_AXIS_LEFT_Y: _sticks["stick:left"].y = -value
			JOY_AXIS_RIGHT_X: _sticks["stick:right"].x = value
			JOY_AXIS_RIGHT_Y: _sticks["stick:right"].y = -value
			_:
				for sign in ["+", "-"]:
					var source := "axis:%d%s" % [event.axis, sign]
					var signed := value if sign == "+" else -value
					var was := bool(_axes.get(source, false))
					var now := signed > PRESS or (was and signed > RELEASE)
					if now != was:
						_axes[source] = now; _transition(source, now, changes)
	return changes

## Android key codes Godot cannot name ({keycode, action} from the plugin's external_input).
func feed_android(code: int, pressed: bool) -> Array[Dictionary]:
	var changes: Array[Dictionary] = []
	if ANDROID_KEYS.has(code): _transition("android:%d" % code, pressed, changes)
	return changes

func _transition(source: String, pressed: bool, changes: Array[Dictionary]) -> void:
	if pressed:
		if held.has(source): return
		var slot := slot_for(source)
		if slot.is_empty() or slot.ends_with("/stick"): return
		held[source] = slot
		changes.append({"slot": slot, "pressed": true})
	elif held.has(source):
		changes.append({"slot": held[source], "pressed": false})
		held.erase(source)

## Whether any held source still presses [slot]: two sources on one slot release once.
func slot_held(slot: String) -> bool:
	return held.values().has(slot)

## Analog stick plus held stick directions for [hand], clamped to the unit circle.
func stick(hand: String) -> Vector2:
	var value := Vector2.ZERO
	for source in sources(hand + "/stick"):
		if _sticks.has(source): value += _sticks[source]
	for direction in DIRECTIONS:
		if slot_held(hand + "/" + direction): value += DIRECTIONS[direction]
	return value.limit_length(1.0) if value.length() > 0.15 else Vector2.ZERO

static func source_name(source: String) -> String:
	var parts := source.split(":")
	if parts.size() != 2: return source
	match parts[0]:
		"key": return OS.get_keycode_string(int(parts[1]))
		"joy":
			var index := int(parts[1])
			if DPAD.has(index): return I18n.t("Gamepad") + " " + I18n.t("D-pad") + " " + DPAD[index]
			return I18n.t("Gamepad") + " " + JOY_NAMES.get(index, parts[1])
		"axis":
			if parts[1] == "%d+" % JOY_AXIS_TRIGGER_LEFT: return I18n.t("Gamepad") + " LT"
			if parts[1] == "%d+" % JOY_AXIS_TRIGGER_RIGHT: return I18n.t("Gamepad") + " RT"
			return I18n.t("Gamepad") + " " + I18n.t("Axis") + " " + parts[1]
		"stick": return I18n.t("Gamepad") + " " + I18n.t("Left stick" if parts[1] == "left" else "Right stick")
		"android": return I18n.t(ANDROID_KEYS[int(parts[1])]) if ANDROID_KEYS.has(int(parts[1])) else I18n.t("Key") + " " + parts[1]
	return source

static func slot_name(slot: String) -> String:
	var input := slot.get_slice("/", 1)
	if input == "stick": return I18n.t("Stick")
	if input == "menu_button": return I18n.t("Menu button")
	var name := Bindings.input_name(input, slot.get_slice("/", 0))
	return (I18n.t("Stick direction") + " " + name) if input in DIRECTIONS else name

func summary(slot: String) -> String:
	var names := sources(slot).map(func(source): return source_name(source))
	return I18n.t("Unassigned") if names.is_empty() else " / ".join(names)
