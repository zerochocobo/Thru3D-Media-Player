extends Node3D
signal piece_placed(id: int, hand: String)
signal piece_rotated(id: int, hand: String)
signal changed
signal prepared
const Geometry := preload("res://scripts/puzzle/puzzle_geometry.gd")
const Piece := preload("res://scripts/puzzle/puzzle_piece.gd")
const Builder := preload("res://scripts/puzzle/puzzle_builder.gd")
const Sphere := preload("res://scripts/puzzle/puzzle_sphere.gd")
const SkyEnvironment := preload("res://scripts/puzzle/puzzle_sky.gd")
const Gallery := preload("res://scripts/photo_gallery.gd")
const FLAT_COUNTS := [24,48,96]
const SPHERE_COUNTS := [6,24,54]
const DEFAULT_COUNT := 24
const MAX_PIECES := 96
var pieces: Array[MeshInstance3D] = []
var captures := {}
var source := {}
var grid := Vector2i(4,3)
var board_size := Vector2(1.2,0.8)
var paused := false
var hint: MeshInstance3D
var seed_value := 731
var standing := false
var tray_page := 0
var tray_seed := 0
var preparing := false
var builder := Builder.new()
var pending_geometry: Array = []
var max_commit_ms := 0.0
var prepare_error := ""
var spherical := false
var sky: Node3D
var view_face := 0
var backdrop := "night"
var turning := false
var turn_tween: Tween
var board: MeshInstance3D
var frame_pose := Transform3D.IDENTITY
var frame_reference: MeshInstance3D
var frame_handles: MeshInstance3D
var frame_corner := -1
var random_rotation := false
var viewer_position := Vector3(0,0,1.8)
var frame_adjusted := false
const FRAME_SCALE_LIMITS := Vector2(0.4,6.0)
const FRAME_MARGIN := 0.06
const HELD_DISTANCE := 0.28

func tray_capacity() -> int:
	if spherical: return 16 if standing else 12
	var total := pieces.size()
	return mini(total,(16 if total<=24 else (24 if total<=48 else 48)) if standing else (12 if total<=24 else (24 if total<=48 else 32)))

func shuffle_tray() -> void:
	tray_seed=randi_range(1,2147483647); tray_page=0; scatter(standing)

func rotate_held(hand: String, steps: int = 1) -> bool:
	if paused or not random_rotation or not captures.has(hand): return false
	var capture: Dictionary=captures[hand]; var piece: MeshInstance3D=pieces[int(capture.id)]
	piece.turn_angle=wrapf((roundf(piece.turn_angle/(PI*0.5))+steps)*PI*0.5,-PI,PI)
	capture.sound_turn=piece.turn_angle; capture.candidate=false
	_update_hint(); piece_rotated.emit(piece.piece_id,hand); changed.emit(); return true

func frame_size() -> Vector2: return board_size+Vector2.ONE*FRAME_MARGIN*2

func frame_scale() -> float: return frame_pose.basis.get_scale().x
func frame_world_pose() -> Transform3D: return global_transform*frame_pose

func set_flat_world_pose(world: Transform3D) -> void:
	set_frame_pose(global_transform.affine_inverse()*world)

func set_frame_scale(value: float) -> void:
	if not is_finite(value): return
	var pose := frame_pose
	pose.basis=pose.basis.orthonormalized().scaled(Vector3.ONE*clampf(value,FRAME_SCALE_LIMITS.x,FRAME_SCALE_LIMITS.y))
	set_frame_pose(pose)

func set_frame_pose(value: Transform3D, user_adjustment: bool = true) -> void:
	if spherical or preparing or not value.is_finite() or value.origin.length()>12: return
	var scale_value := value.basis.get_scale()
	if scale_value.x<FRAME_SCALE_LIMITS.x-0.0001 or scale_value.x>FRAME_SCALE_LIMITS.y+0.0001 or scale_value.distance_to(Vector3.ONE*scale_value.x)>0.001: return
	if not value.basis.orthonormalized().scaled(scale_value).is_equal_approx(value.basis): return
	if value.is_equal_approx(frame_pose): return
	if user_adjustment: frame_adjusted=true
	frame_pose=value; _sync_frame(); scatter(standing)

func _sync_frame() -> void:
	if spherical: return
	for piece in pieces:
		piece.goal=frame_pose*piece.base_goal
		if piece.placed: piece.stop_motion(); piece.transform=piece.goal
	if board: board.transform=frame_pose*Transform3D(Basis.IDENTITY,Vector3(0,0,-0.022))
	if frame_reference: frame_reference.transform=frame_pose*Transform3D(Basis.IDENTITY,Vector3(0,0,0.06))
	if frame_handles: frame_handles.transform=frame_pose
	if frame_corner>=0: set_frame_corner(frame_corner,true)
	_update_hint()

func menu_anchor(below: float) -> Transform3D:
	var world := frame_world_pose(); var axes := world.basis.orthonormalized()
	return Transform3D(axes,world.origin-axes.y*(frame_size().y*frame_scale()*0.5+below)+axes.z*0.04)

