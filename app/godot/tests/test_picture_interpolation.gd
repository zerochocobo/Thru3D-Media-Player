extends SceneTree
## Frame interpolation in picture quality mode: the per-video setting, what blocks it and its menu row.
const Grade := preload("res://scripts/color_grade.gd")
const Menu := preload("res://scripts/player_menu.gd")
const Video := preload("res://scripts/mpv_video_display.gd")
const VideoLayer := preload("res://scripts/video_layer.gd")
const I18n := preload("res://scripts/i18n.gd")
const PairInterpolation := preload("res://scripts/pair_interpolation.gd")
## A runtime that gives display times, and a plugin with what 2D->3D's interpolation calls.
class TimedLayer extends VideoLayer:
	func frame_timed() -> bool: return true
class PairPlatform extends RefCounted:
	var retries := 0
	func retry_layer_interpolation() -> void: retries += 1
	func set_layer_picture_quality(_on: bool) -> void: pass
	func enhance_frame_texture() -> void: pass
	func enhance_layer_texture() -> void: pass
	func interpolate_pair_draw() -> void: pass
var failures: Array[String] = []
func check(value: bool, message: String) -> void:
	if not value: failures.append(message)
func _initialize() -> void: call_deferred("_run")

func _run() -> void:
	_memory()
	_blockers()
	_pair_blockers()
	_timeline()
	_menu()
	print("picture interpolation tests: %d failures" % failures.size())
	for failure in failures: print("  " + failure)
	quit(1 if not failures.is_empty() else 0)

func _memory() -> void:
	var memory := Video.PictureMemory.new(ProjectSettings.globalize_path("res://../../build/interpolation-test-%s" % Time.get_ticks_usec()))
	var grade := Grade.new()
	var before := {"picture_quality": true, "picture_sharpness": 0.5, "picture_upscale": 0, "picture_denoise": 0, "color_grade": grade.snapshot()}
	check(memory._valid_value(before), "What an earlier version saved for a video still reads")
	check(memory._normalize_value(before).picture_interpolation == false, "and leaves interpolation off")
	var edited := memory.edited(memory._normalize_value(before), "picture_interpolation", 1)
	check(edited.picture_interpolation == true and memory._valid_value(edited), "The choice is saved as a switch")
	before["picture_interpolation"] = "yes"
	check(not memory._valid_value(before), "A value that is no switch is refused")
	check(memory.load_defaults(ConfigFile.new()).picture_interpolation == false, "A new video starts without it")
	check(Video.PictureMemory.is_adjustment("picture_interpolation"), "The player takes it as a picture adjustment")

func _blockers() -> void:
	var video := Video.new()
	check(video.picture_interpolation_blocker() == "runtime", "Without a layer there is no refresh timing to pace by")
	video.video_layer = VideoLayer.new(null)
	check(video.picture_interpolation_blocker() == "runtime", "Nor on a runtime that gives no display times")
	video.video_layer.copy_cadence = true
	video.media.playback = {"details": {"container_fps": "23.976"}}
	check(video.picture_interpolation_blocker() == "", "A runtime whose latches are guessed (PICO) gets it as a Beta")
	video.video_layer.copy_cadence = false
	video.video_layer.cadence_supported = true
	video.media.playback = {"details": {"container_fps": "23.976"}}
	check(video.picture_interpolation_blocker() == "", "A film on the decoder's surface can be interpolated")
	video.picture_quality = true; video.picture_interpolation = true
	check(not video.picture_interpolating(), "It runs only in a session opened with the layer copy")
	video._quality_requested = true
	check(video.picture_interpolating() and video._picture_values()[19] == 1.0, "and is then asked of the copy")
	video.media.playback = {"details": {"container_fps": "59.94"}}
	check(video.picture_interpolation_blocker() == "fps" and video._picture_values()[19] == 0.0, "60 fps video is left as it is")
	video.media.playback = {"details": {"container_fps": "29.97"}}
	check(video.picture_interpolation_blocker() == "", "30 fps video can be interpolated")
	video.alpha_requested = true
	check(video.picture_interpolation_blocker() == "mode", "A cut-out is off the decoder's surface")
	video.alpha_requested = false
	video.media.playback = {"details": {"container_fps": "24"}, "layer_copy": {"quality": true, "scaled_down": true}}
	check(video.picture_interpolation_blocker() == "mode", "A copy that gave the mode up does not interpolate")
	video.media.playback = {"details": {"container_fps": "24"}, "layer_copy": {"quality": true}}
	check(video.picture_interpolation_blocker() == "", "A copy carrying the mode does")
	check("fi" in video.picture_diagnostic(), "The exported settings name it")
	video.media.playback = {"details": {"container_fps": "24"}, "layer_copy": {"quality": true, "interpolation_overloaded": true}}
	check(video.picture_interpolation_blocker() == "load" and video._picture_values()[19] == 0.0, "A copy that could not keep pace is not asked again for this video")
	var plugin := PairPlatform.new()
	video.platform = plugin
	video.retry_interpolation()
	check(plugin.retries == 1 and video.picture_interpolation_blocker() == "", "until the user turns it on again: the copy is told to try again")
	video.retry_interpolation()
	check(plugin.retries == 1, "Turning it on where nothing stopped it asks nothing of the copy")
	video.free()

