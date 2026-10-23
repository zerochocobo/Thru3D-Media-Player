extends RefCounted
const Methods := preload("res://scripts/platform_methods.gd")
const Capabilities := preload("res://scripts/cast_capabilities.gd")
var host: Node
var platform: Object
var enabled := false
var token := 0
var pending := {}
var previous := {}
var status := {}
var _next_poll := 0
var _ui_key := ""
var _presented := 0

func bind(owner_node: Node, bridge: Object) -> void:
	host = owner_node; platform = bridge

func supported() -> bool:
	return Methods.supports(platform, "dlna_receiver_enable")

func snapshot() -> Dictionary:
	return {"supported": supported(), "enabled": enabled, "active": token > 0, "pending": pending.duplicate() if _presented == int(pending.get("token", 0)) else {}, "return_available": token == 0 and not previous.is_empty(), "name": status.get("name", "Thru3D"), "error": status.get("error", "")}

func refresh() -> void:
	if not is_instance_valid(host): return
	var state := snapshot()
	var key := str(state)
	if key == _ui_key: return
	if host.player_menu and host.player_menu.has_pointer_capture(): return
	if host.recent_menu.has_pointer_capture(): return
	_ui_key = key
	host.recent_menu.cast_state = state
	host.video_menu.cast_state = state
	host.recent_menu.refresh()
	host.video_menu.refresh()

func command(action: String) -> void:
	match action:
		"toggle":
			if not supported(): return
			if enabled:
				finish(); detach(); platform.dlna_receiver_enable(false); enabled = false
			else:
				enabled = platform.dlna_receiver_enable(true); status = {}
		"accept": accept()
		"reject":
			if not pending.is_empty(): platform.dlna_receiver_reject(int(pending.token))
			pending = {}
		"return": restore()
		"dismiss": previous = {}
	refresh()

## Typing (passwords, server or account fields) must never be interrupted by a LAN sender.
func _typing() -> bool:
	return host.recent_menu.has_method("text_entry_active") and host.recent_menu.text_entry_active()

func busy() -> bool:
	return host.video.media.accepts(host.video.media.session_id) or host.photo_active or (host.puzzle_game and host.puzzle_game.active) or host.recent_menu.voice_manager.opened

func _present_offer() -> void:
	if pending.is_empty() or _presented == int(pending.token): return
	if (host.puzzle_game and host.puzzle_game.active) or host.recent_menu.voice_manager.opened or _typing(): return
	if host.recent_menu.has_pointer_capture() or (host.player_menu and host.player_menu.has_pointer_capture()): return
	_presented = int(pending.token)
	if not busy(): accept()
	elif host.photo_active: host._show_full_library()
	else: host._show_player_menu()

func tick() -> void:
	if not enabled or Time.get_ticks_msec() < _next_poll: return
	_next_poll = Time.get_ticks_msec() + 200
	var data: Variant = JSON.parse_string(platform.dlna_receiver_poll())
	if not data is Dictionary: return
	status = data
	if token > 0 and int(data.get("active_token", 0)) != token: finish()
	if not pending.is_empty() and int(data.get("pending_token", 0)) != int(pending.token): pending = {}
	if data.is_empty(): enabled = false
	for event in data.get("events", []):
		if not event is Dictionary: continue
		if event.get("action") == "request":
			pending = event
		elif int(event.get("token", 0)) == token and token > 0:
			var video: Node = host.video
			match str(event.get("action")):
				"play":
					if not video.requested_play or video.media.state == "ended": video.toggle_play()
				"pause":
					if video.requested_play: video.toggle_play()
				"stop": finish()
				"seek": video.seek_absolute(int(event.position_ms))
				"volume": host._on_menu_volume(float(event.value), false)
				"mute": host._on_menu_volume(unmute_level(video), bool(event.value))
	_present_offer()
	if token > 0:
		var video: Node = host.video
		var state := "TRANSITIONING"
		if video.media.state in ["failed", "closed", "ended"]: state = "STOPPED"
		elif not video._waiting_first and video.media.state in ["playing", "paused", "ready"]: state = "PLAYING" if video.requested_play else "PAUSED_PLAYBACK"
		var caps := Capabilities.capabilities(video)
		platform.dlna_receiver_publish(JSON.stringify({"token": token, "state": state, "position_ms": video.control.observed_position_ms, "duration_ms": video.control.duration_ms, "seekable": caps.seek, "volume": video.system_volume.level() if video.system_volume.supported() else video.audio_volume, "muted": video.audio_muted or (video.system_volume.supported() and video.system_volume.level() == 0), "error": video.media.state == "failed"}))
	refresh()

