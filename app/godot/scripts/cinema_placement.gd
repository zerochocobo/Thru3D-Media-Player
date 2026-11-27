extends RefCounted
## Bottom midpoint of the nominal screen (preset envelope, or visible image for manual sizes).
var enabled := false
var bottom: Variant = null
var height := -0.5 # Bottom relative to eye height, used on explicit recenter/startup only.
var placed := false
var free_rotation := 0.0
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
	_rebase_guide(head)
	surface._apply_flat_pose()

func eye_level(surface: Node3D, eye: Vector3) -> float:
	if bottom == null or surface.screen_frame_height() <= 0: return 0.5
	return (eye.y - bottom.origin.y) / surface.screen_frame_height()

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
