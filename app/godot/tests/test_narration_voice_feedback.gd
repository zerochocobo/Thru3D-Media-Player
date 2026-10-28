extends SceneTree
const Video := preload("res://scripts/mpv_video_display.gd")
const Menu := preload("res://scripts/player_menu.gd")
const Memory := preload("res://scripts/file_narration_memory.gd")
const ID := "custom:12345678-1234-1234-1234-123456789abc"
const VOICE := {"id": ID, "name": "晚霞"}
var checks := 0
var failures: Array[String] = []
class Host extends RefCounted:
	var playing: Array = []
	var commands: Array = []
	var global_state: Dictionary = {}
	var state := {"revision": 1, "state": "preparing", "voices": [], "voices_ready": false}
	func set_mpv_playing(_id: int, value: bool) -> void: playing.append(value)
	func close_mpv_video(_id: int) -> void: pass
	func set_mpv_narration(_id: int, _json: String) -> bool: return true
	func mpv_voice_clone_status(_id: int) -> String: return JSON.stringify(state)
	func narration_voice_manager_status() -> String: return JSON.stringify(global_state if not global_state.is_empty() else state)
	func narration_voice_manager_request(json: String) -> bool: commands.append(JSON.parse_string(json)); return true
	func mpv_voice_clone_request(_id: int, json: String) -> bool:
		var command: Dictionary = JSON.parse_string(json); commands.append(command)
		state.operation = command.operation; state.state = "preparing"
		if command.operation == "list": state.voices_ready = false
		if command.operation == "preview": state.preview_id = command.id
		return true
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)
func poll(video: Node, host: Host, state: Dictionary) -> Dictionary:
	host.state.merge(state, true); video.narration._clone_poll_at = 0
	return video.narration.snapshot()
