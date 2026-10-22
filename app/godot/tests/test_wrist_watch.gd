extends SceneTree
const Logic := preload("res://scripts/wrist_watch_logic.gd")
var checks := 0
var failures: Array[String] = []
var head := Transform3D.IDENTITY
var wrist := Transform3D.IDENTITY
var normal := Vector3.ZERO
var close := Transform3D.IDENTITY
var media := {"has_video": true, "playing": true, "position_ms": 600_000, "duration_ms": 6_000_000}

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok: failures.append(label)

func _initialize() -> void:
	head = Transform3D(Basis.IDENTITY, Vector3(0, 1.6, 0))
	var origin := Vector3(-0.09, 1.25, -0.35)
	normal = (head.origin - origin).normalized()
	var side := normal.cross(Vector3(-1, 0.15, 0.2).normalized()).normalized()
	wrist = Transform3D(Basis(side, normal, side.cross(normal).normalized()), origin)
	head = head.looking_at(origin, Vector3.UP)
	close = Transform3D(wrist.basis, head.origin + (origin - head.origin).normalized() * 0.25)
	glance_rules()
	approach()
	following()
	buttons()
	skipping()
	scrubbing()
	for failure in failures: push_error(failure)
	print("Wrist watch: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)

func run(logic: Logic, tip: Variant, frames: int = 1, pose: Variant = null, view: Variant = null, enabled: bool = true) -> Array[Dictionary]:
	var actions: Array[Dictionary] = []
	for i in frames:
		actions.append_array(logic.update({"head": view if view != null else head, "wrist": pose if pose != null else wrist,
			"tip": tip, "enabled": enabled, "media": media}, 1.0 / 72.0))
	return actions

func shown() -> Logic:
	var logic := Logic.new()
	run(logic, null, 20)
	return logic

func expanded() -> Logic:
	var logic := shown()
	run(logic, null, 30, close)
	run(logic, null, 40)
	return logic

func at(logic: Logic, planar: Vector2, depth: float) -> Vector3:
	return logic.holo * Vector3(planar.x, planar.y, depth)

func press(logic: Logic, planar: Vector2, depth: float = 0.004, pose: Variant = null) -> Array[Dictionary]:
	var actions := run(logic, at(logic, planar, 0.045), 12, pose)
	actions.append_array(run(logic, at(logic, planar, depth), 12, pose))
	actions.append_array(run(logic, at(logic, planar, 0.05), 12, pose))
	return actions

func ops(actions: Array[Dictionary]) -> Array:
	return actions.map(func(action): return action.op)

func seeks(actions: Array[Dictionary]) -> Array:
	return actions.filter(func(a): return a.op == "seek").map(func(a): return int(a.position_ms))

func glance_rules() -> void:
	var logic := Logic.new()
	run(logic, null, 5)
	check(logic.phase == Logic.Phase.HIDDEN, "A brief pass across the view does not show the face")
	run(logic, null, 10)
	check(logic.phase == Logic.Phase.GLANCE, "Holding the glance shows the face")
	var away := head.looking_at(head.origin + Vector3(1, 0.5, -0.2), Vector3.UP)
	run(logic, null, 40, null, away)
	check(logic.phase == Logic.Phase.GLANCE, "Where the head points does not matter")
	var palm_up := Transform3D(wrist.basis.rotated(wrist.basis.z.normalized(), PI), wrist.origin)
	run(logic, null, 10, palm_up)
	check(logic.phase == Logic.Phase.GLANCE, "A brief turn keeps the face (hysteresis)")
	run(logic, null, 40, palm_up)
	check(logic.phase == Logic.Phase.HIDDEN, "Turning the palm up hides the face")
	var palm := Transform3D(wrist.basis.rotated(wrist.basis.z.normalized(), PI), wrist.origin)
	logic = Logic.new()
	run(logic, null, 40, palm)
	check(logic.phase == Logic.Phase.HIDDEN, "The palm side facing the eyes is not a glance")
	var lap := Transform3D(wrist.basis, head.origin + Vector3(0, -0.75, -0.2))
	run(logic, null, 40, lap, head.looking_at(lap.origin, Vector3.UP))
	check(logic.phase == Logic.Phase.HIDDEN, "A hand resting far below is not a glance")
	var middle := Transform3D(wrist.basis, Vector3(0.0, wrist.origin.y, wrist.origin.z))
	logic = Logic.new()
	run(logic, null, 40, middle, head.looking_at(middle.origin, Vector3.UP))
	check(logic.phase == Logic.Phase.GLANCE, "The watch shows wherever the wrist sits around the body")
	logic = shown()
	run(logic, null, 1, null, null, false)
	check(logic.phase == Logic.Phase.HIDDEN, "Disabling hides immediately")

func approach() -> void:
	var logic := shown()
	run(logic, wrist.origin + normal * 0.004, 30)
	check(logic.phase == Logic.Phase.GLANCE, "Touching the face projects nothing")
	run(logic, null, 8, close)
	check(not logic.expanded() and logic.charge > 0.5, "A brief raise only charges the face")
	run(logic, null, 20)
	check(not logic.expanded() and logic.charge < 0.2, "Lowering drains the charge")
	logic = expanded()
	check(logic.expanded(), "Raising the wrist toward the eyes projects the disc")
	var fingers := -wrist.basis.z.normalized()
	fingers = (fingers - normal * fingers.dot(normal)).normalized()
	var offset := logic.holo.origin - logic.face.origin
	check(absf(offset.dot(normal) - Logic.HOLO_HEIGHT) < 0.003 and absf(offset.dot(fingers) - Logic.HOLO_FORWARD) < 0.003,
		"The disc is cast out and forward along the fingers")
	check(logic.holo.basis.z.dot(normal) > 0.99, "The disc lies parallel to the back of the hand")
	check(logic.holo.basis.y.dot(head.basis.y) > 0.3, "Keys stand upright for the viewer")
	var lowered := Transform3D(wrist.basis, head.origin + Vector3(-0.1, -0.7, -0.2))
	run(logic, null, 220, lowered)
	check(not logic.expanded(), "Lowering the wrist collapses the disc")
	logic = shown()
	run(logic, null, 30, close)
	press(logic, Logic.button_position("menu"), 0.004, close)
	run(logic, null, 60, close)
	check(not logic.expanded(), "Staying close after the menu folded the disc does not project again")
	logic = shown()
	run(logic, null, 30, close)
	var flipped := Transform3D(close.basis.rotated(close.basis.z.normalized(), PI), close.origin)
	run(logic, null, 12, flipped)
	check(not logic.expanded(), "Turning the wrist over closes the disc at once")
	var dark := Transform3D(close.basis.rotated(close.basis.z.normalized(), PI), close.origin)
	run(logic, null, 40, dark)
	run(logic, null, 40, close)
	check(logic.expanded(), "Turning the face back after it went dark projects again, even without lowering")

func following() -> void:
	var logic := expanded()
	var moved := Transform3D(wrist.basis, wrist.origin + Vector3(0.03, -0.02, 0.01))
	var expected := logic.holo.origin + Vector3(0.03, -0.02, 0.01)
	run(logic, null, 60, moved)
	check(logic.holo.origin.distance_to(expected) < 0.003, "The projection rides on the wrist without stretching")
	var tilted := Transform3D(moved.basis.rotated(moved.basis.z.normalized(), 0.35), moved.origin)
	run(logic, null, 60, tilted)
	check(logic.holo.basis.z.dot(tilted.basis.y.normalized()) > 0.99, "Rolling the wrist tilts the disc with it")
	# The right hand over the disc covers the left hand, whose tracking then drifts.
	var held := logic.holo
	var face_held := logic.face.origin
	var drifted := Transform3D(tilted.basis, tilted.origin + Vector3(0, 0.04, 0.03))
	var tip := at(logic, Vector2(0.02, 0.03), 0.04)
	run(logic, tip, 60, drifted)
	check(logic.locked and logic.holo.is_equal_approx(held), "The disc locks while the finger works it")
	check(logic.face.origin.distance_to(face_held) < 0.001, "The face ignores the covered hand's drift")
	run(logic, null, 60, drifted)
	check(not logic.locked and logic.holo.origin.distance_to(held.origin) > 0.03, "Once the finger leaves, the disc returns to the wrist")

func buttons() -> void:
	var logic := expanded()
	var play := Logic.button_position("play")
	var actions := press(logic, play)
	check(ops(actions) == ["play"], "Touching the centre toggles playback: " + str(ops(actions)))
	check(logic.expanded(), "Play keeps the disc open")
	actions = run(logic, at(logic, play, 0.045), 12)
	actions.append_array(run(logic, at(logic, play, 0.004), 80))
	check(ops(actions) == ["play"], "Holding a finger on play does not repeat it")
	actions = press(logic, play, 0.009)
	check(ops(actions) == ["play"], "The touch lands a centimetre above the key, before the finger covers it")
	actions = press(logic, play + Vector2(0, 0.03))
	check(ops(actions) == ["play"], "A finger just off the key is caught by it")
	check(logic.owns_tip(), "A finger near the disc belongs to the watch")
	actions = press(logic, Logic.button_position("menu"))
	check(ops(actions) == ["menu"] and not logic.expanded(), "Menu opens the player menu and folds the disc")
	logic = expanded()
	actions = press(logic, Vector2(-0.07, 0.06))
	check(actions.is_empty() and logic.expanded(), "Touching empty space does nothing")

func skipping() -> void:
	var logic := expanded()
	var actions := press(logic, Logic.button_position("rewind"))
	check(seeks(actions) == [590_000], "A tap on rewind jumps back 10 s: " + str(seeks(actions)))
	actions = press(logic, Logic.button_position("rewind"))
	check(seeks(actions) == [580_000], "Quick taps build on the last target, not the lagging position")
	logic = expanded()
	var forward := Logic.button_position("forward")
	actions = run(logic, at(logic, forward, 0.045), 12)
	actions.append_array(run(logic, at(logic, forward, 0.004), int(72 * 2.6)))
	var targets := seeks(actions)
	check(targets.size() >= 6, "Holding forward keeps jumping: " + str(targets))
	var steps: Array = []
	for i in range(1, targets.size()): steps.append(targets[i] - targets[i - 1])
	check(targets[0] == 610_000 and steps.size() >= 5 and steps[0] == 10_000 and steps[-1] == 30_000, "Held skips speed up to 30 s steps: " + str(steps))
	check(logic.skip_total == (targets[-1] - 600_000) / 1000, "The readout total follows the run")
	actions = run(logic, at(logic, forward, 0.05), 20)
	check(seeks(actions).is_empty(), "Lifting the finger stops the run")

func drag(logic: Logic, from: float, to: float, radius: float, steps: int = 40) -> Array[Dictionary]:
	var actions: Array[Dictionary] = []
	for i in steps + 1:
		var a := deg_to_rad(lerpf(from, to, float(i) / steps))
		actions.append_array(run(logic, at(logic, Vector2(sin(a), cos(a)) * radius, 0.004), 2))
	actions.append_array(run(logic, at(logic, Vector2(sin(deg_to_rad(to)), cos(deg_to_rad(to))) * radius, 0.004), 20))
	return actions

func grab(logic: Logic, angle: float) -> void:
	var p := Vector2(sin(deg_to_rad(angle)), cos(deg_to_rad(angle))) * Logic.PROGRESS_RING
	run(logic, at(logic, p, 0.045), 12)
	run(logic, at(logic, p, 0.004), 12)

func scrubbing() -> void:
	var logic := expanded()
	grab(logic, 70.0)
	check(not logic.scrub.is_empty(), "Touching the arc grabs the timeline")
	check(absf(logic.scrub_value() - 600_000) < 1, "Grabbing does not jump to the finger")
	drag(logic, 70.0, 136.0, Logic.PROGRESS_RING)
	var arc_length := PI * Logic.PROGRESS_RING
	var expected := 600_000 + 6_000_000 * (deg_to_rad(66.0) * Logic.PROGRESS_RING - Logic.GRAB_SLOP) / arc_length
	check(absf(logic.scrub_value() - expected) < 30_000, "Coarse: the half arc spans the video: %d vs %d" % [logic.scrub_value(), expected])
	var fine := Logic.PROGRESS_RING + Logic.FINE_ZONE + 0.02
	run(logic, at(logic, Vector2(sin(deg_to_rad(136.0)), cos(deg_to_rad(136.0))) * fine, 0.004), 30)
	check(logic.level == Logic.Level.FINE, "Moving out past the arc selects the fine level")
	var before := logic.scrub_value()
	drag(logic, 136.0, 136.0 + rad_to_deg(0.05 / Logic.PROGRESS_RING), fine)
	var fine_change := logic.scrub_value() - before
	check(absf(fine_change - 10_000) < 1_500, "Fine: about 2 s per centimetre: %d" % fine_change)
	var actions := run(logic, at(logic, Vector2(0, fine), 0.07), 10)
	check("seek" in ops(actions), "Lifting the finger commits the seek")
	logic = expanded()
	grab(logic, 90.0)
	drag(logic, 90.0, 90.2, Logic.PROGRESS_RING, 4)
	actions = run(logic, at(logic, Vector2(0, Logic.PROGRESS_RING), 0.07), 10)
	check("seek" not in ops(actions), "A tiny drag is not a seek")
	logic = expanded()
	grab(logic, 90.0)
	drag(logic, 90.0, 120.0, Logic.PROGRESS_RING)
	actions = run(logic, null, 3)
	check("seek" not in ops(actions) and logic.scrub.is_empty(), "Losing the finger cancels the drag")
	logic = expanded()
	grab(logic, 10.0)
	drag(logic, 10.0, 178.0, Logic.PROGRESS_RING)
	check(logic.scrub_value() <= 6_000_000 - 500, "Scrubbing clamps before the end")
	logic = expanded()
	actions = press(logic, Vector2(-0.03, -0.075))
	check(ops(actions).is_empty(), "The left half of the disc carries no timeline")
	check(Logic.arc_point(0.0).y > 0.08 and Logic.arc_point(0.5).x > 0.08 and Logic.arc_point(1.0).y < -0.08, "The timeline runs down the right side, top to bottom")
