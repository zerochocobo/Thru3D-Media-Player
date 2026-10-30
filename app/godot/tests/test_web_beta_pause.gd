extends SceneTree
const Menu := preload("res://scripts/library_menu.gd")
const Fixture := preload("res://tests/test_web_browser_panel.gd")

class Platform extends Fixture.Platform:
	var accept_resolve := true
	func web_video_resolve_beta(url: String) -> int:
		if not accept_resolve: return 0
		return super.web_video_resolve_beta(url)
	func web_browser_command(value: String) -> void:
		super.web_browser_command(value)
		var command: Dictionary = JSON.parse_string(value)
		if command.action == "resume_tab" and command.get("was_playing", false):
			browser.playing = true; browser.videos[0].playing = true

var checks := 0
var failures: Array[String] = []
var platform: Platform
var menu: Node3D
var selected: Array = []
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)
func poll() -> void:
	menu.web_browser.next_poll = 0; menu.web_browser.tick()
func start(playing: bool = true) -> void:
	menu.visible = true; menu.section = Menu.Section.WEB
	platform.browser.merge({"url": "https://www.bilibili.com/video/BV11rHV6MENj/", "tab_id": 4,
		"navigation": 10, "focused_window": 1, "active": true, "playing": playing,
		"bilibili_beta_available": true, "videos": [{"id": "1", "width": 1920, "height": 1080,
			"playing": playing, "time": 20.0}]}, true)
	menu.web_browser.open(); poll()
	menu.web_browser.action(menu.web_browser.BASE + 18)
func paused() -> void:
	platform.browser.playing = false; platform.browser.videos[0].playing = false
	platform.browser.videos[0].time = 20.25
	poll()
func finish(state: String) -> void:
	platform.web_state = {"id": menu.web_video.pending, "state": state, "uri": platform.browser.url, "title": "Video"}
	menu.web_video.next_poll = 0; menu.web_video.tick(); poll()
func _initialize() -> void: call_deferred("run")
func run() -> void:
	platform = Platform.new(); menu = Menu.new(); root.add_child(menu); menu.attach_platform(platform); menu.toggle()
	menu.chosen.connect(func(uri, _title): selected.append(uri))
	start()
	check(platform.browser_commands.back().action == "pause_tab" and platform.beta_requests == 0,
		"Playing Beta sends a pause before any resolver call")
	poll(); poll()
	check(platform.beta_requests == 0 and menu.web_browser.handoff,
		"Pause token without stopped playback cannot start extraction or fail prematurely")
	var token: int = platform.browser.pause_token
	platform.browser.pause_token = token - 1; paused()
	check(platform.beta_requests == 0, "An old pause acknowledgement is ignored")
	platform.browser.pause_token = token; poll(); poll()
	check(platform.beta_requests == 1 and menu.web_video.pending > 0, "Confirmed pause starts Beta exactly once")
	check(menu.web_browser.handoff_start_ms == 20250, "Handoff uses the acknowledged pause position")
	finish("ready")
	check(selected.size() == 1 and menu.collections.selected_entry.start_ms == 20250,
		"Native playback starts only after resolution and continues from the paused position")
	check(platform.browser_commands.filter(func(c): return c.action == "pause_tab").size() == 1,
		"Beta does not issue a second pause after resolving")

	start(); paused(); finish("error")
	check(not menu.web_browser.handoff and platform.browser.playing and platform.browser_commands.back().action == "resume_tab",
		"Resolution failure restores a previously playing webpage")
	start(false); paused(); finish("error")
	check(not platform.browser.playing and not platform.browser_commands.back().was_playing,
		"Resolution failure leaves an originally paused webpage paused")
	start(); menu.web_browser.action(menu.web_browser.BASE + 18)
	check(not menu.web_browser.handoff and platform.browser_commands.back().action == "resume_tab",
		"Cancel while waiting for pause releases only this handoff")
	start(); paused(); menu.web_browser.action(menu.web_browser.BASE + 18)
	check(menu.web_video.pending == 0 and platform.browser.playing, "Cancel during extraction resumes prior playback")
	start(); var before := platform.beta_requests
	menu.web_browser.pause_started = Time.get_ticks_msec() - 5001; poll()
	check(not menu.web_browser.handoff and platform.beta_requests == before and platform.browser.playing,
		"Pause timeout restores playback without starting a resolver")
	start(); platform.browser.navigation = 11; poll()
	check(not menu.web_browser.handoff and platform.beta_requests == before and platform.browser_commands.back().navigation == 10,
		"Navigation cancels the old handoff without addressing the new document")
	platform.accept_resolve = false; start(); paused()
	check(not menu.web_browser.handoff and platform.browser.playing,
		"A resolver that cannot start restores the original playback state")
	menu.free(); platform.free(); await process_frame
	print("Web Beta pause: %d checks, %d failures" % [checks, failures.size()])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)
