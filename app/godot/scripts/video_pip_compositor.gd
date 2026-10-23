extends RefCounted
## A single native atlas is redrawn only for a new leased frame or crop/effect change.
## Native sampling is generated from the production pair shaders, including both eyes' masks.
const Layer := preload("res://scripts/video_layer.gd")
const Methods := preload("res://scripts/platform_methods.gd")
const Edges := preload("res://scripts/video_pip_edges.gd")
var surface_background := false # Set only for an actual transparent projection background.
var _surface_mask_size := Vector2i.ZERO
var _surface_mask_key := PackedFloat32Array()
var _surface_mask_generation := -1
var _surface_failed_generation := -1
var _pending_cuts := {}
const COMMON := ["video_geometry", "stereo_sbs", "top_bottom", "stereo_half", "swap_eyes", "viewing_eye",
	"rotation_degrees", "fisheye_fov", "source_size", "color_uv_scale", "stereo_offset", "alpha_enabled",
	"depth_enabled", "depth_shift", "depth_convergence", "alpha_edge", "model_size", "model_content_rect",
	"packed_alpha", "packed_size", "packed_color", "grade_enabled", "grade_gain", "grade_gamma", "grade_offset",
	"grade_contrast", "grade_saturation", "sharpness"]
const WINDOW := ["pip_center", "pip_span", "pip_forward", "pip_right", "pip_up", "pip_tangent", "pip_viewing_eye"]
var _manager_ref: WeakRef
var manager: RefCounted:
	get: return _manager_ref.get_ref()
var enabled := true
var size := Vector2i.ZERO
var tile := Vector2i.ZERO
var _generation := -1
var _frame := []
var _common := PackedFloat32Array()
var _windows := PackedFloat32Array()
var _mask := 0
var _eyes := 0
var pending: Array[int] = []
var width := 512
var density := 26.0
var quality := preload("res://scripts/video_pip_quality.gd").new()
var metrics := {"cpu_us": 0, "gpu_p95_us": 0, "gpu_samples": 0}
var samples := ""
var main_samples := ""
var _sample_pending := false
var main_size := Vector2i.ZERO
var main_ready := false
var main_cost_fallback := false
var main_eyes := 1
var _main_frame := []
var _main_common := PackedFloat32Array()
var _main_generation := -1
var _main_failed_generation := -1
var _main_retry_after := 0
var _main_cost_frames := 0
var _avoid_main := PackedFloat32Array()
var _avoid_generation := -1
var _metrics_after := 0
var _frame_ms: Array[float] = []
var draws := 0
var fallback := ""
var failed_generation := -1
var retry_after := 0

func _init(pip: RefCounted) -> void:
	_manager_ref = weakref(pip)

static func append_value(output: PackedFloat32Array, value: Variant) -> void:
	if value is Vector2: output.append_array(PackedFloat32Array([value.x, value.y]))
	elif value is Vector3: output.append_array(PackedFloat32Array([value.x, value.y, value.z]))
	elif value is Vector4: output.append_array(PackedFloat32Array([value.x, value.y, value.z, value.w]))
	else: output.append(float(value))

static func parameters(material: ShaderMaterial, names: Array) -> PackedFloat32Array:
	var values := PackedFloat32Array()
	for key in names:
		var value: Variant = material.get_shader_parameter(key)
		if key == "color_uv_scale" and value == null: value = Vector2.ONE
		if value == null:
			value = RenderingServer.shader_get_parameter_default(material.shader.get_rid(), key)
		if value == null: return PackedFloat32Array()
		append_value(values, value)
	return values

