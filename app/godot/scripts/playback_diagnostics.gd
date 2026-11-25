extends RefCounted
## Playback windows for exported diagnostics. A window closes every WINDOW_MS, or when the menu, display
## path or display policy changes, or on a seek, so undisturbed playback can be told from the rest:
## clean windows have menu "", seeks 0 and mixed false. Drop counts are increments within the window.

const WINDOW_MS := 10000
## Changes inside a shorter window join it and mark it mixed: held seeks must not flood the log.
const MIN_WINDOW_MS := 2000
const STATE_KEYS := ["path", "menu", "menu_layers", "refresh", "cap", "performance", "foveation", "relief", "render_scale", "inference", "picture"]
const COUNTERS := ["decoder_drops", "vo_drops", "vo_late", "menu_layer_repaints", "copy_failed"]
## The layer copy's last size and cost (picture quality mode): what each video frame cost on the GPU.
const LATEST_KEYS := ["copy_out", "copy_gpu_ms", "copy_draw_ms", "copy_window", "copy_deep"]
## Counts already collected by libmpv, the bridge and its post-draw callback in Release.
const EYE_COUNTERS := ["rendered", "published", "acquired", "captured_frames", "unique_post_draw_frames",
	"skipped", "producer_copy_deferred", "superseded_decoder_images", "decoder_recycle_waits", "copy_fence_waits",
	"producer_render_us", "producer_slow_renders"]

static func eye_sample(status: Dictionary, pair: Dictionary) -> Dictionary:
	var session := int(pair.get("session_id", 0))
	if session <= 0 or int(status.get("session_id", 0)) != session or status.get("layer", true): return {}
	var epoch := int(pair.get("source_epoch", 0))
	if epoch <= 0 or int(status.get("last_source_epoch", 0)) != epoch or not status.has("published"): return {}
	for key in ["source_width", "source_height", "width", "height"]:
		if int(pair.get(key, 0)) <= 0: return {}
	var sample := {"session": session, "epoch": epoch,
		"external": pair.get("color_target", "") == "external",
		"source": "%dx%d" % [int(pair.source_width), int(pair.source_height)],
		"output": "%dx%d" % [int(pair.width), int(pair.height)]}
	for key in EYE_COUNTERS:
		if status.has(key): sample[key] = int(status[key])
	return sample

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
	if _latest.has("copy_drawn"):
		event["copy_fps"] = snappedf(maxi(0, int(_latest.copy_drawn) - int(_start.get("copy_drawn", 0))) / seconds, 0.1)
		for key in LATEST_KEYS: event[key] = _latest.get(key)
	event["container_fps"] = _latest.get("container_fps", "")
	event["avsync"] = _latest.get("avsync", "")
	event["cache_ticks"] = _cache_ticks
	event["seeks"] = _seeks
	event["since_seek_ms"] = _since_seek_ms
	event["mixed"] = _mixed
	var first: Dictionary = _start.get("eye", {})
	var last: Dictionary = _latest.get("eye", {})
	if not first.is_empty() and not last.is_empty() and _seeks == 0 and not _mixed and _state.path != "L":
		var eye := {}
		for key in ["session", "epoch", "external", "source", "output"]:
			if first[key] != last[key]: return event
		for key in EYE_COUNTERS:
			if first.has(key) and last.has(key) and last[key] >= first[key]:
				eye[key] = int(last[key]) - int(first[key])
		for key in ["external", "source", "output"]: eye[key] = last[key]
		event["eye_output"] = eye
	return event
