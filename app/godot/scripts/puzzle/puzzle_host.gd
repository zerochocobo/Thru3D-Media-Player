extends Node3D
## Owns the game's UI, input lifetime and durable checkpoint boundary.
const Source := preload("res://scripts/puzzle/puzzle_source.gd")
const Session := preload("res://scripts/puzzle/puzzle_session.gd")
const PuzzlePanel := preload("res://scripts/puzzle/puzzle_panel.gd")
const Store := preload("res://scripts/puzzle/puzzle_store.gd")
const Dock := preload("res://scripts/puzzle/puzzle_dock.gd")
const PhotoEntry := preload("res://scripts/puzzle/puzzle_photo_entry.gd")
const FrameInput := preload("res://scripts/puzzle/puzzle_frame_input.gd")
const Reference := preload("res://scripts/puzzle/puzzle_reference.gd")
const PuzzleAudio := preload("res://scripts/puzzle/puzzle_audio.gd")
const Fireworks := preload("res://scripts/puzzle/puzzle_fireworks.gd")
const Menu := preload("res://scripts/ray_menu.gd")
var app: Node
var active := false
var session: Node3D
var panel: Node3D
var previous := {}
var reference: MeshInstance3D
var ready_after_release := {}
var desktop_position := Vector2.ZERO
var grip_inputs := {}
var sound: Node3D
var celebration: Node3D
var preparation_ms := 0.0
var preparation_started_us := 0
var store := Store.new()
var game_id := ""
var descriptor := {}
var restore_record := {}
var source_worker := Thread.new()
var worker_kind := ""
var initial_standing := false
var dirty := false
var saving_ready := false
var save_elapsed := 0.0
var music_open := false
var music_return_panel := true
var dock: Node3D
var photo_entry: Node3D
var mode_enabled := false
var _preference_store: RefCounted
var _progress_store: RefCounted
var _has_progress := false
var _photo_entry_key := ""
var _photo_controls_visible := false
var _entry_pointer_frame := -1
var setup_source := {}
var setup_descriptor := {}
var initial_count := Session.DEFAULT_COUNT
var initial_random_rotation := false
var frame_input := FrameInput.new(self)
var reference_preview: Node3D
var rotation_hints := {}

func _ready() -> void:
	photo_entry=PhotoEntry.new(); add_child(photo_entry); photo_entry.refresh()
	photo_entry.companion=app.photo_menu
	photo_entry.requested.connect(open_setup)
	app.photo_menu.puzzle_mode_provider=is_mode_enabled

func is_mode_enabled() -> bool:
	_sync_mode(); return mode_enabled

func _sync_mode() -> void:
	if _preference_store==store: return
	_preference_store=store; mode_enabled=store.mode_enabled(); _photo_entry_key=""

func has_progress() -> bool:
	if _progress_store!=store: _progress_from(store.unfinished())
	return _has_progress

func _progress_from(records: Array) -> void:
	_progress_store=store; _has_progress=records.any(func(record):return int(record.done)>0)

func _update_photo_entry() -> void:
	if not is_instance_valid(photo_entry): return
	_sync_mode()
	var show: bool=mode_enabled and not active and app.photo_active and not app.photo.inspect \
		and app._input_focused() and not app._background_app_paused and Source.availability(app.photo).is_empty() \
		and not app.recent_menu.visible and not app.music_menu.visible and app._grab.is_empty() and app.interface_move.capture.is_empty()
	if not show:
		photo_entry.dismiss()
		if is_instance_valid(app.menu_composition): app.menu_composition.unregister_menu(photo_entry)
		return
	var photo: Node3D=app.photo; var camera: Camera3D=app.xr_camera
	var forward := -camera.global_basis.z; forward.y=0
	forward=forward.normalized() if forward.length_squared()>0.01 else Vector3.FORWARD
	var comfortable := Transform3D(Basis.looking_at(forward,Vector3.UP),camera.global_position+forward*1.3-Vector3.UP*0.37)
	if photo.geometry==0:
		var pose: Transform3D=photo.global_transform*photo.flat_pose
		pose.origin=pose*Vector3(0,-photo._flat.size.y*0.5-0.10,0.025)
		var offset := pose.origin-camera.global_position
		photo_entry.global_transform=pose if offset.length()<2.2 and offset.angle_to(-camera.global_basis.z)<deg_to_rad(30) else comfortable
	else:
		var key := str([photo.local_uri,photo.geometry,photo._serial])
		if key!=_photo_entry_key or (app.photo_menu.visible and not _photo_controls_visible): photo_entry.global_transform=comfortable
		_photo_entry_key=key
	_photo_controls_visible=app.photo_menu.visible
	# Keep the optional puzzle entry below the photo-attached magazine actions.
	if photo.magazine.active() and is_instance_valid(app.photo_magazine_controls):
		app.photo_magazine_controls.sync()
		photo_entry.global_transform = app.photo_magazine_controls.global_transform * Transform3D(Basis.IDENTITY, Vector3(0,-0.22,0))
	photo_entry.ray_max_distance = maxf(photo_entry.MAX_RAY_METRES, photo_entry.global_position.distance_to(camera.global_position) + 2.0)
	photo_entry.visible=true
	# Input asks for the active surface several times per frame. Rebuild pointer
	# meshes only once; ray hits at press time are still computed from the latest ray.
	var frame := Engine.get_process_frames()
	if _entry_pointer_frame!=frame:
		_entry_pointer_frame=frame
		for hand in ["left_hand","right_hand"]:
			var ray: Variant=app._ray(hand)
			if ray!=null and not photo_entry.ray_hit(ray[0],ray[1]).is_empty(): photo_entry.update_pointer(hand,ray[0],ray[1],true)
			else: photo_entry.cancel_pointer(hand)
	if is_instance_valid(app.menu_composition): app.menu_composition.register_menu(photo_entry)

