extends SceneTree
const Main := preload("res://scripts/main.gd")
const Menu := preload("res://scripts/library_menu.gd")
const Fixture := preload("res://tests/test_web_browser_windows.gd")
class InputMain extends Main:
	var hall := true
	var eye := Transform3D(Basis(Vector3.UP, 0.25), Vector3(0.4, 1.7, 0.2))
	func _cinema_scene_active() -> bool: return hall
	func _cinema_interaction_owns() -> bool: return false
	func _input_focused() -> bool: return true
	func _head_pose() -> Variant: return eye
	func _move_pose(hand: String) -> Variant:
		var ray: Variant = _ray(hand)
		return null if ray == null else preload("res://scripts/web_browser_window.gd").ray_pose(ray[0], ray[1])
class Movie extends Node3D:
	var local_uri := "content://movie"
	var geometry := 0
	var requested_play := true
	func pause_playback() -> void: requested_play = false
var checks := 0
var failures: Array[String] = []
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)
func _initialize() -> void: _run.call_deferred()
func _run() -> void:
	var main := InputMain.new()
	var movie := Movie.new(); main.video = movie
	var platform := Fixture.Platform.new()
	var menu := Menu.new(); root.add_child(menu); menu.attach_platform(platform); menu.toggle()
	main.recent_menu = menu
	menu.layout_head_provider = func(): return main.eye
	menu.browser_opened.connect(main._on_web_browser_opened)
	menu._activate(Menu.NAV_BASE + Menu.Section.WEB)
	var browser: RefCounted = menu.web_browser
	browser.cinema_provider = func(): return {"position": [0, 3, -12], "width": 10.0, "height": 5.625, "yaw": 0.0}
	browser.cinema_video_provider = main._browser_keeps_cinema_video
	browser.open("http://192.168.31.185:8096/web/index.html#!/home"); browser.tick()
	var host: Node3D = browser.windows[1]
	check(movie.requested_play and not host.on_screen(), "Opening floating web beside a cinema movie preserves playback")
	host.set_mode("cinema"); browser.open()
	check(not host.on_screen() and movie.requested_play, "Reopening an old cinema web layout keeps the movie screen")
	main.hall = false; browser.open()
	check(not movie.requested_play, "Opening web outside the cinema retains the previous pause behavior")
	main.hall = true; movie.requested_play = true
	platform.browser.merge({"tab_id": 1, "navigation": 1, "fullscreen_video": true, "fullscreen_request": 1}, true)
	browser.next_poll = 0; browser.tick()
	check(not browser.handoff and movie.requested_play, "Web fullscreen beside a cinema movie does not automatically replace it")
	# Manual native playback remains an explicit replacement action.
	browser.action(browser.BASE + 6)
	check(browser.handoff, "Play in player still explicitly requests native handoff")
	browser._cancel_handoff(); platform.browser.fullscreen_video = false
	movie.local_uri = ""; host.set_mode("cinema"); browser.refresh_windows(); host._process(0)
	var page: Dictionary = host.page_layout()
	# Exercise the production hand dispatch, both hands, and the physical grip path.
	main.controller_bindings.pinch_hand = "right_hand"
	for hand in ["left_hand", "right_hand"]:
		main.hand_pointers[hand] = preload("res://scripts/hand_pointer.gd").new()
		main.hand_pointers[hand].source = "hand"
		for local in [Vector3(0.655, 0.555, 0.002), Vector3(0.13, 0.515, 0)]:
			var before: Transform3D = host.global_transform
			var origin: Vector3 = main.eye.origin + main.eye.basis * Vector3(-0.18 if hand == "left_hand" else 0.18, -0.25, -0.25)
			var direction := (host.to_global(local) - origin).normalized()
			main.hand_pointers[hand].ray = [origin, direction]
			main._dispatch_hand_input({hand: {"source": "hand", "tracked": true, "down": true, "pressed": true}})
			check(host.drag.get("hand") == hand, "Either hand can pinch the cinema handle or empty bar")
			main.hand_pointers[hand].ray[1] = Basis(Vector3.UP, 0.12) * Basis(Vector3.RIGHT, 0.10) * direction
			main._update_menu_pointer(hand); host._process(0)
			check(not host.global_transform.is_equal_approx(before), "Pinch drag moves the near controls")
			check_facing(host, main.eye.origin)
			check(host.page_layout().pose.is_equal_approx(page.pose), "Dragging controls leaves the distant webpage fixed")
			main._dispatch_hand_input({hand: {"source": "hand", "tracked": true, "released": true}})
			check(host.drag.is_empty() and host.title_move.capture.is_empty(), "Releasing the pinch ends the drag")
			var settled: Transform3D = host.global_transform
			main.eye.basis = main.eye.basis * Basis(Vector3.UP, 0.1); host._process(0)
			check(host.global_transform.is_equal_approx(settled), "Released bar stays placed when the head turns")
		main.hand_pointers[hand].ray = [main.eye.origin, (host.to_global(Vector3(0.655, 0.555, 0.002)) - main.eye.origin).normalized()]
		main._begin_interface_move(hand, "grip_click")
		check(not main.interface_move.capture.is_empty(), "Grip captures the near cinema bar through Main")
		main.hand_pointers[hand].ray[1] = Basis(Vector3.UP, -0.15) * main.hand_pointers[hand].ray[1]
		main._update_interface_move(); host._process(0); check_facing(host, main.eye.origin)
		main.interface_move.cancel()
	# Tracking loss cancels pinch ownership without moving the page.
	var origin: Vector3 = main.eye.origin
	var direction := (host.to_global(Vector3(0.655, 0.555, 0.002)) - origin).normalized()
	host.press_pointer("right_hand", origin, direction, true)
	host.update_pointer("right_hand", origin, direction, false)
	check(host.drag.is_empty(), "Tracking loss cancels near-bar capture")
	# A second selected window can coexist with the first window on the far screen.
	platform.browser.windows = [{"id": 1, "tab_id": 1, "url": platform.browser.url}, {"id": 2, "tab_id": 2, "url": "https://example.com"}]
	platform.browser.tab_list = [{"id": 1, "window": 1}, {"id": 2, "window": 2}]
	platform.browser.focused_window = 1
	browser.next_poll = 0; browser.tick()
	var second: Node3D = browser.windows[2]
	check(host.visible and host.on_screen() and second.visible and not second.on_screen(), "Splitting preserves the cinema webpage plus a separate floating window")
	check(host._buttons.any(func(button): return button.target == host.MOVE and button.enabled), "Cinema window retains its visible draggable narrow bar")
	for id in [1, 2, 1]:
		browser.focus_window(id)
		check(host.on_screen() and not second.on_screen(), "Changing input focus preserves both presentations")
	browser.data.merge({"tab_id": 2, "fullscreen_video": true, "fullscreen_request": 2, "active": true}, true)
	browser._poll_fullscreen()
	check(not browser.handoff, "Second webpage playback cannot automatically replace the first cinema webpage")
	# Bookmark feedback follows the stored URL, even while editing another URL.
	browser.saved = {"bookmarks": [{"url": "http://192.168.31.185:8096/web/index.html"}]}
	browser.data.windows[0].bookmark_url = "http://192.168.31.185:8096/web/index.html"
	browser.draft = "https://unfinished.example"; browser.refresh_windows()
	check(star_texture(host) == host.Icons.texture("star_filled"), "Emby hash route uses the filled bookmark star despite an unfinished address draft")
	check(star_texture(second) == second.Icons.texture("star"), "Other window keeps its own independent bookmark state")
	browser.saved.bookmarks = []; browser.refresh_windows()
	check(star_texture(host) == host.Icons.texture("star"), "Confirmed bookmark removal clears the star")
	browser.close(); menu.free(); platform.free(); movie.free(); main.free(); await process_frame
	print("Browser cinema: %d checks, %d failures" % [checks, failures.size()])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)
func check_facing(host: Node3D, eye: Vector3) -> void:
	var facing := (eye - host.to_global(Vector3(0.13, 0.505, 0))).normalized()
	check(host.global_basis.z.normalized().dot(facing) > 0.9999 and absf(host.global_basis.x.y) < 0.001, "Near bar normal faces the headset from its own centre without roll")
func star_texture(host: Node3D) -> Texture2D:
	var button: Dictionary = host._buttons.filter(func(item): return item.target == host.browser.BASE + 4)[0]
	for child in button.node.get_children():
		if child is MeshInstance3D: return child.material_override.albedo_texture
	return null
