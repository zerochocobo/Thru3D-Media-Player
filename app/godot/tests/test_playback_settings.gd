extends SceneTree
const Main := preload("res://scripts/main.gd")
const Video := preload("res://scripts/mpv_video_display.gd")
const Menu := preload("res://scripts/player_menu.gd")
const Library := preload("res://scripts/library_menu.gd")
const Style := preload("res://scripts/subtitle_style.gd")
var checks := 0
var failures: Array[String] = []

class Host extends RefCounted:
	var rates: Array = []
	var alpha_fps: Array = []
	func set_mpv_alpha_fps(fps: int) -> bool:
		alpha_fps.append(fps)
		return true
	var accept := true
	func set_mpv_speed(id: int, rate: float) -> bool:
		if not accept: return false
		rates.append([id, rate])
		return true
	func close_mpv_video(_id: int) -> void: pass

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func _initialize() -> void: call_deferred("_run")

func click(menu: Node3D, target: int) -> bool:
	for button in menu._buttons:
		if button.target == target and button.enabled:
			var origin: Vector3 = button.node.to_global(Vector3(0, 0, 1))
			var direction: Vector3 = -button.node.global_basis.z
			menu.press_pointer("right", origin, direction, true)
			menu.release_pointer("right", origin, direction, true)
			return true
	return false

func drag(menu: Node3D, target: int, fraction: float) -> void:
	var button: Dictionary = menu._buttons.filter(func(row): return row.target == target)[0]
	var surface: Node3D = menu._input_surface(target)
	var point := Vector3(menu.SLIDER_LEFT + menu.SLIDER_WIDTH * fraction, button.rect.get_center().y, 1)
	menu.press_pointer("right", surface.to_global(point), -surface.global_basis.z, true)
	menu.release_pointer("right", surface.to_global(point), -surface.global_basis.z, true)

func button(menu: Node3D, target: int) -> Dictionary:
	return menu._buttons.filter(func(row): return row.target == target)[0]

func reset_shown(menu: Node3D, target: int) -> bool:
	var reset := button(menu, target)
	return reset.enabled and reset.node.visible