func direct_compatible(count: int = -1) -> bool:
	if not enabled: return false
	var video: Node3D = manager.owner
	var layer: RefCounted = video.get("video_layer")
	if not layer or not layer.pip_supported() or not layer._types.get("quad", false): return false
	if not surface_background or not layer.alpha_blend or _surface_failed_generation == layer.generation: return false
	if not Methods.supports(video.platform, "render_pip_feather_mask"): return false
	if manager.video_windows().size() != manager.windows.size(): return false
	if layer.runtime_image_size.x < Edges.MASK_TILE + 4 or layer.runtime_image_size.y < (Edges.MASK_TILE + 4) * 3: return false
	if video.geometry != 0 or video.alpha_requested or video.depth_requested or video.packed_file: return false
	if int(video.media.format.get("source_rotation_degrees", 0)) != 0 or video.stereo_offset_uv() != Vector2.ZERO: return false
	var eyes := 1
	var total: int = manager.video_windows().size() if count < 0 else count
	# Main eyes + a subtitle are reserved even if no cue is currently visible.
	return layer.capacity() >= (2 if video.stereo_sbs else 1) + 1 + total * eyes * 2

func window_eyes(_window: Node3D) -> int:
	return 1 # One selected source eye, shown to BOTH display eyes.

func _surface_extras(origin: Node3D, occupied: int) -> Array:
	var video: Node3D = manager.owner
	var layer: RefCounted = video.video_layer
	if not direct_compatible(): fallback = "surface_sampling"; return []
	if size != Vector2i.ZERO or main_size != Vector2i.ZERO: release()
	if not _prepare_surface_mask(): return _fail_surface()
	var image := Vector2(float(video.media.playback.get("layer_surface_width", Layer.SURFACE_SIZE)),
		float(video.media.playback.get("layer_surface_height", Layer.SURFACE_SIZE)))
	var source: PackedFloat32Array = layer.layer_values(video, origin, Layer.SURFACE, image)
	var required := 0
	for window in manager.video_windows(): required += window_eyes(window) * 2
	if occupied + required > layer.capacity(): fallback = "budget"; return []
	var extras: Array = []
	for slot in manager._stack:
		var window: Node3D = manager.windows[slot]
		if window.image_mode: continue
		var eyes := window_eyes(window)
		var span: Vector2 = window.crop_span()
		var center: Vector2 = manager.candidate.get("center", window.crop_center) if manager.selecting == slot else window.crop_center
		center = center.clamp(span / 2, Vector2.ONE - span / 2)
		for eye in eyes:
			var offset: int = eye * Layer.STRIDE
			var whole := Rect2(source[offset + 9], source[offset + 10], source[offset + 11], source[offset + 12])
			var rect := Rect2(whole.position + (center - span / 2) * whole.size, span * whole.size)
			var first := rect.position.ceil(); var last := rect.end.floor()
			rect = Rect2(first, last - first)
			var mask_rect := Rect2(2, (slot - 1) * (Edges.MASK_TILE + 4) + 2, Edges.MASK_TILE, Edges.MASK_TILE)
			var mask_values: PackedFloat32Array = layer.quad_values(origin, window.global_transform, window.size,
				Layer.PIP_SLOT, Vector2(_surface_mask_size), mask_rect, Layer.MASK_WRITE | Layer.SOURCE_ALPHA)
			mask_values[18] = 0 # Sharpening a coverage mask creates a halo.
			var order: int = Layer.PIP_ORDER + manager._stack.find(slot) * 2
			extras.append({"values": mask_values, "order": order, "group": slot})
			var values: PackedFloat32Array = layer.quad_values(origin, window.global_transform, window.size, 0, image, rect, Layer.MASKED, eye + 1 if eyes == 2 else 0)
			for index in range(17, 26): values[index] = source[offset + index]
			values[19] = Layer.SURFACE
			extras.append({"values": values, "order": order + 1, "group": slot})
		pending.append(slot)
	fallback = ""
	return extras

