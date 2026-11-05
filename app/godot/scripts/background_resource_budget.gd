extends RefCounted
## Optional work admission. Frame time is observed, never inferred from free RAM or device name.
## Android GLES uses the existing bridge's EXT GPU timer when Godot has no GPU timestamps.
const Methods := preload("res://scripts/platform_methods.gd")
const MIB := 1024 * 1024
var frame_reserve := 0.30
# A page change stalls one frame by itself; measured background photo inference on Quest 3 left
# stale frames at the idle level, so a short settle is enough and 2 s + 1 s only delayed every page.
var stable_seconds := 0.5
var cooldown_seconds := 0.25
const MIN_SAMPLES := 30
var policy := {}
var poll_at := 0
var stable := 0.0
var cooldown := 0.0
var samples := 0
var _viewport := RID()
var _cpu := PackedFloat32Array()
var _gpu := PackedFloat32Array()
var _frames := PackedFloat32Array()
var _assess_seconds := 0.0
var _last_frame_usec := 0
var _native_platform: Object
var _native_generation := 0
var _native_gpu := 0.0
var _native_gpu_at := 0
var _native_status := 0.0
var _native_updates := 0
var gpu_source := "unavailable"
var reason := "starting"

func tick(owner: Node, delta: float, enabled: bool) -> void:
	if not enabled or not Methods.supports(owner.platform, "background_resource_policy"):
		stop(); return
	if Time.get_ticks_msec() >= poll_at:
		poll_at = Time.get_ticks_msec() + 1000
		var value: Variant = JSON.parse_string(owner.platform.background_resource_policy())
		policy = value if value is Dictionary else {}
	var viewport: RID = owner.get_viewport().get_viewport_rid()
	if _viewport != viewport:
		stop_measurement()
		_viewport = viewport
		RenderingServer.viewport_set_measure_render_time(_viewport, true)
	var rate := refresh_rate()
	if not is_finite(rate) or rate <= 0.0: rate = 90.0
	var now := Time.get_ticks_usec()
	var elapsed := frame_interval(delta)
	# TIME_PROCESS can include frame pacing/XR waits; use measured render CPU time instead.
	# Other main-thread congestion is caught by the actual frame intervals below.
	var times := render_times(_viewport)
	var gpu := times.y
	if gpu > 0:
		gpu_source = "godot"; _stop_native()
	else:
		_start_native(owner.platform)
		if _native_gpu > 0 and now - _native_gpu_at < 250000:
			gpu = _native_gpu; gpu_source = "gles_timer"
		else: gpu_source = "unavailable"
	observe(times.x, gpu, elapsed * 1000.0,
		1000.0 / rate, elapsed)

func render_times(viewport: RID) -> Vector2:
	return Vector2(RenderingServer.get_frame_setup_time_cpu() + RenderingServer.viewport_get_measured_render_time_cpu(viewport),
		RenderingServer.viewport_get_measured_render_time_gpu(viewport))

func frame_interval(delta: float) -> float:
	var now := Time.get_ticks_usec()
	var elapsed := (now - _last_frame_usec) / 1000000.0 if _last_frame_usec > 0 else delta
	_last_frame_usec = now
	return elapsed

func refresh_rate() -> float:
	var xr := XRServer.find_interface("OpenXR") as OpenXRInterface
	return xr.display_refresh_rate if xr and xr.is_initialized() else 90.0

func _start_native(platform: Object) -> void:
	if _native_platform == platform or not Methods.supports(platform, "background_gpu_timing"): return
	_stop_native(); _native_platform = platform
	RenderingServer.frame_pre_draw.connect(_frame_begin)
	RenderingServer.frame_post_draw.connect(_frame_end)

func _frame_begin() -> void: _queue_native(1)
func _frame_end() -> void: _queue_native(0)

func _queue_native(action: int) -> void:
	var platform := _native_platform
	var generation := _native_generation
	# Frame signals may be emitted on the main thread. Queue around the renderer's draw,
	# and deliver the result back to the main thread before touching budget state.
	RenderingServer.call_on_render_thread(func():
		if not is_instance_valid(platform): return
		var value := float(platform.background_gpu_timing(action))
		if action == 1: _accept_native.call_deferred(value, generation))

func _accept_native(value: float, generation: int) -> void:
	if generation != _native_generation: return
	_native_status = value; _native_updates += 1
	if is_finite(value) and value > 0:
		_native_gpu = value; _native_gpu_at = Time.get_ticks_usec()
	elif not is_finite(value) or value < 0: _native_gpu = 0; _native_gpu_at = 0

func _stop_native() -> void:
	if _native_platform == null: return
	if RenderingServer.frame_pre_draw.is_connected(_frame_begin): RenderingServer.frame_pre_draw.disconnect(_frame_begin)
	if RenderingServer.frame_post_draw.is_connected(_frame_end): RenderingServer.frame_post_draw.disconnect(_frame_end)
	var platform := _native_platform
	_native_platform = null; _native_generation += 1; _native_gpu = 0; _native_gpu_at = 0
	_native_status = 0.0; _native_updates = 0
	RenderingServer.call_on_render_thread(func():
		if is_instance_valid(platform): platform.background_gpu_timing(-1))

