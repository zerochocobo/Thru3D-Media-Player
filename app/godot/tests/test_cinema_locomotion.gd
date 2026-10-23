extends SceneTree

const Locomotion := preload("res://scripts/environments/cinema_locomotion.gd")
var checks := 0
var failures: Array[String] = []


func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures.append(message)


func _initialize() -> void:
	call_deferred("run")


func fixture() -> Dictionary:
	return {
		"default_seat": "A1",
		"seats": [{"id": "A1", "eye_position": [0.0, 1.2, 1.0], "yaw": 0.0, "exit_position": [0.0, 0.0, 1.7]},
			{"id": "A2", "eye_position": [2.0, 1.2, 1.0], "yaw": 0.2, "exit_position": [2.0, 0.0, 1.7]}],
		"walkable": [{"min": [-5.0, 0.0, -5.0], "max": [5.0, 0.0, 5.0], "height": 0.0}],
		"colliders": [{"min": [-0.35, 0.0, 0.6], "max": [0.35, 1.05, 1.3]}],
	}


func walker(manifest: Dictionary) -> RefCounted:
	var movement := Locomotion.new()
	movement.configure(manifest)
	movement.set_moving(true)
	movement.step(Vector2.ZERO, 0, 0.016)
	return movement


func advance(movement: RefCounted, axes: Vector2, frames: int = 60) -> void:
	for frame in frames:
		movement.step(axes, 0, 1.0 / 60.0)


