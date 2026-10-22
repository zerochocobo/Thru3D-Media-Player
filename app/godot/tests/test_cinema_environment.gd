extends SceneTree

const CinemaEnvironment := preload("res://scripts/environments/cinema_environment.gd")
const Locomotion := preload("res://scripts/environments/cinema_locomotion.gd")
var checks := 0
var failures: Array[String] = []

class Fixture extends "res://scripts/environments/cinema_environment.gd":
	func _begin_loading() -> void:
		_manifest = {
			"default_seat": "A1", "screen": {"position": [0, 3, -4], "width": 8, "height": 5},
			"seats": [{"id": "A1", "eye_position": [0, 1.2, 1], "yaw": 0, "exit_position": [0, 0, 1.7]},
				{"id": "A2", "eye_position": [2, 1.2, 1], "yaw": 0, "exit_position": [2, 0, 1.7]}],
			"walkable": [{"id": "floor", "min": [-5, 0, -5], "max": [5, 0, 5], "height": 0}],
			"colliders": [{"id": "seat_A1_back", "min": [-0.35, 0, 0.6], "max": [0.35, 1.05, 1.3]},
				{"id": "seat_A2_back", "min": [1.65, 0, 0.6], "max": [2.35, 1.05, 1.3]}],
		}
		_movement = Locomotion.new()
		_movement.configure(_manifest)
		_model = Node3D.new()
		_model.name = "GrandCinema"
		add_child(_model)
		is_ready = true
		loading = false


func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures.append(message)


func _initialize() -> void:
	call_deferred("run")


