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

static func page_ray(host: Node3D, uv: Vector2) -> Array:
	var layout: Dictionary = host.page_layout()
	var offset := Vector3((uv.x - 0.5) * layout.size.x, (0.5 - uv.y) * layout.size.y, 0.4)
	return [layout.pose * offset, -layout.pose.basis.z]

func check_touch(events: Array, commands: Array, endpoint: Vector2, message: String) -> void:
	check(events.map(func(event): return event[0]) == commands, message + " sends the expected touch sequence")
	check(not events.is_empty() and Vector2(events.back()[1], events.back()[2]).is_equal_approx(endpoint),
		message + " ends at the expected source coordinates")

func touch_slop(main: InputMain, host: Node3D, platform: Fixture.Platform, mode: String, button: String) -> void:
	const HAND := "right_hand"
	const CENTRE := Vector2(0.5, 0.5)
	var pixel := Vector2(1.0 / float(host.page_css_scale().x), 0)
	var edge := Vector2(pixel.x * 0.5, 0.5)
	var first := platform.pointers.size()
	main.rays[HAND] = page_ray(host, CENTRE)
	main._on_controller_button(button, HAND)
	for drift in [1, -3, 5, -6]:
		main.rays[HAND] = page_ray(host, CENTRE + drift * pixel)
		main._update_menu_pointer(HAND)
	main._on_controller_release(button, HAND)
	check_touch(platform.pointers.slice(first), ["down", "up"], CENTRE, mode + ": jitter within the tap tolerance")

	first = platform.pointers.size()
	main.rays[HAND] = page_ray(host, edge)
	main._on_controller_button(button, HAND)
	main.rays[HAND] = page_ray(host, edge - pixel)
	main._update_menu_pointer(HAND)
	main._on_controller_release(button, HAND)
	check_touch(platform.pointers.slice(first), ["down", "up"], edge, mode + ": tap jitters across the webpage edge")

	first = platform.pointers.size()
	main.rays[HAND] = page_ray(host, CENTRE)
	main._on_controller_button(button, HAND)
	main.rays[HAND] = page_ray(host, CENTRE + 30 * pixel)
	main._update_menu_pointer(HAND)
	main.rays[HAND] = page_ray(host, CENTRE + pixel)
	main._update_menu_pointer(HAND)
	main._on_controller_release(button, HAND)
	check_touch(platform.pointers.slice(first), ["down", "move", "move", "up"], CENTRE + pixel, mode + ": drag stays active after returning near the start")

	first = platform.pointers.size()
	main.rays[HAND] = page_ray(host, CENTRE)
	main._on_controller_button(button, HAND)
	main.rays[HAND] = page_ray(host, CENTRE + 30 * pixel)
	main._on_controller_release(button, HAND)
	check_touch(platform.pointers.slice(first), ["down", "move", "up"], CENTRE + 30 * pixel, mode + ": fast drag first moves on release")

	first = platform.pointers.size()
	main.rays[HAND] = page_ray(host, edge)
	main._on_controller_button(button, HAND)
	main.rays[HAND] = page_ray(host, edge - 30 * pixel)
	main._on_controller_release(button, HAND)
	check_touch(platform.pointers.slice(first), ["down", "cancel"], edge, mode + ": large drag released outside the webpage")

	first = platform.pointers.size()
	main.rays[HAND] = page_ray(host, CENTRE)
	main._on_controller_button(button, HAND)
	main.rays.erase(HAND)
	main._update_menu_pointer(HAND)
	main._on_controller_release(button, HAND)
	check_touch(platform.pointers.slice(first), ["down", "cancel"], CENTRE, mode + ": tracking loss during a tap")

	var browser: RefCounted = host.browser
	browser.focus_regions[host.focus_tab()] = Rect2(0.3, 0.3, 0.05, 0.05)
	var destination := CENTRE + Vector2(0.02, 0)
	first = platform.pointers.size()
	main.rays[HAND] = page_ray(host, CENTRE)
	main._on_controller_button(button, HAND)
	main.rays[HAND] = page_ray(host, destination)
	main._update_menu_pointer(HAND)
	main._on_controller_release(button, HAND)
	check_touch(platform.pointers.slice(first), ["down", "move", "up"], host.source_point(destination), mode + ": focused page starts dragging promptly")
	browser.focus_regions.erase(host.focus_tab())

