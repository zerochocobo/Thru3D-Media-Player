extends SceneTree
const Main := preload("res://scripts/main.gd")
const Menu := preload("res://scripts/library_menu.gd")
const Fixture := preload("res://tests/test_web_browser_panel.gd")

class InputMain extends Main:
	var rays := {}
	func _ray(hand: String) -> Variant: return rays.get(hand)
	func _controller_allowed(_hand: String) -> bool: return true
	func _input_focused() -> bool: return true
	func _vr_passthrough_active() -> bool: return false

var checks := 0
var failures: Array[String] = []
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)
func _initialize() -> void: run.call_deferred()
static func trigger(main: Node3D, hand: String) -> void:
	main._on_controller_button("trigger_click", hand)
	main._on_controller_release("trigger_click", hand)

func run() -> void:
	var main := InputMain.new()
	var video := Main.Video.new(); root.add_child(video); video.set_process(false); main.video = video
	var photo := Main.PhotoDisplay.new(); root.add_child(photo); photo.set_process(false); main.photo = photo
	var menu := Menu.new(); root.add_child(menu); menu.set_process(false)
	var platform := Fixture.Platform.new(); menu.attach_platform(platform); menu.toggle()
	main.recent_menu = menu; menu._activate(Menu.NAV_BASE + Menu.Section.WEB)
	var browser: RefCounted = menu.web_browser
	browser.open("https://example.com/page"); browser.tick()
	browser.next_poll = 0; browser.tick() # Settle the initial chrome signature before measuring rebuilds.
	browser.cinema_provider = func(): return {"position":[0,3,-12],"width":10.0,"height":5.625}
	var host: Node3D = browser.windows[1]; host.set_process(false)
	var surface: Node3D = host.surface
	for photo_active in [false, true]:
		main.photo_active = photo_active
		for mode in ["floating", "cinema"]:
			host.set_mode(mode)
			for toolbar in [true, false]:
				host.toolbar_shown = toolbar; host.refresh()
				browser.next_poll = 0; browser.tick()
				for hand in Main.ControllerBindings.HANDS:
					var tag := "%s/%s/frame=%s/%s" % ["photo" if photo_active else "video", mode, toolbar, hand]
					var layout: Dictionary = host.page_layout()
					var generation: int = host._buttons_generation
					var actions := platform.actions.duplicate()
					var commands := platform.browser_commands.duplicate()
					var pointer_count: int = platform.pointers.size()
					# Move beyond both the webpage and its auto-hiding lower controls.
					main.rays[hand] = [layout.pose * Vector3(layout.size.x * 2, 0, 0.4), -layout.pose.basis.z]
					check(host.ray_hit(main.rays[hand][0], main.rays[hand][1]).is_empty(), tag + ": ray misses the entire browser")
					trigger(main, hand)
					check(host.visible and browser.active(), tag + ": outside trigger keeps the live webpage visible")
					check(main._video_control_tap.is_empty() and main._grab.is_empty(), tag + ": no deferred menu dismissal or picture grab")
					browser.next_poll = 0; browser.tick()
					check(host._buttons_generation == generation and host.surface == surface and host.page_layout() == layout,
						tag + ": native polling never has to reopen or rebuild the window")
					check(platform.actions == actions and platform.browser_commands == commands and platform.pointers.size() == pointer_count,
						tag + ": missed trigger sends no page or session commands")
					# Clicking the page must still reach the same source coordinates afterwards.
					var uv := Vector2(0.31, 0.28)
					main.rays[hand] = [layout.pose * Vector3((uv.x - 0.5) * layout.size.x, (0.5 - uv.y) * layout.size.y, 0.4), -layout.pose.basis.z]
					trigger(main, hand)
					check(platform.pointers.size() == pointer_count + 2 and platform.pointers.back()[0] == "up"
						and Vector2(platform.pointers.back()[1], platform.pointers.back()[2]).distance_to(uv) < 0.001,
						tag + ": the next webpage trigger still completes down/up at the selected point")
					check(browser.hand.is_empty(), tag + ": release clears webpage pointer ownership")
	browser.close(); menu.free(); platform.free(); video.free(); photo.free(); main.free(); await process_frame
	print("Browser trigger routing: %d checks, %d failures" % [checks, failures.size()])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)
