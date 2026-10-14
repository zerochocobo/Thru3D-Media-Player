extends Node3D

const DisplayController := preload("res://scripts/xr_display.gd")
const Board := preload("res://scripts/calibration_board.gd")
const Log := preload("res://scripts/diagnostic_log.gd")
const Video := preload("res://scripts/mpv_video_display.gd")
const StickControls := preload("res://scripts/player_stick_controls.gd")
const HandPointer := preload("res://scripts/hand_pointer.gd")
const InputVisuals := preload("res://scripts/input_visuals.gd")
const Geometry := preload("res://scripts/video_geometry.gd")
const LibraryMenu := preload("res://scripts/library_menu.gd")
const StorageVolume := preload("res://scripts/storage_volume.gd")
const Quality := preload("res://scripts/display_quality.gd")
const ThumbnailCache := preload("res://scripts/thumbnail_cache.gd")
const SETTINGS_PATH := "user://player_settings.cfg"
const PhotoDisplay := preload("res://scripts/photo_display.gd")
const PhotoMenu := preload("res://scripts/photo_menu.gd")
const PhotoHandGestures := preload("res://scripts/photo_hand_gestures.gd")
const PhotoPalmSwipe := preload("res://scripts/photo_palm_swipe.gd")
const ImageInfo := preload("res://scripts/image_info.gd")
const PlayerMenu := preload("res://scripts/player_menu.gd")
const I18n := preload("res://scripts/i18n.gd")
const PlatformMethods := preload("res://scripts/platform_methods.gd")
const FpsOverlay := preload("res://scripts/fps_overlay.gd")
const Background := preload("res://scripts/app_background.gd")
const ViewFollow := preload("res://scripts/view_follow.gd")
const ControllerBindings := preload("res://scripts/controller_bindings.gd")
const InterfaceMove := preload("res://scripts/interface_move.gd")
const MenuComposition := preload("res://scripts/menu_composition.gd")
var menu_composition: Node
var controller_bindings := ControllerBindings.new()
var interface_move := InterfaceMove.new()
var _controller_consumed := {}
const RVM_PROFILES := ["256x144", "384x216", "512x288", "256x256", "384x384", "512x512", "320x320"]
const ALPHA_FPS_DEFAULT := 20
const ALPHA_FPS_LIMITS := Vector2i(10, 40)

var display := DisplayController.new()
var display_quality := Quality.DEFAULT
## GPU name used for the quality tier; empty reads the active renderer (tests may preset it).
var gpu_adapter := ""
var low_end_gpu := false
var status_label: Label3D
var report_timer: Timer
var platform_plugin: Object
var last_request := 0
var android_report: Dictionary = {}
var photo: Node3D
var photo_active := false
var video_menu: Node3D
var photo_menu: Node3D
var video: Node3D
var video_queue: Array[Dictionary] = []
var calibration_board: Node3D
var last_rvm_request := 0
var next_rvm_case := 0
var rvm_report: Dictionary = {}
var rvm_status := "RVM benchmark not run"
var right_controller: XRController3D
var left_controller: XRController3D
var hand_pointers := {}
var photo_hands := PhotoHandGestures.new()
var photo_swipe := PhotoPalmSwipe.new()
var memory_swipe := preload("res://scripts/memory_swipe.gd").new()
var _gallery_save_after := 0
var _gallery_saved_state := ""
var _photo_open_hide_controls := false
var _photo_pointer_hand := ""
var _inspect_hand := ""
var _inspect_blocked := {}
var _inspect_desktop_ray: Variant
var hand_marks := {}
var input_visuals: Node3D
var xr_origin: XROrigin3D
var xr_camera: XRCamera3D
var fps_overlay: Label3D
var stick_controls := StickControls.new()
var recent_menu: Node3D
var player_menu: Node3D
var settings := ConfigFile.new()
var settings_path := SETTINGS_PATH
var _audio_save_after := 0
var background: Node
var view_follow := ViewFollow.new()
var temporary_passthrough := false
var controlled_request := 0
var controlled_report: Dictionary = {}
var controlled_status := "Controlled decoder probe not run"

func _ready() -> void:
	var world := WorldEnvironment.new()
	world.environment = Environment.new()
	add_child(world)
	var origin := XROrigin3D.new()
	xr_origin = origin
	origin.name = "XROrigin3D"
	add_child(origin)
	var camera := XRCamera3D.new()
	xr_camera = camera
	camera.name = "XRCamera3D"
	origin.add_child(camera)
	var desktop := OS.get_name() != "Android" or OS.get_cmdline_user_args().has("--mpv-diagnostic-2d")
	if desktop:
		camera.position.y = 1.6
	for hand in ["left_hand", "right_hand"]:
		hand_pointers[hand] = HandPointer.new()
		var mark := MeshInstance3D.new()
		var sphere := SphereMesh.new()
		sphere.radius = 0.006
		sphere.height = 0.012
		mark.mesh = sphere
		var material := StandardMaterial3D.new()
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		material.albedo_color = Color(0.15, 0.9, 1.0) if hand == "left_hand" else Color(1.0, 0.65, 0.15)
		mark.material_override = material
		mark.visible = false
		origin.add_child(mark)
		hand_marks[hand] = mark
		var controller := XRController3D.new()
		controller.tracker = hand
		controller.pose = "aim"
		controller.button_pressed.connect(_on_controller_button.bind(hand))
		controller.button_released.connect(_on_controller_release.bind(hand))
		origin.add_child(controller)
		if hand == "right_hand":
			right_controller = controller
		else:
			left_controller = controller
	var board := Board.new()
	calibration_board = board
	board.name = "CalibrationBoard"
	add_child(board)
	status_label = Label3D.new()
	status_label.position = Vector3(0, 2.45, -2)
	status_label.font_size = 22
	status_label.pixel_size = 0.003
	status_label.outline_size = 5
	add_child(status_label)
	display.status_changed.connect(_update_status)
	display.status_changed.connect(_on_input_session_changed)
	settings.load(settings_path)
	controller_bindings.restore(settings.get_value("input", "controller_bindings", {}))
	I18n.use(str(settings.get_value("ui", "language", "auto")))
	fps_overlay = FpsOverlay.new()
	fps_overlay.source = _fps_sample
	camera.add_child(fps_overlay)
	fps_overlay.set_shown(bool(settings.get_value("ui", "show_fps", false)))
	# Eye-buffer render scale: the background and shader-drawn media. Compositor layers (menus,
	# layer video and photos) keep their own resolution.
	display_quality = Quality.load_quality(settings)
	if gpu_adapter.is_empty(): gpu_adapter = RenderingServer.get_video_adapter_name()
	low_end_gpu = Quality.is_low_end_gpu(gpu_adapter)
	display.render_scale = Quality.render_scale(display_quality, low_end_gpu)
	display.configure(get_viewport(), world.environment, XRServer.find_interface("OpenXR"), desktop)
	display.attach_backdrop(camera)
	input_visuals = InputVisuals.new()
	input_visuals.name = "InputVisuals"
	origin.add_child(input_visuals)
	# Long-press of the controller's Meta button recenters the runtime's space; bring the screen
	# and menus in front of the new view, exactly as the in-app Recenter does.
	var openxr := XRServer.find_interface("OpenXR")
	if not desktop and openxr and openxr.has_signal("pose_recentered"):
		openxr.connect("pose_recentered", _on_system_recentered)
	_head_placed = desktop
	# Everyday playback uses the validated default model, including migrated settings.
	if str(settings.get_value("alpha", "model", "fast")) != "fast":
		settings.set_value("alpha", "model", "fast")
		settings.save(settings_path)
	# The video node warms the RVM model when it enters the tree: select the model first.
	if Engine.has_singleton("QuestPlayer"):
		Engine.get_singleton("QuestPlayer").set_rvm_model("fast")
	video = Video.new()
	video.name = "VideoDisplay"
	video.changed.connect(_on_video_changed)
	video.playback_failed.connect(_on_video_playback_failed)
	video.audio_options_changed.connect(_on_audio_options_changed)
	_restore_audio_preferences()
	video.mode_lock_changed.connect(_on_mode_lock_changed.bind("video"))
	video.thumbnail_ready.connect(_on_video_thumbnail_ready)
	video.prefer_clone_voice = bool(settings.get_value("audio", "prefer_clone_voice", false))
	video.history_enabled = bool(settings.get_value("library", "history", true))
	_restore_seek_settings()
	video.depth_strength = video.DepthStrength.remembered(float(settings.get_value("video", "depth_strength", 1.0)))
	video.auto_depth = bool(settings.get_value("effects", "auto_3d", false))
	video.load_mode_lock(settings.get_value("video", "mode_lock", {}))
	_restore_subtitle_settings()
	video.color_grade.restore(settings.get_value("video", "color_grade", {}))
	# The flat screen keeps the distance, size and curve the viewer last chose.
	video.screen_distance = clampf(float(settings.get_value("screen", "distance", video.SCREEN_DISTANCE)),
		video.DISTANCE_LIMITS.x, video.DISTANCE_LIMITS.y)
	video.screen_scale = clampf(float(settings.get_value("screen", "scale", 1.0)), video.SCALE_LIMITS.x, video.SCALE_LIMITS.y)
	video.screen_curve = clampf(float(settings.get_value("screen", "curve", 0.0)), 0.0, 1.0)
	add_child(video)
	_update_thumbnail_protection()
	video.sharpness = Quality.load_sharpness(settings, low_end_gpu)
	video.view_camera = camera
	photo = PhotoDisplay.new()
	photo.name = "PhotoDisplay"
	photo.depth_strength = photo.DepthStrength.remembered(float(settings.get_value("photo", "depth_strength", 1.0)), photo.DepthStrength.PHOTO_MAX)
	photo.auto_depth = bool(settings.get_value("effects", "auto_3d", true))
	photo.load_mode_lock(settings.get_value("photo", "mode_lock", {}))
	photo.catalog = video.recent_files
	photo.history_enabled = video.history_enabled
	photo.changed.connect(_on_photo_changed)
	photo.mode_lock_changed.connect(_on_mode_lock_changed.bind("photo"))
	photo.restore_view_settings(settings)
	add_child(photo)
	photo.sharpness = Quality.load_sharpness(settings, low_end_gpu)
	photo.view_camera = camera
	photo.video_layer = video.video_layer # one compositor layer provider for both players
	if video.video_layer: video.video_layer.supersampling = Quality.load_supersampling(settings)
	display.set_foveation(int(settings.get_value("video", "foveation", 0)))
	recent_menu = LibraryMenu.new()
	recent_menu.controls_page.bindings = controller_bindings
	recent_menu.catalog = video.recent_files
	recent_menu.file_actions.load(settings.get_value("library", "orders", {}))
	recent_menu.load_view_mode(settings.get_value("library", "view_mode", "grid"))
	recent_menu.file_actions.set_enabled(bool(settings.get_value("library", "file_editing", false)))
	recent_menu.file_renamed.connect(_on_file_renamed)
	recent_menu.current_file_provider = func(): return _viewer().local_uri
	recent_menu.file_delete_preparing.connect(_prepare_file_delete)
	recent_menu.file_deleted.connect(_forget_deleted_file)
	recent_menu.settings_provider = _library_settings
	recent_menu.chosen.connect(_on_library_chosen)
	recent_menu.storage_eject_requested.connect(_on_storage_eject_requested)
	recent_menu.storage_removed.connect(_release_storage_readers)
	recent_menu.layout_requested.connect(_toggle_library_layout)
	recent_menu.setting_changed.connect(_on_setting_changed)
	recent_menu.setting_previewed.connect(_on_playback_adjustment)
	_connect_session_controls(recent_menu)
	add_child(recent_menu)
	if Engine.has_singleton("QuestPlayer"):
		var plugin := Engine.get_singleton("QuestPlayer")
		recent_menu.attach_platform(plugin)
		plugin.connect("mpv_debug_command", _on_display_debug_command)
		plugin.set_mpv_output_width(Quality.output_width(Quality.load_output_choice(settings), low_end_gpu))
		if PlatformMethods.supports(plugin, "set_mpv_alpha_fps"):
			plugin.set_mpv_alpha_fps(_alpha_fps())
	player_menu = PlayerMenu.new()
	player_menu.state_provider = _menu_state
	player_menu.action_requested.connect(_on_menu_action)
	player_menu.recent_requested.connect(_show_recent_menu)
	player_menu.seek_requested.connect(_on_menu_seek)
	player_menu.bookmark_requested.connect(_on_bookmark_request)
	player_menu.bookmark_mode_requested.connect(_on_bookmark_mode_requested)
	player_menu.setting_requested.connect(_on_player_setting)
	player_menu.volume_requested.connect(_on_menu_volume)
	player_menu.adjustment_requested.connect(_on_playback_adjustment)
	player_menu.adjustment_committed.connect(_save_playback_adjustments)
	player_menu.subtitle_requested.connect(video.set_subtitle_track)
	player_menu.depth_strength_requested.connect(_on_depth_strength.bind(false))
	player_menu.depth_strength_committed.connect(_save_depth_strength)
	_connect_session_controls(player_menu)
	add_child(player_menu)
	video_menu = player_menu
	photo_menu = PhotoMenu.new()
	photo_menu.state_provider = photo.snapshot
	photo_menu.queue_provider = func(): return photo.queue
	photo_menu.action_requested.connect(_on_photo_action)
	photo_menu.adjustment_requested.connect(_on_photo_adjustment)
	photo_menu.adjustment_committed.connect(_save_photo_adjustments)
	photo_menu.depth_strength_requested.connect(_on_depth_strength.bind(true))
	photo_menu.depth_strength_committed.connect(_save_depth_strength)
	photo_menu.recent_requested.connect(_show_recent_menu)
	_connect_session_controls(photo_menu)
	add_child(photo_menu)
	video_menu.expanded_library = recent_menu
	photo_menu.expanded_library = recent_menu
	menu_composition = MenuComposition.new()
	add_child(menu_composition)
	if OS.is_debug_build(): # capture-density experiments; applies at launch
		menu_composition.debug_pixel_scale = float(settings.get_value("debug", "menu_layer_scale", 0.0))
		menu_composition.debug_bands = bool(settings.get_value("debug", "menu_layer_bands", false))
	menu_composition.configure(origin, camera, display, [recent_menu, video_menu, photo_menu], low_end_gpu)
	background = Background.new()
	background.choice = str(settings.get_value("appearance", "background", "belfast"))
	background.custom_path = str(settings.get_value("appearance", "custom_path", ""))
	background.custom_title = str(settings.get_value("appearance", "custom_title", ""))
	background.custom_orientation = int(settings.get_value("appearance", "custom_orientation", 1))
	background.yaw = fposmod(float(settings.get_value("appearance", "background_yaw", 0.0)), 360.0)
	background.brightness = clampf(float(settings.get_value("appearance", "background_brightness", 1.0)), 0.5, 1.25)
	background.changed.connect(_on_background_changed)
	background.custom_saved.connect(_on_custom_background_saved)
	add_child(background)
	if Engine.has_singleton("QuestPlayer"):
		platform_plugin = Engine.get_singleton("QuestPlayer")
		if PlatformMethods.supports(platform_plugin, "set_ui_language"):
			platform_plugin.set_ui_language(I18n.choice)
		platform_plugin.connect("capabilities_ready", _on_capabilities_ready)
		platform_plugin.connect("android_lifecycle", _on_android_lifecycle)
		platform_plugin.connect("rvm_benchmark_result", _on_rvm_result)
		for kind in ["state", "frame", "error"]:
			platform_plugin.connect("controlled_" + kind, _on_controlled_event.bind(kind))
		request_capabilities()
	else:
		Log.record("android_plugin_unavailable", {"desktop_preview": desktop})
	report_timer = Timer.new()
	report_timer.wait_time = 2.0
	report_timer.timeout.connect(_save_report)
	add_child(report_timer)
	report_timer.start()
	_update_status()
	if not OS.get_cmdline_user_args().has("--mpv-diagnostic-2d"):
		_show_recent_menu()
	Log.record("ui_ready", {"library_visible": recent_menu.visible, "player_visible": player_menu.visible,
		"diagnostics_visible": status_label.visible, "calibration_visible": calibration_board.visible,
		"menu_selection": "controller_ray_trigger_or_hand_pinch"})
	Log.record("app_started", {"version": ProjectSettings.get_setting("application/config/version"), "os": OS.get_name()})
	# Source distribution: private capture automation is excluded.

