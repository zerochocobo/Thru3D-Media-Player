extends SceneTree
## The viewer's scene library and the controller that shows one scene over the dark background,
## against a stand-in for the player (no headset, no plugin).
const Library := preload("res://scripts/scene_import/scene_import_library.gd")
const Controller := preload("res://scripts/scene_import/scene_import_controller.gd")
const Cache := preload("res://scripts/scene_import/scene_import_cache.gd")
var checks := 0
var failures: Array[String] = []
var output := ProjectSettings.globalize_path("res://../../build/output/scene-import/library")

class Background extends Node:
	var choice := "cinema"

class Scenery extends Node:
	var host: Node
	func select(mode: String, id: String) -> void:
		host.background.choice = id
		if mode == "global" and host.scene_import: host.scene_import.background_selected()
		host._update_background()

class Flat extends Node3D:
	var size := Vector2(4.0, 2.25)

class Film extends Node:
	## Stands in for the film sampler: a steady warm picture.
	var colors: Array[Color] = [Color(0.8, 0.4, 0.2), Color(0.8, 0.4, 0.2), Color(0.8, 0.4, 0.2)]
	func update(_delta: float, _video: Node, _active: bool, _fraction: float) -> bool: return true

class Video extends Node3D:
	var geometry := 0
	var flat_pose := Transform3D(Basis.IDENTITY, Vector3(0, 1.5, -3))
	var _flat := Flat.new()
	var playing := false
	var placed := 0
	func _init() -> void: add_child(_flat)
	func has_active_presentation() -> bool: return playing
	func set_flat_world_pose(pose: Transform3D) -> void:
		flat_pose = global_transform.affine_inverse() * pose
		placed += 1

class Display extends RefCounted:
	var environment := Environment.new()

class App extends Node3D:
	var video := Video.new()
	var display := Display.new()
	var photo_active := false
	var settings := ConfigFile.new()
	var settings_path := ""
	var background := Background.new()
	var scenery := Scenery.new()
	var xr_origin := Node3D.new()
	var xr_camera := Node3D.new()
	var low_end_gpu := false
	var scene_import: Node
	var updates := 0
	var shown := false
	func _init() -> void:
		scenery.host = self
		for node in [background, scenery, xr_origin, video]: add_child(node)
		xr_origin.add_child(xr_camera)
	func _update_background() -> void:
		updates += 1
		if scene_import: shown = scene_import.present(background.choice == "dark")

func _initialize() -> void:
	_run.call_deferred()

func _check(ok: bool, label: String) -> void:
	checks += 1
	if not ok: failures.append(label)

func _clear(directory: String) -> void:
	if not DirAccess.dir_exists_absolute(directory): return
	for sub in DirAccess.get_directories_at(directory): _clear(directory.path_join(sub))
	for file in DirAccess.get_files_at(directory): DirAccess.remove_absolute(directory.path_join(file))
	DirAccess.remove_absolute(directory)

func _glb(path: String, size: float) -> void:
	var scene := Node3D.new()
	var floor := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = Vector3(size, 1, size)
	floor.mesh = mesh
	floor.name = "Floor"
	floor.position = Vector3(0, -.5, 0)
	scene.add_child(floor)
	floor.owner = scene
	var document := GLTFDocument.new()
	var state := GLTFState.new()
	document.append_from_scene(scene, state)
	document.write_to_filesystem(state, path)
	scene.free()

func _settle(library: Node) -> void:
	while library.busy: await process_frame

