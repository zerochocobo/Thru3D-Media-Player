extends SceneTree
const Fixture := preload("res://tests/test_web_browser_global_footer.gd")
const Menu := preload("res://scripts/library_menu.gd")
const Platform := preload("res://tests/test_web_browser_windows.gd").Platform
const I18n := preload("res://scripts/i18n.gd")
const Palette := preload("res://scripts/ui_theme.gd")
var output := ProjectSettings.globalize_path("res://../../build/output/browser-global-footer/visuals")
var view: SubViewport
var count := 0
var failures: Array[String] = []
func _initialize() -> void: run.call_deferred()
func capture(name: String) -> void:
	for frame in 4: await process_frame; await RenderingServer.frame_post_draw
	if view.get_texture().get_image().save_png(output.path_join(name+".png")) != OK: failures.append(name)
	count += 1
func run() -> void:
	DirAccess.make_dir_recursive_absolute(output)
	view = SubViewport.new(); view.size = Vector2i(1600,1000); view.own_world_3d = true
	view.render_target_update_mode = SubViewport.UPDATE_ALWAYS; root.add_child(view)
	var camera := Camera3D.new(); camera.projection = Camera3D.PROJECTION_ORTHOGONAL; camera.size = .9; view.add_child(camera)
	var main := Fixture.Host.new()
	var menu := Menu.new(); view.add_child(menu); menu.set_process(false)
	var platform := Platform.new(); menu.attach_platform(platform); menu.toggle(); main.recent_menu = menu
	menu._activate(Menu.NAV_BASE+Menu.Section.WEB)
	var browser: RefCounted = menu.web_browser
	browser.window_created = func(window): main._connect_session_controls(window.effect_controls)
	browser.open("https://example.test/page"); browser.tick()
	var window: Node3D = browser.windows[1]; window.reparent(view); window.set_process(false)
	window.global_transform = Transform3D(Basis.IDENTITY,Vector3(-.13,.2,-2))
	var footer: Node3D = window.effect_controls
	footer.app_actions.now_provider = func(): return 10000
	footer.near_hands.right_hand = true; footer.entered = 0; footer.sync(1000)
	footer.device_status.clock_provider = func(): return {"hour":21,"minute":36}
	footer.device_status.status_provider = func(): return {"level":87,"charging":false,"clock24":true}
	footer.device_status.refresh(true)
	for language in ["zh","zh_Hant","en","ja"]:
		I18n.use(language)
		for theme in ["default","pearl"]:
			Palette.use(theme)
			for frame in 3: await process_frame
			main.hall = true; footer.refresh(); footer.sync(1000)
			footer.device_status.refresh(true)
			camera.global_transform = footer.global_transform * Transform3D(Basis.IDENTITY,Vector3(.08,-.10,1.5))
			await capture(language+"-"+theme+"-scene")
			footer.app_actions.activate(footer.app_actions.STATUS,"right_hand")
			footer.app_actions.activate(footer.app_actions.QUIT,"right_hand")
			camera.global_transform = footer.global_transform * Transform3D(Basis.IDENTITY,Vector3(.08,-.18,1.5))
			await capture(language+"-"+theme+"-confirm")
			footer.app_actions.reset()
	I18n.use("zh"); Palette.use("default"); main.hall = false
	for frame in 3: await process_frame
	window.depth.enabled = true; window.depth.state = "ready"
	footer.strength_open = true; footer.refresh(); footer.sync(1000)
	camera.size = 1.3; camera.global_transform = footer.global_transform * Transform3D(Basis.IDENTITY,Vector3(0,.15,1.5))
	await capture("strength-and-footer")
	window.depth.enabled = false; footer.sync(1000)
	camera.size = 2.15; camera.global_transform = Transform3D(Basis.IDENTITY,Vector3(0,-.1,1))
	window.set_toolbar_shown(false); footer.sync(1000)
	await capture("pure-page")
	window.set_toolbar_shown(true); window.refresh()
	platform.browser.windows = [{"id":1,"tab_id":1,"url":"https://example.test/1"},{"id":2,"tab_id":2,"url":"https://example.test/2"}]
	platform.browser.tab_list = [{"id":1,"window":1},{"id":2,"window":2}]
	browser.next_poll = 0; browser.tick()
	var second: Node3D = browser.windows[2]; second.reparent(view); second.set_process(false)
	window.global_transform = Transform3D(Basis.IDENTITY,Vector3(-1.1,.3,-2))
	second.global_transform = Transform3D(Basis.IDENTITY,Vector3(.65,.3,-2))
	for peer in [window,second]:
		peer.refresh(); peer.effect_controls.near_hands.right_hand = true; peer.effect_controls.entered = 0; peer.effect_controls.sync(1000)
	camera.size = 2.7; await capture("two-windows")
	second.visible = false
	browser.cinema_provider = func(): return {"position":[0,3,-12],"width":10.0,"height":5.625}
	window.set_mode("cinema"); window.refresh(); main.hall = true; footer.sync(1000)
	camera.size = 1.55; camera.global_transform = window.global_transform * Transform3D(Basis.IDENTITY,Vector3(.13,.36,1.5))
	await capture("projected-near-menu")
	window.depth.enabled = true; window.depth.state = "ready"; footer.strength_open = true; footer.refresh(); footer.sync(1000)
	await capture("projected-near-strength")
	menu.free(); platform.free(); main.free(); view.free(); await process_frame
	print("Browser global footer render: %d images, %d failures" % [count,failures.size()])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)
