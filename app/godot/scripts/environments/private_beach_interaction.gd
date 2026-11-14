extends "res://scripts/environments/cinema_environment.gd"
## Reuse the auditorium's rig transforms, pointer visuals, single-hand capture,
## focus suspension and stick-neutral/snap-turn rules. Beach owns its resources
## and terrain queries; no auditorium model, bake, XR interface or camera is loaded.
const Beach := preload("res://scripts/environments/private_beach_environment.gd")
const FilmSampler := preload("res://scripts/environments/cinema_film_light.gd")
const ScreenEdit := preload("res://scripts/environments/private_beach_screen_edit.gd")
const BeachMovement := preload("res://scripts/environments/private_beach_locomotion.gd")
const BeachLog := preload("res://scripts/diagnostic_log.gd")
signal screen_committed(parameters: Dictionary)
signal view_committed(view: Dictionary)
signal hours_committed(hours: float)
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
## Sun, moon and firework-button gestures work in both watch and free movement.
var _scene_hand := ""
var _scene_kind := ""
var _scene_hover := {}
## Screen drag state: width anchor for a corner, last ray angles for a grip.
var _screen_drag := {}
var seat_id := ""
var _scene_marks := {}
var _seat_arc_end := 0
## Stick push speed as a share of the current distance per second, with a floor.
const SCREEN_PUSH_RATE := .6
const SCREEN_PUSH_MIN := 1.5
const SCREEN_RESIZE_RATE := .6
const STICK_DEADZONE := .2
## Hand travel is magnified by the screen's distance over a comfortable reach.
const HAND_REACH := .45

func _ready() -> void:
	# Refresh the tracked viewer before the child host may commit a screen edit.
	process_priority=-20
	beach=Beach.new(); beach.name="PrivateBeach"; add_child(beach)
	beach.viewer_position_provider=_viewer_position
	beach.viewer_mouth_provider=_viewer_mouth
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
	if not seat_id.is_empty():
		# The saved seat restores its own eye; the head may sit inside the chair's collider.
		record.seat=seat_id; record.eye_height=clampf(height,.3,2.5); record.mode="watch"
		return record
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
	if beach:
		beach.set_presented(active)
		if beach.fireworks!=null: beach.fireworks.audio.listener=_camera
	if not active:
		suspend(); _restore_original_rig(); set_process(false); return
	if not _has_original_rig:
		_original_rig=_rig.global_transform; _has_original_rig=true
	set_process(true)
	if not _position_applied and _tracking_ready():
		var saved_seat_id: String=str(_restore_view.get("seat",""))
		if beach.seats.has(saved_seat_id):
			interaction="watch"; _movement.set_moving(false); suspend()
			_position_applied=true
			_sit(saved_seat_id)
			return
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
	_movement.observe_source(head)
	_movement.selected_seat=""
	beach.viewer_seated=not seat_id.is_empty()

func _viewer_position() -> Vector3:
	if active: return _camera.global_position if _tracking_ready() else Vector3.INF
	return _movement.eye_position if _movement!=null else Vector3.INF

func _viewer_mouth() -> Vector3:
	if not active or not _tracking_ready(): return Vector3.INF
	return _camera.global_transform*Vector3(0,-.09,-.055)

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
	# Free movement starts from the sand beside the lounger, never from inside it.
	if not seat_id.is_empty() and value=="move": _stand_up()
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
	interaction="watch"; _movement.set_moving(false); suspend(); seat_id=""
	_land(point,0.0); _sync_tracking(); _remember_view(0,true,true); changed.emit()
	return true

func recenter_view() -> bool:
	if not _position_applied or not _tracking_ready(): return false
	var applied := super.recenter_view()
	if applied: _sync_tracking(); _remember_view(0,true,true)
	return applied

