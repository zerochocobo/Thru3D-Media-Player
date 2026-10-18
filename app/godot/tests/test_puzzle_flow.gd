extends SceneTree
const Main := preload("res://scripts/main.gd")
const Store := preload("res://scripts/puzzle/puzzle_store.gd")
const Memory := preload("res://scripts/file_mode_memory.gd")
var checks := 0
var failures: Array[String]=[]
var output := ProjectSettings.globalize_path("res://../../build/output/puzzle-p1/flow-")+str(Time.get_ticks_usec())
func _initialize() -> void: call_deferred("_run")
func check(ok: bool, message: String) -> void:
	checks+=1
	if not ok: failures.append(message); push_error(message)
func load_photo(app: Node, path: String) -> void:
	app._on_library_chosen("file://"+path,"same.png")
	var deadline := Time.get_ticks_msec()+5000
	while app.photo.loading and Time.get_ticks_msec()<deadline: await create_timer(0.01).timeout
	app.photo.finish_transition()
func ready_game(host: Node) -> bool:
	var deadline := Time.get_ticks_msec()+8000
	while host.active and host.panel.preparing and Time.get_ticks_msec()<deadline: await create_timer(0.01).timeout
	return host.session!=null and host.saving_ready
func place(app: Node, id: int) -> void:
	var host: Node=app.puzzle_game
	host.show_panel(false)
	var piece: MeshInstance3D=host.session.pieces[id]
	while not piece.visible: host.session.next_tray()
	piece.transform=piece.goal
	app.hand_pointers.right_hand.source="hand"
	app.hand_pointers.right_hand.ray=[piece.global_position+host.session.global_basis.z,-host.session.global_basis.z]
	host.ready_after_release.right_hand=true
	host.button("trigger_click","right_hand"); host.button("trigger_click","right_hand",true)
	app.hand_pointers.right_hand.source="none"; app.hand_pointers.right_hand.ray=null
