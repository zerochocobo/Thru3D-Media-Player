extends SceneTree
const Menu := preload("res://scripts/library_menu.gd")
const Fixture := preload("res://tests/test_web_browser_panel.gd")
const Capture := preload("res://scripts/menu_composition.gd")
var checks := 0
var failures: Array[String] = []
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)
func _initialize() -> void: run.call_deferred()
func run() -> void:
	var world := Node3D.new(); root.add_child(world)
	var camera := Camera3D.new(); camera.position.y = 1.6; world.add_child(camera)
	var menu := Menu.new(); world.add_child(menu)
	var platform := Fixture.Platform.new(); menu.attach_platform(platform); menu.toggle()
	menu._activate(Menu.NAV_BASE + Menu.Section.WEB); menu.set_process(false)
	var capture := Capture.new(); world.add_child(capture)
	capture.configure(world, camera, null, [menu], false, true); capture.set_process(false)
	var browser: RefCounted = menu.web_browser
	browser.window_created = capture.register_companion
	browser.open("https://example.com/page"); browser.tick()
	for count in [1, 2]:
		if count == 2:
			platform.browser.tab_list = [{"id": 1, "window": 1}, {"id": 2, "window": 2}]
			browser.next_poll = 0; browser.tick()
		capture.update()
		check(capture.layer_reservation() == 5 + count, "Chrome providers plus one page layer per window")
		for window in browser.windows.values():
			check(capture.menus.has(window), "Independent window registers for HD capture")
			var address: Node = window._buttons.filter(func(button): return button.target == browser.BASE + 3)[0].node
			check(capture.slots.any(func(slot): return slot.used and slot.nodes.has(address)), "Address bar captured into HD texture")
			var page: Node = window._buttons.filter(func(button): return button.target == browser.WEB)[0].node
			check(not capture.slots.any(func(slot): return slot.nodes.has(page)), "Native page hit tile excluded from chrome texture")
			check(not window._backdrop.visible, "Floating chrome has a transparent page centre")
		if OS.get_cmdline_user_args().has("--render"):
			for frame in 3: await process_frame; await RenderingServer.frame_post_draw; capture.update()
			var folder := ProjectSettings.globalize_path("res://../../build/output/browser-interaction-fixes/capture-%d" % count)
			DirAccess.make_dir_recursive_absolute(folder)
			for slot in capture.slots:
				if not slot.used or slot.empty: continue
				var pixels: Image = slot.raw.get_texture().get_image()
				check(pixels.save_png(folder.path_join("plane-%d.png" % slot.index)) == OK, "Chrome texture saved")
				var clear := 0; var ink := 0
				for y in range(0, pixels.get_height(), 4):
					for x in range(0, pixels.get_width(), 4):
						var color := pixels.get_pixel(x, y)
						if color.a < 0.01: clear += 1
						if color.a > 0.5 and color.r > 0.6 and color.g > 0.7: ink += 1
				for window in browser.windows.values():
					var address: Node = window._buttons.filter(func(button): return button.target == browser.BASE + 3)[0].node
					if not slot.nodes.has(address): continue
					var local: Vector3 = slot.camera.global_transform.affine_inverse() * window.page_layout().pose.origin
					var x := int((local.x / slot.layer.quad_size.x + 0.5) * pixels.get_width())
					var y := int((0.5 - local.y / slot.layer.quad_size.y) * pixels.get_height())
					check(pixels.get_pixel(x, y).a < 0.01, "Native webpage centre remains transparent in the HD chrome texture")
				check(clear > 100 and ink > 10, "Rendered texture %d/%d contains transparency=%d and glyphs=%d" % [count, slot.index, clear, ink])
	browser.close(); menu.visible = false; capture.update()
	check(capture.slots.all(func(slot): return not slot.used), "Leaving retires chrome captures")
	world.free(); platform.free(); await process_frame
	print("Browser composition: %d checks, %d failures" % [checks, failures.size()])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)
