extends SceneTree

const Memory := preload("res://scripts/file_mode_memory.gd")
const Video := preload("res://scripts/mpv_video_display.gd")
var failures: Array[String] = []
var checks := 0
var test_path := ""

class Interrupted extends "res://scripts/file_mode_memory.gd":
	func _commit(_staged: String, target: String) -> Error:
		# Model the real Windows rename gap: old target removed, replacement fails.
		if FileAccess.file_exists(target):
			DirAccess.remove_absolute(target)
		return ERR_CANT_CREATE

class Host extends RefCounted:
	var calls: Array = []
	var depths: Array[bool] = []
	var next_id := 7
	func mpv_supported() -> bool:
		return true
	func open_mpv_video(uri: String, start: int, stereo: bool, profile: String, alpha: bool, vulkan: bool, _depth: bool = false, _top_bottom: bool = false, _exact: bool = false) -> int:
		calls.append([uri, start, stereo, profile, alpha, vulkan])
		depths.append(_depth)
		return next_id
	func set_mpv_playing(_id: int, _playing: bool) -> void:
		pass
	func close_mpv_video(_id: int) -> void:
		pass
	func revise_mpv_video(_id: int, _stereo: bool, _alpha: bool, _profile: String, _position: int, _depth: bool = false, _top_bottom: bool = false, _exact: bool = false) -> int:
		return 0

func check(value: bool, message: String) -> void:
	checks += 1
	if not value:
		failures.append(message)

