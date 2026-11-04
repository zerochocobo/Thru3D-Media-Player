extends SceneTree

const Host := preload("res://scripts/environments/cinema_environment.gd")
const Motion := preload("res://scripts/environments/cinema_locomotion.gd")
const Targets := preload("res://scripts/environments/cinema_seat_targets.gd")
var env: Node3D
var rig: Node3D
var camera: Camera3D
var checks := 0
var failures: Array[String] = []
var feedback: Array[String] = []

func _initialize() -> void:
	call_deferred("run")

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func position(value: Variant) -> Vector3:
	return Vector3(float(value[0]), float(value[1]), float(value[2]))

func ballistic(origin: Vector3, target: Vector3, high: bool = false) -> Vector3:
	var delta := target - origin
	var horizontal := Vector3(delta.x, 0, delta.z)
	var r := horizontal.length()
	var discriminant := pow(8.5, 4) - 9.8 * (9.8 * r * r + 2 * delta.y * 8.5 * 8.5)
	if discriminant < 0: return Vector3.ZERO
	var pitch := atan((8.5 * 8.5 + (1 if high else -1) * sqrt(discriminant)) / (9.8 * r))
	return horizontal.normalized() * cos(pitch) + Vector3.UP * sin(pitch)

func setup() -> void:
	env = Host.new(); root.add_child(env)
	rig = Node3D.new(); root.add_child(rig)
	camera = Camera3D.new(); rig.add_child(camera); camera.position.y = 1.65
	env._rig = rig; env._camera = camera
	env._manifest = JSON.parse_string(FileAccess.get_file_as_string(Host.MANIFEST_PATH))
	env._movement = Motion.new(); env._movement.configure(env._manifest)
	env._movement.set_moving(true)
	env.active = true; env.interaction = "move"
	env.seat_hovered.connect(func(hand: String): feedback.append(hand))

func run() -> void:
	setup()
	var source := position(env._movement._seats.I12.exit_position) + Vector3.UP * 1.2
	var begin := Time.get_ticks_usec()
	# Regression for the reported acquisition problem, including diagonal neighbours,
	# two rows down/up, and small changes of controller pitch/yaw.
	for id in ["I12", "I13", "I14", "H12", "G12", "J12", "K12"]:
		var marker: Vector3 = env._movement.seat_targets.marker(id)
		var direction := ballistic(source, marker)
		for yaw in [-1.0, 0.0, 1.0]:
			for pitch in [-1.0, 0.0, 1.0]:
				var ray := direction.rotated(Vector3.UP, deg_to_rad(yaw))
				ray = ray.rotated(ray.cross(Vector3.UP).normalized(), deg_to_rad(pitch))
				var hit: Dictionary = env.ray_hit(source, ray)
				check(hit.get("id", "") == id, "Cushion acquisition %s yaw=%s pitch=%s got=%s" % [id, yaw, pitch, hit.get("id", hit.kind)])
				check(hit.points[-1].is_equal_approx(hit.position + Vector3.UP * Targets.MARKER_LIFT), "Seat arc ends on displayed ring")
	# Every authored seat and edge, without ever expanding horizontally across the
	# adjoining seat's centre boundary. Preserve each row's standing exit as well.
	for seat in env._manifest.seats:
		var marker: Vector3 = env._movement.seat_targets.marker(seat.id)
		for offset in [Vector3.ZERO, Vector3(0, 0, -.46), Vector3(0, 0, .41)]:
			var hit: Dictionary = env.ray_hit(marker + offset + Vector3.UP * 2, Vector3.DOWN)
			check(hit.get("id", "") == seat.id, "Chair centre/front assist/backrest %s %s" % [seat.id, offset])
		if int(seat.row) < 14:
			var upper: Dictionary = env.ray_hit(marker + Vector3(0, 2, .53), Vector3.DOWN)
			check(upper.kind == "floor" and upper.valid, "Past the backrest aims at upper row passage " + seat.id)
		var exit_hit: Dictionary = env.ray_hit(position(seat.exit_position) + Vector3.UP * .4, Vector3.DOWN)
		check(exit_hit.get("kind", "") == "floor" and exit_hit.get("valid", false), "Authored aisle exit stays standing " + seat.id)
	var high_arc := ballistic(source, env._movement.seat_targets.marker("K12"), true)
	check(env.ray_hit(source, high_arc).get("id", "") == "K12", "Rising arc crosses foreground chairs without selecting them")
	var back := position(env._movement._seats.I12.eye_position) + Vector3(0, -.22, .14)
	for offset in [Vector3(0, .7, 1.2), Vector3(2, .7, .6), Vector3(-2, .7, .6)]:
		check(env.ray_hit(back + offset, ballistic(back + offset, back)).get("id", "") == "I12",
			"Backrest can be acquired from behind and both sides " + str(offset))
	print("Seat acquisition sweep: %d us" % (Time.get_ticks_usec() - begin))
	_stability()
	_blockers(source)
	_release_and_visuals(source)
	for failure in failures: push_error(failure)
	print("Cinema seat targeting: %d checks, %d failures" % [checks, failures.size()])
	env.free(); rig.free()
	quit(0 if failures.is_empty() else 1)

