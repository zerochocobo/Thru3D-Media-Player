extends SceneTree
## A return to the compositor layer that falls back at its first frame is not retried after every
## seek: each retry reopened the source twice and exhausted MPV's two native slots.

var checks := 0
var failures: Array[String] = []

class Backend extends RefCounted:
	func set_mpv_speed(_id: int, _value: float) -> bool: return true
	func close_mpv_video(_id: int) -> void: pass

class Layers extends "res://scripts/video_layer.gd":
	var room := 6
	func update_session() -> void: pass
	func available() -> bool: return true
	func supports(_geometry: int, _curved: bool) -> bool: return true
	func capacity() -> int: return room

class ReopenProbe extends "res://scripts/mpv_video_display.gd":
	var opens: Array = []
	func open_local(uri: String, _title: String, start_ms: int = 0, _restore_mode: bool = true,
			_alpha: bool = false, _basename: String = "", _metadata: Dictionary = {}) -> bool:
		opens.append({"uri": uri, "position": start_ms, "layer": not _eye_buffer_only})
		_eye_buffer_only = false
		media.begin(media.session_id + 1)
		_layer_session = false
		return true

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func _initialize() -> void: call_deferred("_run")

## The current session has shown a frame, on the layer or in the eye buffers.
func _settle(video: ReopenProbe, layer: bool) -> void:
	video._layer_session = layer
	video.media.frame_counter = 1
	video._update_layer()

func _run() -> void:
	var video := ReopenProbe.new()
	root.add_child(video)
	video.set_process(false)
	video.platform = Backend.new()
	var layers := Layers.new(null)
	layers.color_scale_bias = true # gain presets stay on the layer
	video.video_layer = layers
	video.local_uri = "file:///return.mp4"
	video.display_name = "return"
	video.geometry = 0
	video.media.begin(1)
	video._layer_return_uri = video.local_uri

	# The eye-buffer session returns to the layer once nothing blocks it.
	_settle(video, false)
	check(video.opens.size() == 1 and video.opens[0].layer, "An eye-buffer session returns to the layer")
	# Something only the layer session sees blocks it at its first frame.
	layers.room = 0
	_settle(video, true)
	check(video.opens.size() == 2 and not video.opens[1].layer, "The blocked layer session falls back to the eye buffers")
	check(video._layer_return_uri == video.local_uri, "The fallback keeps the file's way back to the layer")
	# After a seek the same settings would be tried again: they are not.
	layers.room = 6
	_settle(video, false)
	_settle(video, false)
	check(video.opens.size() == 2, "A failed return is not retried with unchanged settings")
	# A changed setting tries the layer again.
	video.color_grade.select("Warm")
	_settle(video, false)
	check(video.opens.size() == 3 and video.opens[2].layer, "A changed setting retries the layer")
	# A return that held past its first frame leaves later fallbacks free to return.
	_settle(video, true)
	check(video._layer_return_attempt.is_empty(), "A held return is no longer an attempt")
	layers.room = 0
	_settle(video, true)
	check(video.opens.size() == 4 and not video.opens[3].layer, "A later block still falls back")
	layers.room = 6
	_settle(video, false)
	check(video.opens.size() == 5 and video.opens[4].layer, "A fallback from a held layer session returns as before")

	print("Layer return guard: %d checks, %d failures" % [checks, failures.size()])
	for failure in failures: print("FAIL: " + failure)
	quit(1 if failures.size() else 0)