func frame_hit(origin: Vector3, direction: Vector3) -> Dictionary:
	if spherical or preparing or not origin.is_finite() or not direction.is_finite() or direction.length_squared()<0.1: return {}
	var world := frame_world_pose(); var inverse := world.affine_inverse()
	var start := inverse*origin; var ray := inverse.basis*direction.normalized()
	if start.z<=0 or ray.z>=-0.00001: return {}
	var point := start+ray*(-start.z/ray.z); var half := frame_size()*0.5
	var margin := 0.06/frame_scale()
	if absf(point.x)>half.x+margin or absf(point.y)>half.y+margin: return {}
	var corner := -1
	for i in 4:
		var target := Vector2(half.x*(-1 if i%2==0 else 1),half.y*(1 if i<2 else -1))
		if Vector2(point.x,point.y).distance_to(target)<=margin: corner=i; break
	return {"point":world*point,"corner":corner,"distance":origin.distance_to(world*point)}

func set_frame_corner(value: int, force: bool = false) -> void:
	if spherical or board==null: return
	if frame_corner==value and not force: return
	frame_corner=value
	if frame_handles==null:
		frame_handles=MeshInstance3D.new(); frame_handles.mesh=ImmediateMesh.new(); add_child(frame_handles)
		var ink := StandardMaterial3D.new(); ink.shading_mode=BaseMaterial3D.SHADING_MODE_UNSHADED; ink.albedo_color=Color(0.5,0.85,0.75)
		frame_handles.material_override=ink
	frame_handles.visible=value>=0
	if value<0: return
	frame_handles.transform=frame_pose
	var mesh: ImmediateMesh=frame_handles.mesh; mesh.clear_surfaces(); mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	var x := -1.0 if value%2==0 else 1.0; var y := 1.0 if value<2 else -1.0
	var corner := Vector3(frame_size().x*x*0.5,frame_size().y*y*0.5,0.008)
	var length := 0.045/frame_scale()
	for p in [corner-Vector3(x*length,0,0),corner,corner,corner-Vector3(0,y*length,0)]: mesh.surface_add_vertex(p)
	mesh.surface_end()

## Match physical piece aspect, keeping the selected total exact.
static func grid_for_source(image_source: Dictionary, count: int) -> Vector2i:
	if image_source.get("projection","flat")=="sphere":
		var side := roundi(sqrt(float(count)/6.0))
		return Vector2i(side*6,side)
	var size: Vector2=image_source.get("size",Vector2.ONE)
	var aspect := maxf(0.001,size.x/maxf(0.001,size.y))
	var best := Vector2i(count,1); var error := INF
	for columns in range(1,count+1):
		if count%columns!=0: continue
		var rows := count/columns
		var candidate := absf(log(aspect*rows/columns))
		if candidate<error: error=candidate; best=Vector2i(columns,rows)
	return best

func configure(image_source: Dictionary, dimensions: Vector2i = Vector2i(4,3), seed_id: int = 731) -> bool:
	if not _initialize_source(image_source,dimensions,seed_id): return false
	for y in grid.y:
		for x in grid.x:
			var geometry := Sphere.patch(Vector2i(x,y),grid,false,seed_value) if spherical else Geometry.flat(Vector2i(x,y),grid,board_size,_options())
			if geometry.is_empty(): clear(); return false
			_add_piece(geometry,Vector2i(x,y))
	_finish_preparing(); return true

func prepare_async(image_source: Dictionary, dimensions: Vector2i = Vector2i(4,3), seed_id: int = 731) -> bool:
	if not _initialize_source(image_source,dimensions,seed_id): return false
	preparing=true; visible=false
	var options := _options(); options["arrays_only"]=true
	if not builder.start({"grid":grid,"size":board_size,"options":options,"projection":"sphere" if spherical else "flat"}):
		preparing=false; return false
	return true

func _initialize_source(image_source: Dictionary, dimensions: Vector2i, seed_id: int) -> bool:
	if image_source.get("texture") == null or image_source.get("size",Vector2.ZERO).y <= 0 \
		or dimensions.x < 1 or dimensions.y < 1 or dimensions.x*dimensions.y > MAX_PIECES: return false
	if image_source.get("projection","flat")=="sphere" and not Sphere.valid_grid(dimensions): return false
	clear()
	source = image_source.duplicate(); grid = dimensions; seed_value = seed_id
	spherical=source.get("projection","flat")=="sphere"
	var aspect: float = source.size.x/source.size.y
	board_size = Vector2(1.2,minf(1.2/aspect,1.1))
	board_size.x = board_size.y*aspect
	return true

func _options() -> Dictionary:
	return {"seed":seed_value,"depth":source.get("depth"),"depth_rect":source.get("depth_rect",Vector4(0,0,1,1)),"relief":source.get("relief",0.0)}