func run() -> void:
	var movement := Locomotion.new()
	movement.configure(fixture())
	check(movement.mode == Locomotion.Mode.WATCH and movement.selected_seat == "A1", "Default seat starts in watch mode")
	check(movement.eye_position.is_equal_approx(Vector3(0, 1.2, 1)), "Author eye height is preserved when selecting a seat")
	check(not movement.select_seat("missing") and movement.selected_seat == "A1", "Unknown seat cannot alter the current position")
	check(not movement.teleport_floor(Vector3(0, 0, -2)), "Watch mode cannot silently consume a teleport")
	advance(movement, Vector2.RIGHT)
	check(movement.eye_position.is_equal_approx(Vector3(0, 1.2, 1)), "Watch mode cannot move through held movement axes")
	check(movement.select_seat("A2") and is_equal_approx(movement.yaw, 0.2), "Seat selection applies its authored direction")
	check(movement.select_seat("A1") and movement.set_moving(true), "A seat with a safe aisle exit can enter move mode")
	check(movement.selected_seat.is_empty() and movement.eye_position.is_equal_approx(Vector3(0, 1.65, 1.7)), "Leaving a seat places the standing body in its authored aisle")
	var initial: Vector3 = movement.eye_position
	advance(movement, Vector2.RIGHT)
	check(movement.eye_position == initial and movement.waiting_for_neutral, "Changing modes requires axes to return to centre")
	movement.step(Vector2.ZERO, 0, 0.016)
	advance(movement, Vector2.RIGHT)
	check(movement.eye_position.x > initial.x + 1.7, "Neutral then axis input produces smooth world movement")
	initial = movement.eye_position
	movement.suspend()
	movement.step(Vector2.ZERO, 1.0, 0.016)
	advance(movement, Vector2.RIGHT)
	check(movement.eye_position == initial and movement.waiting_for_neutral, "Menu/focus suspension requires both movement and turn axes to be neutral")
	movement.step(Vector2.ZERO, 0, 0.016)
	advance(movement, Vector2.RIGHT, 10)
	check(movement.eye_position.x > initial.x, "Movement resumes after complete input neutral")
	movement.step(Vector2.ZERO, 1, 0.016)
	var first_yaw: float = movement.yaw
	for frame in 20:
		movement.step(Vector2.ZERO, 1, 0.016)
	check(is_equal_approx(first_yaw, -PI / 6.0) and is_equal_approx(movement.yaw, first_yaw), "A held turn performs exactly one 30 degree snap")
	movement.step(Vector2.ZERO, 0, 0.016)
	movement.step(Vector2.ZERO, 1, 0.016)
	check(is_equal_approx(movement.yaw, -PI / 3.0), "Snap turn rearms only after turn axis neutral")
	check(movement.set_moving(false) and movement.mode == Locomotion.Mode.WATCH, "Move mode exits explicitly")
	check(movement.select_seat("A1") and movement.mode == Locomotion.Mode.WATCH, "Selecting a seat exits movement")

	movement = walker(fixture())
	check(movement.teleport_floor(Vector3(3, 0, -3)), "Teleport accepts a clear floor within the reachable room")
	initial = movement.eye_position
	check(not movement.teleport_floor(Vector3(5, 0, 1)) and movement.eye_position == initial, "Teleport rejects an edge without full body support")
	check(not movement.teleport_floor(Vector3(8, 0, 1)), "Teleport rejects points beyond any floor")
	check(not movement.teleport_floor(Vector3(2, 2, -2)), "Teleport rejects a floating target above the floor")
	check(not movement.teleport_floor(Vector3(0, 0, 1)), "Standing teleport cannot overlap a seat body")
	check(not movement.teleport_floor(Vector3(NAN, 0, 0)), "Invalid coordinates cannot poison the rig")

	var low_ceiling := fixture()
	low_ceiling.colliders.append({"min": [-1, 1.7, -2], "max": [1, 2.1, -1]})
	movement = walker(low_ceiling)
	check(not movement.teleport_floor(Vector3(0, 0, -1.5)), "Teleport checks head clearance")
	var blocked_seat := fixture()
	blocked_seat.colliders.append({"min": [1.8, 1.1, 0.8], "max": [2.2, 1.5, 1.2]})
	movement = Locomotion.new()
	movement.configure(blocked_seat)
	check(not movement.select_seat("A2") and movement.selected_seat == "A1", "Seat selection also checks head clearance")
	var unsafe_exit := fixture()
	unsafe_exit.seats[0].exit_position = [0, 0, 1]
	movement = Locomotion.new()
	movement.configure(unsafe_exit)
	check(not movement.set_moving(true) and movement.mode == Locomotion.Mode.WATCH, "An obstructed authored exit keeps the viewer seated")

	var wall := {
		"seats": [{"id": "start", "eye_position": [-1, 1.2, 0], "exit_position": [-1, 0, 0]}],
		"walkable": [{"min": [-3, 0, -3], "max": [3, 0, 3], "height": 0}],
		"colliders": [{"min": [-0.03, 0, -3], "max": [0.03, 3, 3]}],
	}
	movement = walker(wall)
	check(not movement.teleport_floor(Vector3(1, 0, 0)), "A wall separating a shared floor prevents unreachable teleport")
	advance(movement, Vector2.RIGHT, 180)
	check(movement.eye_position.x < -0.24, "Small movement substeps prevent tunnelling through a thin wall")
	var before_slide: Vector3 = movement.eye_position
	advance(movement, Vector2(1, 1), 30)
	check(movement.eye_position.z > before_slide.z + 0.4 and movement.eye_position.x < -0.24, "Diagonal motion can slide along an obstructing wall")
	wall.colliders[0].max[2] = 1.0
	movement = walker(wall)
	check(movement.teleport_floor(Vector3(1, 0, 0)), "Reachability finds an aisle around a wall instead of requiring a straight line")

	var stairs := {
		"seats": [{"id": "start", "eye_position": [0, 1.2, -0.75], "exit_position": [0, 0, -0.75]}],
		"walkable": [{"min": [-1, 0, -1.5], "max": [1, 0, 0], "height": 0}],
		"colliders": [],
	}
	for stair in 6:
		stairs.walkable.append({"min": [-1, 0, stair * 0.5], "max": [1, 0, (stair + 1) * 0.5], "height": (stair + 1) * 0.1625})
	movement = walker(stairs)
	advance(movement, Vector2(0, 1), 120)
	check(movement.eye_position.z > 2.3 and movement.eye_position.y > 2.5, "Continuous movement follows small staircase elevations")
	check(movement.teleport_floor(Vector3(0, 0, -0.75)), "Teleport can return down connected small stairs")
	stairs.walkable = [{"min": [-1, 0, -1.5], "max": [1, 0, 0], "height": 0}, {"min": [-1, 0, 0], "max": [1, 0, 3], "height": 0.65}]
	movement = walker(stairs)
	advance(movement, Vector2(0, 1), 80)
	check(movement.eye_position.z < -0.2 and is_equal_approx(movement.eye_position.y, 1.65), "A tall stage cannot be climbed as a single step")
	check(not movement.teleport_floor(Vector3(0, 0.65, 1)), "A nearby but disconnected high platform is not a legal teleport")

	var island := fixture()
	island.walkable = [{"min": [-2, 0, 0], "max": [2, 0, 3], "height": 0}, {"min": [-2, 0, -4], "max": [2, 0, -2], "height": 0}]
	movement = walker(island)
	check(not movement.teleport_floor(Vector3(0, 0, -3)), "Disconnected floor islands cannot be teleported between")
	var bounds := fixture()
	bounds.walkable = [{"bounds": [-5, -5, 5, 5], "height": 0}]
	movement = walker(bounds)
	check(movement.mode == Locomotion.Mode.MOVE, "Bounds-style floor manifests remain readable")
	initial = movement.eye_position
	movement.step(Vector2(NAN, 0), 0, 0.016)
	movement.step(Vector2.RIGHT, 0, -1)
	check(movement.eye_position == initial, "Invalid input and non-positive frame deltas leave the rig stable")

	# Pure navigation follows the current source blueprint, never ignored old bake output.
	var manifest: Dictionary = preload("res://scripts/environments/cinema_blueprint.gd").manifest()
	movement = Locomotion.new()
	movement.configure(manifest)
	check(movement.selected_seat == "I12", "The full cinema starts in its authored central ninth-row seat")
	var valid_seats := 0
	var valid_exits := 0
	for seat in manifest.seats:
		if movement.select_seat(str(seat.id)):
			valid_seats += 1
			if movement.set_moving(true):
				valid_exits += 1
	check(valid_seats == 336, "All 336 cinema seat eye volumes are clear")
	check(valid_exits == 336, "All 336 cinema seats have safe standing aisle exits")
	movement.select_seat("I12")
	movement.set_moving(true)
	var front_exit := Vector3.ZERO
	for seat in manifest.seats:
		if str(seat.id) == "A12":
			front_exit = Vector3(seat.exit_position[0], seat.exit_position[1], seat.exit_position[2])
	check(movement.teleport_floor(front_exit), "Full cinema middle-to-front navigation connects via a side staircase")
	check(movement.last_teleport_ms < 100, "Static navigation preparation keeps the first long teleport below 100ms on the test host")
	print("Full cinema navigation: prepare=%dms first_teleport=%dms" % [movement.navigation_prepare_ms, movement.last_teleport_ms])

	for failure in failures:
		push_error(failure)
	print("Cinema locomotion: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
