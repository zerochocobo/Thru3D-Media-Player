extends SceneTree
## Picture quality mode under 2D to 3D: the bridge's stereo pair is drawn into the picture layer denoised,
## enlarged and sharpened eye by eye instead of copied, and the eye buffers' draw stays out of its way.
## With frame interpolation the native side keeps each pair, and every refresh draws the picture for its moment.
const Video := preload("res://scripts/mpv_video_display.gd")
const VideoLayer := preload("res://scripts/video_layer.gd")
const Geometry := preload("res://scripts/video_geometry.gd")
var checks := 0
var failures: Array[String] = []

class Host extends RefCounted:
	var created: Array = []
	var copied: Array = []
	var enhanced: Array = []
	var refuse_above := 0 # widths above this are refused (0: none)
	var pushed: Array = []
	var between: Array = []
	var delays: Array = []
	var released := 0
	var refuse_pairs := false
	var nearest_only := false
	func interpolate_pair_push(texture: int, w: int, h: int, id: int, before: int) -> bool:
		pushed.append([texture, w, h, id, before])
		return not refuse_pairs
	func interpolate_pair_draw(slot: int, before: int, after: int, phase: float, w: int, h: int, sharpen: float, grade: PackedFloat32Array,
			_step: float, _tolerance: float) -> bool:
		between.append({"slot": slot, "before": before, "after": after, "phase": phase, "source": [w, h], "sharpen": sharpen, "graded": not grade.is_empty()})
		return true
	# Pairs shown at their own size are kept as the mode's finished pictures and shown in one draw.
	var finished: Array = []
	func interpolate_pair_push_enhanced(texture: int, w: int, h: int, id: int, before: int, sharpen: float, grade: PackedFloat32Array,
			_step: float, _tolerance: float) -> bool:
		pushed.append([texture, w, h, id, before])
		finished.append({"id": id, "sharpen": sharpen, "graded": not grade.is_empty()})
		return not refuse_pairs
	func interpolate_pair_show(slot: int, before: int, after: int, phase: float) -> bool:
		between.append({"slot": slot, "before": before, "after": after, "phase": phase, "direct": true})
		return true
	func interpolate_pair_show_phase(slot: int, before: int, after: int, phase: float) -> float:
		interpolate_pair_show(slot, before, after, phase)
		return roundf(phase) if nearest_only else phase
	func interpolate_pair_draw_phase(slot: int, before: int, after: int, phase: float, w: int, h: int, sharpen: float,
			grade: PackedFloat32Array, step: float, tolerance: float) -> float:
		interpolate_pair_draw(slot, before, after, phase, w, h, sharpen, grade, step, tolerance)
		return roundf(phase) if nearest_only else phase
	func interpolate_pair_release() -> void: released += 1
	func set_mpv_pair_delay(id: int, ms: float) -> bool:
		delays.append([id, ms])
		return true
	func create_layer_image(slot: int, w: int, h: int, _levels: int, _static: bool) -> bool:
		if refuse_above > 0 and w > refuse_above: return false
		if created.is_empty() or created[-1] != [slot, w, h]: created.append([slot, w, h])
		return true
	func acquire_layer_image(_slot: int) -> int: return 1
	func copy_layer_texture(slot: int, texture: int) -> bool:
		copied.append([slot, texture])
		return true
	func enhance_layer_texture(slot: int, texture: int, w: int, h: int, across: int, down: int, sharpen: float, grade: PackedFloat32Array,
			_step: float, _tolerance: float) -> bool:
		enhanced.append({"slot": slot, "texture": texture, "source": [w, h], "eyes": [across, down], "sharpen": sharpen, "graded": not grade.is_empty()})
		return true
	func enhance_frame_texture(_texture: int, _external: bool, _w: int, _h: int, _sx: float, _sy: float, _ow: int, _oh: int,
			_across: int, _down: int, _sharpen: float, _step: float, _tolerance: float) -> int: return 0
	func set_layer_picture_quality(_enabled: bool) -> void: pass
	func release_layer_image(_slot: int, _mipmaps: bool) -> bool: return true
	func close_mpv_video(_id: int) -> void: pass
	func detach_mpv_pair(_id: int, _token: int) -> void: pass

class PlainHost extends RefCounted:
	func create_layer_image(_slot: int, _w: int, _h: int, _levels: int, _static: bool) -> bool: return true
	func copy_layer_texture(_slot: int, _texture: int) -> bool: return true
	func set_layer_picture_quality(_enabled: bool) -> void: pass
	func close_mpv_video(_id: int) -> void: pass
	func detach_mpv_pair(_id: int, _token: int) -> void: pass