func _prepare_surface_mask() -> bool:
	var video: Node3D = manager.owner
	var layer: RefCounted = video.video_layer
	var key := PackedFloat32Array()
	for slot in [1, 2, 3]:
		var feather: Vector2 = manager.windows[slot].edge_feather() if manager.windows.has(slot) else Vector2.ONE * 0.02
		key.append_array(PackedFloat32Array([feather.x, feather.y]))
	var wanted := Vector2i(Edges.MASK_TILE + 4, (Edges.MASK_TILE + 4) * 3)
	if _surface_mask_size != wanted or _surface_mask_generation != layer.generation:
		if not video.platform.create_layer_image(Layer.PIP_SLOT, wanted.x, wanted.y, 1, false): return false
		layer.invalidate(); _surface_mask_size = wanted; _surface_mask_generation = layer.generation
		_surface_mask_key.clear()
	if key == _surface_mask_key: return true
	if video.platform.acquire_layer_image(Layer.PIP_SLOT) <= 0: return false
	var drawn: bool = video.platform.render_pip_feather_mask(Layer.PIP_SLOT, key)
	var released: bool = video.platform.release_layer_image(Layer.PIP_SLOT, false)
	if not drawn or not released: return false
	_surface_mask_key = key
	return true

func _release_surface_mask() -> void:
	if _surface_mask_size != Vector2i.ZERO:
		manager.owner.video_layer.invalidate()
		manager.owner.platform.destroy_layer_image(Layer.PIP_SLOT)
	_surface_mask_size = Vector2i.ZERO; _surface_mask_key.clear(); _surface_mask_generation = -1

func _fail_surface() -> Array:
	_surface_failed_generation = manager.owner.video_layer.generation
	_release_surface_mask(); pending.clear(); fallback = "surface_mask"
	return [] # Next layer presentation check reopens on the shared-texture path.

func release() -> void:
	commit(false, false)
	_release_surface_mask()
	if manager.video_windows().is_empty(): _surface_failed_generation = -1
	release_main()
	var video: Node3D = manager.owner
	if size != Vector2i.ZERO and video.get("video_layer"):
		video.video_layer.invalidate()
		if Methods.supports(video.platform, "destroy_layer_image"): video.platform.destroy_layer_image(Layer.PIP_SLOT)
	size = Vector2i.ZERO; tile = Vector2i.ZERO; _frame.clear(); _mask = 0; _generation = -1
	failed_generation = -1
	samples = ""; main_samples = ""; _sample_pending = false
	quality = preload("res://scripts/video_pip_quality.gd").new(); _frame_ms.clear()
	_avoid_main.clear(); _avoid_generation = -1
	main_cost_fallback = false

func needs_main() -> bool:
	var video: Node3D = manager.owner
	var material: ShaderMaterial = video._binding.material
	return enabled and not manager.video_windows().is_empty() and material != null and not video._binding.layer and (
		(material.get_shader_parameter("alpha_enabled") == true and material.get_shader_parameter("depth_enabled") != true)
		or material.get_shader_parameter("packed_alpha") == true)

## Opaque panoramas can use the same leased frame for a compositor main and mono
## crops. Keep this optional: a costly full-resolution copy may fall back alone,
## while its opaque PiP windows remain on their own compositor layers.
func prefers_main() -> bool:
	var video: Node3D = manager.owner
	var material: ShaderMaterial = video._binding.material
	return enabled and not manager.video_windows().is_empty() and video.geometry in [1, 3] and material != null \
		and not video._binding.layer and not video._binding.warped \
		and material.get_shader_parameter("alpha_enabled") != true \
		and material.get_shader_parameter("packed_alpha") != true \
		and material.get_shader_parameter("depth_enabled") != true

func release_main() -> void:
	main_ready = false
	var video: Node3D = manager.owner
	if main_size != Vector2i.ZERO and video.get("video_layer"):
		video.video_layer.invalidate()
		if Methods.supports(video.platform, "destroy_layer_image"): video.platform.destroy_layer_image(Layer.PICTURE_SLOT)
		video.video_layer.picture_size = Vector2.ZERO
	main_size = Vector2i.ZERO; _main_frame.clear(); _main_common.clear(); _main_generation = -1
	_main_cost_frames = 0
	_main_failed_generation = -1; _main_retry_after = 0

