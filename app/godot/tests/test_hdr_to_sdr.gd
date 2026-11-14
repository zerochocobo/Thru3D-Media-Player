extends SceneTree
## HDR to SDR: On has an HDR source leave the compositor layer for MPV's SDR frames; Off keeps or
## returns it to the layer. Unset is Off on the Meta runtime and On elsewhere; one global setting in both menus.
const Video := preload("res://scripts/mpv_video_display.gd")
const HdrToSdr := preload("res://scripts/hdr_to_sdr.gd")
const Menu := preload("res://scripts/player_menu.gd")
var checks := 0
var failures: Array[String] = []

class Host extends RefCounted:
	func close_mpv_video(_id: int) -> void: pass
	func detach_mpv_pair(_id: int, _token: int) -> void: pass
	func set_mpv_audio(_id: int, _track: int, _volume: float, _muted: bool) -> bool: return true
	func set_mpv_subtitle(_id: int, _track: Variant) -> bool: return true

class Layers extends "res://scripts/video_layer.gd":
	func update_session() -> void: pass
	func available() -> bool: return true
	func supports(_geometry: int, _curved: bool) -> bool: return true
	func _apply(count: int, _values: PackedFloat32Array, _orders := PackedInt32Array()) -> bool: return count > 0

class Reopen extends "res://scripts/mpv_video_display.gd":
	var opens: Array = []
	func open_local(uri: String, _title: String, start_ms: int = 0, _restore_mode: bool = true,
			_alpha: bool = false, _basename: String = "", _metadata: Dictionary = {}) -> bool:
		opens.append({"uri": uri, "position": start_ms, "eye_buffer": _eye_buffer_only})
		close_video()
		media.begin(media.session_id + 1)
		_layer_requested = false
		return true

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func _initialize() -> void: call_deferred("_run")

func _video(origin: Node, uri: String, session: int) -> Reopen:
	var video := Reopen.new()
	origin.add_child(video); video.set_process(false)
	video.platform = Host.new(); video.video_layer = Layers.new(null)
	video.local_uri = uri
	video.media.begin(session)
	return video

func _state(video: Reopen, session: int, hdr: bool) -> void:
	video._on_state(session, JSON.stringify({"state": "playing", "layer_compatible": true, "source_start_ms": 30000,
		"details": {"position_seconds": "30.0", "duration_seconds": "7200", "hdr_source": hdr,
			"color_transfer": "pq" if hdr else "bt.1886"}}))