func scene_press(hand: String,origin: Vector3,direction: Vector3) -> bool:
	if not active or not _position_applied or not _tracking_ready() or not _scene_hand.is_empty() or not _capture_hand.is_empty(): return false
	if beach.firework_hit(origin,direction):
		beach.press_firework(hand); _scene_kind="firework"
	elif beach.grab_handheld(hand,null,[origin,direction]): return true
	elif _begin_screen_resize(origin,direction): _scene_kind="screen_resize"
	elif beach.begin_drag(direction): _scene_kind="drag"
	else: return false
	_scene_hand=hand
	return true

func celestial_easter_egg(direction: Vector3, activate: bool = true) -> bool:
	if not active or not _position_applied or not _tracking_ready() or not _scene_hand.is_empty() or not _capture_hand.is_empty(): return false
	return beach.celestial_easter_egg(direction, activate)

func _begin_screen_resize(origin: Vector3,direction: Vector3) -> bool:
	var hit: Dictionary=beach.screen_hit(origin,direction)
	if hit.is_empty() or not hit.corner or beach.screen_loading: return false
	var layout: Dictionary=beach.screen_layout
	# The stand stays planted: the panel grows from the middle of its lower edge.
	var anchor: Vector3=layout.center-layout.up*float(layout.half_size.y)
	var reach: float=hit.point.distance_to(anchor)
	if reach<.01: return false
	beach.begin_screen_preview()
	_screen_drag={"anchor":anchor,"normal":layout.normal,"reach":reach,"width":float(layout.parameters.width),"before":ScreenEdit.parameters(layout.parameters)}
	return true

func screen_grab(hand: String,origin: Vector3,direction: Vector3) -> bool:
	if not active or not _position_applied or not _tracking_ready() or not _scene_hand.is_empty() or not _capture_hand.is_empty() or beach.screen_loading: return false
	if beach.screen_hit(origin,direction).is_empty(): return false
	beach.begin_screen_preview()
	var layout: Dictionary=beach.screen_layout
	var axis := Vector3(layout.normal.x,0,layout.normal.z).normalized()
	_screen_drag={"origin":origin,"axis":axis,"center":layout.center,"before":ScreenEdit.parameters(layout.parameters)}
	_scene_hand=hand; _scene_kind="screen_move"
	return true

## A grip drag ends on grip; everything else belongs to the trigger.
func scene_input_matches(action: String) -> bool:
	return (action=="grip_click")==(_scene_kind=="screen_move")

func screen_editing() -> bool:
	return _scene_kind in ["screen_resize","screen_move"]

func _update_screen_drag(origin: Vector3,direction: Vector3) -> void:
	if _scene_kind=="screen_resize":
		var normal: Vector3=_screen_drag.normal
		var facing := direction.dot(normal)
		if absf(facing)<.0001: return
		var t: float=(_screen_drag.anchor-origin).dot(normal)/facing
		if t<=0.0: return
		var reach: float=(origin+direction*t).distance_to(_screen_drag.anchor)
		beach.preview_screen({"width":clampf(float(_screen_drag.width)*reach/float(_screen_drag.reach),1.0,20.0)})
		beach.show_screen_marks(beach.screen_hit(origin,direction))
		return
	# Pulling the hand back brings the screen closer, magnified by its distance.
	var axis: Vector3=_screen_drag.axis
	var range_ := _screen_range()
	var gain := clampf(range_/HAND_REACH,3.0,40.0)
	var travel: float=-(origin-_screen_drag.origin).dot(axis)*gain
	_screen_drag.origin=origin
	_slide_screen(travel)

func _screen_range() -> float:
	var eye: Vector3=_viewer_position()
	var center: Vector3=beach.screen_layout.center
	return Vector2(center.x-eye.x,center.z-eye.z).length() if eye.is_finite() else 10.0

## Moves the whole stand straight along the line it faces; positive is farther away.
func _slide_screen(travel: float) -> void:
	if is_zero_approx(travel): return
	var axis: Vector3=_screen_drag.axis
	var center: Vector3=beach.screen_layout.center-axis*travel
	beach.preview_screen({"center_x":center.x,"center_z":center.z})

