extends RefCounted
## One normal next-image action per fully presented image; never a queue of timer events.
const DEFAULT_INTERVAL := 5.0
const INTERVAL_LIMITS := Vector2(3, 30)
var enabled := false
var interval := DEFAULT_INTERVAL
const EFFECTS := ["cut", "fade", "wipe", "depth", "slide"]
var effect := "slide" # Existing installations keep their familiar transition.
var advancing := false
var _elapsed := 0.0
var _identity: Array = []
var _armed := false
var _started_us := 0
# Godot clamps process delta during slow frames. The displayed dwell uses a monotonic
# clock so initial cache/conversion work cannot stretch five seconds into fifteen.
var clock: Callable = Time.get_ticks_usec

func reset() -> void:
	_elapsed = 0.0; _identity = []; _armed = false; _started_us = 0

func set_enabled(value: bool) -> void:
	enabled = value; reset()

func set_interval(value: Variant) -> bool:
	if typeof(value) not in [TYPE_INT, TYPE_FLOAT] or not is_finite(float(value)): return false
	var seconds := clampf(roundf(float(value)), INTERVAL_LIMITS.x, INTERVAL_LIMITS.y)
	if is_equal_approx(interval, seconds): return false
	interval = seconds; reset(); return true

func set_effect(value: Variant) -> bool:
	if not value is String or value not in EFFECTS or value == effect: return false
	effect = value; reset(); return true

func tick(photo: Node3D, delta: float, blocked: bool) -> bool:
	if not enabled: return false
	if photo.autoplay_failed() or (photo.queue.size() < 2 and photo.queue_complete and not photo.loading):
		set_enabled(false); photo.changed.emit(); return false
	if blocked or not photo.autoplay_ready() or not is_finite(delta) or delta < 0:
		reset(); return false
	var identity: Array = photo.autoplay_identity()
	if identity != _identity:
		reset(); _identity = identity
	var now: int = clock.call()
	if not _armed:
		_armed = true; _started_us = now; return false # Exclude the frame that first exposed the final picture.
	_elapsed = maxf(0, (now - _started_us) / 1000000.0)
	if _elapsed + 0.000001 < interval: return false
	reset()
	advancing = true
	var accepted: bool = photo.navigate(1)
	advancing = false
	if accepted: return true
	set_enabled(false); photo.changed.emit()
	return false