## Desktop preview: dragging with the mouse moves the picture, the wheel zooms immersive views.
func _unhandled_input(event: InputEvent) -> void:
	if photo_active and photo.inspect:
		if event is InputEventMouseMotion:
			_inspect_desktop_ray = [photo.view_camera.project_ray_origin(event.position), photo.view_camera.project_ray_normal(event.position)]
			_update_photo_inspect()
		elif event is InputEventMouseButton and event.pressed and event.button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT]:
			_close_photo_inspect()
		return
	if _active_menu() or not video or _viewer().local_uri.is_empty():
		return
	if photo_active and photo.gallery.mode != 0 and event is InputEventMouse:
		var origin: Vector3 = photo.view_camera.project_ray_origin(event.position)
		var direction: Vector3 = photo.view_camera.project_ray_normal(event.position)
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				if photo.gallery.press_pointer("desktop", origin, direction): return
			elif photo.gallery.release_pointer("desktop", origin, direction): return
		elif event is InputEventMouseMotion:
			photo.gallery.update_pointer("desktop", origin, direction)
			if photo.gallery.has_capture(): return
		elif event is InputEventMouseButton and event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN] and photo.gallery.overview():
			photo.zoom_picture(0.08 if event.button_index == MOUSE_BUTTON_WHEEL_UP else -0.08); return
	if event is InputEventMouseMotion and event.button_mask & MOUSE_BUTTON_MASK_LEFT:
		_turn_picture(-event.relative.x * MOUSE_TURN, -event.relative.y * MOUSE_TURN)
	elif event is InputEventMouseButton and event.pressed and event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
		var forward := 1.0 if event.button_index == MOUSE_BUTTON_WHEEL_UP else -1.0
		if photo_active:
			_toggle_photo_inspect()
			if display.preview:
				_inspect_desktop_ray = [photo.view_camera.project_ray_origin(event.position), photo.view_camera.project_ray_normal(event.position)]
			_update_photo_inspect()
		elif _viewer().geometry != Geometry.Geometry.FLAT:
			_viewer().zoom_view(0.05 * forward)
		else:
			_push_screen(0.1 * forward)
			_save_screen()

func _unhandled_key_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if photo_active and photo.inspect and event.keycode in [KEY_ESCAPE, KEY_SPACE]:
			_close_photo_inspect()
			return
		if event.keycode == KEY_TAB:
			_toggle_player_menu()
			return
		var menu := _active_menu()
		if menu:
			if OS.get_name() == "Android":
				return
			if event.keycode == KEY_ESCAPE:
				menu.dismiss()
			elif menu == recent_menu:
				match event.keycode:
					KEY_UP: recent_menu.move_focus(-1)
					KEY_DOWN: recent_menu.move_focus(1)
					KEY_ENTER: recent_menu.activate_desktop()
			return
		if photo_active:
			match event.keycode:
				KEY_LEFT: if not photo.inspect: photo.navigate(-1)
				KEY_RIGHT: if not photo.inspect: photo.navigate(1)
				KEY_SPACE: _toggle_photo_inspect()
				KEY_R: _reset_picture()
				KEY_P: photo.cycle_projection()
				KEY_S: photo.toggle_stereo()
				KEY_E: photo.toggle_eye_order()
				KEY_O: _show_recent_menu()
			return
		match event.keycode:
			KEY_T:
				_toggle_display()
			KEY_R:
				_recenter()
			KEY_D:
				request_capabilities()
			KEY_O:
				_show_recent_menu()
			KEY_SPACE:
				video.toggle_play()
			KEY_S:
				video.toggle_stereo()
			KEY_P:
				video.cycle_projection()
			KEY_LEFT:
				video.seek_relative(-10000)
			KEY_RIGHT:
				video.seek_relative(10000)
			KEY_L:
				video.toggle_loop()
			KEY_M:
				video.toggle_mute()
			KEY_U:
				video.change_volume(10.0)
			KEY_J:
				video.change_volume(-10.0)
			KEY_H:
				video.cycle_audio_track()
			KEY_C:
				video.cycle_subtitle_track()
			KEY_E:
				video.toggle_eye_order()
			KEY_V:
				video.play_calibration_clip()
			KEY_F8:
				_request_rvm_benchmark(false)
			KEY_F9:
				_request_rvm_benchmark(true)
			KEY_F6:
				_request_rvm_benchmark(next_rvm_case % 2 == 1, RVM_PROFILES[next_rvm_case >> 1])
			KEY_F7:
				_request_controlled_probe()

# Menus are ray + trigger only. A list row clicks on release unless the ray dragged to scroll.
# Outside the menus a trigger tap shows/hides the controls; held and moved, it drags the picture.
func _on_controller_release(action: String, hand: String = "") -> void:
	controller_bindings.release(hand, action)
	var consumed_key := hand + "/" + action
	var consumed: bool = _controller_consumed.has(consumed_key)
	_controller_consumed.erase(consumed_key)
	if not interface_move.capture.is_empty() and interface_move.capture.hand == hand and interface_move.capture.input == action:
		if interface_move.capture.moved:
			_menu_touched_ms = Time.get_ticks_msec()
			var head: Variant = _head_pose()
			for target in interface_move.capture.targets:
				if not is_instance_valid(target.node): continue
				if head != null and target.kind in ["menu", "screen", "detail"]:
					var world: Transform3D = target.node.global_transform * target.node.flat_pose if target.kind == "screen" else target.node.global_transform
					var frame: Transform3D = InterfaceMove.menu_head(head, view_follow.enabled) if target.kind == "menu" else head
					interface_move.placements[target.key] = frame.affine_inverse() * world
					if target.kind != "detail": view_follow.capture(target.key, head, world)
					elif photo: photo.detail_placement = interface_move.placements[target.key]
				if target.kind == "gallery": target.node.remember_layout_pose()
				if target.kind == "screen" and is_instance_valid(target.node):
					target.node.set_screen_distance((target.node.global_transform * target.node.flat_pose).origin.distance_to(_eye()))
					if photo_active and photo.gallery.focus >= 0: photo.gallery.remember_focus_pose(photo.global_transform * photo.flat_pose)
			if video and not _viewer().local_uri.is_empty() and interface_move.capture.targets.any(func(target): return target.kind in ["screen", "immersive", "gallery"]): _save_screen()
		interface_move.cancel(); stick_controls.suspend(); return
	if not _grab.is_empty() and _grab.get("release_input", "trigger_click") == action and _grab.hand == hand:
		_on_pointer_release("trigger_click", hand); return
	if consumed: return
	if not _controller_allowed(hand): return
	_on_pointer_release(action, hand)

func _on_pointer_release(action: String, hand: String) -> void:
	if action == "trigger_click" and _inspect_blocked.has(hand):
		_inspect_blocked.erase(hand)
		return
	if action == "trigger_click" and _ray(hand) == null:
		_cancel_pointer(hand)
		return
	if action == "trigger_click" and photo_active and photo.gallery.capture.get("hand", "") == hand:
		var ray: Variant = _ray(hand)
		photo.gallery.release_pointer(hand, ray[0] if ray != null else Vector3.ZERO, ray[1] if ray != null else Vector3.ZERO, ray != null)
		stick_controls.suspend()
		return
	if action == "trigger_click" and not _grab.is_empty() and _grab.hand == hand:
		var grab := _grab
		_grab = {}
		_viewer().set_corner_hover(-1)
		if grab.moved and not grab.has("inspect") and _viewer().geometry == Geometry.Geometry.FLAT:
			_save_screen()
		if not grab.moved:
			if player_menu.visible:
				player_menu.dismiss()
			elif not grab.get("hid_menu", false):
				_show_player_menu()
		return
	var menu := _active_menu()
	if action != "trigger_click" or not menu or not menu.has_method("release_pointer"):
		return
	var ray: Variant = _ray(hand)
	menu.release_pointer(hand, ray[0] if ray != null else Vector3.ZERO,
		ray[1] if ray != null else Vector3.ZERO, ray != null)

func _on_controller_button(action: String, hand: String = "") -> void:
	if not _controller_allowed(hand): return
	if action not in ControllerBindings.BUTTONS or hand not in ControllerBindings.HANDS:
		if action == "menu_button": interface_move.cancel()
		_on_pointer_button(action, hand); return
	if controller_bindings.blocked[hand].has(action): return
	controller_bindings.press(hand, action)
	var consumed_key := hand + "/" + action
	if not interface_move.capture.is_empty() and interface_move.capture.moved:
		_controller_consumed[consumed_key] = true; return
	var id := controller_bindings.resolve(hand, action, _controller_context())
	if photo_active and photo.inspect and not (id in ["photo_close", "move_photo"] and _shortcut_allowed(id)):
		_on_pointer_button(action, hand); return
	var menu := _active_menu()
	# A real UI hit/capture keeps trigger selection, regardless of user shortcut mappings.
	if action == "trigger_click" and menu:
		var ray: Variant = _ray(hand)
		var chord_modifier: bool = controller_bindings.down[hand].has("grip_click") and controller_bindings.is_modifier(hand, action, _controller_context()) and _shortcut_allowed("play")
		if _menu_captured(menu) or (not chord_modifier and ray != null and not menu.ray_hit(ray[0], ray[1]).is_empty()):
			interface_move.cancel(); _on_pointer_button(action, hand); return
	if interface_move.pending() and not id.begins_with("move_") and not _is_chord(id, hand, action):
		_controller_consumed[consumed_key] = true; return
	if id.begins_with("move_") and _shortcut_allowed(id):
		_begin_interface_move(hand, action); _controller_consumed[consumed_key] = true; return
	if controller_bindings.is_modifier(hand, action, _controller_context()):
		_controller_consumed[consumed_key] = true; return
	if not id.is_empty() and _shortcut_allowed(id, _is_chord(id, hand, action)):
		if interface_move.pending(): interface_move.cancel()
		if id.begins_with("drag_"):
			_on_pointer_button("trigger_click", hand)
			if not _grab.is_empty(): _grab["release_input"] = action
		else:
			_controller_consumed[consumed_key] = true
			_execute_shortcut(id, hand, 1.0, 0.18)
		return
	if menu and action in ["trigger_click", "by_button"]: _on_pointer_button(action, hand)
	else: _controller_consumed[consumed_key] = true

func _binding_page() -> bool:
	return recent_menu is LibraryMenu and recent_menu.controls_page.active()

func _controller_context() -> String:
	if photo_active: return "photo"
	return "video_immersive" if video and video.geometry != Geometry.Geometry.FLAT else "video_flat"

func _menu_captured(menu: Node3D) -> bool:
	if menu == null: return false
	if menu.has_method("has_pointer_capture"): return menu.has_pointer_capture()
	if menu is LibraryMenu: return not menu._drag.is_empty() or not menu.choices.capture.is_empty() or not menu.account_panel.web_hand.is_empty()
	return false

func _shortcut_allowed(id: String, chord: bool = false) -> bool:
	if not _input_focused() or not _inspect_blocked.is_empty(): return false
	if photo_active and ((photo.inspect and id not in ["photo_close", "move_photo"]) or photo.gallery.has_capture() or not photo_hands.owners.is_empty()): return false
	var menu := _active_menu()
	if _menu_captured(menu) or not _grab.is_empty(): return false
	if id == "photo_close": return photo_active and photo.gallery.mode in [2, 3] and photo.gallery.focus >= 0 and not photo.gallery.returning and (menu == null or menu == photo_menu)
	if id.begins_with("move_"): return not (_binding_page() and (not recent_menu.choices.opened.is_empty() or not recent_menu.controls_page.pending.is_empty()))
	if menu:
		if menu != player_menu or photo_active or not player_menu.allows_playback_sticks(): return false
		if id.begins_with("drag_"): return false
		if not chord and id in ["library_video", "library_photo", "reset_video", "reset_photo", "projection_video", "projection_photo", "inspect"]: return false
	if id == "play": return video != null and not video.local_uri.is_empty() and video.media.accepts(video.media.session_id)
	return true

func _execute_shortcut(id: String, hand: String = "right_hand", amount: float = 1.0, delta: float = 1.0 / 72.0) -> void:
	match id:
		"play": video.toggle_play()
		"library_video", "library_photo": _show_recent_menu()
		"reset_video", "reset_photo": _reset_picture()
		"projection_video", "projection_photo": _viewer().cycle_projection()
		"inspect": _toggle_photo_inspect(hand)
		"back20", "forward20", "back10", "forward10":
			var seconds := 20 if id.ends_with("20") else 10
			video.seek_relative(seconds * 1000 * (-1 if id.begins_with("back") else 1))
		"volume_up", "flat_volume_up": video.change_volume(10)
		"volume_down", "flat_volume_down": video.change_volume(-10)
		"zoom_in", "zoom_out": video.zoom_view((1 if id == "zoom_in" else -1) * absf(amount) * ZOOM_SPEED * delta)
		"photo_next", "photo_previous": photo.navigate(1 if id == "photo_next" else -1)
		"photo_close":
			if photo.inspect: _close_photo_inspect(false)
			if photo.portrait_requested: photo.set_portrait(false)
			photo.gallery.return_focus(); stick_controls.suspend()
		"photo_zoom_in", "photo_zoom_out":
			if photo.geometry != Geometry.Geometry.FLAT and not photo.gallery.overview(): _toggle_photo_inspect(hand)
			else: photo.zoom_picture((1 if id == "photo_zoom_in" else -1) * absf(amount) * ZOOM_SPEED * delta)
		"subtitles":
			_show_player_menu(); player_menu._activate(110)
		"passthrough_video", "passthrough_photo": _on_session_control("temporary_passthrough")
		"follow_video", "follow_photo": _on_session_control("follow")
		"grade_next", "grade_previous":
			var presets: Array = video.color_grade.PRESETS
			var index: int = presets.find(video.color_grade.preset)
			_on_playback_adjustment("grade_preset", presets[posmod(index + (1 if id == "grade_next" else -1), presets.size())]); _save_playback_adjustments()
		"temperature_up", "temperature_down":
			_on_playback_adjustment("temperature", video.color_grade.values().temperature + (100 if id == "temperature_down" else -100)); _save_playback_adjustments()
		"mute": video.toggle_mute()
		"audio_next": video.cycle_audio_track(1)
		"subtitle_next": video.cycle_subtitle_track(1)
		"eyes": video.toggle_eye_order()
		"alpha": _on_menu_action("alpha")
	if player_menu and player_menu.visible and not photo_active:
		_menu_touched_ms = Time.get_ticks_msec(); player_menu.refresh_values()

func _axis_binding(hand: String, input: String) -> Dictionary:
	var id := controller_bindings.resolve(hand, input, _controller_context())
	if id.is_empty(): return {}
	if interface_move.pending() and not _is_chord(id, hand, input): return {}
	return {"operation": "shortcut", "id": id, "hand": hand, "continuous": controller_bindings.definition(id).continuous}

func _is_chord(id: String, hand: String, input: String) -> bool:
	return controller_bindings.bindings(id).any(func(binding): return binding.hand == hand and binding.input == input and not binding.modifiers.is_empty() and binding.modifiers.all(func(mod): return controller_bindings.down[hand].has(mod)))

func _move_pose(hand: String) -> Variant:
	var controller: XRController3D = left_controller if hand == "left_hand" else right_controller
	return controller.global_transform if controller and controller.get_is_active() and controller.get_has_tracking_data() and _controller_allowed(hand) else null

func _begin_interface_move(hand: String, input: String) -> void:
	var pose: Variant = _move_pose(hand)
	var head: Variant = _head_pose()
	if pose == null or head == null: return
	if photo_active and photo.inspect:
		var detail: MeshInstance3D = photo._detail
		if detail and detail.visible and interface_move.begin(hand, input, pose, [{"node": detail, "kind": "detail", "pose": detail.global_transform, "key": "magnifier"}], detail.global_position, head):
			stick_controls.suspend()
		return
	var targets: Array = []
	var menu := _active_menu()
	var ray: Variant = _ray(hand)
	var hit: Dictionary = menu.grab_hit(ray[0], ray[1]) if menu and ray != null else {}
	var scope: String = controller_bindings.move_scope
	var move_media := scope != "panel" or menu == null
	if menu and (scope != "panel" or not hit.is_empty()):
		targets.append({"node": menu, "kind": "menu", "pose": menu.global_transform, "key": _menu_key(menu)})
	else: move_media = true
	if scope == "all":
		for other in [recent_menu, video_menu, photo_menu]:
			if other == recent_menu and _library_is_attached(): continue
			if other and other != menu:
				if not other.visible: _place_menu(other)
				targets.append({"node": other, "kind": "menu", "pose": other.global_transform, "key": _menu_key(other)})
	var surface := _viewer()
	if move_media and surface and not surface.local_uri.is_empty():
		if photo_active and photo.gallery.overview():
			targets.append({"node": photo.gallery, "kind": "gallery", "pose": photo.gallery.anchor, "key": "gallery"})
		else:
			targets.append({"node": surface, "kind": "screen" if surface.geometry == Geometry.Geometry.FLAT else "immersive", "pose": surface.global_transform * surface.flat_pose, "key": _surface_key(surface)})
	if targets.is_empty(): return
	for target in targets:
		if target.kind == "screen": target["distance_limits"] = photo.PHOTO_DISTANCE_LIMITS if photo_active else video.DISTANCE_LIMITS
		elif target.kind == "gallery": target["distance_limits"] = photo.gallery.DISTANCE_LIMITS
	var anchor: Vector3 = menu.to_global(hit.point) if not hit.is_empty() else targets[0].pose.origin
	if interface_move.begin(hand, input, pose, targets, anchor, head, view_follow.enabled): stick_controls.suspend()