func _run() -> void:
	preload("res://scripts/i18n.gd").use("en")
	var main := Main.new()
	main.settings_path = "user://playback-settings-regression.cfg"
	var video := Video.new()
	root.add_child(video)
	video.set_process(false)
	main.video = video
	var host := Host.new()
	video.platform = host
	video.local_uri = "file:///movie.mp4"
	video.media.begin(7)
	video.media.format = {"width": 1920, "height": 1080}
	video.media.playback = {"details": {"pgs_supported": true, "subtitle_tracks": [{"id": 1, "codec": "subrip"}, {"id": 2, "codec": "hdmv_pgs_subtitle"}]}}
	video.flat_pose = Transform3D(Basis(), Vector3(0, 1.6, -2))
	video._apply_geometry()
	video.panel.visible = true
	var menu := Menu.new()
	menu.state_provider = main._menu_state
	menu.adjustment_requested.connect(main._on_playback_adjustment)
	menu.adjustment_committed.connect(main._save_playback_adjustments)
	menu.setting_requested.connect(main._on_player_setting)
	root.add_child(menu)
	menu.set_process(false)
	main.player_menu = menu
	var camera := Camera3D.new()
	camera.position = Vector3(0, 1.6, 0)
	root.add_child(camera)
	video.view_camera = camera
	main._place_menu(menu)
	var centre: Vector3 = menu.to_global(menu.panel_centre())
	check(menu.global_basis.z.normalized().dot((camera.global_position - centre).normalized()) > 0.99999, "Below-eye menu faces the eye")
	check(centre.is_equal_approx(camera.global_position + Vector3(0, -0.475, -1.4)), "Tilting preserves the transport's default centre")
	menu.toggle()
	check(click(menu, 11) and menu.section == 1 and menu._adjustment.is_empty() and click(menu, Menu.SCREEN_SETTINGS) and menu._adjustment == "screen", "Settings opens Playback; Screen is the second tab")
	check(menu._buttons.any(func(b): return b.target == 102), "The bar stays under the settings popup")
	check(menu._adjust_rows.size() == 3 and menu.text_snapshot().contains("Screen size"), "Flat panel includes distance, size and rotation")
	check(not menu.text_snapshot().contains("Audio track") and not menu.text_snapshot().contains("Subtitles") and not menu.text_snapshot().contains("3D depth"), "Screen panel contains no duplicate controls")
	check(not reset_shown(menu, Menu.ROTATION_RESET) and not click(menu, Menu.ROTATION_RESET), "Zero rotation hides and disables reset")
	for scale in [0.4, 1.0, 1.5, 3.0]:
		video.set_screen_scale(scale)
		menu.refresh_values()
		var row: Dictionary = menu._adjust_rows[451]
		var percent: float = scale * 100
		check(is_equal_approx(main._menu_state().screen_scale, percent) and row.label.text == "%d%%" % roundi(percent), "Physical scale, menu state and percentage agree")
		check(is_equal_approx(row.knob.position.x, Menu.SLIDER_LEFT + (percent - 40) / 260 * Menu.SLIDER_WIDTH), "Screen size thumb matches displayed percentage")
	drag(menu, 451, 0)
	check(is_equal_approx(video.screen_scale, 0.4) and video.screen_distance == 2, "Minimum screen size changes no distance")
	check(menu._adjust_rows[451].label.text == "40%" and is_equal_approx(menu._adjust_rows[451].knob.position.x, Menu.SLIDER_LEFT), "Minimum drag displays 40% at the start")
	drag(menu, 451, 1)
	check(video.screen_scale == 3 and is_equal_approx(video._flat.size.x / video._flat.size.y, 16.0 / 9), "Maximum screen size preserves aspect")
	check(menu._adjust_rows[451].label.text == "300%" and is_equal_approx(menu._adjust_rows[451].knob.position.x, Menu.SLIDER_LEFT + Menu.SLIDER_WIDTH), "Maximum drag displays 300% at the end")
	drag(menu, 452, 1)
	check(video.screen_rotation == 90 and absf(video.panel.global_basis.x.y) > 0.99, "Rotation slider reaches clockwise 90 degrees")
	check(reset_shown(menu, Menu.ROTATION_RESET) and is_equal_approx(button(menu, Menu.ROTATION_RESET).rect.get_center().y, button(menu, 452).rect.get_center().y), "Rotation reset appears on its slider row")
	check(not button(menu, Menu.ROTATION_RESET).rect.intersects(button(menu, 452).rect), "Rotation reset does not overlap slider hit area")
	video.caption.text = "第一行字幕\nSecond subtitle line"
	video.caption.visible = true
	video._place_caption()
	check(video.caption.global_basis.is_equal_approx(Basis.IDENTITY), "Flat subtitle remains horizontal at 90 degrees")
	main._push_screen(1.0)
	check(video.screen_rotation == 90 and video.subtitle_transform().basis.is_equal_approx(Basis.IDENTITY), "Changing distance does not bake or double rotation")
	main._push_screen(-1.0)
	var bottom := video.caption.global_position.y
	main._on_playback_adjustment("subtitle_flat_position", 100)
	video._place_caption()
	check(video.caption.global_position.y > bottom and video.subtitle_position == 0, "Flat position rises without changing VR angle")
	main._on_playback_adjustment("subtitle_size", 200)
	video._place_caption()
	check(video.caption.font_size == 80 and video.caption.outline_size == 16, "Font and outline grow together")
	check(is_equal_approx(video.caption.pixel_size, 0.0016 * video.screen_scale), "Flat text scales with the screen")
	main._save_playback_adjustments()
	var saved := ConfigFile.new()
	check(saved.load(main.settings_path) == OK and saved.get_value("subtitles", "size") == 2 and saved.get_value("subtitles", "flat_position") == 1, "Text size and flat position persist")
	check(click(menu, Menu.ROTATION_RESET) and video.screen_rotation == 0 and video.screen_scale == 3 and video.screen_distance == 2, "Straighten changes only rotation")
	check(not reset_shown(menu, Menu.ROTATION_RESET) and not menu.text_snapshot().contains("Straighten"), "Rotation reset disappears immediately after restoration")
	for geometry in [1, 2, 3]:
		video.geometry = geometry
		video._apply_geometry()
		menu.refresh()
		check(menu._adjust_rows.size() == 1 and menu._adjust_rows[452].key == "screen_rotation", "Immersive mode offers rotation and hides flat controls")
		video.turn_view(0.2, 0.1)
		video.zoom_view(0.1)
		var yaw: float = video.view_yaw
		var pitch: float = video.view_pitch
		var zoom: float = video.view_zoom
		video.screen_rotation = 0
		video._apply_geometry()
		video._place_caption()
		var plane: Transform3D = video.material.get_shader_parameter("subtitle_world_to_patch")
		var pose := plane.affine_inverse()
		video.set_screen_rotation(-90)
		menu.refresh_values()
		video._place_caption()
		video._sync_subtitle_surface()
		check(video._subtitle_surface.visible and video._subtitle_surface.global_transform.is_equal_approx(pose), "VR captions keep their pose while the picture rolls")
		check(video._subtitle_surface.mesh is QuadMesh, "VR captions draw only their projection plane, not the whole sphere")
		check(click(menu, Menu.ROTATION_RESET) and video.view_yaw == yaw and video.view_pitch == pitch and video.view_zoom == zoom, "VR straighten preserves direction and zoom")
	video.geometry = 0
	video._apply_geometry()
	menu.refresh()
	check(click(menu, Menu.PLAYBACK_SETTINGS) and not menu.text_snapshot().contains("Eye order"), "Mono playback settings hide eye order")
	check(not menu._adjust_rows.has(454), "Flat video has no Alpha frame rate")
	check(not reset_shown(menu, Menu.SPEED_RESET) and not click(menu, Menu.SPEED_RESET), "Default playback rate hides and disables reset")
	for fraction in [0.0, 1.0]:
		drag(menu, 453, fraction)
		check(is_equal_approx(video.playback_speed, (0.25 if fraction == 0 else 3.0)) and host.rates.back() == [7, video.playback_speed], "Speed slider changes actual bridge rate at endpoint")
		check(reset_shown(menu, Menu.SPEED_RESET), "Non-default rate shows reset while dragging")
	check(is_equal_approx(button(menu, Menu.SPEED_RESET).rect.get_center().y, button(menu, 453).rect.get_center().y) and not button(menu, Menu.SPEED_RESET).rect.intersects(button(menu, 453).rect), "Speed reset shares its row without overlapping the rail")
	check(click(menu, Menu.SPEED_RESET) and video.playback_speed == 1.0 and host.rates.back() == [7, 1.0], "Restore 1x reaches bridge")
	check(not reset_shown(menu, Menu.SPEED_RESET) and not menu.text_snapshot().contains("Restore 1×"), "Speed reset disappears immediately at 1x")
	check(not video.set_playback_speed(NAN) and not video.set_playback_speed(0) and not video.set_playback_speed(3.1), "Invalid rates are rejected")
	host.accept = false
	check(not video.set_playback_speed(2) and video.playback_speed == 1, "Rejected native change leaves displayed rate unchanged")
	main.platform_plugin = host
	video.geometry = 1
	video._apply_geometry()
	menu.refresh()
	check(menu._adjust_rows.has(454) and menu._adjust_rows[454].label.text == "30 FPS", "VR180 playback settings show the Alpha frame rate at 30")
	drag(menu, 454, 1.0)
	check(host.alpha_fps.back() == 40 and main._menu_state().alpha_fps == 40 and menu._adjust_rows[454].label.text == "40 FPS", "Alpha frame rate reaches the bridge while dragging")
	drag(menu, 454, 0.0)
	var stored := ConfigFile.new()
	check(host.alpha_fps.back() == 10 and stored.load(main.settings_path) == OK and stored.get_value("video", "alpha_fps") == 10, "Alpha frame rate persists on release at the 10 FPS minimum")
	main._apply_alpha_fps(500)
	check(host.alpha_fps.back() == 40, "Alpha frame rate is clamped to 40")
	video.geometry = 0
	video._apply_geometry()
	video.stereo_sbs = true
	menu.refresh()
	check(click(menu, Menu.SETTINGS_TILE + Menu.OPERATIONS[1].find("stereo_view")) and menu._adjustment == "stereo_view"
		and menu._buttons.any(func(b): return b.target == Menu.EYE_SWAP and b.enabled), "Flat native stereo retains accessible eye-order control")
	check(click(menu, 400) and menu._adjustment.is_empty(), "Eye-order panel returns to video settings")
	video.stereo_sbs = false
	click(menu, Menu.SETTINGS_CLOSE)
	click(menu, 110)
	check(menu.choices.sliders.is_empty() and not menu.choices.targets.values().any(func(item): return item.get("key") == "subtitle_style"), "Flat CC initially hides all appearance controls")
	check(click(menu, Menu.SUBTITLE_APPEARANCE) and menu._subtitle_open, "Ray opens appearance without closing subtitle selection")
	check(menu.choices.sliders.size() == 3 and menu.text_snapshot().contains("Auto-load matching subtitles"), "Flat CC provides sync, size, vertical position and automatic loading switch")
	video.subtitles.select(2)
	menu.refresh()
	check(menu.choices.sliders.size() == 3 and not menu.choices.targets.values().any(func(item): return item.get("key") == "subtitle_style"), "PGS offers sync, size and vertical position while preserving bitmap colors")
	video.subtitles.select(1)
	menu.refresh()
	check(menu.choices.sliders.size() == 3, "Text controls return despite PGS also being listed")
	var saved_size: float = video.subtitle_size
	check(click(menu, Menu.SUBTITLE_APPEARANCE) and menu.choices.sliders.is_empty() and not menu.choices.targets.values().any(func(item): return item.get("key") == "subtitle_style") and video.subtitle_size == saved_size, "Collapsing hides all appearance controls without resetting settings")
	check(click(menu, 110) and click(menu, 110) and not menu._subtitle_appearance_open and menu.choices.sliders.is_empty(), "Reopening subtitles starts with appearance collapsed")
	check(click(menu, Menu.SUBTITLE_AUTO) and not video.subtitle_auto_load and menu._subtitle_open, "Automatic-loading switch is wired to the player")
	stored.load(main.settings_path)
	check(stored.get_value("subtitles", "auto_load") == false and main._menu_state().subtitle_auto_load == false, "Automatic-loading preference persists and refreshes menu state")
	video.subtitle_auto_load = true; main._restore_subtitle_settings()
	check(not video.subtitle_auto_load, "Automatic-loading preference survives settings reload")
	main._on_player_setting("subtitle_auto_load", true)
	# The global and playback panels share the same saved appearance and live renderer.
	var library := Library.new()
	library.settings_provider = main._library_settings
	library.setting_changed.connect(main._on_setting_changed)
	library.setting_previewed.connect(main._on_playback_adjustment)
	root.add_child(library)
	library.toggle(); library.section = Library.Section.SETTINGS; library.tab = Library.VIDEO_TAB; library.refresh()
	check(library.rows.size() == 11 and library.rows[6].value == video.subtitle_size * 100, "Global size reflects playback's current value")
	main._on_setting_changed("subtitle_size", 125)
	check(video.subtitle_size == 1.25 and main._menu_state().subtitle_size == 125 and main._library_settings().subtitle_size == 125, "Global and playback size agree")
	for preset in Style.PRESETS:
		library.scroll = library._max_scroll() # the style row lies below the first page
		library.refresh()
		var target := -1
		for id in library.choices.targets:
			if library.choices.targets[id].get("key") == "subtitle_style" and library.choices.targets[id].get("value") == preset.value: target = id
		check(click(library, target) and video.subtitle_style == preset.value, "Ray selects visual style " + preset.value)
		video._place_caption()
		check(video.caption.modulate == preset.text_color and video.caption.outline_modulate == preset.outline_color, "Flat subtitle receives fill and outline " + preset.value)
		for direction in [0, 1]:
			video.geometry = 1; video.subtitle_direction = direction; video._apply_geometry(); video._place_caption()
			check(video.projected_subtitles._style == preset.value and video.projected_subtitles._size == 1.25, "Same immersive cue updates style and size")
			if direction == 0:
				check(video.projected_subtitles.label.get_theme_color("font_color") == preset.text_color and video.projected_subtitles.label.get_theme_color("font_outline_color") == preset.outline_color, "Horizontal projected colors")
			else:
				check(video.projected_subtitles.vertical_text.text_color == preset.text_color and video.projected_subtitles.vertical_text.outline_color == preset.outline_color, "Vertical projected colors")
		video.geometry = 0; video._apply_geometry()
	main._on_player_setting("subtitle_style", "cyan_black")
	main._save_playback_adjustments()
	var appearance_saved := ConfigFile.new()
	check(appearance_saved.load(main.settings_path) == OK and appearance_saved.get_value("subtitles", "style") == "cyan_black" and appearance_saved.get_value("subtitles", "size") == 1.25, "Style and size persist together")
	video.subtitle_size = 1.0; video.subtitle_style = Style.DEFAULT
	main.settings = appearance_saved; main._restore_subtitle_settings()
	check(video.subtitle_size == 1.25 and video.subtitle_style == "cyan_black", "Startup restores the actual saved appearance")
	for old_distance in [10.0, 0.5, 0.1]:
		main.settings.set_value("subtitles", "distance", old_distance)
		main._restore_subtitle_settings()
		var expected_distance: float = minf(old_distance, 5.0)
		check(is_equal_approx(video.subtitle_distance, expected_distance) and is_equal_approx(main._menu_state().subtitle_distance, expected_distance) and is_equal_approx(main._library_settings().subtitle_distance, expected_distance), "Startup and both menus honor 0.1m to 5m test limits")
	main._save_playback_adjustments()
	var distance_saved := ConfigFile.new()
	check(distance_saved.load(main.settings_path) == OK and is_equal_approx(float(distance_saved.get_value("subtitles", "distance")), 0.1), "Nearest test distance persists on save")
	main.settings = distance_saved
	main._restore_subtitle_settings()
	check(is_equal_approx(video.subtitle_distance, 0.1), "Nearest test distance survives reload")
	main.settings.set_value("subtitles", "style", {"bad": true}); main.settings.set_value("subtitles", "size", INF)
	main._restore_subtitle_settings()
	check(video.subtitle_style == Style.DEFAULT and video.subtitle_size == 1.0, "Malformed style and non-finite size return to readable defaults")
	main._on_setting_changed("subtitle_size", 10)
	check(video.subtitle_size == 0.5, "Global size clamps the minimum")
	main._on_setting_changed("subtitle_size", 400)
	check(video.subtitle_size == 2, "Global size clamps the maximum")
	library.free()
	menu.free()
	video.free()
	main.free()
	camera.free()
	for failure in failures: push_error(failure)
	print("Playback settings: %s (%d)" % ["passed" if failures.is_empty() else "failed", checks])
	quit(0 if failures.is_empty() else 1)