func write(path: String, data: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(data)
	file.close()

func read_again() -> RefCounted:
	var fresh := Memory.new(test_path)
	fresh.load_saved()
	return fresh

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	test_path = ProjectSettings.globalize_path("res://../../build/output/mode-memory-host/" + str(Time.get_ticks_usec()))
	DirAccess.make_dir_recursive_absolute(test_path)
	var uri := "content://local.documents/document/字幕%20VideoA"
	var mode := {"geometry": 1, "stereo_sbs": true, "swap_eyes": true, "alpha_requested": true, "profile": "512x288"}
	var memory := Memory.new(test_path)
	memory.load_saved()
	check(memory.sequence == 0 and memory.lookup(uri).is_empty(), "Missing preferences start safely")
	check(Memory.key_for(uri) != Memory.key_for(uri.to_lower()), "Opaque content URI retains case-sensitive identity")
	check(Memory.key_for("http://127.0.0.1:4242/t/v.mp4").is_empty() and Memory.key_for("").is_empty() and Memory.key_for("ftp://x/v").is_empty(),
		"Per-run loopback proxy and unknown schemes are not persisted")
	check(not Memory.key_for("smb://server-id/share/v.mp4").is_empty() and not Memory.key_for("http://192.168.1.5/1.mp4").is_empty(),
		"Stable SMB and DLNA library URIs keep per-file modes")
	check(not Memory.key_for("cloud://mount-id/中文%20VR.mp4").is_empty(), "Cloud mount identity survives proxy URL changes")
	check(not memory.remember(uri, {}) and not memory.remember("http://127.0.0.1:4242/t/v.mp4", mode), "Invalid modes/proxy source cannot enter memory")
	for mutation in [{"geometry": 4}, {"geometry": 0.5}, {"geometry": NAN}, {"stereo_sbs": "true"}, {"profile": "wrong"}, {"depth_requested": "true"}]:
		var invalid := mode.duplicate(true)
		invalid.merge(mutation, true)
		check(not memory.remember(uri, invalid), "Reject invalid saved mode " + str(mutation))
	check(memory.remember(uri, mode) and memory.save(), "Initial generation writes and commits")
	check(read_again().lookup(uri) == mode and read_again().sequence == 1, "Fresh object loads first committed mode")
	var exposed: Dictionary = memory.lookup(uri)
	exposed.geometry = 0
	check(memory.lookup(uri) == mode, "Caller cannot mutate saved settings through lookup")
	check(memory.remember(uri, mode) and memory.save() and memory.sequence == 1, "Unchanged controls avoid unnecessary writes")
	var newer := mode.duplicate(true)
	newer.geometry = 2
	check(memory.remember(uri, newer) and memory.save() and read_again().lookup(uri) == newer, "Second bank wins by validated sequence")
	var bank0 := test_path.path_join("file_modes_0.json")
	var bank1 := test_path.path_join("file_modes_1.json")
	var intact := FileAccess.get_file_as_string(bank1)
	write(bank1, '{"interrupted":')
	check(read_again().lookup(uri) == mode, "Truncated newest generation falls back to previous valid bank")
	write(bank1, intact)
	var envelope: Dictionary = JSON.parse_string(intact)
	envelope.sequence = 99
	write(bank1, JSON.stringify(envelope))
	check(read_again().lookup(uri) == mode, "Sequence tampering cannot promote an older payload")
	envelope = JSON.parse_string(intact)
	envelope.payload_json += " "
	write(bank1, JSON.stringify(envelope))
	check(read_again().lookup(uri) == mode, "Checksum rejects modified payload")
	envelope = JSON.parse_string(intact)
	envelope.schema_version = 2
	write(bank1, JSON.stringify(envelope))
	check(read_again().lookup(uri) == mode, "Unknown schema does not reinterpret settings")
	var future := read_again()
	future.remember(uri, newer)
	var future_bytes := FileAccess.get_file_as_string(bank1)
	check(future.read_only and not future.save() and FileAccess.get_file_as_string(bank1) == future_bytes,
		"A downgraded reader cannot overwrite newer configuration schema")
	write(bank1, intact)
	var broken := Interrupted.new(test_path)
	broken.load_saved()
	broken.remember(uri, mode)
	check(not broken.save() and broken.dirty and broken.sequence == 2, "Failed commit retains pending choices and old in-memory generation")
	check(not FileAccess.file_exists(bank0) and read_again().lookup(uri) == newer,
		"Real target-removal gap retains another valid generation")
	check(FileAccess.file_exists(bank0 + ".tmp") and read_again().sequence == 2, "Uncommitted staging file is never loaded")
	memory = read_again()
	check(memory.remember(uri, mode) and memory.save() and read_again().sequence == 3, "Successful retry commits after interrupted write")
	var disk := FileAccess.get_file_as_string(bank0) + FileAccess.get_file_as_string(bank1)
	check(not disk.contains(uri), "Format memory stores a hash rather than document identifiers")
	for index in 129:
		memory.remember("file:///movie_%d.mp4" % index, mode)
		check(memory.save(), "Bounded map entry must save")
	check(memory.entries.size() == 128 and memory.lookup("file:///movie_0.mp4").is_empty()
		and not memory.lookup("file:///movie_128.mp4").is_empty(), "Oldest updated mode is evicted at the fixed limit")
	check(read_again().entries.size() == 128, "Bounded map survives reload")
	# A real Video instance exercises restore before native open and live eye swap.
	var video := Video.new()
	root.add_child(video)
	video.set_process(false)
	video.mode_memory = Memory.new(test_path.path_join("integration"))
	video.mode_memory.remember(uri, newer)
	video.mode_memory.save()
	var host := Host.new()
	video.platform = host
	check(video.open_local(uri, "Selected video"), "Restored source opens")
	# Projection, stereo and eye order are restored; Alpha always starts off (player controls switch it on).
	check(host.calls.back() == [uri, 0, true, Video.AUTOMATIC_PROFILE, false, true]
		and video.geometry == 2 and video.swap_eyes and not video.alpha_requested, "Projection and eye order restore while legacy model resolution is replaced automatically")
	check(not video.alpha_enabled and not video.panel.visible, "Remembered Alpha intent cannot expose passthrough before a complete pair")
	video._waiting_first = false
	video.media.generation = 4
	check(video.toggle_eye_order() and not video.swap_eyes and video.media.session_id == 7 and video.media.generation == 4,
		"Eye order is a shader choice and preserves source/processing generation")
	var loaded := Memory.new(test_path.path_join("integration"))
	loaded.load_saved()
	check(not loaded.lookup(uri).swap_eyes, "Manual eye order persists for the exact file")
	video.stereo_sbs = false
	check(not video.toggle_eye_order(), "Mono source has no L/R swap")
	video.geometry = 0
	video.alpha_requested = false
	check(video.open_local(uri, "Calibration", 1234, false) and not host.calls.back()[4] and video.geometry == 0,
		"Explicit diagnostic open bypasses per-file settings")
	var before := video.mode_memory.sequence
	video.set_alpha(true)
	check(video.mode_memory.sequence == before, "Diagnostic controls do not rewrite user memory")
	video._remember_file = true
	video.geometry = 1
	video._reopen_after_context_loss(uri, "Recovered", 1234, true)
	check(video.geometry == 1 and video._remember_file and host.calls.back()[1] == 1234,
		"Context recovery retains unsaved live choices and memory eligibility")
	host.next_id = -1
	video.open_local(uri, "Failed open")
	before = video.mode_memory.sequence
	video.set_alpha(false)
	check(video.mode_memory.sequence == before, "Rejected source cannot overwrite its remembered settings")
	# A file without a remembered mode: explicit markers win, exact unmarked 2:1 defaults to VR180 SBS.
	host.next_id = 7
	check(video.open_local("file:///v/show_RL_180.mp4", "show_RL_180.mp4") and host.calls.back()[2] == true
		and video.geometry == 1 and video.swap_eyes and video._layout_pending == null, "Name markers reach native at open")
	check(video.open_local("file:///v/clip.mp4", "clip.mp4") and host.calls.back()[2] == false and video._layout_pending != null,
		"Unmarked name waits for the frame")
	video.media.format = {"width": 8192, "height": 4096, "pixel_aspect": 1.0, "unapplied_rotation_degrees": 0}
	video._complete_layout()
	check(video.geometry == 1 and video.stereo_sbs and not video.top_bottom and not video.stereo_half
		and video._pending_revision.get("stereo", false) and video._layout_pending == null,
		"Unmarked exact 2:1 requests full SBS processing in VR180")
	video._complete_layout()
	check(video.geometry == 1 and video.stereo_sbs, "Completed automatic layout remains VR180 SBS")
	var converted_uri := "file:///v/clip.mp4"
	video.set_projection(0); video.set_stereo_layout(0)
	check(video.set_depth(true) and video.mode_memory.lookup(converted_uri).depth_requested, "Manual conversion is saved for the current file")
	video.set_depth_strength(1.65); video._remember_mode()
	check(is_equal_approx(video.mode_memory.lookup(converted_uri).depth_strength,1.65),"Strength is committed with this video's conversion record")
	check(video.open_local("file:///other/clip.mp4", "clip.mp4") and not video.depth_requested and not video.auto_depth and not host.depths.back(),
		"Another URI with the same filename never inherits conversion")
	check(video.depth_strength==1.0,"Another URI never inherits the previous video's strength")
	video.media.format = {"width": 8192, "height": 4096, "pixel_aspect": 1.0}
	video._complete_layout()
	check(video.geometry == 1 and video.stereo_sbs and not video.depth_requested and not video._pending_revision.depth,
		"Unmarked first frame defaults to VR180 SBS without inheriting the previous file's depth")
	video.set_projection(2)
	check(not video.depth_requested and not video._pending_revision.depth, "Manual VR selection never needs to exit unwanted depth processing")
	video.mode_memory = Memory.new(test_path.path_join("integration")); video.mode_memory.load_saved()
	check(video.open_local(converted_uri, "clip.mp4") and video.depth_requested and video.auto_depth and host.depths.back(),
		"A fresh store restores this file's conversion before the native open")
	check(is_equal_approx(video.depth_strength,1.65),"A fresh file-settings store restores this video's individual strength")
	video.media.format = {"width": 8192, "height": 4096, "pixel_aspect": 1.0}
	video._complete_layout()
	check(video.geometry == 0 and not video.stereo_sbs and video.depth_requested and video._layout_pending == null,
		"Remembered flat mono conversion overrides the exact 2:1 fallback")
	check(video.set_depth(false) and not video.mode_memory.lookup(converted_uri).depth_requested, "Manual Off updates only this file's conversion record")
	check(video.open_local("cloud://mount/movie", "clip.mp4") and not host.depths.back(), "A new network video starts without conversion")
	video.set_depth(true)
	video.set_depth_strength(.75); video._remember_mode()
	check(video.open_local(converted_uri, "clip.mp4") and not video.depth_requested and not host.depths.back(), "An older Off file ignores another video's On choice")
	check(is_equal_approx(video.depth_strength,1.65),"Turning this video off retains only its own last nonzero strength")
	check(video.open_local("cloud://mount/movie", "clip.mp4") and video.depth_requested and host.depths.back(), "Another video's Off choice cannot overwrite the network file's On record")
	check(is_equal_approx(video.depth_strength,.75),"The network video restores its own independent strength")
	video._reopen_after_context_loss(video.local_uri, video.display_name, 1234, true)
	check(video.depth_requested and host.depths.back(), "Context recovery keeps the current file's live conversion")
	check(is_equal_approx(video.depth_strength,.75),"Context recovery keeps live strength instead of resetting it")
	var legacy := mode.duplicate(true); legacy.geometry = 0; legacy.stereo_sbs = false
	video.mode_memory.remember("file:///legacy.mp4", legacy)
	check(video.open_local("file:///legacy.mp4", "legacy.mp4") and not video.auto_depth and not host.depths.back(), "A legacy mode without a depth field defaults Off")
	check(video.depth_strength==1.0,"Legacy per-file settings without strength use 100%, not another file's choice")
	video.set_alpha(true)
	check(video.alpha_requested and not video.mode_memory.lookup("file:///legacy.mp4").alpha_requested, "Manual passthrough is live only and is never saved On")
	video._reopen_after_context_loss(video.local_uri, video.display_name, 1234, true)
	check(video.alpha_requested and host.calls.back()[4], "Context recovery preserves live passthrough")
	video._reopen_at(1234, false)
	check(video.alpha_requested and host.calls.back()[4], "Changing the render path preserves live passthrough")
	check(video.open_local("file:///legacy.mp4", "legacy.mp4") and not video.alpha_requested and not host.calls.back()[4], "Reopening the same unmarked video always starts passthrough Off")
	video.set_alpha(true)
	check(video.open_local("file:///other.mp4", "other.mp4") and not video.alpha_requested and not host.calls.back()[4], "A different video never inherits manual passthrough")
	for lock in [{"geometry": 0, "layout": 0, "depth": false, "fisheye_fov": 180},
			{"geometry": 0, "layout": 0, "depth": true, "fisheye_fov": 180},
			{"geometry": 1, "layout": 1, "depth": false, "fisheye_fov": 180},
			{"geometry": 2, "layout": 4, "depth": false, "fisheye_fov": 200},
			{"geometry": 3, "layout": 2, "depth": false, "fisheye_fov": 180}]:
		video.load_mode_lock(lock)
		video.auto_depth = lock.depth
		var expected: Dictionary = lock.duplicate(); expected.depth = false
		check(video.open_local("file:///v/locked_%d.mp4" % lock.geometry, "locked_%d.mp4" % lock.geometry)
			and video.current_lock() == expected and not host.depths.back() and video._layout_pending == null, "Projection lock cannot carry depth into an unmarked source %d" % lock.geometry)
		video.media.format = {"width": 8192, "height": 4096, "pixel_aspect": 1.0}
		video._complete_layout()
		check(video.current_lock() == expected and video.mode_lock == expected and video._pending_revision.is_empty(),
			"First 2:1 frame preserves locked mode %d" % lock.geometry)
	video.load_mode_lock({})
	video.auto_depth = false
	check(video.open_local("file:///v/clip_alpha.mp4", "clip_alpha.mp4") and host.calls.back()[4] == true and not video.packed_file,
		"Alpha in the name opens with live Alpha")
	video.set_alpha(false)
	check(video.open_local("file:///v/clip_alpha.mp4", "clip_alpha.mp4") and video.alpha_requested and host.calls.back()[4], "Explicit Alpha filename still opts in after manual Off")
	check(video.open_local("file:///v/clip_passthrough.mp4", "clip_passthrough.mp4") and video.alpha_requested, "Passthrough filename marker also opts in")
	var packed_uri := "file:///v/clip_LR_180_FISHEYE_F180_alpha.mp4"
	check(video.open_local(packed_uri, "clip_LR_180_FISHEYE_F180_alpha.mp4") and host.calls.back()[4] == false
		and video.packed_file and video.alpha_wanted() and video.geometry == 2 and video.stereo_sbs, "Packed output shows its own mask without RVM")
	var opens := host.calls.size()
	check(video.set_alpha(false) and not video.alpha_wanted() and host.calls.size() == opens, "Alpha switch toggles the packed mask in place")
	video._reopen_after_context_loss(packed_uri, video.display_name, 1234, true)
	check(video.packed_file and not video.alpha_wanted() and not host.calls.back()[4], "Packed-mask Off survives context recovery without live inference")
	video.set_alpha(true); video._reopen_at(1234, false)
	check(video.packed_file and video.alpha_wanted() and not host.calls.back()[4], "Packed-mask On survives render-path changes without live inference")
	video.mode_memory.remember(packed_uri, {"geometry": 0, "stereo_sbs": false, "swap_eyes": false, "alpha_requested": false, "profile": "320x320"})
	check(video.open_local(packed_uri, "clip_LR_180_FISHEYE_F180_alpha.mp4") and video.geometry == 0 and not video.stereo_sbs,
		"The user's remembered mode wins over the name")
	video.media.format = {"width": 8192, "height": 4096, "pixel_aspect": 1.0}
	video._complete_layout()
	check(video.geometry == 0 and not video.stereo_sbs and video._pending_revision.is_empty(),
		"First 2:1 frame preserves the per-file choice over explicit VR naming")
	video.queue_free()
	await process_frame
	var half_uri := "file:///v/half.webm"
	var half_mode := mode.duplicate(true)
	half_mode.merge({"geometry": 2, "top_bottom": true, "stereo_half": true}, true)
	check(memory.remember(half_uri, half_mode) and memory.save() and read_again().lookup(half_uri) == half_mode, "Half packing survives both checksummed banks")
	var report := {"state": "passed" if failures.is_empty() else "failed", "checks": checks,
		"scope": "Actual Windows files and Godot player with mocked MPV; Android storage/power loss/URI permission not exercised",
		"failures": failures}
	write(test_path.path_join("verification.json"), JSON.stringify(report, "\t"))
	print("File mode memory host checks: %s (%d), evidence=%s" % [report.state, checks, test_path])
	for failure in failures:
		push_error(failure)
	quit(0 if failures.is_empty() else 1)
