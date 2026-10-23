extends SceneTree
const Video := preload("res://scripts/mpv_video_display.gd")
const Menu := preload("res://scripts/player_menu.gd")
const Library := preload("res://scripts/library_menu.gd")
const Session := preload("res://scripts/cast_session.gd")
const Caps := preload("res://scripts/cast_capabilities.gd")
const CastPanel :=  preload("res://scripts/cast_panel.gd")
var checks := 0
var failures: Array[String] = []

class Bridge extends "res://tests/test_file_mode_memory.gd".Host:
	var enabled := false
	var offer := {}
	var batch: Array = []
	var active := 0
	var rejected: Array = []
	var published := {}
	var revisions: Array = []
	func dlna_receiver_enable(value: bool) -> bool: enabled = value; return true
	func dlna_receiver_poll() -> String:
		var result := {"running": enabled, "events": batch.duplicate(), "pending_token": offer.get("token", 0), "active_token": active}
		batch.clear(); return JSON.stringify(result)
	func dlna_receiver_accept(id: int) -> String:
		if id != offer.get("token", 0): return "{}"
		active = id; var result := JSON.stringify(offer); offer = {}; return result
	func dlna_receiver_reject(id: int) -> void: rejected.append(id); offer = {}
	func dlna_receiver_detach() -> void: active = 0; offer = {}; batch.clear()
	func dlna_receiver_finish(id: int) -> void: active = 0 if active == id else active
	func dlna_receiver_publish(value: String) -> void: published = JSON.parse_string(value)
	func revise_mpv_video(_id: int, stereo: bool, alpha: bool, _profile: String, position: int, depth: bool = false, _tb: bool = false, _exact: bool = false) -> int:
		revisions.append({"depth": depth, "alpha": alpha, "stereo": stereo, "position": position}); next_id += 1; return next_id
	func send(id: int) -> void:
		offer = {"action": "request", "token": id, "uri": "http://192.168.1.20/movie.mp4", "title": "Phone video", "start_ms": 12000}
		batch.append(offer.duplicate())

class VolumeBridge extends Bridge:
	func system_media_volume() -> String: return "{}"
	func set_system_media_volume(_percent: float, _show_ui: bool) -> int: return 0

class StubMenu extends Node3D:
	var cast_state := {}
	var voice_manager := {"opened": false}
	var captured := false
	var typing := false
	func text_entry_active() -> bool: return typing
	func refresh() -> void: pass
	func dismiss() -> void: hide()
	func has_pointer_capture() -> bool: return captured

class Photo extends Node3D:
	var local_uri := ""
	var display_name := ""
	func close_image() -> void: local_uri = ""

class Owner extends Node:
	var video: Node3D
	var photo := Photo.new()
	var photo_active := false
	var puzzle_game: Node = null
	var recent_menu := StubMenu.new()
	var video_menu := StubMenu.new()
	var player_menu: Node3D
	var video_directory: Node = null
	var video_queue_pages := preload("res://scripts/video_queue_pages.gd").new()
	var video_queue: Array[Dictionary] = []
	var stick_controls := preload("res://scripts/player_stick_controls.gd").new()
	var playback_mode := "sequence"
	var restored: Array = []
	func _viewer() -> Node3D: return photo if photo_active else video
	func _cancel_video_queue_wait() -> void: pass
	func _prepare_cast_switch() -> void: pass
	func _show_full_library() -> void: recent_menu.show()
	func _show_player_menu() -> void: player_menu.show()
	func _close_current_media() -> void: video.close_video()
	func _on_library_chosen(uri: String, title: String) -> void:
		restored.append([uri, title]); video.open_library(uri, title)
	func _on_menu_volume(value: float, muted: bool) -> void: video.audio_volume = value; video.audio_muted = muted
	func dispose() -> void: photo.free(); recent_menu.free(); video_menu.free(); queue_free()

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func poll(session: RefCounted) -> void:
	session._next_poll = 0; session.tick()

func _initialize() -> void: call_deferred("run")

