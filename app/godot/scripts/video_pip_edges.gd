extends RefCounted
## Photo-viewer strategy: native centre, sampled feather ring, smaller centre hole.
const OVERLAP_METRES := 0.004
const MASK_TILE := 512
const MASK_GUTTER := 2

static func centre(rect: Rect2, feather: Vector2) -> Rect2:
	var first := (rect.position + rect.size * feather).ceil()
	var last := (rect.end - rect.size * feather).floor()
	return Rect2(first, last - first)

static func coverage(whole: Rect2, inner: Rect2) -> Rect2:
	return Rect2((inner.position - whole.position) / whole.size, inner.size / whole.size)

static func hole(coverage_rect: Rect2, size: Vector2) -> Rect2:
	var overlap := Vector2.ONE * minf(OVERLAP_METRES, minf(size.x, size.y) * 0.02) / size
	return Rect2(coverage_rect.position + overlap, coverage_rect.size - 2 * overlap)

static func cropped_pose(pose: Transform3D, size: Vector2, uv: Rect2) -> Transform3D:
	var centre_uv := uv.get_center() - Vector2.ONE * 0.5
	pose.origin += pose.basis * Vector3(centre_uv.x * size.x, -centre_uv.y * size.y, 0)
	return pose

static func vector(rect: Rect2) -> Vector4:
	return Vector4(rect.position.x, rect.position.y, rect.size.x, rect.size.y)
