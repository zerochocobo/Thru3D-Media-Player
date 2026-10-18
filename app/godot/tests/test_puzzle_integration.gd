extends SceneTree
const Main := preload("res://scripts/main.gd")
const Source := preload("res://scripts/puzzle/puzzle_source.gd")
const Memory := preload("res://scripts/file_mode_memory.gd")
var checks := 0
var failures: Array[String] = []
var output := ProjectSettings.globalize_path("res://../../build/output/puzzle-p0/integration")

func _initialize() -> void: call_deferred("_run")
func check(ok: bool, message: String) -> void:
	checks+=1
	if not ok: failures.append(message); push_error(message)

func ready_game(app: Node) -> void:
	var deadline := Time.get_ticks_msec()+8000
	while app.puzzle_game.active and app.puzzle_game.panel.preparing and Time.get_ticks_msec()<deadline:
		await create_timer(0.01).timeout

func _run() -> void:
	DirAccess.make_dir_recursive_absolute(output)
	var app := Main.new(); app.settings_path=output.path_join("settings.cfg"); root.add_child(app)
	app.set_process(false); app.photo.history_enabled=false; app.photo.mode_memory=Memory.new(output.path_join("modes"))
	var image := Image.create(180,120,false,Image.FORMAT_RGB8); image.fill(Color(0.3,0.6,0.8))
	var path := output.path_join("fixture.png"); image.save_png(path)
	app._on_library_chosen("file://"+path,"fixture.png")
	var deadline := Time.get_ticks_msec()+5000
	while app.photo.loading and Time.get_ticks_msec()<deadline: await create_timer(0.01).timeout
	app.photo.finish_transition()
	check(app.photo_active and not app.photo.loading and app.photo.error.is_empty(),"Fixture loads through normal photo viewer")
	var original_pose: Transform3D=app.photo.flat_pose
	var original_layer: bool=app.photo.layer_enabled
	check(app.puzzle_game!=null,"Normal application creates puzzle host")
	app.photo_menu.refresh()
	check(app.photo_menu._buttons.any(func(b):return b.target==app.photo_menu.PHOTO_PUZZLE and b.enabled),"Debug photo toolbar exposes playable puzzle entry")
	app._on_photo_action("photo_puzzle")
	check(app.puzzle_game.panel.mode=="hub","Photo action opens the global game entry")
	check(app.menu_composition.menus.has(app.puzzle_game.panel),"Game entry registers its actual menu for the normal high-density compositor")
	app.puzzle_game.start(false)
	check(app.puzzle_game.active and app.puzzle_game.panel.preparing and app.photo.visible,"Original photo stays visible during asynchronous preparation")
	await ready_game(app)
	check(app.puzzle_game.active and app.puzzle_game.session.pieces.size()==24,"Photo action starts a default 24-piece real-image game")
	check(not app.photo.visible and not app.photo.layer_enabled and not app.photo.is_processing(),"Viewer and photo compositor pause while game owns the view")
	check(app.puzzle_game.session.source.texture==app.photo._texture,"Existing full texture is shared, not copied per piece")
	var held_piece: MeshInstance3D=app.puzzle_game.session.pieces.filter(func(p):return p.visible)[0]
	var ray_origin: Vector3=held_piece.global_position+app.puzzle_game.session.global_basis.z
	app.hand_pointers.right_hand.source="hand"
	app.hand_pointers.right_hand.ray=[ray_origin,-app.puzzle_game.session.global_basis.z]
	app.puzzle_game.ready_after_release.right_hand=true
	app._dispatch_hand_input({"right_hand":{"source":"hand","tracked":true,"down":true,"pressed":true}})
	check(app.puzzle_game.session.captures.has("right_hand"),"Existing bare-hand dispatch acquires a real puzzle piece")
	app.puzzle_game.tick(0.016)
	check(app.controller_feedback.hands.right_hand.nodes.line.visible and app.controller_feedback.hands.right_hand.nodes.line.scale.y>0.8,"A held piece has a visible aiming ray extending beyond the hand")
	app._dispatch_hand_input({"right_hand":{"source":"hand","tracked":false,"cancelled":true}})
	check(app.puzzle_game.session.captures.is_empty() and app.puzzle_game.session.completed()==0,"Bare-hand tracking loss cancels without committing progress")
	app.hand_pointers.right_hand.ray=null; app.puzzle_game.tick(0.016)
	check(not app.controller_feedback.hands.right_hand.nodes.dot.visible,"Tracking loss removes stale world pointer graphics")
	held_piece.transform=held_piece.goal; held_piece.position.x+=0.02
	app.hand_pointers.right_hand.ray=[held_piece.global_position+app.puzzle_game.session.global_basis.z,-app.puzzle_game.session.global_basis.z]
	app.puzzle_game.ready_after_release.right_hand=true
	app._dispatch_hand_input({"right_hand":{"source":"hand","tracked":true,"down":true,"pressed":true}})
	app._dispatch_hand_input({"right_hand":{"source":"hand","tracked":true,"down":false,"released":true}})
	check(app.puzzle_game.session.completed()==1 and app.puzzle_game.sound.counts.snap==1,"Bare-hand release commits one snap and plays its quiet feedback sound")
	app.hand_pointers.right_hand.source="none"; app.hand_pointers.right_hand.ray=null
	app._on_pointer_button("menu_button","left_hand")
	check(app.puzzle_game.panel.visible and app._active_menu()==app.puzzle_game.panel and app.puzzle_game.session.paused,"Application menu summons independent game surface and pauses placement")
	app.puzzle_game._action("reference")
	check(not app.puzzle_game.reference_preview.enabled,"Reference defaults on and can be hidden from game controls")
	app._on_pointer_button("menu_button","left_hand")
	check(not app.puzzle_game.panel.visible and not app.puzzle_game.session.paused,"Second menu press resumes game")
	var menu_key := InputEventKey.new(); menu_key.keycode=KEY_TAB; menu_key.pressed=true
	Input.parse_input_event(menu_key); await process_frame
	check(app.puzzle_game.panel.visible,"A desktop menu key is consumed once, without toggling twice through both input callbacks")
	menu_key=InputEventKey.new(); menu_key.keycode=KEY_TAB; menu_key.pressed=true
	Input.parse_input_event(menu_key); await process_frame
	check(not app.puzzle_game.panel.visible,"Next desktop menu key closes the game panel")
	app._notification(Main.NOTIFICATION_APPLICATION_FOCUS_OUT)
	check(app.puzzle_game.panel.visible and app.puzzle_game.session.paused,"Focus loss safely parks interaction")
	app._notification(Main.NOTIFICATION_APPLICATION_FOCUS_IN)
	app.puzzle_game.finish()
	check(not app.puzzle_game.active and app.photo.visible and app.photo.is_processing(),"Exit restores original viewer")
	check(app.menu_composition.menus.size()==4,"Game exit unregisters its temporary menu without removing player or music menus")
	check(app.photo.layer_enabled==original_layer and app.photo.flat_pose==original_pose,"Photo pose and compositor policy survive the round trip")
	check(app.photo.local_uri=="file://"+path,"Original source stays open")
	app.photo.loading=true
	check(Source.from_photo(app.photo).has("error"),"Loading photo cannot start a stale game")
	app.photo.loading=false
	var depth := Image.create(8,8,false,Image.FORMAT_RF); depth.fill(Color(0.6,0,0))
	app.photo._display_depth_data={"image":depth}; app.photo.depth_enabled=true
	var converted := Source.from_photo(app.photo)
	check(converted.kind=="relief" and converted.layout==0 and converted.depth==depth,"Converted image passes shared depth to geometric relief, without stereo being applied twice")
	check(app.puzzle_game.start(),"Converted photo starts a background preparation job")
	await ready_game(app)
	check(not app.puzzle_game.session.preparing and app.puzzle_game.session.source.kind=="relief","Current converted photo starts a real relief puzzle")
	print("Puzzle relief preparation_ms=%.2f worker_ms=%.2f max_main_commit_ms=%.2f" % [app.puzzle_game.preparation_ms,app.puzzle_game.session.builder.cpu_ms,app.puzzle_game.session.max_commit_ms])
	app.puzzle_game.finish()
	check(app.puzzle_game.start(),"Another background build can start")
	app.puzzle_game.finish()
	check(not app.puzzle_game.active and app.photo.visible,"Cancelling preparation restores the viewer and joins only its own worker")
	app.photo.depth_enabled=false; app.photo.depth_requested=true
	check(Source.from_photo(app.photo).has("error"),"Pending 3D never silently becomes a flat puzzle")
	app.photo.depth_requested=false; app.photo.stereo_sbs=true; app.photo.swap_eyes=true
	var spatial := Source.from_photo(app.photo)
	check(spatial.kind=="stereo" and spatial.layout==1 and spatial.depth==null and spatial.swap_eyes,"Spatial source preserves both eyes and eye order without reusing cached monocular depth")
	check(spatial.size==Vector2(90,120),"Packed stereo aspect is normalized per eye")
	app.photo.stereo_sbs=false; app.photo.swap_eyes=false; app.photo._display_depth_data={}
	app.queue_free(); await process_frame; await process_frame
	print("Puzzle integration: %d checks, %d failures" % [checks,failures.size()])
	quit(0 if failures.is_empty() else 1)
