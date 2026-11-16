extends SceneTree
## Renders the scene gallery page and the scene-settings shortcut to build/output/scene-gallery/menu
## for review, and checks that presses turn into the right commands and the page is remembered.
const Menu := preload("res://scripts/scenery_menu.gd")
const Library := preload("res://scripts/background_library.gd")
const Gallery := preload("res://scripts/scene_import/scene_gallery.gd")
const GalleryView := preload("res://scripts/scene_import/scene_gallery_view.gd")
const I18n := preload("res://scripts/i18n.gd")
var commands: Array = []
var controls: Array = []
var failures: Array[String] = []
var checks := 0

class Pictures extends Node:
	## Stands in for the controller: the pictures that ship with the catalogue.
	var gallery := Gallery.new()
	func gallery_preview(slug: String) -> Texture2D: return gallery.preview(slug)
	func thumbnail(_id: String) -> Texture2D: return null

func _initialize() -> void: _run.call_deferred()

func _check(ok: bool, label: String) -> void:
	checks += 1
	if not ok: failures.append(label)

func save_frame(viewport: SubViewport, camera: Camera3D, menu: Node3D, path: String, below: float = 0.06) -> void:
	await create_timer(.15).timeout
	await RenderingServer.frame_post_draw
	var a := camera.unproject_position(menu.to_global(Vector3(-.80, menu._top + .055, 0)))
	var b := camera.unproject_position(menu.to_global(Vector3(.80, menu._bottom - below, 0)))
	var rectangle := Rect2i(Vector2i(a.floor()), Vector2i((b - a).ceil())).intersection(Rect2i(Vector2i.ZERO, viewport.size))
	viewport.get_texture().get_image().get_region(rectangle).save_png(path)

func _press(menu: Node, slug: String) -> void:
	menu._activate(menu.CARD + menu._cards.find_custom(func(card): return card.get("slug") == slug))

