extends RefCounted
## A finite spherical patch, mapped by geodesic distance from its centre.
## The diagonal arc is bounded to 180 degrees, so no corner crosses the far hemisphere.

static func point(at: Vector3, radius: float) -> Vector3:
	var distance := Vector2(at.x, at.y).length()
	if distance < 0.000001: return Vector3(at.x, at.y, 0)
	var angle := distance / radius
	var factor := sin(angle) / angle
	return Vector3(at.x * factor, at.y * factor, radius * (1.0 - cos(angle)))

static func unbend(at: Vector3, radius: float) -> Vector3:
	var distance := Vector2(at.x, at.y).length()
	if distance < 0.000001: return Vector3.ZERO
	var factor := radius * atan2(distance, radius - at.z) / distance
	return Vector3(at.x * factor, at.y * factor, 0)

static func tangent(at: Vector3, direction: Vector3, radius: float) -> Vector3:
	var distance := Vector2(at.x, at.y).length()
	if distance < 0.000001: return Vector3(direction.x, direction.y, 0)
	var angle := distance / radius
	var factor := sin(angle) / angle
	var radial := (at.x * direction.x + at.y * direction.y) / distance
	var derivative := (angle * cos(angle) - sin(angle)) / (angle * angle * radius) * radial
	return Vector3(factor * direction.x + at.x * derivative, factor * direction.y + at.y * derivative, sin(angle) * radial)

static func mesh(size: Vector2, radius: float, segments: int = 48) -> ArrayMesh:
	var extent := maxf(size.x, size.y)
	var columns := maxi(2, ceili(segments * size.x / extent))
	var rows := maxi(2, ceili(segments * size.y / extent))
	var vertices := PackedVector3Array()
	var uv := PackedVector2Array()
	var indices := PackedInt32Array()
	for row in rows + 1:
		for column in columns + 1:
			var at := Vector2(float(column) / columns, float(row) / rows)
			vertices.append(point(Vector3((at.x - 0.5) * size.x, (0.5 - at.y) * size.y, 0), radius))
			uv.append(at)
			if row < rows and column < columns:
				var a := row * (columns + 1) + column
				var b := a + columns + 1
				indices.append_array(PackedInt32Array([a, a + 1, b, a + 1, b + 1, b]))
	var arrays := []; arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices; arrays[Mesh.ARRAY_TEX_UV] = uv; arrays[Mesh.ARRAY_INDEX] = indices
	var result := ArrayMesh.new(); result.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return result

static func hit(size: Vector2, radius: float, origin: Vector3, ray: Vector3) -> Variant:
	var a := ray.length_squared()
	if a < 0.000001: return null
	var b := origin.dot(ray) - radius * ray.z
	var c := origin.length_squared() - 2.0 * radius * origin.z
	var discriminant := b * b - a * c
	if discriminant < 0.0: return null
	for distance in [(-b - sqrt(discriminant)) / a, (-b + sqrt(discriminant)) / a]:
		if distance <= 0.0: continue
		var at: Vector3 = origin + ray * distance
		if at.z > radius + 0.00001: continue
		var flat := unbend(at, radius)
		if absf(flat.x) <= size.x * 0.5 + 0.00001 and absf(flat.y) <= size.y * 0.5 + 0.00001: return at
	return null
