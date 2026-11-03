extends SceneTree
const Reports := preload("res://scripts/media_server_playback.gd")
const Video := preload("res://scripts/mpv_video_display.gd")
var checks := 0
var failures: Array[String] = []

class Platform extends RefCounted:
	var calls: Array = []
	func media_server_playback(raw: String) -> void: calls.append(JSON.parse_string(raw))

class Preview extends RefCounted:
	var running := false
	func active() -> bool: return running

class VideoState extends Node:
	var local_uri := "medialib://server/scene/film?source=version-b"
	var platform := Platform.new()
	var media := preload("res://scripts/mpv_media_state.gd").new()
	var control := preload("res://scripts/playback_control.gd").new()
	var vr_passthrough := Preview.new()
	var _waiting_first := false
	var _recover := false
	var _pending_revision := {}
	var requested_play := true
	var audio_muted := false
	var audio_volume := 75.0
	var playback_speed := 1.0
	var loop_enabled := false
	var final_frame_ready := false
	func playback_end_ready() -> bool: return final_frame_ready

func check(value: bool, message: String) -> void:
	checks += 1
	if not value: failures.append(message)

func _initialize() -> void: call_deferred("_run")
func _run() -> void:
	var video := VideoState.new()
	var reports := Reports.new()
	var count := 0
	reports.begin(video.local_uri)
	var token: String = reports.token
	video.media.begin(7); video.media.generation = 3; video.media.state = "playing"
	video.media.playback = {"details": {"paused": "no", "seekable": "yes", "audio_track_id": "9",
		"audio_tracks": [{"id": 9, "stream_index": 3}], "subtitle": {"track_id": "no"}}}
	reports.poll(video, true)
	check(video.platform.calls.is_empty(), "opening without a presented source frame never reports playback")
	video.media.last_pair = {"session_id": 7, "generation": 3, "source_pts_verified": true, "pts_us": 120000000}
	reports.poll(video, true)
	check(video.platform.calls.size() == 1 and video.platform.calls.back().position_ms == 120000, "uses confirmed source PTS in milliseconds")
	check(video.platform.calls.back().audio == 3 and video.platform.calls.back().subtitle == -1, "MPV track ID maps through FFmpeg stream_index and disabled subtitle is explicit")
	check(video.platform.calls.back().volume == 75 and video.platform.calls.back().can_seek, "includes actual playback controls")
	video.control.seek_absolute(900000); reports.seek_serial += 1
	reports.poll(video, true)
	check(video.platform.calls.size() == 1, "queued seek target is never uploaded")
	video.control.take_pending(); reports.poll(video, true)
	check(video.platform.calls.size() == 1, "in-flight seek waits for source confirmation")
	video.control.first_frame(119000); video.media.last_pair.pts_us = 119000000
	reports.poll(video, true)
	check(video.platform.calls.back().position_ms == 119000 and video.platform.calls.back().seek == 1, "confirmed keyframe landing wins over the requested target")
	reports.finish(video.platform, true); reports.begin(video.local_uri)
	check(reports.token == token and video.platform.calls.back().action == "state", "internal close/open retains the viewing token without a Stop")
	video.media.state = "failed"; video._recover = true; count = video.platform.calls.size()
	reports.poll(video, true)
	check(reports.token == token and video.platform.calls.size() == count, "GL recovery keeps the same viewing session")
	video.media.state = "playing"; video._recover = false
	video.media.generation = 4; reports.poll(video, true)
	check(video.platform.calls.back().position_ms == 119000, "old generation cannot replace current progress")
	video.media.last_pair.generation = 4
	video.vr_passthrough.running = true; reports.poll(video, true)
	check(video.platform.calls.back().paused and video.platform.calls.back().position_ms == 119000, "preview suspends the real viewing clock")
	count = video.platform.calls.size(); reports.poll(video, true)
	check(video.platform.calls.size() == count, "preview never sends repeated fake clocks")
	video.vr_passthrough.running = false; video.requested_play = true; reports.poll(video, true)
	check(not video.platform.calls.back().paused, "returning from preview resumes the same viewing token")
	video.media.playback.details.audio_tracks = [{"id": 9, "stream_index": 0, "external": true}]
	reports.poll(video, true)
	check(not video.platform.calls.back().has("audio"), "external audio index is not confused with server index zero")
	video.media.state = "ended"; reports.poll(video, true)
	check(video.platform.calls.back().action == "state", "decoder EOF cannot stop before the final frame is presented")
	video.final_frame_ready = true; video.loop_enabled = true; reports.poll(video, true)
	check(video.platform.calls.back().action == "state", "continuous looping keeps one viewing session")
	video.loop_enabled = false; reports.poll(video, true)
	check(video.platform.calls.back().action == "stop", "end reports a single final Stop")
	count = video.platform.calls.size(); reports.poll(video, true)
	check(video.platform.calls.size() == count, "repeated ended snapshots do not create new history")
	video.media.state = "playing"; video.media.last_pair.pts_us = 0; reports.poll(video, true)
	check(reports.token != token and video.platform.calls.back().action == "state", "replay after EOF creates a fresh viewing session")
	reports.finish(video.platform)
	check(reports.token.is_empty() and video.platform.calls.back().action == "stop", "user close terminates and clears the session")
	reports.begin("file:///local.mp4"); reports.poll(video, true)
	check(reports.token.is_empty(), "local and unrelated media never report to a server")
	reports.begin(video.local_uri); video.media.state = "failed"; reports.poll(video, true)
	check(reports.token.is_empty() and video.platform.calls.back().action == "stop", "failed output ends any existing viewing session")
	check(Reports.stream_index({"audio_track_id": "auto"}, "audio") == null, "unknown automatic track is omitted")
	check(Reports.stream_index({"subtitle": {"track_id": "4"}, "subtitle_tracks": [{"id": 4, "stream_index": 6}]}, "subtitle") == 6, "embedded subtitle index maps without using MPV IDs")
	# Production node carries the same observer and its normal seek entry advances the event serial.
	var production := Video.new()
	check(production.server_playback.get_script() == Reports, "production player owns the tested observer")
	production.free(); video.free()
	print("Media server playback: %d checks, %d failures" % [checks, failures.size()])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)