func run() -> void:
	var rig := Node3D.new()
	root.add_child(rig)
	rig.transform = Transform3D(Basis.from_euler(Vector3(0, 0.36, 0)), Vector3(3, 2, 4))
	var camera := Camera3D.new()
	rig.add_child(camera)
	camera.transform = Transform3D(Basis.from_euler(Vector3(0.1, 0.2, 0)), Vector3(0.45, 1.4, 0.35))
	var tracked_pose := camera.transform
	var original_rig := rig.global_transform
	var environment := Fixture.new()
	root.add_child(environment)
	environment.configure(rig, camera)
	check(not environment.active and not environment.selected, "New environment starts deselected")
	environment.select(true)
	check(environment.active and environment.is_ready and environment.snapshot().ready, "Selected prepared scene becomes active")
	check(environment.get_node("GrandCinema").visible, "Active cinema geometry is visible")
	check(camera.global_position.is_equal_approx(Vector3(0, 1.2, 1)), "Default seat aligns the real tracked eye instead of the rig origin")
	check(camera.transform.is_equal_approx(tracked_pose), "Selecting a seat preserves the camera tracking transform")
	check(absf(environment._head_yaw()) < 0.001, "Seat heading cancels the tracked local yaw through the rig")
	check(not environment.poll_sticks(Vector2.RIGHT, Vector2.RIGHT, 0.1), "Watch mode leaves playback stick handling available")
	check(not environment.set_interaction("invalid"), "Unknown interaction mode is rejected")
	var cinema_rig := rig.global_transform
	environment.set_presented(false)
	check(not environment.active and not environment.get_node("GrandCinema").visible, "Incompatible media temporarily hides cinema and interaction")
	check(rig.global_transform.is_equal_approx(cinema_rig), "Temporary hiding keeps the current rig position")
	check(not environment.poll_sticks(Vector2.RIGHT, Vector2.ZERO, 0.1), "Hidden cinema consumes no controls")
	check(not environment.set_interaction("move"), "Hidden cinema cannot enter move mode")
	environment.set_presented(true)
	check(environment.active and rig.global_transform.is_equal_approx(cinema_rig), "Presenting cinema again preserves its head position")
	check(environment.set_interaction("seat"), "Seat-selection mode can be entered")
	check(environment.poll_sticks(Vector2.RIGHT, Vector2.RIGHT, 0.1), "Seat-selection mode consumes playback axes without locomotion")
	check(rig.global_transform.is_equal_approx(cinema_rig), "Seat mode axes do not move the rig")
	var first_origin := Vector3(0, 2.5, 1)
	var second_origin := Vector3(2, 2.5, 1)
	var hit: Dictionary = environment.ray_hit(second_origin, Vector3.DOWN)
	check(hit.get("kind", "") == "seat" and hit.get("id", "") == "A2", "Controller ray resolves a seat target")
	var pointer_changes := [0]
	environment.changed.connect(func(): pointer_changes[0] += 1)
	environment.update_pointer("left_hand", second_origin, Vector3.DOWN)
	var left_pointer := environment.get_node("CinemaPointer_left_hand") as Node3D
	check(left_pointer.visible and left_pointer.get_node("SeatMarker").visible and not left_pointer.get_node("FloorRing").visible, "Seat feedback shows a small 3D marker")
	check(left_pointer.get_node("SeatLabel").text == "A2", "Seat feedback uses only the short authored seat label")
	environment.update_pointer("right_hand", second_origin, Vector3.DOWN)
	var right_pointer := environment.get_node("CinemaPointer_right_hand") as Node3D
	check(right_pointer.visible and right_pointer != left_pointer, "Each controller has an independent feedback node")
	environment.hide_pointer("left_hand")
	check(not left_pointer.visible and right_pointer.visible, "Hiding one controller marker leaves the other visible")
	environment.update_pointer("right_hand", second_origin, Vector3.DOWN, false)
	check(not right_pointer.visible and pointer_changes[0] == 0, "Blocked feedback hides without emitting frame-by-frame state changes")
	environment.update_pointer("right_hand", second_origin, Vector3.DOWN)
	environment.set_presented(false)
	check(not right_pointer.visible, "Temporarily hiding the cinema also clears pointer feedback")
	environment.set_presented(true)
	var resting_hand := Vector3(0, 1.0, 1.1)
	hit = environment.ray_hit(resting_hand, (Vector3(2, 1.2, 1) - resting_hand).normalized())
	check(hit.get("id", "") == "A2", "A hand inside its occupied seat can still point at another seat")
	check(not environment.pointer_press("", second_origin, Vector3.DOWN), "Empty pointer ownership cannot create a capture")
	check(environment.pointer_press("left_hand", second_origin, Vector3.DOWN), "Trigger press captures a seat with hand ownership")
	check(not environment.pointer_press("right_hand", first_origin, Vector3.DOWN), "The other hand cannot replace an active capture")
	check(not environment.pointer_release("right_hand", second_origin, Vector3.DOWN, true), "The other hand cannot commit a capture")
	check(environment.snapshot().seat == "A1", "Seat selection does not execute on trigger press")
	check(environment.pointer_release("left_hand", second_origin, Vector3.DOWN, true), "Owning-hand trigger release is consumed")
	check(environment.snapshot().seat == "A2" and environment.interaction == "watch", "Release on the same seat commits and returns to watch mode")
	check(camera.global_position.is_equal_approx(Vector3(2, 1.2, 1)) and camera.transform.is_equal_approx(tracked_pose), "Selected seat aligns the eye while preserving tracking")
	environment.set_interaction("seat")
	environment.pointer_press("left_hand", first_origin, Vector3.DOWN)
	environment.pointer_release("left_hand", second_origin, Vector3.DOWN, true)
	check(environment.snapshot().seat == "A2", "Moving the ray to a different seat before release cancels the action")
	environment.pointer_press("left_hand", first_origin, Vector3.DOWN)
	environment.pointer_release("left_hand", first_origin, Vector3.DOWN, false)
	check(environment.snapshot().seat == "A2" and environment.snapshot().capture_hand.is_empty(), "Invalidated trigger release cancels and clears capture")
	environment.pointer_press("left_hand", first_origin, Vector3.DOWN)
	environment.cancel_pointer("right_hand")
	check(environment.snapshot().capture_hand == "left_hand", "Unrelated hand cancellation leaves the capture alone")
	environment.cancel_pointer("left_hand")
	check(environment.snapshot().capture_hand.is_empty(), "Owning hand cancellation releases the capture")
	environment._manifest.colliders.append({"id": "wall", "min": [-5, 0, -0.1], "max": [5, 3, 0.1]})
	check(environment.ray_hit(Vector3(0, 1.2, -3), Vector3.BACK).is_empty(), "A seat cannot be selected through a wall")
	environment._manifest.colliders.pop_back()
	environment._manifest.walkable.append({"id": "raised_tier", "min": [-5, 1.3, -0.1], "max": [5, 1.3, 0.1], "height": 1.3})
	check(environment.ray_hit(Vector3(0, 1.2, -3), (Vector3(0, 1.2, 1) - Vector3(0, 1.2, -3)).normalized()).is_empty(), "A seat cannot be selected through a raised platform riser")
	environment._manifest.walkable.pop_back()
	check(environment.home() and environment.snapshot().seat == "A1", "Home restores the authored default seat and watch mode")
	check(environment.set_interaction("move"), "Move mode can leave a seat through its safe authored exit")
	check(camera.global_position.is_equal_approx(Vector3(0, 1.65, 1.7)), "Leaving a seat aligns the tracked head with standing aisle height")
	var before: Vector3 = camera.global_position
	environment.poll_sticks(Vector2.RIGHT, Vector2.ZERO, 0.1, true)
	environment.poll_sticks(Vector2.RIGHT, Vector2.ZERO, 0.1)
	check(camera.global_position.is_equal_approx(before), "Blocked input suspends movement until the real axes return to centre")
	environment.poll_sticks(Vector2.ZERO, Vector2(0, 1), 0.016)
	environment.poll_sticks(Vector2.RIGHT, Vector2(0, 1), 0.1)
	check(camera.global_position.is_equal_approx(before), "Held right vertical input cannot release the full-stick neutral gate before left movement")
	environment.poll_sticks(Vector2.RIGHT, Vector2.ZERO, 0.1)
	check(camera.global_position.is_equal_approx(before), "Releasing the right stick while the left remains held still cannot release the neutral gate")
	environment.poll_sticks(Vector2.ZERO, Vector2.ZERO, 0.016)
	environment.poll_sticks(Vector2.RIGHT, Vector2.ZERO, 0.1)
	check(camera.global_position.x > before.x + 0.17, "Neutral then movement input translates the player rig")
	before = camera.global_position
	environment.poll_sticks(Vector2.ZERO, Vector2(1, 0), 0.016)
	check(camera.global_position.is_equal_approx(before), "Snap turn pivots around the current tracked head")
	check(is_equal_approx(environment._head_yaw(), -PI / 6.0), "Right turn axis rotates the head heading by 30 degrees")
	check(camera.transform.is_equal_approx(tracked_pose), "Movement and snap turn never overwrite the tracking transform")
	var floor_origin := Vector3(2, 2.5, 3)
	hit = environment.ray_hit(floor_origin, Vector3.DOWN)
	check(hit.get("kind", "") == "floor" and hit.get("valid", false), "Move mode ray resolves a reachable standing destination")
	environment.update_pointer("left_hand", floor_origin, Vector3.DOWN)
	check(left_pointer.visible and left_pointer.get_node("FloorRing").visible and not left_pointer.get_node("SeatMarker").visible and not left_pointer.get_node("SeatLabel").visible, "Move feedback shows a floor ring without explanatory text")
	check(left_pointer.global_position.is_equal_approx(Vector3(2, 0.025, 3)), "Move feedback ring sits just above the destination floor")
	environment.suspend()
	check(not left_pointer.visible and not right_pointer.visible, "Suspending interaction clears both controller markers")
	check(environment.pointer_press("right_hand", floor_origin, Vector3.DOWN), "Reachable floor supports trigger capture")
	environment.pointer_release("right_hand", floor_origin, Vector3.DOWN, true)
	check(camera.global_position.is_equal_approx(Vector3(2, 1.65, 3)), "Same-point release commits a floor teleport")
	var source_transform := rig.global_transform
	environment._manifest.colliders.append({"id": "wall", "min": [-5, 0, 0.9], "max": [5, 3, 1.1]})
	check(environment.ray_hit(Vector3(2, 1.65, 0), Vector3(0, -0.2, 1).normalized()).is_empty(), "A floor cannot be targeted through an obstructing wall")
	environment._manifest.colliders.pop_back()
	check(rig.global_transform.is_equal_approx(source_transform), "Ray queries never move the player")
	environment.select(false)
	check(not environment.active and not environment.selected and rig.global_transform.is_equal_approx(original_rig), "Closing cinema restores the rig from before entering the scene")
	check(camera.transform.is_equal_approx(tracked_pose), "Closing cinema leaves the camera tracking pose intact")
	environment.queue_free()
	await process_frame
	rig.queue_free()
	await process_frame

	# Exercise the real asynchronous ResourceLoader + navigation thread path once.
	rig = Node3D.new()
	root.add_child(rig)
	camera = Camera3D.new()
	rig.add_child(camera)
	camera.position = Vector3(0.3, 1.6, -0.2)
	var real_environment := CinemaEnvironment.new()
	root.add_child(real_environment)
	real_environment.configure(rig, camera)
	var started := Time.get_ticks_msec()
	real_environment.select(true)
	var selection_ms := Time.get_ticks_msec() - started
	check(selection_ms < 100 and real_environment.loading, "Selecting the bundled scene starts background loading without synchronous navigation")
	var loading_pose := rig.global_transform
	real_environment.select(false)
	var frames := 0
	while real_environment.loading and Time.get_ticks_msec() - started < 30000:
		await process_frame
		frames += 1
	check(real_environment.is_ready and real_environment.error.is_empty(), "Bundled GLB loads through its imported PackedScene and navigation worker")
	check(not real_environment.active and rig.global_transform.is_equal_approx(loading_pose), "Deselecting during loading prevents late completion from moving the player")
	real_environment.select(true)
	check(real_environment.active and real_environment.has_node("GrandCinema"), "Asynchronous completion presents the real auditorium")
	check(real_environment.snapshot().seat == "I15", "Real auditorium selects the ninth-row centre seat")
	check(real_environment._manifest.seats.size() == 420, "Expanded auditorium exposes all 14 by 30 seats")
	check(camera.global_position.is_equal_approx(Vector3(-0.4, 7.05, 17.65)), "Expanded default seat uses its designed giant-screen sightline")
	check(frames > 1, "The main loop remains responsive while cinema navigation is prepared")
	print("Cinema environment load: select=%dms complete=%dms frames=%d" % [selection_ms, Time.get_ticks_msec() - started, frames])
	_validate_expanded_auditorium(real_environment, camera)
	real_environment.select(false)
	real_environment.queue_free()
	rig.queue_free()
	await process_frame
	for failure in failures:
		push_error(failure)
	print("Cinema environment: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)


func _seat(manifest: Dictionary, id: String) -> Dictionary:
	for seat in manifest.seats:
		if str(seat.id) == id:
			return seat
	return {}


func _position(value: Array) -> Vector3:
	return Vector3(value[0], value[1], value[2])


func _validate_expanded_auditorium(environment: Node3D, camera: Camera3D) -> void:
	var manifest: Dictionary = environment._manifest
	var movement: RefCounted = environment._movement
	var valid_seats := 0
	var valid_exits := 0
	for seat in manifest.seats:
		if movement.select_seat(str(seat.id)):
			valid_seats += 1
			if movement.set_moving(true):
				valid_exits += 1
	check(valid_seats == 420, "All 420 expanded seat eye volumes remain collision-safe")
	check(valid_exits == 420, "All 420 expanded seats preserve a full-body standing exit")
	check(environment.home(), "Expanded auditorium restores home after exhaustive seat validation")
	var neighbour := _seat(manifest, "I16")
	var hand_origin := camera.global_position + Vector3(0.18, -0.25, -0.2)
	var direction := (_position(neighbour.eye_position) - hand_origin).normalized()
	environment.set_interaction("seat")
	var hit: Dictionary = environment.ray_hit(hand_origin, direction)
	check(hit.get("id", "") == "I16", "Thirty-seat row allows a seated controller to target the adjacent seat")
	var far_seat := _seat(manifest, "I30")
	var through_row: Dictionary = environment.ray_hit(hand_origin, (_position(far_seat.eye_position) - hand_origin).normalized())
	check(through_row.get("id", "") == "I16", "Dense row ray keeps the first visible seat target instead of selecting through the intervening seats")
	if hit.get("id", "") == "I16":
		environment.pointer_press("right_hand", hand_origin, direction)
		environment.pointer_release("right_hand", hand_origin, direction, true)
		check(environment.snapshot().seat == "I16", "Expanded adjacent-seat trigger capture commits on release")
	environment.home()
	check(environment.set_interaction("move"), "Expanded default seat leaves into its narrower authored row aisle")
	var default_seat := _seat(manifest, "I15")
	check(camera.global_position.is_equal_approx(_position(default_seat.exit_position) + Vector3.UP * Locomotion.EYE_HEIGHT), "Expanded default exit preserves standing eye height and floor clearance")
	var front_seat := _seat(manifest, "A15")
	var front_exit := _position(front_seat.exit_position)
	var front_ray := front_exit + Vector3.UP * Locomotion.EYE_HEIGHT
	hit = environment.ray_hit(front_ray, Vector3.DOWN)
	check(hit.get("kind", "") == "floor" and hit.get("valid", false), "Expanded middle-to-front row exits remain connected through the small stairs")
	if hit.get("valid", false):
		environment.pointer_press("right_hand", front_ray, Vector3.DOWN)
		environment.pointer_release("right_hand", front_ray, Vector3.DOWN, true)
		check(camera.global_position.is_equal_approx(front_exit + Vector3.UP * Locomotion.EYE_HEIGHT), "Expanded cross-row floor trigger path commits a safe destination")
	var first_step: Dictionary = {}
	for area in manifest.walkable:
		if str(area.id) == "stair_right_01_0":
			first_step = area
			break
	check(not first_step.is_empty(), "Expanded auditorium provides explicit small staircase steps")
	if first_step.is_empty():
		return
	var stair_floor := (_position(first_step.min) + _position(first_step.max)) * 0.5
	stair_floor.y = float(first_step.height)
	var stair_ray := stair_floor + Vector3.UP * Locomotion.EYE_HEIGHT
	hit = environment.ray_hit(stair_ray, Vector3.DOWN)
	check(hit.get("valid", false), "Expanded side staircase is reachable from the row aisle")
	if not hit.get("valid", false):
		return
	environment.pointer_press("right_hand", stair_ray, Vector3.DOWN)
	environment.pointer_release("right_hand", stair_ray, Vector3.DOWN, true)
	environment.poll_sticks(Vector2.ZERO, Vector2.ZERO, 1.0 / 60.0)
	var largest_rise := 0.0
	for frame in 900:
		var previous := camera.global_position.y
		environment.poll_sticks(Vector2(0, 1), Vector2.ZERO, 1.0 / 60.0)
		largest_rise = maxf(largest_rise, absf(camera.global_position.y - previous))
	check(camera.global_position.z > 26.3 and is_equal_approx(camera.global_position.y, 10.75), "Continuous movement climbs the 14-row staircase to the rear walkway")
	check(largest_rise <= 0.163, "Expanded staircase never climbs a full 0.65 metre row in one movement step")
	for frame in 900:
		environment.poll_sticks(Vector2(0, -1), Vector2.ZERO, 1.0 / 60.0)
	check(camera.global_position.z < 8.0 and camera.global_position.y < 2.0, "Continuous movement can descend the expanded staircase back to its first step")
