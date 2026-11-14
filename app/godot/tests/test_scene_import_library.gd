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

	# Moving through the scene uses the built-in scenes' gestures; the scene slides around the viewer.
	var home_at := shown.global_position
	var floor_top := home_at.y + 0.5
	_check(controller.movable() and controller.interaction == "watch" and not controller.poll_sticks(Vector2(0, 1), Vector2.ZERO, 0.2)
		and shown.global_position.is_equal_approx(home_at), "A scene starts with the viewer in place")
	controller.cycle_movement()
	_check(controller.interaction == "move" and controller.motion.mode == "walk" and not controller.snapshot().floor_ready, "The switch goes to walking first, and the floor is looked for")
	while not controller.motion.prepared: await process_frame
	var hand_at := Vector3(0.2, 1.2, 0)
	var aim := Vector3(0, -0.2, -1).normalized()
	var landing: Dictionary = controller.motion.ray_hit(hand_at, aim)
	_check(landing.get("kind") == "floor" and landing.valid and landing.position.z < -2.0 and absf(landing.position.y - floor_top) < 0.01, "An arc from the hand finds the floor ahead")
	_check(not controller.motion.ray_hit(Vector3(30, 1.2, 0), aim).get("valid", true), "Where there is no floor there is nowhere to land")
	_check(controller.pointer_press("right_hand", hand_at, aim) and not controller.pointer_press("left_hand", hand_at, aim), "One hand aims at a time")
	controller.update_pointer("right_hand", hand_at, aim)
	_check(controller.motion._visuals.right_hand.root.visible and controller.motion._visuals.right_hand.ring.visible, "The arc and its landing ring show while aiming")
	controller.pointer_release("right_hand", hand_at, aim, true)
	_check(shown.global_position.is_equal_approx(home_at - landing.position)
		and not controller.motion._visuals.right_hand.root.visible, "Letting go lands there: the chosen spot comes under the viewer's feet")
	var landed_at := shown.global_position
	controller.pointer_press("right_hand", Vector3(30, 1.2, 0), aim)
	controller.pointer_release("right_hand", Vector3(30, 1.2, 0), aim, true)
	_check(shown.global_position.is_equal_approx(landed_at), "A landing that is not valid goes nowhere")
	controller.poll_sticks(Vector2(0, 1), Vector2(1, 0), 0.1)
	_check(absf(absf(shown.global_rotation.y) - PI / 6.0) < 0.01 and absf(shown.global_position.y - landed_at.y) < 0.001, "A flick turns the viewer one step, and walking never drifts on the stick")
	controller.poll_sticks(Vector2.ZERO, Vector2.ZERO, 0.1)
	controller.poll_sticks(Vector2.ZERO, Vector2(0, -1), 0.1)
	_check(absf(absf(wrapf(shown.global_rotation.y, -PI, PI)) - 5.0 * PI / 6.0) < 0.01, "Pulling back turns the viewer round")
	controller.home()
	_check(shown.global_position.is_equal_approx(home_at) and is_zero_approx(shown.global_rotation.y), "Return to start puts the viewer back where the scene placed them")
	controller.cycle_movement()
	controller.poll_sticks(Vector2(0, 1), Vector2.ZERO, 0.25)
	_check(controller.motion.mode == "fly" and shown.global_position.z > home_at.z + 0.4 and is_equal_approx(shown.global_position.y, home_at.y), "Flying, a stick carries the viewer along the line of sight")
	var flown_to := shown.global_position
	controller.poll_sticks(Vector2(1, 0.9), Vector2.ZERO, 0.25)
	_check(shown.global_position.z > flown_to.z + 0.3 and is_zero_approx(shown.global_rotation.y), "A thumb rolling sideways mid-flight does not turn")
	controller.poll_sticks(Vector2.ZERO, Vector2.ZERO, 0.1)
	flown_to = shown.global_position
	controller.poll_sticks(Vector2(1, 0), Vector2.ZERO, 0.1)
	flown_to = shown.global_position
	controller.poll_sticks(Vector2(1, 0.9), Vector2.ZERO, 0.25)
	_check(absf(absf(shown.global_rotation.y) - PI / 6.0) < 0.01 and shown.global_position.is_equal_approx(flown_to), "Flying, a sideways flick turns one step and goes nowhere")
	controller.poll_sticks(Vector2.ZERO, Vector2.ZERO, 0.1)
	controller.poll_sticks(Vector2(0, -1), Vector2.ZERO, 0.25)
	_check(shown.global_position.distance_to(flown_to) > 0.3 and absf(absf(shown.global_rotation.y) - PI / 6.0) < 0.01, "Pulling back flies backwards rather than turning round")
	_check(not controller.pointer_press("right_hand", hand_at, aim), "Flying has no landing arc")
	controller.cycle_movement()
	_check(controller.interaction == "watch" and controller.motion.mode == "fixed", "A third press stays in place again")
	_check(controller.set_interaction("move") and controller.motion.mode == "fly" and controller.set_interaction("watch") and controller.interaction == "watch", "Free movement resumes the way of moving last used")
	controller.home()
	_check(controller.backdrop() == null and Controller.Unity.sky_backdrop(null) == null, "A scene without its own sky needs no backdrop")
	var sky := Sky.new()
	sky.sky_material = ShaderMaterial.new()
	(sky.sky_material as ShaderMaterial).set_shader_parameter("rotation", 0.5)
	var twin: ShaderMaterial = Controller.Unity.sky_backdrop(sky)
	_check(twin != null and twin.shader.get_mode() == Shader.MODE_SPATIAL and is_equal_approx(twin.get_shader_parameter("rotation"), 0.5), "A scene's own sky has a twin for when menus sit on layers")

	# Picking a file that is already here goes to that scene instead of copying it again.
	controller.add(second, "Hall.glb", FileAccess.get_size(second))
	_check(not controller.library.busy and controller.pending_id == hall and controller.error == "Already in My scenes" and DirAccess.get_files_at(home.path_join("sources")).size() == 2,
		"A file already in the library is recognised before anything is copied")
	while not controller.pending_id.is_empty(): await process_frame
	await process_frame
	# A new file shows as a card at once, and is used as soon as it is in.
	var third := output.path_join("Yard.glb")
	_glb(third, 12.0)
	controller.add(third, "Yard.glb", FileAccess.get_size(third))
	var arriving: Dictionary = controller.snapshot()
	_check(arriving.busy and arriving.pending == Controller.ADDING and arriving.stage == "Copying file" and arriving.rows.any(func(row): return row.id == Controller.ADDING and row.title == "Yard"),
		"A picked file has a card while it is still being copied")
	await _settle(controller.library)
	var yard := ""
	for row in controller.library.rows():
		if row.title == "Yard": yard = str(row.id)
	_check(not yard.is_empty() and controller.pending_id == yard and not controller.snapshot().stage.is_empty(), "Once copied it goes straight on to loading, stage by stage")
	while not controller.pending_id.is_empty(): await process_frame
	_check(controller.active_id == yard, "and is on show when that finishes")
	controller.remove([yard])
	await process_frame
	controller.activate(plaza)
	while not controller.pending_id.is_empty(): await process_frame
	shown = app.find_child("Floor", true, false) as MeshInstance3D

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
