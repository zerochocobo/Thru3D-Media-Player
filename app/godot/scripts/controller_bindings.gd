extends RefCounted
## Semantic bindings stay independent of vendor OpenXR physical paths.
const I18n := preload("res://scripts/i18n.gd")
const BUTTONS := ["ax_button", "by_button", "grip_click", "trigger_click", "primary_click"]
const AXES := ["stick_left", "stick_right", "stick_up", "stick_down"]
const HANDS := ["left_hand", "right_hand"]
const MODIFIERS := ["grip_click", "trigger_click"]
const SCOPES := ["video", "video_flat", "video_immersive", "photo"]
var overrides := {}
var move_scope := "panel"
var down := {"left_hand": {}, "right_hand": {}}
var blocked := {"left_hand": {}, "right_hand": {}}
var press_sequence := 0
var _definitions: Array[Dictionary] = []

func _init() -> void:
	_definitions = [
		entry("play", "Play / pause", "video", [bind("right_hand", "ax_button")]),
		entry("library_video", "Open media library", "video", [bind("left_hand", "ax_button")]),
		entry("library_photo", "Open media library", "photo", [bind("left_hand", "ax_button")]),
		entry("back20", "Back 20 seconds", "video", [bind("left_hand", "stick_left")]),
		entry("forward20", "Forward 20 seconds", "video", [bind("left_hand", "stick_right")]),
		entry("back10", "Back 10 seconds", "video", [bind("right_hand", "stick_left")]),
		entry("forward10", "Forward 10 seconds", "video", [bind("right_hand", "stick_right")]),
		entry("volume_up", "Volume up", "video", [bind("left_hand", "stick_up")]),
		entry("volume_down", "Volume down", "video", [bind("left_hand", "stick_down")]),
		entry("flat_volume_up", "Volume up", "video_flat", [bind("right_hand", "stick_up")]),
		entry("flat_volume_down", "Volume down", "video_flat", [bind("right_hand", "stick_down")]),
		entry("zoom_in", "Zoom in", "video_immersive", [bind("right_hand", "stick_up")], true),
		entry("zoom_out", "Zoom out", "video_immersive", [bind("right_hand", "stick_down")], true),
		entry("photo_next", "Next photo", "photo", [bind("right_hand", "stick_right")]),
		entry("photo_previous", "Previous photo", "photo", [bind("right_hand", "stick_left")]),
		entry("photo_close", "Close expanded photo", "photo", [bind("right_hand", "ax_button")]),
		entry("photo_zoom_in", "Zoom in", "photo", [bind("right_hand", "stick_up")], true),
		entry("photo_zoom_out", "Zoom out", "photo", [bind("right_hand", "stick_down")], true),
		entry("drag_video", "Drag picture", "video", [bind("left_hand", "trigger_click"), bind("right_hand", "trigger_click")], false, true),
		entry("drag_photo", "Drag picture", "photo", [bind("left_hand", "trigger_click"), bind("right_hand", "trigger_click")], false, true),
		entry("reset_video", "Reset picture", "video", [bind("right_hand", "primary_click")]),
		entry("reset_photo", "Reset picture", "photo", [bind("right_hand", "primary_click")]),
		entry("projection_video", "Cycle projection", "video", [bind("left_hand", "primary_click")]),
		entry("projection_photo", "Cycle projection", "photo", [bind("left_hand", "primary_click")]),
		entry("inspect", "Inspect photo", "photo", [bind("left_hand", "grip_click"), bind("right_hand", "grip_click")]),
		entry("move_video", "Move interfaces", "video", [], false, true),
		entry("move_photo", "Move interfaces", "photo", [], false, true),
		entry("subtitles", "Subtitle panel", "video", []),
		entry("passthrough_video", "Temporary passthrough", "video", []),
		entry("passthrough_photo", "Temporary passthrough", "photo", []),
		entry("follow_video", "Head follow", "video", []),
		entry("follow_photo", "Head follow", "photo", []),
		entry("grade_next", "Next color preset", "video", []),
		entry("grade_previous", "Previous color preset", "video", []),
		entry("temperature_up", "Warmer picture", "video", []),
		entry("temperature_down", "Cooler picture", "video", []),
		entry("mute", "Mute", "video", []),
		entry("audio_next", "Next audio track", "video", []),
		entry("subtitle_next", "Next subtitle track", "video", []),
		entry("eyes", "Swap eyes", "video", []),
		entry("alpha", "Person passthrough", "video", [])]

static func bind(hand: String, input: String, modifiers: Array = []) -> Dictionary:
	return {"hand": hand, "input": input, "modifiers": modifiers.duplicate()}

static func entry(id: String, title: String, scope: String, defaults: Array, continuous: bool = false, hold: bool = false) -> Dictionary:
	return {"id": id, "title": title, "scope": scope, "defaults": defaults, "continuous": continuous, "hold": hold}

