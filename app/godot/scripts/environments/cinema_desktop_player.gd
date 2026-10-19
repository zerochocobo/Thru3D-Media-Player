extends "res://scripts/main.gd"
## Desktop entry using the production player, menus and fixed cinema screen.
const DesktopVideo := preload("res://scripts/environments/cinema_desktop_video.gd")
const DesktopFiles := preload("res://scripts/environments/cinema_desktop_files.gd")
var run_directory := ProjectSettings.globalize_path("res://../../build/output/cinema-desktop")
var desktop_files: Node
var _mouse_owner: Node3D
var _mouse_menu: Node3D
var _looking := false
var _desktop_focused := true

func _ready() -> void:
	if not CinemaFeature.enabled():
		get_tree().change_scene_to_file.call_deferred("res://scenes/main.tscn")
		return
	DirAccess.make_dir_recursive_absolute(run_directory)
	settings_path = run_directory.path_join("settings.cfg")
	var desktop_settings := ConfigFile.new()
	desktop_settings.load(settings_path)
	desktop_settings.set_value("appearance", "background", "cinema")
	desktop_settings.set_value("privacy", "history", "none")
	desktop_settings.set_value("effects", "auto_3d", false)
	if not desktop_settings.has_section_key("ui", "language"): desktop_settings.set_value("ui", "language", "zh")
	desktop_settings.save(settings_path)
	super._ready()
	video.history_enabled = false; photo.history_enabled = false
	desktop_files = DesktopFiles.new(); add_child(desktop_files)
	recent_menu.attach_platform(desktop_files)
	recent_menu.set_scene_overlay(true)
	if video.has_signal("file_picker_requested"): video.connect("file_picker_requested", _show_recent_menu)
	get_window().files_dropped.connect(_files_dropped)
	_boot.call_deferred()

func _create_video_display() -> Node3D:
	var result := DesktopVideo.new()
	var state_directory := run_directory.path_join("state")
	DirAccess.make_dir_recursive_absolute(state_directory)
	for field in ["mode_memory", "track_memory", "subtitle_timing", "audio_timing", "whisper_memory", "recent_files"]:
		result.get(field).directory = state_directory
	result.narration.memory.directory = state_directory
	result.bookmark_store = result.bookmark_store.get_script().new(state_directory.path_join("bookmarks"))
	result.history_enabled = false
	return result

func _boot() -> void:
	var deadline := Time.get_ticks_msec() + 30000
	while cinema_environment.loading and Time.get_ticks_msec() < deadline: await get_tree().process_frame
	_update_background()
	if not _cinema_scene_active(): return
	_look_at_cinema()
	var path := ""
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--cinema-video="): path = argument.trim_prefix("--cinema-video=")
	if path.is_empty(): path = ProjectSettings.globalize_path("res://../../build/output/cinema-prototype/cinema-motion.ogv")
	if FileAccess.file_exists(path): video.open_local(DesktopFiles.video_uri(path), path.get_file(), 0, false)
	_show_player_menu()

func _show_recent_menu() -> void:
	# Keep the existing full library at normal size, independent of the giant transport.
	if not recent_menu: return
	if recent_menu.section != recent_menu.Section.LOCAL:
		recent_menu.section = recent_menu.Section.LOCAL; recent_menu.scroll = 0
	_show_full_library()
	recent_menu._load_section(); recent_menu.refresh()
	recent_menu.apply_scene_overlay()

func _files_dropped(paths: PackedStringArray) -> void:
	for path in paths:
		if path.get_extension().to_lower() in DesktopFiles.VIDEO_EXTENSIONS:
			if recent_menu: recent_menu.dismiss()
			video.open_local(DesktopFiles.video_uri(path), path.get_file(), 0, false)
			_show_player_menu(); return

func _look_at_cinema() -> void:
	var screen: Dictionary = cinema_environment.snapshot().get("screen", {})
	if screen.is_empty(): return
	_place_menu(video_menu)
	var eye := xr_camera.global_position
	var top := Vector3(screen.position[0], screen.position[1] + float(screen.height) * 0.5, screen.position[2])
	var bottom := video_menu.to_global(Vector3(0, -0.34, 0))
	# Frame the tall screen and its fixed transport without changing projection or geometry.
	var direction := (top - eye).normalized() + (bottom - eye).normalized()
	xr_camera.look_at(eye + direction, Vector3.UP)

func _input_focused() -> bool:
	return _desktop_focused

