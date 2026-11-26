extends RefCounted
## Where a slow frame goes, for exported diagnostics. A window is reported only while the frame
## rate stays well under the display's; the first slow window switches render timing on, so a
## healthy device never pays for it. frame_ms minus process, setup and render is time spent
## outside Godot's own work (the runtime's frame wait and buffer submission).

const WINDOW_USEC := 10000000
const SLOW := 0.75

var _start := 0
var _last := 0
var _frames := 0
var _worst := 0
var _process := 0.0
var _setup := 0.0
var _render_cpu := 0.0
var _render_gpu := 0.0
var _timed := false

## One call per frame. Returns the event details of a slow window, or {}.
func tick(viewport: Viewport, refresh: float, context: Dictionary) -> Dictionary:
	if viewport == null: return {}
	var now := Time.get_ticks_usec()
	# The first frame, or back from a pause: a new window.
	if _last == 0 or now - _last > 1000000:
		_begin(now)
		return {}
	_worst = maxi(_worst, now - _last)
	_last = now
	_frames += 1
	_process += Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
	_setup += RenderingServer.get_frame_setup_time_cpu()
	var rid := viewport.get_viewport_rid()
	if _timed:
		_render_cpu += RenderingServer.viewport_get_measured_render_time_cpu(rid)
		_render_gpu += RenderingServer.viewport_get_measured_render_time_gpu(rid)
	if now - _start < WINDOW_USEC: return {}
	var fps := _frames * 1000000.0 / (now - _start)
	var event := {}
	if refresh > 1.0 and fps < refresh * SLOW:
		event = {"fps": snappedf(fps, 0.1), "refresh": snappedf(refresh, 0.1), "frame_ms": snappedf(1000.0 / fps, 0.1),
			"worst_ms": snappedf(_worst / 1000.0, 0.1), "process_ms": snappedf(_process / _frames, 0.01),
			"setup_ms": snappedf(_setup / _frames, 0.01), "render_cpu_ms": snappedf(_render_cpu / _frames, 0.01),
			"render_gpu_ms": snappedf(_render_gpu / _frames, 0.01), "render_timed": _timed}
		event.merge(context)
		if not _timed:
			_timed = true
			RenderingServer.viewport_set_measure_render_time(rid, true)
	_begin(now)
	return event

func _begin(now: int) -> void:
	_start = now; _last = now; _frames = 0; _worst = 0
	_process = 0.0; _setup = 0.0; _render_cpu = 0.0; _render_gpu = 0.0