## Reserve only an actual entry hit; ordinary photo gestures remain available elsewhere.
func photo_entry_menu() -> Node3D:
	_update_photo_entry()
	if not is_instance_valid(photo_entry) or not photo_entry.visible: return null
	for hand in ["left_hand","right_hand"]:
		var ray: Variant=app._ray(hand)
		if ray==null: continue
		var hit: Dictionary=photo_entry.ray_hit(ray[0],ray[1])
		if hit.is_empty(): continue
		var other: Dictionary=app.photo_menu.ray_hit(ray[0],ray[1]) if app.photo_menu.visible else {}
		if other.is_empty() or float(other.distance)>float(hit.distance): return photo_entry
	if app.display.preview:
		var mouse: Vector2=app.get_viewport().get_mouse_position()
		if not photo_entry.ray_hit(app.xr_camera.project_ray_origin(mouse),app.xr_camera.project_ray_normal(mouse)).is_empty(): return photo_entry
	return null

func _enter() -> void:
	if active: return
	active=true
	_update_photo_entry()
	previous={"visible":app.photo.visible,"process":app.photo.is_processing(),"layer":app.photo.layer_enabled,
		"video_visible":app.video.visible,"video_uri":app.video.local_uri,"video_paused":false}
	app._grab={}; app.photo_hands.cancel(); app.photo_swipe.cancel(); app.memory_swipe.cancel()
	app.interface_move.cancel(); app.controller_bindings.reset_inputs(); app.stick_controls.suspend()
	for menu in [app.recent_menu,app.player_menu,app.photo_menu,app.music_menu]:
		if menu: menu.dismiss()
	panel=PuzzlePanel.new(); add_child(panel); panel.requested.connect(_action)
	if is_instance_valid(app.menu_composition): app.menu_composition.register_menu(panel)
	panel.thumbnail_provider=store.thumbnail
	dock=Dock.new(); add_child(dock); dock.requested.connect(func(operation: String):
		if operation=="menu": show_panel(true)
		else: _action(operation))
	dock.refresh()
	dock.audio_provider=app.background_audio.snapshot
	dock.capture_provider=func(): return session!=null and (not session.captures.is_empty() or not frame_input.movement.capture.is_empty() or not frame_input.resize.is_empty())
	app.background_audio.changed.connect(dock.refresh)
	if is_instance_valid(app.menu_composition): app.menu_composition.register_menu(dock)
	sound=PuzzleAudio.new(); add_child(sound)
	_place_panel(); panel.standing=bool(store.preferences().get("standing",false))

func _forward() -> Vector3:
	var forward: Vector3=-app.xr_camera.global_basis.z; forward.y=0
	return forward.normalized() if forward.length_squared()>0.01 else Vector3.FORWARD

func _place_panel() -> void:
	if session and not session.spherical and panel.mode!="setup":
		panel.global_transform=session.menu_anchor(panel.layout_height()*0.5+0.08)
	else:
		var drop := 0.10 if session==null and panel.mode=="hub" else maxf(0.37,panel.layout_height()*0.5+0.10)
		panel.global_transform=Transform3D(Basis.looking_at(_forward(),Vector3.UP),app.xr_camera.global_position+_forward()*1.15-Vector3.UP*drop)
	panel.set_layout_viewer(app.xr_camera.global_transform)

func open_hub(history: bool = false) -> void:
	_enter()
	if not save_now(): return
	panel.mode="hub"; panel.deleting=""; panel.preparing=not worker_kind.is_empty() or (session!=null and session.preparing)
	panel.can_start=app.photo_active and Source.availability(app.photo).is_empty()
	panel.current_spherical=app.photo_active and app.photo.geometry==3
	if panel.history_mode!=history: panel.page=0
	panel.history_mode=history
	panel.records=store.history() if history else store.unfinished(); panel.has_game=session!=null and saving_ready
	panel.can_undo=not store.undo_id.is_empty()
	_sync_mode(); panel.mode_enabled=mode_enabled; _progress_from(store.unfinished() if history else panel.records)
	show_panel(true)

func open_history_image(id: String) -> bool:
	if not worker_kind.is_empty() or (session!=null and session.preparing) or not save_now(): return false
	var record := store.get_game(id)
	if record.is_empty(): return false
	_enter(); panel.preparing=true; panel.status=""; show_panel(true)
	worker_kind="picture"
	if source_worker.start(func():
		var source := store.load_source(record.source,false)
		if not source.is_empty(): source.uri=store.image_uri(record.source)
		return source)!=OK:
		worker_kind=""; panel.preparing=false; panel.status="Saved image unavailable"; show_panel(true); return false
	return true

