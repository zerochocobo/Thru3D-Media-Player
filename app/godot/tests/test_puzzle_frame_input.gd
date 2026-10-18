extends SceneTree
const Main := preload("res://scripts/main.gd")
const Store := preload("res://scripts/puzzle/puzzle_store.gd")
const Memory := preload("res://scripts/file_mode_memory.gd")
const Session := preload("res://scripts/puzzle/puzzle_session.gd")
var checks := 0
var failures: Array[String]=[]
var output := ProjectSettings.globalize_path("res://../../build/output/puzzle-frame/flow-")+str(Time.get_ticks_usec())
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
	var deadline := Time.get_ticks_msec()+12000
	while host.active and host.panel.preparing and Time.get_ticks_msec()<deadline: await create_timer(0.01).timeout
	return host.session!=null and host.saving_ready
func aim(app: Node, hand: String, origin: Vector3, target: Vector3) -> void:
	var direction := (target-origin).normalized()
	app.rays[hand]=[origin,direction]; app.poses[hand]=Transform3D(Basis.looking_at(direction,Vector3.UP),origin)
func sample(point: Vector3, down: bool, pressed: bool = false, released: bool = false) -> Dictionary:
	return {"source":"hand","tracked":true,"position":point,"down":down,"pressed":pressed,"released":released}
