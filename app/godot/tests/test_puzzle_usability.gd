extends SceneTree
const Main := preload("res://scripts/main.gd")
const Store := preload("res://scripts/puzzle/puzzle_store.gd")
const Session := preload("res://scripts/puzzle/puzzle_session.gd")
const Memory := preload("res://scripts/file_mode_memory.gd")
const Composition := preload("res://scripts/menu_composition.gd")
var checks := 0
var failures: Array[String]=[]
var output := ProjectSettings.globalize_path("res://../../build/output/puzzle-usability/run-")+str(Time.get_ticks_usec())
func _initialize() -> void: call_deferred("_run")
func check(ok: bool,message: String) -> void:
	checks+=1
	if not ok: failures.append(message); push_error(message)
func ready_game(host: Node) -> bool:
	var deadline := Time.get_ticks_msec()+15000
	while host.active and host.panel.preparing and Time.get_ticks_msec()<deadline: await create_timer(0.01).timeout
	return host.session!=null and host.saving_ready
func acquire(model: Node,piece: MeshInstance3D,optical: bool = false,near_hand: bool = false) -> bool:
	var front := piece.global_basis.z.normalized(); var origin := piece.global_position+front*0.3
	# The optical wrist axis points away from the viewer in this physical pose.
	var wrist := Basis.looking_at(front,Vector3.UP if absf(front.y)<0.98 else Vector3.RIGHT)
	return model.grab("right",origin,-front,Transform3D(wrist,origin),false,optical,near_hand)
func aim(model: Node,piece: MeshInstance3D,pose: Transform3D = Transform3D.IDENTITY) -> void:
	var point: Vector3=model.to_global(piece.goal*model.captures.right.anchor)
	var origin: Vector3=model.global_position if model.spherical else point+model.frame_world_pose().basis.z.normalized()
	model.update_grab("right",origin,(point-origin).normalized(),pose)
func source(image: Image,sphere: bool = false) -> Dictionary:
	return {"image":image,"texture":ImageTexture.create_from_image(image),"size":Vector2(image.get_width(),image.get_height()),"projection":"sphere" if sphere else "flat","uri":"file:///offline/same.png","title":"same.png","kind":"flat"}

func frame_clear(model: Node) -> bool:
	var inverse: Transform3D=model.frame_pose.affine_inverse(); var eye: Vector3=inverse*model.viewer_position
	for piece in model.pieces:
		if piece.placed or not piece.tray_visible: continue
		for corner in 8:
			var point: Vector3=inverse*(piece.transform*piece.mesh.get_aabb().get_endpoint(corner))
			var ray := point-eye
			if ray.z>=-0.0001: continue
			var at := eye+ray*(-eye.z/ray.z)
			if absf(at.x)<model.frame_size().x*0.5 and absf(at.y)<model.frame_size().y*0.5: return false
	return true