func _show_history_image(source: Dictionary) -> void:
	var uri := str(source.uri); var title := str(source.title)
	# Normal photo decoding retains the Android photo handle. Only the archived
	# presentation and depth are supplied, avoiding another remote access/model run.
	source.erase("image"); source.erase("texture")
	finish(false,false)
	app._on_library_chosen(uri,title,source)

func open_setup(replay: bool = false) -> void:
	var source: Dictionary=session.source.duplicate() if replay and session else (Source.from_photo(app.photo) if app.photo_active and is_mode_enabled() else {})
	if source.is_empty() or source.has("error") or not save_now(): return
	if not replay:
		var existing := store.find_unfinished(source)
		if not existing.is_empty(): resume_game(str(existing.id)); return
	_enter(); setup_source=source; setup_descriptor=descriptor.duplicate(true) if replay else {}
	panel.mode="setup"; panel.preparing=false; panel.status=""; panel.can_start=true
	panel.current_spherical=source.get("projection","flat")=="sphere"
	var preferences := store.preferences()
	panel.standing=store.standing_mode(panel.current_spherical)
	var fallback := Session.DEFAULT_COUNT
	panel.piece_count=int(preferences.get("sphere_count" if panel.current_spherical else "flat_count",fallback))
	if panel.piece_count not in panel.difficulty_counts(): panel.piece_count=fallback
	panel.random_rotation=bool(preferences.get("sphere_random_rotation" if panel.current_spherical else "flat_random_rotation",false))
	show_panel(true)

func start(standing_mode: Variant = null, count: int = 0, random_orientation: Variant = null) -> bool:
	if app==null or not worker_kind.is_empty() or (session!=null and session.preparing): return false
	var source: Dictionary=setup_source if active and panel.mode=="setup" else (Source.from_photo(app.photo) if app.photo_active else {})
	if source.is_empty(): return false
	if source.has("error") or not save_now(): return false
	var retained: Dictionary=setup_descriptor.duplicate(true) if active and panel.mode=="setup" else {}
	_enter(); _drop_session()
	var spherical: bool=source.get("projection","flat")=="sphere"
	initial_standing=store.standing_mode(spherical) if standing_mode==null else bool(standing_mode)
	initial_count=count if count>0 else int(store.preferences().get("sphere_count" if spherical else "flat_count",Session.DEFAULT_COUNT))
	if initial_count not in (Session.SPHERE_COUNTS if spherical else Session.FLAT_COUNTS): initial_count=Session.DEFAULT_COUNT
	initial_random_rotation=bool(random_orientation) if random_orientation is bool else bool(store.preferences().get("sphere_random_rotation" if spherical else "flat_random_rotation",false))
	store.remember(initial_standing,initial_count,spherical,initial_random_rotation); panel.standing=initial_standing
	preparation_started_us=Time.get_ticks_usec(); panel.mode="game"; panel.preparing=true; panel.status=""
	if not retained.is_empty():
		descriptor=retained; _prepare(source); return true
	# A single worker freezes image/depth assets while the geometry worker builds pieces.
	worker_kind="cache"
	if source_worker.start(func(): return store.cache_source(source))!=OK:
		worker_kind=""; panel.preparing=false; panel.status="Save failed"; show_panel(true); return false
	_prepare(source)
	return true

func resume_game(id: String) -> bool:
	if not worker_kind.is_empty() or (session!=null and session.preparing) or not save_now(): return false
	var record := store.get_game(id)
	if record.is_empty(): return false
	_enter(); _drop_session(); restore_record=record; game_id=id; descriptor=record.source
	preparation_started_us=Time.get_ticks_usec(); panel.mode="game"; panel.preparing=true; panel.status=""
	worker_kind="load"; show_panel(true)
	if source_worker.start(func(): return store.load_source(record.source,false))!=OK:
		worker_kind=""; _failed("Saved image unavailable"); return false
	return true

