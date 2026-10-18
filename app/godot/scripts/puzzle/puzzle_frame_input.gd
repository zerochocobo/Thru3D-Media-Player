extends RefCounted
## Reuse the photo's grip movement and two-hand pinch recognizer for the target board.
const Movement := preload("res://scripts/interface_move.gd")
const Gestures := preload("res://scripts/photo_hand_gestures.gd")
const Follow := preload("res://scripts/view_follow.gd")
var host: Node
var movement := Movement.new()
var gestures := Gestures.new()
var follow := Follow.new()
var resize := {}
var samples := {}
var optical_move := false

func _init(owner: Node) -> void: host=owner
func enabled() -> bool:
	return host.active and host.saving_ready and host.session!=null and not host.session.spherical and not host.session.paused \
		and host.input_menu()==null and host.app._input_focused() and not host.app._background_app_paused

func cancel(reset: bool = false) -> void:
	movement.cancel(); resize.clear(); gestures.cancel(); optical_move=false
	if reset: gestures.owners.clear(); samples.clear()
	if host.session: host.session.set_frame_corner(-1)

func _pose(hand: String) -> Variant:
	var sample: Dictionary=samples.get(hand,{})
	if sample.get("source")=="hand" and host.app.hand_pointers[hand].source=="hand":
		if not sample.get("tracked",false): return null
		var ray: Variant=host.app._ray(hand)
		if ray==null: return null
		var point: Variant=sample.get("position",ray[0])
		if not point is Vector3 or not point.is_finite(): return null
		var up := Vector3.UP if absf(ray[1].dot(Vector3.UP))<0.98 else Vector3.RIGHT
		return Transform3D(Basis.looking_at(ray[1],up),point)
	return host.app._move_pose(hand)

func _begin_move(hand: String, hit: Dictionary, optical: bool) -> bool:
	var pose: Variant=_pose(hand)
	if pose==null: return false
	var target := {"node":host.session,"kind":"screen","pose":host.session.frame_world_pose(),"key":"puzzle_frame","distance_limits":Vector2(0.3,10.0)}
	optical_move=optical
	return movement.begin(hand,"trigger_click" if optical else "grip_click",pose,[target],hit.point,host.app.xr_camera.global_transform)

func button(action: String, hand: String, released: bool) -> bool:
	if released:
		if resize.get("hand","")==hand and action=="trigger_click":
			_update_resize(); resize.clear(); host.ready_after_release[hand]=true; host.save_now(); return true
		if not movement.capture.is_empty() and movement.capture.hand==hand and not optical_move and action=="grip_click":
			_update_move(); movement.cancel(); host.ready_after_release[hand]=true; host.save_now(); return true
		return false
	if not enabled() or not host.session.captures.is_empty() or not host.ready_after_release.get(hand,true): return false
	var ray: Variant=host.app._ray(hand)
	if ray==null or host._ray_menu(ray[0],ray[1])!=null or not host.session.pick(ray[0],ray[1]).is_empty(): return false
	var hit: Dictionary=host.session.frame_hit(ray[0],ray[1])
	if hit.is_empty(): return false
	if action=="grip_click" and movement.capture.is_empty() and resize.is_empty():
		if not _begin_move(hand,hit,false): return false
		host.ready_after_release[hand]=false; return true
	if action=="trigger_click" and int(hit.corner)>=0 and resize.is_empty() and movement.capture.is_empty():
		var world: Transform3D=host.session.frame_world_pose()
		var point: Vector3=world.affine_inverse()*hit.point
		resize={"hand":hand,"corner":hit.corner,"world":world,"length":Vector2(point.x,point.y).length(),"scale":host.session.frame_scale()}
		host.ready_after_release[hand]=false
		return true
	return false

func hand_inputs(inputs: Dictionary) -> Array:
	samples=inputs
	var accepted := {}
	for hand in inputs:
		var sample: Dictionary=inputs[hand]
		if gestures.owners.has(hand): accepted[hand]=sample; continue
		if not enabled() or not host.session.captures.is_empty() or not sample.get("pressed",false) or sample.get("source")!="hand": continue
		var ray: Variant=host.app._ray(hand)
		if ray==null or host._ray_menu(ray[0],ray[1])!=null or not host.session.pick(ray[0],ray[1]).is_empty(): continue
		if not host.session.frame_hit(ray[0],ray[1]).is_empty() or not gestures.owners.is_empty(): accepted[hand]=sample
	var active: bool=enabled() and host.session.captures.is_empty()
	var result: Dictionary=gestures.update(accepted,active,host.session.frame_scale() if host.session else 1.0,
		host.app.xr_camera.global_basis,XRServer.world_scale,host.session.get_instance_id() if host.session else -1)
	if gestures.mode=="single":
		if movement.capture.is_empty():
			var ray: Variant=host.app._ray(gestures.hand)
			var hit: Dictionary=host.session.frame_hit(ray[0],ray[1]) if ray!=null else {}
			if not hit.is_empty(): _begin_move(gestures.hand,hit,true)
		_update_move()
	elif gestures.mode=="dual": movement.cancel(); optical_move=false
	elif optical_move: movement.cancel(); optical_move=false; host.save_now()
	for action in result.actions:
		if action.operation=="zoom": host.session.set_frame_scale(float(action.value))
		elif action.operation=="finish": host.save_now()
	return result.consumed

func _update_move() -> void:
	if movement.capture.is_empty(): return
	var pose: Variant=_pose(str(movement.capture.hand))
	if pose==null: movement.cancel(); host.save_now(); return
	movement.update(pose,host.app.xr_camera.global_transform,follow)

func _update_resize() -> void:
	if resize.is_empty(): return
	var ray: Variant=host.app._ray(str(resize.hand))
	if ray==null: resize.clear(); host.save_now(); return
	var inverse: Transform3D=resize.world.affine_inverse()
	var origin: Vector3=inverse*ray[0]; var direction: Vector3=inverse.basis*ray[1]
	if origin.z<=0 or direction.z>=-0.00001: return
	var point := origin+direction*(-origin.z/direction.z)
	host.session.set_frame_scale(float(resize.scale)*Vector2(point.x,point.y).length()/float(resize.length))

func tick(delta: float, left: Vector2, right: Vector2) -> void:
	if not enabled(): cancel(); return
	if not host.session.captures.is_empty(): cancel(); return
	if not movement.capture.is_empty():
		movement.adjust_distance(left if movement.capture.hand=="left_hand" else right,delta)
		_update_move()
	_update_resize()
	var corner := int(resize.get("corner",-1))
	if corner<0:
		for hand in ["left_hand","right_hand"]:
			var ray: Variant=host.app._ray(hand)
			if ray==null or not host.session.pick(ray[0],ray[1]).is_empty(): continue
			var hit: Dictionary=host.session.frame_hit(ray[0],ray[1])
			if not hit.is_empty() and hit.corner>=0: corner=int(hit.corner); break
	host.session.set_frame_corner(corner)

func point(hand: String) -> Variant:
	if not movement.capture.is_empty() and movement.capture.hand==hand: return movement.capture.anchor
	var ray: Variant=host.app._ray(hand)
	if enabled() and ray!=null:
		var hit: Dictionary=host.session.frame_hit(ray[0],ray[1])
		if not hit.is_empty(): return hit.point
	return null