func _add_piece(geometry: Dictionary, cell: Vector2i) -> void:
	var piece := Piece.new(); piece.configure(cell.y*grid.x+cell.x,geometry,source); add_child(piece)
	piece.goal.origin = Vector3(((cell.x+0.5)/grid.x-0.5)*board_size.x,(0.5-(cell.y+0.5)/grid.y)*board_size.y,0)
	if spherical: piece.goal=geometry.goal
	piece.base_goal=piece.goal
	pieces.append(piece)

func _process(_delta: float) -> void:
	if not preparing: return
	if pending_geometry.is_empty():
		var result := builder.poll()
		if result.is_empty(): return
		if result.has("error"):
			prepare_error=str(result.error); preparing=false; prepared.emit(); return
		pending_geometry=result.pieces
	if not pending_geometry.is_empty():
		var began := Time.get_ticks_usec()
		var i := pieces.size()
		_add_piece(Geometry.materialize(pending_geometry.pop_front()),Vector2i(i%grid.x,i/grid.x))
		max_commit_ms=maxf(max_commit_ms,float(Time.get_ticks_usec()-began)/1000.0)
		if pending_geometry.is_empty(): _finish_preparing()

func _finish_preparing() -> void:
	hint = MeshInstance3D.new()
	var material := StandardMaterial3D.new(); material.shading_mode=BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency=BaseMaterial3D.TRANSPARENCY_ALPHA; material.albedo_color=Color(0.35,0.95,0.72,0.32)
	material.no_depth_test=false; hint.material_override=material; hint.visible=false; add_child(hint)
	if spherical:
		sky=SkyEnvironment.new(); add_child(sky); sky.configure(source,grid,seed_value)
	else:
		board=MeshInstance3D.new(); var quad := QuadMesh.new(); quad.size=frame_size()
		board.mesh=quad; board.position.z=-0.022
		var board_material := ShaderMaterial.new(); board_material.shader=preload("res://shaders/photo_placeholder.gdshader")
		board_material.set_shader_parameter("surface_size",quad.size)
		board_material.set_shader_parameter("flow_time",0.0)
		board.material_override=board_material; add_child(board)
	scatter(false)
	preparing=false; visible=true; prepared.emit()

func clear() -> void:
	if turn_tween!=null and turn_tween.is_valid(): turn_tween.kill()
	builder.shutdown(); preparing=false; pending_geometry.clear(); prepare_error=""; max_commit_ms=0.0
	captures.clear()
	for child in get_children():
		remove_child(child); child.queue_free()
	pieces.clear(); hint=null; source={}; paused=false; spherical=false; sky=null; board=null; view_face=0; backdrop="night"; turning=false
	frame_pose=Transform3D.IDENTITY; frame_reference=null; frame_handles=null; frame_corner=-1; random_rotation=false; frame_adjusted=false; tray_seed=0

func _exit_tree() -> void: builder.shutdown()

func scatter(is_standing: bool) -> void:
	cancel_all(); standing=is_standing
	var rng := RandomNumberGenerator.new(); rng.seed=tray_seed if tray_seed>0 else seed_value
	var order := []
	for i in pieces.size():
		if not pieces[i].placed: order.append(i)
	var capacity := tray_capacity()
	tray_page=mini(tray_page,maxi(0,ceili(float(order.size())/maxi(1,capacity))-1))
	for i in range(order.size()-1,0,-1):
		var j := rng.randi_range(0,i); var swap: int=order[i]; order[i]=order[j]; order[j]=swap
	var side_scale := 0.36 if standing else 0.32
	for slot in order.size():
		var piece: MeshInstance3D=pieces[order[slot]]
		piece.stop_motion()
		piece.tray_visible=slot/capacity==tray_page
		var local_slot := slot%capacity
		var position_value := Vector3.ZERO
		var basis_value := Basis.IDENTITY
		if spherical:
			var extent: Vector3=piece.mesh.get_aabb().size
			var scale_value := clampf(0.23/maxf(extent.x,extent.y),0.05,0.4)
			position_value=Vector3((local_slot%4-1.5)*0.30,-0.24-(local_slot/4)*0.27,-1.10)
			basis_value=Basis.IDENTITY.scaled(Vector3.ONE*scale_value)
			if standing:
				var angle := (float(local_slot)/mini(order.size(),capacity)-0.5)*TAU*0.85
				position_value=Vector3(sin(angle)*1.10,-0.20-float(local_slot%3)*0.14,-cos(angle)*1.10)
				basis_value=Sphere.frame(position_value.normalized()).scaled(Vector3.ONE*scale_value)
		if not spherical:
			var shown := mini(capacity,order.size()-(slot/capacity)*capacity)
			var side_pose := _flat_slot_pose(local_slot,shown,Vector2.ONE,side_scale)
			var extent: Vector3=piece.mesh.get_aabb().size
			side_pose.basis=side_pose.basis.orthonormalized().scaled(Vector3.ONE*clampf(side_scale/maxf(extent.x,extent.y),0.1,6.0))
			position_value=side_pose.origin; basis_value=side_pose.basis
		if not random_rotation: piece.turn_angle=0.0
		elif not piece.rotation_initialized:
			piece.turn_angle=wrapf(float((seed_value+int(piece.piece_id)*31)%4)*PI*0.5,-PI,PI)
			piece.rotation_initialized=true
		basis_value=basis_value*Basis(Vector3.BACK,piece.turn_angle)
		piece.transform=Transform3D(basis_value,position_value); piece.parked=piece.transform; piece.parked_turn=piece.turn_angle
	_sync_visibility()
	changed.emit()