func _initialize() -> void: call_deferred("_run")
func _run() -> void:
	var host := Host.new(); var video := Video.new(); root.add_child(video); video.set_process(false); video.platform = host
	video.narration.memory = Memory.new(ProjectSettings.globalize_path("res://../../build/output/voice-feedback/%d" % Time.get_ticks_usec()))
	video.local_uri = "file:///voice-feedback.mp4"; video.media.begin(11); video.media.state = "playing"
	video.media.playback = {"details": {"subtitle_tracks": [{"id": 1, "codec": "subrip", "language": "zh"}]}, "narration": {"state": "off"}}
	video.subtitles.select(1)
	var config := ConfigFile.new(); config.set_value("narration", "voice_kind", "custom"); config.set_value("narration", "custom_voice", ID)
	video.requested_play = true; video.narration.load_settings(config); video.narration.reset_source(video.local_uri)
	var state: Dictionary = video.narration.snapshot()
	check(video.requested_play and host.playing.is_empty(), "Background catalog reads never pause the movie")
	check(state.narration_voice_kind == "custom" and state.narration_custom_voice == ID, "Pending empty catalog preserves remembered custom voice")
	state = poll(video, host, {"state": "ready", "voices": [VOICE], "voices_ready": true, "voices_revision": 2})
	check(state.narration_personal_voices == [VOICE] and state.narration_custom_voice == ID, "Completed catalog exposes the selected saved voice")
	host.global_state = {"state": "ready", "voices": [], "voices_ready": true, "voices_revision": 1}
	var global_state: Dictionary = video.narration.voice_manager_snapshot()
	check(global_state.narration_personal_voices == [VOICE] and global_state.narration_custom_voice == ID, "Older global manager catalog cannot erase a voice just saved by the video controller")
	host.global_state.clear()
	video.narration.enabled = true
	var ui := state.duplicate(true); ui.merge({"has_video": true, "source_uri": video.local_uri, "subtitle_options": [{"id": 1, "codec": "subrip"}], "subtitle_track": 1, "narration_enabled": true, "narration_personal_voices": []}, true)
	var menu := Menu.new(); menu.state_provider = func(): return ui
	root.add_child(menu); menu.toggle(); menu.set_process(false); menu._subtitle_open = true; menu._set_subtitle_detail("narration"); menu.refresh()
	check(not menu.choices.targets.values().any(func(item): return item.get("key", "") == "narration_custom_voice"), "A still-loading empty chooser starts hidden")
	ui.narration_personal_voices = [VOICE]; menu.refresh_values()
	check(menu.choices.targets.values().any(func(item): return item.get("key", "") == "narration_custom_voice"), "Late catalog arrival redraws without toggling categories or a new backend revision")
	check(menu.text_snapshot().contains(VOICE.name), "Restored voice name is selected in the visible chooser")
	video.narration.save(config)
	video.narration.reset_source("file:///other-feedback.mp4")
	check(not video.narration.enabled and video.narration.selected_voice() == ID, "Another movie inherits the default voice with narration Off")
	video.narration.reset_source(video.local_uri)
	video.media.begin(12)
	state = poll(video, host, {"state": "preparing", "voices": [], "voices_ready": false})
	check(state.narration_personal_voices == [VOICE] and state.narration_custom_voice == ID and video.narration.enabled, "Reopen keeps cached catalog, per-film voice and On while disk read is pending")
	state = poll(video, host, {"state": "ready", "voices": [VOICE], "voices_ready": true})
	video.narration.custom_voice = ""; video.narration.set_option("narration_voice_kind", "custom")
	check(video.narration.custom_voice == ID, "Custom category selects an available saved/default voice")
	video.narration.set_option("narration_voice", "Yuewen")
	state = poll(video, host, {"state": "saved", "saved": VOICE, "save_request": 999})
	check(state.narration_voice == "Yuewen", "Stale save receipt cannot overwrite a later preset choice")
	video.narration.clone_command({"operation": "save", "key": "fixture", "name": VOICE.name})
	state = poll(video, host, {"state": "saved", "saved": VOICE, "save_request": host.commands.back().request})
	check(state.narration_voice == ID and state.narration_custom_voice == ID, "Current save receipt selects the newly saved voice")
	video.requested_play = true
	check(video.narration.set_option("narration_preview", true), "Custom audition starts")
	check(not video.requested_play and host.playing.back() == false, "Custom audition pauses playback immediately")
	for phase in ["preparing", "model_verifying", "model_loading", "generating", "playing_clone"]:
		state = poll(video, host, {"operation": "preview", "state": phase, "preview_id": ID})
		check(state.narration_preview_busy and not state.narration_preview_status.is_empty(), "Custom audition always has feedback and a stop action: " + phase)
		ui.merge(state, true); menu.refresh_values()
		check(menu._narration_status() == menu.I18n.t(state.narration_preview_status), "Menu follows the audition instead of suspended narration: " + phase)
	video.media.playback.narration = {"state": "loading", "model_phase": "loading"}
	state = poll(video, host, {"state": "ready"})
	check(state.narration_preview_status == "Voice preview finished" and not state.narration_preview_busy, "Completion hides the resumed narrator's unrelated model-loading state")
	state = poll(video, host, {"state": "error", "error": "Unable to load narration model"})
	check(state.narration_preview_status == "Unable to load narration model", "Audition errors remain visible")
	video.requested_play = true; state = video.narration.snapshot()
	check(state.narration_preview_status.is_empty(), "Resuming the movie restores normal narration feedback")
	video.narration.set_option("narration_voice", "Yuewen")
	video.media.playback.narration = {"state": "ready", "preview": false, "preview_request": video.narration.preview}
	video.narration.set_option("narration_preview", true)
	state = video.narration.snapshot()
	check(not video.requested_play and state.narration_preview_status == "Preparing voice preview…", "Preset audition pauses and acknowledges immediately before backend status arrives")
	state = poll(video, host, {"operation": "preview", "state": "model_loading", "preview_id": "Yuewen"})
	check(state.narration_preview_status == "Loading narration model…", "Preset audition shows shared-runtime model loading")
	state = poll(video, host, {"state": "ready"})
	check(state.narration_preview_status == "Voice preview finished", "Preset completion has explicit feedback")
	state = poll(video, host, {"state": "error", "error": "Unable to load narration model"})
	check(state.narration_preview_status == "Unable to load narration model", "Failed preset preparation is not reported as completed")
	for command in [{"operation": "list", "pause": true}, {"operation": "preview", "id": ID}, {"operation": "original", "key": "a"}, {"operation": "clone", "key": "a"}]:
		video.requested_play = true; video.narration.clone_command(command)
		check(not video.requested_play, "Voice configuration and audition pause video: " + command.operation)
	video.requested_play = true; video.narration.global_voice_command({"operation": "preview", "id": ID})
	check(not video.requested_play, "Global manager audition pauses an active video")
	ui.merge({"narration_preview_status": "", "narration_clone_state": {"operation": "clone", "state": "model_loading", "active_key": "a", "candidates": [{"key": "a", "start": 0, "end": 3, "text": "晚霞"}]}}, true)
	menu.clone_panel.opened = true; menu.clone_panel.source = ui.source_uri; menu.refresh()
	var status_labels: Array = menu._labels.filter(func(node): return node.text == menu.I18n.t("Loading narration model…"))
	check(status_labels.size() == 1 and is_zero_approx(status_labels[0].position.x) and status_labels[0].horizontal_alignment == HORIZONTAL_ALIGNMENT_CENTER, "Clone task status is centered in a dedicated footer")
	var stop_targets: Array = menu.clone_panel.actions.keys().filter(func(target): return menu.clone_panel.actions[target].operation == "stop")
	check(stop_targets.size() == 1 and status_labels[0].position.y > menu._buttons.filter(func(button): return menu.clone_panel.actions.get(button.target, {}).get("operation", "") == "candidates").back().node.position.y and status_labels[0].position.y < menu._buttons.filter(func(button): return button.target == stop_targets[0])[0].node.position.y, "Model loading remains stoppable and status uses the gap between rows and paging without growing the panel")
	menu.free(); video.queue_free(); await process_frame
	print("Voice feedback checks=%d failures=%d" % [checks, failures.size()])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)
