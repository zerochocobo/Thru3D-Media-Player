extends SceneTree

const FilmLight := preload("res://scripts/environments/cinema_film_light.gd")
var checks := 0
var failures: Array[String] = []

func check(ok: bool, message: String, detail: Variant = null) -> void:
	checks += 1
	if not ok: failures.append(message + ("" if detail == null else ": " + str(detail)))

func _initialize() -> void:
	var image := Image.create(FilmLight.SAMPLE_SIZE.x, FilmLight.SAMPLE_SIZE.y, false, Image.FORMAT_RGBA8)
	image.fill(Color.BLACK)
	var third := FilmLight.SAMPLE_SIZE.x / 3
	image.fill_rect(Rect2i(0, 0, third, FilmLight.SAMPLE_SIZE.y), Color.WHITE)
	var zones: Array[Color] = FilmLight.zone_colors(image, 1.0)
	check(zones[0].is_equal_approx(Color(FilmLight.MAX_GAIN, FilmLight.MAX_GAIN, FilmLight.MAX_GAIN)),
		"A white left third lights only the left strip, clamped to the maximum gain", zones)
	check(zones[1].r < .2 and zones[2].is_equal_approx(Color.BLACK), "Dark centre and right strips stay nearly unlit", zones)
	image.fill(Color(.5, .5, .5))
	zones = FilmLight.zone_colors(image, .5)
	var expected := Color(.5, .5, .5).srgb_to_linear().r * .5 / FilmLight.REFERENCE
	check(absf(zones[1].r - expected) < .01, "Mid-grey is linearised, normalised to the reference and scaled by picture area", zones[1])
	image.fill(Color(1, 0, 0))
	zones = FilmLight.zone_colors(image, 1.0)
	check(zones[2].r > 1 and zones[2].g == 0 and zones[2].b == 0, "A red frame throws red light", zones[2])
	check(FilmLight.eye_crop({"stereo_sbs": true}) == Vector4(0, 0, .5, 1)
		and FilmLight.eye_crop({"stereo_sbs": true, "top_bottom": true}) == Vector4(0, 0, 1, .5)
		and FilmLight.eye_crop({}) == Vector4(0, 0, 1, 1), "Stereo sources sample the left eye only")
	var light := FilmLight.new()
	root.add_child(light)
	light.colors = [Color(2, 2, 2), Color(2, 2, 2), Color(2, 2, 2)]
	check(light.update(.05, null, false, 1.0), "Without a picture the colours start fading")
	check(light.colors[0].r < 2 and light.colors[0].r > 1, "Fading is smoothed, not an instant cut", light.colors[0])
	for i in 60: light.update(.05, null, false, 1.0)
	check(light.colors[0].is_equal_approx(FilmLight.IDLE_GLOW) or absf(light.colors[0].r - FilmLight.IDLE_GLOW.r) < .01,
		"Stopped playback settles to the faint idle screen glow, never pitch black", light.colors[0])
	for failure in failures: push_error(failure)
	print("Cinema film light: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
