extends SceneTree
const Main := preload("res://scripts/main.gd")
const Photo := preload("res://scripts/photo_display.gd")
const Menu := preload("res://scripts/photo_menu.gd")
const I18n := preload("res://scripts/i18n.gd")
var checks := 0
var failures: Array[String] = []
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)
func _initialize() -> void: call_deferred("run")
func run() -> void:
	var app := Main.new()
	var folder := "user://cache_settings_%d" % Time.get_ticks_usec()
	DirAccess.make_dir_recursive_absolute(folder)
	app.settings_path = folder.path_join("settings.cfg")
	# Exercise the production settings route without starting unrelated browser/cinema sessions.
	app.photo = Photo.new(); root.add_child(app.photo); app.photo.set_process(false)
	app.photo_menu = Menu.new(); app.photo_menu.state_provider = func(): return app.photo.snapshot()
	app.photo_menu.setting_requested.connect(app._on_photo_adjustment)
	root.add_child(app.photo_menu)
	app.photo_active = true; app.player_menu = app.photo_menu
	var menu: Node3D = app.photo_menu
	check(app.photo.cache_each == 1, "New users default to one photo on each side")
	menu.toggle(); menu._activate(11)
	for language in ["en", "zh", "zh_Hant", "ja"]:
		I18n.use(language); menu.refresh()
		var buttons: Array = menu._buttons.filter(func(b): return b.target in [Menu.PHOTO_CACHE_ONE, Menu.PHOTO_CACHE_TWO])
		check(buttons.size() == 2 and buttons.all(func(b): return b.enabled), "Two direct buttons are present: " + language)
		check(buttons.filter(func(b): return b.base_color == menu.SELECTED).size() == 1,
			"Exactly one cache limit is selected: " + language)
		check(menu._tips.has(Menu.PHOTO_CACHE_ONE) and menu._tips.has(Menu.PHOTO_CACHE_TWO), "Both buttons expose the resource tooltip: " + language)
	var two: Dictionary = menu._buttons.filter(func(b): return b.target == Menu.PHOTO_CACHE_TWO)[0]
	var origin: Vector3 = menu.to_global(Vector3(two.rect.get_center().x, two.rect.get_center().y, 1))
	menu.press_pointer("right_hand", origin, -menu.global_basis.z, true)
	menu.release_pointer("right_hand", origin, -menu.global_basis.z, true)
	check(app.photo.cache_each == 2 and app.photo.snapshot().cache_each == 2, "A ray and trigger selects two per side")
	var saved := ConfigFile.new()
	check(saved.load(app.settings_path) == OK and saved.get_value("photo", "cache_each", 0) == 2, "The selection is saved immediately")
	var restored := Photo.new(); restored.restore_view_settings(saved)
	check(restored.cache_each == 2, "Cache limit survives settings reload")
	for i in range(7): restored.queue.append({"uri":"file:///%d.png" % i})
	restored.queue_complete = false
	check(restored._neighbors(3) == [4,2,5,1], "Two per side interleaves distance and browsing direction")
	restored._navigation_direction = -1
	check(restored._neighbors(3) == [2,4,1,5], "Reverse browsing prioritizes the opposite side")
	restored._navigation_direction = 1
	check(restored._neighbors(0) == [1,2], "Incomplete directory windows do not wrap")
	restored.queue_complete = true
	check(restored._neighbors(0) == [1,6,2,5], "Complete album windows wrap without duplicate current photos")
	restored.cache_each = 1
	check(restored._neighbors(3) == [4,2], "One per side retains the original bounded window")
	menu._activate(Menu.PHOTO_CACHE_ONE)
	check(app.photo.cache_each == 1 and int(app.settings.get_value("photo", "cache_each", 0)) == 1, "Selecting one updates and saves the smaller window")
	restored.free(); two.clear(); menu.queue_free(); app.photo.queue_free(); app.free()
	await process_frame; await process_frame; await process_frame
	call_deferred("finish")

func finish() -> void:
	for failure in failures: push_error(failure)
	print("Photo cache settings: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
