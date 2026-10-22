class_name XrDisplay extends RefCounted

signal status_changed

var xr: XRInterface
var viewport: Viewport
var environment: Environment
var preview := true
var requested_passthrough := false
var applied_passthrough := false
var session_state := "uninitialized"
var error_code := ""
var render_scale := 1.0
var scenery: Sky
var scenery_rotation := Vector3.ZERO
## The video is on a compositor layer beneath the eye buffers: they render transparent (only then does
## Godot's blending keep correct alpha over the hole) and the backdrop draws the sky instead.
var video_layer := false
var menu_layers := false
var backdrop: MeshInstance3D
const BACKDROP_RADIUS := 900.0

## parent: the XR camera, so the backdrop sphere stays centred on the eyes.
func attach_backdrop(parent: Node3D) -> void:
	backdrop = MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = BACKDROP_RADIUS
	sphere.height = BACKDROP_RADIUS * 2.0
	backdrop.mesh = sphere
	var material := ShaderMaterial.new()
	material.shader = preload("res://shaders/layer_backdrop.gdshader")
	backdrop.material_override = material
	backdrop.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	backdrop.visible = false
	parent.add_child(backdrop)

func set_video_layer(active: bool) -> void:
	if active == video_layer: return
	video_layer = active
	if environment: _set_background(applied_passthrough)

func set_menu_layers(active: bool) -> void:
	if active == menu_layers: return
	menu_layers = active
	if environment: _set_background(applied_passthrough)

func set_scenery(value: Sky, yaw_degrees: float = 0.0) -> void:
	scenery = value
	# PanoramaSkyMaterial puts the texture seam along the viewer's default -Z axis.
	# Treat 0 degrees as the image centre facing forward; keep user rotation relative to it.
	scenery_rotation = Vector3(0, deg_to_rad(yaw_degrees) + PI, 0)
	if environment: _set_background(applied_passthrough)

func configure(target_viewport: Viewport, target_environment: Environment, interface: XRInterface, desktop_preview: bool) -> bool:
	viewport = target_viewport
	environment = target_environment
	xr = interface
	preview = desktop_preview
	_set_background(false)
	if preview:
		session_state = "desktop_preview"
		status_changed.emit()
		return true
	if xr != null and "render_target_size_multiplier" in xr:
		xr.render_target_size_multiplier = render_scale
	if xr == null or (not xr.is_initialized() and not xr.initialize()):
		error_code = "XR_INITIALIZATION_FAILED"
		session_state = "failed"
		DiagnosticLog.record("xr_initialization_failed")
		status_changed.emit()
		return false
	viewport.use_xr = true
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	for event in ["session_begun", "session_focussed", "session_visible", "session_synchronized", "session_stopping", "session_loss_pending", "instance_exiting"]:
		if xr.has_signal(event):
			xr.connect(event, _on_session_event.bind(event))
	if xr.has_signal("user_presence_changed"):
		xr.connect("user_presence_changed", _on_presence_changed)
	session_state = "initialized"
	DiagnosticLog.record("xr_initialized", capabilities())
	status_changed.emit()
	return true

func supports_passthrough() -> bool:
	return not preview and xr != null and xr.is_initialized() and XRInterface.XR_ENV_BLEND_MODE_ALPHA_BLEND in xr.get_supported_environment_blend_modes()

func set_passthrough(enabled: bool) -> bool:
	if enabled and not supports_passthrough():
		error_code = "XR_PASSTHROUGH_UNAVAILABLE"
		DiagnosticLog.record("display_mode_rejected", {"requested": enabled, "reason": error_code})
		status_changed.emit()
		return false
	requested_passthrough = enabled
	return _apply_requested_mode()

