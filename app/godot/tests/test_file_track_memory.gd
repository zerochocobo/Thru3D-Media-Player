extends SceneTree

const Memory := preload("res://scripts/file_track_memory.gd")
const Video := preload("res://scripts/mpv_video_display.gd")
const Modes := preload("res://scripts/file_mode_memory.gd")
const Recent := preload("res://scripts/recent_files.gd")
var checks := 0
var failures: Array[String] = []
var directory := ""
const URI := "smb://server/share/movie.mp4"
const AUDIO := [{"id": 1, "title": "Original", "language": "en", "codec": "aac", "external": false},
	{"id": 4, "title": "Dubbing", "language": "zh", "codec": "aac", "external": true}]
const SUBS := [{"id": 7, "title": "English", "language": "en", "codec": "ass", "external": false},
	{"id": 12, "title": "中文字幕", "language": "zh", "codec": "subrip", "external": true},
	{"id": 15, "title": "PGS", "language": "zh", "codec": "hdmv_pgs_subtitle", "external": false}]

class Host extends RefCounted:
	var calls: Array = []
	var serial := 10
	var audio_ok := true
	var read_policies: Array = []
	func set_mpv_interleave_compat(enabled: bool) -> void: read_policies.append(enabled)
	var subtitle_ok := true
	func mpv_supported() -> bool: return true
	func open_mpv_video(uri: String, start: int, stereo: bool, profile: String, alpha: bool, _vulkan: bool,
		depth: bool = false, _top_bottom: bool = false, _exact: bool = false) -> int:
		serial += 1
		calls.append(["open", serial, uri, start, stereo, profile, alpha, depth])
		return serial
	func close_mpv_video(id: int) -> void: calls.append(["close", id])
	func set_mpv_playing(_id: int, _playing: bool) -> void: pass
	func set_mpv_audio(id: int, track: int, volume: float, muted: bool) -> bool:
		calls.append(["audio", id, track, volume, muted]); return audio_ok
	func set_mpv_subtitle(id: int, track: int) -> bool:
		calls.append(["subtitle", id, track]); return subtitle_ok
	func revise_mpv_video(id: int, _stereo: bool, _alpha: bool, _profile: String, _position: int,
		_depth: bool = false, _top_bottom: bool = false, _exact: bool = false) -> int:
		serial += 1; calls.append(["revise", id, serial]); return serial

class Interrupted extends "res://scripts/file_track_memory.gd":
	func _commit(_staged: String, _target: String) -> Error: return ERR_CANT_CREATE

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func fresh(path: String) -> RefCounted:
	var store := Memory.new(path); store.load_saved(); return store

func state(video: Node, audio: Array = AUDIO, subs: Array = SUBS, id: int = -1) -> void:
	video._on_state(video.media.session_id if id < 0 else id, JSON.stringify({"state": "ready",
		"details": {"audio_tracks": audio, "subtitle_tracks": subs, "pgs_supported": true}}))

func player(path: String) -> Node:
	var video := Video.new()
	video.mode_memory = Modes.new(path)
	video.recent_files = Recent.new(path)
	video.track_memory = Memory.new(path)
	video.history_enabled = false
	video.layer_enabled = false
	video.platform = Host.new()
	root.add_child(video)
	video.set_process(false)
	return video

func _initialize() -> void: call_deferred("_run")