func _run() -> void:
	var origin := XROrigin3D.new()
	root.add_child(origin)
	check(HdrToSdr.choice("bogus").value == HdrToSdr.ON and HdrToSdr.choice(HdrToSdr.OFF).value == HdrToSdr.OFF
		and HdrToSdr.normalize("auto").is_empty() and HdrToSdr.normalize(HdrToSdr.OFF) == HdrToSdr.OFF,
		"Unknown stored values, including the earlier Auto, follow the headset default")

	# On (unset off Meta's runtime): an HDR layer session reopens on MPV's SDR frames, once, at its position.
	var hdr := _video(origin, "file:///uhd_bluray.m2ts", 3)
	hdr._layer_requested = true
	_state(hdr, 3, true)
	check(hdr.opens.size() == 1 and hdr.opens[0].eye_buffer and hdr.opens[0].position == 30000,
		"An HDR layer session reopens on the converted frames: %s" % [hdr.opens])
	check(hdr._layer_blocked_uri == hdr.local_uri and hdr._hdr_blocked_uri == hdr.local_uri and hdr._layer_return_uri.is_empty(),
		"The file stays off the layer with no automatic return")
	_state(hdr, hdr.media.session_id, true)
	hdr._update_layer()
	check(hdr.opens.size() == 1, "The converted session is not reopened again")
	hdr.video_layer_shown = false
	check(hdr.layer_block_reason() == "hdr", "The FPS overlay names HDR: %s" % hdr.layer_block_reason())

	# Off: the file returns to the layer; On again moves it back off.
	hdr.set_hdr_to_sdr(HdrToSdr.OFF)
	check(hdr._layer_blocked_uri.is_empty() and hdr._hdr_blocked_uri.is_empty() and hdr._layer_return_uri == hdr.local_uri,
		"Off releases a file held off the layer only for HDR")
	hdr._layer_requested = true
	_state(hdr, hdr.media.session_id, true)
	check(hdr.opens.size() == 1, "Off keeps an HDR layer session on the layer")
	hdr.set_hdr_to_sdr(HdrToSdr.ON)
	hdr._update_layer()
	check(hdr.opens.size() == 2 and hdr.opens[1].eye_buffer, "On moves the running layer session to the converted frames")
	hdr.free()

	# A Profile 5 block is not released by Off.
	var dovi := _video(origin, "file:///dv5.mp4", 4)
	dovi._layer_blocked_uri = dovi.local_uri
	dovi.set_hdr_to_sdr(HdrToSdr.OFF)
	check(dovi._layer_blocked_uri == dovi.local_uri, "Off never releases a decoder block")
	dovi.free()

	# Meta's compositor shows HDR itself (Quest 3): unset keeps the layer there; On still converts.
	var VideoLayer := preload("res://scripts/video_layer.gd")
	check(VideoLayer.hdr_surface_runtime("Oculus", false) and VideoLayer.hdr_surface_runtime("Meta XR Runtime", false)
		and not VideoLayer.hdr_surface_runtime("PICO OpenXR runtime", false) and not VideoLayer.hdr_surface_runtime("Oculus", true)
		and not VideoLayer.hdr_surface_runtime("", false), "Only the Meta runtime shows the HDR surface itself")
	var quest := _video(origin, "file:///quest_hdr.mkv", 7)
	quest.video_layer.hdr_surface = true
	quest._layer_requested = true
	_state(quest, 7, true)
	quest._update_layer()
	check(quest.hdr_to_sdr_mode() == HdrToSdr.OFF and quest.opens.is_empty() and quest._layer_blocked_uri.is_empty(),
		"Unset keeps HDR on the Meta compositor layer")
	quest.set_hdr_to_sdr(HdrToSdr.ON)
	quest._update_layer()
	check(quest.opens.size() == 1 and quest.opens[0].eye_buffer, "On converts on the Meta runtime too")
	quest.free()

	# SDR keeps the layer.
	var sdr := _video(origin, "file:///sdr.mp4", 5)
	sdr._layer_requested = true
	_state(sdr, 5, false)
	sdr._update_layer()
	check(sdr.opens.is_empty() and sdr._layer_blocked_uri.is_empty(), "SDR stays on the layer")
	sdr.free()

	# Already in the eye buffers (3D): HDR blocks the later return instead of a layer round trip.
	var depth := _video(origin, "file:///hdr_3d.mkv", 6)
	depth._layer_return_uri = depth.local_uri
	_state(depth, 6, true)
	check(depth.opens.is_empty() and depth._layer_return_uri.is_empty() and depth._layer_blocked_uri == depth.local_uri,
		"An eye-buffer HDR session cancels its return to the layer")
	depth.free()

	# Player menu: a settings tile with the same global choice.
	var menu := Menu.new()
	menu._state = {"has_video": true, "hdr_to_sdr": HdrToSdr.OFF}
	check("hdr_to_sdr" in Menu.OPERATIONS[1] and Menu.OPERATIONS[1].size() == Menu.HEADINGS.size()
		and Menu.HEADINGS.size() == Menu.SETTING_ICONS.size(), "The tile has a heading and an icon")
	var choice: Dictionary = menu._setting_choices("hdr_to_sdr")
	check(choice.get("key") == "hdr_to_sdr" and choice.get("value") == HdrToSdr.OFF and choice.choices.size() == 2,
		"The tile offers Auto and Off with the current value: %s" % choice)
	menu.free()

	origin.free()
	for failure in failures: push_error(failure)
	print("HDR to SDR checks=%d failures=%d" % [checks, failures.size()])
	quit(1 if not failures.is_empty() else 0)
