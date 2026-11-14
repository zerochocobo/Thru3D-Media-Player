extends SceneTree
const Naming := preload("res://scripts/media_naming.gd")
const Video := preload("res://scripts/mpv_video_display.gd")
const Memory := preload("res://scripts/file_mode_memory.gd")
const Recent := preload("res://scripts/recent_files.gd")
const Main := preload("res://scripts/main.gd")
var failures: Array[String] = []
var checks := 0
var serial := 0

class Host extends "res://tests/test_file_mode_memory.gd".Host:
	var rates: Array = []
	var revisions: Array[bool] = []
	var projection := {}
	func set_mpv_speed(id: int, rate: float) -> bool:
		rates.append([id, rate])
		return true
	func web_video_projection(_uri: String) -> String:
		return JSON.stringify(projection)
	func revise_mpv_video(id: int, stereo: bool, alpha: bool, profile: String, position: int, depth: bool = false, top_bottom: bool = false, exact: bool = false) -> int:
		revisions.append(depth)
		return super.revise_mpv_video(id, stereo, alpha, profile, position, depth, top_bottom, exact)

func check(value: bool, message: String) -> void:
	checks += 1
	if not value: failures.append(message)

func complete(video: Node3D, width: int = 8192, height: int = 4096, format: Dictionary = {}) -> void:
	video.media.format = {"width": width, "height": height}
	video.media.format.merge(format, true)
	video.media.frame_counter = 1
	video._complete_layout()
	video._remember_mode(false)

func open_external(video: Node3D, title: String = "Video", width: int = 8192, height: int = 4096, format: Dictionary = {}) -> void:
	serial += 1
	check(video.open_local("externalvideo://fixture-%d/video" % serial, title, 1234, true, false, "", {"external_temporary": true}), "Fresh external delivery opens")
	complete(video, width, height, format)

func current(video: Node3D) -> Dictionary:
	var mode: Dictionary = video.current_lock()
	mode.swap_eyes = video.swap_eyes
	return video.LastMode.clean(mode)

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	var local := Naming.complete({}, 3840, 1920)
	var external := Naming.complete({"external_unknown": true}, 3840, 1920)
	check(local.geometry == 1 and external == local and external.stereo, "Unknown external 2:1 videos infer VR180 SBS just like local videos")
	for size in [Vector2i(8192, 4096), Vector2i(7680, 3840), Vector2i(3840, 1920)]:
		var inferred := Naming.complete({"external_unknown": true}, size.x, size.y)
		check(inferred.geometry == 1 and inferred.stereo and not inferred.top_bottom, "External 2:1 sizes infer VR180 SBS: %s" % size)
	for size in [Vector2i(1920, 1080), Vector2i(4096, 4096), Vector2i(8191, 4096)]:
		var inferred := Naming.complete({"external_unknown": true}, size.x, size.y)
		check(inferred.geometry == 0 and not inferred.stereo, "Other unmarked external shapes retain their fallback: %s" % size)
	var named := Naming.from_name("sample_180_SBS.mp4")
	named.external_unknown = true
	check(Naming.complete(named, 3840, 1920).geometry == local.geometry, "Explicit VR180 names survive external handoff")
	check(Naming.complete({"external_unknown": true}, 3840, 2160, {"stereo_mode": "sbsl"}).stereo, "Container SBS survives external handoff")
	check(Memory.key_for("externalvideo://fixture/video").is_empty(), "Temporary locators cannot create persistent settings")
	var recent := Recent.new("user://external-playback-test")
	check(not recent.opened("externalvideo://fixture/video", "Video", false) and recent.list_recent().is_empty(), "Temporary playback cannot enter recent history")
	var bridge := Host.new()
	var video := Video.new()
	root.add_child(video)
	video.set_process(false)
	video.platform = bridge
	check(video.open_local("externalvideo://fixture/video", "Movie", 1234, true, false, "", {"external_temporary": true}), "External request reaches the real playback dispatch")
	check(int(bridge.calls.back()[1]) == 1234 and video._layout_pending.get("external_unknown", false), "Start position and external source identity reach the player")
	complete(video, 3840, 1920)
	check(video.geometry == 1 and video.stereo_sbs, "External 2:1 source resolves to VR180 SBS after the first frame")
	check_preferences(video, bridge)
	video.free()
	for failure in failures: push_error(failure)
	print("External playback checks: %d, failures: %d" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)

