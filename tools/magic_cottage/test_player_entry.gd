extends "res://tests/test_cinema_player_integration.gd"
## Exercise the scenery picker's actual select/commit and the player's trigger ownership.
func _run() -> void:
	output = OS.get_cmdline_user_args()[0]
	DirAccess.make_dir_recursive_absolute(output)
	var config:=ConfigFile.new()
	config.set_value("appearance","background","dark")
	config.save(output.path_join("settings.cfg"))
	viewport=SubViewport.new()
	viewport.own_world_3d=true
	root.add_child(viewport)
	main=InputMain.new()
	main.settings_path=output.path_join("settings.cfg")
	main.display=SupportedDisplay.new()
	viewport.add_child(main)
	main.set_process(false)
	main.report_timer.stop()
	main.video.set_process(false)
	main.photo.set_process(false)
	main.video.history_enabled=false
	main.video.platform=HostTest.Host.new()
	main.video.local_uri="file:///cottage-test.mp4"
	main.video.media.begin(7)
	main.video.media.state="playing"
	main.video.media.format.width=1920
	main.video.media.format.height=1080
	main.video.requested_play=true
	main.video._waiting_first=false
	main.video.screen_rotation=12.
	main.video._apply_geometry()
	main.video.panel.visible=true
	_close_menus()
	main.scenery.select("global","magic_cottage")
	for frame in 600:
		if main.cottage: break
		if not main._cottage_pending.is_empty(): main._sync_cottage(main._cottage_pending[0],main._cottage_pending[1])
		await process_frame
	for frame in 5: await process_frame
	check(main.background.choice=="magic_cottage" and main.cottage!=null,"Picker commits built-in cottage")
	if main.cottage==null:
		await _finish()
		return
	main._tick_cottage(.02)
	main._sync_cinema_screen()
	var w: Node3D=main.cottage
	check(w.visible and w.aligned,"Seated placement from tracked eye")
	check(is_equal_approx(main.video._flat.size.x,4.5) and w.movie,"Player surface fits portal")
	check(not main._cinema_video_locked() and main._screen_rotation_allowed(),"Flat film accepts normal rotation control")
	var base: BaseMaterial3D=w.room_materials.keys()[0]
	main._tick_cottage(1.)
	check(is_equal_approx(w.light_fraction,.25) and is_equal_approx(w.skies[1].get_shader_parameter("brightness"),.25) and w.room_materials[base].albedo_color.r < base.albedo_color.r,"Playback dims room materials and windows")
	main.video.media.state="paused"
	main._tick_cottage(1.)
	check(is_equal_approx(w.light_fraction,1.),"Paused film restores room lights")
	main.video.media.state="playing"
	main.scenery._command("adjust",{"mode":"global","key":"cottage_play_dim","value":1.})
	main._tick_cottage(1.)
	check(is_equal_approx(w.light_fraction,1.),"Scene setting disables automatic dimming")
	main.scenery_menu.mode="global"
	main.scenery_menu.view="adjust"
	main.scenery_menu.refresh()
	main.scenery_menu._activate(main.scenery_menu.COTTAGE_SCREEN)
	check(main.scenery_menu.view=="cottage_screen" and main.scenery_menu.choices.sliders.size()>=4,"Scenery card opens the four placement limits")
	main.scenery_menu._choice_changed("cottage_near",2.)
	main.scenery_menu._choice_changed("cottage_far",5.)
	main.scenery_menu._choice_changed("cottage_minimum",45.)
	main.scenery_menu._choice_changed("cottage_maximum",115.)
	main._push_screen(-20.)
	main._sync_cinema_screen()
	check(is_equal_approx(main._cottage_screen.SEAT.z-w.film_pose.origin.z,2.),"Near limit acts on the normal distance gesture",w.film_pose.origin)
	main._push_screen(25.)
	main._sync_cinema_screen()
	check(is_equal_approx(main._cottage_screen.SEAT.z-w.film_pose.origin.z,5.),"Far limit acts on the normal distance gesture")
	main._zoom_video(4.)
	main._sync_cinema_screen()
	check(is_equal_approx(w.film_size.x,4.5*1.15),"Maximum size acts on the normal zoom gesture")
	main._zoom_video(-4.)
	main._sync_cinema_screen()
	check(is_equal_approx(w.film_size.x,4.5*.45),"Minimum size acts on the normal zoom gesture")
	main._turn_picture(-.28,.08)
	main._on_playback_adjustment("screen_rotation",90.)
	main._save_screen()
	var custom: Transform3D=w.film_pose
	check(custom.origin.x>.5 and is_equal_approx(main.video.screen_rotation,90.),"Drag and rotation survive the next placement update")
	var aimed:=Vector3(w.SEAT)
	check(w.film_in_ray([aimed,(custom.origin-aimed).normalized()]),"Ray follows moved and rotated picture")
	var underneath:=custom*Vector3(0.,w.film_size.y*.5+.2,0.)
	check(not w.film_in_ray([aimed,(underneath-aimed).normalized()]),"Points outside the rotated film remain interactive")
	var stored:=ConfigFile.new()
	stored.load(main.settings_path)
	check(stored.has_section_key("magic_cottage","pose") and is_equal_approx(stored.get_value("magic_cottage","rotation"),90.),"Gesture saved to cottage preferences")
	main.settings.set_value("screen","default_view",Vector2(2.1,.8))
	main._recenter()
	check(w.film_pose.is_equal_approx(custom),"Recentering follows the room without applying ordinary screen defaults")
	main.settings.erase_section_key("screen","default_view")
	main._on_playback_adjustment("screen_scale",75.)
	main._on_playback_adjustment("screen_distance",3.)
	main._on_playback_adjustment("screen_rotation",28.)
	main._sync_cinema_screen()
	var shown: Dictionary=main._menu_state()
	check(is_equal_approx(shown.screen_scale,75.) and is_equal_approx(shown.screen_distance,3.) and is_equal_approx(shown.screen_rotation,28.),"Playback sliders report arch-relative size, depth and exact angle")
	var watched: Transform3D=w.film_pose
	var jug: Vector3=w.targets.Jug[0]
	var in_front := Transform3D(Basis.IDENTITY,w.SEAT.lerp(jug,.4))
	main.video.set_flat_world_pose(w.room.global_transform*in_front)
	main._sync_cinema_screen()
	var prop_ray: Array=[w.room.to_global(w.SEAT),w.room.global_basis*(jug-w.SEAT).normalized()]
	check(w.target(prop_ray)=="" and not w.press("right_hand",prop_ray),"Moving the film in front of the jug gives the film the trigger")
	main.video.set_flat_world_pose(w.room.global_transform*watched*Transform3D(Basis(Vector3.FORWARD,-deg_to_rad(28.)),Vector3.ZERO))
	main._save_screen()
	main.video.media.state="ended"
	main.video.requested_play=false
	main._sync_cinema_screen()
	main._tick_cottage(1.)
	check(not w.movie and not main._cottage_screen.attached and is_equal_approx(main.video.screen_rotation,12.),"End of film releases screen and restores star mirror")
	var head: Vector3=main.xr_camera.global_position
	main.rays.right_hand=[head,(w.room.to_global(w.ARCH)-head).normalized()]
	main._route_controller_button("trigger_click","right_hand")
	main._route_controller_release("trigger_click","right_hand")
	check(main.recent_menu.visible,"Clicking the idle star mirror opens the player's file library")
	_close_menus()
	main.video.media.begin(8)
	main.video.media.state="playing"
	main.video.requested_play=true
	main._sync_cinema_screen()
	main._tick_cottage(.02)
	check(w.film_pose.is_equal_approx(watched) and is_equal_approx(main._cottage_screen.factor,.75),"New presentation reloads saved room placement")
	main.screen_edit_lock.set_locked(true)
	main._on_playback_adjustment("screen_rotation",0.)
	main._zoom_video(.5)
	main._sync_cinema_screen()
	check(w.film_pose.is_equal_approx(watched) and is_equal_approx(main._cottage_screen.factor,.75),"Screen lock guards rotation and resize inside cottage")
	main.screen_edit_lock.set_locked(false)
	main.scenery_menu._choice_changed("cottage_far",6.6)
	main.scenery_menu._activate(main.scenery_menu.COTTAGE_RESET)
	check(w.film_pose.origin.is_equal_approx(main._cottage_screen.HOME.origin) and is_zero_approx(main.video.screen_rotation),"Reset returns film to the front arch")
	main.scenery_menu.navigate_back()
	for hand in ["left_hand","right_hand"]:
		var p: Vector3=w.room.to_global(w.targets.Jug[0])
		var origin: Vector3=main.xr_camera.global_position
		main.rays[hand]=[origin,(p-origin).normalized()]
		var accepted: String=main._route_controller_button("trigger_click",hand)
		check(accepted=="handled.cottage" and w.held.has(hand),"Real trigger press "+hand,accepted)
		p=w.room.to_global(w.targets.Plant[0])
		main.rays[hand]=[origin,(p-origin).normalized()]
		for i in 50: main._tick_cottage(.02)
		check(w.archive.wet,"Actual held ray waters the plant")
		var released: String=main._route_controller_release("trigger_click",hand)
		check(released=="handled.cottage_release" and w.held.is_empty(),"Trigger release "+hand,released)
	for id in [0,2,5]: w.deposit(id)
	for hand in ["left_hand","right_hand"]:
		var origin: Vector3=main.xr_camera.global_position
		var pillar: Vector3=w.room.to_global(Vector3(2.73,2.64,-4.90))
		main.rays[hand]=[origin,(pillar-origin).normalized()]
		main._tick_cottage(.33)
		var before: int=w.magic.marks.size()
		check(main._route_controller_button("trigger_click",hand)=="handled.cottage" and w.magic.marks.size()==before+1,"Actual wand trigger launches one fireball "+hand)
		check(main._route_controller_release("trigger_click",hand)=="handled.cottage_release","Magic releases through player input "+hand)
	main.temporary_passthrough=true
	main._update_background()
	check(not w.visible and main.cottage==w,"Temporary camera suspends the same specimen")
	main.temporary_passthrough=false
	main._update_background()
	check(w.visible and w.archive.wet,"Return keeps the watered specimen")
	main.scenery.select("global","dark")
	for i in 4: await process_frame
	check(main.cottage==null and main._cinema_screen_saved.is_empty(),"Leaving releases room and screen mount")
	check(is_equal_approx(main.video.screen_rotation,12.) and is_equal_approx(main.video.screen_scale,1.),"Ordinary screen rotation and scale restored")
	main.scenery.select("global","magic_cottage")
	for frame in 600:
		if main.cottage: break
		if not main._cottage_pending.is_empty(): main._sync_cottage(main._cottage_pending[0],main._cottage_pending[1])
		await process_frame
	for i in 4: await process_frame
	check(main.cottage!=null and not main.cottage.archive.wet and main.cottage.archive.stage==0,"Selecting afresh starts a sprout")
	main.scenery.select("global","dark")
	for i in 4: await process_frame
	await _finish()