func _update_interface_move() -> void:
	if interface_move.capture.is_empty(): return
	var pose: Variant = _move_pose(interface_move.capture.hand)
	var head: Variant = _head_pose()
	if pose == null or head == null or not _input_focused(): interface_move.cancel(); stick_controls.suspend(); return
	if interface_move.update(pose, head, view_follow):
		stick_controls.suspend(); _menu_touched_ms = Time.get_ticks_msec()
		if photo_active and photo.inspect:
			photo.detail_placement = interface_move.placements.get("magnifier")
			photo._update_inspect()

func _on_pointer_button(action: String, hand: String) -> void:
	if not interface_move.capture.is_empty():
		if action == "menu_button": interface_move.cancel()
		elif interface_move.capture.moved: return
	if _inspect_blocked.has(hand): return
	if hand in ["left_hand", "right_hand"]: _photo_pointer_hand = hand
	if photo_active and photo.inspect:
		if action in ["trigger_click", "by_button", "menu_button"]:
			if action == "trigger_click": _inspect_blocked[hand] = true
			_close_photo_inspect()
		elif action == "ax_button":
			_close_photo_inspect(false)
			_show_recent_menu()
		return
	if action == "menu_button":
		_toggle_player_menu()
		return
	var menu := _active_menu()
	# ax_button is A on the right controller and X on the left. Only A controls video transport.
	if not photo_active and action == "ax_button" and hand == "right_hand":
		if not video or video.local_uri.is_empty() or not video.media.accepts(video.media.session_id): return
		if not _grab.is_empty() or (menu and (menu != player_menu or not player_menu.allows_playback_sticks())): return
		video.toggle_play()
		if menu:
			_menu_touched_ms = Time.get_ticks_msec()
			player_menu.refresh_values()
		return
	if menu:
		match action:
			"trigger_click":
				# Beside the player controls a tap hides them and a drag moves the picture;
				# beside any other menu a tap simply closes it.
				if not _update_menu_pointer(hand, true):
					var ray: Variant = _ray(hand)
					# A slider owned by the other hand rejects this press; it is not a screen drag.
					if menu == player_menu:
						if ray != null and menu.ray_hit(ray[0], ray[1]).is_empty(): _begin_grab(hand)
					elif ray != null and menu.grab_hit(ray[0], ray[1]).is_empty():
						menu.dismiss()
			"by_button": menu.dismiss()
		return
	if photo_active:
		match action:
			"trigger_click":
				if photo.local_uri.is_empty(): _show_recent_menu()
				elif not _grab.is_empty(): return
				else:
					var ray: Variant = _ray(hand)
					if ray != null and photo.gallery.press_pointer(hand, ray[0], ray[1]): stick_controls.suspend()
					else: _begin_grab(hand)
			"ax_button": _show_recent_menu()
			"primary_click":
				if hand == "left_hand": photo.cycle_projection()
				else: _reset_picture()
		return
	match action:
		"trigger_click":
			if _viewer().local_uri.is_empty():
				_show_recent_menu()
			else:
				_begin_grab(hand)
		"ax_button":
			if hand == "left_hand": _show_recent_menu()
		"primary_click":
			if hand == "left_hand":
				video.cycle_projection()
			else:
				_reset_picture()

## Menus shown at launch are placed before the headset reports a pose (the camera is still at
## the floor origin): once the head is first tracked, recenter and place everything again.
var _head_placed := false

func _head_tracked() -> bool:
	var head := XRServer.get_tracker("head") as XRPositionalTracker
	if not head or not head.has_pose("default"):
		return false
	var pose := head.get_pose("default")
	return pose.has_tracking_data and pose.tracking_confidence != XRPose.XR_TRACKING_CONFIDENCE_NONE

func _on_system_recentered() -> void:
	Log.record("system_recentered")
	_recenter()

func _process(delta: float) -> void:
	if _audio_save_after > 0 and Time.get_ticks_msec() >= _audio_save_after: _save_audio_preferences()
	display.set_video_layer((video != null and not photo_active and video.video_layer_shown) or (photo != null and photo_active and photo.layer_shown))
	_update_view_follow()
	_refresh_session_controls()
	if _gallery_save_after > 0 and Time.get_ticks_msec() >= _gallery_save_after:
		_gallery_save_after = 0; _save_photo_adjustments()
	_update_hand_input(delta)
	if not _head_placed and _head_tracked():
		_head_placed = true
		if not view_follow.enabled: _recenter(false)
	if video and (_viewer().local_uri != _screen_uri or (photo_active and photo.placement_pending)):
		_screen_uri = _viewer().local_uri
		if not _screen_uri.is_empty():
			if not photo_active or photo.placement_pending: _place_screen()
			if photo_active: photo.placement_pending = false
	_update_photo_inspect()
	_update_grab()
	_update_interface_move()
	if photo_active and not _active_menu() and not photo.inspect:
		for hand in ["left_hand", "right_hand"]:
			var ray: Variant = _ray(hand)
			photo.gallery.update_pointer(hand, ray[0] if ray != null else Vector3.ZERO, ray[1] if ray != null else Vector3.ZERO, ray != null)
	if photo:
		var targeted: bool = photo_active and not _active_menu() and not photo.inspect and (photo.gallery.hover.values().has(photo.index) or photo.gallery.focus >= 0)
		var held: bool = targeted and (not photo_hands.owners.is_empty() or not _grab.is_empty())
		photo.set_target_feedback(2 if held else (1 if targeted else 0))
	var right := _stick(right_controller)
	var left := _stick(left_controller)
	_update_corner_hover()
	_update_flat_grab_stick(left, right, delta)
	_process_sticks(left, right, delta)

func _process_sticks(left: Vector2, right: Vector2, delta: float) -> void:
	var menu := _active_menu()
	if menu:
		_update_menu_pointer("left_hand")
		_update_menu_pointer("right_hand")
	if not interface_move.capture.is_empty() and _input_focused():
		var held := left if interface_move.capture.hand == "left_hand" else right
		var chord_pending: bool = interface_move.pending() and controller_bindings.down[interface_move.capture.hand].has("trigger_click")
		if not chord_pending and interface_move.adjust_distance(held, delta):
			_update_interface_move()
			for target in interface_move.capture.get("targets", []):
				if target.kind == "screen" and is_instance_valid(target.node): target.node.set_screen_distance((target.node.global_transform * target.node.flat_pose).origin.distance_to(_eye()))
			if menu and not interface_move.capture.is_empty(): _update_menu_pointer(interface_move.capture.hand)
		if not chord_pending: stick_controls.suspend(); return
	if not interface_move.capture.is_empty() and interface_move.capture.moved:
		stick_controls.suspend(); return
	if photo_active and photo.gallery.has_capture():
		stick_controls.suspend(); return
	if photo_active and photo.inspect:
		stick_controls.suspend()
		return
	if not _input_focused():
		stick_controls.suspend()
		return
	if photo_active and photo.geometry == Geometry.Geometry.FLAT and not photo_hands.owners.is_empty():
		stick_controls.suspend()
		return
	if menu and (menu != player_menu or photo_active or not player_menu.allows_playback_sticks()):
		stick_controls.suspend()
		# Either stick scrolls a list, never selects or controls playback at the same time.
		if menu.has_method("stick_scroll_horizontal"):
			menu.stick_scroll_horizontal(left.x if absf(left.x) > absf(right.x) else right.x, delta)
		if menu.has_method("stick_scroll") and (menu != player_menu or not player_menu.has_pointer_capture()):
			menu.stick_scroll(left.y if absf(left.y) > absf(right.y) else right.y, delta)
		_update_controls_visibility(menu)
		return
	var actions := stick_controls.poll(left, right, video != null and (photo_active or _viewer().geometry != Geometry.Geometry.FLAT)) if controller_bindings.overrides.is_empty() and not interface_move.pending() else stick_controls.poll_mapped(left, right, _axis_binding)
	if not _grab.is_empty():
		# Holding the picture: only zoom; other stick shortcuts wait for the stick to recenter.
		actions = actions.filter(func(action): return action.operation == "zoom")
	_apply_stick_actions(actions, delta)
	if menu == player_menu and menu != null:
		if not actions.is_empty():
			_menu_touched_ms = Time.get_ticks_msec()
			player_menu.refresh_values()
		_update_controls_visibility(menu)

func _update_controls_visibility(menu: Node3D) -> void:
	if menu != player_menu or menu == null or not menu.visible: return
	if player_menu.has_expanded_library(): return
	var now := Time.get_ticks_msec()
	if menu.has_pointer_capture() or menu._hover.values().any(func(target): return int(target) != menu.NONE):
		_menu_touched_ms = now
		return
	# Keep popups, sliders and pending seeks visible; use media state, not the seek queue's state.
	if menu.section != 0 or menu._mode_open or not menu._adjustment.is_empty() or menu._volume_open or menu._depth_open: return
	if photo_active and photo_menu._layout_open: return
	if photo_active:
		if photo_menu._gallery_open or photo.loading: return
	else:
		if not menu.choices.opened.is_empty() or menu._subtitle_open or menu.bookmarks.opened or not video.requested_play or video.media.state != "playing" \
			or video.control.pending or video.control.in_flight > 0 or not video.loading_caption().is_empty(): return
	if now - _menu_touched_ms > CONTROLS_HIDE_MS: menu.dismiss()

func _stick(controller: XRController3D) -> Vector2:
	return controller.get_vector2("primary") if controller and controller.get_is_active() and _controller_allowed(str(controller.tracker)) else Vector2.ZERO

func _hand_tracker(hand: String) -> XRHandTracker:
	return XRServer.get_tracker("/user/hand_tracker/" + ("left" if hand == "left_hand" else "right")) as XRHandTracker

func _hand_action_tracker(hand: String) -> XRPositionalTracker:
	return XRServer.get_tracker(hand) as XRPositionalTracker

func _meta_aim_tracker(hand: String) -> XRPositionalTracker:
	return XRServer.get_tracker("/user/fbhandaim/" + ("left" if hand == "left_hand" else "right")) as XRPositionalTracker

func _input_focused() -> bool:
	return display.preview or display.session_state == "session_focussed"

func _controller_allowed(hand: String) -> bool:
	if not _input_focused(): return false
	# Query current data too: XR input signals may arrive before our process callback.
	return not HandPointer.is_optical(_hand_tracker(hand)) and not HandPointer.is_hand_profile(_hand_action_tracker(hand)) \
		and not (hand_pointers.has(hand) and hand_pointers[hand].source == "hand")

func _controller_ray(hand: String) -> Variant:
	var controller := left_controller if hand == "left_hand" else right_controller
	if not controller or not controller.get_is_active() or not controller.get_has_tracking_data(): return null
	var pose := controller.get_pose()
	if not pose or pose.tracking_confidence == XRPose.XR_TRACKING_CONFIDENCE_NONE: return null
	return [controller.global_position, -controller.global_basis.z]

func _update_hand_input(delta: float) -> void:
	if input_visuals: input_visuals.update_visibility(_input_focused() and _head_tracked())
	var inputs := {}
	var wave_enabled: bool = photo_active and photo.gallery.mode in [2, 3] and photo.gallery.focus < 0 and not photo.portrait_requested and not _active_menu() and _input_focused()
	for hand in hand_pointers:
		var sample := {}
		var point: Variant = null
		var palm := {}
		if _input_focused():
			var tracker := _hand_tracker(hand)
			if HandPointer.is_optical(tracker) and xr_camera and xr_origin and _head_tracked():
				sample = HandPointer.sample(tracker, hand, xr_camera.global_transform,
					xr_origin.global_transform * XRServer.get_reference_frame(), XRServer.world_scale,
					_meta_aim_tracker(hand), _hand_action_tracker(hand))
				point = HandPointer.pinch_position(tracker, xr_origin.global_transform * XRServer.get_reference_frame(), XRServer.world_scale)
				if wave_enabled:
					palm = HandPointer.sweep_sample(tracker, xr_camera.global_transform,
						xr_origin.global_transform * XRServer.get_reference_frame(), XRServer.world_scale,
						_meta_aim_tracker(hand), _hand_action_tracker(hand))
			elif HandPointer.is_hand_profile(_hand_action_tracker(hand)):
				# Action aim/select is independent of the optional hand-joint stream.
				# Runtimes may also expose controllers through a hand interaction profile.
				if xr_origin:
					sample = HandPointer.runtime_sample(_hand_action_tracker(hand),
						xr_origin.global_transform * XRServer.get_reference_frame(), XRServer.world_scale, false)
			elif not HandPointer.is_optical(tracker):
				var ray: Variant = _controller_ray(hand)
				if ray != null: sample = {"source": "controller", "ray": ray}
		var event: Dictionary = hand_pointers[hand].update(sample, delta)
		if event.cancelled: _cancel_pointer(hand)
		if event.menu and hand == "left_hand": _on_pointer_button("menu_button", hand)
		var pointer: RefCounted = hand_pointers[hand]
		inputs[hand] = event.merged({"source": pointer.source, "tracked": pointer.ray != null,
			"down": pointer.down, "position": point, "palm": palm})
		if hand_marks.has(hand):
			var mark: MeshInstance3D = hand_marks[hand]
			mark.visible = pointer.source == "hand" and pointer.ray != null and not _active_menu() and not photo_active
			if mark.visible:
				mark.global_position = pointer.ray[0]
				mark.scale = Vector3.ONE * XRServer.world_scale * (0.65 if pointer.down else 1.0)
	_dispatch_hand_input(inputs, delta)

func _is_photo_hand(hand: String) -> bool:
	return photo_active and photo != null and photo.geometry == Geometry.Geometry.FLAT \
		and hand_pointers.has(hand) and hand_pointers[hand].source == "hand"

func _dispatch_hand_input(inputs: Dictionary, _delta: float = 1.0 / 72.0) -> void:
	if not interface_move.capture.is_empty(): return
	if photo_active:
		inputs = inputs.duplicate(true)
		var overview_enabled: bool = (photo.gallery.overview() or (photo.gallery.focus >= 0 and photo.geometry == 0 and photo.panel.visible)) and not photo.inspect and not _active_menu() and _input_focused() and photo_hands.owners.is_empty()
		var zoom: Dictionary = photo.gallery.hand_zoom(inputs, overview_enabled)
		for hand in zoom.consumed: inputs.erase(hand)
		if not zoom.consumed.is_empty(): stick_controls.suspend(); _grab = {}
		if zoom.finished: _save_photo_adjustments()
		var wave_enabled: bool = photo.gallery.overview() and overview_enabled and photo.gallery._swap_phase == 0
		var head := xr_camera.global_transform if xr_camera else Transform3D.IDENTITY
		var waves: Array = memory_swipe.update(inputs, wave_enabled, photo.gallery.has_capture() or inputs.values().any(func(input): return input.get("down", false)), head, XRServer.world_scale, _delta)
		for detail in memory_swipe.diagnostics: Log.record("memory_wave", detail)
		memory_swipe.diagnostics.clear()
		if not waves.is_empty():
			if photo.gallery.change_batch(int(waves[0].direction)): Log.record("photo_batch", {"input": "wave", "hand": waves[0].hand, "layout": photo.gallery.mode})
	if photo_active and photo.gallery.mode != 0 and not photo.inspect and not _active_menu() and _input_focused() and photo_hands.owners.is_empty():
		inputs = inputs.duplicate(true)
		for hand in inputs.keys():
			if inputs[hand].get("source") != "hand": continue
			var ray: Variant = _ray(hand)
			var reserved: bool = photo.gallery.capture.get("hand", "") == hand
			var hit: Dictionary = photo.gallery.ray_hit(ray[0], ray[1]) if ray != null else {}
			if inputs[hand].get("pressed", false) and not hit.is_empty() and (photo.gallery.cards.has(int(hit.index)) or int(hit.index) == photo.gallery.focus):
				photo_hands.cancel(); _on_pointer_button("trigger_click", hand); reserved = true
			if reserved:
				if inputs[hand].get("released", false): _on_pointer_release("trigger_click", hand)
				inputs.erase(hand)
	var flat_photo: bool = photo_active and photo != null and photo.geometry == Geometry.Geometry.FLAT
	var inspecting: bool = photo_active and photo != null and photo.inspect
	if inspecting:
		for hand in inputs:
			if inputs[hand].get("source") == "hand" and inputs[hand].get("pressed", false):
				for side in inputs:
					if inputs[side].get("down", false) or inputs[side].get("pressed", false): _inspect_blocked[side] = true
				_close_photo_inspect()
				break
	var enabled: bool = flat_photo and (photo.panel.visible or photo.placeholder_visible()) and _input_focused() and not _active_menu() and _grab.is_empty() \
		and not inspecting and not photo.inspect and _inspect_blocked.is_empty()
	var pose := xr_camera.global_basis if xr_camera else Basis.IDENTITY
	var result: Dictionary = photo_hands.update(inputs, enabled,
		photo.screen_scale if flat_photo else 1.0,
		pose, XRServer.world_scale, photo._serial if photo else -1)
	for action in result.actions:
		match action.operation:
			"tap": _show_player_menu()
			"navigate":
				var accepted: bool = photo.navigate(int(action.direction))
				if action.has("hand"): Log.record("photo_pinch_navigation", {"hand":action.hand, "direction":action.direction, "accepted":accepted})
			"zoom":
				photo.finish_transition(); photo.set_hand_scale(float(action.value))
			"finish":
				_save_screen()
	if flat_photo and not result.actions.any(func(action): return action.operation == "navigate"):
		photo.preview_navigation(float(result.get("preview", 0.0)))
	for hand in inputs:
		if _inspect_blocked.has(hand):
			if inputs[hand].get("released", false) or inputs[hand].get("cancelled", false) or not inputs[hand].get("tracked", false) or not inputs[hand].get("down", false):
				_inspect_blocked.erase(hand)
			continue
		if hand in result.consumed: continue
		if inputs[hand].get("pressed", false): _on_pointer_button("trigger_click", hand)
		if inputs[hand].get("released", false): _on_pointer_release("trigger_click", hand)

