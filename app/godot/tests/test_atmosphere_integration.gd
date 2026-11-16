extends SceneTree
## The atmosphere controller inside the running player: settings, the scene menu's row, a
## picture's folder and its keep-out rectangle.
const Main := preload("res://scripts/main.gd")
const Memory := preload("res://scripts/atmosphere/atmosphere_memory.gd")
var checks := 0
var failures: Array = []

func check(value: bool, message: String, detail: Variant = null) -> void:
	checks += 1
	if not value: failures.append(message); printerr(message + ("" if detail == null else ": " + str(detail)))

func _initialize() -> void: _run.call_deferred()

func settle(seconds: float) -> void:
	await create_timer(seconds).timeout

func _run() -> void:
	var directory := ProjectSettings.globalize_path("res://../../build/output/atmosphere/integration-") + str(Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(directory)
	var config := ConfigFile.new(); config.set_value("appearance", "background", "dark"); config.set_value("ui", "language", "zh")
	config.set_value("atmosphere", "theme", "rain"); config.set_value("atmosphere", "amount", 2)
	var settings_path := directory.path_join("settings.cfg"); config.save(settings_path)
	var main := Main.new(); main.settings_path = settings_path; root.add_child(main)
	await process_frame
	var air: Node = main.atmosphere
	air.memory = Memory.new(directory.path_join("memory")); air.memory.load_saved()
	check(air.theme_global == "rain" and air.amount == 2 and air.sound_on and air.theme_photo == "", "Saved choices are restored")
	await settle(0.4)
	check(air.field.theme == "rain" and air.field.particle_count() == 1120 and air.field.opacity > 0.0, "The library shows the global theme", [air.field.theme, air.field.particle_count(), air.field.opacity])
	check(air.last.keep == "" and air.field.layers[0].material.get_shader_parameter("screen_half") == Vector2.ZERO, "Nothing to keep clear without a picture")

	# The scene menu's row.
	main.scenery.open(main.recent_menu)
	var menu: Node3D = main.scenery_menu
	check(menu._state.get("atmosphere", {}).get("theme", "") == "rain", "Menu reads the global theme", menu._state.get("atmosphere"))
	check(menu._buttons.any(func(item): return item.target == menu.ENTRY_ATMOSPHERE), "The scene page shows the way in to the themes")
	menu._activate(menu.ENTRY_ATMOSPHERE)
	check(menu.view == "atmosphere" and menu._buttons.any(func(item): return item.target == menu.ATMOSPHERE + 2), "Its page draws the theme row")
	menu._activate(menu.ATMOSPHERE + 2)
	check(air.theme_global == "snow" and menu._state.atmosphere.theme == "snow", "Choosing a theme applies and redraws")
	menu._activate(menu.ATMOSPHERE_AMOUNT); menu._activate(menu.ATMOSPHERE_SOUND)
	check(air.amount == 0 and not air.sound_on, "Amount cycles and sound toggles", [air.amount, air.sound_on])
	var saved := ConfigFile.new(); saved.load(settings_path)
	check(saved.get_value("atmosphere", "theme", "") == "snow" and saved.get_value("atmosphere", "amount", -1) == 0 and saved.get_value("atmosphere", "sound", true) == false, "Choices are saved")
	main.scenery_menu.dismiss()
	await settle(2.2)
	check(air.field.theme == "snow" and air.field.particle_count() == 350 and air.field.opacity > 0.0, "The old theme fades out before the new one is built", [air.field.theme, air.field.particle_count()])

	# A flat picture: the picture default applies, the picture is kept clear, its folder remembers.
	var folder := directory.path_join("trip"); DirAccess.make_dir_recursive_absolute(folder)
	var source := folder.path_join("flat.png")
	var image := Image.create(320, 180, false, Image.FORMAT_RGB8); image.fill(Color(.3, .4, .2)); image.save_png(source)
	main.photo.open_image("file://" + source, "Flat")
	main.photo_active = true; main.player_menu = main.photo_menu
	var deadline := Time.get_ticks_msec() + 20000
	while main.photo.loading and Time.get_ticks_msec() < deadline: await process_frame
	await settle(2.0)
	check(air.last.theme == "" and air.field.opacity == 0.0, "Pictures start without a theme", air.last)
	main.scenery.open(main.photo_menu)
	check(menu.mode == "image" and menu._state.atmosphere.folder == true and menu._state.atmosphere.theme == "", "The image tab is scoped to the picture's folder", menu._state.atmosphere)
	menu._activate(menu.ATMOSPHERE + 3)
	check(air.theme_photo == "" and air.theme_global == "snow", "A folder's choice leaves the defaults alone")
	check(air.memory.lookup("file://" + folder) == {"theme": "leaves"}, "The folder remembers", air.memory.lookup("file://" + folder))
	main.scenery_menu.dismiss()
	await settle(0.5)
	check(air.field.theme == "leaves" and air.last.keep == "photo", "The folder's theme shows around the picture", air.last)
	var half: Vector2 = air.field.layers[0].material.get_shader_parameter("screen_half")
	check(half.x > 0.0 and is_equal_approx(half.x / half.y, 16.0 / 9.0), "The picture's rectangle reaches the shader", half)
	check(not air.last.audible, "Sound stays off when switched off")
	air.command("image", "sound", true)
	await settle(0.3)
	check(air.last.audible and air.sound.theme == "leaves" and air.sound.player.playing, "The recording plays with the picture", [air.last, air.sound.theme])

	# Clearing per-file settings forgets the folder.
	main._clear_file_settings(false)
	check(air.memory.lookup("file://" + folder).is_empty(), "Clearing settings forgets folders")
	await settle(2.0)
	check(air.field.opacity == 0.0 and air.last.theme == "", "The picture returns to its default", air.last)

	# A puzzle of the picture: the theme stays, and the board is what is kept clear.
	air.command("image", "theme", "snow")
	var host: Node = main.puzzle_game
	host.store = load("res://scripts/puzzle/puzzle_store.gd").new(directory.path_join("puzzles"))
	check(host.start(), "A puzzle starts from the picture")
	deadline = Time.get_ticks_msec() + 8000
	while host.active and host.panel.preparing and Time.get_ticks_msec() < deadline: await create_timer(0.01).timeout
	await settle(0.5)
	check(host.session != null and not host.session.spherical and air.last.keep == "puzzle" and air.last.theme == "snow", "The puzzle shows the picture's theme", air.last)
	check(air.field.layers[0].material.get_shader_parameter("screen_half") == host.session.frame_size() * 0.5, "The puzzle board is kept clear",
		air.field.layers[0].material.get_shader_parameter("screen_half") if not air.field.layers.is_empty() else null)

	print("Atmosphere integration: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
