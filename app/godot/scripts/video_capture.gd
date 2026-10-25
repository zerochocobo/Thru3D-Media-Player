extends RefCounted
## Source-time selection and asynchronous exports survive transport dismissal; closing cancels loop exports.
signal saved(result: Dictionary)
const Methods := preload("res://scripts/platform_methods.gd")
const I18n := preload("res://scripts/i18n.gd")
const Mode := preload("res://scripts/capture_mode.gd")
var video: Node3D
var recording: Dictionary = {}
var jobs: Dictionary = {}
var notice := ""
var notice_until := 0
var last_result: Dictionary = {}
var _poll_after := 0
var _clock_after := 0
var _clock_playing := false
var _pip_after := 0

func _init(owner_video: Node3D) -> void: video = owner_video

func supported() -> bool:
	return Methods.supports(video.platform, "original_capture_supported") and video.platform.original_capture_supported()

func ready() -> bool:
	if video.get("cast_token"): return false
	return supported() and video.geometry in [0, 1, 2, 3] and not video.packed_file and not frame().is_empty()

func frame() -> Dictionary:
	var value: Dictionary = video.bookmark_snapshot()
	return value if not value.is_empty() and video.media.state not in ["failed", "closed"] else {}

func _playing() -> bool:
	var details: Dictionary = video.media.playback.get("details", {})
	if details.has("paused"):
		return details.get("paused", "yes") == "no" and details.get("paused_for_cache", "no") != "yes" and details.get("eof_reached", "no") != "yes"
	return video.requested_play and video.media.state == "playing"

func mode(allow_flat: bool = true) -> Dictionary:
	return Mode.clean({"version": 1, "geometry": video.geometry, "stereo_sbs": video.stereo_sbs,
		"top_bottom": video.top_bottom, "stereo_half": video.stereo_half, "swap_eyes": video.swap_eyes, "fisheye_fov": video.fisheye_fov}, allow_flat)

func loop_available() -> bool:
	return not video.get("cast_token") and supported() and not video.packed_file and not video.local_uri.is_empty() and not mode(true).is_empty()

func export_loop(segment: Dictionary) -> bool:
	if not loop_available() or busy("clip") or not recording.is_empty(): return false
	var details: Dictionary = video.media.playback.get("details", {})
	var selected := int(details.get("audio_track_id", video.audio_track_id))
	var audio := {"audio_index": -1}
	if selected != 0:
		var tracks: Array = details.get("audio_tracks", [])
		var choices: Array = tracks.filter(func(track): return int(track.get("id", 0)) == selected) if selected > 0 else tracks.slice(0, 1)
		if not choices.is_empty():
			var track: Dictionary = choices[0]
			if track.get("external", false): audio["audio_title"] = str(track.get("title", ""))
			else: audio.audio_index = int(track.get("stream_index", -1))
			if (track.get("external", false) and str(audio.get("audio_title", "")).is_empty()) or (not track.get("external", false) and int(audio.audio_index) < 0):
				tell(I18n.t("Audio track unavailable for export")); return false
		elif selected > 0:
			tell(I18n.t("Audio track unavailable for export")); return false
		else:
			audio.audio_index = -2 # Auto: let the independent reader discover the source audio.
	var metadata: Dictionary = video.get("_bookmark_metadata") if video.get("_bookmark_metadata") is Dictionary else {}
	var source_name := str(metadata.get("basename", ""))
	if source_name.is_empty(): source_name = str(video.get("display_name") if video.get("display_name") else "")
	if source_name.is_empty(): source_name = video.local_uri.get_file().get_slice("?", 0).uri_decode()
	if source_name.is_empty(): source_name = "video"
	var request := {"kind": "clip", "uri": video.local_uri, "mode": mode(true), "loop_id": str(segment.id),
		"source_name": source_name, "start_us": int(segment.a_ms) * 1000, "end_us": int(segment.b_ms) * 1000}
	request.merge(audio)
	return _request(request)

func busy(kind: String) -> bool:
	return jobs.values().any(func(job): return job.kind == kind)