func _prepare(source: Dictionary) -> void:
	session=Session.new(); add_child(session)
	var is_sphere: bool=source.get("projection","flat")=="sphere"
	var dimensions := Session.grid_for_source(source,initial_count) if restore_record.is_empty() else Vector2i(restore_record.snapshot.grid[0],restore_record.snapshot.grid[1])
	var seed_id := randi_range(1,2147483647) if restore_record.is_empty() else int(restore_record.snapshot.seed)
	session.prepared.connect(_session_ready)
	if not session.prepare_async(source,dimensions,seed_id): _failed("Saved image unavailable"); return
	session.global_transform=Transform3D(Basis.looking_at(_forward(),Vector3.UP),app.xr_camera.global_position+(_forward()*1.8 if not is_sphere else Vector3.ZERO))
	session.viewer_position=session.to_local(app.xr_camera.global_position)
	app.photo._pause_prefetch(); app.photo.close_inspect(); app.photo.finish_transition(); app.photo._hide_layer()
	app.photo.layer_enabled=false; app.photo.set_process(false); app.video.visible=false
	if not app.photo_active and not app.video.local_uri.is_empty() and app.video.requested_play:
		previous.video_paused=true; app.video.toggle_play()
	app._sync_background_audio()
	panel.total=dimensions.x*dimensions.y
	session.piece_placed.connect(_placed)
	session.piece_rotated.connect(func(id: int,hand: String):
		var ray: Variant=app._ray(hand)
		if sound and app._input_focused(): sound.play("rotate",ray[0] if ray!=null else session.pieces[id].global_position))
	panel.spherical=is_sphere
	dock.spherical=is_sphere; dock.refresh()
	reference_preview=Reference.new(); add_child(reference_preview); reference_preview.source=source; reference_preview.companion=dock; reference_preview.refresh()
	if is_instance_valid(app.menu_composition): app.menu_composition.register_menu(reference_preview)
	if not is_sphere:
		reference=MeshInstance3D.new()
		var quad := QuadMesh.new(); quad.size=session.board_size; reference.mesh=quad
		var material := ShaderMaterial.new(); material.shader=preload("res://shaders/puzzle_piece.gdshader")
		material.set_shader_parameter("image_texture",source.texture)
		material.set_shader_parameter("stereo_layout",int(source.get("layout",0)))
		material.set_shader_parameter("swap_eyes",bool(source.get("swap_eyes",false)))
		material.set_shader_parameter("spatial_disparity",float(source.get("spatial_disparity",0)))
		reference.material_override=material; session.add_child(reference); reference.position.z=0.06; reference.visible=false
		session.frame_reference=reference
	grip_inputs.clear(); show_panel(true)
	app.display.set_video_layer(false); app._update_background()

func _process(delta: float) -> void:
	_update_photo_entry()
	if not active: return
	if panel.mode=="hub" and not panel.preparing:
		var ready: bool=app.photo_active and Source.availability(app.photo).is_empty()
		if panel.can_start!=ready:
			panel.can_start=ready; panel.current_spherical=app.photo_active and app.photo.geometry==3; panel.refresh()
	if not worker_kind.is_empty() and not source_worker.is_alive():
		var kind := worker_kind; worker_kind=""
		var result: Dictionary=source_worker.wait_to_finish()
		if kind=="picture":
			if result.is_empty(): panel.preparing=false; panel.status="Saved image unavailable"; show_panel(true)
			else: _show_history_image(result)
			return
		if result.is_empty(): _failed("Saved image unavailable" if kind=="load" else "Save failed"); return
		if kind=="load":
			result.texture=ImageTexture.create_from_image(result.image); _prepare(result)
		else: descriptor=result; _begin_if_ready()
	if dirty and saving_ready:
		save_elapsed+=delta
		if save_elapsed>=1.0: save_now()

func _session_ready() -> void:
	if not active or session==null: return
	if not session.prepare_error.is_empty(): _failed("Saved image unavailable"); return
	if session.spherical: reference=session.sky.reference
	_begin_if_ready()

func _begin_if_ready() -> void:
	if session==null or session.preparing or descriptor.is_empty() or not worker_kind.is_empty() or saving_ready: return
	var resuming := not restore_record.is_empty()
	if not restore_record.is_empty():
		if not session.restore(restore_record.snapshot): _failed("Saved image unavailable"); return
	else: session.random_rotation=initial_random_rotation; session.set_posture(initial_standing)
	if session.spherical and session.standing: session.set_view_face(0,false)
	session.scatter(session.standing)
	store.remember(session.standing,session.pieces.size(),session.spherical,session.random_rotation)
	if game_id.is_empty():
		game_id=store.create_game(descriptor,session.snapshot())
		if game_id.is_empty(): _failed("Save failed"); return
	preparation_ms=float(Time.get_ticks_usec()-preparation_started_us)/1000.0
	saving_ready=true; dirty=false; save_elapsed=0; restore_record={}
	panel.has_game=true
	if sound: sound.reset()
	session.changed.connect(_changed)
	app.photo.visible=false; panel.preparing=false; panel.standing=session.standing; panel.random_rotation=session.random_rotation; panel.status="Saved"
	show_panel(not app._input_focused() or app._background_app_paused)
	if resuming: _changed(); save_now()

func _failed(message: String) -> void:
	_drop_session(); panel.preparing=false; panel.mode="hub"; panel.status=message
	panel.records=store.history() if panel.history_mode else store.unfinished(); panel.has_game=false
	app.photo.visible=bool(previous.visible); app.video.visible=bool(previous.video_visible)
	app.photo.layer_enabled=bool(previous.layer); app.photo.set_process(bool(previous.process))
	_restore_video()
	show_panel(true)

func _restore_video() -> void:
	if previous.get("video_paused",false) and app.video.local_uri==previous.get("video_uri","") and not app.video.requested_play:
		app.video.toggle_play()
	previous.video_paused=false; app._sync_background_audio()

func _changed() -> void:
	if saving_ready:
		if not dirty: save_elapsed=0
		dirty=true

func save_now() -> bool:
	if not saving_ready or session==null or not dirty: return true
	if not store.save_game(game_id,session.snapshot()):
		save_elapsed=0
		panel.status="Save failed"; session.set_paused(true); panel.visible=true; panel.refresh(); return false
	dirty=false; save_elapsed=0; panel.status="Saved"
	if session.completed()==session.pieces.size(): _progress_from(store.unfinished())
	elif session.completed()>0: _progress_store=store; _has_progress=true
	if panel.visible: panel.refresh()
	return true