func _apply_requested_mode() -> bool:
	if xr != null and xr.is_initialized() and not preview:
		var mode := XRInterface.XR_ENV_BLEND_MODE_ALPHA_BLEND if requested_passthrough else XRInterface.XR_ENV_BLEND_MODE_OPAQUE
		xr.environment_blend_mode = mode
		if xr.environment_blend_mode != mode:
			error_code = "XR_BLEND_MODE_REJECTED"
			DiagnosticLog.record("display_mode_rejected", {"requested": requested_passthrough, "reason": error_code})
			status_changed.emit()
			return false
	_set_background(requested_passthrough)
	applied_passthrough = requested_passthrough
	error_code = ""
	DiagnosticLog.record("display_mode_applied", {"passthrough": applied_passthrough, "session": session_state})
	status_changed.emit()
	return true

func _set_background(transparent: bool) -> void:
	var layer := (video_layer or menu_layers) and not preview
	viewport.transparent_bg = transparent or layer
	environment.sky = null if transparent or layer else scenery
	environment.sky_rotation = scenery_rotation
	# Meta reconstruction passthrough needs a transparent environment color too.
	# BG_CLEAR_COLOR inherits the project's opaque dark clear color.
	environment.background_mode = Environment.BG_SKY if scenery and not transparent and not layer else Environment.BG_COLOR
	environment.background_color = Color(0, 0, 0, 0) if transparent or layer else Color(0.035, 0.045, 0.06, 1.0)
	if backdrop:
		backdrop.visible = layer and not transparent
		var material := backdrop.material_override as ShaderMaterial
		var sky_material := scenery.sky_material as PanoramaSkyMaterial if scenery else null
		var panorama: Texture2D = sky_material.panorama if sky_material else null
		material.set_shader_parameter("has_panorama", panorama != null)
		material.set_shader_parameter("panorama", panorama)
		material.set_shader_parameter("energy_multiplier", sky_material.energy_multiplier if sky_material else 1.0)
		# Godot samples the sky with the inverse sky rotation applied to the world direction.
		material.set_shader_parameter("orientation", Basis.from_euler(scenery_rotation).inverse())

func _on_session_event(event: String) -> void:
	session_state = event
	DiagnosticLog.record(event, {"requested_passthrough": requested_passthrough})
	if event in ["session_begun", "session_focussed"]:
		# Reapply the user's mode after session resume; do not destroy the runtime.
		_apply_requested_mode()
		apply_performance_levels()
		_requested_refresh = 0.0
		_apply_refresh()
	status_changed.emit()

# Playback and photo depth request sustained-high CPU/GPU levels (GPU inference and network demux
# are invisible to the runtime's frame timing). Menus and idle request sustained-low: the Quest 3
# idle menu then runs at levels 2/1 instead of 4/4.
var performance_levels := "default"
# Fixed foveated rendering for the eye buffers (0 off .. 3 high); the 8K video is sampled
# for every eye pixel at the display rate, so the periphery is a large bandwidth cost.
var foveation_level := 0
func set_foveation(level: int) -> void:
	foveation_level = clampi(level, 0, 3)
	_apply_foveation()

func _apply_foveation() -> void:
	if xr is OpenXRInterface and xr.is_initialized() and "foveation_level" in xr:
		xr.foveation_dynamic = false
		xr.foveation_level = foveation_level
		DiagnosticLog.record("xr_foveation", {"level": foveation_level, "applied": xr.foveation_level})
## Debug A/B only: one of PERFORMANCE_LEVELS' keys.
var debug_performance_level := ""
var performance_demand := false
func set_performance_demand(high: bool) -> void:
	if high == performance_demand: return
	performance_demand = high
	if xr != null and xr.is_initialized(): apply_performance_levels()
const PERFORMANCE_LEVELS := {"power_savings": OpenXRInterface.PERF_SETTINGS_LEVEL_POWER_SAVINGS,
	"sustained_low": OpenXRInterface.PERF_SETTINGS_LEVEL_SUSTAINED_LOW,
	"sustained_high": OpenXRInterface.PERF_SETTINGS_LEVEL_SUSTAINED_HIGH,
	"boost": OpenXRInterface.PERF_SETTINGS_LEVEL_BOOST}