func _flat_slot_pose(slot: int, shown: int, extent: Vector2, scale_value: float) -> Transform3D:
	var forward := frame_pose.origin-viewer_position; forward.y=0
	if forward.length_squared()<0.01: forward=Vector3.FORWARD
	var axes := Basis.looking_at(forward.normalized(),Vector3.UP)
	var eye_frame := Transform3D(axes,viewer_position)
	var inverse := eye_frame.affine_inverse(); var half := frame_size()*0.5
	var edge := 0.0
	for x in [-1,1]:
		for y in [-1,1]:
			var corner := inverse*(frame_pose*Vector3(half.x*x,half.y*y,0))
			edge=maxf(edge,atan2(absf(corner.x),-corner.z))
	edge=minf(edge,deg_to_rad(86))
	var distance := viewer_position.distance_to(frame_pose.origin)
	var radius := clampf(distance*0.65,1.1,1.3) if standing else clampf(distance,1.2,1.5)
	var rows := (2 if pieces.size()<=24 else (3 if pieces.size()<=48 else 4)) if standing else (3 if pieces.size()<=24 else 4)
	var columns := maxi(1,ceili(float(shown)/(rows*2)))
	var half_angle := atan(extent.x*scale_value*0.5/radius)
	var start := edge+half_angle+0.065
	if standing:
		var available := maxi(1,floori((PI-half_angle-0.03-start)/(half_angle*2+0.025))+1)
		columns=mini(columns,available); rows=maxi(rows,ceili(float(shown)/(columns*2)))
		columns=maxi(1,ceili(float(shown)/(rows*2)))
	var end := maxf(deg_to_rad(100),start+(columns-1)*(half_angle*2+0.025))
	var pitch := (end-start)/maxi(1,columns-1) if standing else half_angle*2+0.045
	var side := -1.0 if slot%2==0 else 1.0
	var rank := slot/2; var column := rank/rows; var row := rank%rows
	var height := ((rows-1)*0.5-row)*(extent.y*scale_value+0.08)-0.08
	# Same viewer-relative ring as the photo's Side previews layout. Its start
	# angle comes from the actual resized frame edge, keeping the image clear.
	var pose := eye_frame*Gallery._ring_pose((start+column*pitch)*side,radius,height)
	pose.basis=pose.basis.scaled(Vector3.ONE*scale_value)
	return pose

func _sync_visibility() -> void:
	for piece in pieces: piece.visible=piece.placed or (piece.tray_visible and not paused)

func _refill_slot(outgoing: MeshInstance3D) -> void:
	var incoming: MeshInstance3D
	for piece in pieces:
		if not piece.placed and not piece.tray_visible and not captures.values().any(func(c):return c.id==piece.piece_id): incoming=piece; break
	if incoming==null: return
	var axes: Basis=outgoing.parked.basis.orthonormalized()*Basis(Vector3.BACK,-outgoing.parked_turn)
	incoming.parked=Transform3D((axes*Basis(Vector3.BACK,incoming.turn_angle)).scaled(incoming.parked.basis.get_scale()),outgoing.parked.origin)
	incoming.parked_turn=incoming.turn_angle; incoming.tray_visible=true; incoming.return_to_tray(false)
	_sync_visibility()

func set_view_face(face: int, animate: bool = true) -> void:
	if not spherical or face<0 or face>=6: return
	cancel_all(); view_face=face
	if turn_tween!=null and turn_tween.is_valid(): turn_tween.kill()
	if not animate: _apply_view(); _dim(1.0); turning=false; return
	turning=true; turn_tween=create_tween()
	turn_tween.tween_method(_dim,1.0,0.0,0.10)
	turn_tween.tween_callback(_apply_view)
	turn_tween.tween_method(_dim,0.0,1.0,0.12)
	turn_tween.tween_callback(func(): turning=false)
	changed.emit()

func _apply_view() -> void:
	var rotation := Sphere.view_basis(view_face)
	for piece in pieces:
		piece.stop_motion(); piece.goal=Transform3D(rotation*piece.base_goal.basis,rotation*piece.base_goal.origin)
		if piece.placed: piece.transform=piece.goal
	sky.set_view(rotation); _update_hint()

func _dim(value: float) -> void:
	for piece in pieces:
		if piece.placed: piece.material_override.set_shader_parameter("turn_light",value)
	if sky: sky.dim(value)

