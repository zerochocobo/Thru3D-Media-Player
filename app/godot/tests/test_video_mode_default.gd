extends SceneTree
const Main := preload("res://scripts/main.gd")
const Video := preload("res://scripts/mpv_video_display.gd")
const Menu := preload("res://scripts/player_menu.gd")
const PhotoMenu := preload("res://scripts/photo_menu.gd")
const I18n := preload("res://scripts/i18n.gd")
const Default := preload("res://scripts/video_mode_default.gd")
const Fixtures := preload("res://tests/test_file_mode_memory.gd")
var checks := 0
var failures: Array[String] = []
var serial := 0
var video: Node3D
var host: RefCounted

func _initialize() -> void: _run.call_deferred()
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func open_unknown(width: int = 1920, height: int = 1080, extra: Dictionary = {}) -> void:
	serial += 1
	check(video.open_local("file:///mode-default-%d.mp4" % serial, "Clip"), "Unknown file opens")
	complete(width, height, extra)

func complete(width: int = 1920, height: int = 1080, extra: Dictionary = {}) -> void:
	video.media.format = {"width": width, "height": height, "pixel_aspect": 1.0, "unapplied_rotation_degrees": 0}
	video.media.format.merge(extra, true)
	video.media.frame_counter = 1
	video._complete_layout()
	video._remember_mode(false)

func current() -> Dictionary:
	var result: Dictionary = video.current_lock()
	result.swap_eyes = video.swap_eyes
	return Default.clean(result)

func ray_toggle(menu: Node3D, hand: String) -> bool:
	for button in menu._buttons:
		if button.target != Menu.MODE_REUSE or not button.enabled: continue
		var origin: Vector3 = button.node.to_global(Vector3(0.46, 0, 1))
		var direction: Vector3 = -button.node.global_basis.z
		menu.press_pointer(hand, origin, direction, true)
		menu.release_pointer(hand, origin, direction, true)
		return true
	return false

