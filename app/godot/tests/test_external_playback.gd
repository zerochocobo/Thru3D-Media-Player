extends SceneTree
const Naming := preload("res://scripts/media_naming.gd")
const Video := preload("res://scripts/mpv_video_display.gd")
const Memory := preload("res://scripts/file_mode_memory.gd")
const Recent := preload("res://scripts/recent_files.gd")
var failures: Array[String] = []

func check(value: bool, message: String) -> void:
	if not value: failures.append(message)

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	var local := Naming.complete({}, 3840, 1920)
	var external := Naming.complete({"external_unknown": true}, 3840, 1920)
	check(local.geometry != 0 and external.geometry == 0 and not external.stereo, "Unknown streams stay flat while stable local inference is preserved")
	var named := Naming.from_name("sample_180_SBS.mp4")
	named.external_unknown = true
	check(Naming.complete(named, 3840, 1920).geometry == local.geometry, "Explicit VR180 names survive external handoff")
	check(Naming.complete({"external_unknown": true}, 3840, 2160, {"stereo_mode": "sbsl"}).stereo, "Container SBS survives external handoff")
	check(Memory.key_for("externalvideo://fixture/video").is_empty(), "Temporary locators cannot create persistent settings")
	var recent := Recent.new("user://external-playback-test")
	check(not recent.opened("externalvideo://fixture/video", "Video", false) and recent.list_recent().is_empty(), "Temporary playback cannot enter recent history")
	var bridge := preload("res://tests/test_file_mode_memory.gd").Host.new()
	var video := Video.new()
	root.add_child(video)
	video.platform = bridge
	check(video.open_local("externalvideo://fixture/video", "Movie", 1234, true, false, "", {"external_temporary": true}), "External request reaches the real playback dispatch")
	check(int(bridge.calls.back()[1]) == 1234 and video._layout_pending.get("external_unknown", false), "Start position and conservative inference reach the player")
	video.media.format = {"width": 3840, "height": 1920}
	video._complete_source_layout()
	check(video.geometry == 0 and not video.stereo_sbs, "No transient 2:1 to VR180 switch after the first frame")
	video.free()
	for failure in failures: push_error(failure)
	print("External playback checks: 9, failures: %d" % failures.size())
	quit(0 if failures.is_empty() else 1)