func cycle_backdrop() -> void:
	if not spherical: return
	backdrop=SkyEnvironment.BACKDROPS[(SkyEnvironment.BACKDROPS.find(backdrop)+1)%SkyEnvironment.BACKDROPS.size()]
	sky.set_backdrop(backdrop); changed.emit()

func set_posture(value: bool) -> void:
	tray_page=0; standing=value
	if spherical and standing: set_view_face(0,false)
	if not spherical and not frame_adjusted:
		var pose := frame_pose; pose.basis=pose.basis.orthonormalized().scaled(Vector3.ONE*(1.35 if value else 1.0))
		set_frame_pose(pose,false)
	scatter(value)

func next_tray() -> void:
	var capacity := maxi(1,tray_capacity())
	tray_page=(tray_page+1)%maxi(1,ceili(float(pieces.size()-completed())/capacity))
	scatter(standing)

func snapshot() -> Dictionary:
	var states := []
	for piece in pieces:
		var held: bool=captures.values().any(func(c):return c.id==piece.piece_id)
		var pose: Transform3D=piece.goal if piece.placed else (piece.parked if held or piece.returning else piece.transform)
		if held: pose.basis=piece.parked.basis*Basis(Vector3.BACK,piece.turn_angle-piece.parked_turn)
		states.append({"id":piece.piece_id,"placed":piece.placed,"shown":piece.tray_visible,"turn":piece.turn_angle,"parked":encode_pose(piece.parked),"parked_turn":piece.parked_turn,"pose":[
			pose.basis.x.x,pose.basis.x.y,pose.basis.x.z,pose.basis.y.x,pose.basis.y.y,pose.basis.y.z,
			pose.basis.z.x,pose.basis.z.y,pose.basis.z.z,pose.origin.x,pose.origin.y,pose.origin.z]})
	return {"grid":[grid.x,grid.y],"seed":seed_value,"standing":standing,"page":tray_page,"tray_seed":tray_seed,"pieces":states,"frame_pose":encode_pose(frame_pose),"frame_adjusted":frame_adjusted,"random_rotation":random_rotation,
		"projection":"sphere" if spherical else "flat","view_face":view_face,"backdrop":backdrop}

static func valid_snapshot(data: Dictionary) -> bool:
	var tray: Variant=data.get("tray_seed",0)
	if not (tray is int or tray is float) or not is_finite(float(tray)) or tray!=int(tray) or tray<0 or tray>2147483647: return false
	if data.has("frame_adjusted") and not data.frame_adjusted is bool: return false
	if data.has("random_rotation") and not data.random_rotation is bool: return false
	if data.get("projection","flat") not in ["flat","sphere"] or data.get("backdrop","night") not in SkyEnvironment.BACKDROPS: return false
	var face: Variant=data.get("view_face",0)
	if not (face is int or face is float) or not is_finite(float(face)) or face!=int(face) or face<0 or face>=6: return false
	if not data.get("grid") is Array or data.grid.size()!=2: return false
	for n in data.grid:
		if not (n is int or n is float) or not is_finite(float(n)) or n!=int(n) or n<1 or n>MAX_PIECES: return false
	var count := int(data.grid[0])*int(data.grid[1])
	if data.get("projection","flat")=="sphere" and not Sphere.valid_grid(Vector2i(data.grid[0],data.grid[1])): return false
	if count>MAX_PIECES or not data.get("pieces") is Array or data.pieces.size()!=count or not data.get("standing") is bool: return false
	if not (data.get("seed") is int or data.get("seed") is float) or not is_finite(float(data.seed)) or absf(data.seed)>2147483647 or data.seed!=int(data.seed): return false
	var last_page := ceili(float(count)/(16 if data.standing else 12))-1
	if not (data.get("page") is int or data.get("page") is float) or not is_finite(float(data.page)) or data.page!=int(data.page) or data.page<0 or data.page>last_page: return false
	if data.has("frame_pose"):
		var values: Variant=data.frame_pose
		if not values is Array or values.size()!=12: return false
		for n in values:
			if not (n is int or n is float) or not is_finite(float(n)) or absf(n)>20: return false
		var frame := decode_pose(values); var scale_value := frame.basis.get_scale()
		if frame.origin.length()>12 or scale_value.x<FRAME_SCALE_LIMITS.x-0.0001 or scale_value.x>FRAME_SCALE_LIMITS.y+0.0001 or scale_value.distance_to(Vector3.ONE*scale_value.x)>0.001: return false
		if not frame.basis.orthonormalized().scaled(scale_value).is_equal_approx(frame.basis): return false
		if data.get("projection","flat")=="sphere" and not frame.is_equal_approx(Transform3D.IDENTITY): return false
	var ids := {}
	for p in data.pieces:
		if not p is Dictionary or not (p.get("id") is int or p.get("id") is float): return false
		var turn: Variant=p.get("turn",0.0)
		if not (turn is float or turn is int) or not is_finite(float(turn)) or absf(turn)>PI+0.0001: return false
		if p.id!=int(p.id) or p.id<0 or p.id>=count or ids.has(int(p.id)): return false
		ids[int(p.id)]=true
		if not p.get("placed") is bool or not p.get("shown") is bool or not p.get("pose") is Array or p.pose.size()!=12: return false
		for n in p.pose:
			if not (n is float or n is int) or not is_finite(float(n)) or absf(n)>20: return false
		var pose := decode_pose(p.pose)
		if p.has("parked"):
			if not p.parked is Array or p.parked.size()!=12: return false
			for n in p.parked:
				if not (n is int or n is float) or not is_finite(float(n)) or absf(n)>20: return false
			var parking := decode_pose(p.parked); var parking_scale := parking.basis.get_scale()
			if parking.basis.determinant()<=0 or parking_scale.x<0.0499 or parking_scale.y<0.0499 or parking_scale.z<0.0499 or parking_scale.x>6.001 or parking_scale.y>6.001 or parking_scale.z>6.001: return false
		var parked_turn: Variant=p.get("parked_turn",p.get("turn",0.0))
		if not (parked_turn is float or parked_turn is int) or not is_finite(float(parked_turn)) or absf(parked_turn)>PI+0.0001: return false
		var scale_value := pose.basis.get_scale().abs()
		var minimum := 0.0499 if data.get("projection","flat")=="sphere" else 0.0999
		var maximum := 2.0 if data.get("projection","flat")=="sphere" else FRAME_SCALE_LIMITS.y+0.0001
		if scale_value.x<minimum or scale_value.y<minimum or scale_value.z<minimum or scale_value.x>maximum or scale_value.y>maximum or scale_value.z>maximum or pose.basis.determinant()<minimum*minimum*minimum*0.5: return false
	return true

