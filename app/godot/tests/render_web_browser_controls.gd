extends SceneTree
const Menu:=preload("res://scripts/library_menu.gd")
const Fixture:=preload("res://tests/test_web_browser_panel.gd")
const I18n:=preload("res://scripts/i18n.gd")
var output:=ProjectSettings.globalize_path("res://../../build/output/browser-controls/preview")
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
	var browser: RefCounted=menu.web_browser; browser.open("https://example.test/search"); browser.tick()
	var host: Node3D=browser.windows[1]; host.reparent(view)
	host.global_transform=Transform3D(Basis.IDENTITY,Vector3(-.13,0,-1.65)); host.set_process(false)
	var footer: Node3D=host.effect_controls
	for language in ["zh","zh_Hant","en","ja"]:
		I18n.use(language)
		for enabled in [false,true]:
			host.depth.auto_3d_hidden=enabled; host.depth_settings=true; host.refresh()
			footer.near_hands.right=true; footer.entered=0; footer.sync(1000)
			var toggle: Array=host.depth_choices.targets.values().filter(func(item): return item.key=="auto_3d_hidden")
			if toggle.size()!=1: failures.append("Missing switch "+language)
			for button in host._buttons:
				if not button.node.has_meta("browser_effect_priority"): continue
				if button.rect.position.x < -.36 or button.rect.end.x > .62: failures.append("Control outside narrow popup "+language)
				for child in button.node.get_children():
					if child is Label3D and not child.text.is_empty():
						var width: float=host.ui_font().get_string_size(child.text,HORIZONTAL_ALIGNMENT_LEFT,-1,child.font_size).x*child.pixel_size
						if width>button.rect.size.x-.012: failures.append("Control label overflow "+language+": "+child.text)
			await capture("settings-%s-%s"%[language,"on" if enabled else "off"])
	host.depth_settings=false; I18n.use("zh"); host.refresh()
	for shown in [false,true]:
		platform.browser.keyboard_visible=shown; browser.next_poll=0; browser.tick(); footer.sync(1000)
		await capture("keyboard-%s"%("on" if shown else "off"))
	host.depth.auto_3d_hidden=false; host.sync_fullscreen({"tab_id":7,"navigation":3,"fullscreen":true})
	footer.near_hands.right=true; footer.entered=0; footer.sync(1000)
	await capture("fullscreen-menus-hidden")
	menu.free(); platform.free(); view.free()
	for failure in failures: push_error(failure)
	print("Browser controls render: %d images, %d failures"%[count,failures.size()])
	quit(0 if failures.is_empty() else 1)
