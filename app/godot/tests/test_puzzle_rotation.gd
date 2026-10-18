extends SceneTree
const Main := preload("res://scripts/main.gd")
const Store := preload("res://scripts/puzzle/puzzle_store.gd")
const Session := preload("res://scripts/puzzle/puzzle_session.gd")
const Memory := preload("res://scripts/file_mode_memory.gd")
const Quick := preload("res://scripts/music_quick_controls.gd")
var checks := 0
var failures: Array[String]=[]
var output := ProjectSettings.globalize_path("res://../../build/output/puzzle-rotation/run-")+str(Time.get_ticks_usec())
class App extends Main:
	var rays := {}
	var poses := {}
	func _ray(hand: String) -> Variant: return rays.get(hand)
	func _move_pose(hand: String) -> Variant: return poses.get(hand)
func _initialize() -> void: call_deferred("_run")
func check(ok: bool, message: String) -> void:
	checks+=1
	if not ok: failures.append(message); push_error(message)
func ready_game(host: Node) -> bool:
	var deadline := Time.get_ticks_msec()+15000
	while host.panel.preparing and Time.get_ticks_msec()<deadline: await create_timer(0.01).timeout
	return host.session!=null and host.saving_ready
func aim(app: Node, origin: Vector3, target: Vector3, roll: float = 0, hand: String = "right_hand") -> void:
	app.rays[hand]=[origin,(target-origin).normalized()]
	app.poses[hand]=Transform3D(Basis(Vector3.BACK,roll),origin)
func acquire(app: Node, piece: MeshInstance3D, hand: String = "right_hand") -> bool:
	var host: Node=app.puzzle_game
	for i in 10:
		if piece.visible: break
		host.session.next_tray()
	var front: Vector3=piece.global_basis.z.normalized()
	aim(app,piece.global_position+front*0.5,piece.global_position,0,hand)
	host.ready_after_release[hand]=true; host.button("trigger_click",hand)
	return host.session.captures.get(hand,{}).get("id",-1)==piece.piece_id
func target(app: Node, piece: MeshInstance3D, roll: float = 0, hand: String = "right_hand") -> void:
	var host: Node=app.puzzle_game
	var point: Vector3=host.session.to_global(piece.goal*host.session.captures[hand].anchor)
	aim(app,app.xr_camera.global_position,point,roll,hand)
func settle(piece: MeshInstance3D) -> void:
	if piece.motion!=null and piece.motion.is_running(): await piece.motion.finished