func apply_performance_levels() -> void:
	if not (xr is OpenXRInterface) or not xr.has_method("set_gpu_level"):
		performance_levels = "unsupported"
		return
	var fallback := "sustained_high" if performance_demand else "sustained_low"
	var level := debug_performance_level if PERFORMANCE_LEVELS.has(debug_performance_level) else fallback
	xr.set_cpu_level(PERFORMANCE_LEVELS[level])
	xr.set_gpu_level(PERFORMANCE_LEVELS[level])
	performance_levels = level
	_apply_foveation()
	DiagnosticLog.record("xr_performance_levels", {"cpu": performance_levels, "gpu": performance_levels})

## Wanted display refresh rate; 0 is the menu rate: the lowest rate from 72 Hz, the cheapest for the
## compositor menu layers (the runtime otherwise keeps whatever rate the app last requested).
var refresh_preference := 0.0
## The runtime switches rates asynchronously, so its reported rate can still be the old one right
## after a request; compare against the last request and re-request if the runtime diverges.
var _requested_refresh := 0.0
var _requested_ms := 0
const REFRESH_RETRY_MS := 2000
func set_refresh_preference(rate: float) -> void:
	if is_equal_approx(rate, refresh_preference): return
	refresh_preference = rate
	_apply_refresh()

## Debug A/B only: a fixed rate that wins over the policy (0 = policy).
var debug_refresh := 0.0
func set_debug_refresh(rate: float) -> void:
	debug_refresh = rate; _requested_refresh = 0.0; _apply_refresh()

func _apply_refresh() -> void:
	if not (xr is OpenXRInterface) or not xr.is_initialized() or preview: return
	var rate := refresh_preference if refresh_preference > 0.0 else menu_refresh_rate(available_refresh_rates())
	if debug_refresh > 0.0: rate = debug_refresh
	if rate <= 0.0 or is_equal_approx(rate, _requested_refresh): return
	_requested_refresh = rate; _requested_ms = Time.get_ticks_msec()
	if not is_equal_approx(rate, xr.display_refresh_rate): set_refresh_rate(rate)

## Called every frame: repeats the last request while the runtime reports another rate.
func check_refresh() -> void:
	if _requested_refresh <= 0.0 or not (xr is OpenXRInterface) or not xr.is_initialized() or preview: return
	if is_equal_approx(xr.display_refresh_rate, _requested_refresh): return
	if Time.get_ticks_msec() - _requested_ms < REFRESH_RETRY_MS: return
	_requested_ms = Time.get_ticks_msec()
	set_refresh_rate(_requested_refresh)

func available_refresh_rates() -> Array:
	if not (xr is OpenXRInterface) or not xr.is_initialized() or preview: return []
	return xr.get_available_display_refresh_rates()

static func menu_refresh_rate(available: Array) -> float:
	var rates: Array = available.map(func(rate): return float(rate)).filter(func(rate): return rate >= 71.5)
	rates.sort()
	return rates[0] if not rates.is_empty() else 0.0

## Display rate for a video: the lowest rate up to [cap] Hz showing every frame for the same number
## of refreshes (24 -> 72, 30 -> 90, 60 -> 120 Hz). Without one, a 120 Hz cap shortens the uneven
## repeats with the fastest panel; lower caps keep the menu rate.
static func video_refresh_rate(fps: float, available: Array, cap: float) -> float:
	if not is_finite(fps) or fps < 10.0 or fps > 130.0: return 0.0
	var rates: Array = available.map(func(rate): return float(rate)).filter(func(rate): return rate >= 59.5 and rate <= cap + 0.5)
	rates.sort()
	for rate in rates:
		var repeats := roundf(rate / fps)
		if repeats >= 1.0 and absf(rate - repeats * fps) <= rate * 0.005: return rate
	return rates[-1] if cap > 90.5 and not rates.is_empty() else 0.0