class Layers extends "res://scripts/video_layer.gd":
	var shown := PackedFloat32Array()
	var display := 0 # the runtime's display time of the frame being drawn, and its refresh period
	var period := 0
	func predicted_display_ns() -> int: return display
	func refresh_period_ns() -> int: return period
	func update_session() -> void: pass
	func available() -> bool: return true
	func supports(_geometry: int, _curved: bool) -> bool: return true
	func _apply(count: int, values: PackedFloat32Array, _orders := PackedInt32Array()) -> bool:
		shown = values
		return count > 0

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func _initialize() -> void: call_deferred("_run")

## A 1080p frame's stereo pair as the bridge hands it over.
func _pair(token: int, width := 1920, height := 1080) -> Dictionary:
	return {"session_id": 5, "color_target": "texture", "color_texture_id": 40 + token, "warp_texture_id": 80 + token,
		"width": width, "height": height, "warp_width": width * 2, "warp_height": height, "slot_token": token, "stereo_sbs": true}

## A film's pair at its source time (a frame is 41.708 ms).
func _film(token: int, frame: int) -> Dictionary:
	var pair := _pair(token)
	pair["pts_us"] = 10_000_000 + frame * 41_708
	pair["depth_ran"] = true
	return pair

func _interpolation(video: Video, host: Host, origin: XROrigin3D) -> void:
	var layers: Layers = video.video_layer
	video._depth_picture = false
	video.picture_upscale = Video.Upscale.OFF
	video.media.playback = {"details": {"container_fps": "23.976"}}
	video._binding.ticket = _film(10, 0)
	video.picture_interpolation = true
	check(video.picture_interpolation_blocker() == "runtime" and not video.picture_interpolating(), "Without display times the pairs show as they come")
	video._show_depth_picture(origin, [])
	check(host.pushed.is_empty() and host.enhanced[-1].texture == 90, "and the pair is drawn as ever")
	layers.display = 9_000_000_000_000; layers.period = 13_888_889
	check(video.picture_interpolation_blocker() == "" and video.picture_interpolating(), "With them 2D to 3D can be interpolated")
	video._show_depth_picture(origin, [])
	check(host.pushed == [[90, 3840, 1080, 0, -1]], "The first pair is handed over, following none: %s" % [host.pushed])
	check(host.between.is_empty() and host.enhanced[-1].texture == 90, "and stays on show as it is")
	var plain := host.enhanced.size()
	layers.display += 3 * layers.period
	video._binding.ticket = _film(11, 1)
	check(video._show_depth_picture(origin, []), "The next pair keeps the picture on the layer")
	check(host.pushed[-1] == [91, 3840, 1080, 1, 0], "It follows the first: %s" % [host.pushed[-1]])
	check(host.delays.size() == 1 and host.delays[0][0] == 5 and absf(host.delays[0][1] - 69.486) < 0.01, "The audio is delayed as long as the picture: %s" % [host.delays])
	check(host.between.size() == 1 and host.between[0].before == 0 and host.between[0].phase == 0.0 and host.between[0].get("direct", false),
		"The pair on show is drawn from its copy while the delay passes, in one draw: %s" % [host.between])
	check(host.finished.size() == 2 and is_equal_approx(host.finished[-1].sharpen, Video.sharpen_strength(video.picture_sharpness)),
		"Each pair is kept as the mode's finished picture: %s" % [host.finished])
	check(host.enhanced.size() == plain and video.layer_picture_baked(VideoLayer.PICTURE), "by the mode's own draw, not a second one")
	video._show_depth_picture(origin, [])
	check(host.between.size() == 1, "The same picture is not drawn twice")
	# Playing: a pair every three refreshes, a picture every refresh.
	var token := 12
	for refresh in 18:
		layers.display += layers.period
		if refresh % 3 == 2:
			video._binding.ticket = _film(token, token - 10)
			token += 1
		video._show_depth_picture(origin, [])
	var moving := host.between.filter(func(draw): return draw.phase > 0.0 and draw.phase < 1.0)
	check(moving.size() >= 10, "Most refreshes draw a picture between two pairs: %d of %d" % [moving.size(), host.between.size() - 1])
	check(moving.all(func(draw): return draw.after == draw.before + 1), "each between a pair and the one after it")
	check(video._pair_drawn.y == moving.size(), "Only successful intermediate stereo pictures count")
	video.video_layer_shown = true
	video.media.state = "playing"; video.requested_play = true; video._waiting_first = false
	var sample := video.interpolation_sample(4000)
	check(sample.get("time") == 4000 and sample.get("between") == moving.size() and sample.get("total") == video._pair_drawn.x,
		"The live 3D readout uses both eyes as one video frame")
	check(host.enhanced.size() == plain and host.pushed.size() == 8, "Every pair is handed over once, none drawn the plain way meanwhile")
	video.picture_sharpness = 0.25
	var draws_before := host.between.size()
	video._show_depth_picture(origin, [])
	check(host.between.size() == draws_before, "A slider does not redraw a finished picture")
	# Super resolution enlarges the pairs: they are kept as they came, and each picture passes the mode's draw.
	video.picture_upscale = Video.Upscale.MAXIMUM
	video._depth_upscale_failed = 0
	layers.display += 3 * layers.period
	video._binding.ticket = _film(token, token - 10)
	token += 1
	video._show_depth_picture(origin, [])
	check(host.released == 1 and host.pushed[-1][4] == -1 and host.finished.size() == 8, "Enlarged pairs start again, kept as they came: %s" % [host.pushed[-1]])
	layers.display += 3 * layers.period
	video._binding.ticket = _film(token, token - 10)
	token += 1
	video._show_depth_picture(origin, [])
	check(host.between[-1].get("source", []) == [3840, 1080] and is_equal_approx(host.between[-1].sharpen, Video.sharpen_strength(0.25))
		and host.created[-1] == [VideoLayer.PICTURE_SLOT, 7680, 2160], "and drawn enlarged with the look of the moment: %s" % [host.between[-1]])
	video.picture_upscale = Video.Upscale.OFF
	layers.display += 3 * layers.period
	video._binding.ticket = _film(token, token - 10)
	token += 1
	video._show_depth_picture(origin, [])
	check(host.released == 2 and host.finished.size() == 9 and is_equal_approx(host.finished[-1].sharpen, Video.sharpen_strength(0.25)),
		"Back at their own size the pairs are finished pictures again, with the slider's value")
	host.nearest_only = true
	var intermediate_before := video._pair_drawn.y
	for refresh in 9:
		layers.display += layers.period
		if refresh % 3 == 2:
			video._binding.ticket = _film(token, token - 10)
			token += 1
		video._show_depth_picture(origin, [])
	check(video._pair_drawn.y == intermediate_before, "A successful draw that fell back to the nearest source is no intermediate picture")
	host.nearest_only = false
	plain = host.enhanced.size()
	var kept_pairs := host.pushed.size()
	# A pause: the picture runs on to the newest pair, which is then drawn the plain way (the bridge redraws that one in place).
	for refresh in 12:
		layers.display += layers.period
		video._show_depth_picture(origin, [])
	check(host.enhanced.size() == plain + 1 and host.enhanced[-1].texture == 80 + token - 1, "A pause ends in the newest pair, drawn as ever: %s" % [host.enhanced[-1]])
	var draws := host.between.size()
	layers.display += layers.period
	video._show_depth_picture(origin, [])
	check(host.between.size() == draws and host.enhanced.size() == plain + 1, "and nothing is drawn while it holds")
	check(host.delays[-1][1] > 60.0, "The audio keeps its delay through the pause")
	# Too large a pair is left alone.
	video._binding.ticket.warp_width = 7680; video._binding.ticket.warp_height = 2160
	check(video.picture_interpolation_blocker() == "depth_size", "A 4K pair for each eye is past what the headset draws every refresh")
	video._binding.ticket.warp_width = 3840; video._binding.ticket.warp_height = 1080
	# Off: the pairs show as they come, the audio's delay goes and the copies are freed.
	video.picture_interpolation = false
	video._binding.ticket = _film(token, token - 10)
	video._show_depth_picture(origin, [])
	check(host.enhanced[-1].texture == 80 + token and host.pushed.size() == kept_pairs, "Off: the pair is drawn the plain way and not kept")
	video._stop_pair_interpolation()
	check(host.released == 3 and host.delays[-1] == [5, 0.0], "The copies go and the audio comes back: %s" % [host.delays])
	# A GL that cannot do it.
	video.picture_interpolation = true
	host.refuse_pairs = true
	video._binding.ticket = _film(token + 1, token - 9)
	layers.display += 3 * layers.period
	check(video._show_depth_picture(origin, []) and host.enhanced[-1].texture == 81 + token, "A refused pair still shows, the plain way")
	check(video.picture_interpolation_blocker() == "load" and not video.picture_interpolating(), "and the session stops asking")
	host.refuse_pairs = false
	video.picture_interpolation = false
	video._pair_failed = 0

