extends SceneTree
## The browser's settings popup (2D to 3D group, pause while opening the player, page clarity), in each language.
const Menu:=preload("res://scripts/library_menu.gd")
const Fixture:=preload("res://tests/test_web_browser_panel.gd")
const I18n:=preload("res://scripts/i18n.gd")
var output:=ProjectSettings.globalize_path("res://../../build/output/browser-settings-menu")
var view: SubViewport
var count:=0
var failures: Array[String]=[]
func _initialize() -> void: run.call_deferred()
func capture(name: String) -> void:
	for frame in 3: await process_frame; await RenderingServer.frame_post_draw
	if view.get_texture().get_image().save_png(output.path_join(name+".png"))!=OK: failures.append(name)
	count+=1
func run() -> void:
	DirAccess.make_dir_recursive_absolute(output)
	view=SubViewport.new(); view.size=Vector2i(1600,1200); view.own_world_3d=true
	view.render_target_update_mode=SubViewport.UPDATE_ALWAYS; root.add_child(view)
	var camera:=Camera3D.new(); camera.fov=70; camera.position=Vector3(0,-.1,.3); view.add_child(camera)
	var menu:=Menu.new(); camera.add_child(menu); menu.set_process(false)
	var platform:=Fixture.Platform.new(); platform.browser.merge({"tab_id":7,"navigation":3,"keyboard_visible":false},true)
	menu.attach_platform(platform); menu.toggle(); menu._activate(Menu.NAV_BASE+Menu.Section.WEB)
	var browser: RefCounted=menu.web_browser; browser.open("https://example.test/watch"); browser.tick()
	var host: Node3D=browser.windows[1]; host.reparent(view)
	host.global_transform=Transform3D(Basis.IDENTITY,Vector3(-.13,0,-1.65)); host.set_process(false)
	for language in ["zh","zh_Hant","en","ja"]:
		I18n.use(language)
		for expanded in [false,true]:
			browser.pause_on_handoff=expanded
			host.depth_settings=true; host.depth_expanded=expanded; host.refresh()
			var title: String=I18n.t("Pause page while opening player")
			var width: float=host.ui_font().get_string_size(title,HORIZONTAL_ALIGNMENT_LEFT,-1,20).x*0.001
			# The row's label starts at -0.30 and its switch sits at 0.50.
			if width>0.72: failures.append("Pause label reaches its switch "+language)
			await capture("settings-%s-%s"%[language,"expanded" if expanded else "collapsed"])
	menu.free(); platform.free(); view.free()
	for failure in failures: push_error(failure)
	print("Browser settings menu render: %d images, %d failures"%[count,failures.size()])
	quit(0 if failures.is_empty() else 1)
