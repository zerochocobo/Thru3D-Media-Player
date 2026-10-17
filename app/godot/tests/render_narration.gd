extends SceneTree
const Menu := preload("res://scripts/player_menu.gd")
const I18n := preload("res://scripts/i18n.gd")
var failures: Array[String] = []
var checks := 0
func _initialize() -> void: call_deferred("_run")
func _run() -> void:
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
		for view in ["chinese","english","unknown","more"]:
			state.narration_resolved_language="" if view=="unknown" else ("zh" if view=="chinese" else "en")
			state.narration_voice="Yuewen" if view=="chinese" else "Ava"
			state.narration_status="language_required" if view=="unknown" else "ready"
			menu._audio_open=true;menu._audio_source=str(state.source_uri);menu._audio_more=view=="more";menu.refresh()
			if Menu.NarrationSettings.FEATURE_ENABLED:
				if menu.choices.targets.size()<5:failures.append("Missing narration fields")
			else:
				for target in menu.choices.targets:
					if str(menu.choices.targets[target].get("key", "")).begins_with("narration_"): failures.append("Withheld narration field visible")
				for button in menu._buttons:
					if button.target in [menu.AUDIO_MORE, menu.AUDIO_PREVIEW, menu.AUDIO_RETRY]: failures.append("Withheld narration action visible")
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
	print("Narration render layouts=16 checks=%d failures=%d" % [checks,failures.size()])
	for failure in failures:push_error(failure)
	quit(0 if failures.is_empty() else 1)
