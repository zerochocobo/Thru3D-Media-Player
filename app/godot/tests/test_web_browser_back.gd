extends SceneTree
const Library := preload("res://scripts/library_menu.gd")
const Player := preload("res://scripts/player_menu.gd")
const Fixture := preload("res://tests/test_web_browser_panel.gd")

class InputMain extends "res://scripts/main.gd":
	func _input_focused() -> bool: return true
	func _ray(_hand: String) -> Variant: return null
	func _head_pose() -> Variant: return Transform3D(Basis.IDENTITY, Vector3(0, 1.6, 0))

class ReturnVideo extends "res://scripts/mpv_video_display.gd":
	var closes := 0
	func pause_playback() -> void: requested_play = false
	func close_video() -> void:
		closes += 1; media.close(); control.close()

var checks := 0
var failures: Array[String] = []
var main: InputMain
var library: Node3D
var controls: Node3D
var platform: Fixture.Platform
var video: ReturnVideo

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func tap(hand: String) -> void:
	main._on_controller_button("by_button", hand)
	# Repeated press callbacks during a hold must not act on the newly exposed page.
	main._on_controller_button("by_button", hand)
	main._on_controller_release("by_button", hand)

func poll() -> void:
	library.web_browser.next_poll = 0; library.web_browser.tick()

func reset() -> void:
	video.media.close(); video.local_uri = "file:///finished.mp4"
	controls.dismiss(); library.visible = true; library.section = Library.Section.WEB
	library.web_browser.tabs_open = false; library.web_browser.window_action.clear()
	library.web_browser.playback_return.clear()
	platform.browser = {"url": "https://www.bilibili.com/video/BV1xx411c7mD/", "title": "Video", "progress": 100,
		"back": true, "tab_id": 1, "navigation": 5, "focused_window": 1, "active": true,
		"playing": false, "videos": []}
	library.web_browser.open(); poll()
	platform.actions.clear(); platform.inputs.clear(); platform.browser_commands.clear()

func _initialize() -> void: call_deferred("run")
func run() -> void:
	main = InputMain.new()
	main.settings_path = ProjectSettings.globalize_path("res://../../build/output/browser-back/settings.cfg")
	video = ReturnVideo.new(); video.history_enabled = false; root.add_child(video); video.set_process(false)
	main.video = video
	library = Library.new(); root.add_child(library); library.set_process(false)
	platform = Fixture.Platform.new(); library.attach_platform(platform); main.recent_menu = library
	controls = Player.new(); controls.state_provider = main._menu_state
	root.add_child(controls); controls.set_process(false); main.player_menu = controls; main.video_menu = controls
	await process_frame
	for hand in ["right_hand", "left_hand"]:
		reset()
		controls.visible = true; controls.refresh()
		tap(hand)
		check(not controls.visible and library.web_browser.active(), "First Back dismisses residual controls and retains webpage: " + hand)
		check(platform.actions.is_empty() and platform.inputs.is_empty(), "Closing controls cannot navigate or close the page on press/hold/release")
		tap(hand)
		check(platform.actions == ["back"] and library.web_browser.active(), "The next physical press performs exactly one webpage Back")
		for can_back in [false, true]:
			for fullscreen in [false, true]:
				reset(); platform.browser.back = can_back; platform.browser.fullscreen = fullscreen; poll()
				tap(hand)
				check(platform.actions == ["back"], "Web Back uses native history/fullscreen arbitration without hibernating: %s/%s/%s" % [hand, can_back, fullscreen])
				check(library.web_browser.active(), "No-history Back keeps the browser rather than opening the website picker")
		reset(); library.web_browser.windows[1].set_toolbar_shown(false)
		tap(hand)
		check(platform.actions == ["back"] and library.web_browser.active(), "Pure-page Back works with menus hidden")
		library.web_browser.windows[1].set_toolbar_shown(true)
		reset(); controls.visible = true; controls._volume_open = true; controls.refresh()
		tap(hand)
		check(controls.visible and not controls._volume_open and platform.actions.is_empty(), "A player child panel consumes Back before its transport or webpage")
		tap(hand)
		check(not controls.visible and platform.actions.is_empty(), "Closing the transport still consumes a separate press")
		reset(); video.local_uri = "webvideo://capture/playing"; video.media.begin(7); video.media.state = "playing"
		controls.visible = true; controls.refresh(); var closes := video.closes
		tap(hand)
		check(not controls.visible and video.closes == closes and video.media.state == "playing" and platform.actions.is_empty(),
			"Closing overlaid player controls leaves ongoing playback and browser history alone")
		reset(); library.web_browser.tabs_open = true; library.web_browser.window_action = {"command": "move_tab", "tab": 1}
		tap(hand)
		check(not library.web_browser.tabs_open and library.web_browser.window_action.is_empty() and platform.actions.is_empty(), "Tab overlay Back cannot also navigate")
		for keyboard in ["editing", "keyboard_visible"]:
			reset(); platform.browser[keyboard] = true; poll(); tap(hand)
			check(platform.inputs == [["close", ""]] and platform.actions.is_empty() and library.web_browser.active(), "Keyboard Back only closes input: " + keyboard)
		# Return from native playback on B must not immediately back out of the retained page.
		reset(); var uri := "webvideo://capture/return"
		video.local_uri = uri; video.media.begin(8); video.media.state = "playing"
		library.web_browser.playback_return = {"native_uri": uri, "retained": true, "window": 1, "tab": 1, "navigation": 5, "origin": platform.browser.url}
		library.dismiss(); controls.visible = true; controls.refresh(); platform.actions.clear(); closes = video.closes
		tap(hand)
		check(video.closes == closes + 1 and not controls.visible and library.web_browser.active(), "Native playback Back returns once to the retained webpage")
		check(not platform.actions.has("back") and not platform.actions.has("hibernate"), "Native return never also navigates or exits the browser")
		platform.actions.clear(); tap(hand)
		check(platform.actions == ["back"], "The first new press after native return belongs to webpage history")
	reset()
	library.web_browser.action(library.web_browser.BASE + 5)
	check(platform.browser_commands.any(func(command): return command.action == "close_window"), "Explicit close-window button remains available for exiting the webpage")
	library.free(); controls.free(); video.free(); main.free(); platform.free(); await process_frame
	print("Web browser Back: %d checks, %d failures" % [checks, failures.size()])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)