func check_preferences(video: Node3D, bridge: Host) -> void:
	var output := ProjectSettings.globalize_path("res://../../build/output/external-playback/" + str(Time.get_ticks_usec()))
	DirAccess.make_dir_recursive_absolute(output)
	var main := Main.new()
	main.video = video; main.settings_path = output.path_join("settings.cfg")
	video.mode_memory = Memory.new(output.path_join("modes"))
	video.last_mode_changed.connect(main._on_last_video_mode_changed)
	video.reuse_last_mode_changed.connect(main._on_reuse_last_video_mode_changed)
	video.mode_lock_changed.connect(main._on_mode_lock_changed.bind("video"))
	main._on_player_setting("reuse_last_mode", true)
	for projection in range(4):
		for layout in range(5):
			video.set_projection(projection); video.set_stereo_layout(layout)
			video.set_fisheye_fov(220)
			if video.stereo_sbs and not video.swap_eyes: video.toggle_eye_order()
			var expected := current(video)
			var sequence: int = video.mode_memory.sequence
			serial += 1
			check(video.open_local("externalvideo://mode-%d/video" % serial, "Video", 0, true, false, "", {"external_temporary": true}), "External mode matrix opens")
			check(current(video) == expected, "External dispatch inherits the full last layout: %d/%d" % [projection, layout])
			complete(video)
			check(current(video) == expected and video.last_mode == expected, "First frame retains the inherited layout: %d/%d" % [projection, layout])
			check(video.mode_memory.sequence == sequence and video.mode_memory.lookup(video.local_uri).is_empty(), "Global layout reuse never persists temporary file settings")
	video.set_projection(1); video.set_stereo_layout(1)
	open_external(video, "flat_2d.mp4")
	check(video.geometry == 0 and not video.stereo_sbs, "Explicit flat filename wins over inherited VR")
	open_external(video, "clip_360_TB.mp4", 4096, 4096)
	check(video.geometry == 3 and video.stereo_sbs and video.top_bottom, "Explicit external VR360 filename wins")
	open_external(video, "clip_180.mp4")
	check(video.geometry == 1 and video.stereo_sbs and not video.top_bottom, "Partial external filename uses normal completion")
	open_external(video, "Video", 4096, 4096, {"stereo_mode": "ab2r"})
	check(video.geometry == 0 and video.stereo_sbs and video.top_bottom and video.swap_eyes, "Container layout wins without re-enabling external square-frame guessing")
	video.set_projection(2); video.set_fisheye_fov(220)
	open_external(video, "Video", 8192, 4096, {"stereo_mode": "sbs2l"})
	check(video.geometry == 0 and video.stereo_sbs and not video.top_bottom and video.fisheye_fov == 180, "External container SBS wins over last fisheye")
	video.set_projection(1); video.set_stereo_layout(1)
	var before_spatial: Dictionary = video.last_mode.duplicate()
	open_external(video, "Video", 1920, 1080, {"spatial_video": true})
	check(video.geometry == 0 and video.stereo_sbs and video.last_mode == before_spatial, "External spatial video remains native without replacing general defaults")
	video.close_video()
	bridge.projection = {"version": 1, "kind": "equirectangular", "geometry": 3, "stereo_mode": 0}
	open_external(video)
	check(video.geometry == 3 and not video.stereo_sbs, "Stream projection wins over the external fallback")
	bridge.projection = {}
	video.set_reuse_last_mode(false)
	video.set_projection(1); video.set_stereo_layout(1); video.toggle_mode_lock()
	var locked: Dictionary = video.mode_lock.duplicate()
	open_external(video)
	check(video.geometry == 1 and video.stereo_sbs and video.mode_lock == locked, "Explicit fixed mode also applies to unknown external videos")
	open_external(video, "flat_2d.mp4")
	check(video.geometry == 0 and not video.stereo_sbs and video.mode_lock == locked, "External filename overrides the fixed default without removing it")
	video._unlock_mode()
	main._on_setting_changed("video_auto_3d", true)
	video.preferred_playback_speed = 1.65
	main._save_playback_adjustments()
	var revision_count := bridge.revisions.size()
	open_external(video, "Video", 1920, 1080)
	check(not bridge.depths.back(), "Unknown external video waits for actual format before requesting conversion")
	check(video.depth_requested and video.auto_depth and bridge.revisions.size() > revision_count and bridge.revisions.back(), "Saved default 2D to 3D reaches native revision after flat format is confirmed")
	check(video.playback_speed == 1.65 and bridge.rates.back() == [video.media.session_id, 1.65], "External playback applies the global playback speed")
	video._reopen_at(2000, false)
	check(video.depth_requested and video.playback_speed == 1.65, "Internal external-source reopen preserves conversion and speed")
	open_external(video, "Video", 4096, 4096, {"stereo_mode": "ab2l"})
	check(video.stereo_sbs and video.top_bottom and not video.depth_requested and not bridge.depths.back(), "Native external stereo never starts default flat conversion")
	main._on_setting_changed("video_auto_3d", false)
	open_external(video, "Video", 1920, 1080)
	check(not video.depth_requested and not bridge.depths.back(), "Disabled global conversion remains off for the next external video")
	check(video.set_depth(true), "Manual conversion can be enabled for an external video")
	open_external(video, "Video", 1920, 1080)
	check(not video.depth_requested and video.mode_memory.entries.is_empty(), "Manual per-file conversion does not persist under a fresh temporary locator")
	main._on_setting_changed("video_auto_3d", true)
	video.set_projection(1); video.set_stereo_layout(1)
	video.set_reuse_last_mode(true)
	open_external(video)
	check(video.geometry == 1 and video.stereo_sbs and not video.depth_requested and not bridge.depths.back(), "Inherited external VR never starts flat 2D to 3D conversion")
	video.set_projection(0); video.set_stereo_layout(0)
	open_external(video)
	check(video.geometry == 0 and not video.stereo_sbs and video.depth_requested, "Changing external VR back to flat also updates the next delivery and its conversion default")
	var restarted := Main.new(); var fresh := Video.new()
	restarted.settings_path = main.settings_path; restarted.video = fresh
	check(restarted.settings.load(main.settings_path) == OK, "Fresh application reads saved global preferences")
	fresh.default_auto_depth = fresh.Auto3D.load_enabled(restarted.settings)
	fresh.load_last_mode_preferences(restarted.settings)
	restarted._restore_playback_speed()
	root.add_child(fresh); fresh.set_process(false); fresh.platform = bridge
	open_external(fresh)
	check(fresh.reuse_last_mode and fresh.geometry == 0 and not fresh.stereo_sbs and fresh.depth_requested and fresh.playback_speed == 1.65,
		"Restart restores mode reuse, automatic conversion and speed for a new external locator")
	fresh.free(); restarted.free()
	main.free()
