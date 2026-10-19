extends "res://scripts/mpv_video_display.gd"
## Experimental desktop decoder behind the production media surface and menu API.
## The extension stays outside res:// so Android never discovers or exports it.

signal file_picker_requested

class DesktopMediaState extends "res://scripts/mpv_media_state.gd":
	func snapshot() -> Dictionary:
		var result := super.snapshot()
		result.backend = "desktop_ffmpeg"
		result.frame_pairing = "desktop_CPU_Texture2D"
		result.presentation_identity = {"source_pts_verified": false, "immutable_color_frame": false, "pair_identity_verified": false}
		result.device_validation = "desktop_only"
		return result

var decoder_extension_path := ProjectSettings.globalize_path("res://../../build/desktop-video/runtime-patched/FFmpegPlayer.gdextension")
var open_timeout_ms := 6000
var _desktop_player: VideoStreamPlayer
var _candidate: VideoStreamPlayer
var _candidate_request: Dictionary = {}
var _desktop_texture: Texture2D
var _desktop_extension: Resource
var _desktop_session := 0
var _desktop_completed := false
var _desktop_clock_ms := -1
var _desktop_notify_after := 0
var _desktop_seek_after := 0


func _init() -> void:
	media = DesktopMediaState.new()
	history_enabled = false
	_remember_file = false


func _ready() -> void:
	super._ready()
	_desktop_player = _new_player()
	material.set_shader_parameter("alpha_enabled", false)
	material.set_shader_parameter("depth_enabled", false)
	material.set_shader_parameter("packed_alpha", false)


func pick_file() -> void:
	file_picker_requested.emit()


func open_local(uri: String, title: String, start_ms: int = 0, _restore_mode: bool = true, alpha: bool = false, _basename: String = "", metadata: Dictionary = {}) -> bool:
	_cancel_candidate()
	if alpha:
		return _desktop_error("Desktop playback does not support portrait passthrough")
	var path := _local_path(uri)
	if path.is_empty() or not FileAccess.file_exists(path):
		return _desktop_error("Local video unavailable")
	var source := FileAccess.open(path, FileAccess.READ)
	if not source or source.get_length() < 32:
		return _desktop_error("Video file is empty or invalid")
	source.close()
	if not _load_decoder():
		return false
	var stream := ClassDB.instantiate("VideoStreamFFmpeg") as VideoStream
	if not stream:
		return _desktop_error("Desktop video decoder unavailable")
	stream.file = path
	_candidate = _new_player()
	_candidate.volume_db = -80.0
	_candidate_request = {"uri": uri, "title": title, "start_ms": maxi(0, start_ms),
		"started": Time.get_ticks_msec(), "metadata": metadata.duplicate(true), "finished": false}
	_candidate.stream = stream
	_candidate.play()
	if start_ms > 0:
		_candidate.stream_position = float(start_ms) / 1000.0
	picker_error = ""
	# Keep the old stream, texture, dimensions and screen pose until the new
	# decoder has delivered usable video. Two audio streams must never mix.
	changed.emit()
	return true


func close_video() -> void:
	_cancel_candidate()
	_desktop_seek_after = 0
	_desktop_completed = false
	requested_play = false
	_waiting_first = false
	control.close()
	media.close()
	local_uri = ""
	display_name = ""
	picker_error = ""
	_desktop_texture = null
	if material:
		material.set_shader_parameter("color_texture", null)
	if panel:
		panel.visible = false
	if is_instance_valid(_desktop_player):
		_retire_player(_desktop_player)
	_desktop_player = null
	changed.emit()


func toggle_play() -> void:
	if not _has_desktop_video():
		return
	if media.state == "ended":
		requested_play = true
		seek_absolute(0)
		return
	requested_play = not requested_play
	_desktop_player.paused = not requested_play
	_update_desktop_state(true)


func set_playback_speed(_value: float) -> bool:
	# 4.7 exposes a video speed_scale, but this extension's real audio mixing at
	# other rates has not been validated. Keep the decoder at the tested 1x.
	return false


func set_audio_options(track_id: int, volume: float, muted: bool) -> bool:
	if not _has_desktop_video() or track_id not in [-1, 0, 1] or not is_finite(volume) or volume < 0 or volume > 100:
		return false
	audio_track_id = track_id
	audio_volume = volume
	audio_muted = muted or volume <= 0.0 or track_id == 0
	_apply_desktop_audio()
	audio_options_changed.emit(audio_volume, audio_muted)
	_update_desktop_state(true)
	return true


func seek_absolute(position_ms: int, _mode: String = "") -> bool:
	if not _has_desktop_video() or control.duration_ms <= 0:
		return false
	control.seek_absolute(position_ms)
	var request := control.take_pending()
	if media.state == "ended":
		_desktop_player.play()
	_desktop_completed = false
	_desktop_player.stream_position = float(request.target_ms) / 1000.0
	# A paused VideoStreamPlayer does not run its decoder update. Let it render
	# the sought frame silently, then restore the user's pause and volume intent.
	_desktop_player.paused = false
	if not requested_play:
		_desktop_player.volume_db = -80.0
	_desktop_seek_after = Time.get_ticks_msec() + 60
	media.state = "seeking"
	changed.emit()
	return true