func _drop_session() -> void:
	for hint in rotation_hints.values(): hint.queue_free()
	rotation_hints.clear()
	frame_input.cancel(true)
	if sound: sound.stop_all()
	if is_instance_valid(celebration): remove_child(celebration); celebration.queue_free()
	celebration=null
	if is_instance_valid(reference_preview):
		if is_instance_valid(app.menu_composition): app.menu_composition.unregister_menu(reference_preview)
		remove_child(reference_preview); reference_preview.queue_free()
	reference_preview=null
	if is_instance_valid(session):
		session.cancel_all(); remove_child(session); session.queue_free()
	session=null; reference=null; saving_ready=false; dirty=false; game_id=""; descriptor={}; restore_record={}

func finish(discard: bool = false, reveal_media: bool = true) -> void:
	if not active: return
	if session: session.cancel_all()
	if not discard and not save_now(): return
	if source_worker.is_started(): source_worker.wait_to_finish()
	worker_kind=""; _drop_session(); active=false; music_open=false
	app.photo.visible=bool(previous.visible); app.photo.layer_enabled=bool(previous.layer); app.photo.set_process(bool(previous.process))
	app.video.visible=bool(previous.video_visible)
	_restore_video()
	app.controller_bindings.reset_inputs(); app.stick_controls.suspend(); app.interface_move.cancel()
	if app.music_menu: app.music_menu.dismiss()
	if is_instance_valid(panel):
		if is_instance_valid(app.menu_composition): app.menu_composition.unregister_menu(panel)
		remove_child(panel); panel.queue_free()
	if is_instance_valid(dock): remove_child(dock); dock.queue_free()
	if is_instance_valid(sound): remove_child(sound); sound.queue_free()
	sound=null
	dock=null
	panel=null; grip_inputs.clear(); ready_after_release.clear(); setup_source={}; setup_descriptor={}
	app._update_background()
	if reveal_media:
		if app._has_open_media(): app._show_player_menu()
		else: app._show_full_library()

func _exit_tree() -> void:
	if active: save_now()
	if source_worker.is_started(): source_worker.wait_to_finish()

func show_panel(value: bool) -> void:
	if not active: return
	panel.drag.clear()
	value=value or panel.preparing or session==null
	if value: frame_input.cancel()
	if value:
		for hint in rotation_hints.values(): hint.visible=false
	if value and reference_preview:
		for hand in ["left_hand","right_hand","desktop"]: reference_preview.cancel_pointer(hand)
	if session:
		session.set_paused(value or not app._input_focused())
		if saving_ready and value: save_now()
	if value:
		panel.count=0 if session==null else (session.pieces.size() if session.preparing else session.completed())
		panel.visible=true; panel.scroll_ready=false; panel.refresh(); _place_panel()
	else:
		panel.dismiss()
		if reference: reference.visible=false
	if dock: dock.visible=not value
	ready_after_release.clear()
	for hand in ["left_hand","right_hand"]:
		var controller: XRController3D=app.left_controller if hand=="left_hand" else app.right_controller
		var held := controller!=null and (controller.is_button_pressed("trigger_click") or controller.is_button_pressed("grip_click"))
		ready_after_release[hand]=not held and not app.hand_pointers[hand].down

func _action(operation: String) -> void:
	if operation.begins_with("resume:"): resume_game(operation.trim_prefix("resume:")); return
	if operation.begins_with("picture:"): open_history_image(operation.trim_prefix("picture:")); return
	if operation.begins_with("delete:"):
		var id := operation.trim_prefix("delete:")
		if store.delete_game(id):
			if id==game_id: _drop_session()
			panel.deleting=""; open_hub(panel.history_mode)
		else: panel.status="Delete failed"; panel.refresh()
		return
	match operation:
		"close":
			if not panel.deleting.is_empty(): panel.deleting=""; panel.refresh()
			elif session and saving_ready: panel.mode="game"; show_panel(false)
			else: finish()
		"confirm_exit": panel.mode="exit_confirm"; show_panel(true)
		"back": panel.mode="game"; show_panel(true)
		"mode_on","mode_off":
			var value := operation=="mode_on"
			if store.set_mode_enabled(value): mode_enabled=value; _preference_store=store; panel.mode_enabled=value; _photo_entry_key=""
			else: panel.status="Save failed"
			panel.refresh()
			app.photo_menu.refresh(); app.recent_menu.refresh()
		"exit": finish()
		"hub": open_hub()
		"history": open_hub(true)
		"start": start(panel.standing,panel.piece_count,panel.random_rotation)
		"again": open_setup(true)
		"new_seated": start(false)
		"new_standing": start(true)
		"undo": store.undo_delete(); open_hub(panel.history_mode)
		"continue":
			if not save_now(): return
			if panel.mode in ["help","hub","sky"] and session: panel.mode="game"; show_panel(true)
			elif session: show_panel(false)
		"help": panel.mode="help"; panel.refresh(); _place_panel()
		"sky":
			if session and session.spherical and not session.standing: panel.mode="sky"; panel.refresh()
		"background":
			if session: session.cycle_backdrop(); save_now()
		"music":
			if save_now():
				music_return_panel=panel.visible; music_open=true; frame_input.cancel()
				if session: session.set_paused(true)
				panel.dismiss(); dock.dismiss(); app._show_music_menu(false)
		"music_toggle": app.background_audio.toggle_pause()
		"posture":
			if session:
				session.set_posture(not session.standing); panel.standing=session.standing
				if session.standing and panel.mode=="sky": panel.mode="game"
				store.remember(session.standing,0,session.spherical); save_now(); panel.refresh()
		"organize":
			if session: session.shuffle_tray(); save_now()
		"tray":
			if session: session.next_tray(); save_now()
		"reference":
			if reference_preview:
				reference_preview.enabled=not reference_preview.enabled
				if reference: reference.visible=reference_preview.enabled
	if operation.begins_with("view:") and session and session.spherical and not session.standing:
		session.set_view_face(int(operation.trim_prefix("view:"))); save_now(); panel.mode="game"; panel.refresh()
	if operation=="recenter" and session and session.spherical:
		session.cancel_all(); session.set_view_face(0,false); session.global_position=app.xr_camera.global_position; _changed(); save_now()

