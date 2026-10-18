extends SceneTree
const Main := preload("res://scripts/main.gd")
const Source := preload("res://scripts/puzzle/puzzle_source.gd")
const Store := preload("res://scripts/puzzle/puzzle_store.gd")
const Memory := preload("res://scripts/file_mode_memory.gd")
var checks := 0
var failures: Array[String]=[]
var output := ProjectSettings.globalize_path("res://../../build/output/puzzle-p2/flow-")+str(Time.get_ticks_usec())
func _initialize() -> void: call_deferred("_run")
func check(ok: bool, message: String) -> void:
	checks+=1
	if not ok: failures.append(message); push_error(message)
func ready_game(host: Node) -> bool:
	var deadline := Time.get_ticks_msec()+10000
	while host.active and host.panel.preparing and Time.get_ticks_msec()<deadline: await create_timer(0.01).timeout
	return host.session!=null and host.saving_ready
func load_photo(app: Node, path: String, projection: int) -> void:
	app._on_library_chosen("file://"+path,path.get_file())
	var deadline := Time.get_ticks_msec()+6000
	while app.photo.loading and Time.get_ticks_msec()<deadline: await create_timer(0.01).timeout
	app.photo.finish_transition(); app.photo.set_projection(projection)
func deliver(app: Node, piece: MeshInstance3D) -> bool:
	var host: Node=app.puzzle_game; var session: Node=host.session
	host.show_panel(false)
	piece.visible=true; piece.transform=Transform3D(Basis.IDENTITY.scaled(Vector3.ONE*0.14),Vector3(-0.80,0.10,-0.90))
	app.hand_pointers.right_hand.source="hand"
	var origin: Vector3=app.xr_camera.global_position
	app.hand_pointers.right_hand.ray=[origin,(piece.global_position-origin).normalized()]
	host.ready_after_release.right_hand=true; host.button("trigger_click","right_hand")
	if not session.captures.has("right_hand"): return false
	var capture: Dictionary=session.captures.right_hand
	if int(capture.id)!=piece.piece_id: session.cancel("right_hand"); return false
	var target: Vector3=session.global_transform*(piece.goal*capture.anchor)
	app.hand_pointers.right_hand.ray=[origin,(target-origin).normalized()]; host.tick(0.016)
	host.button("trigger_click","right_hand",true)
	app.hand_pointers.right_hand.source="none"; app.hand_pointers.right_hand.ray=null
	if piece.motion!=null and piece.motion.is_running(): await piece.motion.finished
	return piece.placed
