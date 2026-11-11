extends SceneTree
const Player := preload("res://scripts/mpv_video_display.gd")
const Mirror := preload("res://scripts/airplay_window.gd")
const Caps := preload("res://scripts/cast_capabilities.gd")
const Receiver := preload("res://tests/test_cast_receiver.gd")
const Menu := preload("res://scripts/player_menu.gd")
var checks := 0
var failures: Array[String] = []

class Bridge extends "res://tests/test_cast_listening.gd".Host:
	var live := false
	var disconnects := 0
	var speech: Array = []
	var live_report := {"state": "ready", "generation": 1, "sequence": 1, "cues": [{"text": "Live speech"}]}
	func dlna_receiver_enable(_enabled: bool) -> bool: return true
	func dlna_receiver_detach() -> void: pass
	func airplay_receiver_poll() -> String: return JSON.stringify({"active": 7, "player_active": live})
	func airplay_receiver_open_player(epoch: int) -> bool: live = epoch == 7; return live
	func airplay_receiver_suspend(_epoch: int) -> bool: live = false; return true
	func airplay_receiver_disconnect(_epoch: int) -> void: disconnects += 1
	func airplay_receiver_captions(epoch: int, language: String) -> bool: speech.append([epoch, language]); return epoch == 7
	func airplay_receiver_caption_status(_epoch: int) -> String: return JSON.stringify(live_report)

class Owner extends "res://scripts/main.gd":
	func _prepare_cast_switch() -> void: pass
	func _cancel_video_queue_wait() -> void: pass
	func _clear_controls_locks() -> void: pass
	func _show_player_menu() -> void: player_menu.show()
	func _show_full_library() -> void: recent_menu.show()
	func _head_pose() -> Transform3D: return Transform3D.IDENTITY
	func _input_focused() -> bool: return true

func check(value: bool, label: String) -> void:
	checks += 1
	if not value: failures.append(label)

func _initialize() -> void: run.call_deferred()

