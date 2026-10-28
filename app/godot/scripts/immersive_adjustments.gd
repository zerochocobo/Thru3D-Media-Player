extends RefCounted
## Fixed grip-stick controls. Values are fractions of the projection sphere radius.
const KEYS := ["view_horizontal", "view_vertical", "view_zoom"]
const OFFSET_LIMIT := 0.5
const ZOOM_LIMITS := Vector2(-0.5, 0.6)
const MOVE_SPEED := 0.25
const ALIGNMENT_SPEED := 2.0 # percent of one eye per second
const FEEDBACK_HOLD_MS := 850
const FEEDBACK_FADE_MS := 350
const TITLES := {"view_horizontal": "Horizontal position", "view_vertical": "Vertical position", "view_zoom": "Depth / zoom", "stereo_horizontal": "Stereo horizontal alignment"}
var ready := {}
var axes := {}
var alignment_value := NAN
var feedback := {}
var feedback_source := ""

## Keep one changing axis per hand visible; simultaneous hands get separate gauges.
func show_feedback(key: String, value: float, identity: String, now: int = Time.get_ticks_msec()) -> void:
	if not TITLES.has(key) or not is_finite(value): return
	if feedback_source != identity: feedback.clear()
	feedback_source = identity
	var group := ["view_horizontal", "view_vertical"] if key in ["view_horizontal", "view_vertical"] else ["view_zoom", "stereo_horizontal"]
	for other in group: feedback.erase(other)
	var span := limits(key) * 100.0
	if key == "stereo_horizontal":
		var alignment := preload("res://scripts/stereo_view.gd").HORIZONTAL
		span = Vector2(alignment.x, alignment.y)
	else: value *= 100.0
	feedback[key] = {"key": key, "title": TITLES[key], "value": value, "span": span, "time": now}

func clear_feedback() -> void:
	feedback.clear(); feedback_source = ""

func feedback_snapshot(identity: String, now: int = Time.get_ticks_msec()) -> Array[Dictionary]:
	if identity != feedback_source: clear_feedback()
	var result: Array[Dictionary] = []
	for key in TITLES:
		if not feedback.has(key): continue
		var age := maxi(0, now - int(feedback[key].time))
		if age >= FEEDBACK_HOLD_MS + FEEDBACK_FADE_MS:
			feedback.erase(key); continue
		var sample: Dictionary = feedback[key].duplicate()
		sample["alpha"] = clampf(float(FEEDBACK_HOLD_MS + FEEDBACK_FADE_MS - age) / FEEDBACK_FADE_MS, 0.0, 1.0)
		result.append(sample)
	return result

static func value_text(key: String, value: float) -> String:
	var precision := 0.01 if key == "stereo_horizontal" else 0.1
	if absf(value) < precision * 0.5: value = 0.0
	return ("%+.2f%%" if key == "stereo_horizontal" else "%+.1f%%") % value

static func limits(key: String) -> Vector2:
	return ZOOM_LIMITS if key == "view_zoom" else Vector2(-OFFSET_LIMIT, OFFSET_LIMIT)

static func valid(value: Dictionary) -> bool:
	for key in KEYS:
		if not value.has(key): continue
		var number: Variant = value[key]
		var span := limits(key)
		if not (number is int or number is float) or not is_finite(float(number)) or float(number) < span.x or float(number) > span.y: return false
	return true

func suspend() -> void:
	ready.clear(); axes.clear(); alignment_value = NAN

## A newly held grip, lost focus or reset requires a centred stick first. Lock the
## selected axis until centre, so a diagonal cannot silently change another setting.
func poll(hand: String, stick: Vector2, held: bool) -> Dictionary:
	if not held or not stick.is_finite():
		ready.erase(hand); axes.erase(hand)
		if hand == "right_hand": alignment_value = NAN
		return {}
	if stick.length() < 0.3:
		ready[hand] = true; axes.erase(hand)
		if hand == "right_hand": alignment_value = NAN
		return {}
	if not ready.get(hand, false): return {}
	if not axes.has(hand): axes[hand] = "x" if absf(stick.x) > absf(stick.y) else "y"
	var axis: String = axes[hand]
	var value: float = stick.x if axis == "x" else stick.y
	if absf(value) <= 0.2: return {}
	var key := ("view_horizontal" if axis == "x" else "view_vertical") if hand == "left_hand" else ("stereo_horizontal" if axis == "x" else "view_zoom")
	return {"key": key, "amount": signf(value) * (absf(value) - 0.2) / 0.8}
