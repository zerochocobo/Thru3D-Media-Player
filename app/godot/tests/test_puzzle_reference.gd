extends SceneTree
const Main := preload("res://scripts/main.gd")
const Store := preload("res://scripts/puzzle/puzzle_store.gd")
const Memory := preload("res://scripts/file_mode_memory.gd")
var checks := 0
var failures: Array[String]=[]
var output := ProjectSettings.globalize_path("res://../../build/output/puzzle-reference/run-")+str(Time.get_ticks_usec())
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
	while host.panel.preparing and Time.get_ticks_msec()<deadline: await create_timer(0.01).timeout
	return host.session!=null and host.saving_ready
func click(app: Node, preview: Node, target: int) -> void:
	for button in preview._buttons:
		if button.target!=target: continue
		var point: Vector3=button.node.global_position
		app.rays.right_hand=[point+preview.global_basis.z*0.4,-preview.global_basis.z]
		app.puzzle_game.ready_after_release.right_hand=true
		app.puzzle_game.button("trigger_click","right_hand"); app.puzzle_game.button("trigger_click","right_hand",true)
		return
func _run() -> void:
	DirAccess.make_dir_recursive_absolute(output)
	var image := Image.create(320,160,false,Image.FORMAT_RGB8); image.fill(Color(0.4,0.7,0.8))
	var path := output.path_join("reference.png"); image.save_png(path)
	var app := App.new(); app.settings_path=output.path_join("settings.cfg"); root.add_child(app); app.set_process(false)
	app.photo.history_enabled=false; app.photo.mode_memory=Memory.new(output.path_join("modes"))
	app._on_library_chosen("file://"+path,"reference.png")
	var deadline := Time.get_ticks_msec()+6000
	while app.photo.loading and Time.get_ticks_msec()<deadline: await create_timer(0.01).timeout
	app.photo.finish_transition()
	var host: Node=app.puzzle_game; host.store=Store.new(output.path_join("saved"))
	for spherical in [false,true]:
		app.photo.set_projection(3 if spherical else 0); host.start(false); check(await ready_game(host),"Reference prepares with its real photo puzzle")
		if not host.saving_ready: quit(1); return
		var preview: Node=host.reference_preview
		var status: Node=host.dock.device_status
		check(app.menu_composition.menus.has(preview) and preview.source.texture==host.session.source.texture,"Reference shares the photo texture and registers for normal menu clarity")
		status.status_provider=func():return {"level":82,"charging":false,"clock24":true}
		status.clock_provider=func():return {"hour":23,"minute":58}
		status.refresh(true)
		host.show_panel(true); host.show_panel(false)
		var head: Vector3=app.xr_camera.global_position
		app.poses.left_hand=Transform3D(Basis.IDENTITY,head+Vector3(-0.2,-0.25,-0.4)); host.tick(0.016)
		check(preview.visible and preview.hand_attached,"Reference follows an available off-hand controller while the game continues")
		check(preview.device_status==null and status.position.y< -0.06 and status.text_snapshot().contains("82%") and status.text_snapshot().contains("23:58"),"Battery and time appear below the front menu, with no duplicate on the thumbnail")
		status.clock_provider=func():return {"hour":23,"minute":59}
		status.refresh()
		check(status.text_snapshot().contains("23:59"),"Clock advances on the front menu")
		preview.place(app,host.session,{},0)
		var stable: Transform3D=preview.global_transform
		app.poses.left_hand.basis=Basis(Vector3.BACK,PI*0.4); preview.place(app,host.session,{},0)
		check(preview.global_transform.is_equal_approx(stable),"Turning the wrist cannot orbit or reverse-rotate the reference")
		var palm := head+Vector3(-0.16,-0.20,-0.45)
		preview.place(app,host.session,{"left_hand":{"reference_position":palm,"pose":app.poses.left_hand}},0)
		check(preview.global_position.y>=palm.y+0.17 and preview.global_position.distance_to(palm)<0.23 and preview.global_basis.z.dot((head-preview.global_position).normalized())>0.999,"The reference follows the palm above the hand and automatically faces the eyes")
		var palm_before: Vector3=preview.global_position
		preview.place(app,host.session,{"left_hand":{"reference_position":palm+Vector3.RIGHT*0.1}},0)
		check(is_equal_approx(preview.global_position.x-palm_before.x,0.1),"Reference translation follows palm motion with the correct sign even without wrist orientation")
		click(app,preview,1); var pinned: Transform3D=preview.global_transform
		app.poses.left_hand.origin+=Vector3(0.15,0.1,0); host.tick(0.016)
		check(preview.pinned and preview.global_transform==pinned and host.session.captures.is_empty(),"A real ray pins the thumbnail without moving or grabbing any puzzle piece")
		var start: Vector3=preview.global_position; var axes: Basis=preview.global_basis
		var origin := start+axes.z*0.4
		app.rays.right_hand=[origin,-axes.z]; host.ready_after_release.right_hand=true; host.button("trigger_click","right_hand")
		check(preview.has_pointer_capture() and preview.pinned,"A real ray can grab the thumbnail after hand-follow is disabled")
		app.rays.right_hand=[origin+axes.x*0.18,-axes.z]; host.tick(0.05); host.button("trigger_click","right_hand",true)
		check(not preview.has_pointer_capture() and preview.pinned and (preview.global_position-start).dot(axes.x)>0.17 and host.session.captures.is_empty(),"Dragging the pinned reference moves it in the same direction without taking a game piece")
		var fixed: Vector3=preview.global_position; host.tick(0.05)
		check(preview.global_position.is_equal_approx(fixed),"Releasing a dragged reference keeps its new position")
		pinned=preview.global_transform
		click(app,preview,1); app.rays.clear(); host.tick(0.2)
		check(not preview.pinned and preview.global_position.distance_to(pinned.origin)>0.05,"Follow resumes after unpinning")
		app.poses.clear(); host.tick(1.0)
		check(preview.visible and not preview.hand_attached,"Missing hand tracking uses a fixed fallback instead of losing the reference")
		app.hand_pointers.left_hand.source="hand"
		host.frame_input.samples={"left_hand":{"pose":Transform3D(Basis.IDENTITY,head+Vector3(-0.15,-0.2,-0.35))}}
		host.tick(1.0); check(preview.hand_attached,"The same thumbnail follows a tracked optical hand")
		app.hand_pointers.left_hand.source="none"; host.frame_input.samples.clear()
		host.show_panel(true); host.tick(0.016)
		check(not preview.visible and host.panel.visible,"The independent game menu keeps input priority over the reference")
		host.show_panel(false); host.tick(0.016); click(app,preview,2); host.tick(0.016)
		check(not preview.enabled and not preview.visible,"The thumbnail closes through its own ray button")
		check(host.dock.visible and status.is_visible_in_tree() and status.text_snapshot().contains("23:59"),"Front clock remains visible after closing the thumbnail")
		app.rays.clear(); host.finish()
		check(not app.menu_composition.menus.has(preview),"Exiting unregisters the thumbnail and status with the game")
	app.queue_free(); await process_frame; await process_frame
	print("Puzzle reference: %d checks, %d failures" % [checks,failures.size()]); quit(0 if failures.is_empty() else 1)