func main_dimensions(common: PackedFloat32Array) -> Vector2i:
	var eye_width := roundi(common[8] * (0.5 if bool(common[1]) and not bool(common[2]) else 1.0))
	var eye_height := roundi(common[9] * (0.5 if bool(common[1]) and bool(common[2]) else 1.0))
	var view := Vector2i(eye_width, eye_height)
	if int(common[0]) == 2:
		# Match the existing main fisheye cache's angular density. PiP crops still
		# sample the original leased source, independently of this main-view cache.
		view = Layer.fisheye_picture_size(view, Layer.fisheye_span(common[7]), false, false, Layer.FISHEYE_PIXELS_PER_DEGREE)
	return Vector2i(view.x * (2 if bool(common[1]) or bool(common[15]) else 1), view.y)

func prepare_main() -> bool:
	main_ready = false
	main_cost_fallback = false
	var video: Node3D = manager.owner
	var layer: RefCounted = video.get("video_layer")
	if (needs_main() and manager.video_windows().size() != manager.windows.size()) or not (needs_main() or prefers_main()) or not video.layer_enabled:
		release_main(); return false
	# Transparent native windows need the main video beneath them in the compositor;
	# otherwise an eye-buffer hole would erase that video's pixels behind transparent edges.
	if not layer or not layer.pip_supported() or not video.panel.visible: return false
	if _main_failed_generation == layer.generation and Time.get_ticks_msec() < _main_retry_after: return false
	if not layer.supports(1 if video.geometry == 2 else video.geometry, video.geometry == 0 and video.screen_curve > 0): return false
	var common := parameters(video._binding.material, COMMON)
	if common.size() != 43: return false
	if _avoid_generation == layer.generation and _avoid_main == common:
		main_cost_fallback = true; return false
	# If the extra full-resolution pass is costly, keep the shared-frame main
	# instead of repeatedly copying it or reducing the small windows' detail.
	# Only transparent windows need to join the main's fallback path.
	if _main_generation == layer.generation and common == _main_common and _main_cost_frames >= 60 \
		and int(metrics.get("main_gpu_samples", 0)) >= 60 and int(metrics.get("main_gpu_p95_us", 0)) > 1000000.0 / refresh_hz() * 0.35:
		release(); _avoid_main = common; _avoid_generation = layer.generation
		main_cost_fallback = true
		DiagnosticLog.record("pip_main_mesh_fallback", {"main_gpu_p95_us": metrics.get("main_gpu_p95_us", 0), "transparent": needs_main()})
		return false
	main_eyes = 2 if bool(common[1]) or bool(common[15]) else 1
	var required := 0
	for window in manager.video_windows(): required += window_eyes(window)
	# A native transparent hole would erase a lower eye-buffer window's pixels.
	# Keep the entire transparent group on one path, including its main and subtitle.
	if layer.capacity() < main_eyes + required + 1:
		release_main(); return false
	var wanted := main_dimensions(common)
	if wanted.x > layer.runtime_image_size.x or wanted.y > layer.runtime_image_size.y or wanted.x <= 0 or wanted.y <= 0: return false
	if main_size != wanted or _main_generation != layer.generation:
		if not video.platform.create_layer_image(Layer.PICTURE_SLOT, wanted.x, wanted.y, 1, false): return _fail_main()
		layer.invalidate(); layer.picture_size = Vector2(wanted); main_size = wanted; _main_frame.clear(); _main_generation = layer.generation
		_main_common.clear()
	var ticket: Dictionary = video._binding.ticket
	var frame := [layer.generation, ticket.get("session_id", 0), ticket.get("generation", 0), ticket.get("slot_token", 0), ticket.get("frame_id", 0)]
	if frame != _main_frame or common != _main_common:
		if common != _main_common:
			_main_cost_frames = 0
			metrics["main_gpu_samples"] = 0; metrics["main_gpu_p95_us"] = 0
		if video.platform.acquire_layer_image(Layer.PICTURE_SLOT) <= 0: return _fail_main()
		var color := RenderingServer.texture_get_native_handle(video._binding.color_texture())
		var matte := RenderingServer.texture_get_native_handle(video._binding.alpha_rid) if video._binding.alpha_rid.is_valid() else 0
		var unused := PackedFloat32Array(); unused.resize(48)
		var external: bool = str(ticket.get("color_target", "")) == "external" and not video._binding.warped
		var drawn: bool = video.platform.render_pip_atlas(Layer.PICTURE_SLOT, color, external, matte, 8, main_eyes, common, unused)
		var released: bool = video.platform.release_layer_image(Layer.PICTURE_SLOT, false)
		if not drawn or not released: return _fail_main()
		_main_frame = frame; _main_common = common
		_main_cost_frames += 1
	main_ready = true
	return true