func seek_relative(delta_ms: int) -> bool:
	if not _has_desktop_video():
		return false
	var base := control.display_position_ms()
	return seek_absolute(base + clampi(delta_ms, -2147483647, 2147483647))


func playback_end_ready() -> bool:
	return _desktop_completed and media.state == "ended" and requested_play and not control.pending and control.in_flight == 0


func set_alpha(enabled: bool) -> bool:
	return not enabled


func set_depth(enabled: bool) -> bool:
	return not enabled


func set_projection(value: int) -> void:
	if value == Geometry.Geometry.FLAT:
		geometry = value
		_apply_geometry()


func cycle_projection() -> void:
	pass


func toggle_stereo() -> void:
	# Desktop keyboard S bypasses main's menu capability checks. This preview
	# accepts mono video only, so that shortcut must never halve the picture.
	pass


func set_stereo_layout(layout: int) -> void:
	if layout != 0:
		return
	geometry = Geometry.Geometry.FLAT
	stereo_sbs = false
	top_bottom = false
	stereo_half = false
	_apply_geometry()


func layout_snapshot() -> Dictionary:
	var result := super.layout_snapshot()
	result.backend = "desktop_ffmpeg"
	result.device_validation = "desktop_only"
	result.playback_control.seek_method = "VideoStreamPlayer.stream_position"
	result.playback_control.source_frame_pts_verified = false
	result["source_pts_verified"] = false
	result["pair_identity_verified"] = false
	return result


func snapshot() -> Dictionary:
	return {"backend": "desktop_ffmpeg", "media": media.snapshot(), "layout": layout_snapshot(),
		"source_pts_verified": false, "pair_identity_verified": false}


func mode_action_allowed(operation: String) -> bool:
	return operation not in ["alpha", "depth", "depth_strength", "clone_voice", "lock_mode", "stereo", "projection"] \
		and not operation.begins_with("projection_") and not operation.begins_with("stereo_") and not operation.begins_with("fov_")


func _request_revision(_position_ms: int = -1, _mode: String = "") -> void:
	# A desktop surface change never enters the Android MPV slot lifecycle.
	geometry = Geometry.Geometry.FLAT
	_apply_geometry()


func _remember_mode(_user_change: bool = true) -> void:
	pass


func _record_history(_force: bool = false) -> void:
	pass


func _process(_delta: float) -> void:
	if _candidate:
		_poll_candidate()
	if not _has_desktop_video():
		return
	var now := Time.get_ticks_msec()
	if _desktop_seek_after > 0 and now >= _desktop_seek_after:
		_desktop_seek_after = 0
		_desktop_player.paused = not requested_play
		_apply_desktop_audio()
		var position := int(_desktop_player.stream_position * 1000.0)
		var request := control.in_flight
		control.first_frame(position)
		seek_presented.emit(request, position)
	_update_desktop_state(now >= _desktop_notify_after)


func _new_player() -> VideoStreamPlayer:
	var player := VideoStreamPlayer.new()
	player.name = "DesktopVideoDecoder"
	player.visible = false
	player.autoplay = false
	player.expand = true
	player.finished.connect(_on_desktop_finished.bind(player))
	add_child(player)
	return player


func _load_decoder() -> bool:
	if ClassDB.class_exists("VideoStreamFFmpeg"):
		return true
	if not FileAccess.file_exists(decoder_extension_path):
		return _desktop_error("Desktop video decoder is not installed")
	_desktop_extension = load(decoder_extension_path)
	if not ClassDB.class_exists("VideoStreamFFmpeg"):
		return _desktop_error("Desktop video decoder could not be loaded")
	return true


func _poll_candidate() -> void:
	var texture := _candidate.get_video_texture()
	var age := Time.get_ticks_msec() - int(_candidate_request.started)
	if texture and texture.get_width() > 0 and texture.get_height() > 0 and age >= 40 and _decoded_image_ready(texture):
		_commit_candidate(texture)
	elif age >= open_timeout_ms or (_candidate_request.get("finished", false) and age >= 100):
		_cancel_candidate()
		_desktop_error("Video could not be decoded or contains no video track")


func _decoded_image_ready(texture: Texture2D) -> bool:
	# v1.0.1 allocates an all-zero RGBA texture before decoding. FFmpeg's opaque
	# video frames have alpha, including a legitimate completely black frame.
	# A playback clock and nonzero dimensions alone cannot prove a first frame.
	var image := texture.get_image()
	if not image or image.is_empty():
		return false
	for pixel in [Vector2i.ZERO, Vector2i(image.get_width() / 2, image.get_height() / 2), Vector2i(image.get_width() - 1, image.get_height() - 1)]:
		if image.get_pixelv(pixel).a > 0.01:
			return true
	return false


