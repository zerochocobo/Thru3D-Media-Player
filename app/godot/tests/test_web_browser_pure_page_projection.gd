extends SceneTree
const InputFixture := preload("res://tests/test_web_browser_trigger.gd")
const Main := preload("res://scripts/main.gd")
const Menu := preload("res://scripts/library_menu.gd")
const Fixture := preload("res://tests/test_web_browser_panel.gd")
const Capture := preload("res://scripts/menu_composition.gd")
const Surface := preload("res://scripts/web_browser_surface.gd")
var checks := 0
var failures: Array[String] = []
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)
func _initialize() -> void: run.call_deferred()
func settle(capture: Node) -> void:
	for frame in 6:
		capture.update(); await process_frame; await RenderingServer.frame_post_draw
func run() -> void:
	var render := OS.get_cmdline_user_args().has("--render")
	var viewport := SubViewport.new(); viewport.size = Vector2i(900, 900)
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS; root.add_child(viewport)
	var world := Node3D.new(); viewport.add_child(world)
	var camera := Camera3D.new(); world.add_child(camera); camera.fov = 65
	camera.environment = Environment.new()
	var main := InputFixture.InputMain.new()
	main.display.configure(viewport, camera.environment, null, true)
	# Exercise the headset's projection-alpha policy without claiming native XR submission.
	main.display.preview = false
	var video := Main.Video.new(); root.add_child(video); video.set_process(false); main.video = video
	var menu := Menu.new(); world.add_child(menu); menu.set_process(false); main.recent_menu = menu
	var platform := Fixture.Platform.new(); menu.attach_platform(platform); menu.toggle()
	menu._activate(Menu.NAV_BASE + Menu.Section.WEB)
	var capture := Capture.new(); world.add_child(capture)
	capture.configure(world, camera, null, [menu], false, true); capture.set_process(false)
	var browser: RefCounted = menu.web_browser; browser.window_created = capture.register_companion
	browser.open("https://example.com/page"); browser.tick()
	browser.cinema_provider = func(): return {"position":[0,3,-12],"width":10.0,"height":5.625}
	var host: Node3D = browser.windows[1]; host.set_process(false)
	# The same eye-buffer shader and priority as the native Surface, which is unavailable on desktop.
	var hole := MeshInstance3D.new(); hole.mesh = QuadMesh.new()
	var material := ShaderMaterial.new(); material.shader = Surface.HOLE; material.render_priority = 25
	hole.material_override = material; world.add_child(hole)
	for mode in ["floating", "cinema"]:
		host.set_mode(mode); host.refresh(); host._process(0)
		for enabled in [false, true]:
			host.depth.enabled = enabled; host.depth.state = "ready"
			host.toolbar_shown = true; host.refresh(); host._process(0)
			var footer: Node3D = host.effect_controls
			footer.sync(1000); footer.visible = true
			host._activate(footer.CHROME); host._process(0)
			# A missed trigger and the row's normal leave timeout remove every HD control.
			var layout: Dictionary = host.page_layout()
			main.rays.right_hand = [layout.pose * Vector3(layout.size.x * 2, 0, 0.4), -layout.pose.basis.z]
			main._update_menu_pointer("right_hand")
			InputFixture.trigger(main, "right_hand")
			footer.near_hands.clear(); footer.last_near = 0; footer.sync(2000)
			host._update_feedback(); capture.invalidate(); capture.update()
			check(not footer.visible and capture._any_placed == (mode == "cinema"), mode + ": floating pure page parks chrome; projected screen keeps its near menu")
			main.display.set_menu_layers(false); main._sync_display_policy()
			check(host.surface.shown and host.visible and browser.active(), mode + ": webpage remains presented after the missed trigger")
			check(viewport.transparent_bg and camera.environment.background_color.a == 0.0,
				mode + ": the browser alone keeps projection alpha after HD controls disappear")
			if render:
				hole.global_transform = layout.pose; hole.mesh.size = layout.size
				camera.global_position = layout.pose * Vector3(0, 0, layout.size.x)
				camera.look_at(layout.pose.origin)
				await settle(capture)
				var pixels := viewport.get_texture().get_image()
				var alpha := pixels.get_pixelv(viewport.size / 2).a
				print("Pure-page projection alpha (%s, depth=%s): %.4f" % [mode, enabled, alpha])
				check(alpha < 0.02, mode + ": rendered page hole stays clear with no visible menu")
				var output := ProjectSettings.globalize_path("res://../../build/output/browser-trigger")
				DirAccess.make_dir_recursive_absolute(output)
				pixels.save_png(output.path_join("pure-page-%s-depth-%s.png" % [mode, enabled]))
	# A hidden window or an internal tab sheet must not stand in for a live page.
	browser.tabs_open = true; host._process(0); main._sync_display_policy()
	check(not viewport.transparent_bg, "The tab sheet releases the hidden webpage's transparency request")
	browser.tabs_open = false
	platform.browser.windows = [{"id":1,"tab_id":1,"url":"https://example.com/page"}, {"id":2,"tab_id":2,"url":"https://example.com/second"}]
	platform.browser.tab_list = [{"id":1,"window":1}, {"id":2,"window":2}]
	browser.next_poll = 0; browser.tick()
	var second: Node3D = browser.windows[2]; second.set_process(false)
	second._process(0); host.dismiss(); main._sync_display_policy()
	check(viewport.transparent_bg, "A second visible webpage retains alpha when the first window is hidden")
	second.dismiss(); main._sync_display_policy()
	check(not viewport.transparent_bg, "Hidden windows cannot keep browser transparency active")
	# Native closure must release the browser's own transparency request.
	browser.close(); main._sync_display_policy()
	check(not viewport.transparent_bg, "Closing the browser restores the opaque background")
	main.display.set_video_layer(true); main._sync_display_policy()
	check(viewport.transparent_bg, "Closing the browser preserves an independent video underlay")
	main.display.set_video_layer(false); main.display.set_menu_layers(true); main._sync_display_policy()
	check(viewport.transparent_bg, "Closing the browser preserves independent menu layers")
	viewport.free(); platform.free(); video.free(); main.free(); await process_frame
	print("Browser pure-page projection: %d checks, %d failures" % [checks, failures.size()])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)
