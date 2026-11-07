extends SceneTree

const Video := preload("res://scripts/mpv_video_display.gd")
var failures: Array[String] = []

class RetryProbe extends "res://scripts/mpv_video_display.gd":
	var reopens: Array = []
	func _reopen_at(position_ms: int, layer: bool) -> void:
		reopens.append([position_ms, layer])

func _check(value: bool, message: String) -> void:
	if not value:
		failures.append(message)

func _initialize() -> void:
	var video := Video.new()
	video.local_uri = "http://127.0.0.1:39565/a/video.mp4"
	video.media.format = {"width": 8192, "height": 4096, "pixel_aspect": 1.0, "unapplied_rotation_degrees": 0}
	video.media.playback = {"details": {"codec": "hevc", "hwdec_current": "no"}}
	_check(video.software_decode_limited(), "8K CPU decoding is limited")
	video._software_notice_uri = video.local_uri
	video._software_notice_until = Time.get_ticks_msec() + Video.SOFTWARE_DECODE_NOTICE_MS
	_check(video.hud_caption().contains("8192×4096"), "HUD names the rejected source size")
	video._software_notice_until = Time.get_ticks_msec() - 1
	_check(not video.hud_caption().contains("8192×4096"), "Notice expires")
	video.media.playback.details.hwdec_current = "mediacodec"
	_check(not video.software_decode_limited(), "Hardware decoding is not flagged")
	video.media.playback.details.hwdec_current = "no"
	video.media.format.width = 3840
	video.media.format.height = 1080
	_check(not video.software_decode_limited(), "Full-SBS 1080p MVC stays below the notice")
	video.media.format.width = 3840
	video.media.format.height = 2160
	_check(video.software_decode_limited(), "4K CPU decoding is limited")
	video.media.format.spatial_video = true
	_check(not video.software_decode_limited(), "Spatial MOV software decoding is by design")
	video.media.format.erase("spatial_video")
	video.media.playback.details.codec = ""
	_check(not video.software_decode_limited(), "No verdict before the codec is known")
	video.free()
	var retry := RetryProbe.new()
	retry.local_uri = "http://127.0.0.1:39565/b/video.mp4"
	_check(not retry._await_web_decoder(), "Library playback never waits for a browser decoder")
	retry._web_handoff = true
	retry.media.playback = {"details": {"dolby_profile5": true}}
	_check(not retry._await_web_decoder(), "Profile 5 cannot use the layer however long it waits")
	retry.media.playback = {"details": {"codec": "hevc", "hwdec_current": "no"}}
	_check(retry._await_web_decoder() and retry.reopens.is_empty(), "Web handoff waits before retrying hardware")
	for attempt in Video.WEB_DECODER_RETRIES:
		retry._decoder_retry_at = Time.get_ticks_msec() - 1
		_check(retry._await_web_decoder(), "Retry %d is taken" % (attempt + 1))
		retry._decoder_retry_at = 0
	_check(retry.reopens.size() == Video.WEB_DECODER_RETRIES and retry.reopens.all(func(r): return r[1]), "Each retry reopens the layer")
	_check(not retry._await_web_decoder(), "Exhausted retries settle on software decoding")
	retry.local_uri = "http://127.0.0.1:39565/c/video.mp4"
	_check(retry._await_web_decoder(), "A new file gets its own retries")
	retry.free()
	print("software decode notice failures=%d" % failures.size())
	for failure in failures: push_error(failure)
	quit(1 if not failures.is_empty() else 0)
