extends SceneTree
const Video := preload("res://scripts/mpv_video_display.gd")
const Menu := preload("res://scripts/player_menu.gd")
const Library := preload("res://scripts/library_menu.gd")
const VoiceMemory := preload("res://scripts/file_narration_memory.gd")
const ID := "custom:12345678-1234-1234-1234-123456789abc"
var checks := 0
var failures: Array[String] = []
class Host extends RefCounted:
	var playing: Array = []
	var commands: Array = []
	var payloads: Array = []
	var global_commands: Array = []
	var state := {"revision": 1, "state": "ready", "voices": []}
	func set_mpv_playing(_id: int, value: bool) -> void: playing.append(value)
	func close_mpv_video(_id: int) -> void: pass
	func set_mpv_narration(_id: int, json: String) -> bool: payloads.append(JSON.parse_string(json)); return true
	func mpv_voice_clone_status(_id: int) -> String: return JSON.stringify(state)
	func narration_voice_manager_status() -> String: return JSON.stringify(state)
	func narration_voice_manager_request(json: String) -> bool: global_commands.append(JSON.parse_string(json)); return true
	func mpv_voice_clone_request(_id: int, json: String) -> bool:
		var command: Dictionary = JSON.parse_string(json); commands.append(command)
		if command.operation in ["open", "close"]: state.opened = command.operation == "open"
		if command.operation in ["preview", "stop"]:
			state.operation = command.operation; state.state = "preparing" if command.operation == "preview" else "ready"; state.preview_id = command.get("id", "")
		return true
func check(value: bool, message: String) -> void:
	checks += 1
	if not value: failures.append(message)

func click_choice(menu: Node3D, target: int, hand: String) -> void:
	var button: Dictionary = menu._buttons.filter(func(item): return item.target == target)[0]
	var origin: Vector3 = button.node.to_global(Vector3(0, 0, 1))
	var direction: Vector3 = -menu.global_basis.z
	check(menu.press_pointer(hand, origin, direction, true), "Controller ray presses the sample track control")
	menu.release_pointer(hand, origin, direction, true)

func check_sample_track(menu: Node3D, ui: Dictionary) -> void:
	var saved_state: Dictionary = ui.narration_clone_state.duplicate(true)
	var saved_audio: Array = ui.get("audio_options", [])
	var saved_language: String = menu.I18n.choice
	var events: Array = []; var actions: Array = []
	var listener := func(key: String, value: Variant): events.append([key, value])
	var action_listener := func(action: String): actions.append(action)
	menu.setting_requested.connect(listener); menu.action_requested.connect(action_listener)
	var headings := {"zh": "取样音轨", "zh_Hant": "取樣音軌", "ja": "サンプル音声トラック", "en": "Sample track"}
	for language in headings:
		menu.I18n.use(language); ui.audio_options = []
		ui.narration_clone_state.audio_options = [{"id": 1}]; ui.narration_clone_state.audio_id = 1; menu.refresh()
		check(menu.text_snapshot().contains(headings[language]), "Sample track has its own unambiguous heading: " + language)
		check(menu._labels.any(func(node): return node.text == menu.I18n.t("Track %d") % 1), "Unnamed single audio track displays its localized name")
		check(not menu.choices.targets.values().any(func(item): return item.key == "narration_clone_audio"), "Single audio track has no redundant selection button")
		ui.narration_clone_state.audio_options = [{"id": 7, "language": "jpn"}, {"id": 19, "title": "Close"}]
		ui.narration_clone_state.audio_id = 7; menu.refresh()
		var expected: String = menu.I18n.t("Track %d") % 7 + " · " + menu.I18n.t("Japanese")
		check(menu.clone_panel._audio_label({"id": 7, "language": "jpn"}) == expected, "Unnamed multilingual audio retains its track number and language")
		ui.audio_options = [{"value": 7, "label": expected}, {"value": 19, "label": "Close"}]
		ui.narration_clone_state.audio_id = -1; menu.refresh()
		var target: int = menu.choices.targets.keys().filter(func(id): return menu.choices.targets[id].key == "narration_clone_audio")[0]
		var selector: Dictionary = menu._buttons.filter(func(item): return item.target == target)[0]
		check(selector.select_caption.text == menu.I18n.t("Auto"), "Automatic selection never exposes the internal -1 value")
		ui.narration_clone_state.audio_id = 7; menu.refresh()
		target = menu.choices.targets.keys().filter(func(id): return menu.choices.targets[id].key == "narration_clone_audio")[0]
		check(menu.choices.targets[target].kind == "open", "Multiple audio tracks use the existing dropdown selector")
		click_choice(menu, target, "right_hand")
		check(menu.choices.opened == "narration_clone_audio" and menu.choices.popup.choices[1].label == "Close", "Sample dropdown preserves literal track titles")
		var chosen: Array = menu.choices.targets.keys().filter(func(id): return menu.choices.targets[id].get("key", "") == "narration_clone_audio" and menu.choices.targets[id].kind == "choose" and menu.choices.targets[id].value == 19)
		check(chosen.size() == 1, "Sample dropdown retains the backend track ID")
		if not chosen.is_empty(): click_choice(menu, chosen[0], "left_hand")
		check(events.size() == 1 and events[0] == ["narration_clone_audio", 19] and actions.is_empty(), "Changing sample audio sends only the existing clone setting")
		events.clear()
	menu.setting_requested.disconnect(listener); menu.action_requested.disconnect(action_listener)
	ui.narration_clone_state = saved_state; ui.audio_options = saved_audio; menu.I18n.use(saved_language); menu.refresh()

