extends "res://scripts/environments/cinema_environment.gd"
## Reuse the auditorium's rig transforms, pointer visuals, single-hand capture,
## focus suspension and stick-neutral/snap-turn rules. Beach owns its resources
## and terrain queries; no auditorium model, bake, XR interface or camera is loaded.
const Beach := preload("res://scripts/environments/private_beach_environment.gd")
const FilmSampler := preload("res://scripts/environments/cinema_film_light.gd")
const ScreenEdit := preload("res://scripts/environments/private_beach_screen_edit.gd")
const BeachMovement := preload("res://scripts/environments/private_beach_locomotion.gd")
signal screen_committed(parameters: Dictionary)
signal view_committed(view: Dictionary)
var saved_screen := {}
var saved_view := {}
var view_restore_failed := false
var screen_restore_failed := false
var _restore_pending := true
var _restoring_screen := false
var _screen_requested := false
var _restore_view := {}
var _observed_view := {}
var _resume_mode := "watch"
var _view_sample_time := 0.0
var _view_stable_time := 0.0
var _view_unsaved_time := 0.0
var beach: Node3D
var _view_floor_y := INF

func _ready() -> void:
	# Refresh the tracked viewer before the child host may commit a screen edit.
	process_priority=-20
	beach=Beach.new(); beach.name="PrivateBeach"; add_child(beach)
	beach.viewer_position_provider=_viewer_position
	beach.changed.connect(_beach_changed)
	set_process(false)

func prepare() -> void:
	if beach: beach.prepare(); _beach_changed()

func select(enabled: bool) -> void:
	if selected==enabled: return
	if active: _sync_tracking(); _remember_view(0,true)
	selected=enabled
	if enabled: prepare()
	else:
		suspend(); interaction="watch"
		if _movement: _movement.set_moving(false)
	_update_active(); changed.emit()

func set_presented(enabled: bool) -> void:
	if _presented==enabled: return
	if active: _sync_tracking(); _remember_view(0,true)
	_presented=enabled; suspend(); _update_active(); changed.emit()

func _beach_changed() -> void:
	if not beach.is_ready: _restore_pending=true; _restoring_screen=false; _screen_requested=false
	if beach.is_ready and beach.movement==null and not beach.movement_loading: beach.prepare_movement()
	var previous: RefCounted = _movement
	_movement=beach.movement
	if _movement==null: _view_floor_y=INF
	if beach.is_ready and _movement!=null and _restore_pending:
		_restore_pending=false
		_restore_view=_restoration_view()
		if not saved_screen.is_empty():
			_restoring_screen=true
			if not beach.request_screen(saved_screen,_restore_view):
				_restoring_screen=false; screen_restore_failed=true; _finish_view_restore(false)
		else: _finish_view_restore(false)
	if _restoring_screen and not beach.screen_loading:
		_restoring_screen=false; screen_restore_failed=not beach.screen_error.is_empty()
		_finish_view_restore(not screen_restore_failed)
	is_ready=beach.is_ready and _movement!=null and not _restoring_screen
	loading=beach.loading or beach.movement_loading or _restoring_screen
	error=beach.error
	if _movement!=previous: suspend()
	if not beach.screen_layout.is_empty():
		var layout: Dictionary = beach.screen_layout
		var center: Vector3 = layout.center
		_manifest={"scene_id":"private_beach","default_seat":"default_view","screen":{
			"position":[center.x,center.y,center.z],"width":layout.half_size.x*2,"height":layout.half_size.y*2,
			"yaw":deg_to_rad(float(layout.parameters.yaw_degrees)),"pitch":deg_to_rad(float(layout.parameters.pitch_degrees))}}
	_update_active()
	if _screen_requested and not beach.screen_loading:
		_screen_requested=false
		if beach.screen_error.is_empty():
			screen_restore_failed=false
			saved_screen=ScreenEdit.parameters(beach.screen_layout.parameters)
			screen_committed.emit(saved_screen.duplicate(true))
			_remember_view(0,true,true)
	changed.emit()

