extends SceneTree
const Menu := preload("res://scripts/player_menu.gd")
const I18n := preload("res://scripts/i18n.gd")
var failures: Array[String] = []
func _initialize() -> void: run.call_deferred()
func run() -> void:
	var output := ProjectSettings.globalize_path("res://../../build/output/portrait-distance-menu")
	DirAccess.make_dir_recursive_absolute(output)
	var view := SubViewport.new(); view.size = Vector2i(1440,1600); view.own_world_3d = true
	view.render_target_update_mode = SubViewport.UPDATE_ALWAYS; root.add_child(view)
	var camera := Camera3D.new(); camera.projection = Camera3D.PROJECTION_ORTHOGONAL; camera.size = 2.0
	camera.position = Vector3(0,0.75,2); view.add_child(camera)
	var menu := Menu.new(); view.add_child(menu); menu.set_process(false)
	var state := {"has_video":true,"geometry":0,"stereo":false,"alpha_requested":true,"flat_passthrough_requested":true,
		"portrait_requested":true,"portrait_auto":false,"portrait_distance":18.4,"portrait_scale":600.0,"playing":true,"alpha_fps":30}
	menu.state_provider = func(): return state
	menu.section = 1; menu.visible = true
	for stereo in [false,true]:
		state.stereo = stereo; state.portrait_requested = not stereo
		for language in ["zh","zh_Hant","en","ja"]:
			I18n.use(language)
			for expanded in [false,true]:
				menu._alpha_expanded = expanded; menu.refresh()
				if not menu._adjust_rows.has(457): failures.append("Missing distance slider: " + language)
				elif menu._adjust_rows[457].label.text != "18.4 m": failures.append("Distance value: " + language)
				if not menu._adjust_rows.has(Menu.PORTRAIT_SIZE): failures.append("Missing size slider: " + language)
				elif menu._adjust_rows[Menu.PORTRAIT_SIZE].label.text != "600%": failures.append("Size value: " + language)
				if menu._adjust_rows.has(Menu.ALPHA_GROUP): failures.append("Alpha fold header intercepted by a slider")
				if menu._buttons.filter(func(button): return button.target == Menu.PORTRAIT_SIZE).size() != 1: failures.append("Size slider target is not unique")
				if stereo and (menu.text_snapshot().contains(I18n.t("Automatic distance")) or menu.text_snapshot().contains(I18n.t("Detailed depth"))): failures.append("Mono depth controls leaked into native stereo")
				await RenderingServer.frame_post_draw; await RenderingServer.frame_post_draw
				view.get_texture().get_image().save_png(output.path_join(language + ("-stereo" if stereo else "") + ("-expanded" if expanded else "") + ".png"))
	menu.state_provider = func(): return {"has_video":true,"geometry":0,"stereo":false,"portrait_requested":false}
	menu.refresh()
	if menu._adjust_rows.has(457): failures.append("Portrait control leaked into ordinary video")
	if menu._adjust_rows.has(Menu.PORTRAIT_SIZE): failures.append("Portrait size leaked into ordinary video")
	view.free()
	for failure in failures: push_error(failure)
	print("Portrait distance menu: 17 states, %d failures" % failures.size())
	quit(0 if failures.is_empty() else 1)
