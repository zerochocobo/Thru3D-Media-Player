extends SceneTree

const Video := preload("res://scripts/mpv_video_display.gd")
const Menu := preload("res://scripts/player_menu.gd")
const Main := preload("res://scripts/main.gd")
const I18n := preload("res://scripts/i18n.gd")
var failures: Array[String] = []
var checks := 0

class Probe extends "res://scripts/mpv_video_display.gd":
	func _ready() -> void: pass # This fixture initializes only the source-format state below.
	var revisions := 0
	var advance_session := false
	var requests: Array[Dictionary] = []
	func _request_revision(_position_ms: int = -1, _mode: String = "") -> void:
		revisions += 1
		requests.append({"alpha": alpha_requested, "stereo": stereo_sbs, "depth": depth_requested, "geometry": geometry})
		if advance_session: media.begin(media.session_id + 1)
	func _apply_geometry() -> void:
		pass
	func _remember_mode(_user_change: bool = true) -> void:
		pass
	func _unbind() -> void:
		pass

func check(value: bool, message: String) -> void:
	checks += 1
	if not value: failures.append(message)

func _initialize() -> void:
	call_deferred("_run")

func click(menu: Node3D, target: int) -> bool:
	for button in menu._buttons:
		if button.target == target:
			var centre: Vector2 = button.rect.get_center()
			return menu.press_pointer("right_hand", menu.to_global(Vector3(centre.x, centre.y, 1)), -menu.global_basis.z, true)
	return false