func _restoration_view() -> Dictionary:
	var record := saved_view.duplicate(true)
	if not BeachMovement.valid_view_record(record):
		if not record.is_empty(): view_restore_failed=true
		var viewer: Dictionary = beach.bundle.config.viewer
		record={"schema":1,"x":float(viewer.x),"z":float(viewer.z),"yaw":0.0,"eye_height":float(viewer.eye_height),"mode":"watch"}
	# This is clearance metadata only. _land always uses the current tracked
	# height, never the old seated/standing eye height saved with the position.
	if is_instance_valid(_rig) and is_instance_valid(_camera) and _tracking_ready():
		record.eye_height=maxf(float(record.eye_height),clampf(_tracked_height(),.3,2.5))
	return record

func _finish_view_restore(already_applied: bool) -> void:
	if not already_applied and not _movement.restore_view(_restore_view):
		view_restore_failed=not saved_view.is_empty()
		_movement.home()
	_resume_mode="move" if _movement.mode==Locomotion.Mode.MOVE else "watch"
	_view_floor_y=_movement.terrain.ground(_movement.eye_position.x,_movement.eye_position.z)

func view_record() -> Dictionary:
	if not active or not _position_applied or not is_instance_valid(_rig) or not is_instance_valid(_camera) or not _tracking_ready() or _movement==null: return {}
	var head := _camera.global_position
	var height := _tracked_height()
	var record := {"schema":1,"x":head.x,"z":head.z,"yaw":_head_yaw(),"eye_height":height,"mode":interaction}
	if not BeachMovement.valid_view_record(record) or not _destination_supported(Vector3(head.x,_movement.terrain.ground(head.x,head.z),head.z)): return {}
	return record

static func _same_view(a: Dictionary,b: Dictionary) -> bool:
	if not BeachMovement.valid_view_record(a) or not BeachMovement.valid_view_record(b): return false
	return Vector2(a.x,a.z).distance_to(Vector2(b.x,b.z))<.04 and absf(wrapf(a.yaw-b.yaw,-PI,PI))<.02 and absf(a.eye_height-b.eye_height)<.04 and a.mode==b.mode

func _remember_view(delta: float,force := false,accept_fallback := false) -> void:
	if accept_fallback: view_restore_failed=false
	_view_sample_time+=delta
	if not force and _view_sample_time<.2: return
	var elapsed := _view_sample_time; _view_sample_time=0
	var record := view_record()
	if not record.is_empty():
		if not _same_view(record,_observed_view): _observed_view=record; _view_stable_time=0
		else: _view_stable_time+=elapsed
	if _observed_view.is_empty() or view_restore_failed: return
	_resume_mode=str(_observed_view.mode)
	if _same_view(saved_view,_observed_view): return
	_view_unsaved_time+=elapsed
	# Save after a short rest, at most every five seconds during continuous
	# movement, and immediately on explicit placement or leaving the scene.
	if not force and _view_stable_time<.6 and _view_unsaved_time<5: return
	saved_view=_observed_view.duplicate(true); _view_unsaved_time=0
	view_committed.emit(saved_view.duplicate(true))

func _update_active() -> void:
	active=selected and _presented and is_ready and is_instance_valid(_rig) and is_instance_valid(_camera)
	if beach: beach.set_presented(active)
	if not active:
		suspend(); _restore_original_rig(); set_process(false); return
	if not _has_original_rig:
		_original_rig=_rig.global_transform; _has_original_rig=true
	set_process(true)
	if not _position_applied and _tracking_ready():
		var point: Vector3 = _movement.eye_position
		# Room-scale X/Z can move across a small slope without changing the
		# tracking floor. Restore that floor instead of adding a vertical jump.
		point.y=_view_floor_y if is_finite(_view_floor_y) else _movement.terrain.ground(point.x,point.z)
		# Tracking may arrive after navigation was prepared with the old eye
		# height. Check the actual current clearance before moving the rig.
		if not _entry_supported(point):
			var report_failure := not view_restore_failed
			view_restore_failed=true
			point=_entry_fallback(point)
			if report_failure: changed.emit()
			if not point.is_finite(): suspend(); return
		interaction=_resume_mode
		if not _movement.set_moving(interaction=="move"): interaction="watch"
		suspend()
		_land(point,float(_movement.yaw))
		_position_applied=true
		_sync_tracking()

