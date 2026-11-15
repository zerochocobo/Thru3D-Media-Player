extends SceneTree
## Automatic stereo focus: where the view centre lies in each eye's picture, the distance a measured
## disparity means, and how measurements settle.

const Autofocus := preload("res://scripts/stereo_autofocus.gd")
var failures: Array[String] = []
var checks := 0

class FakePlatform extends RefCounted:
	var requests: Array = []
	var result := PackedFloat32Array([0, 0, 0, 0, 0, 0])
	var accept := true
	func request_mpv_stereo_focus(session: int, width: int, height: int, params: PackedFloat32Array) -> bool:
		if accept: requests.append([session, width, height, params])
		return accept
	func request_lens_stereo_focus(texture: int, external: bool, params: PackedFloat32Array) -> bool:
		if accept: requests.append([texture, external, params])
		return accept
	func mpv_stereo_focus_result() -> PackedFloat32Array:
		return result
	func finish(disparity: float, peak := 0.9, contrast := 30.0, state := 1.0) -> void:
		result = PackedFloat32Array([result[0] + 1.0, state, disparity, peak, 0.2, contrast])

func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition: failures.append(message)

func _near(a: float, b: float, tolerance := 0.001) -> bool:
	return absf(a - b) < tolerance

func _initialize() -> void:
	# The view centre in an eye's picture.
	var ahead: Array = Autofocus.gaze(Vector3.FORWARD, PI)
	_check(ahead[0].is_equal_approx(Vector2(0.5, 0.5)) and ahead[1].is_equal_approx(Vector2.ZERO), "Straight ahead is the picture centre")
	var right: Array = Autofocus.gaze(Vector3(1, 0, -1), PI)
	_check(_near(right[0].x, 0.75) and _near(right[1].x, PI / 4), "45 degrees right is three quarters across a 180 picture")
	_check(_near(Autofocus.gaze(Vector3(1, 0, -1), TAU)[0].x, 0.625), "A 360 picture spans twice the longitude")
	var up: Array = Autofocus.gaze(Vector3(0, 1, -1), PI)
	_check(_near(up[0].y, 0.25) and _near(up[1].y, PI / 4), "Up is towards the first row")
	_check(Autofocus.measurable(ahead[0], ahead[1], PI) and Autofocus.measurable(right[0], right[1], PI), "The middle of a 180 picture can be measured")
	var edge: Array = Autofocus.gaze(Vector3(1, 0, -0.2), PI)
	_check(not Autofocus.measurable(edge[0], edge[1], PI), "A patch leaving the picture is not measured")
	var steep: Array = Autofocus.gaze(Vector3(0, 2, -1), PI)
	_check(not Autofocus.measurable(steep[0], steep[1], PI), "Near a pole a horizontal match says nothing")

	# Frame points of the two shown eyes.
	var sbs: PackedFloat32Array = Autofocus.probe(Vector2(0.5, 0.25), PI, false, false)
	_check(sbs == PackedFloat32Array([0.25, 0.25, 0.75, 0.25, 360.0, 180.0]), "Side by side: the left half is the left eye")
	_check(Autofocus.probe(Vector2(0.5, 0.25), PI, false, true) == PackedFloat32Array([0.75, 0.25, 0.25, 0.25, 360.0, 180.0]), "Swapped eyes read the other halves")
	_check(Autofocus.probe(Vector2(0.5, 0.5), TAU, true, false) == PackedFloat32Array([0.5, 0.25, 0.5, 0.75, 360.0, 360.0]), "Top-bottom 360: the top half is the left eye")

	# Disparity to distance.
	var ipd := 0.064
	_check(_near(1.0 / Autofocus.inverse_distance(deg_to_rad(3.667), ipd, Vector2.ZERO, false), 1.0, 0.002), "A disparity of the eyes' own angle at one metre focuses at one metre")
	_check(_near(1.0 / Autofocus.inverse_distance(deg_to_rad(3.667) * cos(PI / 4), ipd, Vector2(PI / 4, 0), false), 1.0, 0.002), "A 180 pair's disparity shrinks towards the sides for the same distance")
	_check(_near(1.0 / Autofocus.inverse_distance(deg_to_rad(3.667), ipd, Vector2(PI / 4, 0), true), 1.0, 0.002), "A 360 pair turns with the view")
	_check(_near(1.0 / Autofocus.inverse_distance(deg_to_rad(3.667) / cos(0.5), ipd, Vector2(0, 0.5), false), 1.0, 0.002), "Longitude lines close in towards the poles")
	_check(_near(1.0 / Autofocus.inverse_distance(-0.02, ipd, Vector2.ZERO, false), Autofocus.LIMITS.y), "Diverging pictures focus at the far limit")
	_check(_near(1.0 / Autofocus.inverse_distance(1.0, ipd, Vector2.ZERO, false), Autofocus.LIMITS.x), "The nearest focus is limited")

	# Measuring and settling.
	var platform := FakePlatform.new()
	var focus := Autofocus.new()
	var frame := Vector2i(8192, 4096)
	var tick := func(delta := 0.014) -> bool: return focus.tick(platform, 7, frame, Vector3.FORWARD, PI, false, false, 0.0, ipd, delta)
	_check(not tick.call() and platform.requests.size() == 1 and focus.distance == 0.0, "The first frame asks for a measurement and shows nothing yet")
	_check(platform.requests[0] == [7, 8192, 4096, PackedFloat32Array([0.25, 0.5, 0.75, 0.5, 360.0, 180.0])], "The request carries the session, frame and both gaze points")
	_check(not tick.call() and platform.requests.size() == 1, "No second request while one is running")
	platform.finish(3.667)
	_check(tick.call() and _near(focus.distance, 1.0, 0.002), "The first measurement applies at once")
	_check(platform.requests.size() == 1, "Requests keep their interval")
	focus._requested_ms -= Autofocus.INTERVAL_MS
	tick.call()
	_check(platform.requests.size() == 2, "The next request follows the interval")
	platform.finish(1.2, 0.3)
	tick.call()
	_check(_near(focus.distance, 1.0, 0.002) and not focus.report.valid, "A weak match is ignored")
	focus._requested_ms -= Autofocus.INTERVAL_MS; tick.call()
	platform.finish(1.2, 0.9, 1.0)
	tick.call()
	_check(_near(focus.distance, 1.0, 0.002), "A patch without texture is ignored")
	focus._requested_ms -= Autofocus.INTERVAL_MS; tick.call()
	platform.finish(0.0, 0.0, 0.0, -1.0)
	tick.call()
	_check(_near(focus.distance, 1.0, 0.002), "An unreadable surface keeps the last focus")
	# One outlier between agreeing measurements never moves the focus; a real change settles smoothly.
	focus._requested_ms -= Autofocus.INTERVAL_MS; tick.call()
	platform.finish(9.0)
	tick.call(); tick.call(1.0)
	_check(_near(focus.distance, 1.0, 0.002), "One outlier of three is dropped")
	for i in 2:
		focus._requested_ms -= Autofocus.INTERVAL_MS; tick.call()
		platform.finish(1.8335)
		tick.call()
	_check(focus.distance > 1.0 and focus.distance < 1.2, "A new depth is approached, not jumped to")
	for i in 200: tick.call()
	_check(_near(focus.distance, 2.0, 0.03), "The focus settles on the new depth")
	# The stereo alignment's shown disparity adds to the measured one.
	var aligned := Autofocus.new()
	aligned.tick(platform, 7, frame, Vector3.FORWARD, PI, false, false, deg_to_rad(1.8335) / PI, ipd, 0.014)
	platform.finish(1.8335)
	aligned.tick(platform, 7, frame, Vector3.FORWARD, PI, false, false, deg_to_rad(1.8335) / PI, ipd, 0.014)
	_check(_near(aligned.distance, 1.0, 0.002), "Alignment disparity counts towards the focus")
	# A new session starts over; an unmeasurable view asks for nothing.
	_check(not focus.tick(platform, 8, frame, Vector3.FORWARD, PI, false, false, 0.0, ipd, 0.014) or focus.distance == 0.0, "A new session forgets the old focus")
	_check(focus.distance == 0.0, "A new session shows nothing until measured")
	var asked := platform.requests.size()
	var side := Autofocus.new()
	side.tick(platform, 7, frame, Vector3(1, 0, -0.1), PI, false, false, 0.0, ipd, 0.014)
	_check(platform.requests.size() == asked, "A view past the picture's edge asks for nothing")

	# A fisheye frame: read from its texture around the view centre, a fixed pair like a 180 picture.
	_check(Autofocus.lens_measurable(Vector3.FORWARD, Vector2.ZERO, 180.0), "The middle of a lens can be measured")
	var rim := Vector3(1, 0, -0.25).normalized()
	_check(not Autofocus.lens_measurable(rim, Autofocus.gaze(rim, PI)[1], 180.0), "A patch reaching past the lens rim is not measured")
	var wide := Vector3(sin(deg_to_rad(74.5)), 0, -cos(deg_to_rad(74.5)))
	_check(not Autofocus.lens_measurable(wide, Autofocus.gaze(wide, PI)[1], 180.0) and Autofocus.lens_measurable(wide, Autofocus.gaze(wide, PI)[1], 220.0),
		"A wider lens can be measured further out")
	var sideways := Vector3(sin(deg_to_rad(80.0)), 0, -cos(deg_to_rad(80.0)))
	_check(not Autofocus.lens_measurable(sideways, Autofocus.gaze(sideways, PI)[1], 220.0), "A camera pair seen end on is not measured")
	var lens := {"texture": 41, "external": true, "fov": 190.0, "half": true, "size": Vector2(8192, 4096), "scale": Vector2(1.0, 0.5)}
	_check(Autofocus.lens_probe(Vector2(0.5, -0.25), lens, false, true) == PackedFloat32Array([1, 1, 190, 8192, 4096, 1, 0.5, 0.5, -0.25, 1]),
		"The lens request names the frame, the lens and the view centre")
	_check(Autofocus.lens_probe(Vector2.ZERO, lens, true, false)[0] == 2.0, "Eyes above each other are their own layout")
	var fisheye := Autofocus.new()
	asked = platform.requests.size()
	var turned := Vector3(1, 0, -1)
	fisheye.tick(platform, 7, frame, turned, deg_to_rad(190.0), false, false, 0.0, ipd, 0.014, lens)
	_check(platform.requests.size() == asked + 1 and platform.requests[-1][0] == 41 and platform.requests[-1][1] == true
		and _near(platform.requests[-1][2][7], PI / 4), "A fisheye frame is asked for by its texture")
	platform.finish(3.667 * cos(PI / 4))
	fisheye.tick(platform, 7, frame, turned, deg_to_rad(190.0), false, false, 0.0, ipd, 0.014, lens)
	_check(_near(fisheye.distance, 1.0, 0.002), "A lens pair's disparity shrinks towards the sides like a 180 picture's")
	var whole := Autofocus.new()
	whole.tick(platform, 7, frame, turned, TAU, false, false, 0.0, ipd, 0.014, {"texture": 41, "external": false, "fov": 360.0, "half": false, "size": Vector2(8192, 4096), "scale": Vector2.ONE})
	platform.finish(3.667 * cos(PI / 4))
	whole.tick(platform, 7, frame, turned, TAU, false, false, 0.0, ipd, 0.014, lens)
	_check(_near(whole.distance, 1.0, 0.002), "A lens is never a turning 360 pair")
	asked = platform.requests.size()
	Autofocus.new().tick(platform, 7, frame, rim, deg_to_rad(190.0), false, false, 0.0, ipd, 0.014, lens)
	_check(platform.requests.size() == asked, "A view near the lens rim asks for nothing")

	print("stereo autofocus: %d checks, %d failures" % [checks, failures.size()])
	for failure in failures: printerr("ERROR: " + failure)
	quit(0 if failures.is_empty() else 1)
