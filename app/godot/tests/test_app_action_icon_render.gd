extends SceneTree

# Run with a real renderer, --xr-mode off; no headset or Android build needed.
const Menu := preload("res://scripts/library_menu.gd")
const Actions := preload("res://scripts/app_actions.gd")
var failures: Array[String] = []
var checks := 0
var output := ProjectSettings.globalize_path("res://../../build/output/app-actions/icon-render")

func _initialize() -> void: run.call_deferred()

func frame(view: SubViewport) -> Image:
	for index in 4:
		await process_frame
		await RenderingServer.frame_post_draw
	return view.get_texture().get_image()

func run() -> void:
	DirAccess.make_dir_recursive_absolute(output)
	var view := SubViewport.new()
	view.size = Vector2i(800, 600); view.own_world_3d = true
	view.render_target_update_mode = SubViewport.UPDATE_ALWAYS; root.add_child(view)
	var camera := Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL; camera.size = 0.42
	view.add_child(camera)
	var menu := Menu.new(); view.add_child(menu); menu.toggle()
	menu.set_process(false); menu.app_actions.set_process(false)
	for overlay in [false, true]:
		menu.set_scene_overlay(overlay)
		for state in ["idle", "restart", "quit"]:
			menu.app_actions.reset(); menu.app_actions.activate(Actions.STATUS, "desktop")
			if state != "idle": menu.app_actions.activate(Actions.RESTART if state == "restart" else Actions.QUIT, "desktop")
			var icons: Array[MeshInstance3D] = []
			for button in menu._buttons:
				if button.target in [Actions.RESTART, Actions.QUIT]: icons.append(button.node.get_child(1))
			var centre: Vector3 = menu.app_actions._panel.global_position
			for angle in [-45, 0, 45]:
				camera.position = centre + Vector3(0, sin(deg_to_rad(angle)), cos(deg_to_rad(angle))) * 0.8
				camera.look_at(centre)
				var tag := "%s-%s-%s" % [overlay, state, angle]
				var visible_image := await frame(view)
				visible_image.save_png(output.path_join(tag + ".png"))
				for icon in icons: icon.hide()
				var hidden_image := await frame(view)
				for icon in icons:
					var pixels := 0
					var point := camera.unproject_position(icon.global_position)
					for y in range(maxi(0, int(point.y) - 28), mini(view.size.y, int(point.y) + 28)):
						for x in range(maxi(0, int(point.x) - 28), mini(view.size.x, int(point.x) + 28)):
							var a := visible_image.get_pixel(x, y)
							var b := hidden_image.get_pixel(x, y)
							if Vector3(a.r - b.r, a.g - b.g, a.b - b.b).length() > 0.15: pixels += 1
					checks += 1
					if pixels < 20: failures.append("%s icon %d is obscured (%d visible pixels)" % [tag, icons.find(icon), pixels])
					icon.show()
	view.free(); await process_frame
	for failure in failures: printerr(failure)
	print("App action icon render: %d checks, %d failures" % [checks, failures.size()])
	quit(1 if not failures.is_empty() else 0)
