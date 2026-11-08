extends SceneTree
const Video := preload("res://scripts/mpv_video_display.gd")
const Fixture := preload("res://tests/test_mpv_seek_hold.gd")
var checks := 0
var failures: Array[String] = []

func check(value: bool, message: String) -> void:
	checks += 1
	if not value: failures.append(message)

func report(id: int, generation: int = 1) -> String:
	return JSON.stringify({"session_id": id, "logical_session_id": 99, "generation": generation,
		"source_epoch_change": {"previous": 1, "next": 2}})

func _initialize() -> void:
	var bridge := Fixture.BridgeProbe.new()
	var video := Video.new()
	video.platform = bridge
	video.panel = MeshInstance3D.new()
	video.material = ShaderMaterial.new()
	video._binding = Fixture.BindingProbe.new()
	video.media.begin(7); video.media.logical_session_id = 99; video.media.generation = 1
	video.media.state = "playing"; video.requested_play = true; video.depth_requested = true
	video.control.observe(5480, 2656920)
	video.mode_transition.stage = "preparing"; video._waiting_first = true
	video._on_state(7, report(7))
	check(bridge.revisions == [[7, -1]], "Spontaneous source reset revises processing without seeking or reopening media")
	check(video.media.session_id == 8 and video._waiting_first and video.media.error.is_empty(), "New frames require the new decoder scope instead of failing playback")
	check(video.requested_play and video.depth_requested and video.control.observed_position_ms == 5480, "Playing intent, 3D choice and timeline survive the processing reset")
	video._on_state(7, report(7))
	check(bridge.revisions.size() == 1, "A retired decoder cannot restart the current generation")
	video.media.logical_session_id = 99; video.media.generation = 2
	video._on_state(8, report(8, 1))
	check(bridge.revisions.size() == 1, "An old logical generation cannot reset the current decoder")
	video._on_state(8, JSON.stringify({"source_epoch_change": {"previous": 2, "next": 2}}))
	check(bridge.revisions.size() == 1, "Malformed or nonadvancing epochs cannot trigger a reset")
	video._pixel_busy = true
	video._request_revision(17000)
	video._on_state(8, report(8, 2))
	check(video._pending_revision.position_ms == 17000 and video._pending_revision.source_reset,
		"A reset preserves a newer user seek while an independent capture still owns the frame")
	check(bridge.revisions.size() == 1, "Pinned captures are not invalidated before they release ownership")
	video._pixel_busy = false
	video._try_revision()
	check(bridge.revisions.back() == [8, 17000] and video.media.session_id == 9, "The preserved seek and source reset become one processing revision")
	video.requested_play = false
	video._on_state(9, report(9, 3))
	check(not video.requested_play and video.media.session_id == 10, "A paused programme stays paused across a spontaneous reset")
	video.mode_transition.stage = ""; video._waiting_first = false
	video.media.state = "paused"; video.media.logical_session_id = 99; video.media.generation = 4
	video._binding.bind(video.material, {"session_id": 10, "slot_token": 77, "pts_us": 5480000})
	video._request_revision(23000)
	var freeze: int = video._freeze_request
	video._on_state(10, report(10, 4))
	video._on_frozen_pair(10, JSON.stringify({"request_id": freeze, "state": "failed", "error": "allocation failed"}))
	check(bridge.revisions.back() == [10, -1] and video.media.session_id == 11,
		"A failed seek snapshot still performs the mandatory source reset without retrying the rejected seek")
	check(not video.requested_play and video._waiting_first and video._pending_revision.is_empty(),
		"Capture failure cannot strand a paused video behind the retired native source gate")
	video.platform = null
	video.panel.free(); video.free()
	print("MPV source epoch: %d checks, %d failures" % [checks, failures.size()])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)
