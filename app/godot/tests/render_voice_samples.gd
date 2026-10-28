extends SceneTree
const Library := preload("res://scripts/library_menu.gd")
const I18n := preload("res://scripts/i18n.gd")
func _initialize() -> void: call_deferred("_run")
func _run() -> void:
	var output := ProjectSettings.globalize_path("res://../../build/output/voice-samples-inline")
	DirAccess.make_dir_recursive_absolute(output)
	var viewport := SubViewport.new(); viewport.size = Vector2i(1400, 1400); viewport.own_world_3d = true; viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS; root.add_child(viewport)
	var camera := Camera3D.new(); camera.fov = 70; viewport.add_child(camera)
	var state := {"source_uri": "global-voice-manager", "global_voice_manager": true, "narration_clone_supported": true, "narration_current_uri": "file:///demo.mp4", "narration_resolved_language": "zh", "narration_personal_voices": [],
		"narration_clone_state": {"state": "ready", "source_ready": true, "duration": 7200, "audio_id": 1, "audio_options": [{"id": 1, "language": "ja", "title": "日本語"}, {"id": 2, "language": "en", "title": "English"}], "ready_key": "sample-0", "candidates": []}}
	for i in 12: state.narration_clone_state.candidates.append({"key": "sample-%d" % i, "start": 612.3 + i * 10, "end": 618.4 + i * 10, "text": "", "waveform": range(32).map(func(x): return 0.02 + absf(sin(x * 0.7)) * 0.1)})
	var menu := Library.new(); menu.settings_provider = func(): return {"voice_manager": state}
	camera.add_child(menu); menu.position.z = -1.15; menu.set_process(false); menu.visible = true; menu.section = menu.Section.SETTINGS
	menu._state = state; menu.voice_manager.open(true)
	var sample: RefCounted = menu.voice_manager.sample
	var layouts := 0
	var failures := 0
	for lang in ["zh", "zh_Hant", "ja", "en"]:
		I18n.use(lang)
		# Render the actual picker entered by Add voice, using synthetic local rows.
		menu.position.z = -1.75
		sample.begin(); menu.status = ""; menu._local_stack = [{"id": "/demo", "title": "Samples"}]
		menu._local_entries = [{"uri": "file:///demo/speech.mp3", "title": "参考声音.mp3", "kind": "audio"}, {"uri": "file:///demo/recording.m4a", "title": "录音机录音.m4a", "kind": "audio"}, {"uri": "file:///demo/reference.wav", "title": "参考录音.wav", "kind": "audio"}, {"uri": "file:///demo/movie.mkv", "title": "示例影片.mkv", "kind": "video"}]
		menu._rebuild_rows(); menu.refresh()
		if not menu.voice_picker_mode or menu.voice_manager.opened: failures += 1
		await process_frame; await RenderingServer.frame_post_draw; await RenderingServer.frame_post_draw
		viewport.get_texture().get_image().save_png(output.path_join(lang + "-picker.png")); layouts += 1
		menu.finish_voice_picker("file:///demo/speech.mp3", "参考声音.mp3")
		menu.position.z = -1.15
		for view in ["setup", "results", "cropped", "scanning", "naming"]:
			sample.page = "setup" if view == "setup" else "results"
			sample.start = 600.0; sample.scan_seconds = 300; sample.search_start = 600
			sample.finish = sample.start + 300
			state.narration_clone_state.candidates[0].original_start = 612.3
			state.narration_clone_state.candidates[0].original_end = 618.4
			state.narration_clone_state.candidates[0].start = 613.2 if view == "cropped" else 612.3
			state.narration_clone_state.candidates[0].end = 616.2 if view == "cropped" else 618.4
			state.narration_clone_state.state = "scanning" if view == "scanning" else "ready"
			state.narration_clone_state.operation = "scan"
			state.narration_clone_state.scan_start = 600.0; state.narration_clone_state.scan_end = 900.0
			state.narration_clone_state.next = 738.0 if view == "scanning" else 900.0
			state.narration_clone_state.ready_key = "sample-0" if view not in ["cropped", "scanning"] else ""
			menu.voice_manager.naming = {"operation": "save", "key": "sample-0", "apply": false} if view == "naming" else {}
			menu.voice_manager.draft = I18n.t("My cloned voice") + " 1"; menu.refresh()
			if menu._buttons.size() < 4 or not menu.text_snapshot().contains(I18n.t("Add voice")): failures += 1
			await process_frame; await RenderingServer.frame_post_draw; await RenderingServer.frame_post_draw
			viewport.get_texture().get_image().save_png(output.path_join(lang + "-" + view + ".png")); layouts += 1
		menu.voice_manager.naming.clear()
	menu.free(); viewport.free(); print("Voice sample renders=%d failures=%d" % [layouts, failures]); quit(0 if failures == 0 else 1)