func cancel_export(source_uri: String = "") -> bool:
	for id in jobs:
		if not jobs[id].has("loop_id") or jobs[id].get("cancelling", false): continue
		if not source_uri.is_empty() and jobs[id].uri != source_uri: continue
		return _cancel_job(int(id))
	return false

func cancel_save() -> bool:
	for id in jobs:
		var job: Dictionary = jobs[id]
		if job.kind == "clip" and (job.has("loop_id") or job.get("saving", false)) and not job.get("cancelling", false):
			return _cancel_job(int(id))
	return false

func _cancel_job(id: int) -> bool:
	if not Methods.supports(video.platform, "original_capture_cancel"): return false
	if not video.platform.original_capture_cancel(id): return false
	jobs[id]["cancelling"] = true
	return true

func tell(message: String, lifetime_ms: int = 3500) -> void:
	notice = message; notice_until = Time.get_ticks_msec() + lifetime_ms

func _request(request: Dictionary) -> bool:
	var id: int = video.platform.original_capture_request(JSON.stringify(request))
	if id <= 0: tell(I18n.t("Capture is busy")); return false
	jobs[id] = request.duplicate(true)
	last_result.clear()
	if request.has("loop_id"): jobs[id]["progress"] = 0
	return true

func screenshot() -> bool:
	if not ready() or busy("screenshot"): return false
	var request := {"kind": "screenshot", "uri": video.local_uri, "mode": mode(),
		"position_us": int(frame().position_ms) * 1000, "exact_frame": not video.requested_play}
	if _has_pip():
		var layout: Dictionary = preload("res://scripts/pip_screenshot.gd").snapshot(video)
		if layout.is_empty(): tell(I18n.t("Picture in picture capture unavailable")); return false
		request["pip"] = layout
	return _request(request)

func start() -> bool:
	if not recording.is_empty() or busy("clip") or not ready(): return false
	if not is_equal_approx(video.playback_speed, 1.0):
		tell(I18n.t("Recording requires 1× playback")); return false
	if not Methods.supports(video.platform, "original_capture_stop") or not Methods.supports(video.platform, "original_capture_clock"): return false
	var position := int(frame().position_ms) * 1000
	var request := {"kind": "live_clip", "uri": video.local_uri, "mode": mode(), "session_id": video.media.session_id,
		"start_us": position, "playing": _playing()}
	var with_pip: bool = _has_pip()
	if with_pip:
		if not Methods.supports(video.platform, "original_capture_pip"):
			tell(I18n.t("Picture in picture recording unavailable")); return false
		var layout: Dictionary = preload("res://scripts/pip_screenshot.gd").snapshot(video)
		if layout.is_empty(): tell(I18n.t("Picture in picture capture unavailable")); return false
		request["pip"] = layout
	var id: int = video.platform.original_capture_request(JSON.stringify(request))
	if id <= 0: tell(I18n.t("Capture is busy")); return false
	jobs[id] = {"kind": "clip", "uri": video.local_uri, "live": true}
	last_result.clear()
	recording = {"id": id, "uri": video.local_uri, "start_us": position, "end_us": position, "pip": with_pip, "mode": mode()}
	_clock_after = 0
	_pip_after = 0
	return true

