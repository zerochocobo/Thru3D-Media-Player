extends SceneTree
const Menu := preload("res://scripts/library_menu.gd")
const Palette := preload("res://scripts/ui_theme.gd")
const I18n := preload("res://scripts/i18n.gd")
const Usage := preload("res://scripts/session_usage.gd")
var output := ProjectSettings.globalize_path("res://../../build/output/app-actions/visuals")
func _initialize() -> void: run.call_deferred()
func capture(view: SubViewport, name: String) -> void:
	for index in 4: await process_frame; await RenderingServer.frame_post_draw
	view.get_texture().get_image().save_png(output.path_join(name + ".png"))
func run() -> void:
	DirAccess.make_dir_recursive_absolute(output)
	var view := SubViewport.new(); view.size = Vector2i(1400, 650); view.own_world_3d = true
	view.render_target_update_mode = SubViewport.UPDATE_ALWAYS; root.add_child(view)
	var camera := Camera3D.new(); camera.projection = Camera3D.PROJECTION_ORTHOGONAL; camera.size = 0.42; view.add_child(camera)
	var menu := Menu.new(); view.add_child(menu); menu.toggle(); menu.set_process(false); menu.app_actions.set_process(false)
	menu.device_status.status_provider = func(): return {"level": 73, "clock24": true}
	menu.device_status.clock_provider = func(): return {"hour": 21, "minute": 30}
	Usage.start(Time.get_ticks_msec() - 83 * 60000)
	for language in ["zh", "zh_Hant", "ja", "en"]:
		I18n.use(language)
		for theme in ["default", "pearl"]:
			Palette.use(theme)
			for frame in 3: await process_frame
			menu.refresh(); menu.device_status.refresh(true)
			camera.position = menu.to_global(Vector3(menu._footer_centre.x, menu._footer_centre.y - 0.10, 0.80))
			for state in ["collapsed", "expanded", "confirm", "busy", "error"]:
				menu.app_actions.reset()
				if state != "collapsed":
					menu.app_actions.activate(menu.app_actions.STATUS, "desktop")
				if state in ["confirm", "busy", "error"]:
					menu.app_actions.activate(menu.app_actions.QUIT, "desktop")
				if state in ["busy", "error"]:
					menu.app_actions.release("desktop")
					menu.app_actions.activate(menu.app_actions.QUIT, "desktop")
				if state == "error": menu.app_actions.failed()
				await capture(view, language + "-" + theme + "-" + state)
	# A full production settings page verifies placement relative to existing controls.
	I18n.use("zh"); Palette.use("default")
	for frame in 3: await process_frame
	menu.section = menu.Section.SETTINGS; menu.refresh()
	menu.app_actions.reset()
	menu.app_actions.activate(menu.app_actions.STATUS, "desktop")
	menu.app_actions.activate(menu.QUIT_APP, "desktop")
	view.size = Vector2i(1400, 1400); camera.size = 2.20
	camera.position = menu.to_global(Vector3(-0.12, -0.12, 0.80))
	await capture(view, "settings-full")
	view.free(); await process_frame; Palette.use("default"); I18n.use("auto")
	print("App actions visuals: 41 production renders saved to ", output)
	quit()
