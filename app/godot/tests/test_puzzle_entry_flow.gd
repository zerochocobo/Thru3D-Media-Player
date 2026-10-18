extends SceneTree
const Main := preload("res://scripts/main.gd")
const Store := preload("res://scripts/puzzle/puzzle_store.gd")
const Memory := preload("res://scripts/file_mode_memory.gd")
const Session := preload("res://scripts/puzzle/puzzle_session.gd")
var checks := 0
var failures: Array[String]=[]
var output := ProjectSettings.globalize_path("res://../../build/output/puzzle-entry/flow-")+str(Time.get_ticks_usec())

class PhotoHost extends RefCounted:
	var ready: Callable
	var depth: Callable
	var depth_path := ""
	var spatial := {}
	var request := 100
	func open_photo(uri: String) -> int:
		request+=1
		ready.call_deferred(request,JSON.stringify(spatial if uri.ends_with(".heic") else {"state":"ready","path":uri.trim_prefix("file://")}))
		return request
	func prepare_photo_depth(id: int) -> bool:
		depth.call_deferred(id,JSON.stringify({"state":"ready","path":depth_path,"width":252,"height":140,"rect":[0,0,1,1]})); return true
	func cancel_photo(_id: int) -> void: pass
	func release_photo(_id: int) -> void: pass

func _initialize() -> void: call_deferred("_run")
func check(ok: bool, message: String) -> void:
	checks+=1
	if not ok: failures.append(message); push_error(message)
func ready_game(host: Node) -> bool:
	var deadline := Time.get_ticks_msec()+15000
	while host.active and host.panel.preparing and Time.get_ticks_msec()<deadline: await create_timer(0.01).timeout
	return host.session!=null and host.saving_ready
func ray(app: Node, position: Vector3, normal: Vector3) -> void:
	app.hand_pointers.right_hand.source="hand"; app.hand_pointers.right_hand.ray=[position+normal*0.4,-normal]
func clear_ray(app: Node) -> void:
	app.hand_pointers.right_hand.source="none"; app.hand_pointers.right_hand.ray=null
func click(app: Node, target: int) -> void:
	var host: Node=app.puzzle_game
	var buttons: Array=host.panel._buttons.filter(func(b):return b.target==target)
	if buttons.is_empty(): check(false,"Missing popup target %d" % target); return
	ray(app,buttons[0].node.global_position,host.panel.global_basis.z)
	host.ready_after_release.right_hand=true; host.button("trigger_click","right_hand"); host.button("trigger_click","right_hand",true); clear_ray(app)
func place(app: Node, piece: MeshInstance3D) -> void:
	var host: Node=app.puzzle_game
	host.show_panel(false); piece.visible=true; piece.transform=piece.goal
	ray(app,piece.global_position,host.session.global_basis.z)
	if host.session.spherical: app.hand_pointers.right_hand.ray=[app.xr_camera.global_position,(piece.global_position-app.xr_camera.global_position).normalized()]
	host.ready_after_release.right_hand=true; host.button("trigger_click","right_hand"); host.tick(0.016); host.button("trigger_click","right_hand",true); clear_ray(app)
	await process_frame

func remote_place(app: Node, piece: MeshInstance3D) -> void:
	var host: Node=app.puzzle_game; var origin: Vector3=app.xr_camera.global_position
	app.hand_pointers.right_hand.source="hand"; app.hand_pointers.right_hand.ray=[origin,(piece.global_position-origin).normalized()]
	host.ready_after_release.right_hand=true; host.button("trigger_click","right_hand")
	check(host.session.captures.has("right_hand"),"A real scattered fragment can be picked up without moving it to the target first")
	if not host.session.captures.has("right_hand"): clear_ray(app); return
	var capture: Dictionary=host.session.captures.right_hand
	var held: MeshInstance3D=host.session.pieces[int(capture.id)]
	var target: Vector3=host.session.global_transform*(held.goal*capture.anchor)
	app.hand_pointers.right_hand.ray=[origin,(target-origin).normalized()]; host.tick(0.016)
	check(not held.placed and capture.candidate and host.session.hint.visible and host.session.can_snap(held),"Pointing attaches the actual flat/relief/spatial/sky fragment to its magnetic destination")
	host.button("trigger_click","right_hand",true); clear_ray(app)
	if held.motion!=null and held.motion.is_running(): await held.motion.finished
	check(held.placed,"Releasing at the distant surface snaps without physically reaching the board")

