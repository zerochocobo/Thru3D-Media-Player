# Originally contributed by ghanshyam (github.com/ghanshyamv1) in public PR #9.
extends SceneTree

const Model := preload("res://scripts/passthrough_relight_model.gd")
var checks := 0
var failures: Array[String] = []

func check(ok: bool, message: String, detail: Variant = null) -> void:
	checks += 1
	if not ok: failures.append(message + ("" if detail == null else ": " + str(detail)))

func _image(fill: Color) -> Image:
	var image := Image.create(Model.SAMPLE_SIZE.x, Model.SAMPLE_SIZE.y, false, Image.FORMAT_RGBA8)
	image.fill(fill)
	return image

func _initialize() -> void:
	var w := Model.SAMPLE_SIZE.x
	var h := Model.SAMPLE_SIZE.y
	# Frame average: the plain mean of the picture.
	var grey := Model.linear_pixels(_image(Color(0.5, 0.5, 0.5)))
	var linear := Color(0.5, 0.5, 0.5).srgb_to_linear().r
	var average := Model.screen_average(grey, w, h)
	check(absf(average.r - linear) <= 0.002 and absf(average.b - linear) <= 0.002, "The frame average is the mean colour", [average, linear])
	check(Model.screen_average(Model.linear_pixels(_image(Color.WHITE)), w, h).is_equal_approx(Color.WHITE), "White stays white")

	# Room colour.
	var dark := Model.color_scale(Color.BLACK)
	var bright := Model.color_scale(Color.WHITE)
	check(dark.v < 0.05, "A black film nearly blacks out the room", dark)
	check(bright.v > 0.6 and bright.v < 0.7, "A white film leaves the room at about two thirds", bright)
	var red := Model.color_scale(Color(1, 0.2, 0.2))
	check(red.r > red.g * 1.5 and is_equal_approx(red.g, red.b), "A red film tints the room red", red)
	check(Model.color_scale(Color(0.1, 0.1, 0.1)).v > bright.v * 0.4, "A dim film already lights the room")
	var previous := -1.0
	var rising := true
	for step in 21:
		var value := Model.color_scale(Color(step / 20.0, step / 20.0, step / 20.0)).v
		rising = rising and value > previous
		previous = value
	check(rising, "A brighter film gives a brighter room")

	# Easing does not depend on the frame rate: 72 one-frame steps equal one second.
	var stepped := 0.0
	for frame in 72: stepped = lerpf(stepped, 1.0, Model.ease_weight(Model.ROOM_FOLLOW, 1.0 / 72.0))
	check(absf(stepped - Model.ease_weight(Model.ROOM_FOLLOW, 1.0)) < 0.001, "Easing is frame-rate independent", stepped)
	check(absf(Model.ease_weight(0.5, 0.5) - (1.0 - exp(-1.0))) < 0.0001 and Model.ease_weight(0.5, 0.0) == 0.0, "Easing covers 63 % in one time constant")

	# Border walk: clockwise from the top-left corner, a quarter for each side.
	check(absf(Model.border_coordinate(Vector2(0, 1)) - 0.125) < 0.0001 and absf(Model.border_coordinate(Vector2(1, 0)) - 0.375) < 0.0001
		and absf(Model.border_coordinate(Vector2(0, -1)) - 0.625) < 0.0001 and absf(Model.border_coordinate(Vector2(-1, 0)) - 0.875) < 0.0001,
		"Top, right, bottom and left sit in the middle of their quarters")
	check(absf(Model.border_coordinate(Vector2(0.5, 3.0)) - Model.border_coordinate(Vector2(0.1, 0.6))) < 0.0001, "Only the direction matters")
	# Halo bar: a red left half lights the left edge, not the right.
	var image := _image(Color.BLACK)
	image.fill_rect(Rect2i(0, 0, w / 2, h), Color.RED)
	var bar := Model.halo_bar(Model.linear_pixels(image), w, h)
	check(bar.size() == Model.BAR_SIZE, "32 halo colours", bar.size())
	check(bar[28].x > 0.9 and bar[12].x < 0.05, "Left edge red, right edge dark", [bar[28], bar[12]])
	check(bar[4].x > 0.3 and bar[4].x < 0.7, "The top edge blends across the cut", bar[4])
	var uniform := Model.halo_bar(Model.linear_pixels(_image(Color(0.2, 0.4, 0.6))), w, h)
	var target := Vector3(Color(0.2, 0.4, 0.6).srgb_to_linear().r, Color(0.2, 0.4, 0.6).srgb_to_linear().g, Color(0.2, 0.4, 0.6).srgb_to_linear().b)
	var even := true
	for colour in uniform: even = even and colour.distance_to(target) < 0.01
	check(even, "An even picture gives an even bar", [uniform[0], uniform[10], target])
	# A centre spot does not reach the border.
	var spot := _image(Color.BLACK)
	spot.fill_rect(Rect2i(w / 2 - 6, h / 2 - 4, 12, 8), Color.WHITE)
	var quiet := true
	for colour in Model.halo_bar(Model.linear_pixels(spot), w, h): quiet = quiet and colour.length() < 0.001
	check(quiet, "The picture's middle does not colour the halo")

	# Halo falloff: a wider reach is brighter at the edge and reaches further.
	var tight := Model.halo_profile(0.0)
	var wide := Model.halo_profile(1.0)
	check(tight.x < 1.0 and wide.x > 1.0 and wide.y > tight.y, "Reach raises the peak and widens the glow", [tight, wide])
	check(Model.halo_margin(0.0) >= Model.HALO_MARGIN_LIMITS.x and Model.halo_margin(1.0) <= Model.HALO_MARGIN_LIMITS.y
		and Model.halo_margin(0.0) < Model.halo_margin(0.5) and Model.halo_margin(0.5) < Model.halo_margin(1.0), "The mesh grows with the reach")
	var edge := Model.halo_profile(0.5)
	var far := Model.halo_margin(0.5)
	check(absf(edge.x / pow(1.0 + pow(far / edge.y, Model.HALO_POWER), 1.0 / Model.HALO_POWER) - Model.HALO_CUTOFF) < 0.001, "The mesh ends where the glow meets the cutoff")

	# Passthrough LUT layout of OpenXRMetaPassthroughColorLut: width res^2, height res.
	var lut := Model.scale_lut_image(Color(0.5, 1.0, 1.0), 16)
	check(lut.get_width() == 256 and lut.get_height() == 16, "LUT image layout", lut.get_size())
	var top := lut.get_pixel(15 * 16 + 15, 15)
	check(absf(top.g - 1.0) < 0.01 and absf(top.r - Color(0.5, 0.5, 0.5).linear_to_srgb().r) < 0.01, "LUT scales linear red only", top)
	check(lut.get_pixel(0, 0).is_equal_approx(Color.BLACK), "LUT keeps black")

	if failures.is_empty(): print("Passthrough relight checks passed: %d" % checks)
	else:
		for failure in failures: printerr(failure)
	quit(0 if failures.is_empty() else 1)
