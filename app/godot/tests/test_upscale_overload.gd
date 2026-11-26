extends SceneTree
## Super resolution the headset cannot carry stops for the video (PICO 4, log D7NHRSGV): the slow seconds
## it takes, what resets them, what the copy is then told, the retry and the menu row.
const Grade := preload("res://scripts/color_grade.gd")
const Menu := preload("res://scripts/player_menu.gd")
const Video := preload("res://scripts/mpv_video_display.gd")
const I18n := preload("res://scripts/i18n.gd")
var failures: Array[String] = []
func check(value: bool, message: String) -> void:
	if not value: failures.append(message)
func _initialize() -> void: call_deferred("_run")

func _run() -> void:
	_load()
	_menu()
	print("upscale overload tests: %d failures" % failures.size())
	for failure in failures: print("  " + failure)
	quit(1 if not failures.is_empty() else 0)

## A 1080 x 1920 file enlarged by the layer copy, playing.
func _enlarging() -> Node:
	var video := Video.new()
	video.local_uri = "file:///portrait.mp4"
	video.requested_play = true; video.media.state = "playing"
	video.picture_quality = true; video.picture_upscale = Video.Upscale.MAXIMUM
	video._layer_session = true
	video.media.format = {"width": 1080, "height": 1920}
	video.media.playback = {"layer_copy": {"quality": true, "output_width": 1728, "output_height": 3840, "enlarged": true}}
	return video

func _seconds(video: Node, from_ms: int, count: int, fps: float) -> void:
	for second in count: video.check_upscale_load(from_ms + 1000 * second, 72.0, fps)

func _load() -> void:
	var video := _enlarging()
	check(video._picture_values()[13] == float(Video.Upscale.MAXIMUM), "The copy is asked to enlarge")
	_seconds(video, 1000, Video.UPSCALE_SLOW_SECONDS - 1, 20.0)
	check(not video.upscale_overloaded, "A few slow seconds (a seek, a menu opening) leave it on")
	video.check_upscale_load(1000 * (Video.UPSCALE_SLOW_SECONDS - 1) + 500, 72.0, 20.0)
	check(not video.upscale_overloaded, "It looks once a second, not every frame")
	video.check_upscale_load(1000 * Video.UPSCALE_SLOW_SECONDS + 1000, 72.0, 20.0)
	check(video.upscale_overloaded and video.picture_upscale_blocker() == "load", "Slow seconds in a row stop it")
	check(video._picture_values()[13] == 0.0, "The copy then shows the picture at its own size")
	check(video.picture_upscale == Video.Upscale.MAXIMUM, "The level chosen stays as it was, for the next video")
	check(video.picture_diagnostic().begins_with("on up2:load"), "The exported log says it stopped")
	video.retry_upscale()
	check(not video.upscale_overloaded and video._picture_values()[13] == float(Video.Upscale.MAXIMUM), "Choosing a level again tries once more")
	video.free()

	video = _enlarging()
	_seconds(video, 1000, Video.UPSCALE_SLOW_SECONDS - 1, 20.0)
	video.check_upscale_load(1000 * Video.UPSCALE_SLOW_SECONDS, 72.0, 70.0)
	_seconds(video, 1000 * Video.UPSCALE_SLOW_SECONDS + 1000, Video.UPSCALE_SLOW_SECONDS - 1, 20.0)
	check(not video.upscale_overloaded, "A second at full rate starts the count again")
	_seconds(video, 20000, Video.UPSCALE_SLOW_SECONDS * 2, 70.0)
	check(not video.upscale_overloaded, "A headset that keeps up keeps it")
	_seconds(video, 40000, Video.UPSCALE_SLOW_SECONDS * 2, 54.5)
	check(not video.upscale_overloaded, "Three quarters of the refresh rate counts as keeping up")
	video.media.state = "paused"
	_seconds(video, 60000, Video.UPSCALE_SLOW_SECONDS * 2, 20.0)
	check(not video.upscale_overloaded, "A paused picture is not judged")
	video.media.state = "playing"
	video.media.playback = {"layer_copy": {"quality": true, "output_width": 1080, "output_height": 1920, "enlarged": false}}
	_seconds(video, 80000, Video.UPSCALE_SLOW_SECONDS * 2, 20.0)
	check(not video.upscale_overloaded, "Nor one super resolution does not enlarge: the load is something else's")
	video.media.playback = {"layer_copy": {"quality": true, "output_width": 1728, "output_height": 3840, "enlarged": true}}
	video.picture_upscale = Video.Upscale.OFF
	_seconds(video, 100000, Video.UPSCALE_SLOW_SECONDS * 2, 20.0)
	check(not video.upscale_overloaded, "Nor with super resolution off")
	video.free()

func _menu() -> void:
	I18n.use("en")
	var menu := Menu.new()
	var state := {"has_video": true, "layer_available": true, "grade_on_layer": true,
		"picture_quality_supported": true, "picture_quality_available": true, "picture_quality": true, "picture_sharpness": 50.0,
		"grade_curves_locked": false, "grade_values": Grade.DEFAULTS.duplicate(), "color_grade": {"preset": "Custom"},
		"picture_upscale": 2, "picture_upscale_available": true, "picture_upscale_blocker": "",
		"picture_upscale_sizes": {"source": Vector2i(1080, 1920), "moderate": Vector2i(1728, 3840), "maximum": Vector2i(1728, 3840), "vr": false},
		"picture_interpolation": false, "picture_interpolation_blocker": ""}
	menu.state_provider = func(): return state
	root.add_child(menu)
	menu.toggle()
	menu._open_picture_controls()
	var option := func(value: int) -> Dictionary:
		return menu._buttons.filter(func(button): var target: Dictionary = menu.choices.targets.get(button.target, {}); return target.get("key", "") == "picture_upscale" and int(target.get("value", -1)) == value)[0]
	var chosen := func(value: int) -> bool: return option.call(value).base_color == menu.SELECTED
	check(chosen.call(2), "The level chosen shows while it runs")
	state.picture_upscale_blocker = "load"
	menu.refresh()
	check(chosen.call(0) and not chosen.call(2), "Stopped for the load, the row shows off")
	check(option.call(2).enabled and menu._tips[option.call(2).target] == Menu.PICTURE_UPSCALE_STOPPED, "and stays open to try again, saying why")
	for language in ["zh", "zh_Hant", "ja"]:
		I18n.use(language)
		check(I18n.t(Menu.PICTURE_UPSCALE_STOPPED) != Menu.PICTURE_UPSCALE_STOPPED, language + " has the stopped hint")
	I18n.use("en")
	menu.queue_free()
