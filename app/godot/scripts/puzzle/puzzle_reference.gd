extends "res://scripts/ray_menu.gd"
## Follow palm position without rotating a wrist-mounted offset around the hand.
const DRAG := 3
var source := {}
var enabled := true
var companion: Node3D
var pinned := false
var preferred_hand := "left_hand"
var hand_attached := false
var picture: MeshInstance3D
var drag := {}
var viewer := Transform3D.IDENTITY

func composition_root() -> Node3D:
	return companion if is_instance_valid(companion) and companion.is_visible_in_tree() else self

func _place_device_status(_centre: Vector2) -> void: pass

func _draw() -> void:
	_clear_layout()
	var size: Vector2=source.get("size",Vector2(3,2))
	var ratio := maxf(0.1,size.x/maxf(1,size.y))
	var dimensions := Vector2(0.32,minf(0.32/ratio,0.28)); dimensions.x=dimensions.y*ratio
	var width := maxf(0.20,dimensions.x)
	_set_backdrop(Vector2(width+0.02,dimensions.y+0.055),Vector2(0,0.0175))
	picture=MeshInstance3D.new(); var quad := QuadMesh.new(); quad.size=dimensions; picture.mesh=quad
	var material := ShaderMaterial.new(); material.shader=preload("res://shaders/puzzle_piece.gdshader")
	material.set_shader_parameter("image_texture",source.get("texture"))
	material.set_shader_parameter("stereo_layout",int(source.get("layout",0)))
	material.set_shader_parameter("swap_eyes",bool(source.get("swap_eyes",false)))
	material.set_shader_parameter("spatial_disparity",float(source.get("spatial_disparity",0)))
	picture.material_override=material; picture.position.z=0.008; add_child(picture); _decorations.append(picture)
	_ray_blockers.append({"target":DRAG,"rect":Rect2(-dimensions*0.5,dimensions),"enabled":true,"node":picture,"radius":0.0})
	_round(1,"head_follow",Vector2(width*0.5-0.067,dimensions.y*0.5+0.026),0.038,true,not pinned,I18n.t("Follow hand"))
	_round(2,"close",Vector2(width*0.5-0.020,dimensions.y*0.5+0.026),0.038,true,false,I18n.t("Close"))

func _activate(target: int) -> void:
	if target==1: pinned=not pinned; refresh()
	elif target==2: enabled=false; dismiss()

func place(app: Node, session: Node, samples: Dictionary, delta: float) -> void:
	if not visible: return
	var head: Transform3D=app.xr_camera.global_transform
	viewer=head
	if pinned:
		if drag.is_empty(): _face_viewer()
		return
	var pose: Variant=null
	var point: Variant=null
	if not session.captures.has(preferred_hand):
		point=samples.get(preferred_hand,{}).get("reference_position")
		pose=samples.get(preferred_hand,{}).get("pose")
		if not pose is Transform3D: pose=app._move_pose(preferred_hand)
		if not point is Vector3 and pose is Transform3D and pose.is_finite(): point=pose.origin
	var next := Transform3D.IDENTITY
	if point is Vector3 and point.is_finite() and point.distance_to(head.origin)>0.1 and point.distance_to(head.origin)<1.5:
		var forward := -head.basis.z; forward.y=0
		if forward.length_squared()<0.01: forward=Vector3.FORWARD
		forward=forward.normalized(); var right := forward.cross(Vector3.UP)
		next.origin=point+right*(-0.05 if preferred_hand=="left_hand" else 0.05)+Vector3.UP*0.18+forward*0.10
		hand_attached=true
	else:
		hand_attached=false
		if not session.spherical:
			var frame: Transform3D=session.frame_world_pose(); var axes := frame.basis.orthonormalized()
			next=Transform3D(axes,frame.origin+axes.y*(session.board_size.y*session.frame_scale()*0.5+0.22)-axes.x*0.20+axes.z*0.06)
		else:
			var forward := -head.basis.z; forward.y=0
			if forward.length_squared()<0.01: forward=Vector3.FORWARD
			forward=forward.normalized(); var axes := Basis.looking_at(forward,Vector3.UP)
			next=Transform3D(axes,head.origin+forward*0.9-axes.x*0.38-Vector3.UP*0.15)
	global_position=next.origin if delta<=0 else global_position.lerp(next.origin,1.0-exp(-delta*14.0))
	_face_viewer()

func _face_viewer() -> void:
	var direction := global_position-viewer.origin
	if direction.length_squared()<0.01: return
	var up := viewer.basis.y.normalized()
	global_basis=Basis.looking_at(direction.normalized(),up if absf(up.dot(direction.normalized()))<0.98 else viewer.basis.x)

func has_pointer_capture() -> bool: return not drag.is_empty()

func press_pointer(hand: String, origin: Vector3, direction: Vector3, tracked: bool) -> bool:
	if not drag.is_empty(): return true
	var hit := ray_hit(origin,direction) if tracked else {}
	if int(hit.get("target",NONE))!=DRAG: return super(hand,origin,direction,tracked)
	pinned=true; refresh()
	drag={"hand":hand,"distance":float(hit.distance),"anchor":hit.point,"basis":global_basis}
	return true

func update_pointer(hand: String, origin: Vector3, direction: Vector3, tracked: bool) -> void:
	if drag.get("hand","")==hand:
		if not tracked or not origin.is_finite() or not direction.is_finite() or direction.length_squared()<0.1: drag.clear()
		else: global_position=origin+direction.normalized()*float(drag.distance)-Basis(drag.basis)*Vector3(drag.anchor)
	super(hand,origin,direction,tracked)

func release_pointer(hand: String, origin: Vector3, direction: Vector3, tracked: bool) -> void:
	if drag.get("hand","")!=hand: return
	update_pointer(hand,origin,direction,tracked); drag.clear(); _face_viewer()

func cancel_pointer(hand: String) -> void:
	if drag.get("hand","")==hand: drag.clear()
	super(hand)