func _fail_main() -> bool:
	_main_failed_generation = manager.owner.video_layer.generation
	_main_retry_after = Time.get_ticks_msec() + 2000; _main_frame.clear()
	return false

func commit(submitted: bool, attempted := true) -> void:
	if attempted and not submitted and not pending.is_empty() and manager.owner._binding.layer:
		_surface_failed_generation = manager.owner.video_layer.generation
		fallback = "surface_submit"
	for slot in manager.windows:
		var window: Node3D = manager.windows[slot]
		var accepted: bool = submitted and pending.has(slot)
		if manager.owner._binding.layer and not window.image_mode: window.frame.visible = accepted
		window.set_compositor(accepted, _pending_cuts.get(slot, Rect2(Vector2.ZERO, Vector2.ONE)), _pending_cuts.has(slot))
	if not submitted: pending.clear()

func request_samples() -> bool:
	var video: Node3D = manager.owner
	if not OS.is_debug_build() or size == Vector2i.ZERO or not Methods.supports(video.platform, "pip_compositor_samples"): return false
	video.platform.pip_compositor_samples(true); _frame.clear(); samples = ""; _sample_pending = true
	main_samples = ""
	if main_ready and Methods.supports(video.platform, "pip_main_samples"):
		video.platform.pip_main_samples(true); _main_frame.clear()
	return true