func _entry_supported(point: Vector3) -> bool:
	var ground := Vector3(point.x,_movement.terrain.ground(point.x,point.z),point.z)
	if not _destination_supported(ground): return false
	return not _movement._body_blocked(ground,ground.y+.03,maxf(ground.y+Locomotion.EYE_HEIGHT,point.y+_tracked_height())+Locomotion.HEAD_CLEARANCE)

func _entry_fallback(point: Vector3) -> Vector3:
	# Bounded local search on the current layout; the authored Home may itself
	# be occupied by the saved screen. Keep the rejected record for adjustment.
	for radius in [.5,1.0,2.0,4.0,8.0]:
		for index in 16:
			var angle := TAU*index/16.0
			var candidate: Vector3 = point+Vector3(cos(angle),0,sin(angle))*radius
			candidate.y=_movement.terrain.ground(candidate.x,candidate.z)
			if _destination_supported(candidate): return candidate
	var viewer: Dictionary = beach.bundle.config.viewer
	var home_floor := Vector3(viewer.x,beach.navigation.ground(viewer.x,viewer.z),viewer.z)
	return home_floor if _destination_supported(home_floor) else Vector3.INF

func _process(delta: float) -> void:
	if not active: return
	if not _position_applied: _update_active()
	if not _tracking_ready(): suspend(); return
	_sync_tracking()
	_remember_view(delta)

func _sync_tracking() -> void:
	if not active or not _position_applied or not _tracking_ready(): return
	var head := _camera.global_position
	# Navigation MOVE keeps a standing-height anchor for inherited reachability;
	# the rig itself retains the user's physical height, including crouching.
	if interaction=="move": head.y=_movement.terrain.ground(head.x,head.z)+Locomotion.EYE_HEIGHT
	_movement.eye_position=head; _movement.yaw=_head_yaw()
	_movement.selected_seat=""

func _viewer_position() -> Vector3:
	if active: return _camera.global_position if _tracking_ready() else Vector3.INF
	return _movement.eye_position if _movement!=null else Vector3.INF

func _tracking_ready() -> bool:
	return _head_tracked()

func _tracked_height() -> float:
	return _camera.global_position.y-_rig.global_position.y

func _land(floor_position: Vector3,heading: float) -> void:
	var before := _rig.global_transform
	_align_head(floor_position+Vector3.UP*_tracked_height(),heading)
	_view_floor_y=floor_position.y
	if not before.is_equal_approx(_rig.global_transform): view_relocated.emit(before,_rig.global_transform)

func set_interaction(value: String) -> bool:
	if value not in ["watch","move"] or not active or not _position_applied or not _tracking_ready(): return false
	if interaction==value: return true
	_sync_tracking(); suspend()
	if not _movement.set_moving(value=="move"): return false
	interaction=value
	_sync_tracking(); _remember_view(0,true,true); changed.emit()
	return true

func home() -> bool:
	if not active or not _position_applied or not _tracking_ready(): return false
	var viewer: Dictionary = beach.bundle.config.viewer
	var point := Vector3(viewer.x,beach.navigation.ground(viewer.x,viewer.z),viewer.z)
	# Like the auditorium's Home, this explicit reset can recover a tracked head
	# that physically stepped outside the virtual navigation boundary.
	if not _destination_supported(point): return false
	interaction="watch"; _movement.set_moving(false); suspend()
	_land(point,0.0); _sync_tracking(); _remember_view(0,true,true); changed.emit()
	return true

