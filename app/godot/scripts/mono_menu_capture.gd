extends Node
## Experimental centre-eye UI capture, reusing the production menu geometry and hit tests.
## Finite-depth modes keep MenuComposition's native quad layers. This mode parks those
## swapchains without detaching/freeing them. An infinite-radius native equirect layer
## keeps text out of the eye buffer; the projection surface is only the compatibility fallback.
const Composition := preload("res://scripts/menu_composition.gd")
const Ui := preload("res://scripts/ray_menu.gd")
const SHADER := preload("res://shaders/menu_zero_parallax.gdshader")
const RAY_SHADER := preload("res://shaders/menu_zero_parallax_ray.gdshader")
const COPY_SHADER := preload("res://shaders/menu_mono_equirect.gdshader")
const HOLE_SHADER := preload("res://shaders/menu_zero_parallax_hole.gdshader")
const BIT := 1 << Composition.GROUP_BIT
var source_provider: Callable
var eye: Camera3D
var composition: Node
var low_end := false
var active: Node3D
var raw: SubViewport
var camera: Camera3D
var surface: MeshInstance3D
var originals: Array[Dictionary] = []
var visual_planes: Array[Dictionary] = []
var button_planes := {}
var eye_mask := 0
var resume_composition := false
var native_supported := false
var force_capture := false # Desktop verification of the layer texture, not a native XR claim.
var submit: SubViewport
var copy: ColorRect
var layer: OpenXRCompositionLayerEquirect
var hole: MeshInstance3D
## The layer capture is redrawn when the menu changed or the head moved this far across it, not every
## frame: two 2304 px targets a frame took 8K 120 Hz playback from 117 to 65 frames a second on Quest 3
## with a still control bar (2026-11-26). 1 mm at the bar's 1.4 m is under two layer pixels; between
## captures the layer and its mask follow the head. Changes arrive as in MenuComposition: its dirty
## flags from the menus' signals, and a signature check every KEEPALIVE_MS for the silent ones.
const EYE_TOLERANCE := 0.001
const KEEPALIVE_MS := 250
var captures := 0
var _captured_eye := Vector3.INF
var _captured_basis := Basis.IDENTITY
var _captured_centre := Vector2.ZERO
var _signature := 0
var _signature_poses: Dictionary[int, Transform3D] = {}
var _checked_ms := 0
var _tail := 0

func configure(viewer: Camera3D, compositor: Node, provider: Callable, low: bool, host_capture: bool = false) -> void:
	eye = viewer; composition = compositor; source_provider = provider; low_end = low
	force_capture = host_capture
	var probe := OpenXRCompositionLayerEquirect.new()
	var xr := XRServer.find_interface("OpenXR")
	native_supported = xr != null and xr.is_initialized() and xr.get_view_count() == 2 and probe.is_natively_supported()
	probe.free()
	if native_supported:
		var info: Dictionary = xr.get_system_info()
		native_supported = native_runtime(str(info.get("XRRuntimeName", "")), str(info.get("OpenXRSystemName", "")), OS.has_feature("pico"))
	DiagnosticLog.record("mono_menu_path", {"native": native_supported})
	# See MenuComposition: a session stop must not leave the layer's render target for the next one.
	if native_supported and not xr.session_stopping.is_connected(_renew_submit):
		xr.session_stopping.connect(_renew_submit)
	if not RenderingServer.frame_post_draw.is_connected(_frame_drawn):
		RenderingServer.frame_post_draw.connect(_frame_drawn)
	process_priority = 99 # after input, before the existing compositor

## PICO 4 user report (0.17.4): a VR180 control bar on the infinite-radius equirect layer stayed
## invisible while its hit geometry still answered the rays, so PICO draws it in the eye buffer.
## The same vendor tests as VideoLayer's surface orientation policy.
static func native_runtime(runtime_name: String, system_name: String, pico_build: bool) -> bool:
	var runtime := runtime_name.strip_edges().to_lower()
	return not (pico_build or runtime.contains("pico") or runtime.begins_with("pxr") or system_name.to_lower().contains("pico"))