func prepare(origin: Node3D, occupied: int) -> Array:
	pending.clear()
	_pending_cuts.clear()
	if manager.video_windows().is_empty():
		if size != Vector2i.ZERO or main_size != Vector2i.ZERO or _surface_mask_size != Vector2i.ZERO: release()
		return []
	if not enabled: fallback = "debug_disabled"; return []
	var video: Node3D = manager.owner
	var layer: RefCounted = video.get("video_layer")
	if manager.video_windows().is_empty() or not layer or not layer.pip_supported() or origin == null:
		fallback = "unavailable"; return []
	if failed_generation == layer.generation and Time.get_ticks_msec() < retry_after:
		fallback = "native_draw"; return []
	var binding: RefCounted = video._binding
	if binding.layer and video.panel.visible: return _surface_extras(origin, occupied)
	_release_surface_mask()
	if not binding.material or not video.panel.visible:
		fallback = "source"; return []
	if needs_main() and not main_ready:
		fallback = "transparent_cost" if main_cost_fallback else "transparent_main"; return []
	var common := parameters(binding.material, COMMON)
	if common.size() != 43:
		fallback = "uniforms"; return []
	_update_quality(common)
	var eyes := 1
	var budget: int = maxi(0, layer.capacity() - occupied)
	# The topmost window receives a layer first. Every omitted window
	# remains in the eye buffer, with its own source lease and crop unchanged.
	var stack: Array = manager._stack.duplicate(); stack.reverse()
	for slot in stack:
		if manager.windows[slot].image_mode: continue
		var needed := window_eyes(manager.windows[slot])
		if budget < needed: continue
		pending.push_front(slot); budget -= needed
	if pending.is_empty(): fallback = "budget"; return []
	var maximum: Vector2i = layer.runtime_image_size
	var minimum_aspect: float = manager._aspect()
	for window in manager.video_windows(): minimum_aspect = minf(minimum_aspect, window.size.x / window.size.y)
	var desired := Vector2i(mini(width, maximum.x - 4), clampi(roundi(width / minimum_aspect), 64, maximum.y / 3 - 4))
	if desired.x < 64 or desired.y < 64: fallback = "image_limit"; pending.clear(); return []
	var atlas := Vector2i(desired.x + 4, (desired.y + 4) * 3)
	if _generation != layer.generation or size != atlas:
		if not video.platform.create_layer_image(Layer.PIP_SLOT, atlas.x, atlas.y, 1, false): return _fail("create")
		layer.invalidate(); size = atlas; tile = desired; _generation = layer.generation; _frame.clear()
		quality.settle(Time.get_ticks_msec())
	var windows := PackedFloat32Array()
	var mask := 0
	for slot in [1, 2, 3]:
		if manager.windows.has(slot) and not manager.windows[slot].image_mode:
			windows.append_array(parameters(manager.windows[slot].picture, WINDOW))
		else:
			var empty := PackedFloat32Array(); empty.resize(16); windows.append_array(empty)
		if pending.has(slot): mask |= 1 << (slot - 1)
	var ticket: Dictionary = binding.ticket
	var frame := [layer.generation, ticket.get("session_id", 0), ticket.get("generation", 0), ticket.get("slot_token", 0), ticket.get("frame_id", 0)]
	if frame != _frame or common != _common or windows != _windows or mask != _mask or eyes != _eyes:
		if video.platform.acquire_layer_image(Layer.PIP_SLOT) <= 0: return _fail("acquire")
		var external: bool = str(ticket.get("color_target", "")) == "external" and not binding.warped
		var color := RenderingServer.texture_get_native_handle(binding.color_texture())
		var matte := RenderingServer.texture_get_native_handle(binding.alpha_rid) if binding.alpha_rid.is_valid() else 0
		var drawn: bool = video.platform.render_pip_atlas(Layer.PIP_SLOT, color, external, matte, mask, eyes, common, windows)
		var released: bool = video.platform.release_layer_image(Layer.PIP_SLOT, false)
		if not drawn or not released: return _fail("draw")
		draws += 1; _frame = frame; _common = common; _windows = windows; _mask = mask; _eyes = eyes
		if _sample_pending:
			samples = str(video.platform.pip_compositor_samples(false)); _sample_pending = false
			if main_ready and Methods.supports(video.platform, "pip_main_samples"): main_samples = str(video.platform.pip_main_samples(false))
	var extras: Array = []
	for slot in pending:
		var window: Node3D = manager.windows[slot]
		var layer_eyes := window_eyes(window)
		for eye in layer_eyes:
			var rect := Rect2(Vector2(eye * (tile.x + 4) + 2, (slot - 1) * (tile.y + 4) + 2), Vector2(tile))
			var inner := Edges.centre(rect, window.edge_feather())
			var uv := Edges.coverage(rect, inner)
			_pending_cuts[slot] = Edges.hole(uv, window.size)
			var values: PackedFloat32Array = layer.quad_values(origin, Edges.cropped_pose(window.global_transform, window.size, uv),
				window.size * uv.size, Layer.PIP_SLOT, Vector2(size), inner, Layer.SOURCE_ALPHA, eye + 1 if layer_eyes == 2 else 0)
			values[18] = 0 # the atlas already matches display density; avoid per-layer supersampling
			extras.append({"values": values, "order": Layer.PIP_ORDER + manager._stack.find(slot) * 2 + 1, "group": slot})
	fallback = "budget" if pending.size() < manager.video_windows().size() else ""
	return extras

func _fail(reason: String) -> Array:
	fallback = reason
	var layer: RefCounted = manager.owner.video_layer
	failed_generation = layer.generation
	retry_after = Time.get_ticks_msec() + 2000; _frame.clear()
	pending.clear()
	DiagnosticLog.record("pip_compositor_failed", {"stage": reason, "generation": failed_generation})
	return []

func refresh_hz() -> float:
	var xr := XRServer.find_interface("OpenXR") as OpenXRInterface
	return clampf(xr.display_refresh_rate, 60, 144) if xr and xr.is_initialized() else 90.0