## 2D to 3D: the stereo pairs on the picture layer, by Godot's own frames.
func _pair_blockers() -> void:
	var video := Video.new()
	video.depth_requested = true
	video.video_layer = VideoLayer.new(null)
	video.video_layer.cadence_supported = true
	check(video.picture_interpolation_blocker() == "runtime", "2D to 3D needs the runtime's display times, whatever its latches")
	var layer := TimedLayer.new(null)
	video.video_layer = layer
	check(video.picture_interpolation_blocker() == "mode", "and a plugin that draws between two pairs")
	var plugin := PairPlatform.new()
	video.platform = plugin
	video.media.session_id = 7
	layer.bound = true; layer._flip = true; layer.picture_quality = true
	video.media.playback = {"details": {"container_fps": "23.976"}}
	check(video.picture_interpolation_blocker() == "", "A film's stereo pairs can be interpolated: " + video.picture_interpolation_blocker())
	video.picture_quality = true; video.picture_interpolation = true
	check(video.picture_interpolating() and video._picture_values()[19] == 1.0, "with no layer copy in the session")
	video.media.playback = {"details": {"container_fps": "59.94"}}
	check(video.picture_interpolation_blocker() == "fps", "60 fps video is left as it is in 3D too")
	video.media.playback = {"details": {"container_fps": "25"}}
	video._pair_failed = video.media.session_id
	check(video.picture_interpolation_blocker() == "load" and not video.picture_interpolating(), "A GL that cannot draw them is not asked again in the session")
	video.retry_interpolation()
	check(video.picture_interpolation_blocker() == "" and video.picture_interpolating(), "until the user turns it on again")
	video._pair_failed = video.media.session_id - 1
	video._pair_timeline = PairInterpolation.new(); video._pair_session = video.media.session_id
	check(video.picture_interpolation_blocker() == "", "A timeline alone blocks nothing")
	video._pair_timeline.overloaded = true
	check(video.picture_interpolation_blocker() == "load", "Missed refreshes stop it for the session")
	video.retry_interpolation()
	check(video.picture_interpolation_blocker() == "" and video._pair_timeline == null, "Turned on again, it starts over with a new timeline")
	video._pair_timeline = PairInterpolation.new(); video._pair_timeline.overloaded = true
	video._pair_session = video.media.session_id - 1
	check(video.picture_interpolation_blocker() == "", "Another session tries again")
	video.geometry = Video.Geometry.Geometry.FISHEYE
	check(video.picture_interpolation_blocker() == "mode", "2D to 3D is of flat pictures")
	video.free()

