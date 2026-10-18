extends SceneTree
const Main := preload("res://scripts/main.gd")
const Store := preload("res://scripts/puzzle/puzzle_store.gd")
const Memory := preload("res://scripts/file_mode_memory.gd")
const Sound := preload("res://scripts/puzzle/puzzle_audio.gd")
const Fireworks := preload("res://scripts/puzzle/puzzle_fireworks.gd")
var checks := 0
var failures: Array[String]=[]
var output := ProjectSettings.globalize_path("res://../../build/output/puzzle-feedback/run-")+str(Time.get_ticks_usec())
func _initialize() -> void: call_deferred("_run")
func check(ok: bool, message: String) -> void:
	checks+=1
	if not ok: failures.append(message); push_error(message)
func ready_game(host: Node) -> bool:
	var deadline := Time.get_ticks_msec()+12000
	while host.panel.preparing and Time.get_ticks_msec()<deadline: await create_timer(0.01).timeout
	return host.session!=null and host.saving_ready
func _run() -> void:
	DirAccess.make_dir_recursive_absolute(output)
	for kind in Sound.STREAMS:
		var stream: AudioStreamWAV=Sound.STREAMS[kind]
		check(stream.get_length()>0.04 and stream.get_length()<1.3 and stream.data.size()>1000,"Bundled sound is a real short PCM asset: "+kind)
	var image := Image.create(320,160,false,Image.FORMAT_RGB8); image.fill(Color(0.3,0.6,0.8))
	var path := output.path_join("feedback.png"); image.save_png(path)
	var app := Main.new(); app.settings_path=output.path_join("settings.cfg"); root.add_child(app); app.set_process(false)
	app.photo.history_enabled=false; app.photo.mode_memory=Memory.new(output.path_join("modes"))
	app._on_library_chosen("file://"+path,"feedback.png")
	var deadline := Time.get_ticks_msec()+6000
	while app.photo.loading and Time.get_ticks_msec()<deadline: await create_timer(0.01).timeout
	app.photo.finish_transition()
	var host: Node=app.puzzle_game; host.store=Store.new(output.path_join("saved"))
	for spherical in [false,true]:
		app.photo.set_projection(3 if spherical else 0); host.start(false,24,true)
		check(await ready_game(host),"Feedback starts with a real flat or spherical game")
		if not host.saving_ready: quit(1); return
		var session: Node=host.session; var id: String=host.game_id
		var piece: MeshInstance3D=session.pieces.filter(func(p):return p.visible and not p.placed)[0]
		var start_angle: float=piece.turn_angle; var front: Vector3=piece.global_basis.z.normalized()
		var origin := piece.global_position+front*0.3
		check(session.grab("desktop",origin,-front),"Feedback piece is really acquired")
		if not session.captures.has("desktop"): quit(1); return
		var target: Vector3=app.xr_camera.global_position+Vector3(0,2,-1); origin=app.xr_camera.global_position
		session.update_grab("desktop",origin,(target-origin).normalized(),Transform3D(Basis(Vector3.BACK,deg_to_rad(5)),origin))
		check(host.sound.counts.rotate==0,"Small wrist jitter is silent")
		session.update_grab("desktop",origin,(target-origin).normalized(),Transform3D(Basis(Vector3.BACK,deg_to_rad(35)),origin))
		check(host.sound.counts.rotate==0,"Original orientation disables the wrist rotation cue")
		session.update_grab("desktop",origin,(target-origin).normalized(),Transform3D(Basis(Vector3.BACK,deg_to_rad(36)),origin))
		check(host.sound.counts.rotate==0,"A held wrist remains silent with rotation disabled")
		check(not session.release("desktop") and host.sound.counts.snap==0 and host.celebration==null,"An incorrect destination has no snap or success celebration")
		piece.transform=piece.goal; piece.turn_angle=0; front=piece.global_basis.z.normalized(); origin=piece.global_position+front*0.3
		session.grab("desktop",origin,-front); session.update_grab("desktop",origin,-front); session.release("desktop")
		if piece.motion!=null and piece.motion.is_running(): await piece.motion.finished
		check(piece.placed and host.sound.counts.snap==1 and host.sound.counts.success==0,"A single solved piece plays only its magnetic snap")
		if not spherical: session.set_frame_pose(Transform3D(Basis(Vector3.UP,0.25),Vector3(0.25,0.15,0.1)))
		var last: MeshInstance3D=session.pieces.filter(func(p):return not p.placed)[0]
		for block in session.pieces:
			if block==last: continue
			block.placed=true; block.turn_angle=0; block.transform=block.goal
		last.visible=true; last.transform=last.goal; last.turn_angle=0
		var saved_directory: String=host.store.directory; var blocked := output.path_join("blocked-"+str(spherical))
		var file := FileAccess.open(blocked,FileAccess.WRITE); file.store_string("not a directory"); file.close(); host.store.directory=blocked
		front=last.global_basis.z.normalized(); origin=last.global_position+front*0.3
		session.grab("desktop",origin,-front); session.update_grab("desktop",origin,-front); session.release("desktop")
		await process_frame; await process_frame
		check(session.completed()==24 and host.sound.counts.success==0 and host.celebration==null,"Failed final save cannot claim success or start fireworks")
		if spherical: app.xr_camera.rotation=Vector3(0.8,1.1,0.05)
		host.store.directory=saved_directory; host._complete_game(id)
		check(host.panel.mode=="complete" and host.sound.counts.success==1 and host.celebration!=null,"A saved last piece starts the completion cue and fireworks")
		var effect: Node=host.celebration; effect.set_process(false)
		check(effect.global_transform.is_equal_approx(app.xr_camera.global_transform if spherical else session.frame_world_pose()),"Panorama follows the actual tilted gaze; flat fireworks anchor to the moved frame")
		check(effect.mesh.multimesh.instance_count==360 and effect.mesh.cast_shadow==GeometryInstance3D.SHADOW_CASTING_SETTING_OFF,"Celebration bounds instanced particles and adds no shadow lights")
		check(host.sound.counts.launch==1 and host.sound.counts.burst==0,"The first rocket has an ascent cue before its explosion")
		effect.sample(1.1)
		check(host.sound.counts.launch==3 and host.sound.counts.burst==3,"Each of the three spatial bursts has its own ascent and explosion")
		effect.sample(1.1); host._complete_game(id)
		check(host.sound.counts.success==1 and host.sound.counts.launch==3 and host.sound.counts.burst==3,"Repeated completion or redraw cannot replay the celebration")
		var fixed: Transform3D=effect.global_transform; app.xr_camera.position.x+=0.1
		check(effect.global_transform==fixed,"Turning or moving the head does not drag the fireworks")
		if spherical:
			var inside := true
			for i in effect.particle_positions.size():
				var point: Vector3=effect.to_global(effect.particle_positions[i])
				inside=inside and point.distance_to(session.global_position)<=2.251
			check(inside,"Panorama sparks stay inside the completed sky instead of hiding behind it")
		effect.sample(2.49)
		var faded := true
		for alpha in effect.particle_alpha: faded=faded and alpha<0.001
		check(faded,"The short celebration fades every trail")
		app.display.preview=false; app.display.session_state="session_visible"; host.tick(0.016)
		check(host.celebration==null and host.sound.voices.values().all(func(pool):return pool.all(func(p):return not p.playing)),"Focus loss stops all sounds and removes the effect")
		app.display.preview=true; host.finish(); host.resume_game(id); await ready_game(host)
		check(host.sound.counts.success==0 and host.celebration==null,"Loading a finished checkpoint never replays its victory effects")
		host.finish(); app.xr_camera.rotation=Vector3.ZERO
	app.queue_free(); await process_frame; await process_frame
	print("Puzzle feedback: %d checks, %d failures" % [checks,failures.size()]); quit(0 if failures.is_empty() else 1)