## System volume reads 0 while muted; unmuting must return to the last audible level.
static func unmute_level(video: Node) -> float:
	if not video.system_volume.supported(): return video.audio_volume
	return video.system_volume.last_nonzero if video.audio_muted or video.audio_volume <= 0 else video.audio_volume

func accept() -> void:
	if pending.is_empty(): return
	# Independent editors/games must be closed by the user, never discarded by a LAN sender.
	if (host.puzzle_game and host.puzzle_game.active) or host.recent_menu.voice_manager.opened or _typing(): return
	var offer: Variant = JSON.parse_string(platform.dlna_receiver_accept(int(pending.token)))
	pending = {}
	if not offer is Dictionary or offer.is_empty(): return
	if token == 0 and previous.is_empty():
		var viewer: Node = host._viewer()
		if host.photo_active or host.video.media.accepts(host.video.media.session_id):
			previous = {"photo": host.photo_active, "uri": viewer.local_uri, "title": viewer.display_name, "position": host.video.control.observed_position_ms, "playing": host.video.requested_play,
				"queue": host.video_queue.duplicate(true), "queue_context": host.video_queue_pages.context.duplicate(true), "mode": host.video.capture_cast_view(), "playback_mode": host.playback_mode,
				"metadata": host.video._bookmark_metadata.duplicate(true), "location": viewer.source_location.duplicate(true)}
			if host.photo_active:
				previous.photo_queue = host.photo.queue.duplicate(true)
				previous.photo_directory = host.photo.directory._context.duplicate(true)
	host._cancel_video_queue_wait()
	if host.video_directory: host.video_directory.cancel()
	host.video_queue_pages.cancel(); host.video_queue_pages.context = {}; host.video_queue.clear()
	host.photo.close_image(); host.photo_active = false; host.player_menu = host.video_menu
	host.recent_menu.dismiss(); host.video_menu.dismiss()
	host._prepare_cast_switch()
	host.stick_controls.suspend()
	host.video.close_video()
	token = int(offer.token)
	host.playback_mode = "single"
	host.video.open_cast(str(offer.uri), str(offer.title), token, int(offer.get("start_ms", 0)))
	host._show_player_menu()
	refresh()

func detach() -> void:
	if supported(): platform.dlna_receiver_detach()
	token = 0; pending = {}; _presented = 0; host.video.cast_token = 0
	refresh()

func local_selection() -> void:
	detach(); previous = {}
	refresh()

## Phone Stop / lost ownership: end only this cast. A newer offer from the same
## poll batch (Stop → SetAVTransportURI → Play) must stay acceptable.
func finish() -> void:
	var ended := token
	if ended > 0 and Methods.supports(platform, "dlna_receiver_finish"): platform.dlna_receiver_finish(ended)
	token = 0; host.video.cast_token = 0
	if ended > 0: host._close_current_media()
	refresh()

func restore() -> void:
	if token > 0 or previous.is_empty(): return
	var saved := previous.duplicate(true)
	previous = {}
	host._prepare_cast_switch()
	host.recent_menu.dismiss()
	host.photo_active = saved.photo
	if saved.photo:
		host.player_menu = host.photo_menu
		host.photo.open_image(str(saved.uri), str(saved.title), saved.photo_queue, saved.location)
		host.photo.start_directory(saved.photo_directory)
	else:
		host.player_menu = host.video_menu
		host.video_queue.assign(saved.queue); host.video_queue_pages.context = saved.queue_context
		host.playback_mode = saved.playback_mode
		host.video.requested_play = bool(saved.playing)
		# Reuse the still-granted source and metadata, independent of the current library folder.
		host.video.open_local(str(saved.uri), str(saved.title), int(saved.position), true, false, "", saved.metadata)
		host.video.restore_cast_view(saved.mode)
	host._show_player_menu()
	refresh()

func close() -> void:
	if supported(): platform.dlna_receiver_enable(false)
	enabled = false; token = 0; pending = {}; previous = {}