func observe(cpu_ms: float, gpu_ms: float, frame_ms: float, target_ms: float, delta: float) -> void:
	cooldown = maxf(0.0, cooldown - delta)
	var valid := is_finite(cpu_ms) and is_finite(gpu_ms) and is_finite(frame_ms) and target_ms > 0.0 \
		and cpu_ms > 0.0 and gpu_ms > 0.0
	if not valid or not policy.get("work", false) or frame_ms > target_ms * 2.0:
		reason = "gpu_unavailable" if not is_finite(gpu_ms) or gpu_ms <= 0 else ("resources" if not policy.get("work", false) else "frame_stall")
		_cpu.clear(); _gpu.clear(); _frames.clear(); _assess_seconds = 0.0
		defer_work(); return
	_cpu.append(cpu_ms / target_ms); _gpu.append(gpu_ms / target_ms); _frames.append(frame_ms / target_ms)
	if _cpu.size() > 90:
		_cpu.remove_at(0); _gpu.remove_at(0); _frames.remove_at(0)
	_assess_seconds += delta; samples += 1
	if _cpu.size() < MIN_SAMPLES or _assess_seconds < 0.25: return
	# A rolling p95 tolerates an isolated scheduling blip without admitting sustained overload.
	var safe := _p95(_cpu) <= 1.0 - frame_reserve and _p95(_gpu) <= 1.0 - frame_reserve and _p95(_frames) <= 1.25
	if safe:
		stable += _assess_seconds; reason = "ready" if stable >= stable_seconds and cooldown <= 0 else "settling"
	else:
		reason = "frame_budget"; defer_work()
	_assess_seconds = 0.0

static func _p95(values: PackedFloat32Array) -> float:
	var sorted := values.duplicate(); sorted.sort()
	return sorted[mini(sorted.size() - 1, int(sorted.size() * 0.95))]

func defer_work() -> void:
	stable = 0.0; samples = 0; cooldown = cooldown_seconds

## Memory admission only: for the next stage of work already admitted moments ago.
func can_continue(peak_bytes: int, resident_addition: int = 0) -> bool:
	return policy.get("work", false) and peak_bytes > 0 and int(policy.get("spare_bytes", 0)) >= peak_bytes + resident_addition

func can_start(peak_bytes: int, resident_addition: int = 0) -> bool:
	return policy.get("work", false) and stable >= stable_seconds and samples >= MIN_SAMPLES and cooldown <= 0.0 \
		and peak_bytes > 0 and int(policy.get("spare_bytes", 0)) >= peak_bytes + resident_addition

func resident_limit(current_bytes: int) -> int:
	if not policy.get("retain", false): return 0
	# Existing residents are already charged to availMem; avoid counting them a second time.
	return mini(int(policy.get("cache_limit", 0)), current_bytes + int(policy.get("spare_bytes", 0)) / 4)

func report() -> Dictionary:
	return {"reason":reason,"gpu_source":gpu_source,"stable_s":snappedf(stable,.01),"cooldown_s":snappedf(cooldown,.01),
		"native_status":_native_status,"native_updates":_native_updates,
		"samples":samples,"cpu_p95":_p95(_cpu) if not _cpu.is_empty() else 0,"gpu_p95":_p95(_gpu) if not _gpu.is_empty() else 0,
		"frame_p95":_p95(_frames) if not _frames.is_empty() else 0,
		"spare_bytes":int(policy.get("spare_bytes",0)),"work":bool(policy.get("work",false)),"retain":bool(policy.get("retain",false))}

## [model]: charge building the photo model; Android reports photo_model_ready while it is resident.
static func photo_cost(width: int, height: int, model: bool = true) -> Dictionary:
	if width <= 0 or height <= 0: return {}
	var ratio := minf(1.0, minf(4096.0 / maxi(width, height), sqrt(8.0 * MIB / float(width) / height)))
	var pixels := maxi(1, int(width * ratio)) * maxi(1, int(height * ratio))
	# Matches BackgroundResourceBudget.photoPeak: measured ~130 MB for an 8 MP spread, charged 2-3x.
	return {"peak":(512 * MIB if model else 0) + pixels * 48, "resident":ceili(pixels * 32.0 / 3.0) + 2 * MIB}

func stop_measurement() -> void:
	_stop_native()
	if _viewport.is_valid(): RenderingServer.viewport_set_measure_render_time(_viewport, false)
	_viewport = RID()

func stop() -> void:
	stop_measurement()
	policy = {}; poll_at = 0; stable = 0.0; samples = 0; cooldown = 0.0
	_cpu.clear(); _gpu.clear(); _frames.clear(); _assess_seconds = 0.0
	_last_frame_usec = 0
