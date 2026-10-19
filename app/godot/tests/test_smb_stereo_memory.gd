extends SceneTree
## SMB library A -> B -> A -> B, including presented frames and recent-file routing.
const Video := preload("res://scripts/mpv_video_display.gd")
const Memory := preload("res://scripts/file_mode_memory.gd")
const Privacy := preload("res://scripts/media_privacy.gd")
var checks := 0
var failures: Array[String] = []

class Host extends RefCounted:
	var serial := 100
	var opens: Array = []
	var pair: Dictionary = {}
	func mpv_supported() -> bool: return true
	func open_mpv_video(uri: String, start: int, _stereo: bool, _profile: String, _alpha: bool, _vulkan: bool,
			_depth: bool = false, _tb: bool = false, _exact: bool = false) -> int:
		serial += 1; opens.append([uri, start]); return serial
	func set_mpv_playing(_id: int, _playing: bool) -> void: pass
	func close_mpv_video(_id: int) -> void: pass
	func claim_mpv_pair(_id: int, _token: int) -> String: return JSON.stringify(pair)
	func acknowledge_mpv_pair(_id: int, _token: int) -> bool: return true
	func detach_mpv_pair(_id: int, _token: int) -> void: pass
	func revise_mpv_video(_id: int, _stereo: bool, _alpha: bool, _profile: String, _position: int,
			_depth: bool = false, _tb: bool = false, _exact: bool = false) -> int: return 0

class Layers extends "res://scripts/video_layer.gd":
	func update_session() -> void: pass
	func available() -> bool: return true
	func supports(_geometry: int, _curved: bool) -> bool: return true
	func _apply(_count: int, _values: PackedFloat32Array, _orders := PackedInt32Array()) -> bool: return true

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok: failures.append(label)

func _initialize() -> void: call_deferred("run")

func present(video: Node, host: Host) -> void:
	var session: int = video.media.session_id
	host.pair = {"session_id": session, "logical_session_id": session, "generation": 1, "frame_id": 1,
		"slot_token": 1, "pts_us": 12000000, "width": 3840, "height": 1080, "color_target": "layer",
		"source_pts_verified": true, "format_revision": 1, "effect_revision": 1,
		"alpha_requested": false, "inference_ran": false, "stereo_sbs": true}
	video._on_pair(session, JSON.stringify(host.pair)); video._present_pending()
	video._on_state(session, JSON.stringify({"state": "ready", "layer_active": true,
		"details": {"position_seconds": "12", "duration_seconds": "600"}}))
	check(video.media.frame_counter == 1 and video._layer_session, "First presented frame uses the production layer-binding path")

func aligned(video: Node, expected: Vector2, label: String, rendered: bool = true) -> void:
	check(Vector2(video.stereo_horizontal, video.stereo_vertical).is_equal_approx(expected), label)
	if rendered: check(video.material.get_shader_parameter("stereo_offset").is_equal_approx(expected * 0.01), label + " reaches the renderer")

func scenario(directory: String, policy: String, settings_policy: String = Privacy.ALL, locked: bool = false) -> void:
	Privacy.configure(policy); Privacy.configure_file_settings(settings_policy); Privacy.vault = null
	var video := Video.new()
	for memory in [video.mode_memory, video.track_memory, video.subtitle_timing, video.audio_timing,
			video.whisper_memory, video.narration.memory, video.recent_files, video.bookmark_store]:
		memory.directory = directory.path_join(str(memory.get_instance_id()))
	root.add_child(video); video.set_process(false)
	var host := Host.new(); video.platform = host; video.video_layer = Layers.new(null)
	video.history_enabled = policy != Privacy.NONE
	if locked:
		var vault := preload("res://scripts/favorite_store.gd").new(directory.path_join("favorites"))
		vault.protected = true; vault.locked = true; Privacy.vault = vault
	var a := "smb://saved-pc/CD2/115/影片 A_flat_LRF.mp4"
	var b := "smb://saved-pc/CD2/115/影片 B_flat_LRF.mp4"
	var keep := settings_policy == Privacy.ALL and not locked
	for entry in [[a, Vector2(2.0, -1.0)], [b, Vector2(-0.75, 1.25)]]:
		check(video.open_library(entry[0], str(entry[0]).get_file()), "SMB library opens a stable file URI")
		present(video, host)
		video.set_stereo_alignment("stereo_horizontal", entry[1].x)
		video.set_stereo_alignment("stereo_vertical", entry[1].y)
		video.commit_stereo_view()
		aligned(video, entry[1], "Current movie retains the preview under " + policy)
	for entry in [[a, Vector2(2.0, -1.0)], [b, Vector2(-0.75, 1.25)]]:
		check(video.open_library(entry[0], str(entry[0]).get_file()), "Library reopens the movie through recent-file routing")
		# The old surface is hidden while opening; shader uniforms update with the first bound frame.
		aligned(video, entry[1] if keep else Vector2.ZERO, "Reopened SMB movie follows its recording policy", false)
		present(video, host)
		aligned(video, entry[1] if keep else Vector2.ZERO, "First frame does not replace restored corrections")
	check(host.opens.size() == 4 and host.opens[0][0] == host.opens[2][0] and host.opens[1][0] == host.opens[3][0],
		"SMB A/B identity stays unchanged through the complete switching sequence")
	check(video.recent_files.entries.size() == (2 if policy == Privacy.ALL else 0), "History routing honors privacy independently of favorite locking")
	video.close_video()
	var restored := Memory.new(video.mode_memory.directory); restored.load_saved()
	if keep:
		check(restored.lookup(a).get("stereo_horizontal") == 2.0 and restored.lookup(a).get("stereo_vertical") == -1.0
			and restored.lookup(b).get("stereo_horizontal") == -0.75 and restored.lookup(b).get("stereo_vertical") == 1.25,
			"A and B retain distinct corrections after a fresh disk read")
	else:
		check(restored.entries.is_empty(), "Restricted recording never persists either movie's corrections")
	Privacy.vault = null; video.free()

func run() -> void:
	var directory := ProjectSettings.globalize_path("res://../../build/output/stereo-smb-memory/cases-" + str(Time.get_ticks_usec()))
	for policy in [Privacy.ALL, Privacy.LOCAL, Privacy.NONE]:
		for settings_policy in [Privacy.ALL, Privacy.LOCAL, Privacy.NONE]:
			scenario(directory.path_join(policy + "-" + settings_policy), policy, settings_policy)
	scenario(directory.path_join("locked"), Privacy.ALL, Privacy.ALL, true)
	Privacy.configure(Privacy.ALL); Privacy.configure_file_settings(Privacy.ALL)
	print("SMB stereo memory checks=%d failures=%d" % [checks, failures.size()])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)
