extends "res://tests/render_cinema_player.gd"
## Fixed views of the cottage in the production main scene, for before/after art and culling checks.
## Args: <output dir>
const VIEWS := [
	["front", Vector3(0,1.15,1.82), Vector3(0,1.6,-4.)],
	["left", Vector3(0,1.15,1.82), Vector3(-4.,1.3,0.)],
	["right", Vector3(0,1.15,1.82), Vector3(4.,1.3,0.)],
	["front-left", Vector3(0,1.15,1.82), Vector3(-3.,1.2,-3.)],
	["front-right", Vector3(0,1.15,1.82), Vector3(3.,1.2,-3.)],
	["behind", Vector3(0,1.15,1.82), Vector3(0,1.0,5.)],
	["up", Vector3(0,1.15,1.82), Vector3(0,4.5,-1.5)],
	["corner", Vector3(-3.6,1.6,-3.8), Vector3(2.,1.,1.5)],
	["hearth", Vector3(2.4,1.3,-.2), Vector3(3.96,1.09,-.94)],
	["brew", Vector3(3.35,1.85,-.55), Vector3(3.96,1.05,-.94)],
	["bottles", Vector3(2.9,1.75,-2.3), Vector3(4.1,1.7,-3.0)],
]

func _run() -> void:
	var args := OS.get_cmdline_user_args()
	output = args[0]
	DirAccess.make_dir_recursive_absolute(output)
	var config := ConfigFile.new()
	config.set_value("appearance","background","dark")
	config.save(output.path_join("settings.cfg"))
	viewport = SubViewport.new()
	viewport.size = Vector2i(1280,720)
	viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	main = RenderMain.new()
	main.settings_path = output.path_join("settings.cfg")
	main.display = Logic.SupportedDisplay.new()
	viewport.add_child(main)
	main.set_process(false)
	main.report_timer.stop()
	main.video.set_process(false)
	main.photo.set_process(false)
	main.video.history_enabled = false
	_close_menus()
	main.scenery.select("global","magic_cottage")
	for frame in 600:
		if main.cottage: break
		if not main._cottage_pending.is_empty(): main._sync_cottage(main._cottage_pending[0],main._cottage_pending[1])
		await process_frame
	for i in 4: await process_frame
	main._tick_cottage(.02)
	var room: Transform3D = main.cottage.room.global_transform
	for view in VIEWS:
		main.xr_camera.global_position = room * Vector3(view[1])
		main.xr_camera.look_at(room * Vector3(view[2]), Vector3.UP)
		await _shot(view[0])
	# A hand pointing at the herbal from the right knee: wand, focus lamp and any world pointer.
	main.xr_camera.global_position = room * Vector3(0,1.15,1.82)
	main.xr_camera.look_at(room * Vector3(-2.,1.3,-.5), Vector3.UP)
	var hand := room * Vector3(.22,.88,1.45)
	main.rays.right_hand = [hand, (room * Vector3(main.cottage.homes["Herbal"]) - hand).normalized()]
	main.controller_feedback.wake("right_hand", "shortcut")
	for i in 3:
		main._tick_cottage(.02)
		main._update_controller_feedback(.016)
	await _shot("pointing")
	main.rays.clear()
	viewport.queue_free()
	await process_frame
	quit(0)