func run() -> void:
	var bridge := Bridge.new()
	var video := Player.new(); root.add_child(video); video.set_process(false); video.platform = bridge
	video.history_enabled = false; video.default_auto_depth = false
	var owner := Owner.new()
	owner.video = video; owner.photo = Receiver.Photo.new()
	owner.recent_menu = Receiver.StubMenu.new(); owner.video_menu = Receiver.StubMenu.new(); owner.player_menu = owner.video_menu
	owner.cast_session.bind(owner, bridge)
	var mirror := Mirror.new(); root.add_child(mirror); mirror.bind(owner, bridge); owner.airplay_session = mirror
	mirror.epoch = 7; mirror.pip._open(1, Transform3D.IDENTITY)
	var window: Node3D = mirror.pip.windows[1]
	window.live_source = true
	var pose: Transform3D = window.global_transform
	var size: Vector2 = window.size
	video.open_local("http://192.0.2.1/ordinary.mp4", "Ordinary", 0, false)
	video.requested_play = false; video.control.observe(42000, 120000)
	mirror._open_player()
	check(mirror.player_mode and bridge.live and not window.visible, "PiP transfers its sender to the normal player")
	check(video.local_uri == "airplayvideo://7" and video.cast_token == 7 and owner.player_menu == owner.video_menu, "AirPlay uses the same video display and menu as DLNA")
	check(owner.cast_session.previous.uri.ends_with("ordinary.mp4") and owner.cast_session.previous.position == 42000, "Ordinary film return context survives mirror entry")
	check(not video._remember_file and not video._layer_wanted(), "Live source remains ephemeral and supports frame processing")
	check(not mirror.input_enabled(), "Hidden PiP cannot steal player ray input")
	video.media.state = "playing"; video._waiting_first = false
	video.media.playback = {"details": {"seekable": "no", "audio_tracks": [{"id": 1}]}}
	video.control.observe(5000, 0)
	check(not video.seek_relative(1000) and not video.set_playback_speed(1.5), "Live stream rejects seeking and speed changes at execution")
	var playing: int = bridge.playing.size()
	video.toggle_play()
	check(video.requested_play and bridge.playing.size() == playing, "Pause shortcut cannot pause live mirroring")
	var opens: int = bridge.calls.size()
	check(video.set_depth(true), "3D is available without a seekable timeline")
	check(video.set_depth(false) and video.set_alpha(true), "Normal portrait passthrough is available")
	check(bridge.calls.size() == opens and not bridge.revisions.is_empty(), "Effects revise the existing decoder without reopening the live pipe")
	video.media.playback = {"details": {"seekable": "no", "audio_tracks": [{"id": 1}]}}
	var menu := Menu.new(); root.add_child(menu)
	var state := Caps.apply({"has_video": true, "title": "AirPlay", "playing": true}, Caps.capabilities(video))
	menu.state_provider = func(): return state
	menu.show(); menu.refresh()
	check(not menu._buttons.any(func(b): return b.target in [101, 102, 103]), "Live menu hides previous, pause and next")
	check(not menu._buttons.any(func(b): return b.target == menu.SEEK), "Live menu has no draggable timeline")
	check(menu._buttons.any(func(b): return b.target == 104 and b.enabled) and menu._buttons.any(func(b): return b.target == 112 and b.enabled), "Normal player effect buttons are enabled")
	check(video.listening.available() and video.listening.set_option("listening_enabled", true), "Live PCM captions are available through the normal subtitle controls")
	video.listening.tick()
	check(bridge.speech.back() == [7, "ja"] and bridge.configurations.is_empty(), "Recognition consumes mirror PCM without a second MPV source")
	check(video.listening.text_at(5.0) == "Live speech" and video.listening.text_at(12.0).is_empty(), "Live captions display once and expire on the player's clock")
	var speech_count: int = bridge.speech.size()
	video.listening._poll_at = 0; video.listening.tick()
	check(bridge.speech.size() == speech_count, "Polling does not restart the recognition model")
	video._waiting_first = false; video.set_alpha(false)
	video.listening._poll_at = 0; video.listening.tick()
	check(video.listening.active() and bridge.speech.size() == speech_count, "Processing revision retains the active speech model and live source binding")
	var rows: Array = video.listening.rows(video.listening.snapshot())
	check(not rows.any(func(row): return row.get("title", "") == "Audio lookahead"), "Live captions do not offer unavailable lookahead")
	owner._close_current_media()
	check(not mirror.player_mode and not bridge.live and window.visible and video.cast_token == 0, "Normal player close returns to the same PiP")
	check(mirror.epoch == 7 and bridge.disconnects == 0 and window.global_transform.is_equal_approx(pose) and window.size == size, "Returning retains sender, placement and window size")
	check(bridge.speech.back() == [7, ""], "Closing player releases live recognition")
	owner.cast_session.restore()
	check(video.local_uri.ends_with("ordinary.mp4") and not video.requested_play and video.cast_token == 0, "Original film can be restored at its paused intent")
	video._waiting_first = false; video.media.state = "paused"; video.control.observe(42000, 120000)
	video.media.playback = {"details": {"seekable": "yes"}}
	video.toggle_play()
	check(video.requested_play and video.seek_relative(1000), "Ordinary playback still pauses, resumes and seeks after mirroring")
	video._pending_revision.clear(); video._waiting_first = false
	owner.cast_session.local_selection(); mirror._open_player()
	check(mirror.player_mode and video.local_uri == "airplayvideo://7", "Same sender can re-enter normal playback")
	video.open_local("http://192.0.2.1/new.mp4", "New", 0, false)
	bridge.live = false
	mirror.tick()
	check(video.local_uri.ends_with("new.mp4") and video.media.accepts(video.media.session_id) and not mirror.player_mode, "Late mirror failure cannot close a newer ordinary video")
	menu.free(); mirror.close(); mirror.free(); video.free()
	owner.photo.free(); owner.recent_menu.free(); owner.video_menu.free(); owner.airplay_session = null; owner.free()
	await process_frame
	for failure in failures: push_error(failure)
	print("AirPlay normal player: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
