extends SceneTree
## Production photo/grip routes with synthetic poses; no headset or decoder.
const InputMain := preload("res://tests/test_controller_bindings.gd").InputMain
var checks := 0
var failures: Array[String] = []

func _initialize() -> void: run.call_deferred()
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message); printerr("FAIL: ", message)

func push(main: Node, hand: String, stick: Vector2, delta: float = .1) -> void:
	main._process_sticks(stick if hand == "left_hand" else Vector2.ZERO, stick if hand == "right_hand" else Vector2.ZERO, delta)
	main._update_interface_move()

func grab(main: Node, hand: String, point: Vector3) -> void:
	var origin: Vector3 = main.head_pose.origin + Vector3(.22, -.3, -.4)
	main.pose = main.InterfaceMove.ray_pose(origin, point - origin)
	main.rays = {hand: [origin, (point - origin).normalized()]}
	main._on_controller_button("grip_click", hand)
	check(not main.interface_move.capture.is_empty(), "Grip captures the aimed photo: " + hand)

## The browser window takes the same Grip + stick ← / → through the production route.
func verify_browser_grip(main: Node) -> void:
	main.photo_active = false
	var library := preload("res://scripts/library_menu.gd").new(); root.add_child(library); library.set_process(false)
	var platform := preload("res://tests/test_web_browser_panel.gd").Platform.new(); library.attach_platform(platform); library.toggle()
	library._activate(library.NAV_BASE + library.Section.WEB); main.recent_menu = library
	library.web_browser.open("https://example.test/page"); library.web_browser.tick()
	var window: Node3D = library.web_browser.windows[1]; window.set_process(false)
	window.global_transform = Transform3D(Basis.IDENTITY, main.head_pose.origin + Vector3(-.13, 0, -2))
	var centre: Vector3 = window.to_global(window.CENTRE)
	grab(main, "right_hand", centre)
	push(main, "right_hand", Vector2.ZERO)
	for step in 4: push(main, "right_hand", Vector2.RIGHT)
	var scaled: float = window.global_basis.get_scale().x
	check(scaled > 1 and window.to_global(window.CENTRE).distance_to(centre) < .001, "Grip + stick right enlarges the browser about its centre")
	push(main, "right_hand", Vector2.UP)
	check(is_equal_approx(window.global_basis.get_scale().x, scaled), "Grip + stick up keeps the browser size while changing distance")
	for step in 4: push(main, "right_hand", Vector2.LEFT)
	check(window.global_basis.get_scale().x < scaled, "Grip + stick left shrinks the browser")
	main._on_controller_release("grip_click", "right_hand")
	main.recent_menu = null; library.free(); platform.free()
