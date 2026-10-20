extends SceneTree
const Menu := preload("res://scripts/player_menu.gd")
const Library := preload("res://scripts/library_menu.gd")
const I18n := preload("res://scripts/i18n.gd")
const ID := "custom:12345678-1234-1234-1234-123456789abc"
var failures: Array[String] = []
var layouts := 0
func _initialize() -> void: call_deferred("_run")
func _run() -> void:
	var output := OS.get_environment("NARRATION_CLONE_UI_OUTPUT")
	if output.is_empty(): output = ProjectSettings.globalize_path("res://../../build/output/narration-clone-ui/%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(output)
	print("Clone voice render output=" + output)
	var viewport := SubViewport.new(); viewport.size = Vector2i(1600, 1600); viewport.own_world_3d = true; viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS; root.add_child(viewport)
	var camera := Camera3D.new(); camera.fov = 70; camera.position.y = 0.30; viewport.add_child(camera)
	var state := {"has_video": true, "title": "日语原声 → 中文朗读", "source_uri": "file:///clone-test.mp4", "duration_ms": 240000, "position_ms": 40000,
		"subtitle_options": [{"id": 1, "title": "中文", "codec": "subrip"}], "subtitle_track": 1,
		"narration_available": true, "narration_enabled": false, "narration_clone_supported": true, "narration_voice_kind": "custom", "narration_custom_voice": ID,
		"narration_language": "zh", "narration_resolved_language": "zh", "narration_personal_voices": [{"id": ID, "name": "电影女主角"}, {"id": "custom:22345678-1234-1234-1234-123456789abc", "name": "低沉男声"}],
		"narration_clone_state": {"state": "ready", "revision": 1, "audio_id": 2, "audio_options": [{"id": 2, "language": "ja", "title": "日本語 · 原声"}],
			"ready_key": "b", "candidates": [{"key": "a", "start": 754.2, "end": 757.3, "text": "好，我知道了。"}, {"key": "b", "start": 760.0, "end": 765.0, "text": "别着急，我们明天再来。"}, {"key": "c", "start": 772.1, "end": 781.9, "text": "今晚的风很轻，路边的灯刚刚亮起。我们慢慢往前走。"}]}}
	var menu := Menu.new(); menu.state_provider = func(): return state
	for index in range(9):
		state.narration_clone_state.candidates.append({"key": "row%d" % index, "start": 800.0 + index * 8, "end": 805.0 + index * 8, "text": "这是第%d条字幕，用来检查紧凑列表中的内容显示。" % (index + 4)})
		state.narration_personal_voices.append({"id": "custom:%08d-1234-1234-1234-123456789abc" % (index + 3), "name": "自定义音色 %d" % (index + 3)})
	var personal_voices: Array = state.narration_personal_voices.duplicate(true)
	camera.add_child(menu); menu.position.y = -0.35; menu.toggle(); menu.set_process(false); menu._subtitle_open = true
	for language in ["zh", "zh_Hant", "ja", "en"]:
		I18n.use(language)
		for view in ["settings", "preset", "custom-on", "preset-choices", "preset-choices-last", "preset-playing", "custom-playing", "custom-loading", "custom-finished", "language-choices", "language-choices-last", "language-long", "empty-custom", "advanced", "appearance", "many-tracks", "subtitle-loading", "external-files", "candidates", "single-unnamed-audio", "audio-tracks", "audio-tracks-open", "library", "library-loading", "naming", "saving", "encoding", "model-loading", "error", "hover"]:
			var settings_view: bool = view in ["settings", "preset", "custom-on", "preset-choices", "preset-choices-last", "preset-playing", "custom-playing", "custom-loading", "custom-finished", "language-choices", "language-choices-last", "language-long", "empty-custom", "advanced", "appearance", "many-tracks", "subtitle-loading", "external-files"]
			menu.clone_panel.opened = not settings_view; menu.clone_panel.library = view.begins_with("library"); menu.clone_panel.source = state.source_uri; menu.clone_panel.naming = {}; menu.clone_panel.saving = false
			state.narration_voice_kind = "preset" if view.begins_with("preset") else "custom"; state.narration_enabled = settings_view and view != "settings"
			state.narration_voice = "Xiaoyu"; state.narration_voice_origin = "zh"; state.narration_resolved_origin = "zh"; state.narration_status = "ready"
			state.narration_language = "pt" if view == "language-long" else "zh"; state.narration_resolved_language = state.narration_language
			state.narration_personal_voices = [] if view == "empty-custom" else personal_voices; state.narration_custom_voice = "" if view == "empty-custom" else ID
			state.narration_preview_busy = view in ["preset-playing", "custom-playing", "custom-loading"]
			state.narration_preview_status = "Loading narration model…" if view == "custom-loading" else "Voice preview finished" if view == "custom-finished" else ""
			state.subtitle_files_available = view == "external-files"; state.subtitle_files_state = "loading" if view == "subtitle-loading" else "ready"
			state.subtitle_files = ["movie.zh.srt", "movie.en.ass", "movie.ja.srt", "other.srt"]
			state.subtitle_options = [{"id": 1, "title": "中文", "codec": "subrip"}]
			if view == "many-tracks":
				for index in range(2, 9): state.subtitle_options.append({"id": index, "title": "字幕 %d" % index, "codec": "subrip"})
			menu.choices.reset(); menu._narration_more = view == "advanced"; menu._subtitle_appearance_open = view == "appearance"; menu._subtitle_files_open = view == "external-files"
			camera.fov = 80 if state.narration_enabled else 70; menu.position.y = -0.55 if state.narration_enabled else -0.35
			state.narration_clone_state.state = "encoding" if view == "encoding" else "error" if view == "error" else "ready"
			state.narration_clone_state.operation = "clone" if view == "encoding" else ""; state.narration_clone_state.active_key = "b" if view == "encoding" else ""
			if view in ["model-loading", "library-loading"]:
				state.narration_clone_state.merge({"state": "model_loading", "operation": "preview" if view == "library-loading" else "clone", "active_key": "b", "preview_id": ID}, true)
			state.narration_clone_state.error = "Unable to prepare voice. Try another sample." if view == "error" else ""
			state.narration_clone_state.audio_options = [{"id": 2, "language": "ja", "title": "日本語 · 原声"}]; state.narration_clone_state.audio_id = 2
			if view == "single-unnamed-audio":
				state.narration_clone_state.audio_options = [{"id": 1}]; state.narration_clone_state.audio_id = 1
			elif view.begins_with("audio-tracks"):
				state.narration_clone_state.audio_options = [{"id": 1, "language": "zho"}, {"id": 7, "language": "jpn"}]; state.narration_clone_state.audio_id = 7
			if view in ["naming", "saving"]: menu.clone_panel.naming = {"operation": "save", "key": "b"}; menu.clone_panel.draft = "电影女主角"
			if view == "saving": state.narration_clone_state.state = "saving"; menu.clone_panel.saving = true
			menu.refresh()
			if view == "audio-tracks-open": menu.choices.opened = "narration_clone_audio"; menu.refresh()
			if view in ["preset-choices", "preset-choices-last"]:
				menu.choices.opened = "narration_voice"; menu.choices.offset = 6 if view.ends_with("last") else 0; menu.refresh()
			if view in ["language-choices", "language-choices-last"]:
				menu.choices.opened = "narration_language"; menu.choices.offset = 14 if view.ends_with("last") else 0; menu.refresh()
			if view == "hover":
				for target in menu.clone_panel.actions:
					if menu.clone_panel.actions[target].operation == "caption" and menu.clone_panel.actions[target].key == "c": menu._hover["left_hand"] = target; menu._update_highlights(); break
			await process_frame; await RenderingServer.frame_post_draw; await RenderingServer.frame_post_draw
			if viewport.get_texture().get_image().save_png(output.path_join(language + "-" + view + ".png")) != OK: failures.append("save " + language + view)
			layouts += 1
			if menu.allows_playback_sticks(): failures.append("playback shortcuts " + view)
			if view in ["preset", "custom-on"]:
				var panels := menu._decorations.filter(func(node): return node is MeshInstance3D and node.mesh is QuadMesh and is_equal_approx(node.mesh.size.x, 1.10))
				var panel_height := 0.0
				for panel in panels: panel_height = maxf(panel_height, panel.mesh.size.y)
				# Previous one-track, narration-on layout was 1.305m high for both categories.
				if panel_height <= 0 or panel_height > 1.305 * 0.8: failures.append("compact height " + view)
				print("Compact narration %s %s height=%.3fm reduction=%.1f%%" % [language, view, panel_height, (1.0 - panel_height / 1.305) * 100])
			menu._hover.clear(); menu._hide_tooltip()
			for button in menu._buttons:
				if button.target < menu.ChoiceFields.BASE and button.target not in [menu.NARRATION_CLONE_START, menu.NARRATION_VOICES]: continue
				var label: Label3D = button.node.get_child(0)
				var width: float = menu.ui_font().get_string_size(label.text, HORIZONTAL_ALIGNMENT_LEFT, -1, label.font_size).x * label.pixel_size
				if width > button.rect.size.x - 0.004: failures.append("overflow " + language + " " + view + " " + label.text)
	menu.clone_panel.opened = false; menu.free()
	var global_state := state.duplicate(true); global_state.global_voice_manager = true; global_state.source_uri = "global-voice-manager"
	global_state.narration_clone_state.state = "ready"; global_state.narration_clone_state.error = ""
	var manager := Library.new(); manager.settings_provider = func(): return {"voice_manager": global_state}
	camera.add_child(manager); manager.position.y = -0.10; manager.set_process(false); manager.visible = true; manager.section = manager.Section.SETTINGS; manager.voice_manager.opened = true; manager.voice_manager.library = true; manager.voice_manager.source = global_state.source_uri
	for language in ["zh", "zh_Hant", "ja", "en"]:
		I18n.use(language); manager._cache_usage = Vector2i.ZERO; manager.tab = manager.VIDEO_TAB; manager.voice_manager.opened = false; manager.refresh()
		await process_frame; await RenderingServer.frame_post_draw; await RenderingServer.frame_post_draw
		if viewport.get_texture().get_image().save_png(output.path_join(language + "-global-settings.png")) != OK: failures.append("global entry render")
		if not manager._list.get_children().any(func(node): return node is Label3D and node.text == I18n.t("Subtitle narration")) or not manager.text_snapshot().contains(I18n.t("Manage my voices")): failures.append("global entry labels " + language)
		layouts += 1
		manager.voice_manager.opened = true; manager.refresh()
		await process_frame; await RenderingServer.frame_post_draw; await RenderingServer.frame_post_draw
		if viewport.get_texture().get_image().save_png(output.path_join(language + "-global-manager.png")) != OK: failures.append("global render")
		layouts += 1
	manager.voice_manager.opened = false; manager.free(); viewport.free()
	print("Clone voice render layouts=%d failures=%d" % [layouts, failures.size()])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)