func _timeline() -> void:
	var period := 13_888_889
	var step := 41_708
	var start := 500_000_000_000_000
	var timeline := PairInterpolation.new()
	check(timeline.pick(start, 1.0).is_empty(), "Without a pair there is nothing to show")
	check(timeline.push(1_000_000, start, period, 1.0) == Vector2i(0, -1), "The first pair follows none")
	var pick := timeline.pick(start, 1.0)
	check(pick.before == 0 and pick.after == -1 and pick.settled, "and shows as it is until another comes")
	check(timeline.push(1_000_000 + step, start + 3 * period, period, 1.0) == Vector2i(1, 0), "The next pair follows it")
	check(timeline.delay_ns == step * 1000 + 2 * period, "The picture then runs a source frame and two refreshes late")
	pick = timeline.pick(start + 3 * period, 1.0)
	check(pick.before == 0 and pick.after == 1 and pick.phase == 0.0 and not pick.settled, "The pair on show stays for that delay")
	pick = timeline.pick(start + timeline.delay_ns + step * 500, 1.0)
	check(pick.before == 0 and pick.after == 1 and absf(pick.phase - 0.5) < 0.01, "then the picture moves on from it: halfway half a frame later (%s)" % pick.phase)
	check(timeline.pick(start + timeline.delay_ns + step * 10, 1.0).phase == 0.0, "Next to a pair the picture is the pair")
	check(timeline.pick(start + timeline.delay_ns + step * 990, 1.0).phase == 1.0, "on either side")
	# Playing on: a pair every three refreshes, a picture every refresh.
	var phases := []
	var display := start + 3 * period
	for frame in range(2, 12):
		for refresh in 3:
			display += period
			if refresh == 2: timeline.push(1_000_000 + frame * step, display, period, 1.0)
			pick = timeline.pick(display, 1.0)
			if frame >= 6: phases.append(pick.phase)
			check(not pick.settled and timeline.frames.size() <= PairInterpolation.KEPT, "Playing never runs out of pairs or keeps more than the native side")
	var between := phases.filter(func(phase): return phase > 0.0 and phase < 1.0).size()
	check(between >= phases.size() * 2 / 3 - 1, "Two refreshes of three show a picture in between (%d of %d)" % [between, phases.size()])
	# A pause: no more pairs, and the picture ends in the newest.
	var newest: int = timeline.frames.back()[0]
	pick = timeline.pick(display + 20 * period, 1.0)
	check(pick.before == newest and pick.after == -1 and pick.settled, "A pause ends in the newest pair")
	# Playing again: the clocks are matched afresh, the picture goes on from that pair.
	display += 300 * period
	var ids := timeline.push(1_000_000 + 12 * step, display, period, 1.0)
	check(ids.y == newest, "The pair after a pause follows the one on show")
	pick = timeline.pick(display, 1.0)
	check(pick.before == newest and pick.after == ids.x and pick.phase == 0.0, "which stays until the delay has passed again")
	# A seek: the picture starts again from the new pair, the delay stays (the audio keeps its place).
	var delay := timeline.delay_ns
	ids = timeline.push(90_000_000, display + 5 * period, period, 1.0)
	check(ids.y == -1 and timeline.frames.size() == 1 and timeline.delay_ns == delay, "A seek starts again from its first pair")
	pick = timeline.pick(display + 5 * period, 1.0)
	check(pick.before == ids.x and not pick.settled, "which shows until the next one's time")
	# 60 fps pairs are not interpolated.
	check(timeline.push(90_016_683, display + 6 * period, period, 1.0).y == -1, "A source faster than 33 fps has no pictures in between")
	# Twice the speed: half the source time between pairs counts as a frame.
	timeline.clear()
	timeline.push(0, start, period, 2.0)
	check(timeline.push(2 * step, start + 3 * period, period, 2.0).y >= 0 and timeline.delay_ns == step * 1000 + 2 * period, "Speed scales the source's clock")
	# Missed refreshes.
	var at := start
	for refresh in PairInterpolation.OVERLOAD_WARMUP:
		at += period * 2
		timeline.paced(at, period)
	check(timeline.paced_total == 0, "The first three seconds are not counted: the start is always busy")
	for refresh in PairInterpolation.OVERLOAD_REFRESHES * 3:
		at += period
		timeline.paced(at, period)
	check(not timeline.overloaded and timeline.missed_total == 0, "Every refresh drawn is no overload")
	for refresh in PairInterpolation.OVERLOAD_REFRESHES:
		at += period * 2
		timeline.paced(at, period)
	check(not timeline.overloaded and timeline.last_window == PairInterpolation.OVERLOAD_REFRESHES, "One slow window may be a busy moment")
	for refresh in PairInterpolation.OVERLOAD_REFRESHES:
		at += period
		timeline.paced(at, period)
	for refresh in PairInterpolation.OVERLOAD_REFRESHES * 2:
		at += period * 2
		timeline.paced(at, period)
	check(timeline.overloaded, "Two slow windows running are an overload")
	timeline.clear()
	check(timeline.overloaded and timeline.frames.is_empty() and timeline.delay_ns == 0, "Stopping keeps that for the session")
	# The depth maps against the frames.
	var depth := PairInterpolation.new()
	var maps := 1000
	var taken := 1200
	depth.depth_counts(maps, taken)
	for window in 6: # a slow start, then a map for every frame
		taken += PairInterpolation.DEPTH_FRAMES; maps += 20 if window == 0 else PairInterpolation.DEPTH_FRAMES
		depth.depth_counts(maps, taken)
		depth.depth_counts(maps, taken)
	check(not depth.overloaded and is_equal_approx(depth.depth_share, 1.0), "A map for every frame is no overload, whatever the start was like")
	taken += PairInterpolation.DEPTH_FRAMES; maps += 30
	depth.depth_counts(maps, taken)
	taken += PairInterpolation.DEPTH_FRAMES; maps += PairInterpolation.DEPTH_FRAMES
	depth.depth_counts(maps, taken)
	check(not depth.overloaded, "One window short of maps may be a busy moment")
	depth.depth_counts(40, 60) # a seek: the bridge counts again
	for window in 2:
		taken = 60 + (window + 1) * PairInterpolation.DEPTH_FRAMES; maps = 40 + (window + 1) * 33
		depth.depth_counts(maps, taken)
	check(depth.overloaded and depth.depth_starved and depth.depth_share < 0.7, "Maps for two frames in three, two windows running, stop the pictures in between")

