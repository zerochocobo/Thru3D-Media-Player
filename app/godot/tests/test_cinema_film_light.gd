extends SceneTree

const FilmLight := preload("res://scripts/environments/cinema_film_light.gd")
var checks := 0
var failures: Array[String] = []

class DelayedLight extends "res://scripts/environments/cinema_film_light.gd":
	signal sample_ready
	func _layer_image(_video: Node, _pair: Dictionary) -> Image:
		await sample_ready
		var image := Image.create(SAMPLE_SIZE.x, SAMPLE_SIZE.y, false, Image.FORMAT_RGBA8)
		image.fill(Color.RED)
		return image

class VideoFixture extends Node:
	var media := {"state": "playing", "last_pair": {"pts_us": 100}}
	var _binding := {"layer": true}

func check(ok: bool, message: String, detail: Variant = null) -> void:
	checks += 1
	if not ok: failures.append(message + ("" if detail == null else ": " + str(detail)))

## 72 Hz frames until the colour is within about 5/255 of the target as seen.
func frames_to_settle(from: Color, to: Color) -> int:
	var current := from
	for frame in 300:
		if absf(sqrt(current.r) - sqrt(to.r)) <= .02: return frame
		current = FilmLight.settle(current, to, 1.0 / 72.0)
	return 300

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
	image.fill(Color(1, .8, .2))
	zones = FilmLight.zone_colors(image, 1.0)
	var source := Color(1, .8, .2).srgb_to_linear()
	check(is_equal_approx(zones[1].r, FilmLight.MAX_GAIN) and absf(zones[1].g / zones[1].r - source.g / source.r) < .001
		and absf(zones[1].b / zones[1].r - source.b / source.r) < .001, "The gain limit keeps a bright frame's hue", zones[1])
	check(frames_to_settle(Color(2, 2, 2), Color.BLACK) <= 36, "A cut to black clears the hall within half a second, not seconds")
	check(frames_to_settle(Color.BLACK, Color(2, 2, 2)) <= 18, "A cut to bright lights the hall within a quarter second")
	check(FilmLight.SAMPLE_SIZE.x * FilmLight.SAMPLE_SIZE.y <= 144, "The sample stays cheap on the main thread", FilmLight.SAMPLE_SIZE)
	image.fill(Color.BLACK)
	image.fill_rect(Rect2i(FilmLight.SAMPLE_SIZE.x - 1, 0, 1, FilmLight.SAMPLE_SIZE.y), Color.WHITE)
	zones = FilmLight.zone_colors(image, 1.0)
	check(zones[2].r > 0 and zones[0].r == 0 and zones[1].r == 0, "The sample's last column belongs to the right strip", zones)
	var soft_share := (FilmLight.settle(Color(.5, .5, .5), Color(.504, .504, .504), 1.0 / 72.0).r - .5) / .004
	var cut_share := 1.0 - FilmLight.settle(Color(2, 2, 2), Color.BLACK, 1.0 / 72.0).r / 2.0
	check(soft_share < .15 and cut_share > .3, "Tiny differences stay soft while a cut moves at once", [soft_share, cut_share])
	# Video fades are even in encoded brightness, so this one is even in sqrt(linear).
	var faded := Color.BLACK
	var held := Color.BLACK
	var largest_step := 0.0
	for frame in 144:
		var linear := pow(float(frame) / 144.0, 2.0)
		if frame % ceili(FilmLight.LAYER_INTERVAL_MS * 72 / 1000.0) == 0: held = Color(linear, linear, linear)
		var next := FilmLight.settle(faded, held, 1.0 / 72.0)
		largest_step = maxf(largest_step, absf(sqrt(next.r) - sqrt(faded.r)))
		faded = next
	check(largest_step * 255.0 < 4.0, "A slow fade at the layer sample rate does not visibly staircase", largest_step * 255.0)
	check(FilmLight.eye_crop({"stereo_sbs": true}) == Vector4(0, 0, .5, 1)
		and FilmLight.eye_crop({"stereo_sbs": true, "top_bottom": true}) == Vector4(0, 0, 1, .5)
		and FilmLight.eye_crop({}) == Vector4(0, 0, 1, 1), "Stereo sources sample the left eye only")
	var light := FilmLight.new()
	root.add_child(light)
	light.colors = [Color(2, 2, 2), Color(2, 2, 2), Color(2, 2, 2)]
	check(light.update(.05, null, false, 1.0), "Without a picture the colours start fading")
	check(light.colors[0].r < 2 and light.colors[0].r > 0, "Fading is smoothed, not an instant cut", light.colors[0])
	for i in 60: light.update(.05, null, false, 1.0)
	check(light.colors[0].r < .01, "With no film the blank screen throws no light", light.colors[0])
	light.set_enabled(false)
	for i in 60: light.update(.05, null, true, 1.0)
	check(light.colors.all(func(color): return color == Color.BLACK), "Disabled screen light stays black without idle glow")
	light.set_enabled(true); light.update(.1, null, false, 1.0)
	check(light.enabled and light.colors[0].r < .01, "Re-enabling with no film keeps the blank screen dark")
	var delayed := DelayedLight.new()
	var video := VideoFixture.new()
	root.add_child(delayed); root.add_child(video)
	delayed.update(.016, video, true, 1.0)
	check(delayed._busy, "Fixture holds a real asynchronous sample in flight")
	delayed.set_enabled(false); delayed.set_enabled(true)
	delayed.sample_ready.emit()
	check(delayed._target[0] == Color.BLACK and delayed._last_pts == -1 and delayed.samples == 0,
		"An in-flight sample cannot restore stale colours after toggling off and on")
	delayed.free(); video.free(); light.free()
	for failure in failures: push_error(failure)
	print("Cinema film light: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
