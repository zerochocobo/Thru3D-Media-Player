extends SceneTree
const Menu := preload("res://scripts/library_menu.gd")
const Fixture := preload("res://tests/test_web_browser_panel.gd")

var checks := 0
var failures: Array[String] = []
var platform: Fixture.Platform
var menu: Node3D
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)
func poll() -> void:
	menu.web_browser.next_poll = 0; menu.web_browser.tick()
func press() -> void:
	platform.browser.merge({"tab_id": 4, "navigation": 10, "focused_window": 1, "playing": true}, true)
	platform.browser.videos[0].playing = true
	platform.browser.erase("pause_token")
	poll(); menu.web_browser.action(menu.web_browser.BASE + 6)
func _initialize() -> void: call_deferred("run")
func run() -> void:
	platform = Fixture.Platform.new(); menu = Menu.new(); root.add_child(menu); menu.attach_platform(platform); menu.toggle()
	menu.section = Menu.Section.WEB; menu.web_browser.open()
	press()
	check(menu.web_video.pending > 0 and not platform.browser_commands.any(func(c): return c.action == "pause_tab"),
		"Off: the legacy button resolves at once and leaves the page playing")
	menu.web_browser._cancel_handoff(); platform.browser_commands.clear()
	menu.web_browser.pause_on_handoff = true
	press()
	check(platform.browser_commands.back().action == "pause_tab" and menu.web_video.pending == 0 and menu.web_browser.handoff_waiting_pause,
		"On: the legacy button pauses the page before resolving")
	poll()
	check(menu.web_video.pending == 0, "On: resolving waits for the page to stop")
	platform.browser.playing = false; platform.browser.videos[0].playing = false; poll()
	check(menu.web_video.pending > 0 and platform.beta_requests == 0 and not menu.web_browser.handoff_beta,
		"On: once paused, the original address resolver starts, not a Beta one")
	check(menu.web_browser.handoff_start_ms == 42500, "On: playback starts from where the page was paused")
	platform.web_state = {"id": menu.web_video.pending, "state": "error", "error_code": "timeout"}
	menu.web_video.next_poll = 0; menu.web_video.tick(); poll()
	var resume: Array = platform.browser_commands.filter(func(c): return c.action == "resume_tab")
	check(resume.size() == 1 and resume[0].get("restore_paused", false) and not menu.web_browser.handoff,
		"On: a failed resolve resumes the page")
	menu.free(); platform.free(); await process_frame
	print("Web legacy pause: %d checks, %d failures" % [checks, failures.size()])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)