func stop() -> bool:
	if recording.is_empty(): return false
	_update_end()
	var request := recording.duplicate()
	recording.clear()
	jobs[int(request.id)]["saving"] = true
	jobs[int(request.id)]["progress"] = 0
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
		# Layout changes cannot share the same portable projection metadata.
		if recording.uri != video.local_uri or recording.mode != mode() or video.media.state in ["closed", "failed", "ended"]:
			stop()
		else:
			_sample_pip(now)
	if not recording.is_empty():
		if now >= _clock_after or advancing != _clock_playing:
			_clock_after = now + 100
			_clock_playing = advancing
			video.platform.original_capture_clock(int(recording.id), int(recording.end_us), advancing)
	elif not jobs.is_empty() and now >= _clock_after:
		_clock_after = now + 100
		for id in jobs:
			if jobs[id].kind == "clip" and not jobs[id].has("loop_id"): video.platform.original_capture_clock(int(id), 0, advancing)
	if notice_until > 0 and now >= notice_until: notice = ""; notice_until = 0
	if jobs.is_empty() or now < _poll_after: return
	_poll_after = now + 150
	for id in jobs.keys():
		var result: Variant = JSON.parse_string(video.platform.original_capture_status(int(id)))
		if result is Dictionary and result.get("state", "") == "recording" and int(recording.get("id", 0)) == int(id):
			if result.has("start_us"): recording.start_us = int(result.start_us)
		if not result is Dictionary: continue
		if result.get("state", "") == "saving" and jobs[id].get("live", false):
			jobs[id]["saving"] = true
			if int(recording.get("id", 0)) == int(id): recording.clear()
		if result.has("progress") and (jobs[id].has("loop_id") or jobs[id].get("saving", false)):
			jobs[id].progress = maxi(int(jobs[id].get("progress", 0)), clampi(int(result.progress), 0, 99))
		if result.get("state", "saving") not in ["saved", "exists", "error", "cancelled"]: continue
		var loop_export: bool = jobs[id].has("loop_id")
		last_result = result.duplicate(true)
		if int(recording.get("id", 0)) == int(id): recording.clear()
		jobs.erase(id)
		if result.state in ["saved", "exists"]:
			if loop_export:
				tell((I18n.t("Already saved") if result.state == "exists" else I18n.t("Clip saved")) + "\n" + str(result.get("directory", "")) + "\n" + str(result.get("name", "")), 10000)
			else:
				var destination := I18n.t("Saved to %s") % str(result.get("directory", ""))
				var filename := str(result.get("name", ""))
				if not filename.is_empty(): destination += "\n" + filename
				tell(destination + "\n" + I18n.t("Find it in Library → Local") + " · " + I18n.t("Images" if result.get("kind", "screenshot") == "screenshot" else "Video"), 10000)
			if result.state == "saved": saved.emit(result)
		elif result.state == "cancelled": tell(I18n.t("Clip export cancelled"))
		else: tell(I18n.t(str(result.get("error", "Capture save failed"))))

func _has_pip() -> bool:
	return video.geometry != 0 and video.get("pip") != null and video.pip.active()

func _sample_pip(now: int) -> void:
	if video.geometry == 0: return
	if now < _pip_after: return
	_pip_after = now + 33
	var active: bool = _has_pip()
	if not active and not recording.get("pip", false): return
	if not Methods.supports(video.platform, "original_capture_pip"):
		stop(); tell(I18n.t("Picture in picture recording unavailable")); return
	recording.pip = true
	var layout: Dictionary = preload("res://scripts/pip_screenshot.gd").snapshot(video) if active else {"version": 1, "windows": []}
	# An invalid sample poisons the job; never publish a source-only substitute.
	video.platform.original_capture_pip(int(recording.id), int(recording.end_us), JSON.stringify(layout))

## The persistent HUD needs only local state, never native capability or frame-readiness queries.
func status() -> Dictionary:
	var active := not recording.is_empty()
	var exports := {}; var progress := -1; var cancelling := false
	for job in jobs.values():
		if job.has("loop_id") or job.get("saving", false):
			progress = int(job.get("progress", 0))
			if job.has("loop_id"): exports[job.loop_id] = progress
			cancelling = bool(job.get("cancelling", false))
	return {"recording": active, "paused": active and not _playing(),
		"duration_ms": maxi(0, (int(recording.get("end_us", 0)) - int(recording.get("start_us", 0))) / 1000),
		"picture_busy": busy("screenshot"), "clip_busy": busy("clip"), "notice": notice, "loop_exports": exports, "export_progress": progress,
		"export_cancellable": progress >= 0, "export_cancelling": cancelling}

func snapshot() -> Dictionary:
	var value := status()
	value["pip"] = bool(recording.get("pip", false)) or (_has_pip())
	if video.get("cast_token"):
		value["available"] = false; value["ready"] = false; return value
	value["available"] = supported() and video.geometry in [0, 1, 2, 3] and not video.local_uri.is_empty() and not video.packed_file
	value["ready"] = ready()
	value["loop_available"] = loop_available()
	return value