func _cancel_pointer(hand: String) -> void:
	controller_bindings.cancel_hand(hand)
	if not interface_move.capture.is_empty() and interface_move.capture.hand == hand: interface_move.cancel()
	if photo: photo.gallery.cancel_pointer(hand)
	_inspect_blocked.erase(hand)
	if not _grab.is_empty() and _grab.hand == hand:
		if _grab.moved and not _grab.has("inspect") and _viewer().geometry == Geometry.Geometry.FLAT: _save_screen()
		_grab = {}
		_viewer().set_corner_hover(-1)
	# Cancellation never becomes a tap, row selection, or fling.
	for menu in [recent_menu, video_menu, photo_menu]:
		if is_instance_valid(menu) and menu.has_method("cancel_pointer"): menu.cancel_pointer(hand)

func _on_input_session_changed() -> void:
	if _input_focused(): return
	controller_bindings.reset_inputs(); interface_move.cancel(); stick_controls.suspend()
	photo_hands.cancel()
	photo_swipe.cancel(); memory_swipe.cancel()
	for hand in hand_pointers:
		hand_pointers[hand].update({}, 0)
		_cancel_pointer(hand)
		if hand_marks.has(hand): hand_marks[hand].visible = false

func _hand_input_report() -> Dictionary:
	var report := {}
	for hand in hand_pointers:
		var pointer: RefCounted = hand_pointers[hand]
		var action := _hand_action_tracker(hand)
		var joints := _hand_tracker(hand)
		report[hand] = {"source": pointer.source, "provider": pointer.provider, "tracked": pointer.ray != null, "pinching": pointer.down,
			"profile": str(action.get_tracker_profile()) if action else "",
			"action_aim_tracked": _input_pose_tracked(action, "aim"), "action_grip_tracked": _input_pose_tracked(action, "grip"),
			"joint_tracking": joints != null and joints.has_tracking_data,
			"joint_source": int(joints.hand_tracking_source) if joints else -1}
	return report

static func _input_pose_tracked(tracker: XRPositionalTracker, pose_name: String) -> bool:
	if tracker == null or not tracker.has_pose(pose_name): return false
	var pose := tracker.get_pose(pose_name)
	return pose.has_tracking_data and pose.tracking_confidence != XRPose.XR_TRACKING_CONFIDENCE_NONE

# --- dragging the picture -------------------------------------------------------------------

const GRAB_START := 0.035   # radians the ray turns before a trigger press becomes a drag
const MOUSE_TURN := 0.004   # radians per pixel in the desktop preview
const ZOOM_SPEED := 0.6     # sphere radii per second at full deflection
const PUSH_SPEED := 1.5     # metres per second the held flat screen moves at full deflection
const STICK_DEADZONE := 0.2
## Trigger held outside the menus: hand, start/last ray angles (yaw, pitch), moved; a press on a
## flat screen corner adds resize = {corner, start_length, start_scale}.
var _grab := {}

func _update_flat_grab_stick(left: Vector2, right: Vector2, delta: float) -> void:
	if not _input_focused() or _active_menu() or not interface_move.capture.is_empty() or _grab.is_empty() or _grab.has("resize") or _grab.has("inspect") or _viewer().geometry != Geometry.Geometry.FLAT:
		return
	var held := left if _grab.hand == "left_hand" else right
	if not held.is_finite() or not is_finite(delta) or delta <= 0 or absf(held.y) <= STICK_DEADZONE or absf(held.x) >= absf(held.y): return
	var amount := signf(held.y) * (absf(held.y) - STICK_DEADZONE) / (1.0 - STICK_DEADZONE) * delta
	_grab.moved = true
	_push_screen(amount * PUSH_SPEED)
	stick_controls.suspend()

func _eye() -> Vector3:
	if is_instance_valid(_viewer().view_camera) and _viewer().view_camera.is_inside_tree():
		return _viewer().view_camera.global_position
	return Vector3(0, 1.6, 0)

func _ray(hand: String) -> Variant:
	if not _input_focused(): return null
	if hand_pointers.has(hand) and hand_pointers[hand].source == "hand": return hand_pointers[hand].ray
	if HandPointer.is_optical(_hand_tracker(hand)): return null
	return _controller_ray(hand)

## A ray near a flat screen corner shows its bracket: pressing there resizes.
func _update_corner_hover() -> void:
	if photo_active and photo.gallery.overview():
		photo.set_corner_hover(-1); return
	if not video or not _viewer().has_method("corner_at"):
		return
	var corner := -1
	if _grab.has("resize"):
		corner = int(_grab.resize.corner)
	elif _grab.is_empty() and not recent_menu.visible and not _viewer().local_uri.is_empty() and not (photo_active and photo.inspect):
		for hand in ["right_hand", "left_hand"]:
			if _is_photo_hand(hand): continue
			var ray: Variant = _ray(hand)
			if ray != null and not (player_menu.visible and player_menu._hover.get(hand, -1) != -1):
				corner = _viewer().corner_at(ray[0], ray[1])
				if corner >= 0:
					break
	_viewer().set_corner_hover(corner)

func _begin_grab(hand: String) -> void:
	if not _grab.is_empty() or (photo_active and photo.inspect): return
	if view_follow.enabled and _head_pose() == null: return
	var ray: Variant = _ray(hand)
	if ray == null:
		if player_menu.visible:
			player_menu.dismiss()
		return
	var angles := _ray_angles(ray[1])
	_grab = {"hand": hand, "start": angles, "last": angles, "moved": false,
		"start_direction": ray[1], "last_direction": ray[1]}
	if _is_photo_hand(hand) or (photo_active and photo.gallery.overview()):
		_grab["tap_only"] = true
		return
	var corner: int = _viewer().corner_at(ray[0], ray[1])
	var point: Variant = _viewer().screen_point(ray[0], ray[1]) if corner >= 0 else null
	if point != null and Vector2(point.x, point.y).length() > 0.05:
		_grab["resize"] = {"corner": corner, "start_length": Vector2(point.x, point.y).length(), "start_scale": _viewer().screen_scale}
	# A deliberate screen press leaves the controls before sticks may affect playback.
	# Remember this on release so a tap does not immediately reopen the controls.
	if not photo_active and _viewer().geometry == Geometry.Geometry.FLAT and _viewer().panel.visible and player_menu.visible:
		if point == null: point = _viewer().screen_point(ray[0], ray[1])
		if point != null and (corner >= 0 or (absf(point.x) <= _viewer()._flat.size.x / 2 and absf(point.y) <= _viewer()._flat.size.y / 2)):
			_grab["hid_menu"] = true
			player_menu.dismiss()

func _update_grab() -> void:
	if _grab.is_empty():
		return
	if view_follow.enabled and _head_pose() == null:
		_grab.clear()
		return
	if _grab.get("tap_only", false): return
	var ray: Variant = _ray(_grab.hand)
	if ray == null \
		or not video or _viewer().local_uri.is_empty() or recent_menu.visible:
		_grab = {}
		return
	if _grab.has("inspect"):
		photo.inspect_ray(ray[0], ray[1], true)
		return
	var angles := _ray_angles(ray[1])
	var head: Variant = _head_pose()
	var local_drag: bool = view_follow.enabled and _flat_followable(_viewer()) and head != null
	if local_drag:
		angles = _ray_angles(head.basis.inverse() * ray[1])
	if not _grab.moved:
		var start_angles: Vector2 = _ray_angles(head.basis.inverse() * _grab.start_direction) if local_drag else _grab.start
		var turned: Vector2 = angles - start_angles
		turned.x = wrapf(turned.x, -PI, PI)
		if turned.length() < GRAB_START:
			return
		_grab.moved = true
	if _grab.has("resize"):
		# The corner follows the ray: the screen grows or shrinks about its centre.
		var point: Variant = _viewer().screen_point(ray[0], ray[1])
		if point != null:
			_viewer().set_screen_scale(float(_grab.resize.start_scale) * Vector2(point.x, point.y).length() / float(_grab.resize.start_length))
		return
	var last_angles: Vector2 = _ray_angles(head.basis.inverse() * _grab.last_direction) if local_drag else _grab.last
	var step: Vector2 = angles - last_angles
	_grab.last = angles
	_grab.last_direction = ray[1]
	_turn_picture(wrapf(step.x, -PI, PI), step.y)

## Yaw (positive left) and pitch (positive up) of a direction.
static func _ray_angles(direction: Vector3) -> Vector2:
	var unit := direction.normalized()
	return Vector2(atan2(-unit.x, -unit.z), asin(clampf(unit.y, -1.0, 1.0)))

## The picture follows the pointer: immersive views turn, the flat screen moves around the head
## at its distance and keeps facing the eyes.
func _turn_picture(yaw: float, pitch: float) -> void:
	if photo_active and photo.inspect: return
	if view_follow.enabled and _head_pose() == null: return
	if is_zero_approx(yaw) and is_zero_approx(pitch): return
	if _viewer().geometry != Geometry.Geometry.FLAT:
		_viewer().turn_view(yaw, pitch)
		return
	var head: Variant = _head_pose()
	if view_follow.enabled and _flat_followable(_viewer()) and head != null:
		var local: Transform3D = head.affine_inverse() * (_viewer().global_transform * _viewer().flat_pose)
		var offset := local.origin
		if offset.length() < 0.1: return
		var angles := _ray_angles(offset) + Vector2(yaw, pitch)
		var direction := (Basis(Vector3.UP, angles.x) * Basis(Vector3.RIGHT, clampf(angles.y, -1.5, 1.5))) * Vector3.FORWARD
		local.basis = Basis(Quaternion(offset.normalized(), direction)) * local.basis
		local.origin = direction * offset.length()
		_viewer().set_flat_world_pose(head * local)
		_capture_follow_screen(_viewer(), head)
		return
	var eye := _eye()
	var offset: Vector3 = (_viewer().global_transform * _viewer().flat_pose).origin - eye
	var distance := offset.length()
	if distance < 0.1:
		return
	var angles := _ray_angles(offset) + Vector2(yaw, pitch)
	var facing := Basis(Vector3.UP, angles.x) * Basis(Vector3.RIGHT, clampf(angles.y, -1.3, 1.3))
	var pose := Transform3D(facing, eye + facing * Vector3(0, 0, -distance))
	if photo_active:
		photo.set_flat_world_pose(pose)
	else:
		_viewer().flat_pose = _viewer().global_transform.affine_inverse() * pose
		_viewer()._apply_geometry()
	_capture_follow_screen(_viewer(), head)

## The flat screen nearer (negative) or farther along the line from the eyes, still facing them.
func _push_screen(amount: float) -> void:
	if view_follow.enabled and _head_pose() == null: return
	var eye := _eye()
	var world: Transform3D = _viewer().global_transform * _viewer().flat_pose
	var offset: Vector3 = world.origin - eye
	if offset.length() < 0.1:
		return
	_viewer().set_screen_distance(offset.length() + amount)
	var pose := Transform3D(world.basis, eye + offset.normalized() * _viewer().screen_distance)
	_viewer().set_flat_world_pose(pose)
	_capture_follow_screen(_viewer(), _head_pose())
	if photo_active and photo.gallery.focus >= 0:
		photo.gallery.remember_focus_pose(photo.global_transform * photo.flat_pose)

func _save_screen() -> void:
	if photo_active:
		_save_photo_adjustments()
		return
	settings.set_value("screen", "distance", video.screen_distance)
	settings.set_value("screen", "scale", video.screen_scale)
	settings.set_value("screen", "curve", video.screen_curve)
	settings.save(settings_path)

## Right stick press: the picture back at its natural size and distance (the curve stays). It stays
## where it is: only the menu's recenter button brings the screen in front of the head again.
func _reset_picture() -> void:
	_viewer().reset_view()
	_viewer().set_screen_scale(1.0)
	var offset: Vector3 = (_viewer().global_transform * _viewer().flat_pose).origin - _eye()
	var distance: float = photo.DEFAULT_DISTANCE if photo_active else video.SCREEN_DISTANCE
	if _viewer().geometry == Geometry.Geometry.FLAT and offset.length() >= 0.1:
		_push_screen(distance - offset.length())
	_viewer().set_screen_distance(distance)
	_save_screen()

func _update_menu_pointer(hand: String, pressed: bool = false) -> bool:
	var menu := _active_menu()
	if not menu or hand not in ["left_hand", "right_hand"]:
		return false
	var ray: Variant = _ray(hand)
	var tracked := ray != null
	var origin: Vector3 = ray[0] if tracked else Vector3.ZERO
	var direction: Vector3 = ray[1] if tracked else Vector3.ZERO
	if pressed:
		_menu_touched_ms = Time.get_ticks_msec()
		var handled: bool = menu.press_pointer(hand, origin, direction, tracked)
		if menu != player_menu or photo_active or not player_menu.allows_playback_sticks():
			stick_controls.suspend()
		return handled
	if not interface_move.capture.is_empty():
		# Clear normal hover and child-browser rays, then draw only the owning grip's anchor.
		menu.update_pointer(hand, Vector3.ZERO, Vector3.ZERO, false)
		if hand == interface_move.capture.hand:
			menu.update_move_pointer(hand, origin, interface_move.capture.anchor, tracked)
		return true
	menu.update_pointer(hand, origin, direction, tracked)
	return true

const CONTROLS_HIDE_MS := 5000
var _menu_touched_ms := 0
var _video_waiting_feedback := false

func _viewer() -> Node3D:
	return photo if photo_active and photo else video

func _on_library_chosen(uri: String, title: String) -> void:
	var controls_pose: Variant = recent_menu.get_parent().global_transform if _library_is_attached() else null
	if recent_menu is LibraryMenu: recent_menu.playback_expanded = false
	var is_photo: bool = ImageInfo.is_image(uri, title) or recent_menu.is_image_uri(uri)
	var directory_context: Dictionary = recent_menu.photo_directory_context() if is_photo else {}
	recent_menu.dismiss()
	if player_menu: player_menu.dismiss()
	_grab = {}
	stick_controls.suspend()
	if is_photo:
		video.close_video()
		photo_active = true
		player_menu = photo_menu
		_photo_open_hide_controls = not (controls_pose is Transform3D) and hand_pointers.values().any(func(pointer): return pointer.source == "hand")
		photo.open_image(uri, title, recent_menu.image_queue())
		photo.start_directory(directory_context)
		_show_player_menu()
	else:
		_photo_open_hide_controls = false
		photo.close_image()
		photo_active = false
		player_menu = video_menu
		video_queue = recent_menu.video_queue()
		var metadata: Dictionary = recent_menu.server_browser.selection.duplicate(true) if uri.begins_with("medialib://") else {}
		if not uri.begins_with("medialib://"):
			for row in recent_menu.rows:
				if str(row.get("uri", "")) == uri: metadata = row.duplicate(true); break
		recent_menu.server_browser.selection = {}
		if metadata.get("uri", "") != uri: metadata = {}
		if video.open_library(uri, title, metadata): _show_player_menu()
	if controls_pose is Transform3D:
		player_menu.global_transform = controls_pose
		var head: Variant = _head_pose()
		if head is Transform3D:
			view_follow.capture(_menu_key(player_menu), head, controls_pose)
			interface_move.placements[_menu_key(player_menu)] = InterfaceMove.menu_head(head, view_follow.enabled).affine_inverse() * controls_pose