func a_button_scope(main: InputMain, host: Node3D, platform: Fixture.Platform, mode: String) -> void:
	const RIGHT := "right_hand"
	const LEFT := "left_hand"
	const A := "ax_button"
	const TRIGGER := "trigger_click"
	const CENTRE := Vector2(0.5, 0.5)
	var browser: RefCounted = host.browser
	var centre_ray := page_ray(host, CENTRE)
	main.rays[LEFT] = centre_ray
	var first := platform.pointers.size()
	main._on_controller_button(A, LEFT)
	main._on_controller_release(A, LEFT)
	check(platform.pointers.size() == first, mode + ": left X sends no page touch")

	main.rays[RIGHT] = page_ray(host, Vector2(2.0, 0.5))
	main._on_controller_button(A, RIGHT)
	main.rays[RIGHT] = centre_ray
	main._on_controller_release(A, RIGHT)
	check(platform.pointers.size() == first, mode + ": A pressed outside the page does not click on release inside it")

	for buttons in [[A, TRIGGER], [TRIGGER, A]]:
		first = platform.pointers.size()
		main._on_controller_button(buttons[0], RIGHT)
		main._on_controller_button(buttons[1], RIGHT)
		main._on_controller_release(buttons[1], RIGHT)
		check(browser.owns_pointer(RIGHT, buttons[0]) and platform.pointers.size() == first + 1,
			mode + ": a second button cannot release the first button's page touch")
		main._on_controller_release(buttons[0], RIGHT)
		check_touch(platform.pointers.slice(first), ["down", "up"], CENTRE, mode + ": overlapping A and trigger presses")

	first = platform.pointers.size()
	main._on_controller_button(A, RIGHT)
	main._on_controller_button(A, RIGHT)
	main._on_controller_release(A, RIGHT)
	check_touch(platform.pointers.slice(first), ["down", "up"], CENTRE, mode + ": duplicate A signal")
	check(not main._controller_consumed.has(RIGHT + "/" + A), mode + ": A release clears controller consumption")

	first = platform.pointers.size()
	host.selecting = true; host.refresh()
	main._on_controller_button(A, RIGHT)
	main._on_controller_release(A, RIGHT)
	check(platform.pointers.size() == first and host.drag.is_empty(), mode + ": A does not operate the focus selection overlay")
	host.selecting = false; host.toolbar_shown = true; host.refresh()
	var reload_button: Dictionary = host._buttons.filter(func(item): return item.target == browser.BASE + 2)[0]
	var node: Node3D = reload_button.node
	main.rays[RIGHT] = [node.global_position + node.global_basis.z * 0.4, -node.global_basis.z]
	check(int(host.ray_hit(main.rays[RIGHT][0], main.rays[RIGHT][1]).get("target", -1)) == reload_button.target,
		mode + ": the A scope probe actually targets the browser toolbar")
	var actions := platform.actions.duplicate()
	main._on_controller_button(A, RIGHT)
	main._on_controller_release(A, RIGHT)
	check(platform.actions == actions and platform.pointers.size() == first, mode + ": A sends no browser toolbar action")

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
	main.photo_active = false
	for mode in ["floating", "cinema"]:
		host.set_mode(mode); host.refresh()
		browser.next_poll = 0; browser.tick()
		for button in ["trigger_click", "ax_button"]:
			touch_slop(main, host, platform, mode + "/" + button, button)
		a_button_scope(main, host, platform, mode)
	browser.close(); menu.free(); platform.free(); video.free(); photo.free(); main.free(); await process_frame
	print("Browser trigger routing: %d checks, %d failures" % [checks, failures.size()])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)
