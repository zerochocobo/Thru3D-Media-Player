extends Node
## Debug-only frame cost sample: engine frame deltas, script process time and render counts over a
## fixed window, logged as one [PERF_SAMPLE] line and saved as diagnostics/perf_sample_<label>.json.
## Changes nothing; device A/B runs pair it with VrApi stale-frame counts.
var label := ""
var seconds := 10.0
var _elapsed := 0.0
var _deltas := PackedFloat32Array()
var _script_ms := PackedFloat32Array()
var _objects := 0.0
var _draws := 0.0
var _primitives := 0.0
var _repaints := 0

func start(run_label: String, run_seconds: float) -> void:
	label = run_label; seconds = clampf(run_seconds, 1.0, 120.0)
	process_priority = 1000
	var composition: Node = get_parent().get("menu_composition")
	_repaints = composition.repaints if composition else 0

func _process(delta: float) -> void:
	_elapsed += delta
	_deltas.append(delta * 1000.0)
	_script_ms.append(Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0)
	_objects += Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)
	_draws += Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
	_primitives += Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)
	if _elapsed >= seconds: _finish()

static func _stats(values: PackedFloat32Array) -> Dictionary:
	var sorted := values.duplicate(); sorted.sort()
	var count := sorted.size()
	if count == 0: return {}
	var total := 0.0
	for value in sorted: total += value
	return {"mean": snappedf(total / count, 0.01), "p50": snappedf(sorted[count / 2], 0.01),
		"p90": snappedf(sorted[int(count * 0.9)], 0.01), "p99": snappedf(sorted[mini(count - 1, int(count * 0.99))], 0.01),
		"p95": snappedf(sorted[mini(count - 1, int(count * 0.95))], 0.01),
		"max": snappedf(sorted[count - 1], 0.01)}

func _finish() -> void:
	set_process(false)
	var frames := _deltas.size()
	var target := 1000.0 / maxf(1.0, Engine.get_frames_per_second())
	var xr := XRServer.find_interface("OpenXR") as OpenXRInterface
	if xr and xr.is_initialized() and xr.display_refresh_rate > 0.0: target = 1000.0 / xr.display_refresh_rate
	var late := 0
	for value in _deltas: late += int(value > target * 1.5)
	var composition: Node = get_parent().get("menu_composition")
	var report := {"label": label, "seconds": snappedf(_elapsed, 0.01), "frames": frames,
		"refresh_ms": snappedf(target, 0.01), "late_frames": late, "delta_ms": _stats(_deltas),
		"process_ms": _stats(_script_ms), "objects": snappedf(_objects / maxi(frames, 1), 0.1),
		"draw_calls": snappedf(_draws / maxi(frames, 1), 0.1), "primitives": roundi(_primitives / maxi(frames, 1)),
		"nodes": int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)),
		"menu_repaints": (composition.repaints - _repaints) if composition else -1}
	var encoded := JSON.stringify(report)
	print("[PERF_SAMPLE] " + encoded)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("user://diagnostics"))
	var file := FileAccess.open("user://diagnostics/perf_sample_%s.json" % label, FileAccess.WRITE)
	if file: file.store_string(encoded)
	queue_free()
