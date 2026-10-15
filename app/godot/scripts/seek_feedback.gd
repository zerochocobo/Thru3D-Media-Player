extends RefCounted
## A stick gesture owns a preview; only release submits it to the decoder.
const HOLD_DELAY := 0.4
const REPEAT_SECONDS := 0.25
const MIN_VISIBLE := 0.6
const FADE_SECONDS := 0.25
var phase := ""
var owner := ""
var input := ""
var action_id := ""
var source_uri := ""
var sequence := 0
var origin_ms := 0
var target_ms := 0
var duration_ms := 0
var step_ms := 0
var age := 0.0
var held := 0.0
var next_repeat := HOLD_DELAY
var fade_left := 0.0

func begin(sample: Dictionary, hand: String, axis: String, step: int, id: String = "") -> void:
	if phase == "preview" or not sample.get("active", false) or int(sample.get("duration_ms", 0)) <= 0: return
	phase = "preview"; owner = hand; input = axis; action_id = id
	source_uri = str(sample.uri); sequence = int(sample.sequence)
	duration_ms = int(sample.duration_ms); origin_ms = int(sample.position_ms)
	step_ms = step; target_ms = clampi(origin_ms + step, 0, duration_ms - 1)
	age = 0.0; held = 0.0; next_repeat = HOLD_DELAY; fade_left = 0.0

## NaN/tracking loss cancels; only a deliberate return to the deadzone commits.
func poll(stick: Vector2, delta: float) -> bool:
	if phase != "preview": return false
	if not stick.is_finite(): clear(); return false
	if stick.length() < 0.3:
		if target_ms == origin_ms: clear(); return false
		phase = "waiting"
		return true
	var amount := stick.x if input in ["stick_left", "stick_right"] else stick.y
	var sign_axis := 1.0 if input in ["stick_right", "stick_up"] else -1.0
	if amount * sign_axis > 0.75:
		held += clampf(delta, 0.0, 0.1) # a stalled XR frame must not jump several minutes
		if held + 0.00001 >= next_repeat:
			target_ms = clampi(target_ms + step_ms, 0, duration_ms - 1)
			next_repeat += REPEAT_SECONDS
	return false

func sync(sample: Dictionary, delta: float) -> void:
	if phase.is_empty(): return
	if not sample.get("active", false) or str(sample.get("uri", "")) != source_uri \
		or int(sample.get("sequence", -1)) != sequence:
		clear(); return
	age += maxf(0.0, delta)
	if phase == "done":
		fade_left -= maxf(0.0, delta)
		if fade_left <= 0.0: clear()

func presented(request: int, actual_ms: int) -> void:
	if phase != "waiting" or request != sequence: return
	phase = "done"; target_ms = maxi(0, actual_ms)
	fade_left = FADE_SECONDS + maxf(0.0, MIN_VISIBLE - age)

func cancel_preview() -> void:
	if phase == "preview": clear()

func clear() -> void:
	phase = ""; owner = ""; action_id = ""

func snapshot() -> Dictionary:
	if phase.is_empty(): return {}
	return {"phase": phase, "origin_ms": origin_ms, "target_ms": target_ms,
		"duration_ms": duration_ms, "delta_ms": target_ms - origin_ms,
		"alpha": clampf(fade_left / FADE_SECONDS, 0.0, 1.0) if phase == "done" else 1.0}

static func time(milliseconds: int) -> String:
	var seconds := maxi(0, milliseconds / 1000)
	return "%d:%02d:%02d" % [seconds / 3600, (seconds / 60) % 60, seconds % 60] if seconds >= 3600 else "%02d:%02d" % [seconds / 60, seconds % 60]

static func offset(milliseconds: int) -> String:
	return ("−" if milliseconds < 0 else "+") + time(absi(milliseconds))
