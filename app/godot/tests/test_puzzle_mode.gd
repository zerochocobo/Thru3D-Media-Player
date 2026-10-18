extends SceneTree
var Main: GDScript
const Store := preload("res://scripts/puzzle/puzzle_store.gd")
const Memory := preload("res://scripts/file_mode_memory.gd")
var checks := 0
var failures: Array[String]=[]
var output := ProjectSettings.globalize_path("res://../../build/output/puzzle-mode/flow-")+str(Time.get_ticks_usec())
func _initialize() -> void: call_deferred("_run")
func check(ok: bool, message: String) -> void:
	checks+=1
	if not ok: failures.append(message); push_error(message)
func has_button(menu: Node, id: int) -> bool: return menu._buttons.any(func(button):return button.target==id)
func photo_ready(app: Node) -> void:
	var deadline := Time.get_ticks_msec()+6000
	while app.photo.loading and Time.get_ticks_msec()<deadline: await create_timer(0.01).timeout
	app.photo.finish_transition(); app.photo_menu.dismiss(); app.recent_menu.dismiss(); app.puzzle_game._update_photo_entry()
func _run() -> void:
	for name in ["puzzle_host","puzzle_photo_menu","puzzle_library_menu"]:
		var source := FileAccess.get_file_as_string("res://scripts/puzzle/"+name+".gd")
		check(not source.contains("OS.is_debug_build()"),"Production puzzle entry cannot depend on the Debug feature: "+name)
	# Exercise the real application with its development-only branches disabled.
	Main=GDScript.new(); Main.source_code=FileAccess.get_file_as_string("res://scripts/main.gd").replace("OS.is_debug_build()","false")
	check(Main.reload()==OK,"The application compiles with Release conditions for the mode-entry regression")
	DirAccess.make_dir_recursive_absolute(output)
	var image := Image.create(240,160,false,Image.FORMAT_RGB8); image.fill(Color(0.25,0.5,0.7))
	var path := output.path_join("mode.png"); image.save_png(path)
	var app: Node=Main.new(); app.settings_path=output.path_join("settings.cfg"); root.add_child(app)
	app.set_process(false); app.photo.history_enabled=false; app.photo.mode_memory=Memory.new(output.path_join("modes"))
	var host: Node=app.puzzle_game; host.store=Store.new(output.path_join("saved"))
	host.store.remember(false,12)
	app.recent_menu.refresh()
	check(not has_button(app.recent_menu,app.recent_menu.PUZZLE_OPEN),"Home has no empty progress shortcut on a fresh profile")
	app.recent_menu.media_filter=2; app.recent_menu.refresh()
	check(has_button(app.recent_menu,app.recent_menu.PUZZLE_OPEN),"Images offer a first-time puzzle-mode entry with no progress")
	app.recent_menu._activate(app.recent_menu.PUZZLE_OPEN)
	check(host.active and not host.panel.can_start and not has_button(host.panel,14) and has_button(host.panel,13),"The default hub contains mode and progress without an image-browser link")
	host.panel._activate(13)
	check(host.mode_enabled and Store.new(host.store.directory).mode_enabled(),"Turning mode on is explicit and durable")
	check(app.photo_menu._buttons.filter(func(b):return b.target==app.photo_menu.PHOTO_PUZZLE)[0].base_color==app.photo_menu.ACCENT,"Enabled mode uses the green status icon")
	host.finish(); app._show_full_library()
	check(not host.active and app.recent_menu.visible and app.recent_menu.media_filter==0,"Closing mode settings does not force the browser into an image filter")
	app.recent_menu._choose({"uri":"file://"+path,"title":"mode.png","kind":"image"})
	await photo_ready(app)
	check(host.photo_entry.visible and not host.active and host.store.unfinished().is_empty(),"Opening a large image shows its entry without automatically creating or starting a game")
	check(app.menu_composition.menus.has(host.photo_entry),"The large-image entry uses the normal high-density menu capture")
	var entry_pose: Transform3D=host.photo_entry.global_transform
	app.hand_pointers.right_hand.source="hand"
	var photo_centre: Vector3=(app.photo.global_transform*app.photo.flat_pose).origin
	app.hand_pointers.right_hand.ray=[app.xr_camera.global_position,(photo_centre-app.xr_camera.global_position).normalized()]
	check(app._active_menu()==null,"The entry does not capture ordinary photo gestures when the ray points elsewhere")
	app.hand_pointers.right_hand.ray=[entry_pose.origin+entry_pose.basis.z,-entry_pose.basis.z]
	check(app._active_menu()==host.photo_entry,"A real ray hit reserves the image entry before photo pinch gestures")
	app._dispatch_hand_input({"right_hand":{"source":"hand","tracked":true,"down":true,"pressed":true}})
	check(host.active and host.panel.mode=="setup" and host.panel._backdrop.mesh.size.x<0.65 and has_button(host.panel,50) and not has_button(host.panel,100),"Pinching Enter puzzle game opens a compact posture and piece-count popup without the full progress window")
	check(host.panel.difficulty_counts()==[24,48,96] and host.panel.piece_count==24,"New flat games remove 12, add 96 and replace the old 12-piece preference with 24")
	app.hand_pointers.right_hand.source="none"; app.hand_pointers.right_hand.ray=null
	host.panel._activate(10)
	check(host.session==null,"Choosing posture alone does not prematurely begin a game")
	host.panel._activate(17)
	var deadline := Time.get_ticks_msec()+10000
	while host.panel.preparing and Time.get_ticks_msec()<deadline: await create_timer(0.01).timeout
	check(host.saving_ready and host.session.source.uri=="file://"+path,"The first game starts with the selected image")
	if not host.saving_ready: app.queue_free(); quit(1); return
	check(not host.has_progress(),"A just-created zero-piece checkpoint does not expose Home's progress shortcut")
	var id: String=host.game_id; var piece: MeshInstance3D=host.session.pieces.filter(func(p):return p.visible)[0]; piece.transform=piece.goal
	app.hand_pointers.right_hand.source="hand"; app.hand_pointers.right_hand.ray=[piece.global_position+host.session.global_basis.z,-host.session.global_basis.z]
	host.ready_after_release.right_hand=true; host.button("trigger_click","right_hand"); host.button("trigger_click","right_hand",true)
	app.hand_pointers.right_hand.source="none"; app.hand_pointers.right_hand.ray=null
	check(host.has_progress() and host.store.get_game(id).snapshot.pieces[piece.piece_id].placed,"A real snapped piece makes a resumable Home entry")
	host.finish(); app._show_full_library(); app.recent_menu.media_filter=0; app.recent_menu.refresh()
	check(has_button(app.recent_menu,app.recent_menu.PUZZLE_OPEN),"Home shows the shortcut after actual progress is saved")
	app.recent_menu._activate(app.recent_menu.PUZZLE_OPEN); host.panel._activate(12)
	check(not host.mode_enabled and not Store.new(host.store.directory).mode_enabled() and host.panel.records.size()==1,"Turning the mode off preserves the unfinished game")
	host.finish(); app.recent_menu.dismiss(); app.photo_menu.dismiss(); host._update_photo_entry()
	check(not host.photo_entry.visible,"Mode off hides the entry on a large image")
	host.open_hub(); host.panel._activate(13); host.store.remember(true)
	check(Store.new(host.store.directory).mode_enabled() and host.store.preferences().standing,"The last-play posture does not erase the mode switch")
	host._action("delete:"+id); host.finish(); app._show_full_library(); app.recent_menu.media_filter=0; app.recent_menu.refresh()
	check(not has_button(app.recent_menu,app.recent_menu.PUZZLE_OPEN),"Deleting the last progressed game immediately removes Home's shortcut")
	app.recent_menu.media_filter=2; app.recent_menu.refresh(); app.recent_menu._activate(app.recent_menu.PUZZLE_OPEN)
	host._action("undo"); host.finish(); app._show_full_library(); app.recent_menu.media_filter=0; app.recent_menu.refresh()
	check(has_button(app.recent_menu,app.recent_menu.PUZZLE_OPEN),"Undo restores the existing progressed Home entry")
	image=Image.create(320,160,false,Image.FORMAT_RGB8); image.fill(Color(0.5,0.3,0.2))
	var panorama := output.path_join("panorama.png"); image.save_png(panorama)
	app._on_library_chosen("file://"+panorama,"panorama.png"); await photo_ready(app); app.photo.set_projection(3); host._update_photo_entry()
	check(host.photo_entry.visible,"The remembered mode also exposes Enter puzzle game for a full 360 photo")
	var fixed_pose: Transform3D=host.photo_entry.global_transform; app.xr_camera.rotation.y+=0.5; host._update_photo_entry()
	check(host.photo_entry.global_transform==fixed_pose,"The panorama entry remains fixed when the player turns their head")
	app.photo.loading=true; host._update_photo_entry()
	check(not host.photo_entry.visible,"Loading a replacement image cannot leave the previous image's playable entry")
	app.photo.loading=false; host._update_photo_entry(); app._close_current_media(); host._update_photo_entry()
	check(not host.photo_entry.visible,"Closing the image hides its puzzle entry")
	app.queue_free(); await process_frame
	print("Puzzle mode: %d checks, %d failures" % [checks,failures.size()]); quit(0 if failures.is_empty() else 1)
