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
	# Screen average: a dark frame is lifted by 1 + 2 (1 - max)^2, a white frame is not.
	var grey := Model.linear_pixels(_image(Color(0.5, 0.5, 0.5)))
	var linear := Color(0.5, 0.5, 0.5).srgb_to_linear().r
	var average := Model.screen_average(grey, w, h)
	var expected := linear * (1.0 + 2.0 * pow(1.0 - linear, 2.0))
	check(absf(average.r - expected) <= 2.0 / 255.0, "Mid grey is lifted in the frame average", [average, expected])
	check(Model.screen_average(Model.linear_pixels(_image(Color.WHITE)), w, h).is_equal_approx(Color.WHITE), "White stays white")

	# Colour scale curves at the default intensity.
	var dark := Model.color_scale(Color.BLACK, Model.DEFAULT_INTENSITY)
	var bright := Model.color_scale(Color.WHITE, Model.DEFAULT_INTENSITY)
	check(dark.v < 0.05, "A black film nearly blacks out the room", dark)
	check(bright.v > 0.6 and bright.v < 0.7, "A white film leaves the room at about two thirds", bright)
	var red := Model.color_scale(Color(1, 0.2, 0.2), Model.DEFAULT_INTENSITY)
	check(red.r > red.g * 1.5 and is_equal_approx(red.g, red.b), "A red film tints the room red", red)
	check(Model.color_scale(Color(0.5, 0.5, 0.5), 1.0).v > Model.color_scale(Color(0.5, 0.5, 0.5), 0.0).v,
		"Higher intensity keeps the room brighter")

	# Smoothing is frame-rate independent: 72 one-frame steps equal one second.
	var stepped := Color.BLACK
	for frame in 72: stepped = Model.blend(stepped, Color.WHITE, Model.SCALE_KEEP, Model.SCALE_FRAME_RATE, 1.0 / 72.0)
	var once := Model.blend(Color.BLACK, Color.WHITE, Model.SCALE_KEEP, Model.SCALE_FRAME_RATE, 1.0)
	check(absf(stepped.r - once.r) < 0.001 and absf(stepped.r - (1.0 - pow(0.9, 72))) < 0.001, "EMA matches the per-frame blend", [stepped, once])

	# Perimeter walk and halo bar: a red left half lights the left edge, not the right.
	check(Model.perimeter_point(0.0).is_equal_approx(Vector2(0.06, 0.06)) and Model.perimeter_point(0.4999).distance_to(Vector2(0.94, 0.94)) < 0.001,
		"The bar starts bottom-left and reaches top-right halfway")
	var image := _image(Color.BLACK)
	image.fill_rect(Rect2i(0, 0, w / 2, h), Color.RED)
	var bar := Model.halo_bar(Model.linear_pixels(image), w, h)
	check(bar.size() == Model.BAR_SIZE, "32 halo colours", bar.size())
	check(bar[4].x > 0.9 and bar[20].x < 0.05, "Left edge red, right edge dark", [bar[4], bar[20]])
	var uniform := Model.halo_bar(Model.linear_pixels(_image(Color(0.2, 0.4, 0.6))), w, h)
	var target := Vector3(Color(0.2, 0.4, 0.6).srgb_to_linear().r, Color(0.2, 0.4, 0.6).srgb_to_linear().g, Color(0.2, 0.4, 0.6).srgb_to_linear().b)
	check(uniform[10].distance_to(target) < 0.01, "The blur kernels are normalised", [uniform[10], target])

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