func definitions() -> Array[Dictionary]: return _definitions

func definition(id: String) -> Dictionary:
	for item in _definitions:
		if item.id == id: return item
	return {}

func bindings(id: String) -> Array:
	return overrides.get(id, definition(id).get("defaults", [])).duplicate(true)

static func applies(scope: String, context: String) -> bool:
	return scope == context or (scope == "video" and context.begins_with("video"))

static func overlaps(a: String, b: String) -> bool:
	return a == b or (a.begins_with("video") and b.begins_with("video") and (a == "video" or b == "video"))

func clean_binding(value: Variant, id: String) -> Dictionary:
	if not value is Dictionary or definition(id).is_empty(): return {}
	if value.get("hand", "") not in HANDS or value.get("input", "") not in BUTTONS + AXES: return {}
	var mods: Variant = value.get("modifiers", [])
	if not mods is Array or mods.size() > 2: return {}
	var unique: Array = []
	for modifier in mods:
		if modifier not in MODIFIERS or modifier == value.input or modifier in unique: return {}
		unique.append(modifier)
	unique.sort()
	if not unique.is_empty() and unique != MODIFIERS: return {}
	if definition(id).hold and (value.input not in ["grip_click", "trigger_click"] or not unique.is_empty()): return {}
	if reserved(id, value.input, unique): return {}
	return bind(value.hand, value.input, unique)

## B/Y alone always backs out of menus; only chords and the matching photo close may use them.
static func reserved(id: String, input: String, modifiers: Array) -> bool:
	return input == "by_button" and modifiers.is_empty() and id != "photo_close"

func conflicts(id: String, candidate: Dictionary) -> Array[String]:
	var result: Array[String] = []
	var scope: String = definition(id).scope
	for item in _definitions:
		if item.id == id or not overlaps(scope, item.scope): continue
		for existing in bindings(item.id):
			if existing.hand != candidate.hand: continue
			var identical: bool = existing.input == candidate.input and existing.modifiers == candidate.modifiers
			# Grip owns the beginning of a chord. Trigger alone retains ordinary ray/drag behavior.
			var hold_prefix: bool = (existing.input == "grip_click" and existing.input in candidate.modifiers and not item.id.begins_with("move_")) or (candidate.input == "grip_click" and candidate.input in existing.modifiers and not id.begins_with("move_"))
			if identical or hold_prefix:
				if item.id not in result: result.append(item.id)
	return result

func assign(id: String, value: Variant, advanced: bool = false, replace_conflicts: bool = false) -> Dictionary:
	var candidate := clean_binding(value, id)
	if candidate.is_empty(): return {"ok": false, "error": "Unsupported binding"}
	var collisions := conflicts(id, candidate)
	if not collisions.is_empty() and not replace_conflicts: return {"ok": false, "conflicts": collisions}
	for other in collisions:
		var retained: Array = []
		for old in bindings(other):
			if old.hand == candidate.hand and (old.input == candidate.input and old.modifiers == candidate.modifiers or old.input in candidate.modifiers or candidate.input in old.modifiers): continue
			retained.append(old)
		overrides[other] = retained
	var updated: Array = bindings(id).filter(func(b): return not b.modifiers.is_empty() if not advanced else true)
	if candidate not in updated: updated.append(candidate)
	overrides[id] = updated
	reset_inputs()
	return {"ok": true}

func clear(id: String, advanced: bool = false) -> void:
	overrides[id] = bindings(id).filter(func(b): return b.modifiers.is_empty() if advanced else not b.modifiers.is_empty())
	reset_inputs()

## Validate the complete exchange before committing either side.
func swap_binding(id: String, value: Variant, advanced: bool = false, commit: bool = true) -> Dictionary:
	var candidate := clean_binding(value, id)
	if candidate.is_empty(): return {"ok": false}
	var collisions := conflicts(id, candidate)
	if collisions.size() != 1: return {"ok": false}
	var other: String = collisions[0]
	var matching: Array = bindings(other).filter(func(binding): return binding == candidate)
	var previous: Array = bindings(id).filter(func(binding): return not binding.modifiers.is_empty() if advanced else binding.modifiers.is_empty())
	if matching.size() != 1 or previous.size() > 1: return {"ok": false}
	for binding in previous:
		if clean_binding(binding, other).is_empty(): return {"ok": false}
	var original: Dictionary = overrides.duplicate(true)
	var source: Array = bindings(id).filter(func(binding): return binding.modifiers.is_empty() if advanced else not binding.modifiers.is_empty())
	var destination: Array = bindings(other).filter(func(binding): return binding != candidate)
	source.append(candidate); destination.append_array(previous)
	overrides[id] = source; overrides[other] = destination
	for changed in [id, other]:
		for binding in bindings(changed):
			if not conflicts(changed, binding).is_empty():
				overrides = original; return {"ok": false}
	if commit: reset_inputs()
	else: overrides = original
	return {"ok": true, "other": other}

