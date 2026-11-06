extends RefCounted
## Playback windows for exported diagnostics. A window closes every WINDOW_MS, or when the menu, display
## path or display policy changes, or on a seek, so undisturbed playback can be told from the rest:
## clean windows have menu "", seeks 0 and mixed false. Drop counts are increments within the window.

const WINDOW_MS := 10000
## Changes inside a shorter window join it and mark it mixed: held seeks must not flood the log.
const MIN_WINDOW_MS := 2000
const STATE_KEYS := ["path", "menu", "refresh", "cap", "performance", "foveation", "relief", "render_scale", "inference"]
const COUNTERS := ["decoder_drops", "vo_drops", "vo_late"]

var _start_ms := -1
var _start := {}
var _latest := {}
var _state := {}
var _seeks := 0
var _mixed := false
var _cache_ticks := 0
var _since_seek_ms := -1
var _seek_serial := -1
var _last_seek_ms := -1

## One call per sample, with an empty sample while not playing. Returns the event details of a closed window, or {}.
func tick(now_ms: int, sample: Dictionary) -> Dictionary:
	if sample.is_empty():
		var closed := _finish(now_ms) if _start_ms >= 0 and now_ms - _start_ms >= MIN_WINDOW_MS else {}
		_start_ms = -1
		return closed
	var serial := int(sample.get("seek_serial", 0))
	var seek := _seek_serial >= 0 and serial != _seek_serial
	_seek_serial = serial
	if seek: _last_seek_ms = now_ms
	if _start_ms < 0:
		_begin(now_ms, sample, seek)
		return {}
	_latest = sample
	if sample.get("cache", false): _cache_ticks += 1
	var state := _state_of(sample)
	var changed := seek or state != _state
	var elapsed := now_ms - _start_ms
	if changed and elapsed < MIN_WINDOW_MS:
		_mixed = true
		_state = state
		if seek: _seeks += 1
		return {}
	if not changed and elapsed < WINDOW_MS: return {}
	var event := _finish(now_ms)
	_begin(now_ms, sample, seek)
	return event

func _state_of(sample: Dictionary) -> Dictionary:
	var state := {}
	for key in STATE_KEYS: state[key] = sample.get(key)
	return state

func _begin(now_ms: int, sample: Dictionary, seek: bool) -> void:
	_start_ms = now_ms
	_start = sample
	_latest = sample
	_state = _state_of(sample)
	_seeks = 1 if seek else 0
	_mixed = false
	_cache_ticks = 0
	_since_seek_ms = now_ms - _last_seek_ms if _last_seek_ms >= 0 else -1

func _finish(now_ms: int) -> Dictionary:
	var seconds := maxf(0.001, (now_ms - _start_ms) / 1000.0)
	var event := _state.duplicate()
	event["window_ms"] = now_ms - _start_ms
	# Counters restart with a new file: a negative step counts as none.
	for key in COUNTERS: event[key] = maxi(0, int(_latest.get(key, 0)) - int(_start.get(key, 0)))
	# A seek jumps the estimated frame number, so the rate is only known without one.
	var frames := int(_latest.get("frames", 0)) - int(_start.get("frames", 0))
	event["video_fps"] = snappedf(frames / seconds, 0.1) if _seeks == 0 and frames >= 0 else -1.0
	event["xr_fps"] = snappedf((int(_latest.get("xr_frames", 0)) - int(_start.get("xr_frames", 0))) / seconds, 0.1)
	event["container_fps"] = _latest.get("container_fps", "")
	event["avsync"] = _latest.get("avsync", "")
	event["cache_ticks"] = _cache_ticks
	event["seeks"] = _seeks
	event["since_seek_ms"] = _since_seek_ms
	event["mixed"] = _mixed
	return event