func recenter_view() -> bool:
	if not _position_applied or not _tracking_ready(): return false
	var applied := super.recenter_view()
	if applied: _sync_tracking(); _remember_view(0,true,true)
	return applied

func pointer_press(hand: String,origin: Vector3,direction: Vector3) -> bool:
	if not _position_applied or not _tracking_ready(): return false
	return super.pointer_press(hand,origin,direction)

func poll_sticks(left: Vector2,right: Vector2,delta: float,blocked := false) -> bool:
	if not _position_applied or not _tracking_ready():
		suspend(); return active and interaction!="watch"
	_sync_tracking()
	var before := _camera.global_transform
	var consumed := super.poll_sticks(left,right,delta,blocked)
	if not _camera.global_transform.is_equal_approx(before): view_restore_failed=false
	return consumed

func ray_hit(origin: Vector3,direction: Vector3,_held_seat := "") -> Dictionary:
	if not active or interaction!="move" or not _position_applied or not _tracking_ready(): return {}
	_sync_tracking()
	var hit: Dictionary = _movement.arc_target(origin,direction)
	if hit.is_empty(): return hit
	if hit.kind=="none": hit.kind="miss"; hit.position=hit.points[-1]
	hit.valid=hit.get("valid",false) and _valid_destination(hit.position)
	hit.distance=origin.distance_to(hit.position)
	return hit

func _valid_destination(point: Vector3) -> bool:
	if not _destination_supported(point): return false
	var head := _camera.global_position
	var source := Vector3(head.x,_movement.terrain.ground(head.x,head.z),head.z)
	return _movement._reachable(source,point)

func _destination_supported(point: Vector3) -> bool:
	if not active or _movement==null or not point.is_finite(): return false
	var standing: Vector3 = _movement._standing_at(point,.04)
	if not standing.is_finite(): return false
	var height := maxf(Locomotion.EYE_HEIGHT,_tracked_height())+Locomotion.HEAD_CLEARANCE
	if _movement._body_blocked(standing,standing.y+.03,standing.y+height): return false
	return true

func pointer_release(hand: String,origin: Vector3,direction: Vector3,valid: bool) -> bool:
	if _capture_hand!=hand or _capture.is_empty(): return false
	# Re-query the live ray against the current navigation graph, including a
	# screen edit that completed since press. Stale press-time targets never land.
	var target := _pointer_target(origin,direction) if valid else {}
	_capture={}; _capture_hand=""; hide_pointer(hand)
	if target.get("valid",false) and _valid_destination(target.position):
		if _movement.teleport_floor(target.position):
			var heading := _head_yaw()
			suspend(); _land(target.position,heading); _sync_tracking(); _remember_view(0,true,true); changed.emit()
	return true

func request_screen(changes: Dictionary) -> bool:
	if not is_ready or not beach or beach.screen_loading: return false
	_sync_tracking()
	_screen_requested=true
	var accepted: bool = beach.request_screen(changes)
	if not accepted: _screen_requested=false; changed.emit()
	return accepted

func set_night(enabled: bool) -> void:
	if beach: beach.set_night(enabled)

func set_film_light(colors: Array) -> void:
	if not beach or colors.size()!=3: return
	# Auditorium sampler returns gain relative to REFERENCE, while beach light
	# takes linear RGB. Reuse its exposure conversion, not the indoor lightmap.
	film_light=colors.duplicate()
	beach.set_film_color((colors[0]+colors[1]+colors[2])*(FilmSampler.REFERENCE/3.0))

func snapshot() -> Dictionary:
	var state := super.snapshot()
	state.scene_id="private_beach"
	state.night=beach.night if beach else false
	state.screen_loading=beach.screen_loading if beach else false
	state.screen_error=beach.screen_error if beach else ""
	return state

func _exit_tree() -> void:
	# The child owns its asynchronous loader/worker and drains them on destruction.
	_remember_view(0,true)
	suspend(); _restore_original_rig()