func check_clone_close(menu: Node3D, ui: Dictionary, commands: Array) -> void:
	var video_actions: Array = []
	var listener := func(action: String): video_actions.append(action)
	menu.action_requested.connect(listener)
	for item in [{"state": "ready"}, {"state": "encoding"}, {"state": "playing_original"},
			{"state": "playing_clone", "library": true}, {"state": "ready", "naming": true},
			{"state": "ready", "library": true, "delete": true}]:
		ui.narration_clone_state.state = item.state
		menu._subtitle_open = true; menu._set_subtitle_detail("narration")
		menu.clone_panel.open(item.get("library", false))
		if item.get("naming", false):
			menu.clone_panel.naming = {"operation": "save", "key": "b"}
			menu.clone_panel.edit()
		if item.get("delete", false): menu.clone_panel.confirm_delete = ID
		menu.refresh()
		var hand := "left_hand" if item.get("library", false) else "right_hand"
		var button: Dictionary = menu._buttons.filter(func(value): return value.target == 107)[0]
		var origin: Vector3 = button.node.to_global(Vector3(0, 0, 1))
		var direction: Vector3 = -menu.global_basis.z
		check(menu.ray_hit(origin, direction).get("target", -1) == 107, "Transport X remains reachable below the clone panel: " + str(item))
		check(menu._tips[107] == menu.I18n.t("Close"), "Transport X describes closing the open panel")
		var before := commands.size()
		check(menu.press_pointer(hand, origin, direction, true), "Controller ray presses the transport X")
		menu.release_pointer(hand, origin, direction, true)
		check(not menu.clone_panel.opened and menu._subtitle_open and menu.visible, "Transport X closes only the clone panel: " + str(item))
		check(commands.size() == before + 1 and commands.back().operation == "close", "Transport X sends exactly one existing clone close command")
		check(not menu.clone_panel.editor.active() and menu.clone_panel.naming.is_empty() and menu.clone_panel.confirm_delete.is_empty(), "Transport X clears the clone editor and confirmation")
		check(video_actions.is_empty(), "Closing a clone panel never dispatches a video action")
		if menu.clone_panel.opened: menu.clone_panel.close()
	ui.narration_clone_state.state = "ready"
	check(menu._tips[107] == menu.I18n.t("Close video"), "Transport X restores its video tooltip after the panel closes")
	menu._activate(107)
	check(video_actions == ["stop"] and not menu._subtitle_open, "Without a clone panel, X retains the original close-video action")
	menu._activate(107)
	check(video_actions == ["stop", "stop"], "Plain transport X still dispatches the original close-video action")
	menu.action_requested.disconnect(listener)
	menu._subtitle_open = true; menu._set_subtitle_detail("narration")