func _on_file_renamed(old_uri: String, new_uri: String, title: String) -> void:
	video.recent_files.relocate(old_uri, new_uri, title)
	if not video.recent_files.save(): recent_menu.file_actions.rename.migration_failed = true
	video.mode_memory.relocate(old_uri, new_uri)
	if not video.mode_memory.save(): recent_menu.file_actions.rename.migration_failed = true
	video.track_memory.relocate(old_uri, new_uri)
	if not video.track_memory.save(): recent_menu.file_actions.rename.migration_failed = true
	video.subtitle_timing.relocate(old_uri, new_uri)
	if not video.subtitle_timing.save(): recent_menu.file_actions.rename.migration_failed = true
	photo.mode_memory.relocate(old_uri, new_uri)
	if not photo.mode_memory.save(): recent_menu.file_actions.rename.migration_failed = true
	if not video.bookmark_store.relocate(old_uri, new_uri, title, int(recent_menu.file_actions.target.get("size", -1))): recent_menu.file_actions.rename.migration_failed = true
	LibraryMenu.Thumbnails.relocate(old_uri, new_uri)
	for item in video_queue:
		if str(item.get("uri", "")) == old_uri: item.uri = new_uri; item.title = title; item.erase("metadata")
	_update_thumbnail_protection()

func _prepare_file_delete(uri: String) -> void:
	if video.local_uri == uri or video.local_uri.begins_with(uri.trim_suffix("/") + "/"): video.close_video()
	if photo.local_uri == uri or photo.local_uri.begins_with(uri.trim_suffix("/") + "/") or photo.queue.any(func(item): return str(item.get("uri", "")) == uri or str(item.get("uri", "")).begins_with(uri.trim_suffix("/") + "/")):
		photo.close_image(); photo_active = false
		if photo_menu: photo_menu.dismiss()
		player_menu = video_menu
	_grab = {}; stick_controls.suspend()

func _forget_deleted_file(uri: String) -> void:
	video_queue = video_queue.filter(func(item): return str(item.get("uri", "")) != uri and not str(item.get("uri", "")).begins_with(uri.trim_suffix("/") + "/"))
	# Photo preload readers must be released before removing a queued image.
	if photo.queue.any(func(item): return str(item.get("uri", "")) == uri):
		photo.close_image(); photo_active = false; player_menu = video_menu
	for entry in video.recent_files.list_recent():
		if str(entry.uri) == uri or str(entry.uri).begins_with(uri.trim_suffix("/") + "/"): video.recent_files.forget(str(entry.uri))
	video.recent_files.save()
	_update_thumbnail_protection()

func _on_storage_eject_requested(volume: Dictionary) -> void:
	_release_storage_readers(volume)
	recent_menu.finish_storage_release(str(volume.get("id", "")))

func _release_storage_readers(volume: Dictionary) -> void:
	if video and StorageVolume.contains_uri(volume,video.local_uri): video.close_video()
	video_queue = video_queue.filter(func(item): return not StorageVolume.contains_uri(volume,str(item.get("uri",""))))
	if photo and photo.release_storage(volume):
		photo_active = false
		if photo_menu: photo_menu.dismiss()
		player_menu = video_menu
	_grab = {}; stick_controls.suspend()

func _adjacent_video(direction: int) -> Dictionary:
	if photo_active or not video or direction == 0: return {}
	for index in video_queue.size():
		if str(video_queue[index].uri) != video.local_uri: continue
		var target := index + (1 if direction > 0 else -1)
		return video_queue[target] if target >= 0 and target < video_queue.size() else {}
	return {}

func _navigate_video(direction: int) -> void:
	var item := _adjacent_video(direction)
	if item.is_empty(): return
	_grab = {}
	stick_controls.suspend()
	_menu_touched_ms = Time.get_ticks_msec()
	video.open_library(str(item.uri), str(item.title), item.get("metadata", {}))
	if player_menu and player_menu.visible: player_menu.refresh()

func _on_photo_changed() -> void:
	if not photo_active: return
	var gallery_state := "%d/%s/%s" % [photo.gallery.mode, str(photo.gallery._scales), str(photo.gallery._distances)]
	if gallery_state != _gallery_saved_state:
		_gallery_saved_state = gallery_state; _gallery_save_after = Time.get_ticks_msec() + 450
	if _photo_open_hide_controls and not photo.loading and photo.panel.visible:
		_photo_open_hide_controls = false
		if photo.geometry == Geometry.Geometry.FLAT: photo_menu.dismiss()
	_update_thumbnail_protection()
	_update_background()
	if player_menu and player_menu.visible: player_menu.refresh_values()
	if calibration_board: calibration_board.visible = false

func _on_photo_adjustment(key: String, value: Variant) -> void:
	if not photo_active or not is_finite(float(value)): return
	_menu_touched_ms = Time.get_ticks_msec()
	match key:
		"gallery_scale":
			photo.gallery.set_view_scale(float(value)); photo.changed.emit()
		"gallery_distance":
			photo.gallery.set_view_distance(float(value)); photo.changed.emit()
		"screen_distance":
			if photo.geometry != Geometry.Geometry.FLAT: return
			if photo.gallery.focus >= 0: photo.gallery.set_focus_distance(float(value))
			else: _push_screen(clampf(float(value), photo.PHOTO_DISTANCE_LIMITS.x, photo.PHOTO_DISTANCE_LIMITS.y) - (photo.global_transform * photo.flat_pose).origin.distance_to(_eye()))
			photo.changed.emit()
		"screen_scale":
			if photo.geometry != Geometry.Geometry.FLAT: return
			photo.set_screen_scale(float(value))
			photo.changed.emit()
		"inspect_magnification":
			photo.set_inspect_magnification(float(value))

func _save_photo_adjustments() -> void:
	settings.set_value("photo_screen", "distance", photo.screen_distance)
	settings.set_value("photo_screen", "scale", photo.screen_scale)
	settings.set_value("photo_screen", "curve", photo._portrait_curve if photo.portrait_requested else photo.screen_curve)
	settings.set_value("photo_screen", "magnification", photo.inspect_magnification)
	photo.gallery.save_settings(settings)
	_gallery_save_after = 0
	_gallery_saved_state = "%d/%s/%s" % [photo.gallery.mode, str(photo.gallery._scales), str(photo.gallery._distances)]
	settings.save(settings_path)

func _toggle_photo_inspect(hand: String = "") -> void:
	if not photo.panel.visible or photo.portrait_requested: return
	photo.gallery.cancel_all()
	if photo.inspect:
		_close_photo_inspect()
		return
	_grab = {}
	interface_move.cancel()
	photo_hands.cancel(); photo_swipe.cancel(); memory_swipe.cancel(); stick_controls.suspend()
	_inspect_hand = hand if hand in ["left_hand", "right_hand"] else _photo_pointer_hand
	_inspect_desktop_ray = null
	photo.toggle_inspect()
	if player_menu: player_menu.dismiss()
	_update_photo_inspect()

func _close_photo_inspect(show_controls: bool = true) -> void:
	for hand in hand_pointers:
		if hand_pointers[hand].source == "hand" and hand_pointers[hand].down: _inspect_blocked[hand] = true
	_grab = {}
	interface_move.cancel()
	photo_hands.cancel(); photo_swipe.cancel(); memory_swipe.cancel(); stick_controls.suspend()
	_inspect_hand = ""; _inspect_desktop_ray = null
	photo.close_inspect()
	if show_controls: _show_player_menu()

func _update_photo_inspect() -> void:
	if not photo_active or not photo.inspect or not _input_focused() or _active_menu():
		if photo: photo.hide_inspect_pointer()
		return
	if not interface_move.capture.is_empty() and interface_move.capture.targets.any(func(target): return target.kind == "detail"):
		photo.hide_inspect_pointer()
		return
	var ray: Variant = _ray(_inspect_hand) if _inspect_hand in ["left_hand", "right_hand"] else null
	if ray == null:
		for hand in ["right_hand", "left_hand"]:
			ray = _ray(hand)
			if ray != null:
				_inspect_hand = hand
				break
	if ray == null and display.preview: ray = _inspect_desktop_ray
	if ray == null:
		photo.hide_inspect_pointer()
	else:
		photo.update_inspect_pointer(ray[0], ray[1], _inspect_hand)

func _on_photo_action(operation: String) -> void:
	if operation.begins_with("photo_wall_rows_"):
		_grab = {}; photo_hands.cancel(); photo_swipe.cancel(); memory_swipe.cancel(); stick_controls.suspend()
		photo.gallery.set_wall_rows(int(operation.trim_prefix("photo_wall_rows_")))
		photo.set_layout_mode(2); photo.changed.emit()
		_save_photo_adjustments()
		return
	if operation.begins_with("photo_layout_"):
		_grab = {}; photo_hands.cancel(); photo_swipe.cancel(); memory_swipe.cancel(); stick_controls.suspend()
		photo.set_layout_mode(int(operation.trim_prefix("photo_layout_")))
		_save_photo_adjustments()
		return
	_menu_touched_ms = Time.get_ticks_msec()
	match operation:
		"photo_shuffle":
			if photo.gallery.mode == 2: photo.gallery.change_batch(1)
			elif photo.gallery.shuffle_fragments(): Log.record("memory_shuffle", {"input": "menu"})
		"photo_portrait":
			_grab = {}; photo_hands.cancel(); memory_swipe.cancel(); stick_controls.suspend()
			photo.set_portrait(not photo.portrait_requested)
		"photo_return":
			if photo.portrait_requested: photo.set_portrait(false)
			else: photo.gallery.return_focus()
		"photo_previous":
			if photo.gallery.mode == 2 and photo.gallery.overview(): photo.gallery.change_batch(-1)
			else: photo.navigate(-1)
		"photo_next":
			if photo.gallery.mode == 2 and photo.gallery.overview(): photo.gallery.change_batch(1)
			else: photo.navigate(1)
		"photo_inspect": _toggle_photo_inspect()
		"photo_fit": _close_photo_inspect()
		"stop": _close_current_media()
		"recenter": _recenter()
		"depth":
			if photo.set_depth(not photo.depth_requested): _remember_auto_depth(photo.auto_depth)
		"depth_strength": photo.cycle_depth_strength()
		"projection_0", "projection_1", "projection_2", "projection_3": photo.set_projection(int(operation.right(1)))
		"lock_mode":
			photo.toggle_mode_lock()
		"stereo_2d": _remember_auto_depth(false); photo.set_depth(false); photo.set_stereo_layout(0)
		"stereo_sbs": photo.set_stereo_layout(1)
		"stereo_tb": photo.set_stereo_layout(2)
		"eyes": photo.toggle_eye_order()
		"fov_180", "fov_190", "fov_200", "fov_220": photo.set_fisheye_fov(int(operation.right(3)))
		"screen_curve": photo.cycle_screen_curve(); _save_screen(); photo.changed.emit()
		"photo_background":
			if background.import_photo(photo.background_source(), photo.display_name):
				_show_recent_menu()
				recent_menu.section = recent_menu.Section.SETTINGS
				recent_menu.tab = recent_menu.BACKGROUND_TAB
				recent_menu.refresh()
		_:
			if operation.begins_with("photo_index_"): photo.select_image(int(operation.trim_prefix("photo_index_")))

var _screen_uri := ""

## Preserve the full tracked pose; each surface chooses its placement frame.
func _head_pose() -> Variant:
	var camera: Camera3D = xr_camera
	if not is_instance_valid(camera) and (video or photo): camera = _viewer().view_camera
	if not is_instance_valid(camera) or not camera.is_inside_tree(): return null
	if not display.preview and not _head_tracked(): return null
	var pose := camera.global_transform
	if not pose.is_finite(): return null
	return Transform3D(pose.basis.orthonormalized(), pose.origin)

func _view_pose(distance: float, drop: float) -> Variant:
	if not is_instance_valid(_viewer().view_camera) or not _viewer().view_camera.is_inside_tree():
		return null # host tests and desktop preview without an XR camera
	var head: Transform3D = _viewer().view_camera.global_transform
	var forward: Vector3 = -head.basis.z
	forward.y = 0.0
	if forward.length() <= 0.01:
		# At the zenith/nadir the head's right axis still defines a horizontal heading.
		forward = Vector3.UP.cross(head.basis.x)
	forward = forward.normalized() if forward.length() > 0.01 else Vector3.FORWARD
	return Transform3D(Basis(Vector3.UP, atan2(-forward.x, -forward.z)), head.origin + forward * distance + Vector3(0, -drop, 0))

func _place_screen(recenter: bool = false) -> void:
	var head: Variant = _head_pose()
	var pose: Variant = _view_pose(_viewer().screen_distance, 0.0)
	if recenter and photo_active and photo.gallery.mode in [0, 1] and head != null:
		pose = head * Transform3D(Basis.IDENTITY, Vector3(0, 0, -photo.screen_distance))
	var moved: Variant = interface_move.placement(_surface_key(_viewer()), head) if not recenter and _flat_followable(_viewer()) else null
	if moved != null:
		pose = moved
		view_follow.capture(_surface_key(_viewer()), head, pose)
	elif view_follow.enabled and _flat_followable(_viewer()) and head != null:
		pose = _follow_screen_pose(_viewer(), head, recenter)
	if pose != null:
		_viewer().set_flat_world_pose(pose)
		if _viewer().geometry == Geometry.Geometry.FLAT:
			_viewer()._apply_geometry()

func _flat_followable(surface: Node3D) -> bool:
	return surface != null and surface.geometry == Geometry.Geometry.FLAT and (surface != photo or photo.gallery.mode == 0 or photo.portrait_requested)

func _surface_key(surface: Node3D) -> StringName:
	return &"photo" if surface == photo else &"video"

func _menu_key(menu: Node3D) -> StringName:
	return StringName("menu_%d" % menu.get_instance_id())

func _follow_screen_pose(surface: Node3D, head: Transform3D, recenter: bool = false) -> Transform3D:
	var key := _surface_key(surface)
	var saved: Variant = null if recenter else view_follow.pose(key, head)
	if saved != null: return saved
	var pose := head * Transform3D(Basis.IDENTITY, Vector3(0, 0, -surface.screen_distance))
	view_follow.capture(key, head, pose)
	return pose

func _capture_follow_screen(surface: Node3D, head: Variant) -> void:
	if head != null and _flat_followable(surface):
		var world: Transform3D = surface.global_transform * surface.flat_pose
		interface_move.placements[_surface_key(surface)] = head.affine_inverse() * world
		view_follow.capture(_surface_key(surface), head, world)

func _update_view_follow() -> void:
	if not view_follow.enabled: return
	var head: Variant = _head_pose()
	if head == null: return
	for menu in [recent_menu, video_menu, photo_menu]:
		if not menu or not menu.visible: continue
		if menu == recent_menu and _library_is_attached(): continue
		var pose: Variant = view_follow.pose(_menu_key(menu), head)
		if pose == null:
			view_follow.capture(_menu_key(menu), head, menu.global_transform)
		else:
			menu.global_transform = pose
	var surface := _viewer() if video or photo else null
	if surface and _flat_followable(surface) and (not surface.local_uri.is_empty() or (surface == photo and photo.loading)):
		surface.set_flat_world_pose(_follow_screen_pose(surface, head))

func _place_menu(menu: Node3D) -> void:
	if menu == recent_menu and _library_is_attached(): return
	# The player bar sits low; its popups (settings too) open above it.
	var drop := 0.45 if menu == player_menu else 0.05
	var head: Variant = _head_pose()
	var frame: Variant = InterfaceMove.menu_head(head, view_follow.enabled) if head != null else null
	var moved: Variant = interface_move.placement(_menu_key(menu), frame)
	if moved != null:
		menu.global_transform = moved; view_follow.capture(_menu_key(menu), head, moved); return
	var pose: Variant = frame * Transform3D(Basis.IDENTITY, Vector3(0, -drop, -1.4)) if frame != null else null
	if pose == null:
		menu.transform = Transform3D(Basis.IDENTITY, Vector3(0, 1.6 - drop, -1.55))
	else:
		menu.global_transform = pose
		view_follow.capture(_menu_key(menu), head, pose)