func layer_reservation() -> int:
	# Reserve before first use, and after closing: the swapchain stays attached.
	return 1 if native_supported else 0

func _uses_layer() -> bool:
	return native_supported or force_capture

func _create() -> void:
	raw = SubViewport.new(); raw.size = Vector2i.ONE * (1536 if low_end else 2304)
	raw.transparent_bg = true; raw.world_3d = eye.get_world_3d()
	raw.render_target_update_mode = SubViewport.UPDATE_DISABLED
	if _uses_layer():
		submit = SubViewport.new(); submit.size = raw.size
		submit.transparent_bg = true; submit.disable_3d = true; submit.world_2d = World2D.new()
		submit.render_target_update_mode = SubViewport.UPDATE_DISABLED
		add_child(submit); submit.add_child(raw)
		copy = ColorRect.new(); copy.size = Vector2(submit.size)
		var copy_material := ShaderMaterial.new(); copy_material.shader = COPY_SHADER
		copy_material.set_shader_parameter("menu_texture", raw.get_texture())
		copy.material = copy_material; submit.add_child(copy)
		if native_supported:
			layer = OpenXRCompositionLayerEquirect.new()
			layer.name = "MonoMenuLayer"; layer.alpha_blend = true; layer.enable_hole_punch = false
			# OpenXR defines +infinity as no eye translation. Godot rejects radius=0.
			# Only create this node on native support: its finite fallback mesh cannot use INF.
			layer.radius = INF; layer.sort_order = Composition.ORDER_BASE
			add_child(layer); layer.layer_viewport = submit
			composition._apply_filter(layer)
	else:
		add_child(raw)
	camera = Camera3D.new(); camera.cull_mask = BIT
	camera.environment = Composition.clear_environment(); raw.add_child(camera)
	surface = MeshInstance3D.new(); surface.mesh = QuadMesh.new()
	surface.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	surface.extra_cull_margin = 1.0
	var material := ShaderMaterial.new(); material.shader = SHADER
	material.render_priority = 120; material.set_shader_parameter("menu_texture", raw.get_texture())
	surface.material_override = material; surface.visible = false
	add_child(surface)
	if _uses_layer():
		hole = MeshInstance3D.new(); hole.mesh = surface.mesh
		hole.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		hole.extra_cull_margin = surface.extra_cull_margin
		var hole_material := ShaderMaterial.new(); hole_material.shader = HOLE_SHADER
		hole_material.render_priority = Composition.HOLE_PRIORITY
		hole_material.set_shader_parameter("menu_texture", raw.get_texture())
		hole.material_override = hole_material; hole.hide(); add_child(hole)

func _renew_submit() -> void:
	if layer: submit = Composition.renew_submit(layer, submit)

func _process(_delta: float) -> void:
	update()

