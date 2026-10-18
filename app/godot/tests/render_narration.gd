extends SceneTree
const Menu := preload("res://scripts/player_menu.gd")
const I18n := preload("res://scripts/i18n.gd")
var failures: Array[String] = []
var checks := 0
func _initialize() -> void: call_deferred("_run")
func _run() -> void:
	if "--narration-development" in OS.get_cmdline_user_args(): Menu.NarrationSettings.FEATURE_ENABLED = true
	var output := ProjectSettings.globalize_path("res://../../build/output/narration-integration/ui")
	if not Menu.NarrationSettings.FEATURE_ENABLED: output += "-hidden"
	DirAccess.make_dir_recursive_absolute(output)
	var viewport := SubViewport.new();viewport.size=Vector2i(1280,1280);viewport.own_world_3d=true;viewport.render_target_update_mode=SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var camera := Camera3D.new();camera.fov=70;camera.position.y=0.30;viewport.add_child(camera)
	var state := {"has_video":true,"title":"Offline subtitle narration","duration_ms":240000,"position_ms":40000,"source_uri":"file:///movie.mp4","audio_track_id":1,
		"audio_options":[{"value":-1,"label":"Auto"},{"value":1,"label":"English"},{"value":0,"label":"Off"}],
		"narration_available":true,"narration_enabled":true,"narration_source":-1,"narration_language":"auto","narration_duck":75.0,
		"narration_sources":[{"value":-1,"label":"Follow current subtitles"},{"value":1,"label":"Chinese"},{"value":2,"label":"English"}]}
	var menu := Menu.new()
	menu.state_provider=func(): return state
	camera.add_child(menu);menu.position.y=-0.35;menu.toggle();menu.set_process(false)
	for language in ["zh","zh_Hant","ja","en"]:
		I18n.use(language)
		for view in ["chinese","english","unknown","more","loading","preparing","preview","sample-playing","failed"]:
			state.narration_resolved_language="" if view=="unknown" else ("zh" if view in ["chinese","loading","preparing","preview","failed"] else "en")
			state.narration_language="auto" if view=="unknown" else state.narration_resolved_language
			state.narration_voice="Xiaoyu" if state.narration_resolved_language=="zh" else "Ava"
			state.narration_resolved_origin="zh" if state.narration_resolved_language=="zh" else "en"
			state.narration_status={"unknown":"language_required","loading":"model_loading","preparing":"preparing","preview":"preview_buffering","sample-playing":"speaking","failed":"speech_error"}.get(view,"ready")
			state.narration_progress=60 if view=="preparing" else -1
			state.narration_preview_busy=view in ["preview","sample-playing"]
			state.narration_preview_progress=52 if view=="sample-playing" else -1
			state.narration_missing=3 if view=="failed" else 0
			state.subtitle_options=[{"id":1,"title":"中文 / English / 日本語","codec":"subrip"}];state.subtitle_track=1
			state.narration_profile="ja_male" if view=="unknown" else "zh_female" if view=="chinese" else "en_female"
			state.narration_line=2
			menu._audio_open=false;menu._subtitle_open=true;menu._narration_more=view=="more";menu.refresh()
			if Menu.NarrationSettings.FEATURE_ENABLED:
				if menu.choices.targets.size()<(3 if view=="more" else 6):failures.append("Missing narration fields")
			else:
				for target in menu.choices.targets:
					if str(menu.choices.targets[target].get("key", "")).begins_with("narration_"): failures.append("Withheld narration field visible")
				for button in menu._buttons:
					if button.target in [menu.NARRATION_MORE, menu.NARRATION_PREVIEW, menu.NARRATION_RETRY]: failures.append("Withheld narration action visible")
			await process_frame;await RenderingServer.frame_post_draw;await RenderingServer.frame_post_draw
			if viewport.get_texture().get_image().save_png(output.path_join(language+"-"+view+".png"))!=OK:failures.append("save")
			for button in menu._buttons:
				if not menu.choices.targets.has(button.target):continue
				var label: Label3D=button.node.get_child(0)
				var width := menu.FONT.get_string_size(label.text,HORIZONTAL_ALIGNMENT_LEFT,-1,label.font_size).x*label.pixel_size
				checks+=1
				if width>button.rect.size.x:failures.append("Field overflow: "+language+"-"+view)
			checks+=1
			if menu.allows_playback_sticks():failures.append("Audio panel allowed playback sticks")
	menu.free();viewport.free()
	print("Narration render layouts=36 checks=%d failures=%d" % [checks,failures.size()])
	for failure in failures:push_error(failure)
	quit(0 if failures.is_empty() else 1)
