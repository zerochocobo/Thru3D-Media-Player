extends SceneTree
## Per-image colour grading: the photo settings entry, the shared grade page, shaders and the per-file store.
const Photo := preload("res://scripts/photo_display.gd")
const PhotoMenu := preload("res://scripts/photo_menu.gd")
const PlayerMenu := preload("res://scripts/player_menu.gd")
const Main := preload("res://scripts/main.gd")
const Grade := preload("res://scripts/color_grade.gd")
const GradeMemory := preload("res://scripts/file_photo_grade_memory.gd")
var checks := 0
var failures: Array[String] = []

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func _initialize() -> void: call_deferred("run")

func has_target(menu: Node3D, target: int) -> bool:
	return menu._buttons.any(func(button): return button.target == target)

func run() -> void:
	var directory := ProjectSettings.globalize_path("res://../../build/output/photo-color-grade/test-" + str(Time.get_ticks_usec()))
	DirAccess.make_dir_recursive_absolute(directory)
	_store(directory.path_join("store"))
	var photo := Photo.new()
	photo.material = ShaderMaterial.new(); photo.material.shader = preload("res://shaders/photo.gdshader")
	photo.grade_memory.directory = directory.path_join("photo_settings")
	photo._texture = ImageTexture.create_from_image(Image.create(4, 4, false, Image.FORMAT_RGBA8))
	photo.local_uri = "file:///pictures/a.jpg"; photo.restore_color_grade()
	var main := Main.new(); main.settings = ConfigFile.new(); main.settings_path = directory.path_join("settings.cfg")
	main.photo = photo; main.photo_active = true
	var state := {}
	var refresh_state := func():
		state.clear(); state.merge(photo.snapshot()); state.has_image = photo._texture != null; state.count = 1
	refresh_state.call()
	var menu: Node3D = PhotoMenu.new()
	menu.state_provider = func(): return state
	root.add_child(menu); menu.set_process(false)
	main.photo_menu = menu
	menu.adjustment_requested.connect(main._on_photo_adjustment)
	menu.adjustment_requested.connect(func(_key, _value): refresh_state.call())
	menu.adjustment_committed.connect(main._save_photo_adjustments)
	menu.toggle(); menu.section = 1; menu.refresh()
	check(has_target(menu, PhotoMenu.PHOTO_COLOR), "Image settings show the colour grading entry")
	menu._activate(PhotoMenu.PHOTO_COLOR)
	check(menu._adjustment == "color_grade" and menu._adjust_rows.size() == Grade.PAGES[0].size(), "Entry opens the basic grade page")
	check(has_target(menu, PhotoMenu.PHOTO_GRADE_PRESET + Grade.PRESETS.size() - 1) and has_target(menu, PhotoMenu.PHOTO_GRADE_RESET), "Presets and reset are on the page")
	menu._activate(PhotoMenu.PHOTO_GRADE_PRESET + Grade.PRESETS.find("Warm"))
	check(photo.color_grade.preset == "Warm" and photo.material.get_shader_parameter("grade_enabled") == true, "Preset grades the photo shader")
	check(photo.grade_memory.lookup("file:///pictures/a.jpg").get("preset") == "Warm", "Preset click is saved for this image")
	# Drag exposure to the rail's right end: a custom grade starting from the warm look.
	var row: Dictionary = menu._adjust_rows[450 + Grade.PAGES[0].find("exposure")]
	var end: Vector3 = menu.to_global(Vector3(row.left + row.width, row.button.node.position.y, 1))
	check(menu.press_pointer("right_hand", end, -menu.global_basis.z, true), "Ray captures the exposure slider")
	menu.release_pointer("right_hand", end, -menu.global_basis.z, true)
	check(photo.color_grade.preset == "Custom" and is_equal_approx(photo.color_grade.custom.exposure, 2.0) and is_equal_approx(photo.color_grade.custom.temperature, 4000.0), "Slider edits a custom grade from the shown preset")
	check(is_equal_approx(float(photo.grade_memory.lookup("file:///pictures/a.jpg").custom.exposure), 2.0), "Slider release saves the image grade")
	# Gamma runs right-brighter: the right end is the smallest exponent, shown as its reciprocal.
	var gamma_row: Dictionary = menu._adjust_rows[450 + Grade.PAGES[0].find("gamma")]
	check(gamma_row.label.text == "1.000" and is_equal_approx(Grade.slider_fraction("gamma", 1.0), (1.0 - 1.0 / 1.4) / (1.0 / 0.7 - 1.0 / 1.4)), "Neutral gamma shows 1.000")
	end = menu.to_global(Vector3(gamma_row.left + gamma_row.width, gamma_row.button.node.position.y, 1))
	menu.press_pointer("right_hand", end, -menu.global_basis.z, true)
	menu.release_pointer("right_hand", end, -menu.global_basis.z, true)
	check(is_equal_approx(photo.color_grade.custom.gamma, 0.7) and gamma_row.label.text == "1.429" and is_equal_approx(gamma_row.knob.position.x, gamma_row.left + gamma_row.width), "Gamma right end brightens")
	var start: Vector3 = menu.to_global(Vector3(gamma_row.left, gamma_row.button.node.position.y, 1))
	menu.press_pointer("right_hand", start, -menu.global_basis.z, true)
	menu.release_pointer("right_hand", start, -menu.global_basis.z, true)
	check(is_equal_approx(photo.color_grade.custom.gamma, 1.4), "Gamma left end darkens")
	main._on_photo_adjustment("gamma", 1.0); main._save_photo_adjustments(); refresh_state.call()
	for key in Grade.DEFAULTS:
		for fraction in [0.0, 0.25, 0.5, 1.0]:
			check(absf(Grade.slider_fraction(key, Grade.slider_value(key, fraction)) - fraction) < 0.02, "Slider mapping round-trips " + key)
	menu._activate(PhotoMenu.PHOTO_GRADE_PAGE + 1)
	check(menu._grade_page == 1 and menu._adjust_rows.size() == Grade.PAGES[1].size(), "Page tabs switch to RGB gain")
	main._on_photo_adjustment("red_gain", 1.5); main._save_photo_adjustments(); refresh_state.call(); menu.refresh_values()
	check(menu._grade_page_needs_reset(), "Changed page offers its reset")
	menu._activate(PlayerMenu.GRADE_PAGE_RESET)
	check(is_equal_approx(photo.color_grade.custom.red_gain, 1.0) and is_equal_approx(photo.color_grade.custom.exposure, 2.0), "Page reset leaves other pages")
	# Another image starts ungraded; returning restores the saved grade, also after a reload from disk.
	photo.local_uri = "file:///pictures/b.jpg"; photo.restore_color_grade()
	check(photo.color_grade.preset == "Original" and photo.material.get_shader_parameter("grade_enabled") == false, "An ungraded image shows the original colours")
	refresh_state.call(); menu.refresh_values()
	check(menu._adjustment == "color_grade" and menu._grade_page_needs_reset() == false, "The open page follows the next image")
	photo.grade_memory = GradeMemory.new(directory.path_join("photo_settings")); photo.grade_memory.load_saved()
	photo.local_uri = "file:///pictures/a.jpg"; photo.restore_color_grade()
	check(photo.color_grade.preset == "Custom" and is_equal_approx(photo.color_grade.custom.exposure, 2.0), "Saved grade returns with its image")
	main._on_photo_adjustment("grade_preset", "Original")
	check(photo.color_grade.preset == "Original" and is_equal_approx(photo.color_grade.custom.exposure, 2.0), "Original bypasses the grade and keeps the custom values")
	menu._activate(PhotoMenu.PHOTO_ADJUST_BACK)
	check(menu._adjustment == "" and has_target(menu, PhotoMenu.PHOTO_COLOR), "Back returns to image settings")
	photo._texture = null; refresh_state.call(); menu.refresh()
	check(menu._buttons.any(func(button): return button.target == PhotoMenu.PHOTO_COLOR and not button.enabled), "No image, no grading")
	check(not photo.adjust_color_grade("exposure", 1.0), "Nothing to grade without a picture")
	menu.free(); main.free(); photo.free()
	for failure in failures: push_error(failure)
	print("Photo colour grade: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)

func _store(path: String) -> void:
	var memory := GradeMemory.new(path)
	var grade := Grade.new(); grade.adjust("saturation", 1.4)
	check(memory.remember("file:///x.png", grade.snapshot()) and memory.save(), "Grade saves")
	check(not memory.remember("file:///y.png", {"preset": "Neon", "custom": Grade.DEFAULTS}), "Unknown preset is refused")
	var partial := Grade.DEFAULTS.duplicate(); partial.erase("gamma")
	check(not memory.remember("file:///y.png", {"preset": "Custom", "custom": partial}), "Incomplete grade is refused")
	var bad := Grade.DEFAULTS.duplicate(); bad.exposure = NAN
	check(not memory.remember("file:///y.png", {"preset": "Custom", "custom": bad}), "Non-finite value is refused")
	var reloaded := GradeMemory.new(path); reloaded.load_saved()
	check(is_equal_approx(float(reloaded.lookup("file:///x.png").custom.saturation), 1.4), "Grade reloads")
	var wide := Grade.DEFAULTS.duplicate(); wide.exposure = 9.0
	reloaded.remember("file:///z.png", {"preset": "Custom", "custom": wide})
	check(is_equal_approx(float(reloaded.lookup("file:///z.png").custom.exposure), 2.0), "Values are clamped to the slider range")
	for i in 520: reloaded.remember("file:///many/%d.jpg" % i, grade.snapshot())
	check(reloaded.entries.size() == 512 and reloaded.save(), "Store keeps the 512 most recent grades within its byte budget")
	var again := GradeMemory.new(path); again.load_saved()
	check(again.entries.size() == 512 and not again.lookup("file:///many/519.jpg").is_empty(), "A full store reloads")