func _process(delta: float) -> void:
	if not CinemaFeature.enabled(): return
	super._process(delta)
	var menu := _active_menu()
	if is_instance_valid(_mouse_menu) and _mouse_menu != menu and _mouse_menu != _mouse_owner: _mouse_menu.cancel_pointer("desktop")
	_mouse_menu = menu
	if menu and not _looking and _desktop_focused:
		menu.apply_scene_overlay()
		var point := get_viewport().get_mouse_position()
		var origin := xr_camera.project_ray_origin(point)
		var direction := xr_camera.project_ray_normal(point)
		menu.update_pointer("desktop", origin, direction, true)
		if not menu.ray_hit(origin, direction).is_empty() or menu.has_pointer_capture(): _menu_touched_ms = Time.get_ticks_msec()
	if is_instance_valid(_mouse_owner) and _mouse_owner != menu:
		_mouse_owner.cancel_pointer("desktop"); _mouse_owner = null
	if _cinema_interaction_owns() and not menu and _desktop_focused and not _looking:
		var point := get_viewport().get_mouse_position()
		cinema_environment.update_pointer("desktop", xr_camera.project_ray_origin(point), xr_camera.project_ray_normal(point), true)
	elif cinema_environment:
		cinema_environment.hide_pointer("desktop")

func _unhandled_input(event: InputEvent) -> void:
	if not CinemaFeature.enabled(): return
	if not _desktop_focused: return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT:
		_looking = event.pressed
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if _looking else Input.MOUSE_MODE_VISIBLE
		if is_instance_valid(_mouse_owner): _mouse_owner.cancel_pointer("desktop"); _mouse_owner = null
		get_viewport().set_input_as_handled(); return
	if event is InputEventMouseMotion and _looking:
		var pivot := xr_camera.global_position
		xr_origin.rotate_y(-event.relative.x * MOUSE_TURN)
		xr_origin.global_position += pivot - xr_camera.global_position
		xr_camera.rotation.x = clampf(xr_camera.rotation.x - event.relative.y * MOUSE_TURN, -1.3, 1.3)
		get_viewport().set_input_as_handled(); return
	var menu := _active_menu()
	if menu and event is InputEventMouseMotion:
		menu.update_pointer("desktop", xr_camera.project_ray_origin(event.position), xr_camera.project_ray_normal(event.position), true)
		_menu_touched_ms = Time.get_ticks_msec(); get_viewport().set_input_as_handled(); return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		var origin := xr_camera.project_ray_origin(event.position)
		var direction := xr_camera.project_ray_normal(event.position)
		if not event.pressed and is_instance_valid(_mouse_owner):
			var owner := _mouse_owner; _mouse_owner = null
			owner.release_pointer("desktop", origin, direction, owner == menu)
			_menu_touched_ms = Time.get_ticks_msec(); get_viewport().set_input_as_handled(); return
		if menu:
			if event.pressed:
				if menu.press_pointer("desktop", origin, direction, true): _mouse_owner = menu
				else: menu.dismiss()
			_menu_touched_ms = Time.get_ticks_msec(); get_viewport().set_input_as_handled(); return
		if cinema_environment.interaction == "watch":
			if event.pressed: _show_player_menu()
			get_viewport().set_input_as_handled(); return
	if menu and event is InputEventMouseButton and event.pressed and event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
		menu.stick_scroll(1.0 if event.button_index == MOUSE_BUTTON_WHEEL_UP else -1.0, 0.12)
		_menu_touched_ms = Time.get_ticks_msec(); get_viewport().set_input_as_handled(); return
	super._unhandled_input(event)

func _unhandled_key_input(event: InputEvent) -> void:
	if not CinemaFeature.enabled(): return
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_F2:
			_cinema_request_interaction("seat"); get_viewport().set_input_as_handled(); return
		if event.keycode == KEY_F3:
			_cinema_request_interaction("move"); get_viewport().set_input_as_handled(); return
		if event.keycode == KEY_HOME and cinema_environment.home():
			_look_at_cinema(); get_viewport().set_input_as_handled(); return
	super._unhandled_key_input(event)

func _notification(what: int) -> void:
	super._notification(what)
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		_desktop_focused = false; _looking = false; Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		if is_instance_valid(_mouse_owner): _mouse_owner.cancel_pointer("desktop"); _mouse_owner = null
		if cinema_environment: cinema_environment.suspend()
	elif what == NOTIFICATION_APPLICATION_FOCUS_IN: _desktop_focused = true