func return_from_music() -> void:
	music_open=false
	if app.recent_menu: app.recent_menu.dismiss()
	show_panel(music_return_panel)

func _back_from_music() -> void:
	if app._audio_import_pending:
		if app.recent_menu and app.recent_menu.audio_import_mode: app.recent_menu._restore_audio_import_context()
		app._on_audio_import_cancelled()
	else: app._close_music_menu()

func input_menu() -> Node3D:
	if music_open:
		if app.music_menu.visible: return app.music_menu
		if app.recent_menu.visible: return app.recent_menu
	return panel if panel!=null and panel.visible else null

func _ray_menu(origin: Vector3, direction: Vector3) -> Node3D:
	var menu := input_menu()
	if menu: return menu
	if reference_preview and reference_preview.visible and reference_preview.has_pointer_capture(): return reference_preview
	if reference_preview and reference_preview.visible and not reference_preview.ray_hit(origin,direction).is_empty(): return reference_preview
	return dock if dock and dock.visible and not dock.ray_hit(origin,direction).is_empty() else null

func _placed(id: int, hand: String) -> void:
	if panel: panel.count=session.completed()
	if session.completed()==session.pieces.size(): _complete_game.call_deferred(game_id)
	if sound and app._input_focused(): sound.play("snap",session.pieces[id].global_position)
	var controller: XRController3D=app.left_controller if hand=="left_hand" else app.right_controller
	if controller and controller.get_is_active() and app._controller_allowed(hand):
		controller.trigger_haptic_pulse("haptic",0.0,0.3,0.045,0.0)

func _complete_game(completed_id: String) -> void:
	if not active or not saving_ready or game_id!=completed_id or session==null or session.preparing or session.completed()!=session.pieces.size(): return
	_changed()
	if not save_now(): return
	panel.mode="complete"; panel.status="Saved"; show_panel(true)
	if app._input_focused() and not app._background_app_paused and sound and sound.success(app.xr_camera.global_position):
		celebration=Fireworks.new(); add_child(celebration)
		celebration.configure(app.xr_camera.global_transform,sound,session.global_position if session.spherical else null,
			null if session.spherical else session.frame_world_pose(),session.board_size*session.frame_scale())

func button(action: String, hand: String, released: bool = false) -> void:
	if not active: return
	if not app._input_focused():
		if session: session.cancel(hand)
		return
	if not released and app.controller_feedback: app.controller_feedback.wake(hand)
	if action=="ax_button":
		if released or input_menu()!=null or session==null or hand not in ["right_hand","left_hand"]: return
		var held_hand: String=hand if session.captures.has(hand) else (str(session.captures.keys()[0]) if session.captures.size()==1 else "")
		if session.rotate_held(held_hand,-1 if hand=="right_hand" else 1):
			var ray: Variant=app._ray(held_hand); var pose: Variant=_pose(held_hand)
			if ray!=null and pose!=null: session.update_grab(held_hand,ray[0],ray[1],pose)
			save_now()
		return
	if action in ["menu_button","by_button"] and not released:
		if music_open: _back_from_music(); return
		if action=="by_button" and panel.preparing: finish(); return
		if session==null and not panel.preparing: finish(); return
		if action=="by_button" and session and session.captures.has(hand): session.cancel(hand)
		elif panel.visible and panel.mode in ["hub","help","sky","exit_confirm"] and not panel.preparing:
			panel.mode="game"; show_panel(true)
		else: show_panel(not panel.visible)
		return
	if action not in ["trigger_click","grip_click"]: return
	if frame_input.button(action,hand,released): return
	if released:
		ready_after_release[hand]=true
		var menu := input_menu()
		if reference_preview and reference_preview.has_pointer_capture(): menu=reference_preview
		if menu and menu.has_method("release_pointer") and (action=="trigger_click" or menu==reference_preview):
			var ray: Variant=app._ray(hand)
			menu.release_pointer(hand,ray[0] if ray!=null else Vector3.ZERO,ray[1] if ray!=null else Vector3.ZERO,ray!=null)
		if grip_inputs.get(hand,"")==action:
			if session:
				var ray: Variant=app._ray(hand)
				if ray==null: session.cancel(hand)
				else:
					var pose: Variant=_pose(hand)
					if pose==null: session.cancel(hand)
					else: session.update_grab(hand,ray[0],ray[1],pose); session.release(hand)
				save_now()
			grip_inputs.erase(hand)
		_update_rotation_hint(hand,null)
		return
	if session and session.captures.has(hand): return
	var ray: Variant=app._ray(hand)
	if ray==null: return
	var menu := _ray_menu(ray[0],ray[1])
	if menu:
		if ready_after_release.get(hand,true) and (action=="trigger_click" or (menu==reference_preview and int(menu.ray_hit(ray[0],ray[1]).get("target",-1))==3)):
			ready_after_release[hand]=false; menu.press_pointer(hand,ray[0],ray[1],true)
		return
	if not ready_after_release.get(hand,true) or session==null: return
	var pose: Variant=_pose(hand)
	if pose!=null and session.grab(hand,ray[0],ray[1],pose,app.hand_pointers[hand].source=="hand",app.hand_pointers[hand].source=="hand",true):
		grip_inputs[hand]=action
		if reference_preview: reference_preview.preferred_hand="left_hand" if hand=="right_hand" else "right_hand"

