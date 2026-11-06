extends SceneTree
const Alpha := preload("res://tests/test_alpha_background.gd")
const Fixture := preload("res://tests/test_web_browser_panel.gd")
var checks := 0
var failures: Array[String] = []
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)
func _initialize() -> void: run.call_deferred()
func run() -> void:
	var output := ProjectSettings.globalize_path("res://../../build/output/browser-effects")
	DirAccess.make_dir_recursive_absolute(output)
	var config := ConfigFile.new()
	config.set_value("appearance", "background", "dark")
	config.set_value("alpha", "keep_background", true)
	config.save(output.path_join("scene-test.cfg"))
	var main := Alpha.InputMain.new(); main.settings_path = output.path_join("scene-test.cfg")
	main.display = Alpha.SupportedDisplay.new(); root.add_child(main)
	check(main.screen_rotation_control.composition_root() == main.screen_rotation_control, "App startup registers the standalone rotation companion without interrupting composition setup")
	main.set_process(false); main.video.set_process(false); main.photo.set_process(false); main.report_timer.stop()
	var platform := Fixture.Platform.new(); main.recent_menu.attach_platform(platform)
	main.recent_menu.visible = true
	main.recent_menu._activate(main.recent_menu.NAV_BASE + main.recent_menu.Section.WEB)
	var browser: RefCounted = main.recent_menu.web_browser
	browser.open("https://example.com/person"); browser.next_poll = 0; browser.tick()
	var host: Node3D = browser.windows[1]
	host.depth.config_path = output.path_join("scene-browser-test.cfg")
	main._update_background()
	check(not main.display.applied_passthrough, "Opening a plain webpage keeps the chosen scenery")
	host._depth_changed("matte", true)
	check(main.display.applied_passthrough and main._person_passthrough(), "Actual effects signal switches the scene to camera for a person underlay")
	check(main.settings.get_value("alpha", "keep_background"), "Browser camera does not overwrite the saved player background policy")
	check(not host.depth.enabled, "Person-only mode needs no stereo toggle")
	host.toggle_focus()
	check(not main.display.applied_passthrough, "Region selection restores the source page and saved scene")
	host.toggle_focus()
	check(main.display.applied_passthrough, "Leaving selection resumes person camera passthrough")
	platform.browser.url = "about:blank"; platform.browser.start_page = true
	browser.next_poll = 0; browser.tick()
	check(not main.display.applied_passthrough, "Navigating to the browser start page releases the camera")
	platform.browser.url = "https://example.com/next"; platform.browser.start_page = false
	browser.next_poll = 0; browser.tick()
	check(main.display.applied_passthrough, "A new webpage resumes the selected person mode after navigation")
	main._on_session_control("temporary_passthrough")
	check(main.display.applied_passthrough and not main.temporary_passthrough, "Session camera control cannot interrupt active browser matting")
	host._depth_changed("matte", false)
	check(not main.display.applied_passthrough and not main._person_passthrough(), "Turning person mode off restores the chosen scenery immediately")
	main.temporary_passthrough = true; main._update_background()
	host._depth_changed("matte", true); browser.close()
	check(main.display.applied_passthrough and main.temporary_passthrough, "Closing preserves a camera request that existed before browser matting")
	main.temporary_passthrough = false; main._update_background()
	check(not main.display.applied_passthrough, "Closing releases the browser's own camera request")
	platform.free(); main.free(); await process_frame; await process_frame
	for failure in failures: push_error(failure)
	print("Browser effects background: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
