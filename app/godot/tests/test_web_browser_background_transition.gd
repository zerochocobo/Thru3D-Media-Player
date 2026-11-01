extends SceneTree
const Main := preload("res://scripts/main.gd")
const Menu := preload("res://scripts/library_menu.gd")
const BrowserFixture := preload("res://tests/test_web_browser_windows.gd")
const HallFixture := preload("res://tests/test_cinema_environment.gd")
class RigMain extends Main:
	func _head_pose() -> Variant: return xr_camera.global_transform
var checks := 0
var failures: Array[String] = []
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)
func _initialize() -> void: run.call_deferred()
func run() -> void:
	var main := RigMain.new()
	var rig := XROrigin3D.new(); root.add_child(rig)
	rig.transform = Transform3D(Basis(Vector3.UP, 0.45), Vector3(8, 0.3, 35))
	var camera := XRCamera3D.new(); rig.add_child(camera)
	camera.transform = Transform3D(Basis.from_euler(Vector3(-0.08,0.17,0)), Vector3(0.2,1.65,0.1))
	main.xr_origin = rig; main.xr_camera = camera
	var hall := HallFixture.Fixture.new(); root.add_child(hall); hall.configure(rig, camera)
	main.cinema_environment = hall
	if hall.has_signal("view_relocated"):
		hall.connect("view_relocated", main._on_cinema_view_relocated)
	var platform := BrowserFixture.Platform.new()
	var menu := Menu.new(); root.add_child(menu); menu.attach_platform(platform); menu.toggle()
	main.recent_menu = menu; menu.layout_head_provider = main._head_pose
	menu._activate(Menu.NAV_BASE + Menu.Section.WEB)
	var browser: RefCounted = menu.web_browser
	browser.cinema_provider = func(): return hall.snapshot().screen if hall.active else {}
	platform.browser.windows = [{"id":1,"tab_id":1,"url":"https://example.com/a"}, {"id":2,"tab_id":2,"url":"https://example.com/b"}]
	platform.browser.tab_list = [{"id":1,"window":1},{"id":2,"window":2}]
	browser.open("https://example.com/a"); browser.tick()
	var original: Array[Transform3D] = []
	var relative: Array[Transform3D] = []
	var sizes: Array[Vector2] = []
	for id in [1,2]:
		var host: Node3D = browser.windows[id]
		host.set_mode("floating")
		host.global_transform = camera.global_transform * Transform3D(Basis(Vector3.UP,0.1).scaled(Vector3.ONE*(0.7+id*0.3)),Vector3(-1.3+id,-0.1,-2.0-id*0.2))
		host.page_size = Vector2(1.44+id*0.1,1.0)
		host.refresh(); host._process(0)
		original.append(host.global_transform)
		relative.append(camera.global_transform.affine_inverse()*host.global_transform)
		sizes.append(host.page_layout().size)
	for cycle in 3:
		if cycle == 0:
			var host: Node3D = browser.windows[1]
			var layout: Dictionary = host.page_layout()
			var origin: Vector3 = layout.pose * Vector3(0,0,0.3)
			check(host.press_pointer("left",origin,-layout.pose.basis.z,true) and browser.hand == "left", "A page pointer may still be held when scenery changes")
			var point: Vector3 = host.to_global(host.CENTRE)
			check(main.interface_move.begin("right","grip",host.ray_pose(camera.global_position,point-camera.global_position),[host.move_target("browser")],point,camera.global_transform), "A second controller may hold the browser during transition")
		hall.select(true)
		if cycle == 0:
			check(browser.hand.is_empty() and platform.pointers.back()[0] == "cancel", "Relocation cancels the old page input coordinates")
			check(main.interface_move.capture.is_empty(), "Relocation cancels the old world-space grip anchor")
		check(camera.global_position.distance_to(Vector3(0,1.2,1)) < 0.001, "Production cinema seating relocates the observer")
		for id in [1,2]:
			var host: Node3D = browser.windows[id]; host._process(0)
			check((camera.global_transform.affine_inverse()*host.global_transform).is_equal_approx(relative[id-1]), "Entering cinema preserves each floating window's viewer-relative pose and scale")
			check(host.page_layout().size.is_equal_approx(sizes[id-1]), "Background switch preserves webpage physical dimensions")
			check(host.get_parent() == root and not host.on_screen(), "A floating browser stays independent of the screen and rig")
		hall.select(false)
		for id in [1,2]:
			var host: Node3D = browser.windows[id]; host._process(0)
			check(host.global_transform.is_equal_approx(original[id-1]), "Returning to panorama restores floating placement without accumulated drift")
	var first: Node3D = browser.windows[1]
	first.set_mode("cinema"); hall.select(true); first.refresh(); first._process(0)
	check(first.to_global(first.move_centre()).distance_to(camera.global_position)<2.0, "Explicit cinema tools remain near the newly seated observer")
	check(first.page_layout().size.x > 6.0, "Explicit cinema page fills its screen rather than keeping tiny window size")
	hall.set_presented(false); first._process(0)
	check(first.global_transform.is_equal_approx(original[0]), "Temporarily hiding cinema also restores the saved floating pose")
	hall.set_presented(true); first._process(0)
	check(first.to_global(first.move_centre()).distance_to(camera.global_position)<2.0, "Restoring cinema repositions cached near tools correctly")
	hall.select(false); first._process(0)
	check(first.global_transform.is_equal_approx(original[0]), "Leaving explicit cinema rebases its cached floating pose")
	check(not platform.actions.has("reload") and not platform.actions.has("hibernate"), "Relocation preserves the page session")
	browser.close(); hall.free(); menu.free(); platform.free(); rig.free(); main.free(); await process_frame
	print("Browser background transition: %d checks, %d failures" % [checks,failures.size()])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)
