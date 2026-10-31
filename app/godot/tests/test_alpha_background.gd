extends SceneTree
const Main := preload("res://scripts/main.gd")
const HostTest := preload("res://tests/test_player_menu.gd")
var checks := 0
var failures: Array[String] = []
var output := ProjectSettings.globalize_path("res://../../build/output/alpha-background")

class SupportedDisplay extends XrDisplay:
	func supports_passthrough() -> bool: return true

class InputMain extends Main:
	var test_ray: Array = []
	var test_pose := Transform3D.IDENTITY
	func _ray(_hand: String) -> Variant: return null if test_ray.is_empty() else test_ray
	func _move_pose(_hand: String) -> Variant: return test_pose
	func _input_focused() -> bool: return true

func _initialize() -> void: run.call_deferred()
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func choose(menu: Node3D, value: bool) -> bool:
	for target in menu.choices.targets:
		var item: Dictionary = menu.choices.targets[target]
		if item.get("key") != "alpha_keep_background" or item.get("kind") != "choose" or item.value != value: continue
		for button in menu._buttons:
			if button.target != target: continue
			var point: Vector3 = button.node.global_position + menu.global_basis.z
			if not menu.press_pointer("right_hand", point, -menu.global_basis.z, true): return false
			menu.release_pointer("right_hand", point, -menu.global_basis.z, true)
			return true
	return false

func drag(main: Node3D, surface: Node3D, label: String) -> void:
	for menu in [main.recent_menu, main.video_menu, main.photo_menu, main.music_menu]: menu.dismiss()
	var head: Transform3D = main._head_pose()
	var flat: bool = surface.geometry == 0
	var before: Transform3D = surface.flat_pose
	var yaw: float = surface.view_yaw
	main.test_pose = head
	main.test_ray = [head.origin, (surface.panel.global_position - head.origin).normalized() if flat else -surface.panel.global_basis.z.normalized()]
	main.controller_bindings.reset_inputs()
	main._on_controller_button("grip_click", "right_hand")
	check(not main.interface_move.capture.is_empty() and main.interface_move.capture.targets.any(func(target): return target.node == surface), label + " grip captures the cutout")
	if main.interface_move.capture.is_empty(): return
	main.test_pose = Transform3D(Basis(Vector3.UP, .12) * head.basis, head.origin + Vector3(.12, .05, 0))
	main._update_interface_move(); main._on_controller_release("grip_click", "right_hand")
	check(not surface.flat_pose.is_equal_approx(before) if flat else not is_equal_approx(surface.view_yaw, yaw), label + " controller motion moves cutout")
	var moved: Transform3D = surface.flat_pose
	main._update_background()
	check(surface.flat_pose.is_equal_approx(moved) and not main.display.applied_passthrough, label + " retains position and virtual background after release")
	main.test_ray = []