func run() -> void:
	var main := InputMain.new(); main.settings_path = "user://photo-grip-controls.cfg"
	var video := preload("res://scripts/mpv_video_display.gd").new(); video.history_enabled = false
	root.add_child(video); video.set_process(false); main.video = video
	var photo := preload("res://scripts/photo_display.gd").new(); photo.auto_depth = false; photo.history_enabled = false
	root.add_child(photo); photo.set_process(false); photo.gallery.set_process(false)
	main.photo = photo; main.photo_active = true
	var fixture := Image.create(64, 48, false, Image.FORMAT_RGB8); fixture.fill(Color.CORNFLOWER_BLUE)
	fixture.save_png("user://grip.png"); photo.local_uri = ProjectSettings.globalize_path("user://grip.png")
	photo.queue.assign([{"uri": photo.local_uri, "title": "Grip fixture"}]); photo.index = 0
	var camera := Camera3D.new(); root.add_child(camera); camera.global_transform = main.head_pose; photo.view_camera = camera
	var menu := preload("res://scripts/player_menu.gd").new(); root.add_child(menu); menu.set_process(false)
	main.player_menu = menu; main.photo_menu = menu; menu.state_provider = main._menu_state; menu.visible = false
	for stereo in [false, true]:
		for hand in ["left_hand", "right_hand"]:
			photo.geometry = 0; photo.stereo_sbs = stereo; photo.set_screen_scale(1)
			photo.flat_pose = Transform3D(Basis.IDENTITY, Vector3(0, 1.6, -3)); photo.set_screen_distance(3)
			photo._apply_geometry(); photo.panel.visible = true
			var before: Transform3D = photo.flat_pose
			var index: int = photo.index
			grab(main, hand, photo.panel.global_position)
			push(main, hand, Vector2.RIGHT)
			check(photo.screen_scale == 1, "Held stick must recenter before resize")
			push(main, hand, Vector2.ZERO)
			push(main, "right_hand" if hand == "left_hand" else "left_hand", Vector2.RIGHT)
			check(photo.screen_scale == 1, "Other hand cannot resize the captured photo")
			for step in 4: push(main, hand, Vector2(1, .4))
			check(photo.screen_scale > 1 and photo.flat_pose.is_equal_approx(before) and is_equal_approx(photo.screen_distance, 3), "Right enlarges mono/stereo photo without changing distance or pose")
			for step in 4: push(main, hand, Vector2.LEFT)
			check(is_equal_approx(photo.screen_scale, 1) and photo.flat_pose.is_equal_approx(before), "Left shrinks symmetrically")
			push(main, hand, Vector2.UP)
			check(photo.screen_distance < 3 and is_equal_approx(photo.screen_scale, 1), "Back keeps the existing distance adjustment")
			push(main, hand, Vector2.DOWN)
			check(is_equal_approx(photo.screen_distance, 3) and is_equal_approx(photo.screen_scale, 1), "Forward restores distance without scaling")
			for value in [Vector2(.2, 0), Vector2.ONE, Vector2(NAN, 0), Vector2(INF, 0)]: push(main, hand, value)
			for value in [0.0, -.1, NAN, INF]: push(main, hand, Vector2.RIGHT, value)
			check(is_equal_approx(photo.screen_scale, 1), "Deadzone, diagonals and invalid input do not resize")
			main.settings.set_value("screen", "edit_locked", true); push(main, hand, Vector2.RIGHT)
			check(photo.screen_scale > 1, "Video-only screen lock does not change photo controls")
			push(main, hand, Vector2.LEFT); main.settings.set_value("screen", "edit_locked", false)
			push(main, hand, Vector2.RIGHT)
			var scaled: float = photo.screen_scale
			main._on_controller_release("grip_click", hand)
			var saved := ConfigFile.new(); saved.load(main.settings_path)
			check(main.interface_move.capture.is_empty() and is_equal_approx(saved.get_value("photo_screen", "scale", 0), scaled), "Release saves photo size in its own settings")
			push(main, hand, Vector2.RIGHT)
			check(photo.index == index and photo.screen_scale == scaled, "Resizing/release cannot leak to next photo")
			push(main, hand, Vector2.ZERO)
	# Existing remappable zoom and next/previous shortcuts stay independent.
	check(main.controller_bindings.resolve("right_hand", "stick_right", "photo") == "photo_next" and main.controller_bindings.resolve("right_hand", "stick_left", "photo") == "photo_previous", "Bare horizontal stick keeps photo switching")
	main.controller_bindings.assign("photo_zoom_in", main.ControllerBindings.bind("left_hand", "ax_button"), true)
	grab(main, "right_hand", photo.panel.global_position); push(main, "right_hand", Vector2.ZERO)
	photo.set_screen_scale(photo.PHOTO_SCALE_LIMITS.y); push(main, "right_hand", Vector2.RIGHT)
	check(photo.screen_scale == photo.PHOTO_SCALE_LIMITS.y, "Photo maximum is retained")
	photo.set_screen_scale(photo.PHOTO_SCALE_LIMITS.x); push(main, "right_hand", Vector2.LEFT)
	check(photo.screen_scale == photo.PHOTO_SCALE_LIMITS.x, "Photo minimum is retained")
	push(main, "right_hand", Vector2.RIGHT)
	check(photo.screen_scale > photo.PHOTO_SCALE_LIMITS.x, "Remapping ordinary photo zoom cannot change fixed grip resizing")
	main.controller_bindings.press("right_hand", "trigger_click")
	var scale: float = photo.screen_scale; push(main, "right_hand", Vector2.RIGHT)
	check(photo.screen_scale == scale, "Grip plus trigger combinations keep ownership")
	main.controller_bindings.release("right_hand", "trigger_click")
	main.pose_available = false; push(main, "right_hand", Vector2.RIGHT)
	check(main.interface_move.capture.is_empty() and photo.screen_scale == scale, "Lost tracking cancels without resizing")
	main.pose_available = true; main._on_controller_release("grip_click", "right_hand")
	# Menu-only, magnifier and panorama captures are not flat picture resizing.
	menu.toggle(); main.rays = {"right_hand": [menu.global_position + menu.global_basis.z, -menu.global_basis.z]}
	main._begin_interface_move("right_hand", "grip_click")
	check(main.interface_move.capture.targets.all(func(target): return target.kind == "menu"), "Menu-only capture excludes photo")
	push(main, "right_hand", Vector2.ZERO); push(main, "right_hand", Vector2.RIGHT)
	check(photo.screen_scale == scale, "Moving a menu cannot resize a photo")
	main._finish_interface_move(); menu.dismiss()
	photo.set_screen_scale(1); grab(main, "left_hand", photo.panel.global_position); push(main, "left_hand", Vector2.ZERO)
	photo.inspect = true; push(main, "left_hand", Vector2.RIGHT)
	check(photo.screen_scale == 1, "Magnifier is excluded from photo grip scaling")
	photo.inspect = false; main._on_controller_release("grip_click", "left_hand")
	photo.geometry = 1; photo._apply_geometry()
	grab(main, "left_hand", main.head_pose.origin + Vector3.FORWARD * 3); push(main, "left_hand", Vector2.ZERO); push(main, "left_hand", Vector2.RIGHT)
	check(photo.screen_scale == 1 and not photo.inspect, "Panorama grip does not resize or open the magnifier")
	main._on_controller_release("grip_click", "left_hand"); photo.geometry = 0; photo._apply_geometry()
	# Overview grip resizes actual cards through the existing layout scale, not the hidden full image.
	for layout in [2, 3]:
		for hand in ["left_hand", "right_hand"]:
			photo.gallery.set_mode(layout); photo.gallery.recenter(); photo.gallery.set_view_scale(1); photo.gallery._process(.01)
			var card: Dictionary = photo.gallery.cards.values()[0]
			var height: float = card.size.y
			var anchor: Transform3D = photo.gallery.anchor
			var distance: float = photo.gallery.view_distance
			grab(main, hand, card.node.global_position); push(main, hand, Vector2.ZERO); push(main, hand, Vector2.RIGHT)
			photo.gallery._process(.01)
			check(photo.gallery.view_scale > 1 and photo.screen_scale == 1, "Grip enlarges the overview independently of the full photo")
			check(photo.gallery.cards.values()[0].size.y > height and photo.gallery.anchor.is_equal_approx(anchor) and photo.gallery.view_distance == distance, "Overview cards enlarge without moving the layout")
			push(main, hand, Vector2.LEFT)
			check(is_equal_approx(photo.gallery.view_scale, 1), "Grip left shrinks the overview")
			push(main, hand, Vector2.RIGHT); main._on_controller_release("grip_click", hand)
			var saved := ConfigFile.new(); saved.load(main.settings_path)
			check(is_equal_approx(saved.get_value("photo_screen", "layout_%d_scale" % layout, 0), photo.gallery.view_scale), "Release persists this layout's scale")
	verify_browser_grip(main)
	menu.free(); camera.free(); photo.free(); video.free(); main.free()
	for failure in failures: push_error(failure)
	print("Photo grip controls: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
