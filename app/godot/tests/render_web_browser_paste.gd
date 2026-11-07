extends SceneTree
const Menu := preload("res://scripts/library_menu.gd")
const Fixture := preload("res://tests/test_web_browser_paste.gd")
const I18n := preload("res://scripts/i18n.gd")
var output := ProjectSettings.globalize_path("res://../../build/output/browser-paste/preview")
var view: SubViewport
var count := 0
var failures: Array[String] = []
func _initialize() -> void: run.call_deferred()
func capture(name: String) -> void:
	for frame in 3: await process_frame; await RenderingServer.frame_post_draw
	var pixels := view.get_texture().get_image()
	if pixels.save_png(output.path_join(name+".png"))!=OK: failures.append(name)
	count+=1
func run() -> void:
	DirAccess.make_dir_recursive_absolute(output)
	view=SubViewport.new();view.size=Vector2i(1600,1200);view.own_world_3d=true
	view.render_target_update_mode=SubViewport.UPDATE_ALWAYS;root.add_child(view)
	var camera:=Camera3D.new();camera.fov=58;view.add_child(camera)
	var menu:=Menu.new();view.add_child(menu);menu.set_process(false);menu.position=Vector3(-.13,0,-1.65)
	var platform:=Fixture.Platform.new();menu.attach_platform(platform);menu.toggle();menu._activate(Menu.NAV_BASE+Menu.Section.WEB)
	menu.web_video.address="https://www.bilibili.com/video/BV1xx411c7mD/?"+"tracking=123456789&".repeat(8)
	for language in ["zh","zh_Hant","en","ja"]:
		I18n.use(language);menu.refresh();await capture("home-"+language)
	var browser: RefCounted=menu.web_browser
	browser.open("https://www.bilibili.com/video/BV1xx411c7mD/");browser.next_poll=0;browser.tick()
	var host: Node3D=browser.windows[1];host.reparent(view);host.set_process(false)
	browser.cinema_provider=func():return {"position":[0,3,-12],"width":10.0,"height":5.625,"yaw":0.0}
	for mode in ["floating","cinema"]:
		host.set_mode(mode)
		# Keep the actual chrome close and front-facing for typography inspection.
		host.global_transform=Transform3D(Basis.IDENTITY,Vector3(-.13,-.15,-1.65))
		for language in ["zh","zh_Hant","en","ja"]:
			I18n.use(language);host.refresh();await capture(mode+"-"+language)
	host.set_mode("floating");host.global_transform=Transform3D(Basis.IDENTITY,Vector3(-.13,-.15,-1.65))
	platform.clipboard="https://example.test/"+"long-path/".repeat(30)
	host._activate(browser.PASTE);await capture("floating-pasted")
	menu.free();platform.free();view.free();await process_frame
	for failure in failures:push_error(failure)
	print("Browser paste render: %d images, %d failures"%[count,failures.size()])
	quit(0 if failures.is_empty() else 1)
