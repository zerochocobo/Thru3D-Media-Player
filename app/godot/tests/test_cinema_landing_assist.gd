extends SceneTree

const CinemaHost := preload("res://scripts/environments/cinema_environment.gd")
const Blueprint := preload("res://scripts/environments/cinema_blueprint.gd")
const Locomotion := preload("res://scripts/environments/cinema_locomotion.gd")
var checks := 0
var failures: Array[String] = []

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	var env := CinemaHost.new()
	root.add_child(env)
	var camera := Camera3D.new()
	root.add_child(camera)
	camera.position.y = 1.65
	env._camera = camera
	env._manifest = Blueprint.manifest()
	env._movement = Locomotion.new()
	env._movement.configure(env._manifest)
	env._movement.set_moving(true)
	env.active = true
	env.interaction = "move"
	var started := Time.get_ticks_usec()
	# Every step: aim into its vertical face from below, then down from above.
	# The old trace unconditionally marked the upward hit blocked.
	for area in env._manifest.walkable:
		if not str(area.id).begins_with("stair_"): continue
		var x := (float(area.min[0]) + float(area.max[0])) * .5
		var y := float(area.height)
		var z := float(area.min[2])
		var raw: Dictionary = env._arc_segment(Vector3(x, y - .08, z - .12), Vector3(x, y - .08, z + .12))
		check(raw.get("kind") == "riser", "Recognize small upward riser " + area.id)
		var landing: Vector3 = env._landing_destination(raw)
		check(landing.is_finite() and is_equal_approx(landing.y, y), "Upward riser has a safe top landing " + area.id)
		var down: Dictionary = env.ray_hit(Vector3(x, y + 1.3, z + .3), Vector3.DOWN)
		check(down.get("valid", false), "Downward step stays selectable " + area.id)
	for row in [3, 6, 10]:
		var z: float = float(env._manifest.design.stair_start_z) + row * Blueprint.ROW_PITCH + .3
		var y: float = (row * Blueprint.STEPS_PER_ROW + 1) * Blueprint.STAIR_RISER
		for side in [-1.0, 1.0]:
			for forward in [-1.0, 1.0]:
				for pitch in [-.1, 0.0, .1]:
					for drift in [-.04, 0.0, .04]:
						var hit: Dictionary = env.ray_hit(Vector3(side * 12.5, y + 1.2, z), Vector3(drift, pitch, forward))
						check(hit.get("valid", false), "Actual up/down arc tolerates small hand rotations")
	# Sweep hand jitter through the actual front passages, including both clearance
	# margins. The raw centres can be too close to a chair or the next tier edge.
	for row in 14:
		var z := Blueprint.FIRST_ROW_Z + row * Blueprint.ROW_PITCH
		var y := (row + 1) * Blueprint.ROW_RISER
		var deck: Dictionary = env._manifest.walkable.filter(func(a): return a.id == "row_%02d" % (row + 1))[0]
		var previous_back := z - Blueprint.ROW_PITCH + Blueprint.SEAT_Z_OFFSET + Blueprint.SEAT_REAR
		check(is_equal_approx(float(deck.min[2]), previous_back), "Own deck extends to the preceding chair back")
		var feet := Vector3(-.45, y, z + Blueprint.SEAT_Z_OFFSET - .65)
		check(env._movement._standing_at(feet, .01).is_equal_approx(feet), "Feet and front passage remain on the seated viewer's own floor")
		for x in [-10.0, 0.0, 10.0]:
			for offset in [-1.75, -1.65, -1.5, -1.3, -1.10, -.96, -.89]:
				var hit: Dictionary = env.ray_hit(Vector3(x, y + .4, z + offset), Vector3.DOWN)
				check(hit.get("valid", false), "Jitter still lands in row %d at %.2f" % [row + 1, offset])
				if hit.get("valid", false):
					check(env._valid_destination(hit.position), "Snapped point retains full body support")
	var sample_us := Time.get_ticks_usec() - started
	# An actual chair, tall tier face, outer wall and rail must remain blocked.
	for point in [Vector3(0, .2, 5.1), Vector3(16.7, 1, 0), Vector3(14.1, 2, 6)]:
		check(not env.ray_hit(point, Vector3.DOWN).get("valid", false), "Obstruction cannot become a landing: " + str(point))
	var chair: Dictionary = env.ray_hit(Vector3(-.45, 2.5, 5.6), Vector3.DOWN)
	# Aiming at a chair sits there; it is never a standing landing on the chair.
	check(chair.get("kind", "") == "seat" and chair.get("valid", false), "Chair top targets that seat for sitting: %s" % chair)
	var tall: Dictionary = env._arc_segment(Vector3(0, .1, 4.03), Vector3(0, .1, 4.28))
	check(tall.get("kind") == "blocked" and not env._landing_destination(tall).is_finite(), "High platform side stays blocked")
	# Snap cannot cross a thin wall even when both sides share a route elsewhere.
	env._movement._add_collider(AABB(Vector3(0, 0, 1), Vector3(.03, 3, 1)))
	check(not env._snap_segment_clear(Vector3(-.1, 0, 1.5), Vector3(.25, 0, 1.5)), "Nearby snap cannot cross a wall")
	check(env._movement.landing_candidates(Vector3(100, 0, 100), 0).is_empty(), "No long-distance attraction outside the room")
	print("Landing assist workload: %d us for all steps and row jitter samples" % sample_us)
	for failure in failures: push_error(failure)
	print("Cinema landing assist: %d checks, %d failures" % [checks, failures.size()])
	env.free(); camera.free()
	quit(0 if failures.is_empty() else 1)