func _update_quality(common: PackedFloat32Array) -> void:
	var video: Node3D = manager.owner
	var now := Time.get_ticks_msec()
	_frame_ms.append(minf(1000, video.get_process_delta_time() * 1000))
	if _frame_ms.size() > 120: _frame_ms.pop_front()
	if now < _metrics_after: return
	_metrics_after = now + 1000
	if Methods.supports(video.platform, "pip_compositor_metrics"):
		var values := str(video.platform.pip_compositor_metrics()).split(" ", false)
		if values.size() >= 3:
			metrics = {"cpu_us": int(values[0]), "gpu_p95_us": int(values[1]), "gpu_samples": int(values[2])}
			if values.size() >= 8:
				metrics["main_gpu_p95_us"] = int(values[5]); metrics["main_gpu_samples"] = int(values[6]); metrics["main_cpu_us"] = int(values[7])
			if values.size() >= 9: metrics["main_projection_cached"] = int(values[8]) == 1
	var frame_times := _frame_ms.duplicate(); frame_times.sort()
	var frame_p95: float = frame_times[mini(frame_times.size() - 1, int(frame_times.size() * 0.95))]
	var head: Vector3 = video.view_camera.global_position if video.view_camera else (manager.anchor as Transform3D).origin
	var desired := 256
	var view_width := common[8] * (0.5 if bool(common[1]) and not bool(common[2]) else 1.0)
	for window in manager.video_windows():
		var distance: float = maxf(0.2, head.distance_to(window.global_position))
		var pixels := ceili(rad_to_deg(2 * atan(window.size.x * 0.5 / distance)) * density)
		var available: float = view_width / (3 * window.zoom)
		if int(common[0]) != 0:
			available = view_width * (2 * atan(tan(deg_to_rad(30.0)) / window.zoom)) / (TAU if int(common[0]) == 3 else deg_to_rad(common[7]) if int(common[0]) == 2 else PI)
		desired = maxi(desired, mini(pixels, maxi(256, ceili(available))))
	var hz := refresh_hz()
	var busy: bool = video.media.state != "playing" or video._waiting_first or video.control.pending or video.control.in_flight > 0 or not video._pending_revision.is_empty()
	var next := quality.update(now, desired, int(metrics.gpu_p95_us), frame_p95, hz, busy)
	if next != width:
		DiagnosticLog.record("pip_atlas_quality", {"from": width, "to": next, "frame_p95_ms": frame_p95, "gpu_p95_us": metrics.gpu_p95_us})
		width = next

func snapshot() -> Dictionary:
	var sampling := {}
	if OS.is_debug_build() and not _frame.is_empty() and _common.size() == 43:
		sampling = {"stereo": bool(_common[1]), "swap": bool(_common[4]), "eye": int(_common[5]),
			"offset": [_common[12], _common[13]], "alpha_edge": [_common[18], _common[19]]}
	var windows := []
	for slot in manager.windows:
		var window: Node3D = manager.windows[slot]
		windows.append({"slot": slot, "zoom": window.zoom, "center": [window.crop_center.x, window.crop_center.y],
			"view": "2d", "mode": "image" if window.image_mode else "video", "image_loading": window.image_loading, "image_error": window.image_error, "custom_shape": window.custom_shape,
			"position": [window.global_position.x, window.global_position.y, window.global_position.z],
			"size": [window.size.x, window.size.y], "on_layer": window.on_compositor})
	return {"windows": windows, "preferences": manager.preferences.duplicate(), "layers": pending.duplicate(), "atlas": [size.x, size.y], "tile": [tile.x, tile.y],
		"edge_path": "surface_mask" if _surface_mask_size != Vector2i.ZERO else ("centre_ring" if not pending.is_empty() else "shared_texture"),
		"surface_background": surface_background, "mask_atlas": [_surface_mask_size.x, _surface_mask_size.y],
		"width": width, "draws": draws, "fallback": fallback, "metrics": metrics.duplicate(), "main_image": [main_size.x, main_size.y], "main_ready": main_ready, "main_cost_fallback": main_cost_fallback,
		"samples": samples if OS.is_debug_build() else "", "main_samples": main_samples if OS.is_debug_build() else "", "sampling": sampling}
