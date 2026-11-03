extends SceneTree
const Menu := preload("res://scripts/player_menu.gd")
const Library := preload("res://scripts/library_menu.gd")
const Auto3D := preload("res://scripts/video_auto_3d.gd")
const I18n := preload("res://scripts/i18n.gd")
func _initialize() -> void: _run.call_deferred()
func _run() -> void:
	var output := ProjectSettings.globalize_path("res://../../build/output/video-auto-3d-20261103/previews")
	DirAccess.make_dir_recursive_absolute(output)
	var viewport := SubViewport.new()
	viewport.size = Vector2i(1600, 1100); viewport.own_world_3d = true; viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var camera := Camera3D.new(); camera.fov = 60; viewport.add_child(camera)
	var state := {"has_video": true, "geometry": 0, "stereo": false, "title": "Travel journal", "video_auto_3d": false}
	var library := Library.new(); library.settings_provider = func(): return state
	camera.add_child(library); library.set_process(false)
	library.section = Library.Section.SETTINGS; library.tab = Library.VIDEO_TAB
	var menu := Menu.new(); menu.state_provider = func(): return state
	camera.add_child(menu); menu.set_process(false); menu.position.y = -0.45; menu.section = 1
	for language in ["zh", "zh_Hant", "ja", "en"]:
		I18n.use(language)
		for kind in ["library", "player"]:
			library.visible = kind == "library"; menu.visible = kind == "player"
			var active: Node3D = library if kind == "library" else menu
			active.refresh()
			var target := -1
			for id in active._tips:
				if active._tips[id] == I18n.t(Auto3D.HINT): target = id; break
			if target < 0: push_error("Missing tooltip"); quit(1); return
			active._hover = {"right_hand": target}; active._update_tooltip()
			await process_frame; await RenderingServer.frame_post_draw; await RenderingServer.frame_post_draw
			viewport.get_texture().get_image().save_png(output.path_join(language + "-" + kind + ".png"))
	viewport.queue_free(); await process_frame
	print("Video auto 3D renders: 8 frames")
	quit(0)