static func encode_pose(pose: Transform3D) -> Array:
	return [pose.basis.x.x,pose.basis.x.y,pose.basis.x.z,pose.basis.y.x,pose.basis.y.y,pose.basis.y.z,pose.basis.z.x,pose.basis.z.y,pose.basis.z.z,pose.origin.x,pose.origin.y,pose.origin.z]

static func decode_pose(a: Array) -> Transform3D:
	return Transform3D(Basis(Vector3(a[0],a[1],a[2]),Vector3(a[3],a[4],a[5]),Vector3(a[6],a[7],a[8])),Vector3(a[9],a[10],a[11]))

func restore(data: Dictionary) -> bool:
	if not valid_snapshot(data) or grid!=Vector2i(data.grid[0],data.grid[1]) or seed_value!=int(data.seed) or preparing \
		or data.get("projection","flat")!=("sphere" if spherical else "flat"): return false
	cancel_all(); standing=data.standing; tray_page=int(data.page); tray_seed=int(data.get("tray_seed",0)); random_rotation=bool(data.get("random_rotation",false))
	if not spherical:
		frame_pose=decode_pose(data.frame_pose) if data.has("frame_pose") else Transform3D.IDENTITY; _sync_frame()
		frame_adjusted=bool(data.get("frame_adjusted",true))
	if spherical:
		set_view_face(int(data.get("view_face",0)),false); backdrop=str(data.get("backdrop","night")); sky.set_backdrop(backdrop)
	scatter(standing)
	for state in data.pieces:
		var piece: MeshInstance3D=pieces[int(state.id)]
		piece.stop_motion(); piece.placed=state.placed; piece.tray_visible=state.shown
		piece.turn_angle=0.0 if piece.placed else float(state.get("turn",0.0))
		piece.rotation_initialized=true
		if state.has("parked"):
			piece.parked=decode_pose(state.parked); piece.parked_turn=float(state.get("parked_turn",state.get("turn",0.0)))
		piece.transform=piece.goal if piece.placed else decode_pose(state.pose)
		if not piece.placed and not state.has("parked"): piece.return_to_tray(false)
	if not pieces.any(func(p):return not p.placed and p.tray_visible):
		var remaining := tray_capacity()
		for piece in pieces:
			if piece.placed or remaining==0: continue
			piece.tray_visible=true; remaining-=1
	_sync_visibility()
	changed.emit(); return true

func pick(origin: Vector3, direction: Vector3) -> Dictionary:
	var best := {}
	if paused or preparing or turning: return best
	for piece in pieces:
		if not piece.visible: continue
		if captures.values().any(func(c):return c.id==piece.piece_id): continue
		var hit: Dictionary=piece.ray_hit(origin,direction)
		if not hit.is_empty() and (best.is_empty() or hit.distance < best.distance): best=hit
	return best