func _run() -> void:
	DirAccess.make_dir_recursive_absolute(output)
	var panorama := output.path_join("pano.png"); var flat := output.path_join("flat.png")
	var image := Image.create(320,160,false,Image.FORMAT_RGB8); image.fill(Color(0.18,0.4,0.7)); image.save_png(panorama)
	image=Image.create(160,120,false,Image.FORMAT_RGB8); image.fill(Color(0.7,0.3,0.2)); image.save_png(flat)
	var app := Main.new(); app.settings_path=output.path_join("settings.cfg"); root.add_child(app)
	app.set_process(false); app.photo.history_enabled=false; app.photo.mode_memory=Memory.new(output.path_join("modes"))
	var host: Node=app.puzzle_game; host.store=Store.new(output.path_join("saved"))
	await load_photo(app,panorama,0)
	check(Source.from_photo(app.photo).projection=="flat","A 2:1 image is not guessed to be a panorama")
	app.photo.set_projection(3)
	check(Source.from_photo(app.photo).projection=="sphere","Explicit full mono 360 mode exposes the spherical puzzle source")
	app.photo.stereo_sbs=true
	check(not Source.availability(app.photo).is_empty(),"Stereo 360 is rejected without discarding an eye")
	app.photo.stereo_sbs=false
	app.photo._metadata.merge({"FullPanoWidthPixels":640,"FullPanoHeightPixels":320,"CroppedAreaImageWidthPixels":320,"CroppedAreaImageHeightPixels":160},true)
	check(not Source.availability(app.photo).is_empty(),"Cropped GPano cannot be stretched into a complete sky")
	for key in ["FullPanoWidthPixels","FullPanoHeightPixels","CroppedAreaImageWidthPixels","CroppedAreaImageHeightPixels"]: app.photo._metadata.erase(key)
	var viewer_pose: Transform3D=app.photo.flat_pose
	app._on_photo_action("photo_puzzle")
	check(host.panel.current_spherical and host.panel.can_start,"Panorama toolbar opens the shared entry with seated and standing actions")
	host.start(false)
	check(await ready_game(host),"Panorama prepares asynchronously and creates its first checkpoint")
	if host.session==null: quit(1); return
	var id: String=host.game_id
	check(host.session.spherical and host.session.pieces.size()==24,"Real photo starts a 24-piece inner sky")
	check(host.session.global_position==app.xr_camera.global_position and not app.photo.visible,"Player is inside the sky, with original photo hidden")
	check(host.reference==host.session.sky.reference and not host.reference.visible,"Reference belongs to the spherical sky rather than a flat overlay")
	host.tick(0.016)
	check(host.dock.visible and host.dock.global_position.y<app.xr_camera.global_position.y-0.3,"The spherical game menu handle stays below the view")
	app.xr_camera.rotation.y+=0.25; host.button("by_button","right_hand")
	var forward: Vector3=-app.xr_camera.global_basis.z; forward.y=0; forward=forward.normalized()
	check(host.panel.visible and host.panel.global_position.is_equal_approx(app.xr_camera.global_position+forward*1.15-Vector3.UP*0.37),"B / Y summons the panorama game panel below the current view")
	host.button("by_button","right_hand")
	host.open_hub()
	check(host.panel.global_position.y+host.panel.layout_height()*0.5<app.xr_camera.global_position.y,"The panorama unfinished list also opens below the horizon")
	host.button("by_button","right_hand"); host.button("by_button","right_hand")
	var first: MeshInstance3D=host.session.pieces.filter(func(piece):return piece.visible)[0]
	check(await deliver(app,first),"Bare-hand ray delivery actually snaps a curved source-photo piece")
	check(host.store.get_game(id).snapshot.pieces[first.piece_id].placed,"Sphere release automatically saves the precise game")
	host.show_panel(true); host._action("reference")
	check(not host.reference_preview.enabled,"Reference starts enabled and can be hidden from game controls")
	host._action("reference")
	host._action("sky"); host.panel._activate(44); await host.session.turn_tween.finished
	check(host.session.view_face==4 and first.transform==first.goal and host.store.get_game(id).snapshot.view_face==4,"Top-to-front rotation carries solved patches and autosaves the matching frame")
	host._action("background")
	check(host.session.backdrop=="slate" and host.store.get_game(id).snapshot.backdrop=="slate","Backdrop selection persists independently of the source photo")
	host._action("posture")
	check(host.session.standing and host.session.completed()==1 and host.session.view_face==0,"Standing restores the original sky orientation and preserves solved progress")
	host._action("music"); app._close_music_menu()
	check(host.panel.visible and host.session.paused and host.game_id==id,"Music returns to the same spherical game")
	var centre: Vector3=host.session.global_position
	app.xr_camera.position+=Vector3(0.2,0,0.1); host.tick(0.016)
	check(host.session.global_position==centre,"Head motion does not drag the sky or its snap coordinates")
	host._action("recenter")
	check(host.session.global_position==app.xr_camera.global_position and first.transform==first.goal,"Explicit recenter moves the whole game without changing local answers")
	print("Puzzle panorama preparation_ms=%.2f worker_ms=%.2f max_main_commit_ms=%.2f" % [host.preparation_ms,host.session.builder.cpu_ms,host.session.max_commit_ms])
	host.finish()
	check(app.photo.geometry==3 and app.photo.flat_pose==viewer_pose and app.photo.visible,"Exit restores original panorama viewer and projection")
	await load_photo(app,flat,0); host.start(false); await ready_game(host)
	var flat_id: String=host.game_id; host.open_hub()
	check(host.panel.records.size()==2 and host.panel.records.any(func(r):return r.source.get("projection","flat")=="sphere"),"Global unfinished list mixes flat and panorama games")
	host.resume_game(id); check(await ready_game(host),"A flat-image entry directly resumes a spherical game")
	check(host.session.spherical and host.session.completed()==1 and host.session.standing and host.session.view_face==0 and host.session.backdrop=="slate","Resume restores spherical geometry, posture, photo turn, backdrop and progress")
	check(app.photo.local_uri=="file://"+flat and not host.store.get_game(flat_id).snapshot.pieces[0].placed,"Spherical resume preserves the current flat viewer and its independent progress")
	host.finish(); app._close_current_media(); DirAccess.remove_absolute(panorama)
	host.open_hub(); host.resume_game(id)
	check(await ready_game(host) and host.session.spherical,"No-image global entry resumes an offline panorama from retained resources")
	host.open_hub(); host._action("delete:"+id)
	check(host.session==null and host.store.get_game(id).is_empty() and not host.store.get_game(flat_id).is_empty(),"Deleting current panorama cannot remove a flat game's record")
	host._action("undo"); host.resume_game(id); await ready_game(host)
	check(host.session.completed()==1,"Undo restores a panorama checkpoint without a source file")
	var all_delivered := true
	for piece in host.session.pieces:
		if not piece.placed: all_delivered=bool(await deliver(app,piece)) and all_delivered
	check(all_delivered and host.session.completed()==24,"Actual ray releases complete every face, pole and seam patch")
	check(not host.store.unfinished().any(func(r):return r.id==id) and host.store.unfinished().any(func(r):return r.id==flat_id),"Completed sky leaves the unfinished list without touching another game")
	host.finish(); app.queue_free(); await process_frame; await process_frame
	await create_timer(0.1).timeout # Let the audio mixer release the last victory voices.
	print("Puzzle panorama flow: %d checks, %d failures" % [checks,failures.size()]); quit(0 if failures.is_empty() else 1)