func _run() -> void:
	I18n.use("en")
	var video := Probe.new()
	root.add_child(video)
	video.set_process(false)
	video.material = ShaderMaterial.new()
	video.local_uri = "file:///spatial-test.mov"
	video.media.begin(1)
	video.media.format = {"width": 3840, "height": 1080, "spatial_video": true, "stereo_mode": "sbs2l"}
	video.stereo_sbs = false
	video.depth_requested = true
	video._layout_pending = {"geometry": 1, "stereo": false}
	video._complete_layout()
	check(video.is_spatial_video(), "Verified source type is retained independently of the current format")
	check(video.geometry == 0 and video.stereo_layout() == 1, "Native spatial frames use a flat full-SBS screen")
	check(not video.depth_requested and video.revisions == 1, "Spatial stereo ends automatic mono depth processing")
	check(video._layout_pending == null, "Physical source packing overrides stale name inference")
	video._complete_layout()
	check(video.revisions == 1, "Already configured spatial playback does not recreate its session")
	for layout in [0, 2, 3, 4]:
		video.set_stereo_layout(layout)
		check(video.stereo_layout() == 1 and video.revisions == 1, "Spatial pixels cannot be reinterpreted as layout %d" % layout)
	check(video.toggle_eye_order() and video.swap_eyes, "The user can still reverse spatial eye order")
	video.mode_lock = {"geometry": 1, "layout": 1, "depth": false, "fisheye_fov": 180}
	var saved_lock := video.mode_lock.duplicate()
	for projection in [1, 2, 3]:
		video.set_projection(projection)
		check(video.geometry == 0 and video.revisions == 1, "Projection shortcut is blocked: %d" % projection)
	video.cycle_projection()
	video.toggle_stereo()
	video.toggle_mode_lock()
	video.set_fisheye_fov(220)
	check(video.geometry == 0 and video.stereo_layout() == 1 and video.mode_lock == saved_lock and video.fisheye_fov == 180,
		"Keyboard/controller cycling and mode locks cannot override the source or saved preference")
	video.auto_depth = true
	check(not video.set_depth(false) and not video.set_depth(true) and not video.set_depth_strength(0),
		"Spatial source cannot change global mono depth preference")
	check(video.auto_depth, "The user's automatic 3D preference is retained for ordinary files")
	# Saved/manual mode has no pending filename detection, but MV-HEVC still needs unpacking.
	video.geometry = 3
	video.top_bottom = true
	video.stereo_half = true
	video._layout_pending = null
	video._complete_layout()
	check(video.geometry == 0 and video.stereo_layout() == 1, "Saved TB/360 cannot distort a decoded spatial pair")
	var main := Main.new()
	main.video = video
	main.settings.set_value("effects", "auto_3d", true)
	main._on_menu_action("stereo_2d")
	main._on_menu_action("depth")
	main._on_menu_action("projection_1")
	main._on_menu_action("lock_mode")
	check(video.auto_depth and main.settings.get_value("effects", "auto_3d") and video.mode_lock == saved_lock,
		"Rejected menu commands have no preference-saving side effects")
	check(main._menu_state().spatial_video, "Main exposes decoded source type to the menu")
	video.advance_session = true
	main._on_menu_action("alpha")
	check(video.alpha_requested and video.requests.back() == {"alpha": true, "stereo": true, "depth": false, "geometry": 0},
		"Spatial passthrough reuses the stereo Alpha pipeline without mono depth")
	check(video.is_spatial_video() and not video.media.format.has("spatial_video"), "Alpha session replacement cannot temporarily unlock the source")
	main._on_menu_action("alpha")
	check(not video.alpha_requested and video.is_spatial_video(), "Turning passthrough off retains spatial playback mode")
	video._request_revision(1000)
	check(video.is_spatial_video(), "Seek session replacement retains the source type")
	var menu := Menu.new()
	main.player_menu = menu
	menu.state_provider = main._menu_state
	menu.action_requested.connect(main._on_menu_action)
	root.add_child(menu)
	menu.toggle()
	check(not menu._buttons.any(func(b): return b.target == 112) and menu._enabled("alpha"),
		"Spatial video hides the mono 2D-to-3D action and enables passthrough")
	check(click(menu, Menu.MODE), "Spatial mode panel opens")
	var texts: Array = menu._labels.map(func(label): return label.text)
	check(texts.has("Spatial video · MV-HEVC") and texts.has("Mode fixed"), "Source format and fixed-mode reason are visible")
	var before := video.revisions
	for button in menu._buttons:
		if button.target in range(Menu.MODE_PROJECTION, Menu.MODE_PROJECTION + 4) or button.target in [140, 141, 144, 145, 146]:
			check(not button.enabled and not click(menu, button.target), "Fixed mode tile rejects trigger: %d" % button.target)
			menu._activate(button.target)
	check(video.revisions == before and video.mode_lock == saved_lock, "Disabled tiles cannot switch mode or toggle a remembered lock")
	var selected: Array = menu._buttons.filter(func(b): return b.get("fixed_current", false))
	check(selected.size() == 2 and selected.all(func(b): return b.node.material_override.get_shader_parameter("surface_color") == Menu.SELECTED),
		"Flat and native stereo remain visibly selected while read-only")
	video.close_video()
	check(not video.is_spatial_video(), "Closing the source clears its format lock")
	video.media.begin(10)
	video.media.format = {"width": 1920, "height": 1080}
	video.advance_session = false
	video.auto_depth = false
	video.set_stereo_layout(0)
	check(video.stereo_layout() == 0, "An ordinary next video regains manual mono layout")
	menu.refresh_values()
	check(menu._buttons.any(func(b): return b.target == 112) and menu._enabled("alpha"), "Ordinary flat video offers Auto 3D and mono portrait Alpha")
	check(not menu._labels.any(func(label): return label.text.contains("MV-HEVC")), "Changing to ordinary video removes the source badge in an open mode panel")
	check(menu._buttons.filter(func(b): return b.target in range(130, 134)).all(func(b): return b.enabled), "Ordinary projection choices become clickable again")
	menu._depth_open = true # A source can be recognized while this popup is open.
	video.media.format = {"width": 3840, "height": 1080, "spatial_video": true}
	video._complete_layout()
	menu.refresh_values()
	check(menu._mode_open and menu._labels.any(func(label): return label.text.contains("MV-HEVC")) \
		and not menu._buttons.any(func(b): return b.target == 112), "Late format detection updates an already-open panel and hides Auto 3D")
	check(not menu._depth_open and not menu._buttons.any(func(b): return b.target == Menu.DEPTH), "Late spatial detection dismisses the mono depth slider too")
	main.video = null
	main.free()
	menu.queue_free()
	video.free()
	await process_frame
	print("Spatial video host checks=%d failures=%d" % [checks, failures.size()])
	for message in failures: push_error(message)
	quit(0 if failures.is_empty() else 1)