func _initialize() -> void: call_deferred("_run")
func _run() -> void:
	var host := Host.new(); var video := Video.new(); root.add_child(video); video.set_process(false); video.platform = host
	var directory := ProjectSettings.globalize_path("res://../../build/output/voice-clone-tests/" + str(Time.get_ticks_usec()))
	video.narration.memory = VoiceMemory.new(directory)
	video.local_uri = "file:///A.mp4"; video.media.begin(11); video.media.state = "playing"
	video.media.playback = {"details": {"subtitle_tracks": [{"id": 1, "codec": "subrip", "language": "zh", "title": "中文"}]}}
	video.subtitles.select(1)
	var settings := ConfigFile.new(); video.narration.load_settings(settings); video.narration.reset_source(video.local_uri)
	check(not video.narration.enabled, "First video is opt-in")
	video.narration.set_option("narration_enabled", true); video.narration.set_option("narration_language", "zh"); video.narration.set_option("narration_voice_origin", "zh"); video.narration.set_option("narration_voice", "Yuewen"); video.narration.save(settings)
	video.local_uri = "file:///B.mp4"; video.narration.reset_source(video.local_uri)
	check(not video.narration.enabled, "Next video never inherits On")
	host.state.voices = [{"id": ID, "name": "我的声音"}]
	check(video.narration.set_option("narration_custom_voice", ID), "Custom voice can be selected")
	video.narration.save(settings)
	check(not settings.has_section_key("narration", "enabled"), "Global settings have no On bit")
	video.local_uri = "file:///C.mp4"; video.narration.reset_source(video.local_uri)
	check(not video.narration.enabled and video.narration.selected_voice() == ID, "New video inherits only voice")
	video.local_uri = "file:///A.mp4"; video.narration.reset_source(video.local_uri)
	check(video.narration.enabled and video.narration.selected_voice() == "Yuewen", "Existing video keeps its own On and preset")
	video.requested_play = true
	check(video.narration.set_option("narration_clone", {"operation": "open"}), "Clone command is accepted")
	check(not video.requested_play and not host.playing.back(), "Start cloning immediately pauses video")
	check(host.commands.back().operation == "open" and host.commands.back().subtitle_id == 1, "Backend receives selected subtitle track")
	video.toggle_play(); check(not video.requested_play, "Playback cannot start behind clone panel")
	video.narration.clone_command({"operation": "close"}); video.narration._clone_poll_at = 0; video.narration.snapshot()
	check(not video.requested_play, "Close does not resume video")
	video.local_uri = "file:///D.mp4"; video.narration.reset_source(video.local_uri)
	video.narration.set_option("narration_voice_kind", "preset")
	video.narration.clone_command({"operation": "save", "key": "candidate", "name": "我的声音"})
	host.state = {"revision": 3, "state": "saved", "save_request": host.commands.back().request, "saved": {"id": ID, "name": "我的声音"}, "voices": [{"id": ID, "name": "我的声音"}]}
	video.narration._clone_poll_at = 0; video.narration.snapshot()
	check(not video.narration.enabled and video.narration.selected_voice() == ID, "Saved clone is selected without enabling narration")
	var old: Dictionary = video.narration._values(); old.erase("voice_kind"); old.erase("custom_voice")
	check(video.narration.memory._valid_value(old), "Legacy per-video record remains valid")
	var migrated: Dictionary = video.narration.memory._normalize_value(old)
	check(migrated.voice_kind == "preset" and migrated.custom_voice == "" and migrated.enabled == old.enabled, "Legacy migration preserves On bit")
	var menu := Menu.new(); var ui: Dictionary = video.narration.snapshot(); ui.merge({"has_video": true, "source_uri": video.local_uri, "subtitle_options": [{"id": 1, "codec": "subrip"}], "subtitle_track": 1})
	menu.state_provider = func(): return ui
	root.add_child(menu); menu.toggle(); menu.set_process(false); menu._subtitle_open = true; menu._set_subtitle_detail("narration")
	for kind in ["preset", "custom"]:
		ui.narration_voice_kind = kind; ui.narration_enabled = false; menu.refresh()
		check(menu.choices.targets.values().all(func(item): return item.get("key", "") == "narration_enabled"), "Off hides every narration setting in " + kind)
		check(not menu._buttons.any(func(item): return item.target in [menu.NARRATION_PREVIEW, menu.NARRATION_VOICES, menu.NARRATION_CLONE_START]), "Off hides all narration actions in " + kind)
		menu._activate(menu.NARRATION_CLONE_START); check(not menu.clone_panel.opened, "Off rejects a stale clone entry")
	ui.narration_enabled = true
	ui.narration_voice_kind = "preset"; menu.refresh()
	check(menu._buttons.filter(func(item): return item.target == menu.NARRATION_PREVIEW).size() == 1, "Preset category has one shared audition control")
	check(not menu._buttons.any(func(item): return item.target in [menu.NARRATION_VOICES, menu.NARRATION_CLONE_START]), "Preset category hides clone creation and management")
	menu._activate(menu.NARRATION_CLONE_START); check(not menu.clone_panel.opened, "Preset category rejects stale clone entry actions")
	ui.narration_voice_kind = "custom"; menu.refresh()
	check(menu._buttons.filter(func(item): return item.target == menu.NARRATION_PREVIEW).size() == 1, "Clone category reuses the same audition control")
	ui.narration_personal_voices = []; ui.narration_custom_voice = ""; menu.refresh()
	check(not menu._buttons.any(func(item): return item.target in [menu.NARRATION_PREVIEW, menu.NARRATION_VOICES]) and not menu.choices.targets.values().any(func(item): return item.get("key", "") == "narration_custom_voice"), "Empty personal library hides its chooser, audition and management")
	check(menu._buttons.filter(func(item): return item.target == menu.NARRATION_CLONE_START).size() == 1, "Empty personal library keeps only the start cloning action")
	ui.narration_personal_voices = [{"id": ID, "name": "我的声音"}]; ui.narration_custom_voice = ID; menu.refresh()
	check(menu._buttons.any(func(item): return item.target == menu.NARRATION_CLONE_START) and menu._buttons.any(func(item): return item.target == menu.NARRATION_VOICES), "Clone category exposes creation and management")
	var action_buttons: Array = menu._buttons.filter(func(item): return item.target in [menu.NARRATION_CLONE_START, menu.NARRATION_VOICES])
	check(action_buttons.size() == 2 and action_buttons.all(func(item): return item.node.position.x - item.rect.size.x / 2 >= -0.1801 and not item.node.get_child(0).text.is_empty()), "Clone creation and management are two text buttons confined to the value column")
	var personal_dropdown: Array = menu.choices.targets.values().filter(func(item): return item.get("key", "") == "narration_custom_voice")
	check(personal_dropdown.size() == 1 and personal_dropdown[0].kind == "open" and menu.text_snapshot().contains(menu.I18n.t("My cloned voices")), "My voices is a dropdown even with one saved voice")
	var choice_target: int = menu.choices.targets.keys().filter(func(target): return menu.choices.targets[target].get("key", "") == "narration_custom_voice")[0]
	var choice_button: Dictionary = menu._buttons.filter(func(item): return item.target == choice_target)[0]
	var preview_button: Dictionary = menu._buttons.filter(func(item): return item.target == menu.NARRATION_PREVIEW)[0]
	check(is_equal_approx(choice_button.node.position.y, preview_button.node.position.y) and preview_button.node.position.x - preview_button.rect.size.x / 2 > choice_button.node.position.x + choice_button.rect.size.x / 2 and preview_button.base_color.a > 0.9, "Custom audition has its own visible frame and separate ray hit area beside the chooser")
	menu.update_pointer("left_hand", preview_button.node.to_global(Vector3(0, 0, 1)), -menu.global_basis.z, true)
	check(menu._tooltip != null and menu._tooltip.visible and menu._tooltip.get_child(0).text == menu.I18n.t("Preview voice"), "Inline audition exposes its tooltip to the controller ray")
	var saved_rows: Array = video.narration.rows(ui)
	var saved_choice: Dictionary = saved_rows.filter(func(row): return row.field.key == "narration_custom_voice")[0]
	check(saved_choice.field.value == ID and saved_choice.field.choices.any(func(choice): return choice.value == ID), "Newly saved clone remains the selected dropdown value")
	ui.narration_enabled = true; menu.refresh()
	var line_buttons: Array = menu.choices.targets.values().filter(func(item): return item.get("key", "") == "narration_line")
	check(line_buttons.size() == 3 and line_buttons.all(func(item): return item.kind == "choose"), "Reading line uses three direct buttons, not a dropdown")
	ui.narration_voice_kind = "preset"; menu.refresh()
	line_buttons = menu.choices.targets.values().filter(func(item): return item.get("key", "") == "narration_line")
	check(line_buttons.size() == 3, "Reading line buttons are shared by preset and clone categories")
	menu._activate(menu.SUBTITLE_APPEARANCE)
	check(menu._subtitle_appearance_open and not menu.choices.targets.values().any(func(item): return str(item.get("key", "")).begins_with("narration_")), "Opening subtitle appearance replaces narration controls instead of stacking both groups")
	menu._activate(menu.SUBTITLE_NARRATION)
	check(menu.choices.targets.values().any(func(item): return item.get("key", "") == "narration_duck"), "Selecting narration restores its original controls")
	ui.merge({"subtitle_files_available": true, "subtitle_files_state": "ready", "subtitle_files": ["other.srt"]}, true)
	menu._activate(menu.SUBTITLE_FILES)
	check(menu._subtitle_files_open and menu._subtitle_controls().is_empty() and not menu.choices.targets.values().any(func(item): return str(item.get("key", "")).begins_with("narration_")), "Opening external subtitles hides the other settings groups")
	menu._activate(menu.SUBTITLE_FILES); menu._activate(menu.SUBTITLE_NARRATION)
	check(menu.choices.targets.values().any(func(item): return item.get("key", "") == "narration_duck"), "Closing the external file list restores narration settings")
	ui.subtitle_files_available = false
	ui.narration_voice_kind = "custom"; ui.narration_enabled = false
	ui.narration_clone_state = {"revision": 4, "state": "ready", "ready_key": "b", "candidates": [{"key": "a", "start": 10.0, "end": 13.0, "text": "第一句"}, {"key": "b", "start": 20.0, "end": 25.0, "text": "第二句"}, {"key": "c", "start": 30.0, "end": 40.0, "text": "第三句"}, {"key": "d", "start": 50.0, "end": 55.0, "text": "第四句"}]}
	check(menu.ClonePanel.status_text({"state": "reading"}) == "Finding voice samples…", "Clone scanning has its own status, separate from speaking subtitles")
	check(menu.ClonePanel.status_text({"state": "error", "error": "No available samples"}) == "No available samples", "Clone failure keeps its actual error message")
	for index in range(8): ui.narration_clone_state.candidates.append({"key": "more%d" % index, "start": 60.0 + index * 8, "end": 65.0 + index * 8, "text": "更多字幕 %d" % index})
	menu.clone_panel.open(); menu.refresh()
	var ready_state: Dictionary = ui.narration_clone_state.duplicate(true)
	ui.narration_clone_state = {"state": "reading", "candidates": [], "eof": false}; menu.refresh()
	check(menu.text_snapshot().contains(menu.I18n.t("Finding voice samples…")) and not menu.text_snapshot().contains(menu.I18n.t("Reading subtitles…")), "Candidate search never claims that subtitles are being spoken")
	ui.narration_clone_state = {"state": "error", "candidates": [], "eof": true, "error_code": "no_candidates", "error": "This video has no subtitles suitable for a 3–10 second voice sample."}; menu.refresh()
	check(menu.text_snapshot().contains(menu.I18n.t(ui.narration_clone_state.error)), "A video without suitable samples shows the specific failure")
	check(menu.clone_panel.actions.keys().filter(func(target): return menu.clone_panel.actions[target].operation == "candidates").any(func(target): return menu._buttons.any(func(item): return item.target == target and not item.enabled)), "Exhausted empty search disables load more")
	ui.narration_clone_state = ready_state; menu.refresh()
	check(not menu.clone_panel.actions.values().any(func(action): return action.operation == "stop"), "Idle candidate table has no separate stop button")
	var position_target := -1
	for target in menu.clone_panel.actions:
		if menu.clone_panel.actions[target].operation == "nearby": position_target = target; break
	check(position_target > 0 and str(menu._tips[position_target]).contains("20") and menu.text_snapshot().contains(menu.I18n.t("Video position")), "Video position has a tooltip explaining its search window")
	var clone_commands: Array = []
	menu.setting_requested.connect(func(key: String, value: Variant):
		if key == "narration_clone": clone_commands.append(value))
	check_sample_track(menu, ui)
	var operations: Array = []; var save_buttons: Array = []
	for target in menu.clone_panel.actions:
		var action: Dictionary = menu.clone_panel.actions[target]; operations.append(action.operation)
		if action.operation == "save_name":
			for button in menu._buttons:
				if button.target == target: save_buttons.append([action.key, button.enabled])
	check(operations.count("original") == 8 and operations.count("clone") == 8 and operations.count("save_name") == 8, "Compact table shows eight rows with all three actions")
	check(save_buttons.size() == 8 and save_buttons[1] == ["b", true] and save_buttons.filter(func(item): return item[1]).size() == 1, "Only a ready clone can be saved")
	var caption_target := -1
	for target in menu.clone_panel.actions:
		if menu.clone_panel.actions[target].operation == "caption": caption_target = target; break
	check(caption_target > 0 and str(menu._tips[caption_target]).contains("00:00:10.000") and str(menu._tips[caption_target]).contains("第一句"), "Caption hover contains precise time range and full text")
	var caption_button: Dictionary = menu._buttons.filter(func(item): return item.target == caption_target)[0]
	menu.update_pointer("left_hand", caption_button.node.to_global(Vector3(0, 0, 1)), -menu.global_basis.z, true)
	check(menu._tooltip != null and menu._tooltip.visible and menu._tooltip.get_child(0).text.contains("第一句"), "Ray hover displays the full caption tooltip")
	check(not menu._labels.any(func(node): return node.text.contains("00:00:10.000")), "Time range is hidden from the normal table")
	var row_icons := menu._buttons.filter(func(item): return menu.clone_panel.actions.get(item.target, {}).get("operation", "") in ["original", "clone", "save_name"])
	check(row_icons.size() == 24 and row_icons.all(func(item): return item.node.get_child(0).text.is_empty() and item.node.get_child_count() == 2), "Candidate actions use icons without repeated button captions")
	ui.narration_clone_state.merge({"operation": "clone", "active_key": "b", "state": "encoding"}, true); menu.refresh()
	check(not menu.clone_panel.actions.values().any(func(action): return action.operation == "clone" and action.get("key", "") == "b"), "Active clone action becomes a stop icon")
	var stop_targets: Array = menu.clone_panel.actions.keys().filter(func(target): return menu.clone_panel.actions[target].operation == "stop")
	check(stop_targets.size() == 1, "Cloning has only the row's stop icon")
	menu.clone_panel.activate(stop_targets[0]); check(clone_commands.back().operation == "stop", "Second press on the active clone icon stops it")
	ui.narration_clone_state.merge({"operation": "original", "active_key": "a", "state": "playing_original"}, true); menu.refresh()
	stop_targets = menu.clone_panel.actions.keys().filter(func(target): return menu.clone_panel.actions[target].operation == "stop")
	menu.clone_panel.activate(stop_targets[0]); check(stop_targets.size() == 1 and clone_commands.back().operation == "stop", "Original audio uses the same play-stop button")
	ui.narration_clone_state.merge({"operation": "", "active_key": "", "state": "ready"}, true); menu.refresh()
	check(not menu.allows_playback_sticks(), "Clone panel blocks playback stick shortcuts")
	menu.clone_panel.move(1); check(menu.clone_panel.offset == 1, "Candidate list scrolls")
	menu.clone_panel.library = true; menu.clone_panel.offset = 0; menu.refresh()
	check(menu.clone_panel.actions.values().any(func(a): return a.operation == "preview") and menu.clone_panel.actions.values().any(func(a): return a.operation == "rename_name"), "Saved voices support preview and rename")
	check(not menu.clone_panel.actions.values().any(func(action): return action.operation == "stop"), "Idle voice manager has no separate stop button")
	ui.narration_clone_state.merge({"operation": "preview", "preview_id": ID, "state": "playing_clone"}, true); menu.refresh()
	stop_targets = menu.clone_panel.actions.keys().filter(func(target): return menu.clone_panel.actions[target].operation == "stop")
	menu.clone_panel.activate(stop_targets[0]); check(stop_targets.size() == 1 and clone_commands.back().operation == "stop", "Saved voice uses its own preview button to stop")
	ui.narration_clone_state.merge({"operation": "", "state": "ready"}, true)
	check_clone_close(menu, ui, clone_commands)
	menu.clone_panel.opened = false; ui.narration_enabled = true; ui.narration_preview_busy = true; menu.refresh()
	var sample: Dictionary = menu._buttons.filter(func(item): return item.target == menu.NARRATION_PREVIEW)[0]
	check(sample.node.get_child(1).material_override.albedo_texture == menu.Icons.texture("stop"), "Subtitle voice audition shows a stop icon while active")
	ui.narration_preview_busy = false; menu.refresh()
	sample = menu._buttons.filter(func(item): return item.target == menu.NARRATION_PREVIEW)[0]
	check(sample.node.get_child(1).material_override.albedo_texture == menu.Icons.texture("play"), "Subtitle voice audition returns to play when finished")
	menu.clone_panel.close(); menu.free()
	video.media.session_id = 0
	video.narration.set_option("narration_voice_kind", "preset"); video.narration.set_option("narration_voice_origin", "zh"); video.narration.set_option("narration_voice", "Yuewen")
	var global_snapshot: Dictionary = video.narration.voice_manager_snapshot()
	check(global_snapshot.narration_clone_supported and global_snapshot.narration_personal_voices.size() == 1, "Global manager lists voices without a video session")
	video.narration.global_voice_command({"operation": "use", "id": ID})
	check(video.narration.selected_voice() == "Yuewen" and not video.narration.enabled, "Global default does not overwrite current film or enable narration")
	var manager := Library.new()
	manager._cache_usage = Vector2i.ZERO
	manager.settings_provider = func(): return {"voice_manager": video.narration.voice_manager_snapshot()}
	manager.setting_changed.connect(func(key: String, value: Variant):
		if key == "narration_voice_manager": video.narration.global_voice_command(value))
	root.add_child(manager); manager.set_process(false); manager.section = manager.Section.SETTINGS; manager.tab = manager.VIDEO_TAB; manager.visible = true; manager.refresh()
	manager._choose(manager.rows.filter(func(row): return row.get("video_settings_group", "") == "subtitles")[0])
	manager._choose(manager.rows.filter(func(row): return row.get("subtitle_settings_group", "") == "narration")[0])
	check(manager.rows.any(func(row): return row.get("voice_manager", false)), "Global settings contains voice manager entry")
	check(manager.rows.any(func(row): return row.get("voice_manager", false) and row.title == manager.I18n.t("Subtitle narration")) and manager.text_snapshot().contains(manager.I18n.t("My cloned voices")), "Global settings exposes Subtitle narration with a direct Manage my voices button")
	manager._choose({"voice_manager": true})
	check(manager.voice_manager.opened and manager.voice_manager.library and not manager.voice_manager.actions.is_empty(), "Global entry opens the shared manager")
	check(manager.voice_manager.actions.values().any(func(action): return action.operation == "preview") and manager.voice_manager.actions.values().any(func(action): return action.operation == "confirm_delete"), "Global manager offers preview and deletion")
	manager.voice_manager.command({"operation": "preview", "id": ID})
	check(host.global_commands.back().operation == "preview", "Global audition uses no-video backend")
	check(not video.narration.global_voice_command({"operation": "use", "id": "custom:22345678-1234-1234-1234-123456789abc"}), "Global default rejects unavailable voice IDs")
	host.state.voices = []; host.state.revision += 1; video.narration._global_voice_poll_at = 0
	global_snapshot = video.narration.voice_manager_snapshot()
	check(global_snapshot.narration_voice_kind == "preset" and global_snapshot.narration_custom_voice == "", "Deleted global default falls back to preset")
	check(video.narration.selected_voice() == "Yuewen" and not video.narration.enabled, "Default repair preserves current film and Off bit")
	check(not VoiceMemory.valid_custom_voice("custom:123456781-234-1234-1234-123456789abc"), "Malformed UUID dash positions are rejected")
	video.media.session_id = 11; host.state.operation = "preview"; host.state.state = "playing_clone"; video.narration._clone_poll_at = 0; video.narration.snapshot()
	check(video.narration.set_option("narration_preview", true) and host.commands.back().operation == "stop", "Active custom audition can be stopped with the preview button")
	video.narration.clone_state.opened = true; video.narration._clone_session = 11; host.state.revision += 1; video.narration._global_voice_poll_at = 0
	video.narration.voice_manager_snapshot()
	check(video.narration._clone_session == 11, "Global status polling does not cancel an open clone panel")
	menu = Menu.new(); menu.I18n.use("zh")
	check(menu.choices._option_label({"label": "Close", "literal": true}) == "Close", "Personal voice names are not translated as interface labels")
	menu.free()
	host.state = {"state": "ready", "saved": {"id": ID}, "voices": [{"id": ID, "name": "我的声音"}]}
	video.narration._clone_saved = ID; video.narration._clone_session = 0; video.narration._clone_poll_at = 0
	video.narration.snapshot()
	check(video.narration.selected_voice() == "Yuewen", "Catalog refresh does not replay an old save and overwrite a later preset choice")
	video.narration.clone_state = {"state": "ready"}; video.narration.enabled = true
	video.media.playback.narration = {"state": "ready", "preview": false, "preview_request": video.narration.preview}
	video.narration.set_option("narration_preview", true)
	check(video.narration.snapshot().narration_preview_busy, "Preset audition changes to stop immediately before status acknowledgement")
	video.narration.set_option("narration_preview", true)
	check(not video.narration.snapshot().narration_preview_busy, "Rapid second press stops a preset audition before status acknowledgement")
	video.media.playback.narration = {"state": "ready", "preview": false, "preview_request": video.narration.preview}
	video.narration.set_option("narration_preview", true)
	host.state.state = "playing_clone"; video.narration._clone_poll_at = 0
	check(video.narration.snapshot().narration_preview_busy, "Acknowledged preset audition keeps the stop state")
	host.state.state = "ready"; video.narration._clone_poll_at = 0
	check(not video.narration.snapshot().narration_preview_busy, "Natural completion restores the preset play state")
	video.narration.enabled = true; video.narration.save(settings)
	var remembered_uri: String = video.local_uri
	video.media.close(); video.narration.reset_source(); video.narration.save(settings)
	check(video.narration.memory.lookup(remembered_uri).enabled, "Global saves after closing a video do not overwrite its remembered On bit")
	manager.voice_manager.close(); manager.queue_free(); video.queue_free(); await process_frame
	print("Custom voice checks=%d failures=%d" % [checks, failures.size()])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)