func update() -> void:
	var wanted: Node3D = source_provider.call() if source_provider.is_valid() else null
	if wanted != active:
		stop()
		if wanted:
			active = wanted
			resume_composition = composition.enabled and composition.is_processing()
			if resume_composition: composition.set_active(false)
			eye_mask = eye.cull_mask; eye.cull_mask &= ~BIT
			if not raw: _create()
			_captured_eye = Vector3.INF
	if not active: return
	# Picking follows the same centre-eye angular position as the visible beam tip.
	# Keeping finite hand-origin intersections would leave the rendered zero-disparity
	# tip over a small control while its logical hit falls beside that control.
	active.set_meta("menu_mono_pointer", {"eye": eye, "distance": float(active.ray_max_distance)})
	# Refresh membership: popups rebuild, and the browser can reparent on close/switch.
	_restore()
	button_planes.clear()
	var nodes: Array[VisualInstance3D] = []
	_mask(active, nodes)
	var pose := Transform3D(active.global_basis.orthonormalized(), eye.global_position)
	var rect := projected_bounds(nodes, pose)
	if not rect.has_area():
		_park(); return
	if not _uses_layer():
		# The eye-buffer fallback draws its surface every frame anyway.
		_frame(rect, pose)
		surface.global_transform = pose * Transform3D(Basis.IDENTITY, Vector3(_captured_centre.x, _captured_centre.y, -1.0))
		surface.visible = true
		raw.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		return
	if _capture_due(nodes, pose):
		_frame(rect, pose)
		var angles := capture_angles(rect.grow(0.02))
		copy.material.set_shader_parameter("angles", angles)
		if layer:
			layer.central_horizontal_angle = angles.x
			layer.upper_vertical_angle = angles.y; layer.lower_vertical_angle = angles.z
		_captured_eye = active.global_transform.affine_inverse() * eye.global_position
		_captured_basis = pose.basis
		# As MenuComposition: the capture renders once, the copy for the two drawn frames of its tail
		# (counted after each draw: update() also runs outside the frame's own process step).
		raw.render_target_update_mode = SubViewport.UPDATE_ONCE
		submit.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		_tail = 2; captures += 1
	# The picture keeps the directions it was captured in; the layer and its mask stay on the head.
	var held := Transform3D(_captured_basis, eye.global_position)
	surface.global_transform = held * Transform3D(Basis.IDENTITY, Vector3(_captured_centre.x, _captured_centre.y, -1.0))
	surface.visible = not native_supported
	hole.global_transform = surface.global_transform; hole.visible = native_supported
	if layer: layer.global_transform = held
	if native_supported and composition.display: composition.display.set_menu_layers(true)

## The capture camera and the square it fills, for the menu as it stands from [pose].
func _frame(rect: Rect2, pose: Transform3D) -> void:
	# One square target allocated per session; changing menus never resizes an XR swapchain.
	var size := maxf(rect.size.x, rect.size.y) + 0.04
	var centre := rect.get_center()
	camera.global_transform = pose
	camera.set_frustum(size * 0.05, centre * 0.05, 0.05, 100.0)
	if surface.mesh.size != Vector2.ONE * size: surface.mesh.size = Vector2.ONE * size
	_captured_centre = centre
	if copy: copy.material.set_shader_parameter("capture_rect", Vector4(centre.x, centre.y, size, size))

## Whether the layer needs a new picture: the menu changed, or the head moved across it.
func _capture_due(nodes: Array[VisualInstance3D], pose: Transform3D) -> bool:
	var now := Time.get_ticks_msec()
	# MenuComposition is parked in this mode; its flags still collect the menus' change signals.
	var changed: bool = composition.dirty or composition.geometry_dirty or not composition._partial.is_empty()
	var check: bool = composition._verify or now - _checked_ms >= KEEPALIVE_MS
	composition.dirty = false; composition.geometry_dirty = false; composition._verify = false; composition._partial.clear()
	var moved := not _captured_eye.is_finite() or not pose.basis.is_equal_approx(_captured_basis) 		or (active.global_transform.affine_inverse() * eye.global_position).distance_to(_captured_eye) > EYE_TOLERANCE
	if not changed and not check: return moved
	_checked_ms = now
	var values := []
	var poses: Dictionary[int, Transform3D] = {}
	composition._sign_nodes(nodes, active.global_transform.affine_inverse(), values, poses, _signature_poses)
	_signature_poses = poses
	var signature := hash(values)
	changed = changed or signature != _signature
	_signature = signature
	return changed or moved

static func capture_angles(rect: Rect2) -> Vector3:
	# Latitude is atan(y / sqrt(1+x*x)); x=0 conservatively contains every corner.
	return Vector3(2.0 * atan(maxf(absf(rect.position.x), absf(rect.end.x))),
		maxf(atan(rect.end.y), 0.0001), maxf(-atan(rect.position.y), 0.0001))

func _park() -> void:
	if raw: raw.render_target_update_mode = SubViewport.UPDATE_DISABLED
	if submit: submit.render_target_update_mode = SubViewport.UPDATE_DISABLED
	if surface: surface.hide()
	if hole: hole.hide()
	_tail = 0
	if layer:
		# Never hide/detach/resize a live viewport swapchain (see MenuComposition).
		layer.central_horizontal_angle = 0.00001
		layer.upper_vertical_angle = 0.00001; layer.lower_vertical_angle = 0.00001
	if native_supported and is_instance_valid(composition) and composition.display: composition.display.set_menu_layers(false)

