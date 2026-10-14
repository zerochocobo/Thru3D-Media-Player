extends RefCounted
## Grip first arms movement. A deliberate displacement commits it; a chord cancels pending movement.
const START_METRES := 0.018
const START_RADIANS := 0.035
const MAX_TRACKING_STEP_METRES := 0.8
const DEPTH_SPEED := 1.5
const DEPTH_LIMITS := Vector2(0.6, 8.0)
const MAX_MENU_PITCH := deg_to_rad(80.0)
var capture := {}
var placements := {}

func begin(hand: String, input: String, pose: Transform3D, targets: Array, anchor: Variant = null, head: Variant = null, following: bool = false) -> bool:
	if not capture.is_empty() or targets.is_empty() or not pose.is_finite(): return false
	var point: Vector3 = anchor if anchor is Vector3 else pose.origin
	if not point.is_finite(): return false
	if head is Transform3D:
		if not head.is_finite(): return false
		if point.distance_to(head.origin) < 0.01:
			var distance := 1.0
			for target in targets:
				if target.kind == "gallery": distance = target.node.view_distance
			point = head.origin - pose.basis.z.normalized() * distance
	capture = {"hand": hand, "input": input, "pose": pose, "targets": targets, "moved": false,
		"local_anchor": pose.affine_inverse() * point, "anchor": point, "last_pose": pose,
		"head": head, "last_motion": Transform3D.IDENTITY, "depth": 0.0, "depth_ready": false,
		"last_angles": Vector2.ZERO, "last_displacement": Vector3.ZERO}
	if head is Transform3D: capture["depth_limits"] = _depth_bounds(targets, point, head.origin)
	for target in targets:
		if target.kind == "menu":
			var up: Vector3 = head.basis.y if following and head is Transform3D else Vector3.UP
			capture["upright_basis"] = _horizontal_basis(target.pose.basis, up)
			capture["upright_pitch"] = asin(clampf(-target.pose.basis.z.normalized().dot(up), -1, 1))
			capture["upright_yaw"] = 0.0
			break
	return true

func cancel() -> void: capture.clear()

func pending() -> bool: return not capture.is_empty() and not capture.moved

## Only the gripping hand changes depth; a stick held before capture must return to centre.
func adjust_distance(stick: Vector2, delta: float) -> bool:
	if capture.is_empty() or not capture.head is Transform3D or not stick.is_finite() or not is_finite(delta) or delta <= 0: return false
	if stick.length() < 0.3: capture.depth_ready = true
	if not capture.depth_ready or absf(stick.y) <= 0.2 or absf(stick.x) >= absf(stick.y): return false
	if capture.targets.all(func(target): return target.kind == "immersive"): return false
	var amount := signf(stick.y) * (absf(stick.y) - 0.2) / 0.8 * DEPTH_SPEED * minf(delta, 0.1)
	var depth := clampf(capture.depth + amount, capture.depth_limits.x, capture.depth_limits.y)
	if is_equal_approx(depth, capture.depth): return false
	capture.depth = depth; capture.moved = true
	return true

## Bound actual panel centres, including off-centre grabs and linked groups, without scaling.
static func _depth_bounds(targets: Array, point: Vector3, head: Vector3) -> Vector2:
	var direction := (point - head).normalized()
	var bounds := Vector2(0.05 - point.distance_to(head), INF)
	for target in targets:
		if target.kind == "immersive": continue
		var limits: Vector2 = target.get("distance_limits", DEPTH_LIMITS)
		var centres: Array = [target.pose.origin]
		if target.kind == "gallery":
			centres = target.node.cards.values().map(func(card): return card.pose.origin)
			if centres.is_empty(): centres.append(point)
		for centre: Vector3 in centres:
			var offset := centre - head
			var along := offset.dot(direction)
			var side_squared := maxf(0, offset.length_squared() - along * along)
			bounds.x = maxf(bounds.x, minf(0, sqrt(maxf(0, limits.x * limits.x - side_squared)) - along))
			bounds.y = minf(bounds.y, maxf(0, sqrt(maxf(0, limits.y * limits.y - side_squared)) - along))
	return bounds

static func _horizontal_basis(basis: Basis, up: Vector3 = Vector3.UP) -> Basis:
	var forward := -basis.z
	forward -= up * forward.dot(up)
	if forward.length_squared() < 0.0001: forward = up.cross(basis.x)
	return Basis.looking_at(forward.normalized(), up)

## Standard menu offsets use heading and gravity; only follow mode uses head tilt.
static func menu_head(head: Transform3D, following: bool = false) -> Transform3D:
	return head if following else Transform3D(_horizontal_basis(head.basis), head.origin)

static func level_menu(basis: Basis) -> Basis:
	var pitch := clampf(asin(clampf(-basis.z.normalized().y, -1, 1)), -MAX_MENU_PITCH, MAX_MENU_PITCH)
	return _horizontal_basis(basis) * Basis(Vector3.RIGHT, pitch) * Basis.from_scale(basis.get_scale())

