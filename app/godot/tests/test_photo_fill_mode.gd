extends SceneTree
## Image 2D->3D effect (fill gaps / stretch edges): menu row, persistence, the native setting, cached
## pairs of the other mode, and magazine spreads registering their pages.
const Main := preload("res://scripts/main.gd")
const Photo := preload("res://scripts/photo_display.gd")
const Menu := preload("res://scripts/photo_menu.gd")
const Magazine := preload("res://scripts/photo_magazine.gd")
const I18n := preload("res://scripts/i18n.gd")
var checks := 0
var failures: Array[String] = []
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

class FakePlatform extends Object:
	var fills: Array = []
	var pages: Array = []
	func set_photo_depth_mode(_mode: String) -> void: pass
	func set_photo_fill_mode(mode: String) -> void: fills.append(mode)
	func set_photo_pages(id: int, split: float) -> bool: pages.append([id, split]); return true

func _initialize() -> void: call_deferred("run")
func run() -> void:
	var app := Main.new()
	var folder := "user://fill_mode_%d" % Time.get_ticks_usec()
	DirAccess.make_dir_recursive_absolute(folder)
	app.settings_path = folder.path_join("settings.cfg")
	app.photo = Photo.new(); root.add_child(app.photo); app.photo.set_process(false)
	app.photo_menu = Menu.new(); app.photo_menu.state_provider = func(): return app.photo.snapshot()
	app.photo_menu.setting_requested.connect(app._on_photo_adjustment)
	root.add_child(app.photo_menu)
	app.photo_active = true; app.player_menu = app.photo_menu
	var menu: Node3D = app.photo_menu
	check(app.photo.fill_mode == "fill", "New users keep the hole fill")
	menu.toggle(); menu._activate(11)
	var targets := range(Menu.PHOTO_FILL_BASE, Menu.PHOTO_FILL_BASE + Menu.FILL_MODES.size())
	for language in ["en", "zh", "zh_Hant", "ja"]:
		I18n.use(language); menu.refresh()
		var buttons: Array = menu._buttons.filter(func(b): return b.target in targets)
		check(buttons.size() == 2 and buttons.all(func(b): return b.enabled), "Two effect buttons: " + language)
		check(buttons.filter(func(b): return b.base_color == menu.SELECTED).size() == 1, "Exactly one effect is selected: " + language)
		check(targets.all(func(t): return menu._tips.has(t) and not str(menu._tips[t]).is_empty()), "Each effect explains itself on hover: " + language)
		if language != "en":
			check(targets.all(func(t): return I18n.t(Menu.FILL_MODES[t - Menu.PHOTO_FILL_BASE][1]) != Menu.FILL_MODES[t - Menu.PHOTO_FILL_BASE][1]),
				"Effect captions are translated: " + language)
	I18n.use("en")
	var seen := {}
	for button in menu._buttons: seen[button.target] = int(seen.get(button.target, 0)) + 1
	check(seen.values().all(func(count): return count == 1), "No two panel buttons share a target")
	var stretch: Dictionary = menu._buttons.filter(func(b): return b.target == Menu.PHOTO_FILL_BASE + 1)[0]
	var origin: Vector3 = menu.to_global(Vector3(stretch.rect.get_center().x, stretch.rect.get_center().y, 1))
	menu.press_pointer("right_hand", origin, -menu.global_basis.z, true)
	menu.release_pointer("right_hand", origin, -menu.global_basis.z, true)
	check(app.photo.fill_mode == "stretch" and app.photo.snapshot().fill_mode == "stretch", "A ray and trigger selects stretching")
	var saved := ConfigFile.new()
	check(saved.load(app.settings_path) == OK and saved.get_value("photo", "fill_mode", "") == "stretch", "The effect is saved immediately")
	var restored := Photo.new(); restored.restore_view_settings(saved)
	check(restored.fill_mode == "stretch", "The effect survives settings reload")
	check(not restored.set_fill_mode("smear") and restored.fill_mode == "stretch", "Unknown effects are rejected")
	saved.set_value("photo", "fill_mode", "smear"); restored.restore_view_settings(saved)
	check(restored.fill_mode == "stretch", "A damaged saved value leaves the effect alone")
	restored.free()

	var photo := Photo.new(); root.add_child(photo); photo.set_process(false)
	var platform := FakePlatform.new()
	photo.platform = platform
	check(photo.set_fill_mode("stretch") and platform.fills.back() == "stretch", "The effect reaches the native runtime")
	photo.depth_strength = 1.0
	var pair := {"image":Image.create(4, 4, false, Image.FORMAT_RF), "stereo_image":Image.create(8, 4, false, Image.FORMAT_RGBA8),
		"strength":1.0, "convergence":0.35, "rotation":0, "fill":"fill"}
	check(not photo._fill_matches(pair), "A fill pair is not reused for stretching")
	pair.fill = "stretch"
	check(photo._fill_matches(pair), "A stretch pair is reused for stretching")
	check(photo._fill_matches({}) == false, "Pairs without the field were filled")
	photo.set_fill_mode("fill")
	check(photo._fill_matches({}), "Pairs without the field match the default fill")

	Magazine.register_pages(platform, 7, {"comic_rects":[Rect2(0, 0, 0.47, 1), Rect2(0.47, 0, 0.53, 1)]})
	check(platform.pages.size() == 1 and platform.pages[0][0] == 7 and is_equal_approx(platform.pages[0][1], 0.47), "A spread registers its left page's share")
	Magazine.register_pages(platform, 8, {"comic_rects":[Rect2(0, 0, 1, 1)]})
	Magazine.register_pages(platform, 0, {"comic_rects":[Rect2(0, 0, 0.5, 1), Rect2(0.5, 0, 0.5, 1)]})
	check(platform.pages.size() == 1, "Single pages and failed registrations set no pages")

	photo.platform = null; platform.free(); photo.queue_free()
	menu.queue_free(); app.photo.queue_free(); app.free()
	await process_frame; await process_frame; await process_frame
	call_deferred("finish")

func finish() -> void:
	for failure in failures: push_error(failure)
	print("photo fill mode: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
