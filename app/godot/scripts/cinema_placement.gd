extends RefCounted
## Bottom midpoint of the nominal screen (preset envelope, or visible image for manual sizes).
var enabled := false
var bottom: Variant = null
var height := -0.5 # Bottom relative to eye height, used on explicit recenter/startup only.
var placed := false
var free_rotation := 0.0
var guide: MeshInstance3D
var guide_pose: Variant = null

func active(surface: Node3D) -> bool:
	return enabled and surface.geometry == 0

static func upright(basis: Basis) -> Basis:
	var forward := -basis.z; forward.y = 0
	if forward.length_squared() < 0.0001: forward = Vector3.UP.cross(basis.x)
	return Basis.looking_at(forward.normalized(), Vector3.UP)

func capture(surface: Node3D, pose: Transform3D) -> void:
	bottom = Transform3D(upright(pose.basis), pose.origin - Vector3.UP * surface.screen_frame_height() * 0.5)

func content_bottom(surface: Node3D) -> Transform3D:
	var pose: Transform3D = bottom
	pose.origin.y += (surface.screen_frame_height() - surface._flat.size.y) * 0.5
	return pose

func configure(surface: Node3D, value: bool, head: Variant) -> void:
	if enabled == value: return
	hide_guide()
	if value:
		free_rotation = surface.screen_rotation
		capture(surface, surface.global_transform * surface.flat_pose)
		if head is Transform3D:
			height = bottom.origin.y - head.origin.y
			_rebase_guide(head)
			placed = true
	else: bottom = null
	enabled = value
	surface.set_screen_rotation(0.0 if enabled else free_rotation)

func recenter(surface: Node3D, head: Transform3D) -> void:
	hide_guide()
	placed = true
	var basis := upright(head.basis)
	bottom = Transform3D(basis, head.origin - basis.z * surface.screen_distance + Vector3.UP * height)
	_rebase_guide(head)
	surface._apply_flat_pose()

func _rebase_guide(head: Transform3D) -> void:
	# A virtual reference plane, not a detected floor. It stays fixed while adjusting the screen.
	guide_pose = Transform3D(upright(head.basis), head.origin + Vector3(0, minf(-1.25, height - 0.2), 0))

func set_eye_level(surface: Node3D, head: Transform3D, fraction: float) -> void:
	if not active(surface) or not is_finite(fraction): return
	if bottom == null: capture(surface, surface.global_transform * surface.flat_pose)
	height = -surface.screen_frame_height() * clampf(fraction, 0.0, 1.0)
	bottom.origin.y = head.origin.y + height
	_rebase_guide(head); hide_guide()
	surface._apply_flat_pose()

func eye_level(surface: Node3D, eye: Vector3) -> float:
	if bottom == null or surface.screen_frame_height() <= 0: return 0.5
	return (eye.y - bottom.origin.y) / surface.screen_frame_height()

func hide_guide() -> void:
	if is_instance_valid(guide): guide.visible = false

func show_guide(surface: Node3D, head: Variant, adjusting: bool) -> void:
	if not adjusting or not active(surface) or surface.local_uri.is_empty() or not surface.panel.visible or not head is Transform3D:
		hide_guide()
		return
	if guide_pose == null: _rebase_guide(head)
	if not is_instance_valid(guide):
		guide = MeshInstance3D.new(); guide.name = "CinemaAdjustmentGrid"
		surface.add_child(guide); guide.top_level = true
		var mesh := ImmediateMesh.new(); mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
		for x in range(-20, 21, 2): _strip(mesh, Vector3(x, 0, -0.5), Vector3(x, 0, -60), Vector3(0.008, 0, 0))
		for z in range(1, 11) + range(15, 61, 5): _strip(mesh, Vector3(-20, 0, -z), Vector3(20, 0, -z), Vector3(0, 0, 0.008))
		mesh.surface_end(); guide.mesh = mesh
		var material := StandardMaterial3D.new()
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		material.albedo_color = Color(0.075, 0.11, 0.13); material.cull_mode = BaseMaterial3D.CULL_DISABLED
		guide.material_override = material; guide.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		surface.panel.visibility_changed.connect(func():
			if not surface.panel.visible: hide_guide())
	guide.global_transform = guide_pose
	guide.visible = true

static func _strip(mesh: ImmediateMesh, a: Vector3, b: Vector3, width: Vector3) -> void:
	for point in [a - width, b - width, b + width, a - width, b + width, a + width]: mesh.surface_add_vertex(point)

func constrain(surface: Node3D) -> void:
	if not active(surface): return
	if bottom == null: capture(surface, surface.global_transform * surface.flat_pose)
	var pose: Transform3D = bottom
	pose.origin += Vector3.UP * surface.screen_frame_height() * 0.5
	surface.flat_pose = surface.global_transform.affine_inverse() * pose

func distance(surface: Node3D, eye: Vector3) -> float:
	var pose: Transform3D = surface.global_transform * surface.flat_pose
	return (eye - pose.origin).dot(pose.basis.z.normalized())

func push(surface: Node3D, eye: Vector3, amount: float) -> void:
	var before := distance(surface, eye)
	var after := clampf(before + amount, surface.DISTANCE_LIMITS.x, surface.DISTANCE_LIMITS.y)
	if bottom == null: capture(surface, surface.global_transform * surface.flat_pose)
	bottom.origin -= bottom.basis.z * (after - before)
	surface.set_screen_distance(after)
	surface._apply_flat_pose()
