extends SceneTree
const Move := preload("res://scripts/interface_move.gd")
const Follow := preload("res://scripts/view_follow.gd")
var checks := 0
var failures: Array[String] = []

func check(value: bool, message: String) -> void:
	checks += 1
	if not value: failures.append(message)

func _initialize() -> void: call_deferred("run")

func run() -> void:
	for hand in ["left_hand", "right_hand"]:
		for head_basis in [Basis.IDENTITY, Basis.from_euler(Vector3(0.3, 0.5, 0.4)), Basis.from_euler(Vector3(0.5, -0.3, 1.4))]:
			for grab in [Vector3(-0.5, -0.35, 0), Vector3(0.5, -0.35, 0), Vector3(-0.5, 0.35, 0), Vector3(0.5, 0.35, 0)]:
				for following in [false, true]: orbit(hand, head_basis, grab, following)
	repeated_grabs()
	vertical_limits()
	for failure in failures: push_error(failure)
	print("Grip upright: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)

func orbit(hand: String, head_basis: Basis, grab: Vector3, following: bool) -> void:
	var head := Transform3D(head_basis, Vector3(0.2, 1.6, -0.3))
	var frame := Move.menu_head(head, following)
	var panel := Node3D.new(); root.add_child(panel)
	panel.global_transform = frame * Transform3D(Basis.from_scale(Vector3(1.05, 0.95, 1)), Vector3(0, -0.45, -1.4))
	var compact := Node3D.new(); panel.add_child(compact); compact.position = Vector3(0, 0.72, 0)
	var attached := compact.transform
	var other := Node3D.new(); root.add_child(other); other.global_transform = frame * Transform3D(Basis.IDENTITY, Vector3(0.7, 0.2, -1.8))
	var initial := panel.global_transform
	var other_initial := other.global_transform
	var point := panel.to_global(grab)
	var start := Transform3D(Basis.IDENTITY, frame * Vector3(0.2, -0.2, -0.45)).looking_at(point, frame.basis.y)
	var move := Move.new(); var follow := Follow.new(); follow.set_enabled(following)
	check(move.begin(hand, "grip_click", start, [{"node": panel, "pose": initial, "kind": "menu", "key": "controls"},
		{"node": other, "pose": other_initial, "kind": "menu", "key": "library"}], point, head, following), "Off-centre menu grip arms normally")
	var previous := panel.global_basis.orthonormalized().get_rotation_quaternion()
	for step in range(1, 65):
		var angle: float = step * TAU / 64.0 * (-1 if hand == "left_hand" else 1)
		var turn := frame.basis * Basis(Vector3.UP, angle) * frame.basis.transposed()
		var current_head := head; current_head.origin += head_basis * Vector3(0.02 * sin(angle), 0.01 * sin(angle), 0.015 * sin(angle * 2))
		if not following: current_head.basis = head_basis * Basis.from_euler(Vector3(0.1 * sin(angle), 0, 0.25 * sin(angle)))
		var pose := Transform3D(turn * start.basis * Basis(Vector3.FORWARD, 0.4 * sin(angle)), current_head.origin + turn * (start.origin - head.origin))
		check(move.update(pose, current_head, follow), "Grip tracks a complete circle on either side of the head")
		var up := panel.global_basis.y.normalized()
		check(up.dot(frame.basis.y) > 0.99999 and absf(panel.global_basis.x.normalized().dot(frame.basis.y)) < 0.00001,
			"Only follow mode uses head tilt; standard off-centre dragging stays level as the head rolls")
		var expected := Transform3D(turn, current_head.origin - turn * head.origin)
		check(panel.global_transform.is_equal_approx(expected * initial) and other.global_transform.is_equal_approx(expected * other_initial) and compact.transform.is_equal_approx(attached),
			"Upright rotation preserves the shared plane, relative layout, scale and head distances")
		check(panel.to_global(grab).distance_to(move.capture.anchor) < 0.0001 and (move.capture.anchor - pose.origin).normalized().dot(-pose.basis.z) > 0.99999,
			"The exact grabbed point stays on the real ray while the menu remains upright")
		var rotation := panel.global_basis.orthonormalized().get_rotation_quaternion()
		check(previous.angle_to(rotation) < 0.11, "Crossing the side and rear headings does not introduce a rotation jump")
		previous = rotation
	check(move.placement("controls", Move.menu_head(head, following)).is_equal_approx(panel.global_transform), "Completing the circle retains the same session placement")
	panel.free(); other.free()

func repeated_grabs() -> void:
	var head := Transform3D(Basis.from_euler(Vector3(0.2, -0.3, 0.5)), Vector3(0, 1.6, 0))
	var panel := Node3D.new(); root.add_child(panel)
	panel.global_transform = Transform3D(Basis(Vector3.UP, 0.3) * Basis(Vector3.RIGHT, 0.4), Vector3(0, 1.4, -1.4))
	var radius := panel.global_position.distance_to(head.origin)
	var move := Move.new(); var follow := Follow.new()
	for grab_index in 6:
		var grab := Vector3(0.35 if grab_index % 2 == 0 else -0.35, 0.2, 0)
		var point := panel.to_global(grab)
		var start := Transform3D(Basis.IDENTITY, head.origin).looking_at(point)
		move.begin("right_hand", "grip_click", start, [{"node": panel, "pose": panel.global_transform, "kind": "menu", "key": "menu"}], point, head)
		for step in range(1, 25):
			var pose := Transform3D(Basis(Vector3.UP, step * 0.03) * Basis(Vector3.RIGHT, 0.15 * sin(step * PI / 24)) * start.basis, head.origin)
			head.basis = Basis.from_euler(Vector3(0.2, -0.3, 0.5 * cos(step * PI / 24)))
			check(move.update(pose, head, follow) or (step == 1 and move.pending()), "A repeated grip honors the start threshold and keeps moving after an earlier vertical drag")
			check(absf(panel.global_basis.x.normalized().y) < 0.00001 and panel.global_basis.y.y > 0,
				"Repeated horizontal and vertical grabs never accumulate bank or inherit head roll")
			check(panel.to_global(grab).distance_to(move.capture.anchor) < 0.0001 and is_equal_approx(panel.global_position.distance_to(head.origin), radius),
				"Repeated grabs retain the actual point and head distance")
		move.cancel()
	panel.free()

func vertical_limits() -> void:
	var head := Transform3D(Basis.IDENTITY, Vector3(0, 1.6, 0))
	var panel := Node3D.new(); root.add_child(panel); panel.position = Vector3(0, 1.15, -1.4)
	var grab := Vector3(0.45, 0.2, 0)
	var point := panel.to_global(grab)
	var start := Transform3D(Basis.IDENTITY, head.origin).looking_at(point)
	var move := Move.new(); var follow := Follow.new()
	move.begin("right_hand", "grip_click", start, [{"node": panel, "pose": panel.global_transform, "kind": "menu", "key": "menu"}], point, head)
	for pitch in [-1.7, -1.57, -1.3, -0.6, 0.2, 0.8, 1.3, 1.57, 1.7]:
		for yaw in [0.0, 0.8, PI, -PI, -0.8]:
			var pose := Transform3D(Basis(Vector3.UP, yaw) * Basis(Vector3.RIGHT, pitch) * start.basis, head.origin)
			move.update(pose, head, follow)
			check(panel.global_transform.is_finite() and panel.global_basis.y.normalized().dot(Vector3.UP) >= cos(Move.MAX_MENU_PITCH) - 0.00001 and absf(panel.global_basis.x.normalized().dot(Vector3.UP)) < 0.00001,
				"Near vertical directions stay finite and upright instead of overturning")
			check(panel.to_global(grab).distance_to(move.capture.anchor) < 0.0001 and is_equal_approx(panel.global_position.distance_to(head.origin), Vector3(0, -0.45, -1.4).length()),
				"At a vertical limit the reticle stops with its true grab point and depth stays fixed")
	panel.free()
