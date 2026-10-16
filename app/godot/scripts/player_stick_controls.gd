extends RefCounted

signal suspended

var left_latched := false
var right_latched := false
## The right stick stays with the selected zoom action until it returns to center.
var right_zooming := false
var mapped_continuous := {}

## UI captures own the input until each stick returns to center.
func suspend() -> void:
	left_latched = true
	right_latched = true
	right_zooming = false
	mapped_continuous.clear()
	suspended.emit()

# One command per deflection; return to center before changing direction/action.
# With [zoom] the right stick's up/down zooms continuously instead of volume.
func poll(left: Vector2, right: Vector2, zoom: bool = false) -> Array[Dictionary]:
	var actions: Array[Dictionary] = []
	for hand in ["left", "right"]:
		var stick: Vector2 = left if hand == "left" else right
		if not is_finite(stick.x) or not is_finite(stick.y):
			continue
		if stick.length() < 0.3:
			mapped_continuous.erase(hand)
			if hand == "left":
				left_latched = false
			else:
				right_latched = false
				right_zooming = false
			continue
		if hand == "right" and zoom and (right_zooming or (not right_latched and absf(stick.y) >= absf(stick.x))):
			right_zooming = true
			right_latched = true
			actions.append({"operation": "zoom", "amount": stick.y})
			continue
		var latched := left_latched if hand == "left" else right_latched
		if latched:
			continue
		# Cardinal pushes only: a diagonal does nothing (a stray diagonal once swapped the eyes).
		# Left up/down is the volume (up also unmutes); mute lives on the menu's volume slider.
		var action: Dictionary = {}
		if absf(stick.x) > 0.75 and absf(stick.y) < 0.3:
			var direction := 1 if stick.x > 0 else -1
			action = {"operation": "seek", "hand": hand, "direction": direction,
				"delta_ms": direction * (20000 if hand == "left" else 10000)}
		elif absf(stick.y) > 0.75 and absf(stick.x) < 0.3:
			action = {"operation": "volume", "direction": 1 if stick.y > 0 else -1}
		if not action.is_empty():
			actions.append(action)
			if hand == "left":
				left_latched = true
			else:
				right_latched = true
	return actions

## The resolver returns the semantic action for a direction, including grip-first combinations.
func poll_mapped(left: Vector2, right: Vector2, resolver: Callable) -> Array[Dictionary]:
	var actions: Array[Dictionary] = []
	for hand in ["left", "right"]:
		var stick: Vector2 = left if hand == "left" else right
		if not stick.is_finite(): continue
		if stick.length() < 0.3:
			# A centered stick releases its continuous action as well as its latch.
			# Otherwise the old direction blocks reverse zoom and subsequent shortcuts.
			mapped_continuous.erase(hand)
			if hand == "left": left_latched = false
			else: right_latched = false; right_zooming = false
			continue
		var input: String = str(mapped_continuous.get(hand, {}).get("input", ""))
		if input.is_empty():
			if absf(stick.x) > 0.75 and absf(stick.y) < 0.3: input = "stick_right" if stick.x > 0 else "stick_left"
			elif absf(stick.y) >= absf(stick.x): input = "stick_up" if stick.y > 0 else "stick_down"
		if input.is_empty(): continue
		var resolved: Dictionary = resolver.call(hand + "_hand", input)
		if resolved.is_empty(): continue
		if mapped_continuous.has(hand) and mapped_continuous[hand].id != resolved.id: continue
		if mapped_continuous.has(hand):
			var component: float = stick.y if input in ["stick_up", "stick_down"] else stick.x
			if component * (1 if input in ["stick_up", "stick_right"] else -1) <= 0: continue
		var latched: bool = left_latched if hand == "left" else right_latched
		if resolved.get("continuous", false):
			if mapped_continuous.has(hand) or not latched:
				resolved.amount = stick.y if input in ["stick_up", "stick_down"] else stick.x
				mapped_continuous[hand] = {"input": input, "id": resolved.id}
				if hand == "right": right_zooming = true
				if hand == "left": left_latched = true
				else: right_latched = true
				actions.append(resolved)
		elif not latched and (absf(stick.x) > 0.75 and absf(stick.y) < 0.3 or absf(stick.y) > 0.75 and absf(stick.x) < 0.3):
			if hand == "left": left_latched = true
			else: right_latched = true
			actions.append(resolved)
	return actions