func run() -> void:
	DirAccess.make_dir_recursive_absolute(output)
	for model in ["Quest 2", "Oculus Quest 2", "Meta Quest2", "Pico Neo 3", "PICO Neo3", "PICO Neo3 Pro Eye", "PICO Neo3 Link", "Neo3"]:
		check(Main._alpha_keep_background_default(model), "Monochrome headset default: " + model)
	for model in ["Quest 3", "Quest 3S", "Quest Pro", "Quest 20", "PICO 4", "PICO 4 Ultra", "PICO Neo 4", "", "Generic OpenXR"]:
		check(not Main._alpha_keep_background_default(model), "Other headset default: " + model)
	var config := ConfigFile.new()
	config.set_value("appearance", "background", "dark")
	config.set_value("ui", "language", "zh")
	config.save(output.path_join("settings.cfg"))
	var main := InputMain.new(); main.settings_path = output.path_join("settings.cfg")
	main.display = SupportedDisplay.new(); root.add_child(main)
	main.set_process(false); main.video.set_process(false); main.photo.set_process(false); main.report_timer.stop()
	main.video.platform = HostTest.Host.new()
	main.video.history_enabled = false; main.video._remember_file = false
	main.video.local_uri = "file:///alpha-background-test.mp4"
	main.video.media.begin(7); main.video.media.state = "playing"; main.video.panel.visible = true
	main.video.geometry = 0; main.video.stereo_sbs = false
	main.video_menu.section = 1; main.video_menu.visible = true; main.video_menu.refresh()
	check(choose(main.video_menu, true) and main._alpha_keep_background(), "Player ray press/release enables background")
	check(choose(main.video_menu, false) and not main._alpha_keep_background(), "Player ray press/release disables background")
	main.video.packed_file = true; main.video_menu.refresh()
	check(choose(main.video_menu, true), "Video setting remains available with source Alpha instead of AI")
	main.video.packed_file = false
	main.settings.erase_section_key("alpha", "keep_background")
	main.video_menu.dismiss()
	main.recent_menu.section = main.recent_menu.Section.SETTINGS; main.recent_menu.tab = main.recent_menu.VIDEO_TAB
	main.recent_menu.visible = true; main.recent_menu.refresh()
	var row := -1
	for index in main.recent_menu.rows.size():
		if main.recent_menu.rows[index].get("key") == "alpha_keep_background": row = index
	check(row >= 0 and main.recent_menu.rows[row + 1].title == main.I18n.t("AI portrait passthrough (Alpha)"), "Library places toggle immediately before AI portrait configuration")
	if row >= 0:
		main.recent_menu._set_scroll(float(row))
		check(choose(main.recent_menu, true) and main._alpha_keep_background(), "Library ray press/release shares persisted setting")
	main.settings.erase_section_key("alpha", "keep_background")
	main.recent_menu.dismiss()
	main.android_report = {"model": "PICO 4"}
	check(not main._alpha_keep_background(), "PICO 4 shares GPU tier but not Neo3 camera default")
	main.android_report = {"model": "Quest 2"}
	check(main._alpha_keep_background() and not main.settings.has_section_key("alpha", "keep_background"), "Default remains unsaved until explicitly chosen")
	main._on_player_setting("alpha_keep_background", false)
	var restored := ConfigFile.new(); restored.load(main.settings_path)
	check(not restored.get_value("alpha", "keep_background", true) and not main._alpha_keep_background(), "Explicit off persists over monochrome default")
	main._on_setting_changed("alpha_keep_background", true)
	main.android_report = {"model": "Quest 3"}
	check(main._alpha_keep_background() and main._library_settings().alpha_keep_background and main._menu_state().alpha_keep_background, "Saved on wins and both menus share it")
	main.background.select("belfast")
	var deadline := Time.get_ticks_msec() + 20000
	while not main.background._builtin_requested.is_empty() and Time.get_ticks_msec() < deadline: await create_timer(.01).timeout
	check(main.background._material.panorama != null, "Video background loads the production panorama")
	main.video.alpha_requested = true
	for geometry in [0, 1, 2]:
		main.video.geometry = geometry
		main._update_background()
		check(not main.display.applied_passthrough and main.display.scenery == main.background.sky, "Cutout retains selected sky: " + str(geometry))
		check(main.video.alpha_requested and main.video.alpha_over_scenery, "Background does not disable Alpha: " + str(geometry))
		main.video._apply_geometry()
		drag(main, main.video, "Panorama video " + str(geometry))
		main._on_setting_changed("alpha_keep_background", false)
		check(main.display.applied_passthrough and main.display.scenery == null, "Off returns to camera: " + str(geometry))
		main._on_setting_changed("alpha_keep_background", true)
	main.temporary_passthrough = true; main._update_background()
	check(not main.display.applied_passthrough and main.temporary_passthrough, "Retained background temporarily overrides session camera without forgetting it")
	main.video.alpha_requested = false; main._update_background()
	check(main.display.applied_passthrough, "Leaving Alpha restores previous temporary camera")
	main.temporary_passthrough = false
	main.video.alpha_requested = true; main.background.choice = "passthrough"; main._update_background()
	check(main.display.applied_passthrough and not main.video.alpha_over_scenery, "Explicit camera background stays selected")
	main.background.choice = "belfast"; main.video.alpha_requested = false; main.video.alpha_enabled = true
	main.video.packed_file = true; main._update_background()
	check(not main.display.applied_passthrough and main.display.scenery == main.background.sky, "Presented source Alpha mask also keeps background")
	main.video.alpha_enabled = false; main.video.packed_file = false; main._update_background()
	check(main.display.scenery == null, "Ordinary immersive video still hides scenery")
	main.photo_active = true; main.player_menu = main.photo_menu
	main.photo.portrait_requested = true; main.photo.geometry = 0; main.photo.gallery.mode = 0
	main.photo.local_uri = "file:///alpha-background-photo.png"; main.photo.panel.visible = true; main.photo._apply_geometry()
	main.photo_background.select("belfast")
	deadline = Time.get_ticks_msec() + 20000
	while not main.photo_background._builtin_requested.is_empty() and Time.get_ticks_msec() < deadline: await create_timer(.01).timeout
	check(main.photo_background._material.panorama != null, "Photo background loads its independent panorama")
	main._update_background()
	check(not main.display.applied_passthrough and main._active_background() == main.photo_background and main.display.scenery == main.photo_background.sky, "Photo cutout retains its independent panorama")
	drag(main, main.photo, "Panorama photo portrait")
	main.photo_menu.section = 1; main.photo_menu.visible = true; main.photo_menu.refresh()
	check(choose(main.photo_menu, false) and not main._photo_menu_state().alpha_keep_background, "Photo ray toggle updates the global choice")
	check(main.display.applied_passthrough, "Photo off returns to camera")
	check(not main._library_settings().alpha_keep_background and not main._menu_state().alpha_keep_background, "Photo change is reflected by global and video settings")
	restored.load(main.settings_path)
	check(restored.get_value("alpha", "keep_background", true) == false, "Photo selection persists in the same global config")
	check(choose(main.photo_menu, true) and not main.display.applied_passthrough, "Photo toggle returns to the same panorama")
	main.photo.auto_portrait = true; main.photo.portrait_requested = false
	main._update_background()
	check(not main.display.applied_passthrough and main.display.scenery == main.photo_background.sky and main._person_passthrough(), "Portrait continuation retains a chosen panorama while no per-image matte is requested")
	main._on_setting_changed("alpha_keep_background", false)
	check(main.display.applied_passthrough and main._session_controls_state().alpha, "Portrait continuation keeps camera passthrough and its session controls active between images")
	main._on_session_control("temporary_passthrough")
	check(main.display.applied_passthrough and not main.temporary_passthrough, "Temporary camera cannot interrupt an active portrait album between images")
	main.photo.auto_portrait = false; main._update_background()
	check(not main.display.applied_passthrough and main.display.scenery == main.photo_background.sky, "Explicit portrait exit restores the independently selected photo panorama")
	main.photo_menu.dismiss(); main.photo.local_uri = ""; main.photo_active = false; main.photo.portrait_requested = false; main.player_menu = main.video_menu
	main.video.geometry = 1; main.video.alpha_requested = true
	main.video._layer_alpha_allowed = true
	main.video.video_layer = preload("res://scripts/video_layer.gd").new(null)
	main.video.video_layer.alpha_blend = true
	main.video.alpha_over_scenery = false
	check(main.video._layer_alpha(), "Fixture supports native Alpha layer")
	main.video.alpha_over_scenery = true
	check(not main.video._layer_alpha() and not main.video._layer_presentation(), "Retained scenery blocks native holes that erase its pixels")
	main.video.pip.compositor.main_ready = true
	check(not main.video.pip.compositor.prepare_main() and not main.video.pip.compositor.main_ready, "Processed Alpha main also stays in eye buffer")
	main.video.local_uri = ""; main.video.media.session_id = 0; main.video.platform = null
	# Let queued rendering resources finish before disposing the presentation.
	await process_frame
	main.free()
	await process_frame
	await process_frame
	for failure in failures: push_error(failure)
	print("Alpha background: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