func _commit_candidate(texture: Texture2D) -> void:
	var previous := _desktop_player
	var request := _candidate_request
	_desktop_player = _candidate
	_candidate = null
	_candidate_request = {}
	_desktop_texture = texture
	material.set_shader_parameter("color_texture", texture)
	# Bind the new texture before stopping the old player, whose native stop
	# may release its image. No material may retain a decoder's retired texture.
	if is_instance_valid(previous):
		_retire_player(previous)
	_desktop_session += 1
	media.begin(_desktop_session)
	media.decoder = "FFmpeg desktop software"
	media.format = {"width": texture.get_width(), "height": texture.get_height(), "pixel_aspect": 1.0, "unapplied_rotation_degrees": 0}
	media.format_revision += 1
	local_uri = str(request.uri)
	display_name = str(request.title)
	source_location = preload("res://scripts/media_location.gd").infer(local_uri)
	requested_play = true
	_waiting_first = false
	geometry = Geometry.Geometry.FLAT
	stereo_sbs = false
	top_bottom = false
	stereo_half = false
	alpha_requested = false
	alpha_enabled = false
	depth_requested = false
	depth_enabled = false
	packed_file = false
	packed_alpha = false
	_layer_session = false
	_layer_requested = false
	_frame_picture = false
	_desktop_completed = false
	_desktop_clock_ms = -1
	_desktop_seek_after = 0
	picker_error = ""
	control.close()
	control.observe(int(_desktop_player.stream_position * 1000.0), int(_desktop_player.get_stream_length() * 1000.0))
	material.set_shader_parameter("source_size", Vector2(texture.get_width(), texture.get_height()))
	material.set_shader_parameter("alpha_enabled", false)
	material.set_shader_parameter("depth_enabled", false)
	material.set_shader_parameter("packed_alpha", false)
	_apply_geometry()
	panel.visible = true
	_apply_desktop_audio()
	_update_desktop_state(true)


func _update_desktop_state(notify: bool) -> void:
	if not _has_desktop_video():
		return
	var position := maxi(0, int(_desktop_player.stream_position * 1000.0))
	var duration := maxi(0, int(_desktop_player.get_stream_length() * 1000.0))
	if media.state == "ended":
		position = duration
	if media.state != "ended" and _desktop_seek_after == 0:
		media.state = "playing" if requested_play else "paused"
	# The extension supplies a texture and a playback clock, not decoder frame
	# serials or source PTS. Do not turn 60Hz UI clock samples into fake FPS.
	_desktop_clock_ms = position
	control.observe(position, duration)
	media.playback = {"state": media.state, "backend": "desktop_ffmpeg", "details": {
		"position_seconds": str(float(control.display_position_ms()) / 1000.0), "duration_seconds": str(float(duration) / 1000.0),
		"seekable": "yes" if duration > 0 else "no", "partially_seekable": "no", "codec": "FFmpeg",
		"hwdec_current": "no", "audio_tracks": [{"id": 1, "title": "Default audio"}],
		"audio_track_id": 0 if audio_muted else 1, "volume": audio_volume, "muted": audio_muted,
		"subtitle_tracks": [], "playback_speed": 1.0}}
	if notify:
		_desktop_notify_after = Time.get_ticks_msec() + 200
		changed.emit()


func _apply_desktop_audio() -> void:
	if _desktop_player:
		_desktop_player.volume_db = -80.0 if audio_muted or audio_volume <= 0.0 else linear_to_db(audio_volume / 100.0)


func _on_desktop_finished(player: VideoStreamPlayer) -> void:
	if player == _candidate:
		_candidate_request["finished"] = true
		return
	if player != _desktop_player or not _has_desktop_video():
		return
	if loop_enabled and requested_play:
		player.play()
		_desktop_completed = false
		control.reject()
		_update_desktop_state(true)
		return
	control.reject()
	control.observe(control.duration_ms, control.duration_ms)
	media.state = "ended"
	_desktop_completed = true
	_update_desktop_state(true)
	if requested_play:
		playback_completed.emit()


func _cancel_candidate() -> void:
	if is_instance_valid(_candidate):
		_retire_player(_candidate)
	_candidate = null
	_candidate_request = {}


func _retire_player(player: VideoStreamPlayer) -> void:
	var callback := _on_desktop_finished.bind(player)
	if player.finished.is_connected(callback):
		player.finished.disconnect(callback)
	player.stop()
	player.stream = null
	player.queue_free()


func _has_desktop_video() -> bool:
	return is_instance_valid(_desktop_player) and _desktop_player.stream != null and media.accepts(media.session_id)


func _desktop_error(message: String) -> bool:
	picker_error = message
	if not _has_desktop_video():
		media.state = "failed"
		media.error = message
	changed.emit()
	playback_failed.emit()
	return false


func _local_path(uri: String) -> String:
	if uri.begins_with("file://"):
		var path := uri.trim_prefix("file://").uri_decode()
		# Canonical Windows file:///C:/ paths carry one leading URI slash.
		return path.substr(1) if path.length() >= 3 and path[0] == "/" and path[2] == ":" else path
	if uri.contains("://"):
		return ""
	return ProjectSettings.globalize_path(uri)
