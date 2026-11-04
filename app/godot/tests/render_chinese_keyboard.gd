extends SceneTree
const Keyboard := preload("res://scripts/chinese_keyboard.gd")
const I18n := preload("res://scripts/i18n.gd")
func _initialize() -> void: call_deferred("run")
func run() -> void:
	I18n.use("zh"); Keyboard.Pinyin.load_lexicon()
	var viewport := SubViewport.new(); viewport.size = Vector2i(1500, 1050); viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS; root.add_child(viewport)
	var camera := Camera3D.new(); camera.fov = 48; viewport.add_child(camera)
	var keyboard := Keyboard.new(); camera.add_child(keyboard)
	keyboard.present("render", func(_op, _text): return true, func(): return true, func(): return "搜索电影│", false)
	keyboard.position = Vector3(0, 0, -1.18)
	for letter in "dianying": keyboard.type_key(letter)
	var output := ProjectSettings.globalize_path("res://../../build/output/quest-keyboard-layout-20261104")
	DirAccess.make_dir_recursive_absolute(output)
	for mode in ["chinese", "english"]:
		if mode == "english": keyboard.ime.clear(); keyboard.english = true; keyboard.refresh()
		for frame in 5: await process_frame
		await RenderingServer.frame_post_draw
		var picture := viewport.get_texture().get_image()
		if picture.save_png(output.path_join("keyboard-" + mode + ".png")) != OK: quit(1); return
	keyboard.queue_free(); viewport.queue_free(); await process_frame
	print("Chinese keyboard render passed")
	quit()