func _run() -> void:
	DirAccess.make_dir_recursive_absolute(output)
	var image := Image.create(320,160,false,Image.FORMAT_RGBA8); image.fill(Color(0.15,0.5,0.7))
	for sphere in [false,true]:
		for standing in [false,true]:
			var model := Session.new(); root.add_child(model)
			var value := source(image,sphere); var count := 54 if sphere else 96
			model.configure(value,Session.grid_for_source(value,count)); model.set_posture(standing)
			if not sphere:
				var angles: Array[float]=[]
				for block in model.pieces:
					if block.visible:
						var ray: Vector3=block.position-model.viewer_position; angles.append(atan2(ray.x,-ray.z))
				check(frame_clear(model) and angles.min()<0 and angles.max()>0,"Both postures leave the central picture and lower menu clear")
				check((angles.max()-angles.min()>=PI) if standing else (angles.max()-angles.min()<PI),"Standing spans at least 180 degrees; seated pieces remain closer together")
				check(is_equal_approx(model.frame_scale(),1.35 if standing else 1.0),"An untouched standing picture starts larger than the seated picture")
				for factor in [2.0,6.0]:
					model.set_frame_scale(factor); check(frame_clear(model),"Enlarging the picture reflows every loose fragment clear of its visible bounds")
				model.set_frame_scale(1.0)
			var capacity: int=model.tray_capacity()
			var piece: MeshInstance3D=model.pieces.filter(func(p):return p.visible)[0]
			check(acquire(model,piece),"A real tray fragment can be acquired before a failed drop")
			var parking: Transform3D=piece.parked
			var wrong: Vector3=model.pieces[(piece.piece_id+count/2)%count].goal.origin
			var origin := Vector3.ZERO if sphere else Vector3(0,0,1)
			model.update_grab("right",origin,(wrong-origin).normalized())
			check(not model.release("right") and not piece.placed,"Wrong flat/sky position cannot commit a fragment")
			var checkpoint := model.snapshot()
			check(Session.valid_snapshot(checkpoint) and Session.decode_pose(checkpoint.pieces[piece.piece_id].pose).is_equal_approx(parking),"Failed-drop checkpoint stores the small tray pose during the return animation")
			if piece.motion!=null and piece.motion.is_running(): await piece.motion.finished
			check(piece.transform.is_equal_approx(parking),"An unmatched flat/sky fragment returns to its small tray slot")
			var count_before := model.pieces.filter(func(p):return p.tray_visible and not p.placed).size()
			model.set_paused(true)
			check(not model.pieces.any(func(p):return p.visible and not p.placed),"Paused menus cannot be occluded by loose fragments")
			check(model.snapshot().pieces.filter(func(p):return p.shown and not p.placed).size()==count_before,"Hiding pieces for a menu cannot erase the tray from autosave")
			model.set_paused(false)
			var complete := true
			for i in count:
				var available: Array=model.pieces.filter(func(p):return p.visible and not p.placed)
				if available.is_empty(): complete=false; break
				piece=available[0]
				if not acquire(model,piece): complete=false; break
				aim(model,piece)
				if not model.release("right"): complete=false; break
				check(model.pieces.filter(func(p):return p.visible and not p.placed).size()==mini(capacity,count-i-1),"Every consumed slot automatically replenishes from hidden pieces")
			check(complete and model.completed()==count,"The complete seated/standing flat/360 game needs no manual page changes")
			model.queue_free(); await process_frame
		# Quarter-turn optical input uses the wrist axis sign, without chatter.
		var model := Session.new(); root.add_child(model); var value := source(image,sphere)
		model.configure(value,Session.grid_for_source(value,24)); model.random_rotation=true; model.set_posture(false)
		var piece: MeshInstance3D=model.pieces.filter(func(p):return p.visible and is_equal_approx(p.turn_angle,PI*0.5))[0]
		check(acquire(model,piece,true),"Optical pinch acquires a quarter-turned real fragment")
		var basis: Basis=model.captures.right.hand_basis; var origin := model.global_position
		for degrees in [5,15]:
			aim(model,piece,Transform3D(Basis(basis.z,deg_to_rad(degrees))*basis,origin))
			check(is_equal_approx(piece.turn_angle,PI*0.5),"Small wrist motion stays on its 90-degree detent")
		aim(model,piece,Transform3D(Basis(basis.z,deg_to_rad(22))*basis,origin))
		check(is_zero_approx(piece.turn_angle),"A deliberate wrist turn steps 90 degrees in the visible wrist direction")
		for degrees in [20,23,35,60]: aim(model,piece,Transform3D(Basis(basis.z,deg_to_rad(degrees))*basis,origin))
		check(is_zero_approx(piece.turn_angle),"Detent hysteresis prevents wrist jitter from toggling direction")
		aim(model,piece,Transform3D(basis,origin))
		check(model.captures.right.turn_ready and is_zero_approx(piece.turn_angle),"Returning the wrist to neutral rearms without undoing the comfortable quarter turn")
		check(model.release("right") and piece.placed,"The corrected optical detent actually snaps into flat or curved geometry")
		var turns: Array=model.pieces.map(func(p):return p.turn_angle)
		model.next_tray()
		check(turns==model.pieces.map(func(p):return p.turn_angle),"More pieces preserves the player's existing orientation work")
		model.queue_free(); await process_frame
	# Motion far from a slot changes the surface normal without adding a roll.
	var moving := Session.new(); root.add_child(moving); var spherical_source := source(image,true)
	moving.configure(spherical_source,Session.grid_for_source(spherical_source,24))
	var moving_piece: MeshInstance3D=moving.pieces.filter(func(p):return p.visible and (p.goal.origin.normalized().dot(Vector3.FORWARD)>0.6))[0]
	check(acquire(moving,moving_piece),"A real curved fragment starts the no-spin aiming regression")
	var previous_normal := Vector3.ZERO; var previous_frame := Basis.IDENTITY
	for normal in [Vector3(0,0,1),Vector3(0.2,0.2,1).normalized(),Vector3(0.1,1,0.1).normalized(),Vector3(-0.1,1,-0.1).normalized()]:
		moving.update_grab("right",Vector3.ZERO,normal)
		var surface: Basis=moving.captures.right.surface_frame
		if previous_normal!=Vector3.ZERO:
			check(surface.is_equal_approx(Basis(Quaternion(previous_normal,normal))*previous_frame),"Curved delivery parallel-transports orientation instead of adding aim-dependent roll")
		var fixed: Transform3D=moving_piece.transform
		for i in 4: moving.update_grab("right",Vector3.ZERO,normal)
		check(moving_piece.transform.is_equal_approx(fixed),"An unchanged sky pointer never keeps spinning a held fragment")
		previous_frame=surface; previous_normal=normal
	moving.cancel("right"); moving.queue_free(); await process_frame
	# Full-viewer entry, close safety, reference ownership and retained progress.
	var path := output.path_join("entry.png"); image.save_png(path)
	var app := Main.new(); app.settings_path=output.path_join("settings.cfg"); root.add_child(app); app.set_process(false)
	app.photo.history_enabled=false; app.photo.mode_memory=Memory.new(output.path_join("modes"))
	app._on_library_chosen("file://"+path,"entry.png")
	var deadline := Time.get_ticks_msec()+8000
	while app.photo.loading and Time.get_ticks_msec()<deadline: await create_timer(0.01).timeout
	app.photo.finish_transition()
	var host: Node=app.puzzle_game; host.store=Store.new(output.path_join("saved")); host.store.set_mode_enabled(true)
	for kind in ["flat","relief","stereo","sphere"]:
		app.photo.set_projection(3 if kind=="sphere" else 0); app.photo.stereo_sbs=kind=="stereo"; app.photo.top_bottom=false
		app.photo._metadata["native_stereo"]=kind=="stereo"; app.photo.depth_requested=false; app.photo.depth_enabled=kind=="relief"
		if kind=="relief":
			var depth := Image.create(8,8,false,Image.FORMAT_RF); depth.fill(Color(0.4,0,0)); app.photo._display_depth_data={"image":depth}
		else: app.photo._display_depth_data={}
		host.start(false); check(await ready_game(host),"Each source type begins a real saved game: "+kind)
		var id: String=host.game_id; var blank: Dictionary=host.session.snapshot()
		var saved_piece: MeshInstance3D=host.session.pieces.filter(func(p):return p.visible)[0]
		check(acquire(host.session,saved_piece,false,true),"The continuing-game fixture acquires an actual nearby fragment")
		check(host.session.captures.right.near_hand==(kind!="sphere"),"Ordinary, relief and spatial pictures all use near-hand pickup while the sky keeps curved delivery")
		aim(host.session,saved_piece); host.session.release("right"); host.save_now()
		# An older build could have created this more-recent empty duplicate.
		host.store.create_game(host.descriptor,blank)
		var size_before: int=host.store.unfinished().size()
		host.finish(); host.store.remember(true,54 if kind=="sphere" else 96,kind=="sphere",true)
		host.open_setup(); check(await ready_game(host),"The large-photo entry continues its unfinished game: "+kind)
		check(host.game_id==id and host.store.unfinished().size()==size_before,"Re-entering the same media cannot create a duplicate checkpoint: "+kind)
		check(host.session.completed()==1 and not host.session.standing and not host.session.random_rotation and host.session.pieces.size()==24,"Resume skips setup and uses the saved posture/difficulty/direction instead of new defaults: "+kind)
		host.show_panel(true)
		check(host.panel._buttons.any(func(b):return b.target==28) and not host.panel._buttons.any(func(b):return b.target==5),"Game controls have explicit Exit and no global unfinished-list escape")
		host.panel._activate(4)
		check(host.active and host.game_id==id and not host.panel.visible,"The game menu X only closes the panel")
		host.tick(0.016)
		check(host.reference_preview.enabled and host.reference_preview.visible and app.menu_composition.menus.has(host.dock),"Off-hand reference defaults on and the menu handle is registered for HD capture")
		var head: Vector3=app.xr_camera.global_position
		host.frame_input.samples={"left_hand":{"pose":Transform3D(Basis.IDENTITY,head+Vector3(-0.2,-0.25,-0.4)),"tracked":false}}
		app.hand_pointers.left_hand.source="none"; host.tick(1.0)
		check(host.reference_preview.hand_attached,"A tracked wrist can carry the reference even without a left-hand aim ray")
		if kind=="flat":
			check((host.session.board.mesh.size-host.session.board_size).is_equal_approx(Vector2.ONE*0.12),"The completed picture retains a visible white border on all four edges")
			var layers := Composition.new(); root.add_child(layers); layers.configure(app.xr_origin,app.xr_camera,app.display,[],false,true); layers.set_process(false)
			layers.register_menu(host.dock); layers.register_menu(host.reference_preview); layers.update()
			check(layers.active==host.dock and layers.slots.any(func(slot):return slot.nodes.has(host.reference_preview.picture)) and layers.slots.any(func(slot):return slot.nodes.has(host.dock._buttons[0].node)),"Real dock and off-hand reference enter the same HD compositor update")
			layers.unregister_menu(host.reference_preview); layers.unregister_menu(host.dock); layers.queue_free(); await process_frame
		host.show_panel(true); host.panel._activate(28)
		check(host.active and host.panel.mode=="exit_confirm","Only the explicit Exit action opens exit confirmation")
		host.panel._activate(4)
		check(host.active and not host.panel.visible,"Closing exit confirmation also returns to the game")
		host.show_panel(true); host.panel._activate(28); host.panel._activate(29)
		check(not host.active and not host.store.get_game(id).is_empty(),"Confirmed Exit saves the same game and restores the photo")
	# Exercise the actual simultaneous photo controls and game-entry compositor path.
	app.photo.set_projection(0); app.photo.stereo_sbs=false; app.photo.depth_enabled=false; app.photo._metadata.native_stereo=false
	app.photo_menu.visible=true; host._update_photo_entry()
	var layers := Composition.new(); root.add_child(layers); layers.configure(app.xr_origin,app.xr_camera,app.display,[],false,true); layers.set_process(false)
	layers.register_menu(app.photo_menu); layers.register_menu(host.photo_entry); layers.update()
	check(layers.active==app.photo_menu and layers.slots.any(func(slot):return slot.nodes.has(host.photo_entry._labels.back())),"The actual Enter puzzle game caption is HD while photo controls are also visible")
	layers.unregister_menu(host.photo_entry); layers.unregister_menu(app.photo_menu); layers.queue_free()
	# New-photo defaults remain separate from an existing game's own snapshot.
	host.store.remember(true,96,false,true); host.store.remember(false,54,true,false)
	var fresh := Store.new(host.store.directory)
	check(fresh.standing_mode(false) and not fresh.standing_mode(true) and fresh.preferences().flat_count==96 and fresh.preferences().sphere_count==54 and fresh.preferences().flat_random_rotation and not fresh.preferences().sphere_random_rotation,"2D and 360 remember posture, difficulty and direction independently across restart")
	var another := output.path_join("new-photo.png"); image.save_png(another)
	app._on_library_chosen("file://"+another,"new-photo.png")
	deadline=Time.get_ticks_msec()+8000
	while app.photo.loading and Time.get_ticks_msec()<deadline: await create_timer(0.01).timeout
	app.photo.finish_transition()
	for sphere in [false,true]:
		app.photo.set_projection(3 if sphere else 0); host.open_setup()
		check(host.panel.mode=="setup" and host.panel.standing==not sphere and host.panel.piece_count==(54 if sphere else 96) and host.panel.random_rotation==not sphere,"A new image's compact setup restores only this projection's last choices")
		host.finish()
	app.photo.close_image(); app.queue_free(); await process_frame; await process_frame
	print("Puzzle usability: %d checks, %d failures" % [checks,failures.size()]); quit(0 if failures.is_empty() else 1)
