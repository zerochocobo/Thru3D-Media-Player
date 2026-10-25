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


func _inside_chair(point: Vector3) -> bool:
	# Chair A2 footprint grown by the standing body radius.
	var inside_x := point.x > 1.65 - Locomotion.BODY_RADIUS and point.x < 2.35 + Locomotion.BODY_RADIUS
	return inside_x and point.z > 0.6 - Locomotion.BODY_RADIUS and point.z < 1.3 + Locomotion.BODY_RADIUS


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
	environment.select(false); environment.saved_seat = "missing-seat"; environment.select(true)
	check(environment.snapshot().seat == "A1", "A stale saved seat safely retains the default seat")
	environment.saved_seat = ""
	check(not environment.poll_sticks(Vector2.RIGHT, Vector2.RIGHT, 0.1), "Watch mode leaves playback stick handling available")
	check(not environment.set_interaction("invalid"), "Unknown interaction mode is rejected")
	var cinema_rig := rig.global_transform
	environment.set_presented(false)
	check(not environment.active and not environment.get_node("GrandCinema").visible, "Incompatible media temporarily hides cinema and interaction")
	check(rig.global_transform.is_equal_approx(original_rig), "Temporary hiding restores ordinary rig coordinates")
	check(not environment.poll_sticks(Vector2.RIGHT, Vector2.ZERO, 0.1), "Hidden cinema consumes no controls")
	check(not environment.set_interaction("move"), "Hidden cinema cannot enter move mode")
	environment.set_presented(true)
	check(environment.active and rig.global_transform.is_equal_approx(cinema_rig), "Presenting cinema again preserves its head position")
	check(not environment.set_interaction("seat"), "Retired seat mode cannot be reactivated")
	check(environment.set_interaction("move"), "Teleport mode exits to collision-safe aisle")
	check(camera.transform.is_equal_approx(tracked_pose), "Teleport mode preserves tracking")
	var before: Vector3 = camera.global_position
	environment.poll_sticks(Vector2.ZERO, Vector2.ZERO, .016)
	environment.poll_sticks(Vector2.RIGHT, Vector2.ZERO, .1)
	check(camera.global_position.is_equal_approx(before), "Left stick never performs continuous translation")
	environment.poll_sticks(Vector2.ZERO, Vector2.RIGHT, .016)
	check(camera.global_position.is_equal_approx(before), "Snap turn pivots around head")
	check(is_equal_approx(environment._head_yaw(), -PI / 6), "Snap turn keeps 30 degree rotation")
	var floor_origin := Vector3(2, 2.5, 3)
	var hit: Dictionary = environment.ray_hit(floor_origin, Vector3.DOWN)
	check(hit.get("valid", false) and hit.points.size() > 2, "Parabolic trace resolves connected floor")
	var chair_hit: Dictionary = environment.ray_hit(Vector3(2, 2.5, 1), Vector3.DOWN)
	check(chair_hit.get("valid", false) and chair_hit.get("kind", "") == "seat" and chair_hit.get("id", "") == "A2",
		"Aiming the arc at a chair targets that seat")
	var edge_hit: Dictionary = environment.ray_hit(Vector3(4.9, 2.5, 3), Vector3.DOWN)
	check(edge_hit.get("valid", false) and edge_hit.snapped and edge_hit.position.x <= 4.78, "Floor edge snaps inward to a fully supported body footprint")
	check(environment.pointer_press("left_hand", floor_origin, Vector3.DOWN), "Owning trigger starts aiming")
	check(not environment.pointer_press("right_hand", floor_origin, Vector3.DOWN), "Second hand cannot steal aim")
	check(not environment.pointer_release("right_hand", floor_origin, Vector3.DOWN, true), "Second hand cannot commit teleport")
	environment.update_pointer("left_hand", floor_origin, Vector3.DOWN)
	var pointer: Node3D = environment.get_node("CinemaPointer_left_hand")
	check(pointer.visible and pointer.has_node("TeleportArc"), "Aiming draws arc and floor ring")
	check(camera.global_position.is_equal_approx(before), "Aiming does not move the rig")
	environment.pointer_release("left_hand", floor_origin, Vector3.DOWN, true)
	check(camera.global_position.is_equal_approx(Vector3(2, 1.65, 3)), "Release commits a safe landing")
	check(camera.transform.is_equal_approx(tracked_pose), "Landing preserves tracking")
	before = camera.global_position
	environment.pointer_press("left_hand", floor_origin, Vector3.DOWN)
	environment.pointer_release("left_hand", Vector3(2, 2.5, 1), Vector3.DOWN, true)
	check(camera.global_position.is_equal_approx(Vector3(2, 1.2, 1)) and environment.snapshot().seat == "A2",
		"Release on a chair sits there at the seated eye position")
	check(environment.interaction == "watch" and is_equal_approx(environment._head_yaw(), 0.0),
		"Sitting ends free movement and faces the screen")
	check(environment.set_interaction("move"), "Free movement resumes from the chosen seat")
	before = camera.global_position
	environment.pointer_press("left_hand", floor_origin, Vector3.DOWN)
	environment.suspend()
	environment.pointer_release("left_hand", Vector3(-2, 2.5, 3), Vector3.DOWN, true)
	check(camera.global_position.is_equal_approx(before), "Focus/menu suspension cancels pending teleport")
	environment._movement._add_collider(AABB(Vector3(-5, 0, -.1), Vector3(10, 4, .2)))
	hit = environment.ray_hit(Vector3(0, 1.7, -2), Vector3.BACK)
	check(not hit.get("valid", false) and hit.kind == "blocked" and hit.position.z < 0, "Arc stops at front wall face, never chooses floor behind it")
	environment._movement._add_collider(AABB(Vector3(1, 1.3, 2), Vector3(2, .2, 2)))
	check(not environment.ray_hit(Vector3(2, 1.0, 3), Vector3.DOWN).get("valid", false), "Low ceiling rejects head and body clearance")
	# A visible floor across a gap must not bypass the connected-component check.
	environment._manifest.walkable.append({"id": "island", "min": [8, 0, -2], "max": [12, 0, 2], "height": 0})
	environment._movement.configure(environment._manifest)
	environment.interaction = "watch"; environment.set_interaction("move")
	check(not environment.ray_hit(Vector3(10, 2, 0), Vector3.DOWN).get("valid", false), "Disconnected platform cannot become a teleport destination")
	environment.set_lighting("auto", true); check(not environment.lights_on, "Automatic lighting darkens on playback")
	environment.set_lighting("auto", false); check(environment.lights_on, "Automatic lighting brightens when paused")
	environment.set_lighting("on", true); check(environment.lights_on, "Manual on overrides playback")
	environment.set_lighting("off", false); check(not environment.lights_on, "Manual off overrides pause")
	environment.set_lighting("auto", true)
	for level in ["low", "dim", "soft"]:
		environment.set_viewing_brightness(level); environment._process(1.0)
		check(is_equal_approx(environment._light_mix, float(CinemaEnvironment.VIEWING_LIGHT_LEVELS[level])), "Auto playback uses viewing level: " + level)
	environment.set_lighting("off", true); environment._process(1.0)
	check(environment._light_mix == 0, "Manual lights off overrides the selected viewing brightness")
	environment.set_lighting("off", false); environment._process(1.0)
	check(is_equal_approx(environment._light_mix, CinemaEnvironment.OFF_IDLE_LEVEL), "Manual off with no film keeps a little house light")
	environment.set_lighting("on", false); environment._process(1.0)
	environment.set_viewing_brightness("dim", true)
	check(environment._light_mix == .08, "Preview applies immediately even while manual lights are on")
	environment.set_viewing_brightness("dim", false); environment._process(1.0)
	check(environment._light_mix == 1, "Ending preview restores the manual house-light mode")
	environment.set_viewing_brightness("invalid")
	check(environment.viewing_brightness == "low", "Invalid viewing level falls back to the original darkest state")
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
	check(real_environment.snapshot().seat == "I12", "Real auditorium selects the ninth-row centre seat")
	check(real_environment._manifest.seats.size() == 336, "Expanded auditorium exposes all 14 by 24 seats")
	check(camera.global_position.is_equal_approx(Vector3(-0.45, 5.25, 19.9)), "Expanded default seat uses its designed giant-screen sightline")
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
	check(valid_seats == 336, "All 336 expanded seat eye volumes remain collision-safe")
	check(valid_exits == 336, "All 336 expanded seats preserve a full-body standing exit")
	check(environment.home(), "Expanded auditorium restores home after exhaustive seat validation")
	check(environment.set_interaction("move"), "Expanded default seat leaves into its narrower authored row aisle")
	var default_seat := _seat(manifest, "I12")
	check(camera.global_position.is_equal_approx(_position(default_seat.exit_position) + Vector3.UP * Locomotion.EYE_HEIGHT), "Expanded default exit preserves standing eye height and floor clearance")
	var front_seat := _seat(manifest, "A12")
	var front_exit := _position(front_seat.exit_position)
	var front_ray := front_exit + Vector3.UP * Locomotion.EYE_HEIGHT
	var hit: Dictionary = environment.ray_hit(front_ray, Vector3.DOWN)
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
	var before: Vector3 = camera.global_position
	for frame in 30: environment.poll_sticks(Vector2(0, 1), Vector2.ZERO, 1.0 / 60.0)
	check(camera.global_position.is_equal_approx(before), "Continuous stair walking stays disabled in teleport mode")
	var rear := Vector3(12.4, 9.1, 27.0)
	hit = environment.ray_hit(rear + Vector3.UP * 1.65, Vector3.DOWN)
	check(hit.get("valid", false), "Rear walkway remains a connected teleport destination")