## Held grip: horizontal changes size; forward/back moves the whole stand.
func scene_stick(left: Vector2,right: Vector2,delta: float) -> bool:
	if _scene_kind!="screen_move": return false
	var held: Vector2=left if _scene_hand=="left_hand" else right
	if not held.is_finite() or not is_finite(delta) or delta<=0.0: return true
	if absf(held.x)>absf(held.y) and absf(held.x)>STICK_DEADZONE:
		var amount := signf(held.x)*(absf(held.x)-STICK_DEADZONE)/(1.0-STICK_DEADZONE)*SCREEN_RESIZE_RATE*minf(delta,.1)
		if is_zero_approx(amount): return true
		var width := float(beach.screen_layout.parameters.width)*exp(amount)
		# Reuse corner-resize validation: the feet stay on sand and props/viewer stay clear.
		beach.preview_screen({"width":clampf(width,1.0,20.0)})
		return true
	if absf(held.y)<=absf(held.x): return true
	var pushed := signf(held.y)*maxf(absf(held.y)-STICK_DEADZONE,0.0)/(1.0-STICK_DEADZONE)
	if pushed!=0.0: _slide_screen(pushed*maxf(SCREEN_PUSH_MIN,_screen_range()*SCREEN_PUSH_RATE)*delta)
	return true

func _finish_screen_drag() -> void:
	var before: Dictionary=_screen_drag.get("before",{})
	_screen_drag={}
	beach.show_screen_marks({})
	# Commit rebuilds navigation and shadows; a rejected spot returns to where the drag began.
	var edited: Dictionary=ScreenEdit.parameters(beach.screen_layout.parameters)
	if edited==before: beach.request_screen(before)
	elif not request_screen(edited): beach.request_screen(before)

func scene_held(hand: String) -> bool:
	return _scene_hand==hand

func scene_release(hand: String) -> bool:
	if hand.is_empty() or _scene_hand!=hand: return false
	var kind := _scene_kind
	_scene_hand=""; _scene_kind=""
	if kind=="firework": beach.release_firework(hand)
	elif kind in ["screen_resize","screen_move"]: _finish_screen_drag()
	else:
		beach.end_drag()
		hours_committed.emit(beach.hours)
	_sync_scene_highlight()
	return true

## Returns true when this hand has just come onto a target, for haptic feedback.
func scene_hover(hand: String,origin: Vector3,direction: Vector3,valid: bool) -> bool:
	var target := ""
	if valid and active and _position_applied:
		if beach.firework_hit(origin,direction): target="firework"
		else:
			var hit: Dictionary=beach.screen_hit(origin,direction)
			if not hit.is_empty():
				target="corner" if hit.corner else "screen"
				if _scene_hand.is_empty(): _scene_marks[hand]=hit
			elif beach.celestial_hit(direction): target="body"
		if target not in ["corner","screen"]: _scene_marks.erase(hand)
	else: _scene_marks.erase(hand)
	if _scene_hand.is_empty(): beach.show_screen_marks(_scene_marks.values()[0] if not _scene_marks.is_empty() else {})
	var entered: bool=not target.is_empty() and target!=_scene_hover.get(hand,"")
	if _scene_hover.get(hand,"")!=target:
		_scene_hover[hand]=target
		_sync_scene_highlight()
	return entered

func _sync_scene_highlight() -> void:
	if beach: beach.set_scene_highlight(_scene_kind=="drag" or _scene_hover.values().has("body"),_scene_hover.values().has("firework"))

func suspend() -> void:
	if not _scene_hand.is_empty(): scene_release(_scene_hand)
	super.suspend()

func update_pointer(hand: String,origin: Vector3,direction: Vector3,valid: bool = true) -> void:
	if hand==_scene_hand and not hand.is_empty():
		if not valid: scene_release(hand)
		elif _scene_kind=="drag": beach.drag_to(direction)
		elif screen_editing(): _update_screen_drag(origin,direction)
		return
	super.update_pointer(hand,origin,direction,valid)