## Display refresh rate; unsupported rates are ignored.
func set_refresh_rate(rate: float) -> bool:
	if not (xr is OpenXRInterface) or not xr.is_initialized() or preview: return false
	var chosen := 0.0
	for available in xr.get_available_display_refresh_rates():
		if absf(float(available) - rate) < 0.5: chosen = float(available)
	if chosen <= 0.0: return false
	xr.display_refresh_rate = chosen
	DiagnosticLog.record("xr_refresh_rate", {"requested": rate, "applied": xr.display_refresh_rate})
	return true

func _on_presence_changed(present: bool) -> void:
	DiagnosticLog.record("user_presence_changed", {"present": present})

func capabilities() -> Dictionary:
	var report := {
		"preview": preview,
		"session_state": session_state,
		"requested_passthrough": requested_passthrough,
		"applied_passthrough": applied_passthrough,
		"error_code": error_code,
		"initialized": xr != null and xr.is_initialized(),
		"supported_blend_modes": [],
		"passthrough_supported": supports_passthrough(),
		"viewport_use_xr": viewport != null and viewport.use_xr,
		"viewport_transparent_bg": viewport != null and viewport.transparent_bg,
		"performance_levels": performance_levels,
		"foveation_level": foveation_level,
		"render_scale": render_scale,
		"menu_layers": menu_layers,
		# Vendors can shrink the actual render region without changing the allocated eye buffers.
		"meta_dynamic_resolution_enabled": bool(ProjectSettings.get_setting("xr/openxr/extensions/meta/dynamic_resolution", true)),
		"render_target_size_scope": "allocated_eye_buffer",
		"viewport_scaling_3d_scale": viewport.scaling_3d_scale if viewport else 1.0,
		"captured_ticks_usec": Time.get_ticks_usec(),
	}
	if xr != null and xr.is_initialized() and not preview:
		var target_size := xr.get_render_target_size()
		report["render_target_size"] = [int(target_size.x), int(target_size.y)]
		report["system_info"] = xr.get_system_info()
		report["view_count"] = xr.get_view_count()
		report["tracking_status"] = xr.get_tracking_status()
		report["tracking_status_enum_valid"] = int(report["tracking_status"]) in [0, 1, 2, 3, 4]
		# Godot 4.7.2's OpenXR tracking_state is not assigned in the upstream
		# implementation. Use the registered head pose to assess live tracking.
		var head := XRServer.get_tracker("head") as XRPositionalTracker
		report["head_tracker_registered"] = head != null
		if head != null:
			var head_pose := head.get_pose("default")
			if head_pose != null:
				report["head_has_tracking_data"] = head_pose.has_tracking_data
				report["head_tracking_confidence"] = head_pose.tracking_confidence
				report["head_position"] = [head_pose.transform.origin.x, head_pose.transform.origin.y, head_pose.transform.origin.z]
		report["actual_blend_mode"] = xr.environment_blend_mode
		report["eye_origins"] = []
		report["eye_quaternions"] = []
		for eye in range(xr.get_view_count()):
			var pose := xr.get_transform_for_view(eye, Transform3D.IDENTITY)
			var orientation := pose.basis.get_rotation_quaternion()
			report["eye_origins"].append([pose.origin.x, pose.origin.y, pose.origin.z])
			report["eye_quaternions"].append([orientation.x, orientation.y, orientation.z, orientation.w])
		report["supported_blend_modes"] = xr.get_supported_environment_blend_modes()
		if xr is OpenXRInterface:
			report["applied_render_scale"] = xr.render_target_size_multiplier
			report["applied_foveation_level"] = xr.foveation_level
			report["refresh_rates"] = xr.get_available_display_refresh_rates()
			report["refresh_rate"] = xr.display_refresh_rate
	if not preview and Engine.has_singleton("OpenXRFbPassthroughExtension"):
		var fb := Engine.get_singleton("OpenXRFbPassthroughExtension")
		report["fb_passthrough_supported"] = fb.is_passthrough_supported()
		report["fb_passthrough_started"] = fb.is_passthrough_started()
		report["color_passthrough_capability"] = fb.has_color_passthrough_capability()
	return report

