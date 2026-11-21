extends SceneTree
## Photo 3D conversion setting: menu row, persistence, and the progressive refinement handshake.
const Main := preload("res://scripts/main.gd")
const Photo := preload("res://scripts/photo_display.gd")
const Menu := preload("res://scripts/photo_menu.gd")
const I18n := preload("res://scripts/i18n.gd")
var checks := 0
var failures: Array[String] = []
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

class FakePlatform extends Object:
	var modes: Array = []
	var refined: Array = []
	var accept := true
	func set_photo_depth_mode(mode: String) -> void: modes.append(mode)
	func refine_photo_3d(id: int, strength: float, convergence: float, rotation: int) -> bool:
		refined.append([id, strength, convergence, rotation]); return accept

func _initialize() -> void: call_deferred("run")
func run() -> void:
	var app := Main.new()
	var folder := "user://depth_mode_%d" % Time.get_ticks_usec()
	DirAccess.make_dir_recursive_absolute(folder)
	app.settings_path = folder.path_join("settings.cfg")
	app.photo = Photo.new(); root.add_child(app.photo); app.photo.set_process(false)
	app.photo_menu = Menu.new(); app.photo_menu.state_provider = func(): return app.photo.snapshot()
	app.photo_menu.setting_requested.connect(app._on_photo_adjustment)
	root.add_child(app.photo_menu)
	app.photo_active = true; app.player_menu = app.photo_menu
	var menu: Node3D = app.photo_menu
	check(app.photo.depth_mode == "progressive", "New users default to fast-then-fine conversion")
	menu.toggle(); menu._activate(11)
	var targets := range(Menu.PHOTO_DEPTH_MODE_BASE, Menu.PHOTO_DEPTH_MODE_BASE + Menu.DEPTH_MODES.size())
	for language in ["en", "zh", "zh_Hant", "ja"]:
		I18n.use(language); menu.refresh()
		var buttons: Array = menu._buttons.filter(func(b): return b.target in targets)
		check(buttons.size() == 3 and buttons.all(func(b): return b.enabled), "Three direct mode buttons: " + language)
		check(buttons.filter(func(b): return b.base_color == menu.SELECTED).size() == 1, "Exactly one mode is selected: " + language)
		check(targets.all(func(t): return menu._tips.has(t) and not str(menu._tips[t]).is_empty()), "Every mode explains itself on hover: " + language)
		if language != "en":
			check(targets.all(func(t): return I18n.t(Menu.DEPTH_MODES[t - Menu.PHOTO_DEPTH_MODE_BASE][1]) != Menu.DEPTH_MODES[t - Menu.PHOTO_DEPTH_MODE_BASE][1]),
				"Mode captions are translated: " + language)
	I18n.use("en")
	var fast: Dictionary = menu._buttons.filter(func(b): return b.target == Menu.PHOTO_DEPTH_MODE_BASE + 2)[0]
	var origin: Vector3 = menu.to_global(Vector3(fast.rect.get_center().x, fast.rect.get_center().y, 1))
	menu.press_pointer("right_hand", origin, -menu.global_basis.z, true)
	menu.release_pointer("right_hand", origin, -menu.global_basis.z, true)
	check(app.photo.depth_mode == "fast" and app.photo.snapshot().depth_mode == "fast", "A ray and trigger selects the fast model")
	var saved := ConfigFile.new()
	check(saved.load(app.settings_path) == OK and saved.get_value("photo", "depth_mode", "") == "fast", "The mode is saved immediately")
	var restored := Photo.new(); restored.restore_view_settings(saved)
	check(restored.depth_mode == "fast", "Mode survives settings reload")
	check(not restored.set_depth_mode("turbo") and restored.depth_mode == "fast", "Unknown modes are rejected")
	saved.set_value("photo", "depth_mode", "turbo"); restored.restore_view_settings(saved)
	check(restored.depth_mode == "fast", "A damaged saved value leaves the mode alone")
	restored.free()

	# Refinement handshake with a stand-in Android plugin.
	var photo := Photo.new(); root.add_child(photo); photo.set_process(false)
	var platform := FakePlatform.new()
	photo.platform = platform
	check(photo.set_depth_mode("progressive") and platform.modes.back() == "progressive", "The mode reaches the native runtime")
	photo._display_request = 5; photo.depth_requested = true; photo.depth_enabled = true; photo.depth_strength = 1.25
	photo._display_depth_data = {"model":"fast", "source_id":5}
	photo._pump_refine()
	check(platform.refined.is_empty(), "No refinement before the dwell")
	photo._refine_due.at = 0
	photo._pump_refine()
	check(platform.refined.size() == 1 and platform.refined[0][0] == 5 and is_equal_approx(platform.refined[0][1], 1.25), "Dwell elapsed: one refinement with the shown strength")
	photo._pump_refine()
	check(platform.refined.size() == 1, "A picture is refined once")
	photo._display_depth_data = {}
	photo._commit_depth_data({"model":"fast", "rect":Vector4(0,0,1,1)})
	check(photo._refine_request == 0, "A new fast result (another strength) may be refined again")
	photo._refine_due.at = 0
	photo._pump_refine()
	check(platform.refined.size() == 2, "Re-refined after the fast result changed")
	photo._display_depth_data = {"model":"quality", "source_id":5}; photo._refine_request = 0
	photo._pump_refine()
	check(platform.refined.size() == 2, "Quality maps are never refined")
	photo._display_depth_data = {"model":"fast", "source_id":5}
	photo.set_depth_mode("fast"); photo._refine_due = {"id":0, "at":0}
	photo._pump_refine()
	check(platform.refined.size() == 2, "Fast mode never refines")
	photo.set_depth_mode("quality")
	photo._pump_refine()
	check(platform.refined.size() == 3, "Quality mode refines a fast picture at once")
	photo._display_request = 6
	photo._on_depth_refined(5, JSON.stringify({"state":"ready", "stereo_path":"x.rgba"}))
	check(photo._depth_queue.is_empty(), "A late refinement for an earlier picture is ignored")
	photo._display_request = 5; photo._refine_request = 5
	photo._on_depth_refined(5, JSON.stringify({"state":"ready", "stereo_path":"x.rgba"}))
	photo._on_depth_refined(5, JSON.stringify({"state":"ready", "stereo_path":"x.rgba"}))
	check(photo._depth_queue.size() == 1 and photo._depth_queue[0].get("refine", false), "The refined pair queues once for off-thread loading")
	photo._depth_queue.clear()
	photo._on_depth_refined(5, JSON.stringify({"state":"error"}))
	check(photo._depth_queue.is_empty(), "A failed refinement leaves the fast 3D in place")
	photo._finish_refined(5, {"model":"quality", "strength":2.0, "rect":Vector4(0,0,1,1)})
	check(str(photo._display_depth_data.get("model")) == "fast", "A refinement for another strength is not shown")
	photo.platform = null; platform.free(); photo.queue_free()
	menu.queue_free(); app.photo.queue_free(); app.free()
	await process_frame; await process_frame; await process_frame
	call_deferred("finish")

func finish() -> void:
	for failure in failures: push_error(failure)
	print("Photo depth mode: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
