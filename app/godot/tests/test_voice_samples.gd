extends SceneTree
const Library := preload("res://scripts/library_menu.gd")
const Video := preload("res://scripts/mpv_video_display.gd")
const Sample := preload("res://scripts/voice_sample_panel.gd")
const Host := preload("res://tests/test_narration_clone.gd").Host
class VoiceEntryMain extends "res://scripts/main.gd":
	var library_shown := false
	func _show_full_library() -> void: library_shown = true
var failures: Array[String] = []
var checks := 0
func check(value: bool, message: String) -> void:
	checks += 1
	if not value: failures.append(message); push_error(message)
func _initialize() -> void: call_deferred("_run")
func _run() -> void:
	check(is_equal_approx(Sample.parse_time("00:10:12.3"), 612.3), "Timestamp precision")
	check(Sample.parse_time("600") == 600, "Seconds input")
	for bad in ["", "NaN", "-1", "1:60", "1:2:3:4", "abc"]: check(Sample.parse_time(bad) < 0, "Reject invalid time " + bad)
	var backend := {"state": "ready", "source_ready": true, "duration": 1200.0, "audio_id": 2, "audio_options": [{"id": 2, "language": "en"}, {"id": 5, "language": "ja"}], "candidates": [], "voices": []}
	var ui := {"source_uri": "global-voice-manager", "global_voice_manager": true, "narration_clone_supported": true, "narration_current_uri": "file:///current.mp4", "narration_clone_state": backend, "narration_personal_voices": []}
	var menu := Library.new(); menu.settings_provider = func(): return {"voice_manager": ui}
	root.add_child(menu); menu.set_process(false); menu.visible = true; menu.section = menu.Section.SETTINGS; menu.tab = menu.VIDEO_TAB
	var events: Array = []; menu.setting_changed.connect(func(key, value): events.append([key, value]))
	menu._state = ui; menu.voice_manager.open(true)
	var sample: RefCounted = menu.voice_manager.sample
	check(menu.voice_manager.actions.values().any(func(v): return v.operation == "add_sample"), "Global manager offers addition without subtitles")
	sample.begin()
	check(menu.voice_picker_mode and not menu.voice_manager.opened, "Add voice goes directly to video selection")
	menu.finish_voice_picker("file:///selected.mp4", "Selected video")
	check(events.back()[1].operation == "open_source" and events.back()[1].uri == "file:///selected.mp4", "Selected video uses independent source")
	menu.refresh(); check(sample.audio_id == 2 and sample.duration == 1200, "Probe metadata reaches UI")
	check(menu.choices.targets.values().any(func(v): return v.get("key", "") == "voice_sample_track") and menu.choices.targets.values().any(func(v): return v.get("key", "") == "voice_sample_language"), "Track and preview language are directly visible")
	check(not menu.voice_manager.actions.values().any(func(v): return v.operation in ["sample_mode", "sample_current"] or v.get("key", "") == "finish"), "Unified setup has no mode, current video or end-time controls")
	var previous_revision: int = menu._voice_revision
	backend.revision = previous_revision + 1; menu._voice_drag = {"hand": "left"}; menu._process(0.016)
	check(menu._voice_revision == previous_revision, "Incoming scan results cannot replace a captured row")
	menu._voice_drag.clear(); menu._process(0.016)
	check(menu._voice_revision == backend.revision, "Deferred scan results refresh after release")
	sample.choose("voice_sample_start", 100)
	sample.action({"operation": "sample_preset", "seconds": 600}); check(sample.valid_range() and sample.finish == 700, "Ten minutes from chosen start determines end")
	sample.action({"operation": "sample_step", "amount": 30.0})
	check(sample.start == 130 and sample.finish == 730, "Moving start preserves scan duration")
	sample.action({"operation": "sample_run"})
	check(events.back()[1].operation == "scan" and events.back()[1].audio_id == 2 and events.back()[1].end == 730, "Unified search uses computed end and selected audio")
	backend.candidates = [{"key": "a", "start": 50.0, "end": 58.0, "timing": "audio"}, {"key": "b", "start": 60.0, "end": 66.0, "timing": "audio"}]
	backend.ready_key = "a"; menu.refresh()
	check(not menu.voice_manager.actions.values().any(func(v): return v.operation in ["sample_trim", "sample_loop"]), "No adjustment page or loop button")
	var first_play := -1
	for id in menu.voice_manager.actions:
		if menu.voice_manager.actions[id].operation == "original": first_play = id; break
	menu.voice_manager.activate(first_play)
	check(events.back()[1].operation == "original" and not events.back()[1].has("loop"), "Clicking a candidate auditions its original once")
	var slider_id := -1
	for id in menu.choices.targets:
		if menu.choices.targets[id].get("key", "") == "voice_sample_crop:a": slider_id = id
	check(slider_id >= 0, "Each candidate has an inline range slider")
	var slider: Dictionary = menu.choices.sliders[slider_id]
	var button: Dictionary = menu._buttons.filter(func(v): return v.target == slider_id)[0]
	var press: Vector3 = button.node.to_global(Vector3(slider.handles[0].position.x, 0, 1))
	var drag: Vector3 = button.node.to_global(Vector3(slider.left + slider.width, 0, 1))
	var before := events.size()
	menu.press_pointer("left_hand", press, -menu.global_basis.z, true)
	menu.update_pointer("left_hand", drag, -menu.global_basis.z, true)
	check(menu.has_pointer_capture() and is_equal_approx(menu.choices.capture.value.y - menu.choices.capture.value.x, 3), "Dragging start cannot leave less than three seconds")
	check(not events.slice(before).any(func(v): return v[1].get("operation", "") == "trim"), "Dragging previews without submitting repeated crop jobs")
	menu.release_pointer("right_hand", drag, -menu.global_basis.z, true)
	check(menu.has_pointer_capture(), "Other hand cannot commit the range")
	menu.release_pointer("left_hand", drag, -menu.global_basis.z, true)
	check(events.back()[1].operation == "trim" and events.back()[1].key == "a" and is_equal_approx(events.back()[1].start, 55.0) and is_equal_approx(events.back()[1].end, 58.0), "Owner release commits the cropped source times")
	check(sample.page == "results" and backend.candidates.size() == 2, "Crop stays in the same list and preserves other candidates")
	check(not sample.pending_crop.is_empty() and menu._buttons.filter(func(v): return menu.voice_manager.actions.get(v.target, {}).get("operation", "") == "save_name").all(func(v): return not v.enabled), "Old clone cannot be saved while crop is pending")
	backend.candidates[0].original_start = 50.0; backend.candidates[0].original_end = 58.0; backend.candidates[0].start = 55.0; backend.ready_key = ""; menu.refresh()
	check(sample.pending_crop.is_empty(), "Acknowledged bounds release pending edit")
	check(menu.voice_manager.actions.values().any(func(v): return v.operation == "sample_reset_clip" and v.key == "a"), "Only changed candidate gets a reset action")
	sample.action({"operation": "sample_reset_clip", "key": "a"})
	check(events.back()[1].operation == "trim" and events.back()[1].start == 50 and events.back()[1].end == 58, "Reset sends the original range")
	backend.candidates[0].start = 50.0; menu.refresh()
	check(not menu.voice_manager.actions.values().any(func(v): return v.operation == "sample_reset_clip"), "Reset action disappears after restoring original times")
	var fields := preload("res://scripts/choice_fields.gd")
	check(fields.trim_range(Vector2(51, 57), 1, 49, Vector3(50, 58, 0.01), 3) == Vector2(51, 54), "End handle also enforces the three second gap")
	check(fields.trim_range(Vector2(51, 57), 0, 40, Vector3(50, 58, 0.01), 3) == Vector2(50, 57), "Start cannot extend outside original clip")
	check(fields.trim_range(Vector2(51, 57), 1, 70, Vector3(50, 58, 0.01), 3) == Vector2(51, 58), "End cannot extend outside original clip")
	sample.action({"operation": "sample_setup"})
	check(sample.start == 130 and sample.finish == 730 and sample.scan_seconds == 600, "Returning from adjusted clip restores original search range")
	sample.choose("voice_sample_start", 1190)
	check(sample.start == 1190 and sample.finish == 1200 and sample.scan_seconds == 600, "Search is capped at video end without changing duration preset")
	sample.duration = 4; sample.start = 1; sample.finish = 7; sample._clamp_range(); check(sample.finish <= 4, "Clamp to source duration")
	sample.duration = 2; sample._clamp_range(); check(not sample.valid_range(), "Short source cannot produce three seconds")
	sample.begin()
	check(menu.voice_picker_mode and not menu.voice_manager.opened and menu.media_filter == 1, "Video picker excludes images")
	check(menu._browse_scope().is_empty(), "Sampling never saves browse position")
	var chosen: Array = []; menu.chosen.connect(func(uri, _title): chosen.append(uri))
	menu._choose({"uri": "file:///chosen.mp4", "title": "Chosen", "kind": "video"})
	check(chosen.is_empty(), "Selecting a sample never invokes normal playback")
	check(not menu.voice_picker_mode and menu.voice_manager.opened and menu.section == menu.Section.SETTINGS, "Picker restores manager context")
	check(events.back()[1].operation == "open_source" and events.back()[1].uri == "file:///chosen.mp4", "Chosen source reaches clone controller")
	sample.begin(); menu.dismiss(); check(menu.voice_manager.opened and menu.voice_manager.library and not sample.active, "Picker cancellation returns directly to My voices")
	menu.voice_manager.close(); menu.free()
	var video := Video.new(); var host := Host.new(); video.platform = host; video.media.session_id = 4; video.local_uri = "file:///no-subtitles.mp4"
	root.add_child(video); video.set_process(false)
	check(video.narration.clone_command({"operation": "open", "mode": "speech"}), "Current source opens without subtitles")
	check(not video.narration.clone_command({"operation": "open", "mode": "subtitles"}), "Original subtitle path still requires captions")
	var id := "custom:12345678-1234-1234-1234-123456789abc"
	video.narration._clone_session = 4; video.narration._clone_identity_session = 4
	video.narration.clone_command({"operation": "save", "key": "a", "name": "Test", "apply": false})
	host.state = {"voices": [{"id": id, "name": "Test"}], "voices_ready": true, "saved": {"id": id}, "save_request": host.commands.back().request}
	video.narration._clone_poll_at = 0; video.narration._poll_clone()
	check(video.narration.custom_voice != id and not video.narration.enabled, "Save-only preserves playback voice and narration toggle")
	video.narration._global_voice_started = true
	video.narration.global_voice_command({"operation": "save", "key": "a", "name": "Test", "apply": false})
	host.state.save_request = host.global_commands.back().request
	video.narration._global_voice_poll_at = 0; video.narration.voice_manager_snapshot()
	check(video.narration._defaults.get("custom_voice", "") != id, "Global save-only preserves default")
	video.narration.global_voice_command({"operation": "save", "key": "a", "name": "Test", "apply": true})
	host.state.save_request = host.global_commands.back().request
	video.narration._global_voice_poll_at = 0; video.narration.voice_manager_snapshot()
	check(video.narration._defaults.get("custom_voice", "") == id and not video.narration.enabled, "Explicit save-and-use selects default without enabling narration")
	var entry := VoiceEntryMain.new(); var picker := Library.new()
	picker.settings_provider = func(): return {"voice_manager": ui}
	root.add_child(picker); picker.set_process(false); picker.visible = true
	entry.video = video; entry.recent_menu = picker
	entry._on_player_setting("narration_add_voice", true)
	check(entry.library_shown and picker.voice_picker_mode and not picker.voice_manager.opened, "Player addition uses the same global video picker")
	picker.finish_voice_picker(); picker.voice_manager.close(); picker.free(); entry.free()
	video.media.session_id = 0; video.free()
	print("Voice sample checks=%d failures=%d" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
