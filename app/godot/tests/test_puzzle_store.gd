extends SceneTree
const Store := preload("res://scripts/puzzle/puzzle_store.gd")
const Session := preload("res://scripts/puzzle/puzzle_session.gd")
var checks := 0
var failures: Array[String]=[]
var output := ProjectSettings.globalize_path("res://../../build/output/puzzle-p1/store-")+str(Time.get_ticks_usec())
func _initialize() -> void: call_deferred("_run")
func check(ok: bool, message: String) -> void:
	checks+=1
	if not ok: failures.append(message); push_error(message)
func write(path: String, text: String) -> void:
	var file := FileAccess.open(path,FileAccess.WRITE); file.store_string(text); file.close()
func source(uri: String, color: Color) -> Dictionary:
	var image := Image.create(64,48,false,Image.FORMAT_RGBA8); image.fill(color)
	return {"image":image,"texture":ImageTexture.create_from_image(image),"size":Vector2(64,48),"uri":uri,"title":"same.png","kind":"flat"}
func _run() -> void:
	var store := Store.new(output)
	var a := source("file:///folder-a/same.png",Color.RED)
	var b := source("file:///folder-b/same.png",Color.BLUE)
	var asset_a := store.cache_source(a); var asset_b := store.cache_source(b)
	check(not asset_a.is_empty() and not asset_b.is_empty(),"Image assets persist before any game is created")
	check(asset_a.image_key!=asset_b.image_key,"Same filename in different folders has independent identity")
	var identical := source("file:///folder-c/same.png",Color.RED)
	check(store.cache_source(identical).image_key!=asset_a.image_key,"Identical pixels at another URI remain separate image records")
	var session := Session.new(); root.add_child(session); session.configure(a)
	var initial: Dictionary=session.snapshot()
	var id_a := store.create_game(asset_a,initial); var id_b := store.create_game(asset_b,initial)
	var same_image := store.create_game(asset_a,initial)
	check(Store.valid_id(id_a) and id_a!=id_b and id_a!=same_image,"Every image and every new game receives a separate random ID")
	check(store.unfinished().size()==3,"Global list discovers games across all images")
	session.pieces[0].placed=true; session.pieces[0].transform=session.pieces[0].goal
	var saved_pose: Transform3D=session.pieces[1].transform.translated(Vector3(0.1,0.05,0.03)); session.pieces[1].transform=saved_pose
	check(store.save_game(id_a,session.snapshot()),"A game atomically updates its own checkpoint")
	check(not store.get_game(id_b).snapshot.pieces[0].placed and not store.get_game(same_image).snapshot.pieces[0].placed,"Saving A cannot change B or another game of A")
	var restarted := Store.new(output)
	check(restarted.unfinished().size()==3 and restarted.get_game(id_a).snapshot.pieces[0].placed,"Fresh store reconstructs progress without a mutable global index")
	var loaded_source := restarted.load_source(restarted.get_game(id_a).source)
	check(not loaded_source.is_empty() and loaded_source.image.get_pixel(0,0)==Color.RED,"Resume loads retained pixels without consulting original URI")
	var restored := Session.new(); root.add_child(restored); restored.configure(loaded_source)
	check(restored.restore(restarted.get_game(id_a).snapshot) and restored.completed()==1,"Checkpoint recreates solved state")
	check(restored.pieces[1].transform.is_equal_approx(saved_pose),"Checkpoint recreates exact parked piece transform")
	check(restored.pieces[0].transform==restored.pieces[0].goal,"Solved piece restores precisely at its goal")
	var seated := restored.pieces[1].position
	restored.set_posture(true)
	check(restored.standing and restored.pieces[1].position!=seated and restored.pieces[0].transform==restored.pieces[0].goal,"Standing reflows only unsolved pieces around the player")
	check(restored.pieces.filter(func(p):return not p.placed).all(func(p):return p.position.y>=-0.49),"Standing layout keeps pieces above the lower reach band")
	restored.set_posture(false)
	check(not restored.standing and restored.pieces.filter(func(p):return not p.placed).all(func(p):return p.position.distance_to(restored.viewer_position)<1.8),"Seated layout uses compact side trays within comfortable pointing distance")
	store.remember(true)
	check(Store.new(output).preferences().get("standing",false),"Last posture survives a new store instance")
	check(not store.mode_enabled() and store.set_mode_enabled(true) and Store.new(output).mode_enabled(),"Puzzle mode is opt-in and persists explicitly across store instances")
	store.remember(false)
	check(store.mode_enabled() and not store.preferences().standing,"Posture writes preserve the global puzzle-mode choice")
	store.remember(true,48,false); store.remember(false,54,true)
	check(store.preferences().flat_count==48 and store.preferences().sphere_count==54 and store.mode_enabled(),"Flat and sky difficulty memory is independent and preserves the mode switch")
	check(store.set_mode_enabled(false) and not store.mode_enabled() and store.unfinished().size()==3,"Disabling image entries preserves every saved game")
	var current := output.path_join("games").path_join(id_a+".json")
	write(current,"{interrupted")
	check(not restarted.get_game(id_a).is_empty() and not restarted.get_game(id_a).snapshot.pieces[0].placed,"Corrupt current checkpoint falls back to previous good transaction")
	check(store.save_game(id_a,session.snapshot()),"Recovered checkpoint can be saved again")
	write(current,"{interrupted-again")
	check(not restarted.get_game(id_a).is_empty(),"Recovery never rotates corrupt current bytes over good backup")
	check(store.delete_game(id_b),"Delete commits a per-game tombstone")
	check(Store.new(output).get_game(id_b).is_empty() and store.unfinished().size()==2,"Deleted game stays absent across restart")
	check(not store.save_game(id_b,initial),"Late save cannot resurrect a deleted game")
	check(not store.load_source(asset_b).is_empty(),"Deleting a game leaves source image assets intact")
	check(store.undo_delete() and store.unfinished().size()==3,"Undo restores only the selected deleted game")
	check(store.get_game("../outside").is_empty() and not store.delete_game("../outside"),"Game identifiers cannot escape the save directory")
	var malformed := initial.duplicate(true); malformed.pieces[1].id=0
	check(not store.save_game(id_b,malformed),"Duplicate piece identities are rejected before overwriting progress")
	malformed=initial.duplicate(true); malformed.pieces[0].pose[9]=NAN
	check(not Session.valid_snapshot(malformed),"Nonfinite transforms are rejected")
	malformed=initial.duplicate(true); malformed.pieces[0].pose[0]=0; malformed.pieces[0].pose[1]=0; malformed.pieces[0].pose[2]=0
	check(not Session.valid_snapshot(malformed),"Singular transforms are rejected")
	var legacy := initial.duplicate(true); legacy.erase("frame_pose")
	check(Session.valid_snapshot(legacy) and restored.restore(legacy) and restored.frame_pose==Transform3D.IDENTITY,"Legacy games without a frame pose still restore at their original target")
	malformed=initial.duplicate(true); malformed.frame_pose[0]=NAN
	check(not Session.valid_snapshot(malformed),"Nonfinite frame transforms cannot overwrite a checkpoint")
	malformed=initial.duplicate(true); malformed.frame_pose[0]=0
	check(not Session.valid_snapshot(malformed),"Singular frame transforms cannot overwrite a checkpoint")
	malformed=initial.duplicate(true); malformed.frame_pose[3]=0.1
	check(not Session.valid_snapshot(malformed),"Sheared frame transforms are rejected")
	var blocked := output.path_join("blocked"); write(blocked,"not a directory")
	var saved_bytes := FileAccess.get_file_as_bytes(output.path_join("games").path_join(id_b+".json"))
	var failure_store := Store.new(blocked)
	check(not failure_store.set_mode_enabled(true) and not failure_store.mode_enabled(),"A failed preference write cannot report puzzle mode as enabled")
	check(failure_store.create_game(asset_b,initial).is_empty() and not failure_store.last_error.is_empty(),"Unwritable storage reports failure instead of claiming success")
	check(FileAccess.get_file_as_bytes(output.path_join("games").path_join(id_b+".json"))==saved_bytes,"Failed write leaves other game bytes untouched")
	var depth := Image.create(8,8,false,Image.FORMAT_RF)
	for y in 8:
		for x in 8: depth.set_pixel(x,y,Color(float(x+y)/14.0,0,0))
	var relief := a.duplicate(); relief.kind="relief"; relief.depth=depth; relief.relief=0.02
	var relief_asset := store.cache_source(relief); var relief_source := store.load_source(relief_asset)
	check(not relief_source.is_empty() and relief_source.kind=="relief" and relief_source.depth.get_data()==depth.get_data(),"Relief restores exact global float depth without rerunning conversion")
	check(relief_asset.asset_key!=asset_a.asset_key and relief_asset.image_key==asset_a.image_key,"Relief and flat variants share image identity but keep separate assets")
	var stereo := a.duplicate(); stereo.kind="stereo"; stereo.layout=2; stereo.swap_eyes=true; stereo.spatial_disparity=0.015
	var stereo_source := store.load_source(store.cache_source(stereo))
	check(not stereo_source.is_empty() and stereo_source.layout==2 and stereo_source.swap_eyes and is_equal_approx(stereo_source.spatial_disparity,0.015),"Spatial checkpoint preserves eye layout, ordering and disparity")
	var asset_path := output.path_join("assets").path_join(asset_a.asset_key).path_join("image.png")
	b.image.save_png(asset_path)
	check(store.load_source(asset_a).is_empty() and not store.get_game(id_a).is_empty(),"Mismatched cached image refuses resume without removing progress")
	for piece in session.pieces: piece.placed=true
	store.save_game(same_image,session.snapshot())
	check(not store.unfinished().any(func(r):return r.id==same_image),"Completed games leave unfinished list without affecting other games")
	var many := Session.new(); root.add_child(many); many.configure(b,Vector2i(8,6))
	check(many.pieces.filter(func(p):return p.visible).size()==24,"A 48-piece seated game shows a denser, larger batch")
	many.next_tray(); check(many.tray_page==1 and many.pieces.filter(func(p):return p.visible).size()==24,"Next batch cycles the denser seated tray")
	many.set_posture(true); check(many.pieces.filter(func(p):return p.visible).size()==24,"A 48-piece standing game shows twenty-four surrounding pieces")
	var dense := Session.new(); root.add_child(dense)
	check(dense.configure(b,Session.grid_for_source(b,96)) and dense.pieces.size()==96,"96 flat pieces build with the count-derived grid")
	dense.set_posture(true)
	var balanced := true; var clear_frame := true; var separate := true; var seen := {}; var standing_last := {}
	for page in 2:
		var bounds: Array[Rect2]=[]; var left := 0; var right := 0
		for piece in dense.pieces:
			if not piece.visible: continue
			seen[piece.piece_id]=true
			var low := Vector2(INF,INF); var high := Vector2(-INF,-INF)
			for corner in 8:
				var ray: Vector3=piece.transform*piece.mesh.get_aabb().get_endpoint(corner)-dense.viewer_position
				var angular := Vector2(atan2(ray.x,-ray.z),atan2(ray.y,Vector2(ray.x,ray.z).length()))
				low=low.min(angular); high=high.max(angular)
			bounds.append(Rect2(low,high-low))
			if piece.position.x<0: left+=1
			elif piece.position.x>0: right+=1
			else: clear_frame=false
			var toward := dense.viewer_position-piece.position; toward.y=0
			var direction := (piece.position-dense.viewer_position).normalized()
			var half_angle := atan(dense.frame_size().x*dense.frame_scale()*0.5/1.8)
			clear_frame=clear_frame and absf(piece.position.y)<0.75 and toward.length()<2.0 and piece.basis.z.normalized().dot(toward.normalized())>0.999 and absf(atan2(direction.x,-direction.z))>half_angle
		balanced=balanced and left==24 and right==24
		for i in bounds.size():
			for j in range(i+1,bounds.size()): separate=separate and not bounds[i].intersects(bounds[j])
		if page==1: standing_last=dense.snapshot()
		dense.next_tray()
	check(balanced and clear_frame,"Every 96-piece standing arc has twenty-four pieces on each side, facing the player and clear of the target frame")
	check(separate,"Side pieces have separate angular bounds")
	check(seen.size()==96,"All 96 pieces remain reachable through the tray pages")
	check(Session.valid_snapshot(standing_last) and standing_last.page==1,"The second dense standing page is a valid 96-piece checkpoint")
	var previous_bytes := FileAccess.get_file_as_bytes(output.path_join("games").path_join(id_b+".json"))
	var dense_id := store.create_game(asset_b,standing_last)
	check(not dense_id.is_empty() and store.get_game(dense_id).snapshot.pieces.size()==96,"96-piece checkpoints persist through the normal game store")
	var rebuilt := Session.new(); root.add_child(rebuilt); rebuilt.configure(b,dense.grid)
	check(rebuilt.restore(Store.new(output).get_game(dense_id).snapshot) and rebuilt.standing and rebuilt.tray_page==1,"Resume restores the final standing page and side layout")
	dense.set_posture(false)
	for page in 2: dense.next_tray()
	check(dense.tray_page==2 and Session.valid_snapshot(dense.snapshot()) and store.save_game(dense_id,dense.snapshot()),"The third dense seated batch also saves correctly")
	check(FileAccess.get_file_as_bytes(output.path_join("games").path_join(id_b+".json"))==previous_bytes and store.get_game(id_b).snapshot.pieces.size()==12,"Adding 96 pieces preserves existing 12-piece games and their exact progress bytes")
	dense.queue_free(); rebuilt.queue_free()
	session.queue_free(); restored.queue_free(); many.queue_free(); await process_frame
	print("Puzzle store: %d checks, %d failures" % [checks,failures.size()]); quit(0 if failures.is_empty() else 1)