func _run() -> void:
	var origin := XROrigin3D.new()
	root.add_child(origin)
	var video := Video.new()
	origin.add_child(video)
	video.set_process(false)
	var host := Host.new()
	video.platform = host
	video.video_layer = Layers.new(null)
	video.video_layer.picture_quality = true
	video.geometry = Geometry.Geometry.FLAT
	video.depth_requested = true
	video.media.session_id = 5
	video.local_uri = "file:///movie-4k.mp4"
	video._binding.warped = true
	video._binding.ticket = _pair(1)
	check(video.picture_quality_available() and video.picture_quality_blocker() == "", "2D to 3D no longer keeps the mode off")
	video._sync_picture_lock()
	check(video.color_grade.curves_locked, "With the mode on offer, gamma and saturation wait for it under 3D too")

	check(video._show_depth_picture(origin, []), "The pair is shown on the picture layer with the mode off")
	check(host.copied == [[VideoLayer.PICTURE_SLOT, 81]] and host.enhanced.is_empty(), "Off: the pair is copied as it is")
	check(not video.layer_picture_baked(VideoLayer.PICTURE), "A copied pair leaves the layer's own filters on")

	video.set_picture_quality(true)
	check(video._show_depth_picture(origin, []), "On: the pair is still shown on the layer")
	check(host.enhanced.size() == 1 and host.enhanced[0].texture == 81 and host.enhanced[0].source == [3840, 1080]
		and host.enhanced[0].eyes == [2, 1], "On: the same pair is drawn again by the mode, eye by eye: %s" % [host.enhanced])
	check(host.copied.size() == 1, "On: no plain copy as well")
	check(video.layer_picture_baked(VideoLayer.PICTURE), "The drawn pair is sharpened and graded already")
	video._show_depth_picture(origin, [])
	check(host.enhanced.size() == 1, "The same pair is not drawn twice")
	video.picture_sharpness = 1.5
	video._show_depth_picture(origin, [])
	check(host.enhanced.size() == 2 and is_equal_approx(host.enhanced[-1].sharpen, 1.5), "A paused pair follows the sharpness slider")
	video._binding.ticket = _pair(2)
	video._show_depth_picture(origin, [])
	check(host.enhanced.size() == 3 and host.enhanced[-1].texture == 82, "Every new pair is drawn")

	video.picture_upscale = Video.Upscale.MAXIMUM
	video._binding.ticket = _pair(3)
	video._show_depth_picture(origin, [])
	check(host.created[-1] == [VideoLayer.PICTURE_SLOT, 7680, 2160], "Super resolution enlarges each eye of a 1080p pair to 4K: %s" % [host.created])
	check(Vector2i(video.video_layer.picture_size) == Vector2i(7680, 2160), "The layer takes the enlarged size")
	var sizes := video.picture_upscale_sizes()
	check(sizes.source == Vector2i(1920, 1080) and sizes.maximum == Vector2i(3840, 2160), "The menu names one eye's sizes: %s" % [sizes])
	video._depth_picture = true
	check(video.shown_picture().size == [3840, 2160] and video.shown_picture().upscaled, "The info page shows one enlarged eye")

	# 4K: the bridge draws the pair 2560 wide an eye; super resolution takes each eye back to 4K.
	video._binding.ticket = _pair(4, 3840, 2160)
	video._binding.ticket.warp_width = 5120; video._binding.ticket.warp_height = 1440
	host.refuse_above = 6000
	video._show_depth_picture(origin, [])
	check(host.created[-1] == [VideoLayer.PICTURE_SLOT, 5120, 1440] and host.enhanced[-1].source == [5120, 1440],
		"A runtime refusing the enlarged pair gets it at its own size, still drawn by the mode: %s" % [host.created])
	check(video._depth_upscale_failed == 5, "The refusal holds for this session")
	host.refuse_above = 0
	video._depth_picture = false
	check(video.picture_upscale_sizes().source == Vector2i(2560, 1440), "A 4K source is enlarged from the bridge's 2560-wide eye")

	# The eye buffers' draw stays off while the pair is on the layer.
	video._depth_picture = true
	video._binding.material = ShaderMaterial.new()
	video._sync_eye_quality()
	check(not video._binding.enhance_expected, "The eye buffers do not draw the mode a second time")

	_interpolation(video, host, origin)

	video.set_picture_quality(false)
	video._binding.ticket = _pair(5)
	video._show_depth_picture(origin, [])
	check(host.copied[-1] == [VideoLayer.PICTURE_SLOT, 85] and not video.layer_picture_baked(VideoLayer.PICTURE), "Off again: plain copies")

	# A plugin without the draws keeps 2D to 3D as it was, and says why.
	video.platform = PlainHost.new()
	check(not video.picture_quality_available() and video.picture_quality_blocker() == "3d", "Without the draws 3D still explains the blocker")
	video._binding.warped = false
	video._binding.ticket = {}
	video._binding.material = null
	video.free()
	origin.free()
	print("Depth picture quality checks=%d failures=%d" % [checks, failures.size()])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)