func run() -> void:
	preload("res://scripts/i18n.gd").use("en")
	var bridge := Bridge.new()
	var video := Video.new(); root.add_child(video); video.platform = bridge; video.set_process(false)
	video.history_enabled = false
	var owner := Owner.new(); owner.video = video; owner.player_menu = owner.video_menu
	var session := Session.new(); session.bind(owner, bridge); session.command("toggle")
	video.open_local("http://192.168.1.8/original.mp4", "Original", 0, false)
	video.requested_play = false; video.control.observe(43000, 120000)
	video.depth_requested = true; video.auto_depth = true
	owner.video_queue.assign([{"uri": video.local_uri, "title": "Original"}])
	owner.video_menu.captured = true
	bridge.send(1); poll(session)
	check(session.snapshot().pending.is_empty(), "Incoming request waits for a pointer drag to finish")
	owner.video_menu.captured = false; poll(session)
	check(session.token == 0 and session.pending.token == 1, "Busy source waits for headset decision")
	check(video.local_uri.ends_with("original.mp4") and not video.requested_play, "Offer does not start or replace paused movie")
	session.command("reject")
	check(bridge.rejected == [1] and video.control.observed_position_ms == 43000, "Ignore retains old progress")
	bridge.send(2); poll(session); session.command("accept")
	check(session.token == 2 and video.cast_token == 2 and video.local_uri.ends_with("movie.mp4"), "Accept opens in the existing video display")
	check(bridge.calls.back()[1] == 12000, "Sender start position wins over file history")
	check(session.previous.position == 43000 and not session.previous.playing, "Return context preserves paused source and position")
	check(owner.video_queue.is_empty() and owner.playback_mode == "single", "Old directory queue cannot advance cast")
	check(not video._remember_file and not video._layer_wanted(), "Ephemeral source has no persisted identity and starts with accessible frames")
	check(not video.depth_requested and not video.stereo_sbs, "New cast starts as flat mono, not the previous film mode")
	check(not video.set_depth(true) and not video.seek_relative(1000), "Unknown stream cannot enable AI or seek")
	video.control.observe(12000, 120000)
	video.media.playback = {"details": {"seekable": "yes", "partially_seekable": "no", "audio_tracks": [{"id": 1}]}}
	video._waiting_first = false; video.media.state = "paused"; video.requested_play = false
	poll(session)
	check(bridge.published.state == "PAUSED_PLAYBACK" and bridge.published.position_ms == 12000, "Phone receives actual headset pause and progress")
	bridge.batch.append({"action": "volume", "token": 2, "value": 37}); poll(session)
	check(video.audio_volume == 37, "Accepted sender controls headset volume")
	var volume_bridge := VolumeBridge.new(); video.platform = volume_bridge
	video.audio_muted = true; video.audio_volume = 0; video.system_volume.last_nonzero = 64
	check(Session.unmute_level(video) == 64, "Phone unmute restores the last audible system volume")
	video.audio_muted = false; video.audio_volume = 37
	check(Session.unmute_level(video) == 37, "Unmuted system volume keeps its level")
	video.platform = bridge
	var opens := bridge.calls.size()
	check(video.set_depth(true), "Seekable flat cast can enable 2D to 3D")
	video._try_revision()
	check(bridge.calls.size() == opens and bridge.revisions.back().depth, "3D changes processing generation without reopening URL")
	check(video.cast_token == 2 and not video.requested_play, "3D keeps cast identity and paused intent")
	check(video.set_depth(false), "Can return to 2D")
	video._try_revision()
	check(bridge.calls.size() == opens, "Return to 2D does not reconnect phone server")
	video.stereo_sbs = true
	check(not video.set_depth(true), "Native stereo is not converted again")
	video.stereo_sbs = false
	check(not video.captures.ready(), "Unverified original-source exports are blocked at execution")
	check(video.bookmark_action("add", "", "").is_empty(), "Transient cast cannot write persistent bookmarks")
	var menu := Menu.new(); root.add_child(menu)
	var state := {"has_video": true, "title": "Phone video", "duration_ms": 120000, "position_ms": 12000, "geometry": 0, "stereo": false, "playing": true, "playback_state": "playing", "subtitle_browse_available": true}
	state = Caps.apply(state, Caps.capabilities(video)); menu.state_provider = func(): return state
	menu.show(); menu.refresh()
	for target in [101, 103, menu.FAVORITE, menu.CAPTURE]:
		check(not menu._buttons.any(func(b): return b.target == target), "Unsupported cast button hidden: %d" % target)
	check(menu._buttons.any(func(b): return b.target == 112 and b.enabled), "2D to 3D remains on cast bar")
	check(menu._buttons.any(func(b): return b.target == 100), "Library remains available")
	check(menu._setting_choices("loop").get("choices", []).size() == 2, "Only single/repeat-one remain without cast queue")
	var main := preload("res://scripts/main.gd").new(); main.video = video; main.playback_mode = "single"
	main._cycle_playback_mode()
	check(main.playback_mode == "repeat_one" and video.loop_enabled, "Cast loop shortcut enters repeat-one without a directory queue")
	main._cycle_playback_mode()
	check(main.playback_mode == "single" and not video.loop_enabled, "Cast loop shortcut returns to single")
	main.free()
	video.media.state = "ended"; video.requested_play = true
	var eof_sequence: int = video.control.sequence
	bridge.batch.append({"action": "play", "token": 2}); poll(session)
	check(video.control.sequence > eof_sequence, "Phone Play after EOF restarts the current movie")
	video.media.playback = {"details": {"seekable": "no"}}; video.control.duration_ms = 0
	check(not video.seek_relative(1000) and not video.set_depth(true) and not video.set_playback_speed(2.0), "Live capability changes block actual seek, 3D and speed operations")
	state.cast = {"seek": false, "effects": false}; state.duration_ms = 0
	menu.refresh(); check(not menu._can_seek() and not menu._can_depth(), "Live stream disables timeline and AI controls")
	menu.section = 1; menu.refresh()
	check(not menu._buttons.any(func(b): return b.target == 453), "Live source has no speed slider")
	var library := Library.new(); root.add_child(library)
	library.cast_state = {"pending": {"title": "New video"}}; library.refresh()
	check(library._buttons.any(func(b): return b.target == CastPanel.ACCEPT) and library._buttons.any(func(b): return b.target == CastPanel.REJECT), "Busy photo/library prompt has accept and ignore ray buttons")
	session.finish(); session.restore()
	check(video.local_uri.ends_with("original.mp4") and not video.requested_play, "Return restores original paused movie")
	check(bridge.calls.back()[1] == 43000 and video.auto_depth, "Return restores exact in-memory position and 3D choice")
	check(owner.video_queue.size() == 1 and owner.playback_mode == "sequence", "Return restores directory queue and playback mode")
	bridge.send(4); poll(session); session.command("accept")
	bridge.batch.append({"action": "pause", "token": 2}); session.local_selection(); poll(session)
	check(session.token == 0 and session.previous.is_empty() and bridge.active == 0, "Local selection revokes remote control and return context")
	bridge.batch.append({"action": "seek", "token": 4, "position_ms": 90000}); var before := video.control.sequence; poll(session)
	check(video.control.sequence == before, "Stale phone seek cannot reach local media")
	video.close_video(); bridge.send(3); poll(session)
	check(session.token == 3, "Closed media's retained URI does not falsely trigger busy confirmation")
	bridge.batch.append({"action": "stop", "token": 3}); bridge.send(5); poll(session)
	check(session.token == 5 and bridge.active == 5 and video.cast_token == 5, "Phone Stop then new URI in one poll switches to the new cast")
	session.finish(); check(video.media.session_id <= 0 and session.token == 0, "Ending cast releases media and ownership")
	owner.recent_menu.typing = true; bridge.send(6); poll(session)
	check(session.token == 0 and int(session.pending.get("token", 0)) == 6 and session.snapshot().pending.is_empty(), "Typing defers an idle cast instead of interrupting input")
	owner.recent_menu.typing = false; poll(session)
	check(session.token == 6, "Deferred cast starts once typing ends")
	session.finish()
	session.close(); menu.free(); library.free(); video.free(); owner.dispose()
	await process_frame
	for message in failures: push_error(message)
	print("Cast receiver: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
