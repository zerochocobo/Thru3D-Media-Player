extends RefCounted
## Flat surfaces tangent to a viewer-centred sphere. Layout is explicit, never a per-frame billboard.
const GAP_METRES := 0.08

static func facing(pose: Transform3D, eye: Vector3, centre: Vector3, up: Vector3) -> Transform3D:
	var point := pose * centre
	var direction := point - eye
	if direction.length_squared() < 0.0001: return pose
	var vertical := up.normalized()
	if absf(direction.normalized().dot(vertical)) > 0.999: vertical = pose.basis.y.normalized()
	if absf(direction.normalized().dot(vertical)) > 0.999: vertical = pose.basis.x.normalized()
	var basis := Basis.looking_at(direction.normalized(), vertical)
	return Transform3D(basis, point - basis * centre)

## Use complete visual bounds, including floating actions and text, in the surface's own space.
static func bounds(nodes: Array, frame: Node3D) -> Rect2:
	var low := Vector2(INF, INF)
	var high := Vector2(-INF, -INF)
	for node in nodes:
		var extent := _extent(node, frame.global_transform.affine_inverse())
		if extent.size.x < 0: continue
		low = low.min(extent.position); high = high.max(extent.end)
	return Rect2(low, high - low) if low.is_finite() else Rect2()

static func _extent(node: Node, inverse: Transform3D) -> Rect2:
	if node is Node3D and not node.visible: return Rect2(0, 0, -1, -1)
	var low := Vector2(INF, INF)
	var high := Vector2(-INF, -INF)
	if node is VisualInstance3D:
		var box: AABB = node.get_aabb()
		var pose: Transform3D = inverse * node.global_transform
		for index in 8:
			var point := pose * box.get_endpoint(index)
			low = low.min(Vector2(point.x, point.y)); high = high.max(Vector2(point.x, point.y))
	for child in node.get_children():
		var extent := _extent(child, inverse)
		if extent.size.x < 0: continue
		low = low.min(extent.position); high = high.max(extent.end)
	return Rect2(low, high - low) if low.is_finite() else Rect2(0, 0, -1, -1)

## Separate angular footprints at one radius, rather than stacking in a tilted parent's local Y.
static func above(base: Transform3D, eye: Vector3, centre: Vector3, top: float, rect: Rect2, up: Vector3) -> Transform3D:
	var anchor := base * centre
	var radius := anchor.distance_to(eye)
	if radius < 0.01: return base
	var direction := (anchor - eye) / radius
	var vertical := up - direction * up.dot(direction)
	if vertical.length_squared() < 0.0001: vertical = base.basis.y
	vertical = vertical.normalized()
	var top_direction := base * Vector3(centre.x, top, centre.z) - eye
	var top_angle := maxf(0, atan2(top_direction.dot(vertical), top_direction.dot(direction)))
	var angle := top_angle + atan2(rect.size.y * 0.5, radius) + atan2(GAP_METRES, radius)
	var point := eye + radius * (direction * cos(angle) + vertical * sin(angle))
	var pose := Transform3D(Basis.IDENTITY, point)
	pose = facing(pose, eye, Vector3.ZERO, up)
	return pose * Transform3D(Basis.IDENTITY, -Vector3(rect.get_center().x, rect.get_center().y, 0))
