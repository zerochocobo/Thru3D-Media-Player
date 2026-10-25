extends SceneTree
func _initialize() -> void: run.call_deferred()
func run() -> void:
	var output := ProjectSettings.globalize_path("res://../../build/output/comic-ui-r5-20261025/ui")
	DirAccess.make_dir_recursive_absolute(output)
	var viewport := SubViewport.new(); viewport.size = Vector2i(1400,1100); viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS; root.add_child(viewport)
	var camera := Camera3D.new(); camera.position.z = 1.8; camera.fov = 47; viewport.add_child(camera)
	for language in ["zh", "zh_Hant", "ja", "en"]:
		preload("res://scripts/i18n.gd").use(language)
		var menu := preload("res://scripts/photo_menu.gd").new()
		var preferences := preload("res://scripts/comic_reading_settings.gd").new()
		preferences.enabled = true
		var state := preferences.snapshot([])
		state.merge({"comic_supported":true, "has_image":true, "comic_state":"ready", "comic_readable":5, "comic_ready_audio":5, "title":"Comic", "count":11, "index":2})
		menu.state_provider = func(): return state
		viewport.add_child(menu); menu.visible = true; menu.set_process(false)
		for panel in ["bar", "settings", "preset-dropdown", "custom", "custom-dropdown", "preview"]:
			if panel == "settings": menu._activate(menu.PHOTO_COMIC_VOICE)
			if panel == "preset-dropdown": menu.choices.opened = "comic_voice"
			if panel == "custom":
				menu.choices.reset(); state.comic_voice_kind = "custom"
				state.comic_personal_voices = [{"id":"custom:12345678-1234-1234-1234-123456789abc", "name":"Voice A"}, {"id":"custom:22345678-1234-1234-1234-123456789abc", "name":"Voice B"}]
				state.comic_custom_voice = state.comic_personal_voices[0].id
			if panel == "custom-dropdown": menu.choices.opened = "comic_custom_voice"
			if panel == "preview": menu.choices.reset(); state.comic_speech = "speaking"
			menu.refresh()
			await process_frame; await RenderingServer.frame_post_draw; await RenderingServer.frame_post_draw
			viewport.get_texture().get_image().save_png(output.path_join(language + "-" + panel + ".png"))
		menu.free()
	quit()
