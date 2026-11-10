extends RefCounted
## Recovery only: never sends pointer events to application content. Distances are metres.
const DWELL := 0.4
const HOLD := 1.0
const RADIUS := 0.05
var hand := ""
var target := Transform3D.IDENTITY
var shown := false
var armed := false
var holding := false
var complete := false
var progress := 0.0
var hit := false
var cursor := Vector3.ZERO
var _dwell := 0.0
var _anchor := Vector3.ZERO
var _elapsed := 0.0

func reset() -> void:
	hand = ""; shown = false; armed = false; holding = false; complete = false
	progress = 0.0; hit = false; _dwell = 0.0; _elapsed = 0.0

static func eligible(point: Vector3, head: Transform3D, scale: float) -> bool:
	if not point.is_finite() or not head.is_finite() or scale <= 0: return false
	var p := head.affine_inverse() * point / scale
	# Exclude the mouth/chest vicinity, not merely short pinches. Head-relative for reclined use.
	return p.length() >= 0.28 and p.length() <= 0.85 and p.z < -0.20 \
		and absf(p.x) < 0.5 and p.y > -0.24 and p.y < 0.4 \
		and not (p.y < -0.08 and absf(p.x) < 0.22 and -p.z < 0.48)

## {hand, tracked, point, ray, down, blocked}; true only on a valid release AFTER confirmation.
func update(sample: Dictionary, head: Transform3D, scale: float, delta: float) -> bool:
	var point: Variant = sample.get("point")
	var ray: Variant = sample.get("ray")
	if not sample.get("tracked", false) or sample.get("blocked", false) or not point is Vector3 \
		or ray == null or not eligible(point, head, scale):
		reset(); return false
	var side := str(sample.get("hand", ""))
	if side.is_empty(): reset(); return false
	if hand != side:
		reset(); hand = side; _anchor = point
	var dt := clampf(delta, 0.0, 0.05)
	if not shown:
		if point.distance_to(_anchor) > 0.06 * scale:
			_anchor = point; _dwell = 0.0
		_dwell += dt
		if _dwell < DWELL: return false
		shown = true
		target = Transform3D(head.basis.orthonormalized(), head * (Vector3(-0.16 if hand == "left_hand" else 0.16, 0.03, -0.58) * scale))
		cursor = target.origin
		# The first visible frame cannot arm or count a pre-existing pinch.
		return false
	var local_origin: Vector3 = target.affine_inverse() * ray[0]
	var local_dir: Vector3 = target.basis.inverse() * ray[1]
	hit = false
	if absf(local_dir.z) > 0.0001:
		var distance := -local_origin.z / local_dir.z
		if distance > 0:
			var projected := local_origin + local_dir * distance
			cursor = target * Vector3(clampf(projected.x, -0.12 * scale, 0.12 * scale), clampf(projected.y, -0.12 * scale, 0.12 * scale), 0.002 * scale)
			hit = Vector2(projected.x, projected.y).length() <= RADIUS * scale
	if not hit:
		armed = false; holding = false; complete = false; _elapsed = 0.0; progress = 0.0
		return false
	var down: bool = sample.get("down", false)
	if not down:
		if complete:
			reset(); return true
		armed = true; holding = false; _elapsed = 0.0; progress = 0.0
	elif armed:
		holding = true; _elapsed += dt; progress = minf(1.0, _elapsed / HOLD)
		complete = _elapsed >= HOLD
	return false