func cancel_for_hand_lock(hand: String) -> void:
	# Unlike the legacy focus/release path, do not commit a pending scene edit.
	if not hand.is_empty() and _scene_hand == hand:
		var kind := _scene_kind
		_scene_hand = ""; _scene_kind = ""
		if kind == "firework": beach.release_firework(hand)
		elif kind in ["screen_resize", "screen_move"]:
			var before: Dictionary = _screen_drag.get("before", {})
			_screen_drag = {}
			if not before.is_empty(): beach.request_screen(before)
		else: beach.end_drag()
	_scene_hover.erase(hand); _scene_marks.erase(hand)
	if beach:
		beach.show_screen_marks(_scene_marks.values()[0] if not _scene_marks.is_empty() else {})
		_sync_scene_highlight()
	super.cancel_pointer(hand)

func cancel_pointer(hand: String) -> void:
	scene_release(hand)
	super.cancel_pointer(hand)

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
	var seat := _seat_on_arc(hit.points)
	if not seat.is_empty():
		var marker: Vector3=beach.seats[seat].marker
		return {"kind":"seat","id":seat,"position":marker,"points":PackedVector3Array(hit.points.slice(0,int(_seat_arc_end)+1))+PackedVector3Array([marker]),"valid":true,"distance":origin.distance_to(marker)}
	if hit.kind=="none": hit.kind="miss"; hit.position=hit.points[-1]
	hit.valid=hit.get("valid",false) and _valid_destination(hit.position)
	hit.distance=origin.distance_to(hit.position)
	return hit

func _seat_on_arc(points: PackedVector3Array) -> String:
	# Chairs are body colliders, so the arc stops on them; test it against their volumes.
	for index in range(points.size()-1):
		var a: Vector3=points[index]; var b: Vector3=points[index+1]
		for id in beach.seats:
			var box: AABB=beach.seats[id].box
			if box.has_point(b) or box.intersects_segment(a,b):
				_seat_arc_end=index
				return id
	return ""

func _stand_up() -> void:
	# Beside the lounger, on the sand, keeping the heading.
	var eye: Vector3=beach.seats[seat_id].eye
	seat_id=""; beach.viewer_seated=false
	for offset in [Vector3(-1.1,0,0),Vector3(1.1,0,0),Vector3(0,0,-1.6)]:
		var point: Vector3=eye+offset
		point.y=_movement.terrain.ground(point.x,point.z)
		if _destination_supported(point):
			_land(point,_head_yaw()); _sync_tracking()
			return

func _sit(id: String) -> void:
	var seat: Dictionary=beach.seats[id]
	var eye: Vector3=seat.eye
	var screen: Vector3=beach.screen_layout.center
	seat_id=id; interaction="watch"; _movement.set_moving(false); suspend()
	var before := _rig.global_transform
	_align_head(eye,atan2(eye.x-screen.x,eye.z-screen.z))
	_view_floor_y=beach.navigation.ground(eye.x,eye.z)
	if not before.is_equal_approx(_rig.global_transform): view_relocated.emit(before,_rig.global_transform)
	_sync_tracking(); _remember_view(0,true,true); changed.emit()

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
	if target.get("kind","")=="seat":
		_sit(str(target.id))
		return true
	if target.get("valid",false) and _valid_destination(target.position):
		var previous_eye := _camera.global_position
		var source_key: Vector2i=_movement._nav_anchor(_movement.eye_position-Vector3.UP*Locomotion.EYE_HEIGHT)
		var recovering: bool=not _movement._nav_components.has(source_key)
		if _movement.teleport_floor(target.position):
			seat_id=""
			var heading := _head_yaw()
			suspend(); _land(target.position,heading); _sync_tracking(); _remember_view(0,true,true); changed.emit()
			BeachLog.record("beach_teleport",{"from":previous_eye,"to":_camera.global_position,"recovered_source":recovering})
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

func set_hours(value: float,notify := true) -> void:
	if beach: beach.set_hours(value,notify)

func set_surf(audible: bool) -> void:
	if beach: beach.surf_wanted=audible

func set_low_end(value: bool) -> void:
	if beach: beach.set_low_end(value)

func set_screen_light(strength: float) -> void:
	if beach: beach.set_screen_light(strength)

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