func hand_inputs(inputs: Dictionary) -> void:
	if not active: return
	var consumed: Array=frame_input.hand_inputs(inputs)
	for hand in inputs:
		if not active: return
		if hand in consumed: continue
		var input: Dictionary=inputs[hand]
		if input.get("source")!="hand": continue
		if input.get("cancelled",false) or not input.get("tracked",false):
			if session: session.cancel(hand)
			var menu := input_menu()
			if menu: menu.cancel_pointer(hand)
			grip_inputs.erase(hand); ready_after_release[hand]=false; continue
		if not input.get("down",false): ready_after_release[hand]=true
		if input.get("pressed",false): button("trigger_click",hand)
		elif input.get("released",false): button("trigger_click",hand,true)

func _pose(hand: String) -> Variant:
	var controller: XRController3D=app.left_controller if hand=="left_hand" else app.right_controller
	if app.hand_pointers.has(hand) and app.hand_pointers[hand].source=="hand":
		if session and session.random_rotation:
			var pose: Variant=frame_input.samples.get(hand,{}).get("pose")
			return pose if pose is Transform3D and pose.is_finite() else null
		return Transform3D.IDENTITY
	var tracked: Variant=app._move_pose(hand)
	if tracked!=null: return tracked
	return controller.global_transform if controller else Transform3D.IDENTITY

func _update_rotation_hint(hand: String, ray: Variant) -> void:
	var show: bool=ray!=null and session!=null and session.random_rotation and session.captures.has(hand) and not session.paused and input_menu()==null and app.hand_pointers[hand].source!="hand"
	if not show:
		if rotation_hints.has(hand): rotation_hints[hand].visible=false
		return
	if not rotation_hints.has(hand):
		var label := Label3D.new(); label.font=Menu.ui_font(); Menu.set_label_size(label,16)
		label.texture_filter=BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS; label.outline_size=4; label.no_depth_test=false
		add_child(label); rotation_hints[hand]=label
	var hint: Label3D=rotation_hints[hand]
	hint.text=Menu.I18n.t("A ↻ 90° · X ↺ 90°" if session.captures.size()==1 else ("X ↺ 90°" if hand=="left_hand" else "A ↻ 90°"))
	hint.global_position=ray[0]+ray[1]*0.30+app.xr_camera.global_basis.y*0.16
	var direction: Vector3=hint.global_position-app.xr_camera.global_position
	if direction.length_squared()>0.001:
		var up: Vector3=app.xr_camera.global_basis.y
		hint.global_basis=Basis.looking_at(direction.normalized(),up if absf(up.dot(direction.normalized()))<0.98 else app.xr_camera.global_basis.x)
	hint.visible=true

