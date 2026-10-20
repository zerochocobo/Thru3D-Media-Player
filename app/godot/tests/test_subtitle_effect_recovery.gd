extends SceneTree

const Video := preload("res://scripts/mpv_video_display.gd")
const URI := "cloud://fixture/Films/film.mp4"
var checks := 0
var failures: Array[String] = []

class Host extends RefCounted:
	var serial := 400
	var loads: Array = []
	var selections: Array = []
	var narration: Array = []
	var accept_load := true
	func mpv_supported() -> bool: return true
	func open_mpv_video(_uri: String, _start: int, _stereo: bool, _profile: String, _alpha: bool,
		_vulkan: bool, _depth: bool = false, _top: bool = false, _exact: bool = false) -> int:
		serial += 1; return serial
	func close_mpv_video(_id: int) -> void: pass
	func set_mpv_playing(_id: int, _playing: bool) -> void: pass
	func set_mpv_audio(_id: int, _track: int, _volume: float, _muted: bool) -> bool: return true
	func set_mpv_subtitle(id: int, track: int) -> bool: selections.append([id, track]); return true
	func set_mpv_subtitle_delay(_id: int, _seconds: float) -> bool: return true
	func list_mpv_subtitle_files(_id: int, _request: int) -> bool: return true
	func load_mpv_subtitle_file(id: int, request: int, filename: String) -> bool:
		loads.append([id, request, filename]); return accept_load
	func set_mpv_narration(id: int, payload: String) -> bool:
		narration.append([id, JSON.parse_string(payload)]); return true

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func track(id: int) -> Dictionary:
	return {"id": id, "title": "film.srt", "source_file": "film.srt", "external": true, "codec": "subrip"}

func state(video: Node, tracks: Array) -> void:
	video._on_state(video.media.session_id, JSON.stringify({"state": "ready", "details": {"subtitle_tracks": tracks}}))

func load_error(video: Node, host: Host) -> void:
	video._on_subtitle_files(video.media.session_id, JSON.stringify({"operation": "load", "request": host.loads.back()[1], "state": "error"}))

func _initialize() -> void: call_deferred("run")

func run() -> void:
	preload("res://scripts/i18n.gd").use("en")
	var video := Video.new()
	var directory := ProjectSettings.globalize_path("res://../../build/output/subtitle-effect-recovery/%d" % Time.get_ticks_usec())
	video.mode_memory = video.ModeMemory.new(directory + "/modes")
	video.track_memory = video.TrackMemory.new(directory + "/tracks")
	video.subtitle_timing = video.SubtitleTiming.new(directory + "/timing")
	video.narration.memory = video.NarrationSettings.Memory.new(directory + "/narration")
	video.history_enabled = false; video.layer_enabled = false
	root.add_child(video); video.set_process(false)
	var host := Host.new(); video.platform = host
	check(video.open_local(URI, "film.mp4"), "Open cloud source through the production controller")
	state(video, [track(4)])
	check(video.set_subtitle_track(4) and video.set_subtitle_delay(1.2), "Select the cloud sidecar and a live timing correction")
	check(video.narration.set_option("narration_enabled", true), "Enable narration for the selected text subtitle")
	video.narration.save(ConfigFile.new())
	video.control.observed_position_ms = 42000
	video._layer_session = true
	video.set_alpha(true)
	check(video.alpha_requested and video.media.session_id == 402, "Enabling portrait matting actually reopens the layer source")
	state(video, [])
	check(host.loads.size() == 1 and video._track_restore.has("subtitle"), "Reopened cloud playback waits for its sidecar")
	load_error(video, host)
	check(video._track_restore.has("subtitle") and not video.subtitle_file_error.is_empty(), "An optional reload error keeps the original selection pending")
	for index in 3: video._restore_tracks()
	check(host.loads.size() == 1, "Waiting for background discovery does not repeatedly download the failed sidecar")
	state(video, [{"id": 9, "title": "other.srt", "source_file": "other.srt", "external": true, "codec": "subrip"}])
	check(video.subtitles.requested_track == 0 and video._track_restore.has("subtitle"), "A different late subtitle cannot replace the original choice")
	state(video, [track(14)])
	video.narration.apply()
	check(video.subtitles.requested_track == 14 and video._track_restore.is_empty(), "The late original subtitle returns under its new MPV id instead of remaining Off")
	check(video.subtitle_file_error.is_empty() and is_equal_approx(video.subtitle_delay, 1.2), "Successful recovery clears the old error and retains the live timing")
	check(not host.narration.is_empty() and host.narration.back()[1].enabled, "Narration resumes after the original subtitle is recovered")
	# A rejected dispatch has the same late-discovery path, without an async receipt.
	video.set_subtitle_track(14)
	host.accept_load = false
	video._reopen_at(43000, false)
	state(video, [])
	var attempts := host.loads.size()
	check(video._track_restore.has("subtitle"), "A rejected reload dispatch also retains the selected sidecar")
	state(video, [])
	check(host.loads.size() == attempts, "A rejected dispatch is not retried every frame")
	state(video, [track(24)])
	check(video.subtitles.requested_track == 24, "Background discovery can recover after dispatch rejection")
	# Explicit user Off cancels pending restoration, including a late success/error.
	video.set_subtitle_track(24)
	host.accept_load = true
	video._reopen_at(44000, false); state(video, [])
	check(video.set_subtitle_track(0), "The user can still explicitly disable subtitles while recovery is pending")
	load_error(video, host); state(video, [track(34)]); video.narration.apply()
	check(video.subtitles.requested_track == 0 and video._track_restore.is_empty() and not host.narration.back()[1].enabled,
		"Late metadata and old reload receipts cannot undo a newer explicit Off")
	# Internal output changes preserve live settings even if file memory is disabled.
	video.narration.memory = video.NarrationSettings.Memory.new(directory + "/disabled-memory")
	video.narration.memory.read_only = true
	video.set_subtitle_track(34)
	video.narration.set_option("narration_enabled", true)
	video.narration.set_option("narration_language", "ja")
	video.narration.set_option("narration_volume", 37.0)
	video._reopen_at(45000, false)
	check(video.narration.enabled and video.narration.language == "ja" and video.narration.volume == 37.0,
		"Changing output keeps live narration independent of persistent per-file memory")
	state(video, [track(44)]); video.narration.apply()
	check(host.narration.back()[1].enabled and host.narration.back()[1].language == "ja" and is_equal_approx(host.narration.back()[1].volume, 0.37),
		"Recovered text uses the live narration settings on the new native session")
	video._reopen_after_context_loss(URI, "film.mp4", 46000, true)
	check(video.narration.enabled and video.narration.language == "ja" and video.narration.volume == 37.0,
		"Graphics recovery retains the same video's live narration as well")
	video.open_local("cloud://fixture/Films/other.mp4", "other.mp4")
	check(not video.narration.enabled and video.narration.language == "en", "Opening another video still starts with its own narration preferences")
	state(video, [track(54)])
	check(video.subtitles.requested_track == 54 and video.track_memory.lookup(video.local_uri).is_empty(), "Automatic selection supplies a live choice without writing a manual preference")
	video._layer_session = true; video.set_alpha(true); state(video, []); load_error(video, host)
	state(video, [track(64)])
	check(video.subtitles.requested_track == 64, "An automatically chosen cloud subtitle also recovers after portrait output is reopened")
	video._reopen_at(47000, true); state(video, [track(74)])
	check(video.subtitles.requested_track == 74, "Returning from portrait output restores the same subtitle again")
	video.free()
	for failure in failures: push_error(failure)
	print("Subtitle effect recovery checks=%d failures=%d" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
