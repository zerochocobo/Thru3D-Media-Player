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

func _init(owner_video: Node3D) -> void: video = owner_video

func supported() -> bool:
	return Methods.supports(video.platform, "original_capture_supported") and video.platform.original_capture_supported()

func ready() -> bool:
	return supported() and video.geometry in [1, 2, 3] and not video.packed_file and not frame().is_empty()

func frame() -> Dictionary:
	var value: Dictionary = video.bookmark_snapshot()
	return value if not value.is_empty() and video.media.state not in ["failed", "closed"] else {}

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
	var details: Dictionary = video.media.playback.get("details", {})
	var selected: int = video.audio_track_id if video.audio_track_id >= 0 else int(details.get("audio_track_id", 0))
	var audio_index := -1
	var audio_title := ""
	var found_audio: bool = selected == 0 and (video.audio_track_id == 0 or details.get("audio_tracks", []).is_empty())
	for track in details.get("audio_tracks", []):
		if int(track.get("id", 0)) != selected: continue
		found_audio = true
		if track.get("external", false):
			audio_title = str(track.get("title", ""))
			if audio_title.is_empty(): tell(I18n.t("Audio track unavailable for export")); return false
			break
		audio_index = int(track.get("stream_index", -1))
		if audio_index < 0: tell(I18n.t("Audio track unavailable for export")); return false
	if not found_audio:
		tell(I18n.t("Audio track unavailable for export")); return false
	var position := int(frame().position_ms) * 1000
	recording = {"kind": "clip", "uri": video.local_uri, "mode": mode(), "audio_index": audio_index, "audio_title": audio_title,
		"start_us": position, "end_us": position}
	return true

func stop() -> bool:
	if recording.is_empty(): return false
	_update_end()
	var request := recording.duplicate(true)
	recording.clear()
	if int(request.end_us) <= int(request.start_us): tell(I18n.t("Recording is empty")); return true
	_request(request)
	return true

func toggle() -> bool:
	return stop() if not recording.is_empty() else start()

func _update_end() -> void:
	if recording.is_empty() or recording.uri != video.local_uri: return
	var current := frame()
	if not current.is_empty(): recording.end_us = maxi(int(recording.end_us), int(current.position_ms) * 1000)

func tick() -> void:
	if not recording.is_empty():
		_update_end()
		if recording.uri != video.local_uri or video.media.state in ["closed", "failed", "ended"]: stop()
	var now := Time.get_ticks_msec()
	if notice_until > 0 and now >= notice_until: notice = ""; notice_until = 0
	if jobs.is_empty() or now < _poll_after: return
	_poll_after = now + 150
	for id in jobs.keys():
		var result: Variant = JSON.parse_string(video.platform.original_capture_status(int(id)))
		if not result is Dictionary or result.get("state", "saving") not in ["saved", "error"]: continue
		jobs.erase(id)
		if result.state == "saved":
			tell(I18n.t("Saved to %s") % str(result.get("directory", "")) + "\n" + I18n.t("Find it in Library → Local") + " · " + I18n.t("Images" if result.get("kind", "screenshot") == "screenshot" else "Video"))
			saved.emit(result)
		else: tell(I18n.t(str(result.get("error", "Capture save failed"))))

func snapshot() -> Dictionary:
	var active := not recording.is_empty()
	return {"available": supported() and video.geometry in [1, 2, 3] and not video.local_uri.is_empty() and not video.packed_file, "ready": ready(),
		"recording": active, "paused": active and (not video.requested_play or video.media.state != "playing"),
		"duration_ms": maxi(0, (int(recording.get("end_us", 0)) - int(recording.get("start_us", 0))) / 1000),
		"picture_busy": busy("screenshot"), "clip_busy": busy("clip"), "notice": notice}