func snapshot() -> Dictionary:
	return {"active": active != null, "native": native_supported, "reserved_layers": layer_reservation(),
		"path": "infinite_equirect" if native_supported else "eye_buffer_fallback", "captures": captures,
		"pixels": [raw.size.x, raw.size.y] if raw else []}

static func projected_bounds(nodes: Array[VisualInstance3D], pose: Transform3D) -> Rect2:
	var low := Vector2(INF, INF); var high := Vector2(-INF, -INF)
	for node in nodes:
		if not node.is_visible_in_tree() or node.has_meta("menu_pointer"): continue
		var box: AABB = node.get_meta("menu_capture_bounds", node.get_aabb())
		var transform := pose.affine_inverse() * node.global_transform
		for corner in 8:
			var point := transform * box.get_endpoint(corner)
			if point.z >= -0.05: continue
			var projected := Vector2(point.x, point.y) / -point.z
			low = low.min(projected); high = high.max(projected)
	return Rect2(low, high - low) if low.is_finite() else Rect2()

func _mask(node: Node, nodes: Array[VisualInstance3D], plane: Node3D = null) -> void:
	if node is Viewport or node is CanvasItem: return
	if node is Ui:
		for button in node._buttons: button_planes[button.node.get_instance_id()] = true
	if button_planes.has(node.get_instance_id()): plane = node
	if node is VisualInstance3D:
		var saved := {"node": node, "layers": node.layers}
		# The ray stays in the eye buffer and keeps the full ray's per-eye projection.
		if node.has_meta("menu_pointer") and node is MeshInstance3D and node.mesh is ImmediateMesh:
			# Input may update the ray before _restore() on the following frame.
			# Keep one material so restoring cannot discard those fresh endpoints.
			saved["ray_shader"] = node.material_override.shader
			node.material_override.shader = RAY_SHADER
		else:
			# The normal per-plane compositor is orthographic: tiny ink/plate Z offsets
			# only set draw order. A perspective mono capture magnifies those offsets
			# away from the optical centre. Keep leaf ink on its logical button plane.
			if plane and node != plane and node.get_child_count() == 0 and not node.has_meta("menu_pointer"):
				var point := plane.to_local(node.global_position)
				if absf(point.z) > 0.000001:
					visual_planes.append({"node":node,"transform":node.transform})
					node.global_position = plane.to_global(Vector3(point.x,point.y,0))
			node.layers = BIT; nodes.append(node)
		originals.append(saved)
	for child in node.get_children(): _mask(child, nodes, plane)

func _frame_drawn() -> void:
	_restore_visual_planes()
	if _tail == 0: return
	_tail -= 1
	if _tail == 0 and _uses_layer() and submit:
		raw.render_target_update_mode = SubViewport.UPDATE_DISABLED
		submit.render_target_update_mode = SubViewport.UPDATE_DISABLED

func _restore_visual_planes() -> void:
	# Restore before the next input/update frame. Logical hit geometry never moves.
	for saved in visual_planes:
		if is_instance_valid(saved.node): saved.node.transform = saved.transform
	visual_planes.clear()

func _restore() -> void:
	_restore_visual_planes()
	for saved in originals:
		if not is_instance_valid(saved.node): continue
		saved.node.layers = saved.layers
		if saved.has("ray_shader"): saved.node.material_override.shader = saved.ray_shader
	originals.clear()

func stop() -> void:
	_restore()
	_park()
	if active:
		if is_instance_valid(active): active.remove_meta("menu_mono_pointer")
		if is_instance_valid(eye): eye.cull_mask = eye_mask
		if resume_composition and is_instance_valid(composition): composition.set_active(true)
	active = null; resume_composition = false

func _exit_tree() -> void:
	if RenderingServer.frame_post_draw.is_connected(_frame_drawn):
		RenderingServer.frame_post_draw.disconnect(_frame_drawn)
	stop()