func _active_menu() -> Node3D:
	if recent_menu and recent_menu.visible:
		if _library_is_attached(): return recent_menu.get_parent() as Node3D
		return recent_menu
	if player_menu and player_menu.visible:
		return player_menu
	return null

func _library_is_compact() -> bool:
	return recent_menu is LibraryMenu and recent_menu.compact

func _library_is_attached() -> bool:
	return recent_menu is LibraryMenu and recent_menu.get_parent() is PlayerMenu

func _has_open_media() -> bool:
	if photo_active and photo: return not photo.local_uri.is_empty() or photo.loading or not photo.queue.is_empty()
	return video != null and not video.local_uri.is_empty() and video.media.state not in ["closed", "failed"]

func _toggle_player_menu() -> void:
	if photo_active and photo.inspect:
		_close_photo_inspect()
		return
	if player_menu and player_menu.visible:
		player_menu.dismiss()
	else:
		_show_player_menu()

func _show_player_menu() -> void:
	memory_swipe.cancel()
	if photo: photo.gallery.cancel_all()
	if recent_menu:
		recent_menu.dismiss()
	if player_menu and not player_menu.visible:
		_place_menu(player_menu)
		_menu_touched_ms = Time.get_ticks_msec()
		player_menu.toggle()

func _show_recent_menu() -> void:
	memory_swipe.cancel()
	if photo: photo.gallery.cancel_all()
	if photo_active and photo.inspect: _close_photo_inspect(false)
	if recent_menu is LibraryMenu and _has_open_media():
		if photo_active: _photo_open_hide_controls = false
		if player_menu.has_expanded_library():
			recent_menu.dismiss(); stick_controls.suspend(); return
		var was_compact: bool = _library_is_compact()
		_show_player_menu()
		player_menu._reset_navigation(); player_menu.refresh(); player_menu.expanded_library = recent_menu
		if recent_menu.get_parent() != player_menu: recent_menu.reparent(player_menu, false)
		recent_menu.transform = Transform3D(Basis.IDENTITY, Vector3(0, 0.72, 0))
		recent_menu.playback_expanded = false
		recent_menu.set_compact(true, not was_compact)
		recent_menu.visible = true
		recent_menu.composition_layout_changed.emit()
		stick_controls.suspend(); _menu_touched_ms = Time.get_ticks_msec()
		return
	_show_full_library()

func _show_full_library() -> void:
	var was_attached := _library_is_attached()
	if recent_menu is LibraryMenu: recent_menu.playback_expanded = false
	if player_menu:
		player_menu.dismiss()
	if was_attached:
		recent_menu.hide_for_layout()
		if recent_menu.get_parent() != self: recent_menu.reparent(self, false)
		recent_menu.set_compact(false)
		_place_menu(recent_menu)
		recent_menu.visible = true; recent_menu.refresh()
		recent_menu.composition_layout_changed.emit()
	if recent_menu and not recent_menu.visible:
		_place_menu(recent_menu)
		recent_menu.toggle()
	stick_controls.suspend()

func _toggle_library_layout() -> void:
	if not recent_menu is LibraryMenu: return
	if not _has_open_media():
		_show_full_library()
		return
	_grab = {}; interface_move.cancel(); stick_controls.suspend()
	var expand: bool = _library_is_compact()
	recent_menu.hide_for_layout()
	recent_menu.playback_controls_pose = null
	recent_menu.playback_expanded = expand
	if recent_menu.get_parent() != player_menu: recent_menu.reparent(player_menu, false)
	player_menu.visible = true; player_menu.refresh()
	recent_menu.set_compact(not expand)
	if not expand:
		recent_menu.transform = Transform3D(Basis.IDENTITY, Vector3(0, 0.72, 0))
	recent_menu.visible = true; recent_menu.refresh()
	recent_menu.composition_layout_changed.emit()
	_menu_touched_ms = Time.get_ticks_msec()

func _close_current_media() -> void:
	_grab = {}; interface_move.cancel(); stick_controls.suspend()
	if player_menu: player_menu.dismiss()
	if photo_active:
		photo.close_image(); photo_active = false; player_menu = video_menu
	else:
		video.close_video()
	_show_full_library()
	if recent_menu is LibraryMenu: recent_menu._playback_context.clear()

func _restore_subtitle_settings() -> void:
	video.subtitle_auto_load = bool(settings.get_value("subtitles", "auto_load", true))
	video.subtitle_distance = float(settings.get_value("subtitles", "distance", 5.0))
	video.subtitle_position = video.SubtitleDepth.restore_position(settings)
	video.subtitle_size = video.SubtitleStyle.size_ratio(float(settings.get_value("subtitles", "size", 1.0)))
	video.subtitle_style = video.SubtitleStyle.normalize(settings.get_value("subtitles", "style", video.SubtitleStyle.DEFAULT))
	video.subtitle_flat_position = float(settings.get_value("subtitles", "flat_position", 0.0))
	video.subtitle_direction = int(settings.get_value("subtitles", "direction", 0))

func _restore_seek_settings() -> void:
	video.seek_mode = video.SeekPolicy.normalize(settings.get_value("video", "seek_mode", video.SeekPolicy.SPEED))
	video.bookmark_seek_mode = video.SeekPolicy.bookmark_override(settings.get_value("video", "bookmark_seek_mode", video.SeekPolicy.GLOBAL))

func _library_settings() -> Dictionary:
	return {"output_width": Quality.load_output_choice(settings), "alpha_fps": _alpha_fps(),
		"show_fps": fps_overlay != null and fps_overlay.visible,
		"display_quality": display_quality, "display_quality_pending": not is_equal_approx(display.render_scale, Quality.render_scale(display_quality, low_end_gpu)),
		"sharpness": Quality.load_sharpness(settings, low_end_gpu),
		"supersampling": Quality.load_supersampling(settings),
		"history": video.history_enabled,
		"seek_mode": video.SeekPolicy.normalize(video.seek_mode),
		"subtitle_distance": video.subtitle_distance,
		"subtitle_position": video.subtitle_position,
		"subtitle_direction": video.subtitle_direction,
		"subtitle_size": video.subtitle_size * 100.0,
		"subtitle_style": video.subtitle_style,
		"background": background.choice if background else "belfast",
		"background_custom": background.has_custom() if background else false,
		"background_title": background.custom_title if background else "",
		"background_yaw": background.yaw if background else 0.0,
		"background_brightness": background.brightness if background else 1.0,
		"background_loading": background.loading if background else false,
		"background_error": background.error if background else "",
		"version": str(ProjectSettings.get_setting("application/config/version", ""))}

func _on_setting_changed(key: String, value: Variant) -> void:
	match key:
		"controller_bindings":
			controller_bindings.restore(value)
			interface_move.cancel(); _grab.clear(); stick_controls.suspend()
			settings.set_value("input", "controller_bindings", controller_bindings.snapshot()); settings.save(settings_path)
		"file_editing":
			recent_menu.file_actions.set_enabled(bool(value))
			settings.set_value("library", "file_editing", bool(value))
			settings.save(settings_path)
		"library_orders":
			settings.set_value("library", "orders", value)
			settings.save(settings_path)
		"library_view_mode":
			settings.set_value("library", "view_mode", recent_menu.Presentation.mode(value))
			settings.save(settings_path)
		"seek_mode":
			video.seek_mode = video.SeekPolicy.normalize(value)
			settings.set_value("video", "seek_mode", video.seek_mode)
			settings.save(settings_path)
		"restart_app", "quit_app":
			_finish_app(key == "restart_app")
		"display_quality":
			display_quality = clampi(int(value), Quality.AUTO, Quality.SCALES.size() - 1)
			# Apply at next startup: live OpenXR resizing fails to free GLES3 targets on Quest.
			settings.set_value("video", "display_quality", display_quality)
			settings.save(settings_path)
		"supersampling":
			settings.set_value("video", "supersampling", clampi(int(value), 0, Quality.SUPERSAMPLING_NAMES.size() - 1))
			if video.video_layer: video.video_layer.supersampling = Quality.load_supersampling(settings)
			settings.save(settings_path)
		"sharpness":
			video.sharpness = float(value)
			photo.sharpness = float(value)
			if photo._detail_material: photo._detail_material.set_shader_parameter("sharpness", photo.sharpness)
			settings.set_value("video", "sharpness", video.sharpness)
			settings.save(settings_path)
		"background":
			if background.select(str(value)): _save_background()
		"background_yaw":
			if value is bool: background.rotate_sky()
			else: background.set_yaw(float(value))
			_save_background()
		"background_brightness":
			if value is bool: background.cycle_brightness()
			else: background.set_brightness(float(value))
			_save_background()
		"alpha_fps":
			_apply_alpha_fps(value)
			settings.save(settings_path)
		"show_fps":
			if fps_overlay: fps_overlay.set_shown(bool(value))
			settings.set_value("ui", "show_fps", bool(value))
			settings.save(settings_path)
			if player_menu and player_menu.visible: player_menu.refresh()
		"output_width":
			settings.set_value("video", "output_width", int(value))
			settings.save(settings_path)
			if platform_plugin:
				platform_plugin.set_mpv_output_width(Quality.output_width(Quality.load_output_choice(settings), low_end_gpu))
		"history":
			video.history_enabled = bool(value)
			photo.history_enabled = bool(value)
			settings.set_value("library", "history", bool(value))
			settings.save(settings_path)
		"clear_history":
			video.clear_history()
		"language":
			settings.set_value("ui", "language", str(value))
			settings.save(settings_path)
			I18n.use(str(value))
			if PlatformMethods.supports(platform_plugin, "set_ui_language"):
				platform_plugin.set_ui_language(I18n.choice)
			for menu in [recent_menu, player_menu, photo_menu]:
				if menu.visible:
					menu.refresh()
		"subtitle_distance":
			video.subtitle_distance = float(value)
			settings.set_value("subtitles", "distance", video.subtitle_distance)
			settings.save(settings_path)
		"subtitle_size":
			_on_playback_adjustment(key, value)
			settings.set_value("subtitles", "size", video.subtitle_size)
			settings.save(settings_path)
		"subtitle_style":
			video.subtitle_style = video.SubtitleStyle.normalize(value)
			settings.set_value("subtitles", "style", video.subtitle_style)
			settings.save(settings_path)
		"subtitle_direction":
			video.subtitle_direction = int(value)
			settings.set_value("subtitles", "direction", video.subtitle_direction)
			settings.save(settings_path)
		"subtitle_position":
			video.subtitle_position = float(value)
			settings.set_value("subtitles", "elevation_degrees", video.subtitle_position)
			settings.save(settings_path)
	Log.record("setting_changed", {"key": key, "value": value})

func _on_menu_action(operation: String) -> void:
	if photo_active:
		_on_photo_action(operation)
		return
	if video and not video.mode_action_allowed(operation): return
	match operation:
		"open_file": _show_recent_menu()
		"seek_mode":
			_on_setting_changed("seek_mode", video.SeekPolicy.EXACT if video.seek_mode == video.SeekPolicy.SPEED else video.SeekPolicy.SPEED)
		"play": video.toggle_play()
		"alpha": video.set_alpha(not video.alpha_wanted())
		"depth":
			if video.set_depth(not video.depth_requested): _remember_auto_depth(video.auto_depth)
		"depth_strength":
			video.cycle_depth_strength()
			settings.set_value("video", "depth_strength", video.depth_strength)
			settings.save(settings_path)
		"clone_voice":
			if video.toggle_clone_voice():
				settings.set_value("audio", "prefer_clone_voice", video.prefer_clone_voice)
				settings.save(settings_path)
		"previous_video": _navigate_video(-1)
		"next_video": _navigate_video(1)
		"loop": video.toggle_loop()
		"stop": _close_current_media()
		"stereo": video.toggle_stereo()
		"eyes": video.toggle_eye_order()
		"projection": video.cycle_projection()
		"projection_0", "projection_1", "projection_2", "projection_3": video.set_projection(int(operation.right(1)))
		"stereo_2d":
			_remember_auto_depth(false)
			video.set_depth(false) # plain 2D: also ends 2D -> 3D
			video.set_stereo_layout(0)
		"lock_mode":
			video.toggle_mode_lock()
		"stereo_sbs": video.set_stereo_layout(1)
		"stereo_tb": video.set_stereo_layout(2)
		"stereo_half_sbs": video.set_stereo_layout(3)
		"stereo_half_tb": video.set_stereo_layout(4)
		"fov_180", "fov_190", "fov_200", "fov_220": video.set_fisheye_fov(int(operation.right(3)))
		"recenter": _recenter()
		"screen_curve":
			video.cycle_screen_curve()
			_save_screen()
		"calibration": video.play_calibration_clip()
		"volume_down": video.change_volume(-10.0)
		"volume_up": video.change_volume(10.0)
		"mute": video.toggle_mute()
		"audio": video.cycle_audio_track()
		"capabilities": request_capabilities()

func _on_menu_seek(position_ms: int) -> void:
	if photo_active: return
	video.seek_absolute(position_ms)

func _on_player_setting(key: String, value: Variant) -> void:
	if photo_active: return
	match key:
		"subtitle_auto_load":
			video.set_subtitle_auto_load(bool(value))
			settings.set_value("subtitles", "auto_load", video.subtitle_auto_load)
			settings.save(settings_path)
		"subtitle_delay":
			if value is Dictionary and not video.commit_subtitle_delay(float(value.value), str(value.source_uri)):
				if is_instance_valid(player_menu): player_menu.refresh()
		"seek_mode", "subtitle_distance", "subtitle_position", "subtitle_direction", "subtitle_style": _on_setting_changed(key, value)
		"viewing_eye": video.set_viewing_eye(int(value))
		"subtitle_size", "subtitle_flat_position": _on_playback_adjustment(key, value); _save_playback_adjustments()
		"loop": video.loop_enabled = bool(value); video.changed.emit()
		"show_fps": _on_setting_changed(key, value)
		"screen_curve": video.set_screen_curve(float(value)); _save_screen(); video.changed.emit()
		"audio_track":
			if video.select_audio_track(int(value)):
				settings.set_value("audio", "prefer_clone_voice", video.prefer_clone_voice)
				settings.save(settings_path)

func _on_bookmark_mode_requested(mode: String, scope: String) -> void:
	if photo_active or scope != video.bookmark_scope() or mode not in [video.SeekPolicy.GLOBAL, video.SeekPolicy.SPEED, video.SeekPolicy.EXACT]: return
	_menu_touched_ms = Time.get_ticks_msec()
	video.bookmark_seek_mode = mode
	settings.set_value("video", "bookmark_seek_mode", mode)
	settings.save(settings_path)
	Log.record("setting_changed", {"key": "bookmark_seek_mode", "value": mode})

func _on_bookmark_request(operation: String, marker_id: String, scope: String) -> void:
	if photo_active: return
	_menu_touched_ms = Time.get_ticks_msec()
	var message: String = video.bookmark_action(operation, marker_id, scope)
	if message == "Bookmark added":
		player_menu.bookmarks.notify(I18n.t(message) + " · " + player_menu._time(int(video.bookmark_last_added.position_ms)), str(video.bookmark_last_added.id))
	elif not message.is_empty(): player_menu.bookmarks.notify(I18n.t(message))
	else: player_menu.refresh_values()

## Muting keeps the level, so unmuting (left stick) brings the sound back where it was.
func _on_menu_volume(volume: float, muted: bool) -> void:
	if photo_active: return
	video.set_audio_options(video.audio_track_id, video.audio_volume if muted else volume, muted)

func _restore_audio_preferences() -> void:
	var level := float(settings.get_value("audio", "volume", 100.0))
	video.audio_volume = clampf(level, 1.0, 100.0) if is_finite(level) and level > 0.0 else 100.0
	video.audio_muted = bool(settings.get_value("audio", "muted", false))

func _on_audio_options_changed(volume: float, muted: bool) -> void:
	if settings.get_value("audio", "volume", 100.0) == volume and settings.get_value("audio", "muted", false) == muted: return
	settings.set_value("audio", "volume", volume); settings.set_value("audio", "muted", muted)
	_audio_save_after = Time.get_ticks_msec() + 350

func _save_audio_preferences() -> void:
	_audio_save_after = 0
	settings.save(settings_path)

func _exit_tree() -> void:
	if _audio_save_after > 0: _save_audio_preferences()

func _on_depth_strength(strength: float, for_photo: bool) -> void:
	var viewer: Node3D = photo if for_photo else video
	if viewer.set_depth_strength(strength):
		settings.set_value("photo" if for_photo else "video", "depth_strength", viewer.depth_strength)
		_remember_auto_depth(viewer.auto_depth)

func _remember_auto_depth(enabled: bool) -> void:
	if video: video.auto_depth = enabled
	if photo: photo.auto_depth = enabled
	if settings.get_value("effects", "auto_3d", false) != enabled:
		settings.set_value("effects", "auto_3d", enabled)
		settings.save(settings_path)