func _run() -> void:
	DirAccess.make_dir_recursive_absolute(output)
	var image := Image.create(240,160,false,Image.FORMAT_RGBA8); image.fill(Color(0.3,0.6,0.8))
	image.save_png(output.path_join("flat.png")); image.save_png(output.path_join("relief.png"))
	var pair := Image.create(320,120,false,Image.FORMAT_RGBA8); pair.fill(Color.RED); pair.fill_rect(Rect2i(160,0,160,120),Color.GREEN)
	var raw := output.path_join("native.rgba"); FileAccess.open(raw,FileAccess.WRITE).store_buffer(pair.get_data())
	var depth := Image.create(252,140,false,Image.FORMAT_RF)
	for y in 140:
		for x in 252: depth.set_pixel(x,y,Color(float(x)/251,0,0))
	var depth_path := output.path_join("depth.bin"); FileAccess.open(depth_path,FileAccess.WRITE).store_buffer(depth.get_data())
	image=Image.create(320,160,false,Image.FORMAT_RGBA8); image.fill(Color(0.2,0.4,0.7)); image.save_png(output.path_join("360.png"))
	var app := Main.new(); app.settings_path=output.path_join("settings.cfg"); root.add_child(app)
	app.set_process(false); app.photo.history_enabled=false; app.photo.mode_memory=Memory.new(output.path_join("modes"))
	app.background._custom=ImageTexture.create_from_image(image); app.background.select("custom"); app.background.yaw=33; app._update_background()
	var decoder := PhotoHost.new(); decoder.ready=app.photo._on_ready; decoder.depth=app.photo._on_depth; decoder.depth_path=depth_path
	decoder.spatial={"state":"ready","path":raw,"raw_rgba":true,"decoded_width":320,"decoded_height":120,"width":320,"height":120,"native_stereo":true,"spatial_disparity":0.02}
	app.photo.platform=decoder
	var host: Node=app.puzzle_game; host.store=Store.new(output.path_join("saved")); host.store.set_mode_enabled(true)
	var ids: Array[String]=[]
	var kinds := ["flat","relief","stereo","flat"]
	var counts := [24,48,96,54]
	for index in 4:
		var name_value: String=["flat.png","relief.png","spatial.heic","360.png"][index]
		app.photo.auto_depth=false
		app._on_library_chosen("file://"+output.path_join(name_value),name_value)
		var deadline := Time.get_ticks_msec()+8000
		while app.photo.loading and Time.get_ticks_msec()<deadline: await create_timer(0.01).timeout
		if index==1:
			app.photo.set_depth(true)
			while not app.photo.depth_enabled and Time.get_ticks_msec()<deadline: await create_timer(0.01).timeout
		if index==3: app.photo.set_projection(3)
		app.photo.finish_transition(); app.photo_menu.dismiss(); app.recent_menu.dismiss(); host._update_photo_entry()
		check(host.photo_entry.visible,name_value+" exposes Enter puzzle game through the normal photo decoder")
		ray(app,host.photo_entry.global_position,host.photo_entry.global_basis.z)
		app._dispatch_hand_input({"right_hand":{"source":"hand","tracked":true,"down":true,"pressed":true}})
		app._dispatch_hand_input({"right_hand":{"source":"hand","tracked":true,"down":false,"released":true}}); clear_ray(app)
		check(host.active and host.panel.mode=="setup" and is_equal_approx(host.panel._backdrop.mesh.size.x,0.60),name_value+" opens the compact start popup")
		if not host.active: app.queue_free(); quit(1); return
		click(app,10+index%2)
		click(app,50+host.panel.difficulty_counts().find(counts[index]))
		check(host.session==null and host.panel.piece_count==counts[index],"Posture and count remain choices until Start")
		click(app,17)
		check(await ready_game(host),name_value+" actually builds and starts")
		if not host.saving_ready: app.queue_free(); quit(1); return
		ids.append(host.game_id)
		check(host.session.pieces.size()==counts[index] and host.session.source.kind==kinds[index],name_value+" keeps selected count and content type")
		check(host.session.standing==(index%2==1),"Selected posture reaches gameplay")
		if index<3:
			check(app.display.scenery!=null and app.display.scenery==app.background.ready_sky() and app.background.choice=="custom","Flat puzzle retains the selected system environment")
			check(host.session.board.material_override.shader==app.photo.PLACEHOLDER_SHADER,"Flat puzzle frame shares the unloaded photo's frosted-glass style")
		else: check(app.display.scenery==null and app.background.choice=="custom","Panorama's independent sky does not replace the saved system background")
		if index==1:
			check(host.session.source.depth!=null and host.session.pieces.all(func(p):return p.mesh.get_aabb().size.z>=0.0119) and host.session.pieces.any(func(p):return p.mesh.get_aabb().size.z>0.025),"Converted pieces retain thick walls and actual scene relief across finer cuts")
		if index==2:
			check(host.session.source.layout==1 and host.session.source.size==Vector2(160,120) and host.session.source.image.get_pixel(240,40).g>0.9,"Native spatial puzzle retains both eyes and computes cuts from single-eye aspect")
		if index==3:
			check(host.session.spherical and Session.valid_snapshot(host.session.snapshot()),"54-piece inner sky has a resumable valid curved snapshot")
		host.tick(0.016)
		ray(app,host.dock.global_position,host.dock.global_basis.z); host.tick(0.016)
		check(host.dock._pointers.right_hand.line.visible,"The lower menu ray appears only on a current hand hit")
		app.hand_pointers.right_hand.ray=[app.xr_camera.global_position,Vector3.UP]; host.tick(0.016)
		check(not host.dock._pointers.right_hand.line.visible,"Moving off the menu clears the previous yellow line")
		clear_ray(app); host.tick(0.016)
		check(not host.dock._pointers.right_hand.line.visible,"Tracking loss does not leave a detached menu ray")
		await remote_place(app,host.session.pieces.filter(func(p):return p.visible)[0])
		check(host.store.get_game(ids[index]).snapshot.pieces.filter(func(p):return p.placed).size()==1,"A real release snaps and saves the specific game's progress")
		host.finish()
	check(host.store.unfinished().size()==4 and ids.all(func(id):return ids.count(id)==1),"Every source has its own unfinished game")
	var before: Array=[]
	for id in ids: before.append(FileAccess.get_file_as_bytes(host.store.directory.path_join("games").path_join(id+".json")))
	host.open_hub(); host._action("mode_off"); host.finish(); app.photo_menu.dismiss(); host._update_photo_entry()
	check(not host.photo_entry.visible and not host.is_mode_enabled(),"Turning mode off hides the large-image entry")
	var unchanged := true
	for i in ids.size(): unchanged=unchanged and before[i]==FileAccess.get_file_as_bytes(host.store.directory.path_join("games").path_join(ids[i]+".json"))
	check(unchanged and host.store.unfinished().size()==4,"Disabling the mode does not rewrite or remove any game checkpoint")
	for index in 4:
		host.open_hub(); check(host.resume_game(ids[index]) and await ready_game(host),"Mode off still resumes "+kinds[index])
		check(host.session.completed()==1 and host.session.pieces.size()==counts[index] and host.session.source.kind==kinds[index],"Resume preserves the correct source, difficulty and placed piece")
		if index<3: check(app.display.scenery==app.background.ready_sky() and app.display.scenery!=null,"Resuming a flat puzzle over an open panorama restores the system scenery")
		host.finish()
	host.open_hub(); host.resume_game(ids[0]); await ready_game(host)
	for piece in host.session.pieces:
		if not piece.placed: await place(app,piece)
	check(host.panel.mode=="complete" and host.session.completed()==24 and not host.store.unfinished().any(func(r):return r.id==ids[0]),"The last snap saves completion and opens the finished actions")
	click(app,15); check(host.panel.mode=="setup" and host.setup_source.title=="flat.png","Play again uses the finished game's photo, even with a different panorama open")
	click(app,17); check(await ready_game(host) and host.game_id not in ids and host.session.completed()==0,"Play again creates a new independent session")
	check(host.store.get_game(ids[0]).snapshot.pieces.all(func(p):return p.placed) and host.store.unfinished().size()==4,"Replay never overwrites the finished game or the other three games")
	check(host.store.get_game(host.game_id).source.image_key==host.store.get_game(ids[0]).source.image_key,"Offline replay retains the original photo identity rather than re-keying without its URI")
	host.finish(); app.queue_free(); await process_frame; await process_frame
	print("Puzzle entry flow: %d checks, %d failures" % [checks,failures.size()]); quit(0 if failures.is_empty() else 1)
