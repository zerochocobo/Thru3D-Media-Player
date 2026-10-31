extends SceneTree
const Menu := preload("res://scripts/library_menu.gd")
const Fixture := preload("res://tests/test_web_browser_panel.gd")

class Platform extends Fixture.Platform:
	var accept_resolve := true
	var paused_playing := false
	func web_video_resolve_beta(url: String) -> int:
		if not accept_resolve: return 0
		return super.web_video_resolve_beta(url)
	func web_browser_command(value: String) -> void:
		super.web_browser_command(value)
		var command: Dictionary = JSON.parse_string(value)
		if command.action == "pause_tab": paused_playing = browser.videos.any(func(v): return v.get("playing", false))
		if command.action == "resume_tab" and (command.get("restore_paused", false) and paused_playing or command.get("was_playing", false)):
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
func beta_enabled() -> bool:
	return menu.web_browser.input_host()._buttons.any(func(button): return button.target == menu.web_browser.BASE + 18 and button.enabled)
func start(playing: bool = true, ready: bool = true) -> void:
	menu.visible = true; menu.section = Menu.Section.WEB
	platform.browser.merge({"url": "https://www.bilibili.com/video/BV11rHV6MENj/", "tab_id": 4,
		"navigation": 10, "focused_window": 1, "active": true, "playing": playing,
		"bilibili_beta_available": true, "videos": [{"id": "1", "width": 1920, "height": 1080,
			"playing": playing, "bilibili_ready": ready, "time": 20.0}]}, true)
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
	start(true, false)
	var commands := platform.browser_commands.size()
	poll(); poll()
	check(not menu.web_browser.handoff and not beta_enabled() and platform.browser_commands.size() == commands and platform.beta_requests == before,
		"Unready video disables Beta and cannot pause or start extraction")
	platform.browser.videos[0].bilibili_ready = true; poll()
	check(beta_enabled() and not menu.web_browser.handoff and platform.browser_commands.size() == commands,
		"Readiness alone redraws and enables Beta without automatically pausing")
	menu.web_browser.action(menu.web_browser.BASE + 18)
	check(menu.web_browser.handoff_waiting_pause, "A ready video starts on an explicit click")
	platform.browser.videos[0].bilibili_ready = false; poll()
	check(beta_enabled(), "Cancel stays enabled if readiness is lost during handoff")
	menu.web_browser.action(menu.web_browser.BASE + 18)
	check(not menu.web_browser.handoff and not beta_enabled(), "After cancel an unready page returns to disabled Beta")
	start(false, false)
	check(not menu.web_browser.handoff and not beta_enabled() and not platform.browser.playing,
		"Paused pages must also be ready and are never started to manufacture readiness")
	platform.browser.videos[0].bilibili_ready = true; poll()
	check(beta_enabled(), "An already paused video with both tracks is eligible")
	# The native snapshot changes between toolbar refresh and click.
	platform.browser.videos[0].bilibili_ready = false
	commands = platform.browser_commands.size()
	menu.web_browser.action(menu.web_browser.BASE + 18)
	check(not menu.web_browser.handoff and platform.browser_commands.size() == commands,
		"A stale enabled button rechecks readiness before pausing")
	platform.browser.videos[0].bilibili_ready = true; poll()
	platform.browser.navigation += 1
	menu.web_browser.action(menu.web_browser.BASE + 18)
	check(not menu.web_browser.handoff and platform.browser_commands.size() == commands,
		"A stale click cannot start on a newer navigation even when its pair is ready")
	poll(); platform.browser.url = "https://www.bilibili.com/video/BV1r9n86gENW/"
	menu.web_browser.action(menu.web_browser.BASE + 18)
	check(not menu.web_browser.handoff and platform.browser_commands.size() == commands,
		"A sidebar URL change between polls rejects the previous video's button")
	platform.accept_resolve = false; start(); paused()
	check(not menu.web_browser.handoff and platform.browser.playing,
		"A resolver that cannot start restores the original playback state")
	platform.accept_resolve = true
	start(); paused(); menu.web_browser.action(menu.web_browser.BASE + 18); poll()
	var previous_token: int = menu.web_browser.last_pause_token
	menu.web_browser.action(menu.web_browser.BASE + 18)
	check(menu.web_browser.handoff_waiting_pause and menu.web_browser.last_pause_token > previous_token,
		"Cancel and retry without reloading starts a new distinct pause")
	platform.browser.pause_confirmed = false; poll()
	check(menu.web_video.pending == 0, "Unacknowledged script hold cannot start extraction")
	platform.browser.pause_confirmed = true; poll()
	check(menu.web_video.pending > 0 and platform.browser.playing,
		"Current script acknowledgement takes precedence over a stale MediaSession playing flag")
	menu.web_browser.handoff_started_ms = Time.get_ticks_msec() - 30001; poll()
	check(not menu.web_browser.handoff and menu.web_video.pending == 0 and not menu.web_browser.handoff_error.is_empty(),
		"Timed out Beta cancels the resolver and releases its hold with a visible reason")
	platform.browser.erase("pause_confirmed")
	start(true, false)
	check(menu.web_browser.input_host()._tips[menu.web_browser.BASE + 18] == menu.web_browser.I18n.t("Video not ready"),
		"Disabled Beta explains readiness without inviting repeated failed attempts")
	start()
	check(menu.web_browser.handoff_status() == menu.web_browser.I18n.t("Pausing web video…"), "Pause acknowledgement wait is named in the toolbar")
	paused(); finish("ready")
	check(platform.browser_commands.back().action == "resume_tab" and not platform.browser_commands.back().was_playing,
		"Successful handoff releases its hold without restarting the page")
	start(); paused(); menu.web_browser.close()
	check(not menu.web_browser.handoff and menu.web_video.pending == 0 and platform.browser_commands.back().action == "resume_tab",
		"Closing the browser also releases a pending hold before hibernation")
	start(); paused(); menu.web_browser.handoff_context.was_playing = false
	menu.web_browser.action(menu.web_browser.BASE + 18)
	check(platform.browser.playing and platform.browser_commands.back().restore_paused,
		"Cancellation restores the captured pre-pause state even if UI playback state was stale")
	start(); paused()
	platform.browser.videos.append({"id": "preview", "width": 7680, "height": 4320, "time": 2.0, "playing": true})
	poll()
	check(beta_enabled() and menu.web_browser._playhead() == 20250,
		"A playing preview cannot replace the Beta primary's resume position or Cancel target")
	menu.web_browser.action(menu.web_browser.BASE + 18)
	start(true, false)
	menu.web_browser.hand = "left"
	platform.browser.videos[0].bilibili_ready = true; poll()
	check(not beta_enabled(), "Pointer capture defers the toolbar rebuild")
	menu.web_browser.hand = ""; poll()
	check(beta_enabled(), "Releasing the pointer redraws readiness even when no further native state changes")
	menu.web_browser.hand = "left"
	platform.browser.videos[0].bilibili_ready = false; poll()
	menu.web_browser.hand = ""; poll()
	check(not beta_enabled(), "Readiness loss deferred during a press also redraws after release")
	platform.browser.bilibili_beta_available = false; platform.browser.videos = []; poll()
	check(menu.web_browser.input_host()._buttons.any(func(b): return b.target == menu.web_browser.BASE + 18 and b.node.visible),
		"Known Bilibili video keeps its visible Beta action when native capability and media temporarily vanish")
	check(not beta_enabled(), "Visible Beta does not imply permission to resolve missing media")
	platform.browser.videos = [{"id":"new", "bilibili_ready":true}]; poll()
	commands = platform.browser_commands.size(); menu.web_browser.action(menu.web_browser.BASE + 18)
	check(not beta_enabled() and platform.browser_commands.size() == commands, "Stale ready media cannot bypass the native eligibility gate")
	platform.browser.bilibili_beta_available = true; poll()
	check(beta_enabled(), "Native capability recovery enables the retained action")
	platform.browser.bilibili_beta_available = false; platform.browser.url = "https://example.com/video/BV1234"; poll()
	check(not menu.web_browser.input_host()._buttons.any(func(b): return b.target == menu.web_browser.BASE + 18),
		"Leaving Bilibili does not carry its action to another site")
	check(not menu.web_browser.beta_available({"url":"https://www.bilibili.com.evil.test/video/BV1234"}), "Lookalike hosts do not acquire a Bilibili action")
	menu.web_browser.close()
	var actions_before := platform.actions.size()
	menu.web_browser.close(true)
	check(platform.actions.size() == actions_before + 1 and platform.actions.back() == "hibernate",
		"Native playback can request teardown again even after Godot marked the browser closed")
	menu.free(); platform.free(); await process_frame
	print("Web Beta pause: %d checks, %d failures" % [checks, failures.size()])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)
