extends SceneTree
## Renders the scene menu with the viewer's 3D scenes beside their panoramas to
## build/output/scene-import/menu for review, and checks that presses turn into the right commands.
const Menu := preload("res://scripts/scenery_menu.gd")
const Library := preload("res://scripts/background_library.gd")
const I18n := preload("res://scripts/i18n.gd")
var commands: Array = []
var sent := 0
var failures: Array[String] = []

class Pictures extends Node:
	## Stands in for the controller: one scene already has its picture.
	func thumbnail(id: String) -> Texture2D:
		if id != "a1": return null
		var image := Image.create(96, 54, false, Image.FORMAT_RGB8)
		for y in 54:
			for x in 96: image.set_pixel(x, y, Color(0.15 + x / 160.0, 0.2, 0.55 - y / 120.0))
		return ImageTexture.create_from_image(image)

func _initialize() -> void: _run.call_deferred()

func _check(ok: bool, label: String) -> void:
	if not ok: failures.append(label)

func save_frame(viewport: SubViewport, camera: Camera3D, menu: Node3D, path: String) -> void:
	await create_timer(.15).timeout
	await RenderingServer.frame_post_draw
	var a := camera.unproject_position(menu.to_global(Vector3(-.80, menu._top + .055, 0)))
	var b := camera.unproject_position(menu.to_global(Vector3(.80, menu._bottom - .06, 0)))
	var rectangle := Rect2i(Vector2i(a.floor()), Vector2i((b - a).ceil())).intersection(Rect2i(Vector2i.ZERO, viewport.size))
	viewport.get_texture().get_image().get_region(rectangle).save_png(path)