func _run() -> void:
	DirAccess.make_dir_recursive_absolute(output)
	var image := Image.create(320,160,false,Image.FORMAT_RGB8); image.fill(Color(0.4,0.6,0.8))
	var photo := output.path_join("photo.png"); image.save_png(photo)
	var app := App.new(); app.settings_path=output.path_join("settings.cfg"); root.add_child(app); app.set_process(false)
	app.photo.history_enabled=false; app.photo.mode_memory=Memory.new(output.path_join("modes"))
	app._on_library_chosen("file://"+photo,"photo.png")
	var deadline := Time.get_ticks_msec()+8000
	while app.photo.loading and Time.get_ticks_msec()<deadline: await create_timer(0.01).timeout
	app.photo.finish_transition()
	var host: Node=app.puzzle_game; host.store=Store.new(output.path_join("saved")); host.store.set_mode_enabled(true)
	for spherical in [false,true]:
		app.photo.set_projection(3 if spherical else 0)
		host.store.remember(false,24,spherical,false)
		host.open_setup()
		check(not host.panel.random_rotation and host.panel._buttons.any(func(b):return b.target==61),"Setup defaults to original and also offers random quarter turns")
		host.panel._activate(60); host.panel._activate(17)
		check(await ready_game(host) and not host.session.random_rotation,"Original orientation starts without any rotation controls")
		if not host.saving_ready: quit(1); return
		var model: Node=host.session; var id: String=host.game_id
		check(model.pieces.all(func(p):return is_zero_approx(p.turn_angle)),"Every new fragment starts upright")
		host.tick(0.016)
		check(host.dock._buttons.size()==(6 if spherical else 5),"Reference, music and batch controls live beside the persistent menu button")
		var music_button: Dictionary=host.dock._buttons.filter(func(b):return b.target==6)[0]
		check(host.dock._buttons.all(func(b):return b.node.position.x>=music_button.node.position.x),"Music is the leftmost persistent shortcut")
		var reference_enabled: bool=host.reference_preview.enabled; host.dock._activate(5)
		check(host.reference_preview.enabled!=reference_enabled and not host.panel.visible,"The persistent reference button toggles the thumbnail without opening a menu")
		host.dock._activate(5)
		app.background_audio.current="yunhai"; app.background_audio._loaded="yunhai"; app.background_audio.paused=false
		app.background_audio.queue.assign(["yunhai"]); host.dock.refresh()
		music_button=host.dock._buttons.filter(func(b):return b.target==6)[0]
		var music_point: Vector3=music_button.node.global_position; var normal: Vector3=host.dock.global_basis.z
		app.rays.right_hand=[music_point+normal*0.4,-normal]; host.tick(0.016)
		host.dock.music_quick._entered.right_hand=Time.get_ticks_msec()-Quick.ENTER_MS-1; host.tick(0.016)
		check(host.dock.music_quick.expanded and host.dock._buttons.any(func(b):return b.target==Quick.PLAY),"An uninterrupted real host ray expands the same shared music quick controls")
		var play: Dictionary=host.dock._buttons.filter(func(b):return b.target==Quick.PLAY)[0]
		app.rays.right_hand=[play.node.global_position+normal*0.4,-normal]; host.ready_after_release.right_hand=true
		host.button("trigger_click","right_hand"); host.button("trigger_click","right_hand",true)
		check(app.background_audio.paused and not model.paused and not host.panel.visible and host.game_id==id,"Quick Pause controls the existing player in place without pausing or exiting the puzzle")
		music_button=host.dock._buttons.filter(func(b):return b.target==6)[0]
		app.rays.right_hand=[music_button.node.global_position+normal*0.4,-normal]; host.ready_after_release.right_hand=true
		host.button("trigger_click","right_hand"); host.button("trigger_click","right_hand",true)
		check(host.music_open and app.music_menu.visible and model.paused,"The expanded music entry opens full management and pauses the game safely")
		app._close_music_menu(); app.rays.clear(); host.tick(0.016)
		check(not host.music_open and not model.paused and not host.panel.visible and not host.dock.music_quick.expanded,"Closing music opened from the shortcuts returns directly to live play with a compact entry")
		host.show_panel(true)
		check(not host.panel._buttons.any(func(b):return b.target in [2,7]),"Batch controls do not clutter the game menu")
		host.show_panel(false); host.tick(0.016)
		var before: Dictionary=model.snapshot(); host.dock._activate(2)
		check(not host.panel.visible and model.tray_seed>0 and model.tray_seed!=before.tray_seed and host.store.get_game(id).snapshot.tray_seed==model.tray_seed,"Random batch changes and saves the tray without opening a menu or changing geometry")
		host.dock._activate(3)
		check(not host.panel.visible and model.tray_page==1,"Next batch is directly playable beside the menu handle")
		var piece: MeshInstance3D=model.pieces.filter(func(p):return p.visible and not p.placed)[0]
		check(acquire(app,piece),"A real controller acquires the surrounding fragment")
		if not model.captures.has("right_hand"): quit(1); return
		if not spherical:
			check(piece.global_position.distance_to(app.rays.right_hand[0])<0.4,"The fragment immediately comes within forty centimetres of the grabbing hand")
		target(app,piece,PI*0.75); host.tick(0.016)
		check(is_zero_approx(piece.turn_angle) and model.captures.right_hand.candidate,"Wrist rotation cannot alter orientation or prevent magnetic placement")
		if not spherical:
			check(piece.global_position.distance_to(app.rays.right_hand[0])>0.5 and model.hint.visible and piece.transform.is_equal_approx(piece.goal),"Aiming at the frame brings the actual fragment onto its magnetic destination")
		host.button("trigger_click","right_hand",true); await settle(piece)
		check(piece.placed and model.completed()==1,"Release delivers and snaps the held piece to the distant answer")
		if spherical:
			host.show_panel(true); host._action("sky"); host.panel._activate(44); await model.turn_tween.finished
			check(model.view_face==4 and piece.transform==piece.goal,"Seated sky adjustment carries existing solved pieces")
			app.xr_camera.position+=Vector3(0.2,0,0.1); host.panel._activate(24)
			check(model.view_face==0 and model.global_position==app.xr_camera.global_position and model.completed()==1,"One-click Reset sky restores orientation and centre without removing progress")
			host._action("posture")
			check(model.standing and not host.panel._buttons.any(func(b):return b.target==23),"Standing hides the seated sky-adjustment menu")
			host._action("sky"); host._action("view:4")
			check(host.panel.mode!="sky" and model.view_face==0,"Stale seated-sky actions cannot turn the standing panorama")
			host.show_panel(false); host.tick(0.016); host.dock._activate(4)
			check(not host.panel.visible and model.view_face==0 and model.completed()==1 and host.store.get_game(id).snapshot.view_face==0,"The lower-view reset shortcut preserves and saves the current spherical game")
		# Recreate an old random checkpoint without destroying its ID, solved piece or frame.
		host.show_panel(false); model.random_rotation=true; model.scatter(model.standing)
		var saved_turns: Array=model.pieces.map(func(p):return p.turn_angle)
		var frame: Transform3D=model.frame_pose; var seed_id: int=model.seed_value
		host.save_now(); host._changed(); host.save_now(); host.finish(); app.rays.clear(); app.poses.clear()
		host.resume_game(id); check(await ready_game(host),"A legacy random game resumes through the global unfinished entry")
		model=host.session
		var directions_match := true
		for i in saved_turns.size(): directions_match=directions_match and is_equal_approx(model.pieces[i].turn_angle,saved_turns[i])
		check(host.game_id==id and model.completed()==1 and model.seed_value==seed_id and model.frame_pose==frame and model.random_rotation and directions_match,"Resume preserves identity, geometry, frame, solved progress and each saved random direction")
		check(host.store.get_game(id).snapshot.random_rotation,"The random-direction checkpoint remains durably saved")
		var left_piece: MeshInstance3D=model.pieces.filter(func(p):return p.visible and not p.placed)[0]
		check(acquire(app,left_piece,"left_hand"),"The left controller acquires its own random fragment")
		host.tick(0.016)
		check(host.rotation_hints.has("left_hand") and host.rotation_hints.left_hand.visible and host.rotation_hints.left_hand.text.contains("A ↻") and host.rotation_hints.left_hand.text.contains("X ↺"),"Single left-hand pickup shows both opposite-direction controls")
		var old_turn: float=left_piece.turn_angle; host.button("ax_button","left_hand"); host.button("ax_button","left_hand",true)
		check(is_equal_approx(wrapf(left_piece.turn_angle-old_turn,-PI,PI),PI*0.5),"Left X rotates exactly one counterclockwise quarter turn per press")
		host.button("ax_button","right_hand"); host.button("ax_button","right_hand",true)
		check(is_equal_approx(left_piece.turn_angle,old_turn),"Right A reverses X on the sole left-held piece without requiring a right-hand grab")
		var right_piece: MeshInstance3D=model.pieces.filter(func(p):return p.visible and not p.placed and p!=left_piece)[0]
		check(acquire(app,right_piece),"Both controllers can hold separate random fragments")
		host.tick(0.016)
		check(host.rotation_hints.right_hand.text=="A ↻ 90°" and host.rotation_hints.left_hand.text=="X ↺ 90°","Dual pickup shows only each controller's own direction")
		var right_turn: float=right_piece.turn_angle; old_turn=left_piece.turn_angle
		host.button("ax_button","right_hand"); host.button("ax_button","right_hand",true)
		check(is_equal_approx(wrapf(right_piece.turn_angle-right_turn,-PI,PI),-PI*0.5) and is_equal_approx(left_piece.turn_angle,old_turn),"A rotates only the right-held fragment clockwise during dual pickup")
		host.button("ax_button","left_hand"); host.button("ax_button","left_hand",true)
		check(is_equal_approx(wrapf(left_piece.turn_angle-old_turn,-PI,PI),PI*0.5) and is_equal_approx(wrapf(right_piece.turn_angle-right_turn,-PI,PI),-PI*0.5),"X rotates only the left-held fragment counterclockwise during dual pickup")
		host.button("trigger_click","right_hand",true); await settle(right_piece)
		host.button("trigger_click","left_hand",true); app.rays.erase("left_hand"); app.poses.erase("left_hand")
		await settle(left_piece)
		check(not host.rotation_hints.left_hand.visible,"Releasing hides the controller rotation hint")
		var all_placed := true
		for block in model.pieces:
			if block.placed: continue
			host.show_panel(false)
			if not acquire(app,block): all_placed=false; break
			target(app,block,PI*0.8); host.tick(0.016)
			check(host.rotation_hints.has("right_hand") and host.rotation_hints.right_hand.visible and host.rotation_hints.right_hand.text.contains("A ↻") and host.rotation_hints.right_hand.text.contains("X ↺"),"Single right-hand pickup shows both opposite-direction controls")
			var initial_turn: float=block.turn_angle
			host.button("ax_button","right_hand"); host.button("ax_button","right_hand",true)
			check(is_equal_approx(wrapf(block.turn_angle-initial_turn,-PI,PI),-PI*0.5),"A turns the sole right-held piece clockwise once, ignoring the release edge")
			host.button("ax_button","left_hand"); host.button("ax_button","left_hand",true)
			check(is_equal_approx(block.turn_angle,initial_turn),"X reverses A on the sole right-held piece using its held-hand ray")
			for step in 4:
				if is_zero_approx(block.turn_angle): break
				host.button("ax_button","right_hand"); host.button("ax_button","right_hand",true)
			host.button("trigger_click","right_hand",true); await settle(block)
			all_placed=all_placed and block.placed
		check(all_placed and model.completed()==24 and host.panel.mode=="complete","A-key quarter turns complete every random flat/360 fragment without twisting the controller wrist")
		host.finish(); app.rays.clear(); app.poses.clear()
	# Difficulty adds visible pieces while maintaining actual readable fragment size.
	var value := {"texture":ImageTexture.create_from_image(image),"size":Vector2(320,160)}
	for standing in [false,true]:
		var previous := 0
		for count in [24,48,96]:
			var model := Session.new(); root.add_child(model); model.configure(value,Session.grid_for_source(value,count)); model.set_posture(standing)
			var shown: Array=model.pieces.filter(func(p):return p.visible)
			check(shown.size()>previous,"Higher difficulty increases visible batch density")
			previous=shown.size()
			for block in shown:
				var extent: Vector3=block.mesh.get_aabb().size*block.basis.get_scale()
				check(maxf(extent.x,extent.y)>=0.27,"Even a 96-piece fragment keeps a readable physical size")
				if standing:
					var delta: Vector3=block.position-model.viewer_position
					check(Vector2(delta.x,delta.z).length()>=1.09 and Vector2(delta.x,delta.z).length()<=1.31,"Standing fragments stay near the player, at the panorama-like walking distance")
			model.queue_free(); await process_frame
	app.queue_free(); await process_frame; await process_frame; await create_timer(0.1).timeout
	print("Puzzle rotation: %d checks, %d failures" % [checks,failures.size()]); quit(0 if failures.is_empty() else 1)
