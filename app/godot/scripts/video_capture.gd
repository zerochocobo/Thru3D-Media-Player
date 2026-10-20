extends RefCounted
## Source-time selection and asynchronous exports survive transport dismissal and file close.
signal saved(result: Dictionary)
const Methods := preload("res://scripts/platform_methods.gd")
const I18n := preload("res://scripts/i18n.gd")
const Mode := preload("res://scripts/capture_mode.gd")
var video: Node3D
var recording: Dictionary = {}
var jobs: Dictionary = {}
var notice := ""
var notice_until := 0
var _poll_after := 0
var _clock_after := 0
var _clock_playing := false

func _init(owner_video: Node3D) -> void: video = owner_video

func supported() -> bool:
	return Methods.supports(video.platform, "original_capture_supported") and video.platform.original_capture_supported()

func ready() -> bool:
	return supported() and video.geometry in [1, 2, 3] and not video.packed_file and not frame().is_empty()

func frame() -> Dictionary:
	var value: Dictionary = video.bookmark_snapshot()
	return value if not value.is_empty() and video.media.state not in ["failed", "closed"] else {}

func _playing() -> bool:
	var details: Dictionary = video.media.playback.get("details", {})
	if details.has("paused"):
		return details.get("paused", "yes") == "no" and details.get("paused_for_cache", "no") != "yes" and details.get("eof_reached", "no") != "yes"
	return video.requested_play and video.media.state == "playing"

func mode() -> Dictionary:
	return Mode.clean({"version": 1, "geometry": video.geometry, "stereo_sbs": video.stereo_sbs,
		"top_bottom": video.top_bottom, "stereo_half": video.stereo_half, "swap_eyes": video.swap_eyes, "fisheye_fov": video.fisheye_fov})

func busy(kind: String) -> bool:
	return jobs.values().any(func(job): return job.kind == kind)

func tell(message: String) -> void:
	notice = message; notice_until = Time.get_ticks_msec() + 3500

func _request(request: Dictionary) -> bool:
	var id: int = video.platform.original_capture_request(JSON.stringify(request))
	if id <= 0: tell(I18n.t("Capture is busy")); return false
	jobs[id] = request.duplicate(true)
	return true

func screenshot() -> bool:
	if not ready() or busy("screenshot"): return false
	return _request({"kind": "screenshot", "uri": video.local_uri, "mode": mode(), "position_us": int(frame().position_ms) * 1000})

func start() -> bool:
	if not recording.is_empty() or busy("clip") or not ready(): return false
	if not is_equal_approx(video.playback_speed, 1.0):
		tell(I18n.t("Recording requires 1× playback")); return false
	if not Methods.supports(video.platform, "original_capture_stop") or not Methods.supports(video.platform, "original_capture_clock"): return false
	var position := int(frame().position_ms) * 1000
	var request := {"kind": "live_clip", "uri": video.local_uri, "mode": mode(), "session_id": video.media.session_id,
		"start_us": position, "playing": _playing()}
	var id: int = video.platform.original_capture_request(JSON.stringify(request))
	if id <= 0: tell(I18n.t("Capture is busy")); return false
	jobs[id] = {"kind": "clip", "uri": video.local_uri}
	recording = {"id": id, "uri": video.local_uri, "start_us": position, "end_us": position}
	_clock_after = 0
	return true

func stop() -> bool:
	if recording.is_empty(): return false
	_update_end()
	var request := recording.duplicate()
	recording.clear()
	video.platform.original_capture_stop(int(request.id), int(request.end_us))
	return true

func toggle() -> bool:
	return stop() if not recording.is_empty() else start()

func _update_end() -> void:
	if recording.is_empty() or recording.uri != video.local_uri: return
	var current := frame()
	if not current.is_empty(): recording.end_us = maxi(int(recording.end_us), int(current.position_ms) * 1000)

func tick() -> void:
	var now := Time.get_ticks_msec()
	var advancing := _playing()
	if not recording.is_empty():
		_update_end()
		if now >= _clock_after or advancing != _clock_playing:
			_clock_after = now + 100
			_clock_playing = advancing
			video.platform.original_capture_clock(int(recording.id), int(recording.end_us), advancing)
		if recording.uri != video.local_uri or video.media.state in ["closed", "failed", "ended"]: stop()
	elif not jobs.is_empty() and now >= _clock_after:
		_clock_after = now + 100
		for id in jobs:
			if jobs[id].kind == "clip": video.platform.original_capture_clock(int(id), 0, advancing)
	if notice_until > 0 and now >= notice_until: notice = ""; notice_until = 0
	if jobs.is_empty() or now < _poll_after: return
	_poll_after = now + 150
	for id in jobs.keys():
		var result: Variant = JSON.parse_string(video.platform.original_capture_status(int(id)))
		if result is Dictionary and result.get("state", "") == "recording" and int(recording.get("id", 0)) == int(id):
			if result.has("start_us"): recording.start_us = int(result.start_us)
		if not result is Dictionary or result.get("state", "saving") not in ["saved", "error"]: continue
		if int(recording.get("id", 0)) == int(id): recording.clear()
		jobs.erase(id)
		if result.state == "saved":
			tell(I18n.t("Saved to %s") % str(result.get("directory", "")) + "\n" + I18n.t("Find it in Library → Local") + " · " + I18n.t("Images" if result.get("kind", "screenshot") == "screenshot" else "Video"))
			saved.emit(result)
		else: tell(I18n.t(str(result.get("error", "Capture save failed"))))

## The persistent HUD needs only local state, never native capability or frame-readiness queries.
func status() -> Dictionary:
	var active := not recording.is_empty()
	return {"recording": active, "paused": active and not _playing(),
		"duration_ms": maxi(0, (int(recording.get("end_us", 0)) - int(recording.get("start_us", 0))) / 1000),
		"picture_busy": busy("screenshot"), "clip_busy": busy("clip"), "notice": notice}

func snapshot() -> Dictionary:
	var value := status()
	value["available"] = supported() and video.geometry in [1, 2, 3] and not video.local_uri.is_empty() and not video.packed_file
	value["ready"] = ready()
	return value