func _on_mode_lock_changed(lock: Dictionary, media_kind: String) -> void:
	settings.set_value(media_kind, "mode_lock", lock)
	settings.save(settings_path)

func _save_depth_strength() -> void:
	# Keep dragging live without writing settings on every pointer movement.
	settings.save(settings_path)

func _menu_state() -> Dictionary:
	if not video:
		return {}
	var details: Dictionary = video.media.playback.get("details", {})
	var audio_options: Array = [{"value": -1, "label": "Auto"}]
	for track in details.get("audio_tracks", []):
		if track is Dictionary and int(track.get("id", 0)) > 0:
			var label := _audio_option_label(track)
			var option := {"value": int(track.id), "label": label, "hint": label}
			if track.get("external", false) and str(track.get("title", "")) == "Clone voice": audio_options.insert(1, option)
			else: audio_options.append(option)
	audio_options.append({"value": 0, "label": "Off"})
	var text_tracks: Array = video.subtitle_tracks()
	var result := {"has_video": not video.local_uri.is_empty() and video.media.accepts(video.media.session_id),
		"has_previous_video": not _adjacent_video(-1).is_empty(), "has_next_video": not _adjacent_video(1).is_empty(),
		"playing": video.requested_play, "playback_state": video.media.state, "loading_caption": video.loading_caption(),
		"alpha_requested": video.alpha_wanted(), "alpha_enabled": video.alpha_enabled,
		"loop": video.loop_enabled, "stereo": video.stereo_sbs, "swap_eyes": video.swap_eyes,
		"viewing_eye": video.viewing_eye, "stereo_horizontal": video.stereo_horizontal, "stereo_vertical": video.stereo_vertical,
		"top_bottom": video.stereo_sbs and video.top_bottom, "stereo_half": video.stereo_sbs and video.stereo_half, "fisheye_fov": video.fisheye_fov,
		"projection": ["Flat", "VR180", "Fisheye", "360"][video.geometry], "geometry": video.geometry, "profile": video.profile,
		"mode_lock": video.mode_lock,
		"spatial_video": video.is_spatial_video(),
		"volume": video.audio_volume, "muted": video.audio_muted,
		"audio_available": details.get("audio_tracks", []).size() > 0,
		"audio_options": audio_options, "audio_track_id": video.audio_track_id,
		"audio_tracks": details.get("audio_tracks", []).size(), "audio_track": _audio_track_name(details),
		"clone_voice": video.clone_voice_track() > 0, "clone_voice_active": video.clone_voice_active(),
		"depth_requested": video.depth_requested, "depth_enabled": video.depth_enabled, "depth_strength": video.depth_strength,
		"screen_curve": video.screen_curve, "screen_distance": video.screen_distance,
		"screen_scale": video.screen_scale * 100.0, "screen_rotation": video.screen_rotation, "playback_speed": video.playback_speed,
		"alpha_fps": _alpha_fps(), "show_fps": fps_overlay != null and fps_overlay.visible,
		"subtitle_size": video.subtitle_size * 100, "subtitle_flat_position": video.subtitle_flat_position * 100,
		"subtitle_style": video.subtitle_style,
		"subtitle_distance": video.subtitle_distance, "color_grade": video.color_grade.snapshot(),
		"subtitle_position": video.subtitle_position,
		"subtitle_direction": video.subtitle_direction,
		"grade_values": video.color_grade.values(),
		# Options that leave the compositor layer carry a warning only where the layer exists.
		"layer_available": video.video_layer != null and video.video_layer.available(),
		"grade_on_layer": video.video_layer != null and video.video_layer.color_scale_bias,
		"depth_error": str(video.media.playback.get("depth_error", "")),
		"text_subtitle_tracks": text_tracks.size(), "subtitle_options": text_tracks,
		"subtitle_track": video.subtitles.requested_track, "source_uri": video.local_uri,
		"subtitle_auto_load": video.subtitle_auto_load,
		"subtitle_delay": video.subtitle_delay,
		"title": video.display_name, "source_size": "%s x %s" % [video.media.format.get("width", "?"), video.media.format.get("height", "?")],
		"codec": details.get("codec", "Unknown codec"),
		"position_ms": video.control.display_position_ms(), "duration_ms": video.control.duration_ms,
		"xr_state": "Desktop preview" if display.preview else display.session_state,
		"capabilities_available": platform_plugin != null,
		"error": _menu_error()}
	result.merge(video.bookmarks_snapshot())
	return result

## Preserve native titles/IDs for sidecar recognition; localize their presentation only.
func _audio_option_label(track: Dictionary) -> String:
	if track.get("external", false) and str(track.get("title", "")) == "Clone voice": return I18n.t("Dubbing")
	var title := str(track.get("title", "")).replace("\n", " ").replace("\r", " ").strip_edges()
	var language := str(track.get("language", "")).replace("_", "-").to_lower().split("-")[0]
	var names := {"en": "English", "eng": "English", "zh": "Chinese", "zho": "Chinese", "chi": "Chinese",
		"ja": "Japanese", "jpn": "Japanese", "fr": "French", "fra": "French", "fre": "French",
		"de": "German", "deu": "German", "ger": "German", "es": "Spanish", "spa": "Spanish",
		"ko": "Korean", "kor": "Korean", "ru": "Russian", "rus": "Russian"}
	var language_label := I18n.t(str(names.get(language, language))) if language not in ["", "und"] else ""
	if title.is_empty(): title = I18n.t("Track %d") % int(track.get("id", 0))
	return title + (" · " + language_label if not language_label.is_empty() else "")

func _audio_track_name(details: Dictionary) -> String:
	var current := str(details.get("audio_track_id", ""))
	for track in details.get("audio_tracks", []):
		if track is Dictionary and str(track.get("id", "")) == current:
			return _audio_option_label(track)
	return current if not current.is_empty() else "Auto"

func _menu_error() -> String:
	var error: String = video.picker_error if not video.picker_error.is_empty() else video.media.error
	if error.is_empty():
		error = display.error_code
	match error:
		"PERMISSION_LOST", "LOCAL_DOCUMENT_PERMISSION_LOST": error = "File access lost. Select the video again (PERMISSION_LOST)."
		"MISSING", "LOCAL_DOCUMENT_MISSING": error = "Video no longer exists. Select another file (MISSING)."
		"TIMEOUT", "LOCAL_DOCUMENT_TIMEOUT": error = "File access timed out. Try opening again."
		"UNREADABLE": error = "Unable to read the video. Select another file."
	return I18n.t(error)

func _apply_stick_actions(actions: Array[Dictionary], delta: float = 1.0 / 72.0) -> void:
	var mapped: Array[Dictionary] = actions.filter(func(action): return action.operation == "shortcut")
	for action in mapped:
		if interface_move.pending(): interface_move.cancel()
		_execute_shortcut(action.id, action.get("hand", "right_hand"), float(action.get("amount", 1.0)), delta)
	if not mapped.is_empty(): actions = actions.filter(func(action): return action.operation != "shortcut")
	if photo_active:
		if photo.inspect: return
		for action in actions:
			if action.operation == "zoom":
				if photo.geometry != Geometry.Geometry.FLAT and not photo.gallery.overview(): _toggle_photo_inspect("left_hand" if action.get("hand") == "left" else "right_hand")
				else: photo.zoom_picture(float(action.amount) * ZOOM_SPEED * delta)
			elif action.operation == "seek" and action.get("hand", "right") == "right" and not photo.inspect: photo.navigate(int(action.direction))
		return
	for action in actions:
		match action.operation:
			"zoom": video.zoom_view(float(action.amount) * ZOOM_SPEED * delta)
			"seek": video.seek_relative(int(action.get("delta_ms", int(action.direction) * 10000)))
			"volume": video.change_volume(float(action.direction) * 10)
			"audio_track": video.cycle_audio_track(int(action.direction))
			"mute": video.toggle_mute()
			"subtitle": video.cycle_subtitle_track(int(action.direction))
			"swap_eyes": video.toggle_eye_order()

func _request_rvm_benchmark(vulkan: bool, profile: String = "256x144") -> void:
	if not platform_plugin:
		rvm_status = "Android RVM benchmark requires Quest"
		_update_status()
		return
	var id: int = platform_plugin.request_rvm_profile_benchmark(vulkan, profile)
	if id <= 0:
		rvm_status = "RVM benchmark busy or unavailable"
	else:
		last_rvm_request = id
		var profile_index := RVM_PROFILES.find(profile)
		next_rvm_case = (profile_index * 2 + (2 if vulkan else 1)) % (RVM_PROFILES.size() * 2)
		rvm_status = "RVM %s %s validation running" % [profile, "Vulkan" if vulkan else "CPU"]
	_update_status()

func _on_rvm_result(id: int, payload: String) -> void:
	if id != last_rvm_request:
		return
	var parser := JSON.new()
	if parser.parse(payload) != OK or not parser.data is Dictionary:
		rvm_status = "RVM benchmark report invalid"
		_update_status()
		return
	rvm_report = parser.data
	rvm_status = "RVM %s %s: %s" % [rvm_report.get("profile_key", rvm_report.get("requested_profile", "?")),
		rvm_report.get("backend", "native"), rvm_report.get("state", "unknown")]
	Log.record("rvm_validation_result", rvm_report)
	_save_report()

func _request_controlled_probe() -> void:
	if not platform_plugin or not video or video.local_uri.is_empty():
		controlled_status = "Select a video or calibration clip first"
		_update_status()
		return
	if controlled_request > 0:
		platform_plugin.close_controlled_video(controlled_request)
	# The probe has a video-only clock. Pause normal audio/video while validating it.
	platform_plugin.set_mpv_playing(video.media.session_id, false)
	controlled_report = {}
	controlled_request = platform_plugin.request_controlled_probe(video.local_uri, 0, video.stereo_sbs,
		"256x256" if video.stereo_sbs else "256x144")
	controlled_status = "Controlled decode probe running" if controlled_request > 0 else "Controlled decode probe unavailable"
	_update_status()

func _on_controlled_event(id: int, payload: String, kind: String) -> void:
	if id != controlled_request:
		return
	var parser := JSON.new()
	if parser.parse(payload) != OK or not parser.data is Dictionary:
		controlled_status = "Controlled probe invalid report"
		return
	controlled_report[kind] = parser.data
	if kind == "frame":
		controlled_status = "Controlled frames: %s | PTS matched | immutable slot" % parser.data.get("captured_frames", 0)
	else:
		controlled_status = "Controlled probe: %s" % parser.data.get("state", parser.data.get("code", "unknown"))
		Log.record("controlled_" + kind, parser.data)
	_update_status()

func _toggle_display() -> void:
	if photo_active:
		_on_photo_action("photo_portrait"); return
	if not video.local_uri.is_empty():
		video.set_alpha(not video.alpha_wanted())
	else:
		background.select("dark" if background.choice == "passthrough" else "passthrough")
		_save_background()
	_save_report()

func _on_video_changed() -> void:
	if photo_active: return
	var waiting: bool = not video.loading_caption().is_empty()
	if waiting and not _video_waiting_feedback and video_menu and not video_menu.visible and (not recent_menu or not recent_menu.visible):
		player_menu = video_menu
		_show_player_menu()
	_video_waiting_feedback = waiting
	_update_thumbnail_protection()
	_update_background()
	_update_status()
	if player_menu and player_menu.visible:
		player_menu.refresh_values()

func _on_video_thumbnail_ready(_uri: String) -> void:
	if recent_menu and recent_menu.visible: recent_menu.refresh()

func _on_video_playback_failed() -> void:
	if photo_active or not video_menu: return
	_grab = {}; stick_controls.suspend(); interface_move.cancel()
	player_menu = video_menu
	_show_player_menu()
	player_menu.show_playback_error()

var _thumbnail_history_sequence := -1
func _update_thumbnail_protection() -> void:
	if not video or _thumbnail_history_sequence == video.recent_files.sequence: return
	_thumbnail_history_sequence = video.recent_files.sequence
	ThumbnailCache.protect_keys(video.recent_files.list_recent().map(func(e): return str(e.uri)))

func _on_background_changed() -> void:
	_update_background()
	if recent_menu and recent_menu.visible and recent_menu.section == recent_menu.Section.SETTINGS and recent_menu.tab == recent_menu.BACKGROUND_TAB:
		recent_menu.refresh()

func _update_background() -> void:
	if not background or not display.environment: return
	var immersive := false
	var alpha := false
	if photo_active and photo:
		immersive = not photo.local_uri.is_empty() and photo.geometry != Geometry.Geometry.FLAT
		alpha = photo.portrait_requested or photo.portrait_enabled
	elif video:
		var active: bool = video.has_active_presentation()
		# A packed mask only exists once a frame shows it (alpha_enabled). Counting the file's
		# packed marker while a slow stream (PTMediaServer live) opens left bare passthrough
		# with no video for seconds before playback.
		alpha = active and (video.alpha_requested or video.alpha_enabled)
		immersive = active and video.geometry != Geometry.Geometry.FLAT
	# Alpha temporarily overrides the saved scenery. An explicit passthrough choice
	# also applies behind immersive media, including the unused half of VR180.
	var wants_passthrough: bool = alpha or temporary_passthrough or background.choice == "passthrough"
	display.set_scenery(null if immersive or wants_passthrough else background.ready_sky(), background.yaw)
	var passthrough: bool = wants_passthrough and display.supports_passthrough()
	if display.applied_passthrough != passthrough or display.requested_passthrough != passthrough:
		display.set_passthrough(passthrough)
	_refresh_session_controls()

func _connect_session_controls(menu: Node3D) -> void:
	menu.session_controls_provider = _session_controls_state
	menu.session_control_requested.connect(_on_session_control)
	menu.placement_changed.connect(_on_menu_placement_changed.bind(menu))

func _on_menu_placement_changed(menu: Node3D) -> void:
	var head: Variant = _head_pose()
	if head != null: view_follow.capture(_menu_key(menu), head, menu.global_transform)

func _person_passthrough() -> bool:
	if photo_active and photo: return photo.portrait_requested or photo.portrait_enabled
	return not photo_active and video != null and video.has_active_presentation() and (video.alpha_wanted() or video.alpha_enabled)

func _session_controls_state() -> Dictionary:
	return {"follow": view_follow.enabled,
		"passthrough_visible": background != null and background.choice != "passthrough" and display.supports_passthrough(),
		"passthrough": display.applied_passthrough, "alpha": _person_passthrough()}

func _refresh_session_controls() -> void:
	for menu in [recent_menu, video_menu, photo_menu]:
		if menu and menu.visible: menu.refresh_session_controls()

func _on_session_control(operation: String) -> void:
	_menu_touched_ms = Time.get_ticks_msec()
	if operation == "temporary_passthrough":
		if _person_passthrough() or not background or background.choice == "passthrough" or not display.supports_passthrough(): return
		var previous := temporary_passthrough
		temporary_passthrough = not previous
		_update_background()
		if temporary_passthrough and not display.applied_passthrough:
			temporary_passthrough = previous
			_update_background()
	elif operation == "follow":
		_update_view_follow()
		var was_following: bool = view_follow.enabled
		view_follow.set_enabled(not view_follow.enabled)
		interface_move.cancel()
		_grab.clear()
		photo_hands.cancel(); photo_swipe.cancel(); memory_swipe.cancel(); stick_controls.suspend()
		var head: Variant = _head_pose()
		if head != null:
			for menu in [recent_menu, video_menu, photo_menu]:
				if menu == recent_menu and _library_is_attached(): continue
				if not menu: continue
				var world: Variant = menu.global_transform if menu.visible else interface_move.placement(_menu_key(menu), InterfaceMove.menu_head(head, was_following))
				if world == null: continue
				if not view_follow.enabled: world.basis = InterfaceMove.level_menu(world.basis)
				if menu.visible: menu.global_transform = world
				interface_move.placements[_menu_key(menu)] = InterfaceMove.menu_head(head, view_follow.enabled).affine_inverse() * world
				if menu.visible: view_follow.capture(_menu_key(menu), head, world)
		if not view_follow.enabled and recent_menu is LibraryMenu and recent_menu.playback_controls_pose is Transform3D:
			recent_menu.playback_controls_pose.basis = InterfaceMove.level_menu(recent_menu.playback_controls_pose.basis)
		if view_follow.enabled and head != null:
			var surface := _viewer()
			if _flat_followable(surface) and not surface.local_uri.is_empty():
				var local: Vector3 = head.affine_inverse() * (surface.global_transform * surface.flat_pose).origin
				if local.z < -0.1 and absf(local.x / local.z) < 1.0 and absf(local.y / local.z) < 0.9:
					_capture_follow_screen(surface, head)
				else:
					_place_screen(true)
		Log.record("view_follow_changed", {"enabled": view_follow.enabled})
	_refresh_session_controls()

