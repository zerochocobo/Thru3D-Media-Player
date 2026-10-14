extends SceneTree
const Menu := preload("res://scripts/library_menu.gd")
const Paging := preload("res://tests/test_cloud_pagination.gd")
const I18n := preload("res://scripts/i18n.gd")
var checks := 0
var failures: Array[String] = []

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func _initialize() -> void: call_deferred("_run")

func _run() -> void:
	var output := ProjectSettings.globalize_path("res://../previews")
	DirAccess.make_dir_recursive_absolute(output)
	var viewport := SubViewport.new(); viewport.size = Vector2i(1500, 1000); viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS; root.add_child(viewport)
	var camera := Camera3D.new(); camera.fov = 55; viewport.add_child(camera)
	var platform := Paging.Platform.new()
	var menu := Menu.new(); camera.add_child(menu); menu.attach_platform(platform); menu.toggle(); menu.position.z = -1.55
	menu._activate(Menu.NAV_BASE + Menu.Section.CLOUD); platform.respond(1)
	menu._choose(menu.rows[0]); platform.respond(2)
	var long_reason := "list115.list\n115 code: 430004, message: 文件夹不存在或无权限。 " + "服务器返回的完整错误信息在这里显示，可滚动查看。".repeat(12) + " END"
	for language in ["en", "zh", "zh_Hant", "ja"]:
		I18n.use(language)
		for compact in [false, true]:
			menu.set_compact(compact); menu.status = "Cloud connection failed"
			menu.cloud_error.receive({"error": menu.status, "error_reason": "cloud_unavailable", "offset": 48, "error_detail": long_reason})
			for state in ["footer", "detail", "last"]:
				if state == "footer": menu.refresh()
				elif state == "detail": menu._activate(Menu.CloudBrowseError.OPEN)
				else: menu._set_scroll(menu._max_scroll())
				check(menu.text_snapshot().contains("115 430004") if state == "footer" else menu.cloud_error.opened, "Error entry and detail are visible")
				if state != "footer":
					for button in menu._buttons:
						if button.node.get_parent() == menu._list:
							for label in button.node.get_children():
								if label is Label3D:
									check(menu.text_width(label.text, 19) <= (0.99 if compact else 1.15), "Wrapped text fits without truncation")
				await process_frame
				await RenderingServer.frame_post_draw
				check(viewport.get_texture().get_image().save_png(output.path_join("%s-%s-%s.png" % [language, "compact" if compact else "full", state])) == OK, "Preview saved")
			menu.cloud_error.close(); menu.refresh()
	menu.free(); platform.free(); viewport.free()
	print("cloud error render checks=%d failures=%d" % [checks, failures.size()])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)