func _run() -> void:
	directory = ProjectSettings.globalize_path("res://../../build/output/file-track-preferences-20261012/" + str(Time.get_ticks_usec()))
	DirAccess.make_dir_recursive_absolute(directory)
	var path := directory.path_join("storage")
	var choice := {"audio": Memory.describe(4, AUDIO), "subtitle": Memory.describe(12, SUBS)}
	var store := Memory.new(path)
	check(store.remember(URI, choice) and store.save() and fresh(path).lookup(URI) == choice, "Both choices survive disk reload")
	check(store.remember(URI, choice) and store.save() and store.sequence == 1, "Unchanged choices do not write a generation")
	check(store.lookup("smb://server/share/Movie.mp4").is_empty(), "File identities remain case sensitive and separate")
	check(not store.remember("http://127.0.0.1:123/t/movie", choice), "Ephemeral proxy identities cannot be saved")
	check(not store.remember(URI, {"subtitle": {"id": 0.5}}) and not store.remember(URI, {"video": {"id": 0}}), "Malformed channels and IDs rejected")
	var off := {"audio": {"id": -1}, "subtitle": {"id": 0}}
	check(store.remember(URI, off) and store.save() and fresh(path).lookup(URI) == off, "Auto audio and disabled subtitles survive reload")
	var broken := FileAccess.open(store._bank_path(store.active_bank), FileAccess.WRITE)
	broken.store_string("truncated"); broken.close()
	check(fresh(path).lookup(URI) == choice, "Damaged latest generation falls back to the valid previous bank")
	var interrupted := Interrupted.new(path); interrupted.load_saved()
	check(interrupted.remember(URI, off) and not interrupted.save() and fresh(path).lookup(URI) == choice, "Failed atomic commit preserves previous preferences")
	check(store.relocate(URI, "smb://server/share/renamed.mp4") and store.save()
		and fresh(path).lookup(URI).is_empty() and fresh(path).lookup("smb://server/share/renamed.mp4") == off, "Rename migrates both track choices")
	var renamed_subs := SUBS.duplicate(true); renamed_subs[0].id = 12; renamed_subs[1].id = 29
	renamed_subs.reverse()
	check(Memory.resolve(choice.subtitle, renamed_subs) == 29, "Changed order and reused numeric ID resolve by metadata")
	check(Memory.resolve(choice.subtitle, [SUBS[0]]) == Memory.UNRESOLVED, "Missing external caption never selects an unrelated track")
	var duplicates := [{"id": 1, "codec": "aac"}, {"id": 2, "codec": "aac"}]
	var ambiguous := Memory.describe(2, duplicates)
	check(Memory.resolve(ambiguous, duplicates) == 2, "Unchanged duplicate layout retains the selected ID")
	check(Memory.resolve(ambiguous, [duplicates[0]]) == Memory.UNRESOLVED, "Partially loaded duplicate list cannot select the wrong remaining track")
	check(Memory.resolve(ambiguous, [{"id": 6, "codec": "aac"}, {"id": 7, "codec": "aac"}]) == Memory.UNRESOLVED,
		"Renumbered ambiguous tracks do not arbitrarily choose the first")
	var video := player(directory.path_join("player"))
	var host: Host = video.platform
	check(video.open_local(URI, "movie.mp4"), "File opens with default selections")
	state(video)
	check(video.set_subtitle_track(12) and video.select_audio_track(4), "Manual subtitle and audio choices accepted")
	check(fresh(video.track_memory.directory).lookup(URI) == choice, "Manual choices persist even when play history is disabled")
	var serial: int = video.track_memory.sequence
	video.change_volume(-20); video.toggle_mute()
	check(video.track_memory.sequence == serial, "Volume and mute do not rewrite track preference")
	video.subtitles.sequence = 99
	video.subtitles.text = "old cue"
	video._layer_session = true
	video.set_alpha(true)
	video._try_revision()
	check(host.calls.any(func(c): return c[0] == "open" and c[6]) and video.subtitles.sequence == 0 and video.subtitles.text.is_empty(),
		"Layer-to-portrait actually reopens source and resets only cue fencing")
	state(video, AUDIO, [SUBS[0]])
	check(video.audio_track_id == 4 and video.subtitles.requested_track == 0 and video._track_restore.has("subtitle"), "Audio restores while late external subtitle waits")
	state(video, AUDIO, renamed_subs)
	check(video.subtitles.requested_track == 29 and video._track_restore.is_empty() and video.audio_volume == 80 and video.audio_muted,
		"Late caption restores under its new ID, volume and mute remain")
	check(video.track_memory.sequence == serial, "Automatic restore does not overwrite saved identities")
	video.alpha_requested = false
	video._layer_session = true
	video.set_depth(true); video._try_revision()
	state(video, AUDIO, SUBS)
	check(video.depth_requested and video.audio_track_id == 4 and video.subtitles.requested_track == 12, "Layer-to-2D/3D retains both choices")
	video._network_interleave_compat = true
	video._reopen_at(1200, true); state(video)
	check(host.read_policies.back() == true and video._network_interleave_compat, "Confirmed read policy crosses close/open and stays with this source")
	check(video.audio_track_id == 4 and video.subtitles.requested_track == 12, "Returning to the compositor layer retains choices")
	video.subtitles.sequence = 42
	video._layer_session = false
	var count: int = host.calls.size()
	video.seek_absolute(3000); video._try_revision()
	check(video.subtitles.requested_track == 12 and video.audio_track_id == 4 and video.subtitles.sequence == 42
		and not host.calls.slice(count).any(func(c): return c[0] == "subtitle"), "Same-core revision keeps choices and cue fencing without redundant commands")
	video._reopen_at(3100, false); state(video)
	check(host.read_policies.back() == true, "A display-path reopen retains confirmed network compatibility")
	check(video.subtitles.requested_track == 12 and video.audio_track_id == 4, "Immediate reopen after revision retains identities before new metadata arrives")
	video._reopen_after_context_loss(URI, "movie.mp4", 3200, true); state(video)
	check(video.subtitles.requested_track == 12 and video.audio_track_id == 4, "Graphics context recovery restores both tracks")
	video.queue_free(); await process_frame
	video = player(directory.path_join("player")); host = video.platform
	video.prefer_clone_voice = true
	check(video.open_local(URI, "movie.mp4"), "Fresh controller reopens the same file")
	check(host.read_policies.back() == false, "A fresh file open cannot inherit a previous source's compatibility override")
	state(video)
	check(video.audio_track_id == 4 and video.subtitles.requested_track == 12, "App restart restores both file choices")
	check(video.set_subtitle_track(0) and video.select_audio_track(-1), "Explicit disabled subtitle and automatic audio accepted")
	video.close_video(); video.open_local(URI, "movie.mp4"); state(video); video._process(0.0)
	check(video.audio_track_id == -1 and video.subtitles.requested_track == 0 and video._clone_applied, "Explicit auto audio overrides global dubbing and disabled subtitle stays disabled")
	video.set_subtitle_track(12); video.select_audio_track(4)
	var old_id: int = video.media.session_id
	video.close_video(); video.open_local("smb://server/share/other.mp4", "other.mp4")
	state(video, AUDIO, SUBS, old_id)
	check(video._track_restore.is_empty() and video.audio_track_id == -1 and video.subtitles.requested_track == 0,
		"Different file and stale state cannot inherit previous selections")
	var current_id: int = video.media.session_id
	video._reopen_after_context_loss(URI, "old recovery", 0, true, old_id)
	check(video.local_uri == "smb://server/share/other.mp4" and video.media.session_id == current_id,
		"Deferred recovery from another file cannot replace the current file")
	video._reopen_after_context_loss(video.local_uri, "stale recovery", 0, true, old_id)
	check(video.media.session_id == current_id, "Stale recovery from an earlier session of the same file is ignored")
	state(video)
	check(not video._clone_applied, "Untouched file keeps the global dubbing path available")
	video.set_subtitle_track(-1); video.select_audio_track(0)
	video.close_video(); video.open_local("smb://server/share/other.mp4", "other.mp4"); state(video)
	check(video.audio_track_id == 0 and video.subtitles.requested_track == -1, "Disabled audio and automatic subtitles also persist")
	video.subtitle_auto_load = true
	video.close_video(); video.open_local("smb://server/share/fresh.mp4", "fresh.mp4")
	video._reopen_at(500, false)
	state(video, AUDIO, [{"id": 21, "title": "fresh.srt", "language": "", "codec": "subrip", "external": true}])
	check(video.subtitles.requested_track == 21, "An internal reopen before tracks arrive keeps automatic subtitle selection")
	video.subtitle_auto_load = false
	video.close_video(); video.open_local(URI, "movie.mp4", 0, false); state(video)
	check(video._track_restore.is_empty() and video.audio_track_id == -1 and video.subtitles.requested_track == 0,
		"Diagnostic opens bypass user track preferences")
	serial = video.track_memory.sequence
	video.set_subtitle_track(7); video.select_audio_track(1)
	check(video.track_memory.sequence == serial, "Diagnostic selection cannot overwrite stored user choices")
	video.close_video(); video.open_local(URI, "movie.mp4")
	state(video, [AUDIO[0]], [SUBS[0]])
	check(video._track_restore.size() == 2, "Missing external tracks stay pending")
	check(video.set_subtitle_track(7) and video.select_audio_track(1), "Manual choice can replace a pending restoration")
	state(video)
	check(video.subtitles.requested_track == 7 and video.audio_track_id == 1 and video._track_restore.is_empty(), "Late external tracks cannot undo a newer manual choice")
	video.track_memory.read_only = true
	check(video.set_subtitle_track(12) and video.select_audio_track(4), "Storage failure does not break accepted live choices")
	video._reopen_at(4000, false); state(video)
	check(video.subtitles.requested_track == 12 and video.audio_track_id == 4, "Live track choices survive reopen even when disk save failed")
	video.track_memory.read_only = false
	video.track_memory.save()
	host.subtitle_ok = false; host.audio_ok = false
	video._reopen_at(4100, false); state(video)
	check(video._track_restore.size() == 2, "Native rejection retains pending restoration")
	serial = video.track_memory.sequence
	check(not video.set_subtitle_track(7) and not video.select_audio_track(1) and video._track_restore.size() == 2
		and video.track_memory.sequence == serial, "Rejected manual commands cannot cancel pending choices or rewrite memory")
	host.subtitle_ok = true; host.audio_ok = true; state(video)
	check(video._track_restore.is_empty() and video.subtitles.requested_track == 12 and video.audio_track_id == 4, "Native readiness retries the original choices")
	video.set_subtitle_track(15)
	video.geometry = 1; video._apply_geometry(); video._restore_tracks()
	check(video.subtitles.requested_track == 0 and video._track_restore.has("subtitle")
		and int(video.track_memory.lookup(URI).subtitle.id) == 15, "Unsupported immersive PGS is temporarily off without overwriting its file choice")
	video.geometry = 0; video._apply_geometry(); video._restore_tracks()
	check(video.subtitles.requested_track == 15 and video._track_restore.is_empty(), "Returning to flat mode restores the retained PGS selection")
	video.queue_free(); await process_frame
	print("File track preferences: %d checks, %d failures" % [checks, failures.size()])
	var report := FileAccess.open(directory.path_join("verification.json"), FileAccess.WRITE)
	report.store_string(JSON.stringify({"checks": checks, "failures": failures,
		"scope": "Actual Godot controller and Windows persistence with mocked native MPV; no headset installation"}, "\t")); report.close()
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)