func _run() -> void:
	var output := ProjectSettings.globalize_path("res://../../build/output/video-mode-default")
	DirAccess.make_dir_recursive_absolute(output)
	var main := Main.new()
	main.settings_path = output.path_join("settings.cfg")
	video = Video.new(); root.add_child(video); video.set_process(false); main.video = video
	video.mode_memory = Video.ModeMemory.new(output.path_join("memory-" + str(Time.get_ticks_usec())))
	host = Fixtures.Host.new(); video.platform = host
	video.last_mode_changed.connect(main._on_last_video_mode_changed)
	video.reuse_last_mode_changed.connect(main._on_reuse_last_video_mode_changed)
	video.mode_lock_changed.connect(main._on_mode_lock_changed.bind("video"))
	video.load_last_mode_preferences(main.settings)
	check(not video.reuse_last_mode and video.last_mode.is_empty(), "Fresh and existing users default off")
	for invalid in [null, {}, {"geometry": 1.5, "layout": 1, "fisheye_fov": 180}, {"geometry": 1, "layout": 8, "fisheye_fov": 180}, {"geometry": 1, "layout": 1, "fisheye_fov": 90}, {"geometry": 1, "layout": 1, "fisheye_fov": 180, "swap_eyes": "true"}]:
		check(Default.clean(invalid).is_empty(), "Malformed last mode safely ignored")
	open_unknown(3840, 1920)
	check(video.geometry == 1 and video.stereo_sbs and video.last_mode.is_empty(), "Disabled preference preserves automatic shape inference")
	video.set_projection(2); video.set_stereo_layout(4); video.set_fisheye_fov(220); video.toggle_eye_order()
	video.toggle_mode_lock()
	var expected := current()
	main._on_player_setting("reuse_last_mode", true)
	check(video.reuse_last_mode and video.mode_lock.is_empty() and video.last_mode == expected and current() == expected, "Enabling captures current layout and removes fixed lock without changing current playback")
	var stored := ConfigFile.new(); stored.load(main.settings_path)
	var restarted := Video.new(); restarted.load_last_mode_preferences(stored)
	check(restarted.reuse_last_mode and restarted.last_mode == expected, "Switch and full layout survive application restart")
	restarted.free()
	open_unknown()
	check(current() == expected, "Unknown aspect ratio uses last fisheye, half TB, FOV and eye order")
	for projection in range(4):
		for layout in range(5):
			video.set_projection(projection); video.set_stereo_layout(layout)
			expected = current()
			open_unknown(3840, 1920)
			check(current() == expected and video.last_mode == expected, "Last mode follows manual changes: %d/%d" % [projection, layout])
	video.set_projection(1); video.set_stereo_layout(1)
	check(video.open_local("file:///named-flat-2d.mp4", "flat_2d.mp4"), "Explicit filename opens")
	complete()
	check(video.geometry == 0 and not video.stereo_sbs and video.last_mode == current(), "Filename wins and becomes the next last mode")
	open_unknown(3840, 1920)
	check(video.geometry == 0 and not video.stereo_sbs, "Unknown 2:1 video reuses last flat mode instead of aspect guess")
	var saved := {"geometry": 3, "stereo_sbs": true, "top_bottom": true, "stereo_half": false, "swap_eyes": true, "alpha_requested": false, "profile": Video.AUTOMATIC_PROFILE}
	video.mode_memory.remember("file:///saved-flat-2d.mp4", saved)
	video.open_local("file:///saved-flat-2d.mp4", "flat_2d.mp4"); complete()
	check(video.geometry == 3 and video.top_bottom and video.swap_eyes, "Per-file memory wins over filename and last mode")
	video.open_local("file:///partial.mp4", "clip_180.mp4"); complete()
	check(video.geometry == 1 and video.stereo_sbs and not video.top_bottom, "Partial filename match uses normal completion, not last layout")
	video.open_local("file:///server.mp4", "Clip", 0, true, false, "", {"video_3d_format": "HalfTopAndBottom"}); complete()
	check(video.geometry == 0 and video.top_bottom and video.stereo_half, "Server-authored format wins")
	video.set_projection(2); video.set_fisheye_fov(200)
	open_unknown(1920, 1080, {"stereo_mode": "sbs2l"})
	check(video.geometry == 0 and video.stereo_sbs and not video.top_bottom and video.fisheye_fov == 180, "Decoded container stereo wins over last fallback")
	video.set_projection(1); video.set_stereo_layout(1)
	expected = current()
	open_unknown(1920, 1080, {"spatial_video": true})
	check(video.geometry == 0 and video.stereo_sbs and video.last_mode == expected, "Spatial video stays native and does not seed ordinary video defaults")
	video.close_video()
	video.default_auto_depth = true
	open_unknown()
	check(video.geometry == 1 and not video.depth_requested, "VR fallback never starts generated depth")
	video.set_projection(0); video.set_stereo_layout(0)
	open_unknown()
	check(video.geometry == 0 and video.depth_requested, "Flat mono fallback cooperates with global 2D to 3D default")
	video.mode_memory.remember("file:///remembered-off.mp4", {"geometry": 0, "stereo_sbs": false, "swap_eyes": false, "alpha_requested": false, "profile": Video.AUTOMATIC_PROFILE, "depth_requested": false})
	video.open_local("file:///remembered-off.mp4", "Clip"); complete()
	check(not video.depth_requested, "Per-file conversion Off beats both opening defaults")
	video.set_projection(2); video.set_stereo_layout(1)
	expected = current()
	video.open_local("file:///diagnostic.mp4", "flat_2d.mp4", 0, false); complete()
	video.set_projection(0)
	check(video.last_mode == expected, "Diagnostic opens do not overwrite last normal mode")
	video.open_local("externalvideo://temporary", "Clip", 0, true, false, "", {"external_temporary": true}); complete()
	check(video.geometry == 0, "External unknown source retains its existing safe format policy")
	video.set_projection(1); expected = current()
	host.next_id = -1
	video.open_local("file:///failed.mp4", "flat_2d.mp4")
	video.close_video()
	check(video.last_mode == expected, "Failed source does not replace last playable mode")
	host.next_id = 7
	video.set_reuse_last_mode(false)
	open_unknown()
	check(video.geometry == 0, "Disabling restores ordinary inference for the next file")
	video.set_reuse_last_mode(true); video.toggle_mode_lock()
	stored.load(main.settings_path)
	check(not video.reuse_last_mode and not stored.get_value("video", "reuse_last_mode", true) and not video.mode_lock.is_empty(), "Choosing a fixed lock turns off follow-last persistently")
	video._unlock_mode()
	video.set_reuse_last_mode(true); video.default_auto_depth = false
	video.set_projection(1); video.set_stereo_layout(1)
	open_unknown()
	video.set_projection(0); video.set_stereo_layout(0)
	open_unknown()
	check(video.geometry == 0 and not video.stereo_sbs and not video.depth_requested and video.last_mode.geometry == 0 and video.last_mode.layout == 0,
		"Switching an unknown video from inherited VR back to 2D also makes the next unknown file 2D")
	stored.load(main.settings_path)
	check(Default.clean(stored.get_value("video", "last_mode", {})) == current(), "Latest flat 2D choice also persists for restart")
	var menu := Menu.new(); main.player_menu = menu
	menu.state_provider = main._menu_state; menu.setting_requested.connect(main._on_player_setting)
	root.add_child(menu); menu.set_process(false); menu.visible = true; menu._mode_open = true
	for language in ["zh", "zh_Hant", "ja", "en"]:
		I18n.use(language)
		for projection in range(4):
			video.set_projection(projection); menu.refresh()
			var buttons: Array = menu._buttons.filter(func(b): return b.target == Menu.MODE_REUSE)
			check(buttons.size() == 1 and menu._tips.get(Menu.MODE_REUSE) == I18n.t(Default.HINT), "One localized footer switch and tooltip: " + language)
			if buttons.is_empty(): continue
			var button: Dictionary = buttons[0]
			var label: Label3D = button.node.get_child(0)
			check(label.text == I18n.t(Default.TITLE) and menu.text_width(label.text, label.font_size) < 0.9, "Title fits before toggle: " + language)
			for other in menu._buttons:
				if other.target != Menu.MODE_REUSE: check(not button.rect.intersects(other.rect), "Footer avoids other pointer targets")
			var rect: Rect2 = button.rect
			var mode_before := current()
			var enabled_before: bool = video.reuse_last_mode
			check(ray_toggle(menu, "left") and video.reuse_last_mode != enabled_before and current() == mode_before, "Left ray changes preference only")
			check(menu._mode_open and menu._buttons.filter(func(b): return b.target == Menu.MODE_REUSE)[0].rect == rect, "Toggle keeps popup open and stationary")
			check(ray_toggle(menu, "right") and video.reuse_last_mode == enabled_before, "Right ray toggles back")
	var photo := PhotoMenu.new(); root.add_child(photo); photo.set_process(false); photo.visible = true; photo._mode_open = true; photo.refresh()
	check(not photo._buttons.any(func(b): return b.target == Menu.MODE_REUSE), "Photos keep independent mode controls")
	photo.free()
	video._spatial_video = true; menu.refresh()
	check(not menu._buttons.any(func(b): return b.target == Menu.MODE_REUSE), "Fixed spatial mode hides general default")
	video._spatial_video = false; video.cast_token = 1; menu.refresh()
	check(not menu._buttons.any(func(b): return b.target == Menu.MODE_REUSE), "Cast session does not expose file-opening preference")
	video.cast_token = 0
	I18n.use("en"); main.player_menu = null
	menu.free(); video.free(); main.free()
	for failure in failures: push_error(failure)
	print("Video mode default: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
