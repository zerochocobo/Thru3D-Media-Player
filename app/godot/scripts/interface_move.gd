extends RefCounted
## Grip first arms movement. A deliberate displacement commits it; a chord cancels pending movement.
const START_METRES := 0.018
var capture := {}
var placements := {}

func begin(hand: String, input: String, pose: Transform3D, targets: Array) -> bool:
	if not capture.is_empty() or targets.is_empty() or not pose.is_finite(): return false
	capture = {"hand": hand, "input": input, "pose": pose, "targets": targets, "moved": false, "last_angles": Vector2.ZERO, "last_displacement": Vector3.ZERO}
	return true

func cancel() -> void: capture.clear()

func pending() -> bool: return not capture.is_empty() and not capture.moved

func update(pose: Transform3D, head: Variant, follow: RefCounted) -> bool:
	if capture.is_empty(): return false
	if not pose.is_finite(): cancel(); return false
	var displacement: Vector3 = pose.origin - capture.pose.origin
	if displacement.length() > 0.8: cancel(); return false
	var before: Vector3 = -capture.pose.basis.z
	var after: Vector3 = -pose.basis.z
	var angles := Vector2(wrapf(atan2(-after.x, -after.z) - atan2(-before.x, -before.z), -PI, PI),
		asin(clampf(after.y, -1, 1)) - asin(clampf(before.y, -1, 1)))
	var immersive: bool = capture.targets.any(func(target): return target.kind == "immersive")
	if not capture.moved and displacement.length() < START_METRES and (not immersive or angles.length() < 0.07): return false
	capture.moved = true
	for target in capture.targets:
		if not is_instance_valid(target.node): continue
		if target.kind == "immersive":
			var step: Vector2 = angles - capture.last_angles
			target.node.turn_view(step.x, step.y)
		elif target.kind == "gallery":
			target.node.translate_layout(displacement - capture.last_displacement)
		else:
			var world: Transform3D = target.pose
			world.origin += displacement
			if target.kind == "screen": target.node.set_flat_world_pose(world)
			else: target.node.global_transform = world
			if head is Transform3D:
				follow.capture(target.key, head, world)
				if target.kind in ["menu", "screen"]: placements[target.key] = head.affine_inverse() * world
	capture.last_angles = angles
	capture.last_displacement = displacement
	return true

func placement(key: String, head: Variant) -> Variant:
	return head * placements[key] if head is Transform3D and placements.has(key) else null

func reset() -> void: cancel(); placements.clear()
