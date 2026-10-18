extends SceneTree
const Main := preload("res://scripts/main.gd")
const Store := preload("res://scripts/puzzle/puzzle_store.gd")
const Memory := preload("res://scripts/file_mode_memory.gd")
var checks := 0
var failures: Array[String]=[]
var output := ProjectSettings.globalize_path("res://../../build/output/puzzle-placement/run-")+str(Time.get_ticks_usec())
class App extends Main:
	var rays := {}
	var poses := {}
	func _ray(hand: String) -> Variant: return rays.get(hand)
	func _move_pose(hand: String) -> Variant: return poses.get(hand)
func _initialize() -> void: call_deferred("_run")
func check(ok: bool, message: String) -> void:
	checks+=1
	if not ok: failures.append(message); push_error(message)
func aim(app: Node, origin: Vector3, point: Vector3) -> void:
	app.rays.right_hand=[origin,(point-origin).normalized()]
	app.poses.right_hand=Transform3D(Basis.IDENTITY,origin)
func ready_game(host: Node) -> bool:
	var deadline := Time.get_ticks_msec()+15000
	while host.panel.preparing and Time.get_ticks_msec()<deadline: await create_timer(0.01).timeout
	return host.session!=null and host.saving_ready
func _run() -> void:
	DirAccess.make_dir_recursive_absolute(output)
	var image := Image.create(320,160,false,Image.FORMAT_RGBA8); image.fill(Color(0.3,0.55,0.8))
	var photo := output.path_join("photo.png"); image.save_png(photo)
	var app := App.new(); app.settings_path=output.path_join("settings.cfg"); root.add_child(app); app.set_process(false)
	app.photo.history_enabled=false; app.photo.mode_memory=Memory.new(output.path_join("modes"))
	app._on_library_chosen("file://"+photo,"photo.png")
	var deadline := Time.get_ticks_msec()+8000
	while app.photo.loading and Time.get_ticks_msec()<deadline: await create_timer(0.01).timeout
	app.photo.finish_transition()
	var host: Node=app.puzzle_game; host.store=Store.new(output.path_join("saved")); host.store.set_mode_enabled(true)
	for kind in ["flat","dense","relief","stereo"]:
		app.photo.set_projection(0); app.photo.stereo_sbs=kind=="stereo"; app.photo.top_bottom=false
		app.photo._metadata.native_stereo=kind=="stereo"; app.photo.depth_requested=false; app.photo.depth_enabled=kind=="relief"
		if kind=="relief":
			var depth := Image.create(8,8,false,Image.FORMAT_RF); depth.fill(Color(0.4,0,0)); app.photo._display_depth_data={"image":depth}
		else: app.photo._display_depth_data={}
		host.start(kind in ["dense","stereo"],96 if kind=="dense" else 24,false)
		check(await ready_game(host),"A real viewer starts the placement regression: "+kind)
		var model: Node=host.session
		model.set_frame_pose(Transform3D(Basis(Vector3.UP,0.12).scaled(Vector3.ONE*1.7),Vector3(0.12,0.04,0)))
		var node_count: int=model.get_child_count()
		var piece: MeshInstance3D=model.pieces.filter(func(p):return p.visible and not p.placed)[0]
		var head: Vector3=app.xr_camera.global_position
		var hand: Vector3=head+app.xr_camera.global_basis*Vector3(0.22,-0.22,-0.3)
		aim(app,hand,piece.global_position); host.ready_after_release.right_hand=true; host.button("trigger_click","right_hand")
		check(model.captures.has("right_hand") and piece.global_position.distance_to(hand)<0.4,"Pickup still brings the thick fragment close to the hand")
		if not model.captures.has("right_hand"): host.finish(); continue
		# Aim at a visibly wrong part of the frame, without consulting the saved grab anchor.
		var point: Vector3=model.to_global(piece.goal.origin+model.frame_pose.basis.x*piece.width*1.5)
		aim(app,hand,point); host.tick(0.016)
		check(piece.global_position.distance_to(hand)>0.8 and piece.visible and not piece.placed,"Pointing at the frame moves the actual fragment there before the correct slot is found")
		var dot: Node3D=app.controller_feedback.hands.right_hand.nodes.dot
		check(dot.global_position.distance_to(hand)>0.8,"The visible controller pointer reaches the actual fragment on the frame")
		check(model.get_child_count()==node_count and not model.captures.right_hand.candidate,"Placement uses the same entity without creating a second projected piece")
		aim(app,hand,head+app.xr_camera.global_basis.x*3.0); host.tick(0.016)
		check(piece.global_position.distance_to(hand)<0.4 and not model.hint.visible,"Leaving the frame brings the same entity back to the hand")
		aim(app,hand,point); host.tick(0.016)
		check(piece.global_position.distance_to(hand)>0.8,"Pointing back at the frame attaches the entity there again")
		model.random_rotation=true
		var original: Basis=piece.basis
		host.button("ax_button","right_hand")
		check(not piece.basis.is_equal_approx(original) and not model.captures.right_hand.candidate,"A rotates the actual frame-held photograph and does not accept a wrong direction")
		host.button("ax_button","left_hand")
		check(piece.basis.is_equal_approx(original),"X reverses the same entity on the frame")
		model.random_rotation=false
		var previous: Vector3=piece.position
		point+=model.frame_pose.basis.y*0.035; aim(app,hand,point); host.tick(0.016)
		host.reference_preview.pinned=true
		host.reference_preview.global_transform=Transform3D(Basis.looking_at(app.rays.right_hand[1]),hand+app.rays.right_hand[1]*0.5)
		check(host._ray_menu(hand,app.rays.right_hand[1])==host.reference_preview,"The fixture places the reference across the owning hand's aiming ray")
		point+=model.frame_pose.basis.y*0.025; aim(app,hand,point); host.tick(0.016)
		check(piece.position.distance_to(previous)>0.02 and piece.global_position.distance_to(hand)>0.8,"Moving the hand drags the actual fragment across the frame despite the reference crossing the ray")
		host.reference_preview.enabled=false
		# A player aligns the actual piece they see; no invisible capture anchor is needed.
		point+=model.global_basis*(piece.goal.origin-piece.position)
		aim(app,hand,point); host.tick(0.016)
		check(model.captures.right_hand.candidate and model.hint.visible,"Aligning the physical fragment produces a magnetic candidate")
		check(piece.position.distance_to(piece.goal.origin)<0.015,"The same entity magnetically settles into its destination")
		var tolerance: float=clampf(piece.width*0.15,0.02,0.05)*model.frame_scale()
		point+=model.frame_pose.basis.x.normalized()*tolerance*1.1
		aim(app,hand,point); host.tick(0.016)
		check(model.captures.right_hand.candidate,"A small hand tremor retains the visible magnetic candidate until release")
		host.button("trigger_click","right_hand",true)
		check(piece.placed and model.completed()==1 and piece.visible and model.get_child_count()==node_count,"Releasing leaves the same physical fragment in the frame without a duplicate")
		check(host.store.get_game(host.game_id).snapshot.pieces.filter(func(p):return p.placed).size()==1,"The successful placement persists to this game's independent save")
		piece=model.pieces.filter(func(p):return p.visible and not p.placed)[0]
		aim(app,hand,piece.global_position); host.button("trigger_click","right_hand")
		point=model.to_global(piece.goal.origin+model.frame_pose.basis.x*piece.width*1.5)
		aim(app,hand,point); host.tick(0.016)
		check(piece.global_position.distance_to(hand)>0.8 and not model.captures.right_hand.candidate,"The next actual fragment follows the pointer onto a wrong part of the frame")
		host.button("trigger_click","right_hand",true)
		check(not piece.placed and piece.returning and model.completed()==1,"Dropping at a wrong location returns the actual fragment to the tray and preserves earlier progress")
		host.finish(); app.rays.clear(); app.poses.clear()
	app.photo.close_image(); app.queue_free(); await process_frame; await process_frame
	print("Puzzle placement: %d checks, %d failures" % [checks,failures.size()]); quit(0 if failures.is_empty() else 1)
