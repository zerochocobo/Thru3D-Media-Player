extends RefCounted
## System volume is observed, not restored from per-file or application defaults.
const Methods := preload("res://scripts/platform_methods.gd")
var video: Node
var observed := false
var writable := false
var last_nonzero := 50.0
var _poll_at := 0
var _write := 0
var _boost := -1
var _source := ""
var _session := 0

func _init(owner_video: Node) -> void: video = owner_video

func supported() -> bool:
	return Methods.supports(video.platform, "system_media_volume") and Methods.supports(video.platform, "set_system_media_volume")

func poll(force: bool = false) -> void:
	if not supported() or (not force and Time.get_ticks_msec() < _poll_at): return
	_poll_at = Time.get_ticks_msec() + 75
	var state: Variant = JSON.parse_string(str(video.platform.system_media_volume()))
	if not state is Dictionary: return
	var previous := [observed, writable, video.audio_volume, video.audio_muted]
	observed = bool(state.get("available", false))
	writable = observed and bool(state.get("writable", false))
	if not observed:
		_boost = -1
		if previous != [observed, writable, video.audio_volume, video.audio_muted]: video.changed.emit()
		return
	var percent := float(state.get("percent", 0))
	if not is_finite(percent) or percent < 0 or percent > 100: return
	video.audio_volume = percent
	video.audio_muted = bool(state.get("muted", false)) or percent == 0
	if percent > 0: last_nonzero = percent
	if _write > 0 and int(state.get("write_serial", 0)) >= _write:
		_write = 0
		var boost := _boost
		_boost = -1
		if boost >= 0 and bool(state.get("write_ok", false)) and percent == 100 and writable \
			and _source == video.local_uri and _session == video.media.session_id and video.audio_whisper > 0:
			video.set_audio_whisper(boost + 1)
	# A hardware/system-panel decrease must remain a decrease: remove only makeup
	# gain, retain the dialogue compressor and the last per-video boost bookmark.
	if _write == 0 and percent < 100 and video.audio_whisper > 1:
		video.set_audio_whisper(1, false)
	if previous != [observed, writable, video.audio_volume, video.audio_muted]: video.changed.emit()

func request(value: float, show_ui: bool = true) -> bool:
	if not is_finite(value) or value < 0 or value > 150: return false
	poll(true)
	if not writable or (value > 100 and video.audio_whisper <= 0): return false
	# A newer drag supersedes an older deferred boost, even before the system ack.
	_boost = -1
	if value <= 100 and video.audio_whisper > 1: video.set_audio_whisper(1, false)
	var serial: int = video.platform.set_system_media_volume(minf(value, 100), show_ui)
	if serial <= 0: return false
	_write = serial
	_source = video.local_uri; _session = video.media.session_id
	_boost = roundi(value - 100) if value > 100 else -1
	return true

func cancel_source() -> void:
	_boost = -1; _source = ""; _session = 0

func level() -> float:
	if video.audio_muted: return 0
	return 100.0 + video.audio_whisper - 1 if video.audio_whisper > 1 else video.audio_volume

func toggle_mute() -> bool:
	return request(last_nonzero if video.audio_muted or video.audio_volume == 0 else 0)