func _run() -> void:
	I18n.use("zh")
	var output := ProjectSettings.globalize_path("res://../../build/output/scene-import/menu")
	DirAccess.make_dir_recursive_absolute(output)
	var viewport := SubViewport.new()
	viewport.size = Vector2i(1500, 1500)
	viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var camera := Camera3D.new()
	camera.current = true
	viewport.add_child(camera)
	var library := Library.new()
	library.directory = output.path_join("library-" + str(Time.get_ticks_usec()))
	viewport.add_child(library)
	var scenes := {"rows": [], "active": "", "pending": "", "busy": false, "adding": "", "progress": 0.0, "error": "", "bake": 1.0, "tier": "high", "baked": false, "screen_light": 0.7, "movement": "fixed", "floor_ready": true, "stage": "", "stage_progress": -1.0}
	var menu := Menu.new()
	menu.library = library
	menu.scene_import = Pictures.new()
	viewport.add_child(menu.scene_import)
	menu.state_provider = func(_mode): return {"selected": "dark", "choice": "dark", "status": "", "busy": false, "scene_import": scenes.duplicate(true)}
	menu.command.connect(func(operation, value): commands.append([operation, value]))
	viewport.add_child(menu)
	menu.position = Vector3(0, 0, -2.2)
	menu.open("global")
	await save_frame(viewport, camera, menu, output.path_join("scene-empty.png"))
	menu._activate(menu.ADD)
	_check(menu.modal == "add", "The add card asks what to add")
	await save_frame(viewport, camera, menu, output.path_join("add.png"))
	menu._activate(menu.ADD_SCENE)
	_check(commands.back() == ["scene_add", null] and menu.modal.is_empty(), "A 3D scene asks for a scene file")
	menu._activate(menu.ADD)
	menu._activate(menu.ADD_IMAGE)
	_check(commands.back() == ["add", null], "A panorama asks for images")

	scenes.rows = [
		{"id": "a1", "title": "Crystal Palace Cinema", "added": 1, "thumb": true, "summary": {"high": {"triangles": 423713, "culled": 0, "over_budget": []}}},
		{"id": "b2", "title": "天外星宫", "added": 2, "summary": {"high": {"triangles": 794474, "culled": 15, "over_budget": [], "source": "unity"}}},
		{"id": "c3", "title": "Sponza", "added": 3, "summary": {}},
		{"id": "d4", "title": "Simple Modern Living Room", "added": 4, "summary": {"high": {"triangles": 73502, "culled": 0, "over_budget": []}}},
	]
	scenes.active = "b2"
	scenes.baked = true
	menu.refresh()
	await save_frame(viewport, camera, menu, output.path_join("scene-list.png"))
	_check(menu._cards.filter(func(card): return card.get("scene", false)).size() == 3 and menu._chosen() == "b2", "The viewer's 3D scenes sit in their own section, the one in use chosen")
	_check(menu._cards.filter(func(card): return not card.get("builtin", false)).map(func(card): return card.id) == ["d4", "c3", "b2"], "The newest scene comes first")
	var first: int = menu._cards.find_custom(func(card): return card.get("id") == "d4")
	menu._activate(menu.CARD + first)
	_check(commands.back() == ["scene_select", "d4"], "Pressing a 3D scene asks to use it")
	menu._activate(menu.NEXT)
	_check(menu.page == 1, "A fourth entry goes to a second page")
	menu._activate(menu.PREVIOUS)
	menu.mode = "image"
	menu.refresh()
	_check(not menu._cards.any(func(card): return card.get("scene", false)), "3D scenes are not offered where they cannot be used")
	menu.mode = "global"
	menu.refresh()

	menu._activate(menu.ADJUST)
	_check(menu.view == "adjust", "A 3D scene in use can be adjusted")
	await save_frame(viewport, camera, menu, output.path_join("adjust.png"))
	menu._choice_changed("scene_screen_light", 1.0)
	_check(commands.back() == ["adjust", {"mode": "global", "key": "scene_screen_light", "value": 1.0}], "Its screen light is a setting")
	menu._activate(menu.CURRENT)
	_check(commands.back() == ["scene_home", "global"], "Return to start goes back to where the scene put the viewer")
	menu.navigate_back()

	# A file was just picked while the viewer was on the second page: its card leads the first.
	menu._activate(menu.NEXT)
	var settled: Array = scenes.rows.duplicate()
	scenes.rows = settled + [{"id": "adding", "title": "heiligenkreuzerhof", "added": 9, "summary": {}, "thumb": false}]
	scenes.pending = "adding"
	scenes.busy = true
	scenes.stage = "Copying file"
	scenes.stage_progress = 0.42
	menu.show_added_scene()
	await save_frame(viewport, camera, menu, output.path_join("scene-copying.png"))
	var custom: Array = menu._cards.filter(func(card): return not card.get("builtin", false))
	_check(menu.page == 0 and custom[0].id == "adding" and menu._stage_text() == I18n.t("Copying file") + " 42%", "A picked file shows at once as the first card, with what is being done to it")
	sent = commands.size()
	menu._activate(menu.CARD + menu._cards.find(custom[0]))
	_check(commands.size() == sent, "Its card does nothing until the copy is in")
	scenes.rows = settled + [{"id": "e5", "title": "heiligenkreuzerhof", "added": 9, "summary": {}, "thumb": false}]
	scenes.pending = "e5"
	scenes.busy = false
	scenes.stage = "Compressing textures"
	scenes.stage_progress = 0.6
	menu.refresh()
	await save_frame(viewport, camera, menu, output.path_join("scene-importing.png"))
	_check(menu._chosen() == "e5" and menu._scene_status().contains(I18n.t("Compressing textures")), "The import stages follow on the same card")
	scenes.rows = settled
	scenes.pending = ""
	scenes.stage = ""
	scenes.stage_progress = -1.0
	scenes.error = "Scene file is larger than 768 MB"
	menu.refresh()
	await save_frame(viewport, camera, menu, output.path_join("scene-error.png"))
	scenes.error = ""

	# Two panoramas join them: every card says which kind it is.
	library.assets["p1"] = {"title": "海边日落", "created": 0, "geometry": 3}
	library.assets["p2"] = {"title": "Studio VR180", "created": 5, "geometry": 1}
	library.bindings["image"] = {"id": "p1"}
	menu.refresh()
	await save_frame(viewport, camera, menu, output.path_join("scene-mixed.png"))
	_check(menu._tips[menu.CARD + menu._cards.find_custom(func(card): return card.get("id") == "p2")].contains(I18n.t("Panorama image"))
		and menu._tips[menu.CARD + menu._cards.find_custom(func(card): return card.get("id") == "d4")].contains(I18n.t("3D scene")), "Each card says whether it is a panorama or a 3D scene")
	menu._activate(menu.MANAGE)
	await save_frame(viewport, camera, menu, output.path_join("manage.png"))
	_check(menu._cards.size() == 6, "Management lists everything the viewer added")
	menu._activate(menu.RENAMES + 2)
	_check(menu.modal == "rename" and menu.rename_id == "c3", "A 3D scene can be renamed")
	menu.editor.cancel()
	menu.draft = "Atrium"
	menu._save_name()
	_check(commands.back() == ["scene_rename", {"id": "c3", "title": "Atrium"}] and menu.modal.is_empty(), "The new name goes to the scene library")
	menu._activate(menu.REMOVES + 3)
	_check(menu.modal == "delete" and menu.selected == ["b2"], "The trash button asks before removing")
	await save_frame(viewport, camera, menu, output.path_join("remove.png"))
	_check(menu.navigate_back() and menu.modal.is_empty() and menu.view == "manage", "Back leaves the confirmation, not the page")
	menu._activate(menu.REMOVES + 3)
	menu._activate(menu.CONFIRM)
	_check(commands.back() == ["scene_remove", ["b2"]], "Confirming removes that scene")
	_check(menu.navigate_back() and menu.view == "scene", "Back returns to the scene page")

	I18n.use("en")
	menu.refresh()
	await save_frame(viewport, camera, menu, output.path_join("scene-list-en.png"))
	library.assets.clear()
	library.bindings.clear()
	# A build without scene import still shows the option, announced and inert.
	I18n.use("zh")
	menu.scene_import.queue_free()
	menu.scene_import = null
	menu.state_provider = func(_mode): return {"selected": "dark", "choice": "dark", "status": "", "busy": false}
	menu.open("global")
	menu._activate(menu.ADD)
	await save_frame(viewport, camera, menu, output.path_join("add-no-scenes.png"))
	sent = commands.size()
	menu._activate(menu.ADD_SCENE)
	_check(menu.modal == "add" and commands.size() == sent and menu._buttons.any(func(button): return button.target == menu.ADD_SCENE and not button.enabled), "Without the scene importer its button does nothing")
	menu._activate(menu.ADD_IMAGE)
	_check(commands.back() == ["add", null], "Panoramas are still added from there")
	for failure in failures: push_error(failure)
	print("Scene import menu: %d failures; frames in %s" % [failures.size(), output])
	quit(0 if failures.is_empty() else 1)