func _menu() -> void:
	I18n.use("en")
	var menu := Menu.new()
	var state := {"has_video": true, "layer_available": true, "grade_on_layer": true,
		"picture_quality_supported": true, "picture_quality_available": true, "picture_quality": true, "picture_sharpness": 50.0,
		"grade_curves_locked": false, "grade_values": Grade.DEFAULTS.duplicate(), "color_grade": {"preset": "Custom"},
		"picture_interpolation": false, "picture_interpolation_blocker": ""}
	var asked := []
	menu.state_provider = func(): return state
	menu.setting_requested.connect(func(key: String, value: Variant): asked.append([key, value]))
	root.add_child(menu)
	menu.toggle()
	menu._open_picture_controls()
	var option := func(value: int) -> Dictionary:
		return menu._buttons.filter(func(button): var target: Dictionary = menu.choices.targets.get(button.target, {}); return target.get("key", "") == "picture_interpolation" and int(target.get("value", -1)) == value)[0]
	check("Frame interpolation" in menu.text_snapshot(), "The picture quality page has the row")
	check(option.call(1).enabled, "On is on offer for a video that can take it")
	var inside := true
	for value in [0, 1]:
		var rect: Rect2 = option.call(value).rect
		inside = inside and menu._picture_panel_bounds.encloses(rect)
	check(inside, "The row lies within the panel")
	for blocker in Menu.PICTURE_INTERPOLATION_BLOCKERS:
		if blocker == "load": continue
		state.picture_interpolation_blocker = blocker
		state.picture_interpolation = true
		menu.refresh()
		check(not option.call(1).enabled and menu._tips[option.call(1).target] == Menu.PICTURE_INTERPOLATION_BLOCKERS[blocker], "A video blocked by " + blocker + " greys the row and says why")
	state.picture_interpolation_blocker = "load"
	menu.refresh()
	check(option.call(1).enabled and not option.call(1).get("selected", false) and menu._tips[option.call(1).target] == Menu.PICTURE_INTERPOLATION_STOPPED,
		"Stopped for the load, the row shows off and stays open to try again")
	state.picture_interpolation_blocker = ""
	state.picture_quality = false
	menu.refresh()
	check(not option.call(1).enabled and menu._tips[option.call(1).target] == Menu.PICTURE_LOCKED_HINT, "The row waits for the mode")
	for language in ["zh", "zh_Hant", "ja"]:
		I18n.use(language)
		for text in ["Frame interpolation (Beta)", Menu.PICTURE_INTERPOLATION_HINT, Menu.PICTURE_INTERPOLATION_STOPPED] + Menu.PICTURE_INTERPOLATION_BLOCKERS.values():
			check(I18n.t(text) != text, "%s has a translation for: %s" % [language, text.left(40)])
	I18n.use("en")
	menu.queue_free()