func _run() -> void:
	DirAccess.make_dir_recursive_absolute(output)
	var image := Image.create(180,120,false,Image.FORMAT_RGBA8); image.fill(Color(0.3,0.6,0.8))
	var path := output.path_join("frame.png"); image.save_png(path)
	var app := App.new(); app.settings_path=output.path_join("settings.cfg"); root.add_child(app); app.set_process(false)
	app.photo.history_enabled=false; app.photo.mode_memory=Memory.new(output.path_join("modes"))
	app._on_library_chosen("file://"+path,"frame.png")
	var deadline := Time.get_ticks_msec()+5000
	while app.photo.loading and Time.get_ticks_msec()<deadline: await create_timer(0.01).timeout
	app.photo.finish_transition()
	var host: Node=app.puzzle_game; host.store=Store.new(output.path_join("saved")); host.start(true)
	check(await ready_game(host),"Frame controls start on a real standing puzzle")
	if not host.saving_ready: app.queue_free(); quit(1); return
	var game_id: String=host.game_id; var session: Node=host.session
	host.tick(0.016)
	var initial: Transform3D=session.frame_world_pose(); var dock: Transform3D=host.dock.global_transform
	check((dock.origin-initial.origin).dot(initial.basis.y)<-session.board_size.y*0.5,"Flat menu handle is below the target frame")
	app.xr_camera.rotation.y+=0.3; host.tick(0.016)
	check(host.dock.global_transform==dock,"Turning the head does not drag the flat menu away from its frame")
	host.button("menu_button","left_hand")
	check(host.panel.visible and host.panel.global_position.y<session.frame_world_pose().origin.y-session.board_size.y*0.5,"Menu button summons controls below the flat frame")
	host._action("help")
	check(host.panel.global_position.y+host.panel.layout_height()*0.5<initial.origin.y-session.board_size.y*0.5,"The taller frame-control help also fits below the picture")
	host._action("continue")
	host.button("menu_button","left_hand")
	var free_piece: MeshInstance3D=session.pieces.filter(func(p):return p.visible)[0]
	var free_pose: Transform3D=free_piece.transform
	var head: Vector3=app.xr_camera.global_position
	var origin := head+Vector3(0.2,-0.2,-0.2)
	aim(app,"right_hand",origin,initial.origin)
	host.ready_after_release.right_hand=true; host.button("grip_click","right_hand")
	check(not host.frame_input.movement.capture.is_empty() and session.captures.is_empty(),"Grip on the blank frame captures picture movement rather than a piece")
	app.poses.right_hand=app.poses.right_hand.translated(Vector3(0.15,0.1,0)); host.tick(0.016)
	check(session.frame_world_pose().origin.distance_to(initial.origin)>0.05,"The existing photo grip solver moves the target frame")
	check(free_piece.transform!=free_pose and not free_piece.placed,"Moving the target reflows unplaced pieces away from its new picture bounds")
	host.button("grip_click","right_hand",true)
	check(host.frame_input.movement.capture.is_empty() and not host.dirty,"Releasing grip finishes and saves the frame pose")
	var piece: MeshInstance3D=session.pieces.filter(func(p):return p.visible)[0]; piece.transform=piece.goal
	aim(app,"right_hand",piece.global_position+session.global_basis.z,piece.global_position)
	host.ready_after_release.right_hand=true; host.button("trigger_click","right_hand"); host.button("trigger_click","right_hand",true)
	if piece.motion!=null and piece.motion.is_running(): await piece.motion.finished
	check(piece.placed,"A moved frame still accepts a real snapped piece")
	var world: Transform3D=session.frame_world_pose()
	var before_resize: float=session.frame_scale()
	var corner := Vector3(session.frame_size().x*0.5,session.frame_size().y*0.5,0)
	aim(app,"right_hand",head,world*corner); host.tick(0.016)
	check(session.frame_handles!=null and session.frame_handles.visible,"Corner hover shows the same visual resize affordance")
	host.ready_after_release.right_hand=true; host.button("trigger_click","right_hand")
	check(not host.frame_input.resize.is_empty(),"Trigger at a corner begins resize")
	aim(app,"right_hand",head,world*(corner*1.4)); host.tick(0.016)
	check(is_equal_approx(session.frame_scale(),before_resize*1.4) and piece.transform.is_equal_approx(piece.goal),"Corner resize scales the target and solved piece together")
	aim(app,"right_hand",head,world*(corner*1.5))
	host.button("trigger_click","right_hand",true)
	check(is_equal_approx(session.frame_scale(),before_resize*1.5) and Session.valid_snapshot(host.store.get_game(game_id).snapshot),"Corner release uses the latest ray and saves a valid checkpoint")
	app.hand_pointers.left_hand.source="hand"; app.hand_pointers.right_hand.source="hand"
	var left := head+Vector3(-0.2,-0.2,-0.3); var right := head+Vector3(0.2,-0.2,-0.3)
	aim(app,"right_hand",right,session.frame_world_pose().origin)
	app._dispatch_hand_input({"right_hand":sample(right,true,true)})
	var before_pinch: Transform3D=session.frame_pose
	right.x+=0.06; aim(app,"right_hand",right,session.frame_world_pose().origin+Vector3(0.10,0.05,0))
	app._dispatch_hand_input({"right_hand":sample(right,true)})
	check(not session.frame_pose.is_equal_approx(before_pinch) and session.captures.is_empty(),"Single-hand pinch drags the frame through the same photo movement solver")
	app._dispatch_hand_input({"right_hand":{"source":"hand","tracked":false,"cancelled":true}})
	check(host.frame_input.movement.capture.is_empty() and not host.dirty,"Losing optical tracking cancels frame movement and saves the last valid pose")
	right=head+Vector3(0.2,-0.2,-0.3)
	aim(app,"left_hand",left,session.frame_world_pose().origin); aim(app,"right_hand",right,session.frame_world_pose().origin)
	app._dispatch_hand_input({"left_hand":sample(left,true,true),"right_hand":sample(right,true,true)})
	var zoom: float=session.frame_scale()
	left.x-=0.2; right.x+=0.2
	aim(app,"left_hand",left,session.frame_world_pose().origin); aim(app,"right_hand",right,session.frame_world_pose().origin)
	app._dispatch_hand_input({"left_hand":sample(left,true),"right_hand":sample(right,true)})
	check(is_equal_approx(session.frame_scale(),zoom*2) and session.captures.is_empty(),"The photo two-hand pinch recognizer enlarges the frame without taking pieces")
	left.x-=0.7; right.x+=0.7
	aim(app,"left_hand",left,session.frame_world_pose().origin); aim(app,"right_hand",right,session.frame_world_pose().origin)
	app._dispatch_hand_input({"left_hand":sample(left,true),"right_hand":sample(right,true)})
	check(is_equal_approx(session.frame_scale(),6.0),"Frame scale uses the photo's upper size limit")
	app._dispatch_hand_input({"left_hand":sample(left,false,false,true),"right_hand":sample(right,true)})
	var fixed: Transform3D=session.frame_pose
	app._dispatch_hand_input({"left_hand":sample(left,false),"right_hand":sample(right+Vector3(0.1,0,0),true)})
	check(session.frame_pose==fixed,"The remaining hand cannot drag immediately after a two-hand gesture")
	app._dispatch_hand_input({"left_hand":sample(left,false),"right_hand":sample(right,false,false,true)})
	check(piece.transform==piece.goal and Session.valid_snapshot(host.store.get_game(game_id).snapshot),"A six-times scaled solved piece and frame persist successfully")
	var next: MeshInstance3D=session.pieces.filter(func(p):return p.visible and not p.placed)[0]
	aim(app,"right_hand",head,next.global_position); host.ready_after_release.right_hand=true; host.button("trigger_click","right_hand")
	check(session.captures.has("right_hand") and session.captures.right_hand.id==next.piece_id,"The scaled board still allows a loose piece to be picked first")
	if session.captures.has("right_hand"):
		var target: Vector3=session.global_transform*(next.goal*session.captures.right_hand.anchor)
		aim(app,"right_hand",head,target); host.button("trigger_click","right_hand",true)
		if next.motion!=null and next.motion.is_running(): await next.motion.finished
	check(next.placed and next.transform.is_equal_approx(next.goal),"A fresh release projects and snaps onto the resized frame without an intervening tick")
	var saved: Transform3D=session.frame_pose
	app.rays.clear(); app.poses.clear(); app.hand_pointers.left_hand.source="none"; app.hand_pointers.right_hand.source="none"
	host.finish(); host.resume_game(game_id)
	check(await ready_game(host) and host.session.frame_pose.is_equal_approx(saved) and host.session.completed()==2,"Resume restores frame position, size and solved state")
	session=host.session; host.show_panel(false)
	var candidate: MeshInstance3D=session.pieces.filter(func(p):return p.visible and not p.placed)[0]
	aim(app,"right_hand",head,candidate.global_position); app.hand_pointers.right_hand.source="hand"
	app._dispatch_hand_input({"right_hand":sample(right,true,true)})
	check(session.captures.has("right_hand"),"A pinch on a loose fragment keeps piece ownership")
	aim(app,"left_hand",left,session.frame_world_pose().origin); app.hand_pointers.left_hand.source="hand"
	app._dispatch_hand_input({"right_hand":sample(right,true),"left_hand":sample(left,true,true)})
	check(session.frame_pose.is_equal_approx(saved) and host.frame_input.gestures.owners.is_empty(),"A held piece blocks accidental two-hand frame scaling")
	app._dispatch_hand_input({"right_hand":{"source":"hand","tracked":false,"cancelled":true},"left_hand":sample(left,false,false,true)})
	check(session.captures.is_empty() and session.completed()==2,"Tracking loss cancels piece interaction without changing solved progress")
	session.set_frame_pose(saved.translated(Vector3(0,0,-6))); session.scatter(true)
	var far: MeshInstance3D=session.pieces.filter(func(p):return p.visible and not p.placed)[0]
	check(far.global_position.distance_to(head)<2.1 and not session.pick(head,(far.global_position-head).normalized()).is_empty(),"A distant or enlarged frame keeps its side pieces near the player and easy to pick")
	check(host.save_now(),"A distant frame and reorganized side trays still save normally")
	app.rays.clear(); app.poses.clear(); host.finish(); app.queue_free(); await process_frame; await process_frame
	print("Puzzle frame input: %d checks, %d failures" % [checks,failures.size()]); quit(0 if failures.is_empty() else 1)
