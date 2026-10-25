extends SceneTree

const FilmLight := preload("res://scripts/environments/cinema_film_light.gd")
var checks := 0
var failures: Array[String] = []

class DelayedLight extends "res://scripts/environments/cinema_film_light.gd":
	signal sample_ready
	func _layer_image(_video: Node, _pair: Dictionary) -> Image:
		await sample_ready
		var image := Image.create(32, 18, false, Image.FORMAT_RGBA8)
		image.fill(Color.RED)
		return image

class VideoFixture extends Node:
	var media := {"state": "playing", "last_pair": {"pts_us": 100}}
	var _binding := {"layer": true}

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