func tick(delta: float) -> void:
	if not active: return
	if session and session.preparing and panel.count!=session.pieces.size():
		panel.count=session.pieces.size(); panel.refresh()
	if not app._input_focused() or app._background_app_paused:
		for hint in rotation_hints.values(): hint.visible=false
		frame_input.cancel()
		if sound: sound.stop_all()
		if is_instance_valid(celebration): remove_child(celebration); celebration.queue_free(); celebration=null
		if reference_preview: reference_preview.visible=false
		if reference_preview:
			for hand in ["left_hand","right_hand","desktop"]: reference_preview.cancel_pointer(hand)
		if dock: dock.visible=false
		if session: session.set_paused(true)
		save_now(); ready_after_release.clear(); grip_inputs.clear()
		for hand in ["left_hand","right_hand"]:
			if app.controller_feedback: app.controller_feedback.update_hand(hand,null,null,null,false,false,delta)
		if app.input_visuals: app.input_visuals.update_visibility(false)
		return
	var alphas := {}
	var menu := input_menu()
	var left: Vector2=app._stick(app.left_controller); var right: Vector2=app._stick(app.right_controller)
	if session and not session.spherical: session.viewer_position=session.to_local(app.xr_camera.global_position)
	frame_input.tick(delta,left,right)
	if reference_preview:
		var was_visible: bool=reference_preview.visible
		reference_preview.visible=reference_preview.enabled and menu==null and saving_ready
		reference_preview.place(app,session,frame_input.samples,delta if was_visible else 0.0)
	if dock:
		dock.visible=menu==null and saving_ready
		dock.global_transform=session.menu_anchor(0.11) if session and not session.spherical else Transform3D(Basis.looking_at(_forward(),Vector3.UP),app.xr_camera.global_position+_forward()*0.75-Vector3.UP*0.37)
		if dock.visible: dock.set_layout_viewer(app.xr_camera.global_transform)
	if menu==panel:
		panel.scroll_axis(left.y if absf(left.y)>absf(right.y) else right.y)
	elif menu:
		if menu.has_method("stick_scroll"): menu.stick_scroll(left.y if absf(left.y)>absf(right.y) else right.y,delta)
		if menu.has_method("stick_scroll_horizontal"): menu.stick_scroll_horizontal(left.x if absf(left.x)>absf(right.x) else right.x,delta)
	for hand in ["left_hand","right_hand"]:
		var ray: Variant=app._ray(hand)
		var point: Variant=null
		if reference_preview and reference_preview.drag.get("hand","")!=hand: reference_preview.cancel_pointer(hand)
		if ray==null:
			if dock: dock.cancel_pointer(hand)
			if reference_preview: reference_preview.cancel_pointer(hand)
			if session: session.cancel(hand)
			grip_inputs.erase(hand)
			if menu: menu.cancel_pointer(hand)
		elif menu:
			if dock: dock.cancel_pointer(hand)
			menu.update_pointer(hand,ray[0],ray[1],true)
		elif session and session.captures.has(hand):
			if dock: dock.cancel_pointer(hand)
			var pose: Variant=_pose(hand)
			if pose==null: session.cancel(hand)
			else: session.update_grab(hand,ray[0],ray[1],pose)
			point=session.held_pointer(hand)
		elif reference_preview and reference_preview.visible and reference_preview.drag.get("hand","")==hand:
			if dock: dock.cancel_pointer(hand)
			reference_preview.update_pointer(hand,ray[0],ray[1],true); point=reference_preview.global_position
		elif reference_preview and reference_preview.visible and not reference_preview.ray_hit(ray[0],ray[1]).is_empty():
			if dock: dock.cancel_pointer(hand)
			reference_preview.update_pointer(hand,ray[0],ray[1],true)
			point=reference_preview.to_global(reference_preview.ray_hit(ray[0],ray[1]).point)
		elif dock and dock.visible and not dock.ray_hit(ray[0],ray[1]).is_empty():
			dock.update_pointer(hand,ray[0],ray[1],true)
			point=(dock.global_transform*dock.ray_hit(ray[0],ray[1]).point)
		elif session:
			if dock: dock.cancel_pointer(hand)
			var pose: Variant=_pose(hand)
			if pose==null: session.cancel(hand)
			else: session.update_grab(hand,ray[0],ray[1],pose)
			if session.captures.has(hand): point=session.pieces[int(session.captures[hand].id)].global_position
			else:
				var hit: Dictionary=session.pick(ray[0],ray[1])
				if not hit.is_empty(): point=hit.point
				else: point=frame_input.point(hand)
		_update_rotation_hint(hand,ray)
		if app.controller_feedback:
			var pose: Variant=app._move_pose(hand)
			if pose==null and ray!=null: pose=Transform3D(Basis.IDENTITY,ray[0])
			alphas[hand]=app.controller_feedback.update_hand(hand,pose,ray,point,(session!=null and session.captures.has(hand)) or point!=null,
				menu!=null,delta,true,app._controller_activity(hand) if pose!=null else {})
	if app.input_visuals: app.input_visuals.update_visibility(true,alphas)
	if app.display.preview and session and session.captures.has("desktop"):
		session.update_grab("desktop",app.xr_camera.project_ray_origin(desktop_position),app.xr_camera.project_ray_normal(desktop_position))

func desktop(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode in [KEY_TAB,KEY_ESCAPE]:
			if music_open: _back_from_music()
			elif session==null and not panel.preparing: finish()
			elif panel.visible and panel.mode in ["hub","help","sky"] and session and not panel.preparing:
				panel.mode="game"; show_panel(true)
			else: show_panel(not panel.visible)
		elif event.keycode==KEY_R: _action("reference")
		elif event.keycode==KEY_A and session: session.rotate_held("desktop",-1); save_now()
		return
	if event is InputEventMouse:
		desktop_position=event.position
		var origin: Vector3=app.xr_camera.project_ray_origin(event.position)
		var direction: Vector3=app.xr_camera.project_ray_normal(event.position)
		var menu := _ray_menu(origin,direction)
		if event is InputEventMouseMotion:
			if dock and menu!=dock: dock.cancel_pointer("desktop")
			if menu: menu.update_pointer("desktop",origin,direction,true)
			elif session: session.update_grab("desktop",origin,direction)
		elif event is InputEventMouseButton and event.button_index==MOUSE_BUTTON_LEFT:
			if event.pressed:
				if menu: menu.press_pointer("desktop",origin,direction,true)
				elif session: session.grab("desktop",origin,direction,Transform3D.IDENTITY,true,false,true)
			else:
				if menu and menu.has_method("release_pointer"): menu.release_pointer("desktop",origin,direction,true)
				if session: session.release("desktop"); save_now()
