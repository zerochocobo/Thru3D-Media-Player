extends SceneTree
## Choosing a VR video or an image from the files above the cinema transport leaves the hall;
## the controls must open in front of the viewer, not at the hall pose. Pass `vr` or `photo`.
const HostTest := preload("res://tests/test_player_menu.gd")
const Memory := preload("res://scripts/file_mode_memory.gd")
const Catalog := preload("res://scripts/recent_files.gd")
const XrDisplay := preload("res://scripts/xr_display.gd")
var output := ProjectSettings.globalize_path("res://../../build/output/cinema-source-switch")
var main: Node3D
var viewport: SubViewport
var failures: Array[String] = []
var checks := 0

class SupportedDisplay extends XrDisplay:
	func supports_passthrough() -> bool: return true

class InputMain extends "res://scripts/main.gd":
	func _ray(_hand: String) -> Variant: return null
	func _input_focused() -> bool: return true
	func _head_tracked() -> bool: return true

func _initialize() -> void: _run.call_deferred()

func check_facing(label: String) -> void:
	var head: Transform3D = main._head_pose()
	var menu: Node3D = main.player_menu
	var to_menu: Vector3 = menu.global_position - head.origin
	checks += 1
	if not (menu.visible and to_menu.length() < 2.5 and to_menu.normalized().dot(-head.basis.z) > .8):
		failures.append("%s: controls %.2f m away, facing %.2f" % [label, to_menu.length(), to_menu.normalized().dot(-head.basis.z)])

func _run() -> void:
	DirAccess.make_dir_recursive_absolute(output)
	var config := ConfigFile.new()
	config.set_value("appearance", "background", "dark")
	config.set_value("appearance", "cinema_seat", "N11")
	config.set_value("ui", "language", "en")
	config.save(output.path_join("settings.cfg"))
	viewport = SubViewport.new(); viewport.size = Vector2i(1280, 800); viewport.own_world_3d = true
	root.add_child(viewport)
	main = InputMain.new()
	main.settings_path = output.path_join("settings.cfg")
	main.display = SupportedDisplay.new()
	viewport.add_child(main)
	main.set_process(false)
	main.video.set_process(false); main.photo.set_process(false)
	main.report_timer.stop()
	main.video.history_enabled = false; main.photo.history_enabled = false
	main.video.mode_memory = Memory.new(output.path_join("modes.cfg"))
	main.video.recent_files = Catalog.new(output.path_join("recent.cfg"))
	main.video.platform = HostTest.Host.new()
	main.video.local_uri = "file:///cinema-integration.mp4"
	main.video.media.begin(7); main.video.media.state = "playing"
	main.video.media.format.width = 1920; main.video.media.format.height = 1080
	main.video._apply_geometry()
	main.video._waiting_first = false; main.video.requested_play = true
	main.video.control.duration_ms = 600000
	main.background.select("cinema")
	main._update_background()
	var deadline := Time.get_ticks_msec() + 20000
	while main.cinema_environment.loading and Time.get_ticks_msec() < deadline:
		await create_timer(0.01).timeout
	main._update_background(); main._sync_cinema_screen()
	var case_name: String = OS.get_cmdline_user_args()[0] if not OS.get_cmdline_user_args().is_empty() else "photo"
	main._show_player_menu(); main._show_recent_menu()
	check_facing("Cinema transport opens near the viewer")
	# The user looks somewhere else in the hall before choosing.
	main.xr_camera.rotation.y = 0.9
	if case_name == "photo":
		main._on_library_chosen("file:///probe/picture.jpg", "picture.jpg")
		check_facing("An image chosen from the cinema files opens its controls in front")
		main._update_background()
		check_facing("Image controls stay in front once the hall is hidden")
	else:
		main._on_library_chosen("file:///probe/vr180_LR.mp4", "vr180_LR.mp4")
		check_facing("A video chosen from the cinema files opens its controls in front")
		main.video.geometry = 1
		if main.video.local_uri.is_empty(): main.video.local_uri = "file:///probe/vr180_LR.mp4"
		main.video.media.begin(8); main.video.media.state = "playing"
		main._update_background()
		check_facing("VR controls stay in front once the hall is hidden")
	check(not main._cinema_scene_active(), "The chosen source leaves the cinema")
	viewport.queue_free(); await process_frame
	for failure in failures: push_error(failure)
	print("Cinema source switch (%s): %d checks, %d failures" % [case_name, checks, failures.size()])
	quit(0 if failures.is_empty() else 1)

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)
