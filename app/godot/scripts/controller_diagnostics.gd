extends RefCounted
## Bounded input evidence. Values are action states, never media identities or pointer targets.
const Log := preload("res://scripts/diagnostic_log.gd")
const Privacy := preload("res://scripts/media_privacy.gd")
const Bindings := preload("res://scripts/controller_bindings.gd")
const BUTTONS := Bindings.BUTTONS + ["menu_button", "select_button"]
const RECENT_LIMIT := 48
const STICK_GAP_MS := 200
const STICK_HELD_MS := 2000
const EVENTS_PER_SECOND := 40
var recent: Array[Dictionary] = []
var buttons_seen := {}
var sticks := {}
var _emitted := {}
var _window_ms := -1
var _window_count := 0
var suppressed := 0

static func enabled() -> bool:
	return Privacy.mode == Privacy.ALL and not (Privacy.vault != null and Privacy.vault.protected)

func clear() -> void:
	recent.clear(); buttons_seen.clear(); sticks.clear(); _emitted.clear()
	_window_ms = -1; _window_count = 0; suppressed = 0

func button(now: int, hand: String, input: String, pressed: bool, route: String, context: Dictionary) -> void:
	if not enabled(): clear(); return
	if hand not in Bindings.HANDS or input not in BUTTONS: return
	var key := hand + "/" + input
	buttons_seen[key] = int(buttons_seen.get(key, 0)) + int(pressed)
	_append(now, {"kind": "button", "hand": hand, "input": input,
		"pressed": pressed, "route": route, "context_stage": "before_route", "context": context.duplicate(true)})

## Called after routing, before values are lost to the next frame. Context is sampled only when
## an event is due; no tracker/menu dictionaries or file writes on every XR frame.
func stick(now: int, hand: String, raw: Vector2, effective: Vector2, route: String, context: Callable) -> void:
	if not enabled(): clear(); return
	if hand not in Bindings.HANDS: return
	var state := {"kind": "stick", "hand": hand, "raw": _vector(raw),
		"effective": _vector(effective), "direction": direction(raw), "route": route}
	sticks[hand] = state.duplicate()
	var previous: Dictionary = _emitted.get(hand, {})
	var active: bool = state.direction != "center"
	var changed: bool = previous.is_empty() or previous.direction != state.direction or previous.route != route
	var elapsed := now - int(previous.get("at_ms", -STICK_HELD_MS))
	# Preserve short flicks and returns to centre. Only intermediate analogue noise is thinned.
	var edge: bool = not previous.is_empty() and (previous.direction != state.direction and state.direction != "diagonal_or_partial" or previous.route != route)
	if not previous.is_empty() and not edge and elapsed < STICK_GAP_MS: return
	if not changed and (not active or elapsed < STICK_HELD_MS): return
	state["context"] = context.call(hand) if context.is_valid() else {}
	state["context_stage"] = "after_route"
	_emitted[hand] = {"direction": state.direction, "route": route, "at_ms": now}
	_append(now, state)

static func _vector(value: Vector2) -> Variant:
	return [snappedf(value.x, 0.01), snappedf(value.y, 0.01)] if value.is_finite() else "non_finite"

static func direction(value: Vector2) -> String:
	if not value.is_finite(): return "non_finite"
	if value.length() < 0.3: return "center"
	if absf(value.x) > 0.75 and absf(value.y) < 0.3: return "right" if value.x > 0 else "left"
	if absf(value.y) > 0.75 and absf(value.x) < 0.3: return "up" if value.y > 0 else "down"
	return "diagonal_or_partial"

func _append(now: int, event: Dictionary) -> void:
	if _window_ms < 0 or now - _window_ms >= 1000:
		_window_ms = now; _window_count = 0
	if _window_count >= EVENTS_PER_SECOND:
		suppressed += 1; return
	_window_count += 1
	event["at_ms"] = now
	recent.append(event)
	if recent.size() > RECENT_LIMIT: recent.pop_front()
	Log.record("controller_input", event)

func snapshot() -> Dictionary:
	if not enabled():
		clear()
		return {"recording": false, "reason": "privacy"}
	return {"recording": true, "buttons_seen": buttons_seen.duplicate(), "sticks": sticks.duplicate(true),
		"rate_limited": suppressed, "recent": recent.duplicate(true)}