func restore_one(id: String) -> bool:
	var saved := overrides.duplicate(true)
	overrides.erase(id)
	for candidate in bindings(id):
		if not conflicts(id, candidate).is_empty():
			overrides = saved; return false
	reset_inputs(); return true

func restore_all() -> void:
	overrides.clear(); move_scope = "panel"; reset_inputs()

func snapshot() -> Dictionary:
	return {"version": 1, "bindings": overrides.duplicate(true), "move_scope": move_scope}

func restore(data: Variant) -> void:
	restore_all()
	if not data is Dictionary or data.get("version", 0) != 1: return
	if data.get("move_scope", "") in ["panel", "media", "all"]: move_scope = data.move_scope
	var saved: Variant = data.get("bindings", {})
	if not saved is Dictionary: return
	# Validate the whole map first; malformed/conflicting files fall back to usable defaults.
	for id in saved:
		if definition(id).is_empty() or not saved[id] is Array or saved[id].size() > 8: restore_all(); return
		var values: Array = []
		for value in saved[id]:
			# Older builds allowed plain B/Y; drop just that choice instead of resetting every binding.
			if value is Dictionary and value.get("modifiers", []) is Array and reserved(id, str(value.get("input", "")), value.get("modifiers", [])): continue
			var cleaned := clean_binding(value, id)
			if cleaned.is_empty(): restore_all(); return
			if cleaned not in values: values.append(cleaned)
		overrides[id] = values
	# Adding a default must not invalidate a previously saved custom photo A binding.
	if not saved.has("photo_close") and not conflicts("photo_close", bind("right_hand", "ax_button")).is_empty():
		overrides["photo_close"] = []
	for id in overrides:
		for value in bindings(id):
			if not conflicts(id, value).is_empty(): restore_all(); return

func press(hand: String, input: String) -> bool:
	if hand not in HANDS or down[hand].has(input) or blocked[hand].has(input): return false
	press_sequence += 1
	down[hand][input] = press_sequence
	return true

func release(hand: String, input: String) -> void:
	if hand not in HANDS: return
	down[hand].erase(input); blocked[hand].erase(input)

func reset_inputs() -> void:
	for hand in HANDS:
		cancel_hand(hand)

func cancel_hand(hand: String) -> void:
	if hand not in HANDS: return
	for input in down[hand]: blocked[hand][input] = true
	down[hand].clear()

func resolve(hand: String, input: String, context: String) -> String:
	var chosen := ""
	var longest := -1
	for item in _definitions:
		if not applies(item.scope, context): continue
		for value in overrides.get(item.id, item.defaults):
			if value.hand != hand or value.input != input: continue
			if not value.modifiers.all(func(mod): return down[hand].has(mod)): continue
			if not value.modifiers.is_empty() and int(down[hand].grip_click) >= int(down[hand].trigger_click): continue
			if value.modifiers.size() > longest:
				chosen = item.id; longest = value.modifiers.size()
	# A configured modifier owns its press and axes until all modifiers are released.
	if longest == 0 and modifier_held(hand, context) and not (chosen.begins_with("move_") and input == "grip_click"): return ""
	return chosen

func modifier_held(hand: String, context: String) -> bool:
	for input in down.get(hand, {}):
		if is_modifier(hand, input, context): return true
	return false

func is_modifier(hand: String, input: String, context: String) -> bool:
	if input == "trigger_click" and not down.get(hand, {}).has("grip_click"): return false
	for item in _definitions:
		if applies(item.scope, context):
			for value in overrides.get(item.id, item.defaults):
				if value.hand == hand and input in value.modifiers: return true
	return false

static func input_name(input: String, hand: String) -> String:
	match input:
		"ax_button": return "X" if hand == "left_hand" else "A"
		"by_button": return "Y" if hand == "left_hand" else "B"
		"grip_click": return I18n.t("Grip")
		"trigger_click": return I18n.t("Trigger")
		"primary_click": return I18n.t("Stick press")
		"stick_left": return "◀"
		"stick_right": return "▶"
		"stick_up": return "▲"
		"stick_down": return "▼"
	return input

static func describe(value: Dictionary) -> String:
	var parts: Array[String] = []
	for modifier in value.modifiers: parts.append(input_name(modifier, value.hand))
	parts.append(input_name(value.input, value.hand))
	return I18n.t("Left" if value.hand == "left_hand" else "Right") + " · " + " + ".join(parts)

func label(id: String, advanced: bool = false) -> String:
	var values: Array = bindings(id).filter(func(b): return not b.modifiers.is_empty() if advanced else b.modifiers.is_empty())
	return I18n.t("Unassigned") if values.is_empty() else " / ".join(values.map(func(b): return describe(b)))

static func scope_name(scope: String) -> String:
	return I18n.t({"video": "Video", "video_flat": "Flat video", "video_immersive": "Immersive video", "photo": "Images"}.get(scope, scope))