func _run() -> void:
	DirAccess.make_dir_recursive_absolute(output.path_join("a")); DirAccess.make_dir_recursive_absolute(output.path_join("b"))
	var image := Image.create(160,120,false,Image.FORMAT_RGB8); image.fill(Color.RED)
	var a := output.path_join("a/same.png"); var b := output.path_join("b/same.png")
	image.save_png(a); image.fill(Color.BLUE); image.save_png(b)
	var app := Main.new(); app.settings_path=output.path_join("settings.cfg"); root.add_child(app)
	app.set_process(false); app.photo.history_enabled=false; app.photo.mode_memory=Memory.new(output.path_join("modes"))
	var host: Node=app.puzzle_game; host.store=Store.new(output.path_join("saved"))
	app.recent_menu.refresh()
	check(not app.recent_menu._buttons.any(func(button):return button.target==app.recent_menu.PUZZLE_OPEN),"Home hides the resume shortcut before any placed progress")
	app.recent_menu.media_filter=2; app.recent_menu.refresh()
	check(app.recent_menu._buttons.any(func(button):return button.target==app.recent_menu.PUZZLE_OPEN and button.enabled),"Images expose puzzle mode before a first game or open image")
	app.recent_menu.puzzle_requested.emit()
	check(host.active and host.session==null and host.panel.mode=="hub" and not host.panel.can_start,"Empty global hub safely owns input before opening media")
	host.tick(0.016); host.button("trigger_click","right_hand",true); host.button("by_button","right_hand")
	check(not host.active,"Back closes a global hub that has no active game")
	await load_photo(app,a)
	app._on_photo_action("photo_puzzle"); host.start(false)
	check(await ready_game(host),"Seated entry prepares and durably creates a game")
	if host.session==null: quit(1); return
	var id_a: String=host.game_id
	check(not host.session.standing and host.store.unfinished().size()==1,"New seated game appears immediately, including zero placed pieces")
	place(app,0)
	check(host.store.get_game(id_a).snapshot.pieces[0].placed,"Actual trigger release autosaves a snapped piece")
	var parked: Transform3D=host.session.pieces[1].transform.translated(Vector3(0.04,0.02,0.03))
	host.session.pieces[1].transform=parked; host.session.changed.emit()
	await create_timer(1.1).timeout
	check(host.session.decode_pose(host.store.get_game(id_a).snapshot.pieces[1].pose).is_equal_approx(parked),"Dirty progress automatically checkpoints without opening a panel")
	host.show_panel(true); host._action("posture")
	check(host.session.standing and host.session.completed()==1 and host.session.pieces[0].transform==host.session.pieces[0].goal,"Panel switches to standing without disturbing solved pieces")
	check(host.store.get_game(id_a).snapshot.standing and host.store.preferences().standing,"Posture and last-play preference are saved")
	host.show_panel(false)
	var standing_piece: MeshInstance3D=host.session.pieces.filter(func(p):return p.visible and not p.placed)[0]
	var front: Vector3=standing_piece.global_basis.z.normalized()
	app.hand_pointers.right_hand.source="hand"; app.hand_pointers.right_hand.ray=[standing_piece.global_position+front*0.3,-front]
	host.ready_after_release.right_hand=true; host.button("trigger_click","right_hand")
	check(host.session.captures.has("right_hand") and standing_piece.global_basis.z.normalized().is_equal_approx(front),"Bare-hand pickup faces the nearby player without requiring wrist rotation")
	host.button("trigger_click","right_hand",true); app.hand_pointers.right_hand.source="none"; app.hand_pointers.right_hand.ray=null
	host.show_panel(true)
	host._action("help")
	check(host.panel.mode=="help" and host.session.paused,"Help is an independent paused game surface")
	host._action("continue"); host._action("music")
	check(app._active_menu()==app.music_menu and host.session.paused,"Game music action opens the existing music player without unpausing puzzle")
	app._audio_import_pending=true; app._audio_import_playlist="fixture-playlist"
	app._show_full_library(); app.recent_menu.begin_audio_import()
	check(app._active_menu()==app.recent_menu and host.session.paused,"Music import owns the library surface while retaining the paused puzzle")
	host._back_from_music()
	check(not app._audio_import_pending and not app.recent_menu.audio_import_mode and app._active_menu()==app.music_menu,"Back from music import returns to music before returning to game")
	app._close_music_menu()
	check(host.panel.visible and app._active_menu()==host.panel and host.session.completed()==1,"Music closes back into the same game panel")
	host.show_panel(false); host.tick(0.016)
	check(host.dock.visible,"A lower-view menu handle remains available while playing")
	app.hand_pointers.right_hand.source="hand"; app.hand_pointers.right_hand.ray=[host.dock.global_position+host.dock.global_basis.z,-host.dock.global_basis.z]
	host.ready_after_release.right_hand=true; host.button("trigger_click","right_hand")
	check(host.panel.visible and host.session.paused,"Single-hand ray and pinch can reopen game controls through the lower handle")
	host.button("trigger_click","right_hand",true); app.hand_pointers.right_hand.source="none"; app.hand_pointers.right_hand.ray=null
	host.finish()
	await load_photo(app,b)
	host.open_hub()
	check(host.panel.records.size()==1 and host.panel.records[0].id==id_a,"Image B entry displays unfinished A")
	host.start(true); check(await ready_game(host),"Standing entry starts image B")
	var id_b: String=host.game_id; place(app,2)
	check(id_a!=id_b and host.store.get_game(id_a).snapshot.pieces[0].placed and not host.store.get_game(id_a).snapshot.pieces[2].placed,"Different images keep different progress and session identities")
	host._action("hub")
	check(host.panel.records.size()==2 and host.session.paused,"In-game entry lists both unfinished games and saves current game")
	check(host.resume_game(id_a) and await ready_game(host),"One click switches directly from B to retained A")
	check(host.game_id==id_a and host.session.completed()==1 and host.session.pieces[0].placed and host.session.standing,"Resume restores A's progress and posture")
	check(app.photo.local_uri=="file://"+b,"Resuming A does not replace current viewer photo B")
	host.finish(); app._close_current_media()
	DirAccess.remove_absolute(a)
	app.recent_menu.puzzle_requested.emit()
	check(not app.photo_active and host.panel.records.size()==2,"Global entry still lists games with no image open")
	check(host.resume_game(id_a) and await ready_game(host),"A game resumes even after original source is offline")
	check(host.session.source.image.get_pixel(0,0).r>0.9,"Offline resume uses A's pixels rather than current or last-opened B")
	host._action("hub"); host._action("delete:"+id_b)
	check(host.game_id==id_a and host.store.get_game(id_b).is_empty() and host.panel.records.size()==1,"Deleting another game leaves active A intact")
	host._action("undo")
	check(not host.store.get_game(id_b).is_empty() and host.panel.records.size()==2,"Undo returns the selected game")
	host._action("delete:"+id_a)
	check(host.session==null and host.panel.mode=="hub" and host.panel.records.size()==1,"Deleting the current game releases its session into the global hub")
	host.finish()
	check(Store.new(host.store.directory).get_game(id_a).is_empty() and not host.active,"Leaving after deletion cannot recreate the removed current game")
	host.open_hub(); host._action("undo")
	check(host.resume_game(id_a) and await ready_game(host),"Deleted current game can be undone and resumed without state loss")
	var original_directory: String=host.store.directory
	host.session.pieces[3].position.x+=0.01; host.session.changed.emit()
	host.store.directory=output.path_join("missing-store")
	var source_before: String=app.photo.local_uri
	app._on_library_chosen("file://"+b,"same.png")
	check(host.active and host.dirty and host.panel.status=="Save failed" and app.photo.local_uri==source_before,"Save failure keeps current game and blocks media switching")
	host.store.directory=original_directory
	check(host.save_now(),"A failed save can be retried once storage recovers")
	host.finish(); host.open_hub()
	for i in 5: host.store.create_game(host.store.get_game(id_b).source,host.store.get_game(id_b).snapshot)
	host.open_hub(); host.panel._activate(21)
	check(host.panel.page==1 and host.panel.records.size()==7,"Unfinished games paginate beyond the first four cards")
	host.panel.scroll_axis(0); host.panel.scroll_axis(0.9)
	check(host.panel.page==0,"Stick scroll pages the list after a neutral sample")
	host.panel._activate(200)
	check(not host.panel.deleting.is_empty(),"Delete icon opens a separate confirmation instead of deleting on hover")
	host.panel._activate(31)
	check(host.panel.deleting.is_empty() and host.store.unfinished().size()==7,"Cancel leaves all games intact")
	var row: Dictionary=host.panel._buttons.filter(func(button):return button.target==100)[0]
	var row_origin: Vector3=row.node.global_position+host.panel.global_basis.z
	var direction: Vector3=-host.panel.global_basis.z
	app.hand_pointers.right_hand.source="hand"; app.hand_pointers.right_hand.ray=[row_origin,direction]
	host.ready_after_release.right_hand=true; host.button("trigger_click","right_hand")
	check(host.panel.has_pointer_capture() and host.panel.mode=="hub","Unfinished card waits for release, allowing list dragging")
	app.hand_pointers.right_hand.ray=[row_origin+host.panel.global_basis.y*0.20,direction]; host.tick(0.016)
	host.button("trigger_click","right_hand",true)
	check(host.panel.page==1 and host.panel.mode=="hub" and not host.panel.has_pointer_capture(),"Ray drag pages the list without accidentally continuing a game")
	var selected_id: String=host.panel.records[4].id
	row=host.panel._buttons.filter(func(button):return button.target==100)[0]
	app.hand_pointers.right_hand.ray=[row.node.global_position+host.panel.global_basis.z,direction]
	host.ready_after_release.right_hand=true; host.button("trigger_click","right_hand"); host.button("trigger_click","right_hand",true)
	check(await ready_game(host) and host.game_id==selected_id,"Ray click continues the card on the current page, not a stale first-page record")
	app.hand_pointers.right_hand.source="none"; app.hand_pointers.right_hand.ray=null
	host.finish()
	app.photo_active=false; app.video.set_process(false); app.video.local_uri="fixture://paused-behind-puzzle.mp4"
	app.video.media.begin(99); app.video.media.state="playing"; app.video.requested_play=true
	host.resume_game(id_b); await ready_game(host)
	check(not app.video.requested_play and not app.background_audio.video_active,"Resuming from a video pauses its audio and allows game music")
	host.finish()
	check(app.video.requested_play and app.background_audio.video_active,"Leaving restores the previously playing video and music context")
	app.video.local_uri=""; app.video.requested_play=false
	app.queue_free(); await process_frame; await process_frame
	print("Puzzle flow: %d checks, %d failures" % [checks,failures.size()]); quit(0 if failures.is_empty() else 1)