func _run() -> void:
	I18n.use("zh")
	var output := ProjectSettings.globalize_path("res://../../build/output/scene-gallery/menu")
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
	var pictures := Pictures.new()
	pictures.gallery.load_catalog()
	viewport.add_child(pictures)
	var gallery: Node = pictures.gallery
	_check(gallery.rows.size() >= 9, "The catalogue that ships with the app loads")
	var installed := {}
	var scenes := {"rows": [], "active": "", "pending": "", "busy": false, "error": "", "tier": "high", "baked": false, "screen_light": 0.7,
		"movement": "fixed", "floor_ready": true, "stage": "", "stage_progress": -1.0, "own_sky": false, "backdrop": "", "play_dim": 1.0}
	var anchor := [""]
	var selected_background := ["dark"]
	var menu := Menu.new()
	menu.library = library
	menu.scene_import = pictures
	menu.state_provider = func(_mode):
		var state: Dictionary = scenes.duplicate(true)
		state["gallery"] = {"rows": gallery.snapshot(installed), "anchor": anchor[0]}
		return {"selected": selected_background[0], "choice": selected_background[0], "status": "", "busy": false, "scene_import": state}
	menu.command.connect(func(operation, value): commands.append([operation, value]))
	menu.session_control_requested.connect(func(operation): controls.append(operation))
	viewport.add_child(menu)
	menu.position = Vector3(0, 0, -2.2)
	menu.open("global")
	await save_frame(viewport, camera, menu, output.path_join("scene-page.png"))
	_check(menu._buttons.any(func(button): return button.target == menu.GALLERY), "The scene page offers the gallery")
	menu._activate(menu.GALLERY)
	_check(menu.view == "gallery" and menu._cards.size() == GalleryView.PER_PAGE, "The gallery shows eight scenes a page")
	_check(commands.back() == ["gallery_anchor", str(gallery.rows[0].slug)], "Where the viewer is in the gallery is noted by its first scene")
	await save_frame(viewport, camera, menu, output.path_join("gallery.png"))

	var first := str(gallery.rows[0].slug)
	var second := str(gallery.rows[1].slug)
	var third := str(gallery.rows[2].slug)
	var fourth := str(gallery.rows[3].slug)
	var fifth := str(gallery.rows[4].slug)
	_press(menu, first)
	_check(commands.back() == ["gallery_get", first], "Pressing a scene asks for it")
	# One on show, one here, one coming down, one waiting, one that failed, one withdrawn.
	installed[first] = "a1"
	installed[second] = "b2"
	scenes.rows = [{"id": "a1", "title": "x", "added": 1, "summary": {}}, {"id": "b2", "title": "y", "added": 2, "summary": {}}]
	scenes.active = "a1"
	gallery.states[third] = {"state": Gallery.QUEUED}
	gallery.states[fourth] = {"state": Gallery.FAILED, "error": "No connection"}
	gallery.states[fifth] = {"state": Gallery.WITHDRAWN}
	menu.refresh()
	await save_frame(viewport, camera, menu, output.path_join("gallery-states.png"))
	_press(menu, second)
	_check(commands.back() == ["scene_select", "b2"], "A scene already here opens")
	_press(menu, third)
	_check(commands.back() == ["gallery_cancel", third], "A scene that is waiting can be given up")
	_press(menu, fourth)
	_check(commands.back() == ["gallery_get", fourth], "A scene that failed is asked for again")
	var sent := commands.size()
	_press(menu, fifth)
	_check(commands.size() == sent and menu._tips[menu.CARD + 4] == I18n.t("Withdrawn for copyright or other reasons"), "A withdrawn scene says so and does nothing")
	_check(menu._tips[menu.CARD + 1].contains(str(gallery.rows[1].author)) and menu._tips[menu.CARD + 1].contains(str(gallery.rows[1].license)), "Each card credits the work, its author and the licence")

	# The page is kept: across leaving the gallery, closing the menu, and restarting the app.
	menu._activate(menu.NEXT)
	_check(menu.page == 1 and commands.back() == ["gallery_anchor", str(gallery.rows[GalleryView.PER_PAGE].slug)], "Turning the page moves the noted place")
	await save_frame(viewport, camera, menu, output.path_join("gallery-page-2.png"))
	menu.navigate_back()
	_check(menu.view == "scene", "Back returns to the scene page")
	menu._activate(menu.GALLERY)
	_check(menu.page == 1, "Coming back lands on the page that was left")
	menu.dismiss()
	menu.open("global")
	menu._activate(menu.GALLERY)
	_check(menu.page == 1, "Reopening the menu keeps the gallery's page too")
	var later := Menu.new()
	later.library = library
	later.scene_import = pictures
	anchor[0] = str(gallery.rows[GalleryView.PER_PAGE * 2 + 1].slug)
	later.state_provider = menu.state_provider
	viewport.add_child(later)
	later.open("global")
	later._activate(later.GALLERY)
	_check(later.page == 2, "After a restart the gallery opens on the page holding the scene last noted")
	later.queue_free()

	# Every scene is named in each language the app speaks.
	for language in ["en", "zh_Hant", "ja"]:
		I18n.use(language)
		menu.page = 0
		menu.refresh()
		await save_frame(viewport, camera, menu, output.path_join("gallery-%s.png" % language))
		var named: Array = gallery.snapshot({}).map(func(card): return GalleryView.title(card))
		_check(not named.has("") and (language == "en" or named != gallery.rows.map(func(row): return row.title)), "Scenes have names in " + language)
	I18n.use("zh")
	_check(gallery.rows.all(func(row): return not str(row.title_zh).is_empty() and not str(row.title_zh_hant).is_empty() and not str(row.title_ja).is_empty()), "No scene is missing a name in any language")

	# In the viewer's own scene the footer carries a shortcut to that scene's settings.
	menu.session_controls_provider = func(): return {"scene_move": "stand", "passthrough_visible": true}
	menu.navigate_back()
	menu.refresh()
	_check(menu._buttons.any(func(button): return button.target == menu.SCENE_SETTINGS), "A scene of the viewer's own puts its settings in the footer")
	await save_frame(viewport, camera, menu, output.path_join("footer-settings.png"), 0.2)
	menu._activate_footer(menu.SCENE_SETTINGS)
	_check(controls.back() == "scene_settings", "Pressing it asks for the scene's settings")
	menu.show_adjust()
	_check(menu.view == "adjust" and menu.modal.is_empty(), "Which opens straight on the adjust page")
	await save_frame(viewport, camera, menu, output.path_join("adjust.png"), 0.2)
	menu.session_controls_provider = func(): return {"cinema_visible": true, "cinema_lights": "auto"}
	menu.refresh()
	_check(not menu._buttons.any(func(button): return button.target == menu.SCENE_SETTINGS), "The built-in cinema keeps its own two shortcuts")

	# With many scenes of the viewer's own, the scene page opens on the one in use.
	menu.session_controls_provider = Callable()
	scenes.rows = []
	for index in 8: scenes.rows.append({"id": "s%d" % index, "title": "Scene %d" % index, "added": index, "summary": {}})
	scenes.active = "s1"
	installed.clear()
	menu.dismiss()
	menu.open("global")
	_check(menu.page == 2 and menu._cards.any(func(card): return card.get("id") == "s1"), "The scene page opens on the page holding the scene in use")
	await save_frame(viewport, camera, menu, output.path_join("scene-page-located.png"))
	var gallery_button: Dictionary = menu._buttons.filter(func(button): return button.target == menu.GALLERY)[0]
	var manage_button: Dictionary = menu._buttons.filter(func(button): return button.target == menu.MANAGE)[0]
	_check(is_equal_approx(gallery_button.rect.get_center().y, manage_button.rect.get_center().y), "The gallery's way in sits in the row of the viewer's own scenes")
	_check(not menu._buttons.any(func(button): return button.target != menu.GALLERY and button.target > 0 and button.rect.intersects(gallery_button.rect)), "And overlaps nothing there, paging included")
	menu._activate(menu.PREVIOUS)
	menu._activate(menu.GALLERY)
	menu.navigate_back()
	_check(menu.page == 2, "Coming back from the gallery lands on that page again")

	# The corner line credits whoever made the scene in use, and changes with it.
	var corner := func() -> String:
		var found := ""
		for node in menu.get_children():
			if node is Label3D and is_equal_approx(node.position.y, menu._bottom + 0.018): found = node.text
		return found
	var credited: Dictionary = gallery.rows[5]
	var other: Dictionary = gallery.rows[9]
	installed[credited.slug] = "s1"
	installed[other.slug] = "s4"
	menu.mode = "global"
	menu.view = "scene"
	menu.refresh()
	_check(corner.call().contains(str(credited.author)) and corner.call().contains(str(credited.work)) and corner.call().contains(str(credited.license)), "Using a gallery scene puts its author, title and licence in the corner")
	await save_frame(viewport, camera, menu, output.path_join("scene-page-credit.png"))
	menu._activate(menu.ADJUST)
	_check(menu.view == "adjust" and corner.call().contains(str(credited.author)), "The credit stays on that scene's own page")
	menu.navigate_back()
	scenes.active = "s4"
	menu.refresh()
	_check(corner.call().contains(str(other.author)) and not corner.call().contains(str(credited.work)), "Choosing another gallery scene changes the credit to its author")
	scenes.active = "s6"
	menu.refresh()
	_check(corner.call().is_empty(), "A scene the viewer brought in themselves carries no credit line")
	scenes.active = ""
	selected_background[0] = "night"
	menu.refresh()
	_check(corner.call().begins_with("ESO/S. Brunier"), "The Milky Way panorama in use credits its source")
	_check(menu._tips[menu.CARD + menu._cards.find_custom(func(card): return card.get("id") == "night")].contains("ESO/S. Brunier"), "And its card always does, in its tooltip")
	selected_background[0] = "dark"
	menu.refresh()
	_check(corner.call().is_empty(), "With neither in use the corner is empty")
	scenes.active = "s1"
	installed.clear()

	# Image mode shows panoramas only: none of the viewer's 3D scenes, on the page or when managing, and no gallery.
	menu.mode = "image"
	menu.view = "scene"
	menu.refresh()
	_check(not menu._cards.any(func(card): return card.get("scene", false)) and not menu._buttons.any(func(button): return button.target == menu.GALLERY), "Image mode offers no 3D scenes and no gallery")
	menu._activate(menu.MANAGE)
	_check(menu.view == "manage" and not menu._cards.any(func(card): return card.get("scene", false)), "Nor are 3D scenes listed when managing in image mode")
	menu.mode = "global"
	menu.refresh()
	_check(menu._cards.filter(func(card): return card.get("scene", false)).size() == 8, "In global mode managing lists them all")

	for failure in failures: print("FAIL ", failure)
	print("Scene gallery menu: %d checks, %d failures" % [checks, failures.size()])
	quit(1 if not failures.is_empty() else 0)
