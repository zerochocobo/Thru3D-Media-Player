extends SceneTree
## The wand rows: the attic's scene settings and the reading settings' Book page.
## godot --xr-mode off --path app/godot --script ../../tools/wands/render_wand_menus.gd -- <dir> [language]
const Menu := preload("res://scripts/scenery_menu.gd")
const Library := preload("res://scripts/background_library.gd")
const BookReader := preload("res://scripts/book_reader.gd")
const I18n := preload("res://scripts/i18n.gd")

func _initialize() -> void: _run.call_deferred()

func shot(viewport: SubViewport, path: String) -> void:
	await create_timer(.2).timeout
	await RenderingServer.frame_post_draw
	viewport.get_texture().get_image().save_png(path)

func _run() -> void:
	var args := OS.get_cmdline_user_args()
	var output: String = args[0]
	I18n.use(args[1] if args.size() > 1 else "zh")
	DirAccess.make_dir_recursive_absolute(output)
	var viewport := SubViewport.new(); viewport.size = Vector2i(1400, 1200); viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS; root.add_child(viewport)
	var camera := Camera3D.new(); camera.current = true; viewport.add_child(camera)
	var library := Library.new(); library.directory = output.path_join("library"); viewport.add_child(library)
	var menu := Menu.new(); menu.library = library
	menu.state_provider = func(_mode): return {"selected": "magic_cottage", "choice": "magic_cottage", "status": "", "busy": false,
		"brightness": 1.0, "attic_wand": "ebony", "cottage_screen": {"near": 1.2, "far": 6.6, "minimum": 35., "maximum": 135., "play_dim": .25}}
	viewport.add_child(menu); menu.open("global")
	menu.view = "adjust"; menu.refresh()
	camera.global_position = menu.global_position + Vector3(0, -.05, 1.6)
	await shot(viewport, output.path_join("attic-wand.png"))
	menu.queue_free()
	var reader := BookReader.new()
	viewport.add_child(reader)
	reader.restore_settings(ConfigFile.new())
	var bar: Node3D = reader.bar
	bar.section = "book"
	bar.visible = true
	bar.global_transform = Transform3D(Basis.IDENTITY, Vector3(0, 0, -1))
	bar.mode = "settings"; bar._grown = 1.0
	bar.refresh()
	reader.visible = true
	for child in reader.get_children():
		if child != bar and child is Node3D: child.visible = false
	for i in 20: await process_frame
	print("BAR ", bar.is_visible_in_tree(), " ", bar.get_child_count(), " ", bar.global_transform, " ", bar.scale)
	camera.global_position = Vector3(0, .1, .25)
	camera.look_at(Vector3(0, .1, -1), Vector3.UP)
	await shot(viewport, output.path_join("reading-wand.png"))
	reader.set_scene_wand("rosewood")
	bar.refresh()
	await shot(viewport, output.path_join("reading-wand-attic.png"))
	quit()
