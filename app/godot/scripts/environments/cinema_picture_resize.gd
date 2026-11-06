extends RefCounted
## A fixed hall picture scales inside its envelope, including its curved corners
## and the size slider's downward centre bias. Pointer capture stays in main.
const Border := preload("res://scripts/environments/cinema_screen_border.gd")

static func begin(surface: Node3D, corner: int, ray: Array, size: float, drop: float) -> Dictionary:
	var plane: Transform3D = surface.panel.global_transform
	plane.origin -= plane.basis.y * surface._flat.size.y * drop
	var inverse := plane.affine_inverse()
	var origin: Vector3 = inverse * ray[0]
	var point: Variant = _plane_point(origin, inverse.basis * ray[1])
	if point == null: return {}
	var capture := {"plane": plane, "dimensions": surface._flat.size / size, "corner": corner,
		"radius": surface._curve_radius() if surface.screen_curve > 0 else 0.0, "drop": drop, "size": size}
	var projected: Variant = _project_corner(capture, size, origin)
	if projected == null or projected.length_squared() < 0.0001: return {}
	var axis: Vector2 = projected.normalized()
	capture["axis"] = axis
	# Allow the existing corner hit tolerance without snapping on the first frame.
	capture["offset"] = (projected - point).dot(axis)
	return capture

static func size_at(capture: Dictionary, ray: Array, minimum: float) -> float:
	var inverse: Transform3D = capture.plane.affine_inverse()
	var origin: Vector3 = inverse * ray[0]
	var point: Variant = _plane_point(origin, inverse.basis * ray[1])
	if point == null: return float(capture.size)
	var axis: Vector2 = capture.axis
	var target: float = point.dot(axis) + float(capture.offset)
	var low := minimum
	var high := 1.0
	var first: Variant = _project_corner(capture, low, origin)
	var last: Variant = _project_corner(capture, high, origin)
	if first == null or last == null: return float(capture.size)
	var from: float = first.dot(axis)
	var to: float = last.dot(axis)
	var increasing := to > from
	if increasing:
		if target <= from: return minimum
		if target >= to: return 1.0
	else:
		if target >= from: return minimum
		if target <= to: return 1.0
	# Only while a corner is held; 16 steps resolve far below one screen pixel.
	for _step in 16:
		var middle := (low + high) * 0.5
		var projected: Variant = _project_corner(capture, middle, origin)
		if projected == null: return float(capture.size)
		if (projected.dot(axis) < target) == increasing: low = middle
		else: high = middle
	return clampf((low + high) * 0.5, minimum, 1.0)

static func _project_corner(capture: Dictionary, size: float, origin: Vector3) -> Variant:
	var dimensions: Vector2 = capture.dimensions * size
	var side := 1.0 if int(capture.corner) % 2 == 1 else -1.0
	var height := dimensions.y * (0.5 if int(capture.corner) < 2 else -0.5)
	var radius: float = capture.radius
	var corner := Border.at(radius, side * dimensions.x * 0.5 / radius, height) if radius > 0 else Vector3(side * dimensions.x * 0.5, height, 0)
	corner.y += dimensions.y * float(capture.drop)
	return _plane_point(origin, corner - origin)

static func _plane_point(origin: Vector3, direction: Vector3) -> Variant:
	if not origin.is_finite() or not direction.is_finite() or absf(direction.z) < 0.00001: return null
	var distance := -origin.z / direction.z
	if distance <= 0: return null
	var point := origin + direction * distance
	return Vector2(point.x, point.y)