func _stability() -> void:
	var marker: Vector3 = env._movement.seat_targets.marker("I12")
	# Neighbour boundary at x=0. Acquire one seat immediately, tolerate tiny
	# crossings for at most 120 ms, but switch immediately for clear movement.
	var origin := Vector3(-.02, marker.y + 2, marker.z)
	env._capture = {"aiming": true}
	check(env._pointer_target(origin, Vector3.DOWN, 1000).id == "I12", "No dwell needed for acquisition")
	origin.x = .02
	check(env._pointer_target(origin, Vector3.DOWN, 1080).id == "I12", "Small boundary jitter retains highlighted seat")
	check(env._pointer_target(origin, Vector3.DOWN, 1121).id == "I13", "Retention expires without extending itself")
	origin.x = -.2
	check(env._pointer_target(origin, Vector3.DOWN, 1130).id == "I12", "Clear change to neighbour is immediate")
	origin = position(env._movement._seats.I12.exit_position) + Vector3.UP * 1.2
	check(env._pointer_target(origin, Vector3.DOWN, 1140).kind == "floor", "Aiming at passage immediately clears seat retention")
	check(not env._capture.has("target_id"), "No stale seat retained on floor")
	env._pointer_target(marker + Vector3.UP * 2, Vector3.DOWN, 1200)
	check(env._pointer_target(Vector3(INF, 0, 0), Vector3.DOWN, 1210).is_empty(), "Invalid pose cannot replay a seat")
	env.suspend()
	check(env._capture.is_empty(), "Suspension clears retention state")

func _blockers(source: Vector3) -> void:
	# A full height wall before the chair, and a thin wall between a near-miss
	# ray and its attraction point, must defeat both new and retained candidates.
	var original_count: int = env._movement._colliders.size()
	env._movement._add_collider(AABB(Vector3(-11, 0, 19.3), Vector3(22, 25, .03)))
	var direction := ballistic(source, env._movement.seat_targets.marker("I13"))
	check(env.ray_hit(source, direction).kind == "blocked", "Wall occludes selectable volumes")
	check(env.ray_hit(source, direction, "I13").kind == "blocked", "Held candidate cannot bypass wall")
	_restore_colliders(original_count)
	var marker: Vector3 = env._movement.seat_targets.marker("I12")
	env._movement._add_collider(AABB(Vector3(-1, 6.48, 19.5), Vector3(1, 3, .02)))
	var near_wall := Vector3(marker.x, marker.y + 2, 19.47)
	check(env.ray_hit(near_wall, Vector3.DOWN).kind != "seat", "Assist connector cannot cross thin wall")
	_restore_colliders(original_count)
	# The preview must agree with the commit's head-clearance validation.
	var eye := position(env._movement._seats.I12.eye_position)
	env._movement._add_collider(AABB(eye - Vector3(.1, .05, .1), Vector3(.2, .1, .2)))
	check(env.ray_hit(marker + Vector3.UP * .3, Vector3.DOWN).kind != "seat", "Blocked head never previews a valid seat")
	_restore_colliders(original_count)

func _restore_colliders(count: int) -> void:
	var boxes: Array = env._movement._colliders.slice(0, count)
	env._movement._colliders.clear(); env._movement._collider_hash.clear()
	for box in boxes: env._movement._add_collider(box)

func _release_and_visuals(source: Vector3) -> void:
	var marker: Vector3 = env._movement.seat_targets.marker("I13")
	var direction := ballistic(source, marker)
	env.pointer_press("right_hand", source, direction)
	var visual: Dictionary = env._pointer_visuals.right_hand
	check(visual.seat.visible and visual.floor.visible, "Seat outline accompanies ring")
	check(visual.material.albedo_color.r > .9, "Seat feedback differs from green standing ring")
	check(feedback == ["right_hand"], "First acquisition sends one owning-hand feedback event")
	for frame in 8: env.update_pointer("right_hand", source, direction)
	check(feedback.size() == 1, "Stable hover never repeats haptics")
	check(not env.pointer_release("left_hand", source, direction, true), "Wrong hand cannot commit")
	env.pointer_release("right_hand", source, direction, true)
	check(env.saved_seat == "I13" and env.interaction == "watch", "Release seats the highlighted chair and resumes watching")
	check(camera.global_position.is_equal_approx(position(env._movement._seats.I13.eye_position)), "Seat aligns tracked eye with authored position")
	check(env._capture.is_empty() and not visual.root.visible, "Commit clears pointer and hold")
	env.set_interaction("move")
	env.pointer_press("right_hand", source, direction)
	env.update_pointer("right_hand", source, direction, false)
	check(env._capture_hand.is_empty(), "Tracking loss cancels capture")
	var before := camera.global_position
	check(not env.pointer_release("right_hand", source, direction, true) and camera.global_position == before, "Release after cancellation cannot teleport")
	var boundary := Vector3(-.02, marker.y + 2, marker.z)
	env.pointer_press("right_hand", boundary, Vector3.DOWN)
	check(env._capture.get("target_id", "") == "I12", "Boundary preview acquires first seat")
	boundary.x = .02
	env.pointer_release("right_hand", boundary, Vector3.DOWN, true)
	check(env.saved_seat == "I12", "Small release drift commits the highlighted seat")