func grab(hand: String, origin: Vector3, direction: Vector3, pose: Transform3D = Transform3D.IDENTITY, align_to_board: bool = false, optical: bool = false, near_hand: bool = false) -> bool:
	if paused or captures.has(hand) or not pose.is_finite(): return false
	var hit := pick(origin,direction)
	if hit.is_empty(): return false
	var piece: MeshInstance3D=hit.piece
	piece.stop_motion()
	if optical and random_rotation: piece.turn_angle=wrapf(roundf(piece.turn_angle/(PI*0.5))*PI*0.5,-PI,PI)
	var anchor: Vector3=piece.global_transform.affine_inverse()*hit.point
	if not spherical and (piece.content_kind=="stereo" or align_to_board):
		piece.global_basis=((global_basis*frame_pose.basis).orthonormalized()*Basis(Vector3.BACK,piece.turn_angle)).scaled(piece.basis.get_scale())
		piece.global_position=hit.point-piece.global_basis*anchor
	captures[hand]={"id":piece.piece_id,"distance":float(hit.distance),"anchor":anchor,
		"basis":piece.global_basis,"hand_basis":pose.basis.orthonormalized(),"last_hand_basis":pose.basis.orthonormalized(),"sound_turn":piece.turn_angle,"candidate":false,
		"optical":optical,"twist":0.0,"turn_ready":true,"roll_sign":-1.0 if pose.basis.z.dot(-direction)<0 else 1.0}
	captures[hand]["near_hand"]=near_hand and not spherical
	if spherical:
		captures[hand]["source_direction"]=(piece.goal*anchor).normalized(); captures[hand]["valid_pose"]=false
	elif near_hand: update_grab(hand,origin,direction,pose)
	return true

func update_grab(hand: String, origin: Vector3, direction: Vector3, pose: Transform3D = Transform3D.IDENTITY) -> void:
	if paused or not captures.has(hand): return
	if not origin.is_finite() or not direction.is_finite() or not pose.is_finite() or direction.length_squared() < 0.1:
		cancel(hand); return
	var capture: Dictionary=captures[hand]
	var piece: MeshInstance3D=pieces[int(capture.id)]
	var before := piece.transform
	if random_rotation and capture.optical:
		var current := pose.basis.orthonormalized(); var previous: Basis=capture.last_hand_basis
		var transport := Basis(Quaternion(previous.z,current.z))
		var delta := (transport*previous.y).signed_angle_to(current.y,current.z)
		capture.twist+=delta*float(capture.roll_sign)
		if not capture.turn_ready and absf(float(capture.twist))<deg_to_rad(8): capture.turn_ready=true
		elif capture.turn_ready and absf(float(capture.twist))>=deg_to_rad(20):
			rotate_held(hand,int(signf(float(capture.twist)))); capture.turn_ready=false
		capture.last_hand_basis=current
	if spherical:
		var point: Variant=Sphere.ray_surface(to_local(origin),global_basis.inverse()*direction)
		if point==null:
			capture.candidate=false; capture.valid_pose=false; _update_hint(); return
		capture.valid_pose=true
		var normal := (point as Vector3).normalized()
		var source_frame := Sphere.frame(capture.source_direction)
		if not capture.has("surface_frame"): capture.surface_frame=Sphere.frame(normal); capture.surface_normal=normal
		else:
			capture.surface_frame=Basis(Quaternion(capture.surface_normal,normal))*Basis(capture.surface_frame)
			capture.surface_normal=normal
		# Parallel transport prevents extra roll while aiming. Near the answer,
		# the magnetic preview gently matches the slot's own frame, including poles.
		var weight := 1.0-smoothstep(deg_to_rad(4),deg_to_rad(16),normal.angle_to(capture.source_direction))
		var surface: Basis=Basis(capture.surface_frame).slerp(Sphere.frame(normal),weight)
		var rotation := surface*source_frame.inverse()
		if random_rotation: rotation=Basis((point as Vector3).normalized(),-piece.turn_angle)*rotation
		piece.transform=Transform3D(rotation*piece.goal.basis,rotation*piece.goal.origin)
		capture.candidate=can_snap(piece,1.25 if capture.candidate else 1.0); _update_hint()
		if not piece.transform.is_equal_approx(before): changed.emit()
		return
	var basis_value: Basis=capture.basis
	if piece.content_kind != "stereo": basis_value=pose.basis.orthonormalized()*capture.hand_basis.inverse()*basis_value
	# A distant board is a placement surface. The player points at it rather
	# than having to push a fragment from its original grab distance to the board.
	var local_origin := frame_pose.affine_inverse()*to_local(origin)
	var local_ray := frame_pose.basis.inverse()*global_basis.inverse()*direction.normalized()
	if capture.get("near_hand",false):
		# Near-hand inspection ends at the frame: move this same entity onto it.
		var was_candidate: bool=capture.candidate
		capture.erase("delivery"); capture.candidate=false
		if local_origin.z>0 and local_ray.z< -0.0001:
			var point := local_origin+local_ray*((float(capture.anchor.z)-local_origin.z)/local_ray.z)
			if absf(point.x)<=board_size.x*0.5+0.10 and absf(point.y)<=board_size.y*0.5+0.10:
				var rotation := frame_pose.basis*Basis(Vector3.BACK,piece.turn_angle if random_rotation else 0.0)
				var delivery := Transform3D(rotation,frame_pose*point-rotation*capture.anchor)
				capture.delivery=delivery
				capture.candidate=_can_snap_pose(piece,delivery,1.25 if was_candidate else 1.0)
				piece.transform=piece.goal if capture.candidate else delivery
				_update_hint()
				if not piece.transform.is_equal_approx(before): changed.emit()
				return
		var extent: Vector3=piece.mesh.get_aabb().size
		var scale_value := clampf(0.20/maxf(extent.x,extent.y),0.1,6.0)
		var ray := direction.normalized()
		piece.global_basis=(Basis.looking_at(ray,Vector3.UP if absf(ray.y)<0.98 else Vector3.RIGHT)*Basis(Vector3.BACK,piece.turn_angle if random_rotation else 0.0)).scaled(Vector3.ONE*scale_value)
		piece.global_position=origin+ray*HELD_DISTANCE-piece.global_basis*capture.anchor
		_update_hint()
		if not piece.transform.is_equal_approx(before): changed.emit()
		return
	if local_origin.z>0 and local_ray.z< -0.0001:
		var point := local_origin+local_ray*((float(capture.anchor.z)-local_origin.z)/local_ray.z)
		if absf(point.x)<=board_size.x*0.5+0.10 and absf(point.y)<=board_size.y*0.5+0.10:
			piece.global_basis=global_basis*frame_pose.basis*Basis(Vector3.BACK,piece.turn_angle if random_rotation else 0.0)
			piece.global_position=to_global(frame_pose*point)-piece.global_basis*capture.anchor
			capture.candidate=can_snap(piece,1.25 if capture.candidate else 1.0); _update_hint()
			if not piece.transform.is_equal_approx(before): changed.emit()
			return
	piece.global_basis=basis_value
	piece.global_position=origin+direction.normalized()*float(capture.distance)-basis_value*capture.anchor
	capture.candidate=can_snap(piece,1.25 if capture.candidate else 1.0)
	_update_hint()
	if not piece.transform.is_equal_approx(before): changed.emit()