func _run() -> void:
	_clear(output)
	DirAccess.make_dir_recursive_absolute(output)
	var first := output.path_join("Plaza.glb")
	var second := output.path_join("Hall.glb")
	_glb(first, 20.0)
	_glb(second, 30.0)
	var home := output.path_join("store")

	var library := Library.new()
	library.directory = home
	root.add_child(library)
	library.load_catalog()
	_check(library.entries.is_empty(), "A new library starts empty")
	_check(not library.add(output.path_join("notes.txt"), "notes.txt") and library.error == "Unsupported scene format", "Other file types are refused")
	_check(library.add(first, "Plaza.glb") and library.busy, "A scene file starts copying")
	await _settle(library)
	_check(library.entries.size() == 1 and library.rows()[0].title == "Plaza" and FileAccess.file_exists(library.source_path(str(library.rows()[0].id))), "The copy is kept and listed under its name")
	library.add(first, "Plaza again.glb")
	await _settle(library)
	_check(library.entries.size() == 1 and DirAccess.get_files_at(home.path_join("sources")).size() == 1, "The same file again adds nothing")
	library.add(second, "Hall.glb")
	await _settle(library)
	_check(library.entries.size() == 2, "A second scene is added")
	var reopened := Library.new()
	reopened.directory = home
	root.add_child(reopened)
	reopened.load_catalog()
	_check(reopened.entries.size() == 2, "The catalog survives a restart")
	reopened.queue_free()
	var plaza := ""
	var hall := ""
	for row in library.rows():
		if row.title == "Plaza": plaza = str(row.id)
		else: hall = str(row.id)
	library.queue_free()
	await process_frame

	var app := App.new()
	app.settings_path = output.path_join("settings.cfg")
	root.add_child(app)
	var controller := Controller.new()
	controller.library.directory = home
	app.scene_import = controller
	app.add_child(controller)
	controller.setup(app)
	_check(controller.library.entries.size() == 2 and controller.active_id.is_empty(), "The controller opens the same library with nothing active")
	controller.activate(plaza)
	_check(controller.pending_id == plaza and app.background.choice == "dark", "Using a scene switches to the dark background and starts loading")
	while not controller.pending_id.is_empty(): await process_frame
	var shown := app.find_child("Floor", true, false) as MeshInstance3D
	_check(controller.active_id == plaza and app.shown and shown != null and shown.is_visible_in_tree(), "The loaded scene is shown")
	_check(app.settings.get_value("scene_import", "active", "") == plaza, "The choice is remembered")
	_check(int(controller.library.entries[plaza].summary.get("high", {}).get("triangles", 0)) == 12, "The scene's cost is recorded for its card")
	_check(controller.library.rename(plaza, "  Town square ") and controller.snapshot().rows.any(func(row): return row.id == plaza and row.title == "Town square") and not controller.library.rename(plaza, " "),
		"A scene takes a new name, and never an empty one")
	if DisplayServer.get_name() != "headless":
		for frame in 8: await process_frame
		_check(FileAccess.file_exists(controller.library.thumbnail_path(plaza)) and controller.thumbnail(plaza) != null and controller.snapshot().rows[0].thumb,
			"The first showing leaves a picture for the scene's card")
	var state: Dictionary = controller.snapshot()
	_check(state.active == plaza and state.rows.size() == 2 and not state.busy, "The menu state reports the scene in use")
	_check(app.display.environment.ambient_light_source == Environment.AMBIENT_SOURCE_COLOR and is_equal_approx(app.display.environment.ambient_light_energy, Controller.AMBIENT),
		"A glTF scene on show is given ambient light")
	controller._film.queue_free()
	controller._film = Film.new()
	controller.add_child(controller._film)
	await process_frame
	_check(not controller._lamp.visible, "No screen light while nothing plays")
	app.video.playing = true
	for frame in 40: await process_frame
	_check(controller._lamp.visible and controller._lamp.light_color.r > controller._lamp.light_color.b
		and controller._lamp.global_position.distance_to(Vector3(0, 1.5, -3)) < 0.3 and (-controller._lamp.global_transform.basis.z).dot(Vector3(0, 0, 1)) > 0.9,
		"A playing picture lights the scene from the screen, in the picture's colour")
	var level: float = controller.screen_light
	for step in 4: controller.cycle_screen_light()
	_check(is_equal_approx(controller.screen_light, level) and controller.snapshot().has("screen_light"), "The screen light level cycles through its four settings")
	while controller.screen_light > 0.0: controller.cycle_screen_light()
	await process_frame
	_check(not controller._lamp.visible and app.settings.get_value("scene_import", "screen_light", 1.0) == 0.0, "Turned off, the screen throws no light, and the choice is kept")
	while not is_equal_approx(controller.screen_light, 0.7): controller.cycle_screen_light()
	controller.present(false)
	_check(not shown.is_visible_in_tree() and not controller._lamp.visible and app.display.environment.ambient_light_source != Environment.AMBIENT_SOURCE_COLOR,
		"Hidden, the scene takes its light and ambient with it")
	controller.present(true)
	_check(app.video.placed == 0, "Without a screen marker the ordinary screen is left where it is")
	app.video.playing = false

	controller.activate(hall)
	while not controller.pending_id.is_empty(): await process_frame
	await process_frame
	_check(controller.active_id == hall and app.find_children("Floor", "MeshInstance3D", true, false).size() == 1, "Choosing another scene replaces the first")
	app.scenery.select("global", "cinema")
	await process_frame
	_check(controller.active_id.is_empty() and app.find_child("Floor", true, false) == null and app.settings.get_value("scene_import", "active", "x") == "", "Choosing a built-in background turns the imported scene off")

	app.scenery.select("global", "dark")
	controller.activate(plaza)
	while not controller.pending_id.is_empty(): await process_frame
	var cached := Cache.has(Cache.key(controller.library.source_path(plaza), "high"), home)
	controller.remove([plaza])
	await process_frame
	_check(cached and controller.active_id.is_empty() and not controller.library.entries.has(plaza) and app.find_child("Floor", true, false) == null, "Removing the scene in use turns it off first")
	_check(DirAccess.get_files_at(home.path_join("sources")).size() == 1 and Cache.entries(home).size() == 1, "Removal deletes the copy and its cache, and leaves the other scene")
	_check(not FileAccess.file_exists(controller.library.thumbnail_path(plaza)), "Removal deletes the scene's picture")

	# A restart on the dark background returns to the scene that was in use.
	controller.activate(hall)
	while not controller.pending_id.is_empty(): await process_frame
	controller.queue_free()
	await process_frame
	await process_frame
	var again := Controller.new()
	again.library.directory = home
	app.scene_import = again
	app.add_child(again)
	again.setup(app)
	await process_frame
	while not again.pending_id.is_empty(): await process_frame
	_check(again.active_id == hall, "The scene in use comes back after a restart")
	app.background.choice = "cinema"
	again.queue_free()
	await process_frame
	var other := Controller.new()
	other.library.directory = home
	app.scene_import = other
	app.add_child(other)
	other.setup(app)
	await process_frame
	_check(other.pending_id.is_empty() and other.active_id.is_empty(), "It stays off when another background was chosen meanwhile")

	var broken := FileAccess.open(home.path_join("library.json"), FileAccess.WRITE)
	broken.store_string('{"entries": {"../../evil": {"file": "../../evil.glb"}, "zz": 5, "%s": {"file": "missing.glb"}}}' % hall)
	broken.close()
	other.library.load_catalog()
	_check(other.library.entries.is_empty(), "A damaged catalog cannot point outside the library")
	for failure in failures: push_error(failure)
	print("Scene import library: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
