extends SceneTree
const Menu := preload("res://scripts/player_menu.gd")
const PhotoMenu := preload("res://scripts/photo_menu.gd")
const Grade := preload("res://scripts/color_grade.gd")
const Main := preload("res://scripts/main.gd")
const Video := preload("res://scripts/mpv_video_display.gd")
var checks := 0
var failures: Array[String] = []
var commits := 0
func _initialize() -> void: call_deferred("run")
func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok: failures.append(label)
func click(menu: Node3D, button: Dictionary, hand: String = "right") -> void:
	var origin: Vector3 = button.node.to_global(Vector3(0, 0, 1))
	var direction: Vector3 = -button.node.global_basis.z
	check(menu.ray_hit(origin, direction).get("target") == button.target, "Reset has an independent ray target")
	menu.press_pointer(hand, origin, direction, true)
	menu.release_pointer(hand, origin, direction, true)
func row_for(menu: Node, key: String) -> Dictionary:
	for row in menu._adjust_rows.values():
		if row.key == key: return row
	return {}
func run() -> void:
	var main := Main.new(); main.settings_path = "user://slider-reset-test.cfg"
	var video := Video.new(); root.add_child(video); video.set_process(false); main.video = video
	video.local_uri = "file:///slider-reset_LR_180.mp4"; video.media.begin(77)
	video._remember_file = true # This fixture represents a completed file-open request.
	video.media.format = {"width": 4096, "height": 2048}
	var menu := Menu.new(); root.add_child(menu); menu.set_process(false); main.player_menu = menu
	menu.state_provider = main._menu_state
	menu.adjustment_requested.connect(main._on_playback_adjustment)
	menu.adjustment_committed.connect(main._save_playback_adjustments)
	menu.adjustment_committed.connect(func(): commits += 1)
	menu.visible = true; menu.section = 1; menu._adjustment = "color_grade"
	for page in Grade.PAGES.size():
		for key: String in Grade.PAGES[page]:
			video.color_grade.reset_custom()
			var neighbour := "gamma" if key == "contrast" else "contrast"
			video.color_grade.adjust(neighbour, 1.2)
			var span := Grade.limits(key)
			video.color_grade.adjust(key, lerpf(span.x, span.y, 0.25))
			var expected := video.color_grade.values(); expected[key] = Grade.DEFAULTS[key]
			menu._grade_page = page; menu.refresh()
			var before := commits
			click(menu, row_for(menu, key).reset)
			check(video.color_grade.values() == expected and commits == before + 1, "One click resets only this color parameter and commits once: " + key)
			var saved := ConfigFile.new(); saved.load(main.settings_path)
			var restored := Grade.new(); restored.restore(saved.get_value("video", "color_grade"))
			check(restored.values() == expected, "Single color reset survives restart: " + key)
			check(not row_for(menu, key).reset.enabled, "Neutral color reset is disabled: " + key)
	for page in Grade.PAGES.size():
		video.color_grade.reset_custom()
		for key in Grade.DEFAULTS:
			var span := Grade.limits(key); video.color_grade.adjust(key, lerpf(span.x, span.y, 0.25))
		var expected := video.color_grade.values()
		for key in Grade.PAGES[page]: expected[key] = Grade.DEFAULTS[key]
		menu._grade_page = page; menu.refresh()
		var saved_count := commits
		click(menu, menu._buttons.filter(func(button): return button.target == Menu.GRADE_PAGE_RESET)[0])
		check(video.color_grade.values() == expected and commits == saved_count + 1, "Page reset touches only current page and commits once")
		var saved := ConfigFile.new(); saved.load(main.settings_path)
		var restored := Grade.new(); restored.restore(saved.get_value("video", "color_grade"))
		check(restored.values() == expected, "Page reset survives restart and retains other pages")
	var original := video.color_grade.snapshot()
	check(not video.color_grade.reset_page(-1) and not video.color_grade.reset_page(3) and video.color_grade.snapshot() == original, "Invalid page cannot erase custom adjustments")
	menu._activate(440)
	check(video.color_grade.values() == Grade.DEFAULTS, "Existing whole-custom reset still resets every page")
	video.stereo_sbs = true; video.geometry = 1; video.swap_eyes = true; video._apply_geometry()
	video.set_stereo_alignment("stereo_horizontal", 2.0); video.set_stereo_alignment("stereo_vertical", -3.0)
	menu._adjustment = "stereo_view"; menu.refresh()
	click(menu, row_for(menu, "stereo_horizontal").reset)
	check(video.stereo_horizontal == 0 and video.stereo_vertical == -3 and video.swap_eyes, "Horizontal reset preserves vertical correction and eye order")
	click(menu, row_for(menu, "stereo_vertical").reset)
	check(video.stereo_vertical == 0 and video._hole_material.next_pass == null, "Vertical reset removes corrected borders")
	var memory := preload("res://scripts/file_mode_memory.gd").new(); memory.load_saved()
	check(memory.lookup(video.local_uri).get("stereo_horizontal") == 0 and memory.lookup(video.local_uri).get("stereo_vertical") == 0, "Independent alignment resets persist per file")
	# A captured slider cannot be reset by the other hand.
	video.set_stereo_alignment("stereo_horizontal", 2.0); menu.refresh_values()
	var row := row_for(menu, "stereo_horizontal")
	var origin: Vector3 = menu.to_global(Vector3(menu.SLIDER_LEFT + menu.SLIDER_WIDTH * 0.5, row.knob.position.y, 1))
	menu.press_pointer("right", origin, -menu.global_basis.z, true)
	var held: float = video.stereo_horizontal; var before := commits
	var reset_origin: Vector3 = row.reset.node.to_global(Vector3(0, 0, 1))
	check(not menu.press_pointer("left", reset_origin, -menu.global_basis.z, true), "Other hand cannot reset a captured adjustment")
	check(video.stereo_horizontal == held and commits == before, "Rejected reset changes neither preview nor saved state")
	menu.release_pointer("right", origin, -menu.global_basis.z, true)
	video.geometry = 0; video.stereo_sbs = false; video.screen_distance = 5.0; video.screen_scale = 2.0
	video.flat_pose = Transform3D(Basis.IDENTITY, Vector3(0, 1.6, -5)); video._apply_geometry()
	menu._adjustment = "screen"; menu.refresh()
	click(menu, row_for(menu, "screen_distance").reset)
	check(video.screen_distance == 2.0 and video.screen_scale == 2.0, "Video distance resets to 2m without changing size")
	click(menu, row_for(menu, "screen_scale").reset)
	check(video.screen_scale == 1.0 and video.screen_distance == 2.0, "Video percentage reset restores physical scale one")
	video.geometry = 1; video._apply_geometry(); main.settings.set_value("video", "alpha_fps", 35)
	menu._adjustment = ""; menu.refresh()
	click(menu, row_for(menu, "alpha_fps").reset)
	var saved_fps := ConfigFile.new(); saved_fps.load(main.settings_path)
	check(main._alpha_fps() == 30 and saved_fps.get_value("video", "alpha_fps") == 30, "Alpha FPS resets and persists without touching other playback settings")
	menu.free(); main.free(); video.free()
	# Shared subtitle fields own reset clicks until release; no preview writes or double commits.
	var state := {"has_video": true, "source_uri": "file:///subtitle.mp4", "geometry": 1,
		"subtitle_position": 20.0, "subtitle_distance": 1.5, "subtitle_size": 150.0}
	menu = Menu.new(); root.add_child(menu); menu.set_process(false); menu.state_provider = func(): return state
	var settings_events: Array = []
	menu.setting_requested.connect(func(key, value): state[key] = value; settings_events.append([key, value]))
	menu.toggle(); menu._activate(110); menu._activate(Menu.SUBTITLE_APPEARANCE)
	for key in ["subtitle_position", "subtitle_distance", "subtitle_size"]:
		var reset_target: int = menu.choices.targets.keys().filter(func(target): return menu.choices.targets[target].get("kind") == "reset" and menu.choices.targets[target].key == key)[0]
		var button: Dictionary = menu._buttons.filter(func(item): return item.target == reset_target)[0]
		var reset_point: Vector3 = button.node.to_global(Vector3(0, 0, 1))
		var old_value: float = state[key]; var saved_count := settings_events.size()
		check(menu.ray_hit(reset_point, -button.node.global_basis.z).get("target") == reset_target, "Subtitle reset does not overlap its rail")
		menu.press_pointer("right", reset_point, -button.node.global_basis.z, true)
		check(state[key] == old_value and menu.has_pointer_capture(), "Subtitle reset waits for owner release")
		menu.release_pointer("left", reset_point, -button.node.global_basis.z, true)
		check(settings_events.size() == saved_count, "Other hand cannot commit subtitle reset")
		menu.release_pointer("right", reset_point, -button.node.global_basis.z, true)
		check(state[key] == {"subtitle_position": 0.0, "subtitle_distance": 5.0, "subtitle_size": 100.0}[key] and settings_events.size() == saved_count + 1, "Subtitle reset changes once on release")
	var depth_state := {"has_video": true, "geometry": 0, "depth_requested": true, "depth_strength": 1.8}
	menu.state_provider = func(): return depth_state.duplicate(true)
	menu.depth_strength_requested.connect(func(value): depth_state.depth_strength = value)
	menu._adjustment = ""; menu.section = 0; menu._depth_open = true; menu.refresh()
	click(menu, menu._buttons.filter(func(button): return button.target == Menu.DEPTH_RESET)[0])
	check(depth_state.depth_strength == .5 and depth_state.depth_requested and menu._depth_open, "Video strength reset restores 50 percent without disabling conversion")
	check(not menu._buttons.filter(func(button): return button.target == Menu.DEPTH_RESET)[0].enabled, "Video reset disables at its own 50 percent default")
	menu.free()
	var photo_state := {"has_image": true, "count": 12, "layout": 0, "gallery_focus": -1,
		"screen_distance": 8.0, "screen_scale": 4.0, "inspect_magnification": 7.0,
		"gallery_distance": 7.0, "gallery_scale": 1.8, "geometry": 0}
	var photo := PhotoMenu.new(); root.add_child(photo); photo.set_process(false)
	photo.state_provider = func(): return photo_state.duplicate(true)
	photo.adjustment_requested.connect(func(key, value): photo_state[key] = value)
	photo.visible = true; photo._adjustment = "photo_view"; photo.refresh()
	for key in ["screen_distance", "screen_scale", "inspect_magnification"]:
		click(photo, row_for(photo, key).reset)
		check(photo_state[key] == {"screen_distance": 3.0, "screen_scale": 1.0, "inspect_magnification": 2.0}[key], "Photo uses its own default units: " + key)
	for layout in [2, 3]:
		photo_state.layout = layout; photo_state.gallery_distance = 7.0; photo_state.gallery_scale = 1.8; photo.refresh()
		click(photo, row_for(photo, "gallery_distance").reset)
		check(is_equal_approx(photo_state.gallery_distance, [3.0, 3.0, 4.0, 3.6][layout]), "Gallery uses the current layout's default distance")
		click(photo, row_for(photo, "gallery_scale").reset)
		check(photo_state.gallery_scale == 1.0, "Gallery size reset preserves distance")
	photo_state.layout = 0; photo_state.depth_available = true; photo_state.depth_requested = true; photo_state.depth_strength = 1.8
	photo._adjustment = ""; photo._depth_open = true
	photo.depth_strength_requested.connect(func(value): photo_state.depth_strength = value)
	photo.refresh()
	click(photo, photo._buttons.filter(func(button): return button.target == Menu.DEPTH_RESET)[0])
	check(photo_state.depth_strength == 1.0 and photo_state.depth_requested and photo._depth_open, "Strength reset restores 100 percent without closing the popup or changing the 3D switch")
	photo_state.depth_requested = false; photo.refresh_values()
	check(not photo._buttons.filter(func(button): return button.target == Menu.DEPTH_RESET)[0].enabled, "Reset cannot enable a disabled 3D effect")
	photo.free()
	print("Slider reset checks=%d failures=%d" % [checks, failures.size()])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)