func _save_background() -> void:
	settings.set_value("appearance", "background", background.choice)
	settings.set_value("appearance", "background_yaw", background.yaw)
	settings.set_value("appearance", "background_brightness", background.brightness)
	settings.save(settings_path)

func _on_custom_background_saved(path: String, title: String, orientation: int) -> void:
	settings.set_value("appearance", "custom_path", path)
	settings.set_value("appearance", "custom_title", title)
	settings.set_value("appearance", "custom_orientation", orientation)
	settings.set_value("appearance", "background", background.choice)
	settings.save(settings_path)
	if background.choice == "custom" and photo_active: photo.close_image()

func _recenter(restore_defaults: bool = true) -> void:
	interface_move.cancel()
	stick_controls.suspend()
	if restore_defaults:
		for menu in [recent_menu, video_menu, photo_menu]:
			if menu:
				interface_move.placements.erase(_menu_key(menu))
				view_follow.forget(_menu_key(menu))
		if recent_menu is LibraryMenu: recent_menu.playback_controls_pose = null
	_grab.clear()
	photo_hands.cancel()
	photo_swipe.cancel(); memory_swipe.cancel()
	if not _viewer().local_uri.is_empty():
		var reset_photo: bool = restore_defaults and photo_active and photo.geometry == Geometry.Geometry.FLAT and photo.gallery.mode in [0, 1] and not photo.portrait_requested
		_place_screen(reset_photo)
		if reset_photo:
			var head: Variant = _head_pose()
			if head != null:
				var pose: Transform3D = photo.global_transform * photo.flat_pose
				interface_move.placements[&"photo"] = head.affine_inverse() * pose
				view_follow.capture(&"photo", head, pose)
		if _viewer().geometry != Geometry.Geometry.FLAT:
			_viewer().reset_view()
	if photo_active:
		photo.gallery.recenter(false)
		if photo.inspect: photo._place_detail()
	for menu in [recent_menu, player_menu]:
		if menu and menu.visible:
			_place_menu(menu)
	Log.record("recenter_requested")

func request_capabilities() -> void:
	if platform_plugin:
		last_request = platform_plugin.request_capabilities()
		Log.record("capability_probe_requested", {"request_id": last_request})

func _on_capabilities_ready(request_id: int, json_report: String) -> void:
	if request_id != last_request:
		return
	var parsed: Variant = JSON.parse_string(json_report)
	if parsed is Dictionary:
		android_report = parsed
		Log.record("capability_probe_completed", {"request_id": request_id})
	else:
		Log.record("capability_probe_invalid", {"request_id": request_id})
	_save_report()

func _on_android_lifecycle(event: String) -> void:
	Log.record("android_lifecycle", {"event": event})
	if event == "resume":
		request_capabilities()
	elif event == "pause" and video:
		video.checkpoint_playback()

func _save_report() -> void:
	var report := {
		"schema_version": 1,
		"app_version": ProjectSettings.get_setting("application/config/version"),
		"engine": Engine.get_version_info(),
		"captured_unix_seconds": Time.get_unix_time_from_system(),
		"xr": display.capabilities(),
		"menu_composition": menu_composition.snapshot() if menu_composition else {},
		"app_render_fps": Engine.get_frames_per_second(),
		"android": android_report,
		"stage": "MP04_shared_MPV_RVM_display_development",
		"video_implemented": true,
		"video_device_validation": "pending",
		"media": video.media.snapshot() if video else {},
		"video_layout": video.layout_snapshot() if video else {},
		"active_media": "image" if photo_active else "video",
		"hand_input": _hand_input_report(),
		"input_visuals": input_visuals.snapshot() if input_visuals else {},
		"background": background.choice if background else "",
		"photo": photo.snapshot() if photo else {},
		"rvm_implemented": true,
		"rvm_benchmark": rvm_report,
		"rvm_video_integrated": true,
		"mpv_rvm_device_validation": "pending",
		"controlled_decode": controlled_report,
	}
	var encoded := JSON.stringify(report, "\t")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("user://diagnostics"))
	var file := FileAccess.open("user://diagnostics/capabilities_latest.json", FileAccess.WRITE)
	if file:
		file.store_string(encoded)
	if platform_plugin:
		var saved_path: String = platform_plugin.save_capability_report(encoded)
		if saved_path.begins_with("ERROR:"):
			Log.record("capability_report_save_failed", {"reason": saved_path})
	_update_status()

func _update_status() -> void:
	if not status_label:
		return
	var mode := "Passthrough" if display.applied_passthrough else "Opaque"
	var detail := "Desktop preview" if display.preview else display.session_state
	status_label.position.y = 2.45
	status_label.visible = OS.get_cmdline_user_args().has("--show-diagnostics")
	calibration_board.visible = status_label.visible and not (video and video.panel and video.panel.visible)
	if not status_label.visible:
		return
	status_label.text = "Thru3D Media Player - MPV\n%s | %s\nLeft Menu / Tab: player menu\nPoint with a controller and press trigger to select\nX / O: open file   A / Space: play,pause   Grip: move interfaces\nLeft click / P: projection   Right click: reset view\nLeft stick: seek 20s, volume   Right stick / arrows: seek 10s   L: loop\nB / R: recenter   Trigger / T: Alpha,background\nV: fixture" % [mode, detail]
	if video:
		status_label.text += "\n%s | %s | %s | %s\n%s | RVM %s" % [video.display_name.left(42), video.media.state, "SBS" if video.stereo_sbs else "2D", video.layout_snapshot().geometry, "Alpha on" if video.alpha_enabled else ("Preparing Alpha" if video.alpha_requested else "Normal playback"), video.profile]
		status_label.text += "\n" + rvm_status
		status_label.text += "\n" + controlled_status
		status_label.text += "\n%.1f / %.1f s | %s | loop %s" % [video.control.observed_position_ms / 1000.0, video.control.duration_ms / 1000.0, video.control.snapshot().state, "on" if video.loop_enabled else "off"]
		status_label.text += "\nAudio: %s | %.0f%% | %s\nL up/down: volume | L left/right: track" % [str(video.media.playback.get("details", {}).get("audio_track_id", "none")), video.audio_volume, "muted" if video.audio_muted else "on"]
		status_label.text += "\nSubtitles: %s | C: track" % ("off" if video.subtitles.requested_track == 0 else str(video.subtitles.requested_track))
		status_label.text += "\nEyes: %s | E: swap" % ("R/L" if video.swap_eyes else "L/R")
		if not video.picker_error.is_empty():
			status_label.text += "\n" + video.picker_error
		if not video.media.error.is_empty():
			status_label.text += "\n" + video.media.error
	if not display.error_code.is_empty():
		status_label.text += "\n" + display.error_code


func _on_playback_adjustment(key: String, value: Variant) -> void:
	if key in ["stereo_horizontal", "stereo_vertical"]:
		if not photo_active: video.set_stereo_alignment(key, float(value))
		return
	elif key == "stereo_reset":
		if not photo_active: video.reset_stereo_alignment()
		return
	elif key == "screen_distance":
		if photo_active or video.geometry != Geometry.Geometry.FLAT or not is_finite(float(value)): return
		_push_screen(clampf(float(value), video.DISTANCE_LIMITS.x, video.DISTANCE_LIMITS.y) - video.panel.global_position.distance_to(_eye()))
		return
	elif key == "screen_scale":
		if photo_active or video.geometry != Geometry.Geometry.FLAT or not is_finite(float(value)): return
		video.set_screen_scale(float(value) / 100.0)
		return
	elif key == "screen_rotation":
		if photo_active: return
		video.set_screen_rotation(float(value))
		return
	elif key == "playback_speed":
		if photo_active: return
		video.set_playback_speed(float(value))
		return
	elif key == "alpha_fps":
		_apply_alpha_fps(value)
		return
	elif key == "subtitle_size":
		if not is_finite(float(value)): return
		video.subtitle_size = clampf(float(value) / 100.0, 0.5, 2.0)
	elif key == "subtitle_delay":
		if value is Dictionary and str(value.source_uri) == video.local_uri:
			video.set_subtitle_delay(float(value.value))
		return
	elif key == "subtitle_flat_position":
		if not is_finite(float(value)): return
		video.subtitle_flat_position = clampf(float(value) / 100.0, 0.0, 1.0)
	elif key == "subtitle_distance":
		video.subtitle_distance = float(value)
	elif key == "subtitle_position":
		video.subtitle_position = float(value)
	elif key == "grade_preset":
		video.color_grade.select(str(value))
	elif key == "grade_reset":
		video.color_grade.reset_custom()
	elif key == "grade_reset_page":
		video.color_grade.reset_page(int(value))
	else:
		video.color_grade.adjust(key, value)
	video.color_grade.apply(video.material)

func _save_playback_adjustments() -> void:
	video.commit_stereo_view()
	settings.set_value("screen", "distance", video.screen_distance)
	settings.set_value("screen", "scale", video.screen_scale)
	settings.set_value("subtitles", "size", video.subtitle_size)
	settings.set_value("subtitles", "style", video.subtitle_style)
	settings.set_value("subtitles", "flat_position", video.subtitle_flat_position)
	settings.set_value("subtitles", "distance", video.subtitle_distance)
	settings.set_value("subtitles", "elevation_degrees", video.subtitle_position)
	settings.set_value("subtitles", "direction", video.subtitle_direction)
	settings.set_value("video", "color_grade", video.color_grade.snapshot())
	settings.save(settings_path)

func _fps_sample() -> Dictionary:
	if not video or photo_active or not video.panel or not video.panel.visible: return {}
	return {"frames": video.presented_frames(), "target": _alpha_fps() if video.alpha_enabled else 0,
		"active": video.media.state == "playing", "path": "L" if video.video_layer_shown else "E:" + video.layer_block_reason()}

## Alpha source frame rate (RVM runs once per presented frame); MPV follows it live.
func _alpha_fps() -> int:
	return clampi(int(settings.get_value("video", "alpha_fps", ALPHA_FPS_DEFAULT)), ALPHA_FPS_LIMITS.x, ALPHA_FPS_LIMITS.y)

func _apply_alpha_fps(value: Variant) -> void:
	if not is_finite(float(value)): return
	settings.set_value("video", "alpha_fps", clampi(roundi(float(value)), ALPHA_FPS_LIMITS.x, ALPHA_FPS_LIMITS.y))
	if PlatformMethods.supports(platform_plugin, "set_mpv_alpha_fps"):
		platform_plugin.set_mpv_alpha_fps(_alpha_fps())

var seek_policy_probe_result: Dictionary = {}

func _on_display_debug_command(_id: int, payload: String) -> void:
	var command: Variant = JSON.parse_string(payload)
	if not command is Dictionary: return
	var operation := str(command.get("operation", ""))
	if operation == "seek_policy_ui" and OS.is_debug_build():
		var probe := preload("res://scripts/seek_policy_device_probe.gd").new()
		seek_policy_probe_result = probe.run(self, str(command.step), str(command.get("marker_id", "")))
		seek_policy_probe_result.request_key = str(command.request_key)
		video._write_debug_report()
	elif operation in ["display_quality", "supersampling", "sharpness"]:
		_on_setting_changed(operation, command.get("value", 0))
	elif operation in ["restart_app", "quit_app"]:
		recent_menu._activate(recent_menu.RESTART_APP if operation == "restart_app" else recent_menu.QUIT_APP)
	elif operation == "cloud_accounts":
		_show_recent_menu()
		recent_menu.section = recent_menu.Section.CLOUD
		recent_menu.account_panel.open("cloud", true)
	elif operation == "cloud_page_probe" and OS.is_debug_build():
		var probe := preload("res://scripts/cloud_page_probe.gd").new()
		add_child(probe)
		probe.start(platform_plugin)
	elif operation == "media_library_ui" and OS.is_debug_build():
		var probe := preload("res://scripts/media_server_device_probe.gd").new()
		add_child(probe)
		probe.start(self, command)
	elif operation == "display_menu":
		_show_recent_menu()
		recent_menu.section = recent_menu.Section.SETTINGS
		recent_menu.tab = recent_menu.DISPLAY_TAB
		recent_menu.refresh()
	elif operation == "player_menu":
		_show_player_menu()
	elif operation == "photo_open" and OS.is_debug_build():
		# Photo performance probes: the folder's images in name order, starting at [name].
		var folder := str(command.get("folder", ""))
		var entries: Array = []
		for name in DirAccess.get_files_at(folder):
			if ImageInfo.is_image(name, name):
				entries.append({"uri": "file://" + folder.path_join(name), "title": name, "kind": "image"})
		entries.sort_custom(func(a, b): return str(a.title) < str(b.title))
		video.close_video()
		photo_active = true
		player_menu = photo_menu
		photo.layer_enabled = bool(command.get("layer", true))
		photo.open_image("file://" + folder.path_join(str(command.get("name", ""))), str(command.get("name", "")), entries)
		# Debug layout for this session only; the saved layout changes only through the menu.
		if int(command.get("layout", -1)) >= 0: photo.set_layout_mode(int(command.layout))
	elif operation == "layer_flip" and OS.is_debug_build() and video.video_layer:
		video.video_layer.debug_image_layout = int(command.get("value", -2))
	elif operation == "layer_order" and OS.is_debug_build() and video.video_layer and video.video_layer._provider:
		video.video_layer._provider.debug_order = int(command.get("value", 0))
	elif operation == "menu_layers" and OS.is_debug_build() and menu_composition:
		menu_composition.set_active(bool(command.get("enabled", false)))
	elif operation == "menu_layer_filter" and OS.is_debug_build() and menu_composition:
		# value = supersampling + 10 * sharpening (0 off, 1 normal, 2 quality each).
		var code := int(command.get("value", 1))
		menu_composition.set_filter(code % 10, code / 10 % 10)
	elif operation == "menu_layer_holes" and OS.is_debug_build() and menu_composition:
		menu_composition.set_debug_holes(bool(command.get("enabled", true)))
	elif operation == "menu_nav" and OS.is_debug_build():
		_debug_menu_nav(str(command.get("target", "")))
	elif operation == "menu_bench" and OS.is_debug_build():
		var bench := preload("res://scripts/menu_bench_probe.gd").new()
		add_child(bench)
		bench.start(self, str(command.get("profile", "run")).validate_filename())
	elif operation == "photo_depth" and OS.is_debug_build() and photo_active:
		photo.set_depth(bool(command.get("enabled", false)))
	elif operation == "photo_step" and OS.is_debug_build() and photo_active:
		photo.navigate(1 if float(command.get("value", 1.0)) >= 0.0 else -1)

## Debug navigation for device menu probes: "section:N", "tab:N", "scroll:F", "click:TEXT" (first
## button whose labels contain TEXT) or "list" (logs the visible button labels).
func _debug_menu_nav(target: String) -> void:
	if not recent_menu.visible: _show_recent_menu()
	var parts := target.split(":", true, 1)
	var argument := parts[1] if parts.size() > 1 else ""
	var buttons: Array = []
	for button in recent_menu._buttons:
		if not is_instance_valid(button.node): continue
		var texts := PackedStringArray()
		for label in button.node.find_children("*", "Label3D", true, false):
			if not label.text.is_empty(): texts.append(label.text)
		buttons.append({"target": button.target, "text": " ".join(texts)})
	match parts[0]:
		"section": recent_menu._activate(recent_menu.NAV_BASE + int(argument))
		"tab": recent_menu._activate(recent_menu.TAB_BASE + int(argument))
		"scroll":
			recent_menu.scroll = float(argument); recent_menu.refresh()
		"click":
			for button in buttons:
				if argument in button.text:
					recent_menu._activate(button.target); break
		"list": print("MENU_NAV ", JSON.stringify(buttons.map(func(b): return b.text).filter(func(t): return not t.is_empty())))

var _finishing_app := false
func _finish_app(restart: bool) -> void:
	if photo and _gallery_save_after > 0: _save_photo_adjustments()
	if _finishing_app: return
	_finishing_app = true
	_save_playback_adjustments()
	video.close_video()
	photo.close_image()
	settings.save(settings_path)
	DiagnosticLog.record("app_restart" if restart else "app_close")
	if PlatformMethods.supports(platform_plugin, "finish_app"):
		platform_plugin.finish_app(restart)
	else:
		if restart: OS.set_restart_on_exit(true)
		get_tree().quit()

func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_PAUSED and _audio_save_after > 0: _save_audio_preferences()
	if what == NOTIFICATION_APPLICATION_PAUSED and photo and _gallery_save_after > 0:
		_save_photo_adjustments()