## Solve yaw/pitch about gravity (or head up in follow mode), never the menu's
## pitched up axis: repeated grabs must not accumulate bank after a vertical drag.
func _menu_swing(initial: Vector3, direction: Vector3) -> Basis:
	var frame: Basis = capture.upright_basis
	var local := frame.transposed() * initial
	var aimed := frame.transposed() * direction.normalized() * initial.length()
	var vertical_radius := Vector2(local.y, local.z).length()
	if vertical_radius < 0.0001: return Basis.IDENTITY
	var pitch := clampf(asin(clampf(aimed.y / vertical_radius, -1, 1)) - atan2(local.y, -local.z), -MAX_MENU_PITCH - capture.upright_pitch, MAX_MENU_PITCH - capture.upright_pitch)
	var pitched := Basis(Vector3.RIGHT, pitch) * local
	var yaw: float = capture.upright_yaw
	if Vector2(aimed.x, aimed.z).length_squared() > 0.000001 and Vector2(pitched.x, pitched.z).length_squared() > 0.000001:
		yaw = wrapf(atan2(-aimed.x, -aimed.z) - atan2(-pitched.x, -pitched.z), -PI, PI)
	capture.upright_yaw = yaw
	return frame * Basis(Vector3.UP, yaw) * Basis(Vector3.RIGHT, pitch) * frame.transposed()

func update(pose: Transform3D, head: Variant, follow: RefCounted) -> bool:
	if capture.is_empty(): return false
	if not pose.is_finite(): cancel(); return false
	# A tracking jump is a per-frame discontinuity, not a limit on a deliberate long drag.
	if pose.origin.distance_to(capture.last_pose.origin) > MAX_TRACKING_STEP_METRES: cancel(); return false
	capture.last_pose = pose
	var anchor: Vector3 = pose * capture.local_anchor
	var displacement: Vector3 = anchor - capture.pose * capture.local_anchor
	var motion := Transform3D.IDENTITY
	if capture.head is Transform3D:
		if not head is Transform3D or not head.is_finite(): cancel(); return false
		var initial: Vector3 = capture.pose * capture.local_anchor - capture.head.origin
		anchor = _sphere_point(pose.origin, pose.basis * capture.local_anchor, head.origin, initial.length() + capture.depth, capture.anchor)
		var swing := Basis.IDENTITY
		if capture.has("upright_basis"):
			swing = _menu_swing(initial, anchor - head.origin)
			# At vertical limits the live grab stops with the menu instead of flipping.
			anchor = head.origin + (swing * initial).normalized() * (initial.length() + capture.depth)
		else:
			swing = Basis(Quaternion(initial.normalized(), (anchor - head.origin).normalized()))
		# Rotation preserves distance and group layout. Only an explicit stick push
		# adds radial translation; physical panel sizes stay unchanged.
		motion = Transform3D(swing, head.origin - swing * capture.head.origin)
		motion.origin += (anchor - head.origin).normalized() * capture.depth
	var before: Vector3 = -capture.pose.basis.z
	var after: Vector3 = -pose.basis.z
	var angles := Vector2(wrapf(atan2(-after.x, -after.z) - atan2(-before.x, -before.z), -PI, PI),
		asin(clampf(after.y, -1, 1)) - asin(clampf(before.y, -1, 1)))
	var immersive: bool = capture.targets.any(func(target): return target.kind == "immersive")
	var translated: bool = pose.origin.distance_to(capture.pose.origin) >= START_METRES
	if capture.head is Transform3D: translated = translated or head.origin.distance_to(capture.head.origin) >= START_METRES
	var pointed: bool = displacement.length() >= START_METRES and angles.length() >= START_RADIANS
	if not capture.moved and not translated and not pointed and (not immersive or angles.length() < 0.07): return false
	capture.moved = true
	capture.anchor = anchor
	for target in capture.targets:
		if not is_instance_valid(target.node): continue
		if target.kind == "immersive":
			var step: Vector2 = angles - capture.last_angles
			target.node.turn_view(step.x, step.y)
		elif target.kind == "gallery":
			if capture.head is Transform3D: target.node.transform_layout(motion * capture.last_motion.affine_inverse())
			else: target.node.translate_layout(displacement - capture.last_displacement)
		else:
			var world: Transform3D = target.pose
			if capture.head is Transform3D: world = motion * world
			else: world.origin += displacement
			if target.kind == "screen": target.node.set_flat_world_pose(world)
			else: target.node.global_transform = world
			if head is Transform3D:
				if target.kind != "detail": follow.capture(target.key, head, world)
				if target.kind in ["menu", "screen", "detail"]:
					var frame: Transform3D = menu_head(head, follow.enabled) if target.kind == "menu" else head
					placements[target.key] = frame.affine_inverse() * world
	capture.last_angles = angles
	capture.last_displacement = displacement
	capture.last_motion = motion
	return true

## Intersect the current controller ray with the fixed head-centred grab sphere.
## A hand outside the sphere may miss it; clamp to its silhouette without changing depth.
static func _sphere_point(origin: Vector3, direction: Vector3, centre: Vector3, radius: float, previous: Vector3) -> Vector3:
	var ray := direction.normalized()
	var offset := origin - centre
	var b := offset.dot(ray)
	var discriminant := b * b - offset.length_squared() + radius * radius
	if ray.length_squared() > 0.5 and discriminant >= 0:
		var root := sqrt(discriminant)
		var near := -b - root
		var far := -b + root
		if far >= 0:
			if near >= 0:
				var first := origin + ray * near
				var second := origin + ray * far
				return first if first.distance_squared_to(previous) <= second.distance_squared_to(previous) else second
			return origin + ray * far
	var closest := offset + ray * maxf(0, -b)
	if closest.length_squared() < 0.000001: closest = previous - centre
	if closest.length_squared() < 0.000001: closest = Vector3.FORWARD
	return centre + closest.normalized() * radius

func placement(key: String, head: Variant) -> Variant:
	return head * placements[key] if head is Transform3D and placements.has(key) else null

func reset() -> void: cancel(); placements.clear()