func can_snap(piece: MeshInstance3D, multiplier: float = 1.0) -> bool:
	return _can_snap_pose(piece,piece.transform,multiplier)

func _can_snap_pose(piece: MeshInstance3D, pose: Transform3D, multiplier: float) -> bool:
	if piece.placed or turning or not pose.is_finite(): return false
	var tolerance := (clampf(piece.width*0.13,0.08,0.18) if spherical else clampf(piece.width*0.15,0.02,0.05))*multiplier
	if not spherical: tolerance*=frame_scale()
	if spherical and (pose.basis.get_scale().distance_to(Vector3.ONE)>0.06 or pose.origin.normalized().angle_to(piece.goal.origin.normalized())>deg_to_rad(4)*multiplier): return false
	var rotation := pose.basis.orthonormalized().get_rotation_quaternion().angle_to(piece.goal.basis.get_rotation_quaternion())
	return pose.origin.distance_to(piece.goal.origin) <= tolerance and rotation <= deg_to_rad(15 if spherical else 12)*multiplier

func release(hand: String) -> bool:
	if not captures.has(hand): return false
	var capture: Dictionary=captures[hand]
	var piece: MeshInstance3D=pieces[int(capture.id)]
	captures.erase(hand); _update_hint()
	var valid := _can_snap_pose(piece,capture.delivery,1.25 if capture.candidate else 1.0) if capture.get("near_hand",false) and capture.has("delivery") else (false if capture.get("near_hand",false) else can_snap(piece))
	if paused or not capture.get("valid_pose",true) or not valid:
		piece.return_to_tray(); changed.emit(); return false
	piece.settle(); _refill_slot(piece); piece_placed.emit(piece.piece_id,hand); changed.emit(); return true

func cancel(hand: String) -> void:
	if not captures.has(hand): return
	var piece: MeshInstance3D=pieces[int(captures[hand].id)]
	captures.erase(hand); piece.return_to_tray(); _update_hint()
	changed.emit()

func cancel_all() -> void:
	for hand in captures.keys(): cancel(str(hand))

func set_paused(value: bool) -> void:
	if value: cancel_all()
	paused=value
	_sync_visibility()

func completed() -> int:
	var count := 0
	for piece in pieces:
		if piece.placed: count+=1
	return count

func _update_hint() -> void:
	if hint==null: return
	hint.visible=false
	for capture in captures.values():
		if not capture.candidate: continue
		var piece: MeshInstance3D=pieces[int(capture.id)]
		hint.mesh=piece.mesh; hint.transform=piece.goal
		if not spherical: hint.position+=frame_pose.basis.z.normalized()*0.002
		hint.visible=true; return

func held_pointer(hand: String) -> Variant:
	if not captures.has(hand): return null
	var capture: Dictionary=captures[hand]
	if capture.get("near_hand",false):
		return to_global(capture.delivery*capture.anchor) if capture.has("delivery") else null
	return pieces[int(capture.id)].to_global(capture.anchor)
