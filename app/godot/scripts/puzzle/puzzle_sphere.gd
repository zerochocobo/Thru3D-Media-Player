extends RefCounted
## Six cube faces avoid polar slivers. Source directions are interpolated instead of wrapped UVs.
const Geometry := preload("res://scripts/puzzle/puzzle_geometry.gd")
const RADIUS := 2.5
const THICKNESS := 0.04
const CENTRES := [Vector3.FORWARD,Vector3.RIGHT,Vector3.BACK,Vector3.LEFT,Vector3.UP,Vector3.DOWN]
const RIGHTS := [Vector3.RIGHT,Vector3.BACK,Vector3.LEFT,Vector3.FORWARD,Vector3.RIGHT,Vector3.RIGHT]
const UPS := [Vector3.UP,Vector3.UP,Vector3.UP,Vector3.UP,Vector3.BACK,Vector3.FORWARD]

static func valid_grid(grid: Vector2i) -> bool: return grid.y in [1,2,3] and grid.x==6*grid.y

static func point(face: int, uv: Vector2) -> Vector3:
	return (CENTRES[face]+RIGHTS[face]*(uv.x*2-1)+UPS[face]*(1-uv.y*2)).normalized()

static func frame(direction: Vector3, pole_right: Vector3 = Vector3.RIGHT) -> Basis:
	var inward := -direction.normalized()
	var right := Vector3.UP.cross(inward)
	if right.length_squared()<0.000001: right=pole_right-inward*pole_right.dot(inward)
	if right.length_squared()<0.000001: right=Vector3.BACK.cross(inward)
	right=right.normalized()
	return Basis(right,inward.cross(right).normalized(),inward)

static func view_basis(face: int) -> Basis:
	return [Basis.IDENTITY,Basis(Vector3.UP,PI/2),Basis(Vector3.UP,PI),Basis(Vector3.UP,-PI/2),
		Basis(Vector3.RIGHT,-PI/2),Basis(Vector3.RIGHT,PI/2)][face]

static func joint_profile() -> PackedVector2Array:
	return Geometry.joint_profile()

static func _key(value: Vector3) -> String:
	return "%d,%d,%d" % [roundi(value.x*1000000),roundi(value.y*1000000),roundi(value.z*1000000)]

static func edge(a: Vector3, b: Vector3, seed_value: int = 731) -> PackedVector3Array:
	# Canonical endpoints make one physical joint, even between different cube faces.
	a=a.snapped(Vector3.ONE*0.000001).normalized(); b=b.snapped(Vector3.ONE*0.000001).normalized()
	var reversed := _key(a)>_key(b)
	var start := b if reversed else a; var end := a if reversed else b
	var code := (_key(start)+"/"+_key(end)+":"+str(seed_value)).hash()
	code=((code^(code>>16))*0x45d9f3b)&0xffffffff; code=code^(code>>16)
	var sign_value := 1.0 if code&1 else -1.0
	var normal := start.cross(end).normalized()*start.distance_to(end)*sign_value
	var curve := PackedVector3Array()
	for p in joint_profile(): curve.append((start.lerp(end,p.x)+normal*p.y).normalized())
	if reversed: curve.reverse()
	return curve

static func outline(cell: Vector2i, grid: Vector2i, seed_value: int = 731) -> PackedVector3Array:
	var face := cell.x/grid.y
	var region := Rect2(Vector2(float(cell.x%grid.y)/grid.y,float(cell.y)/grid.y),Vector2.ONE/grid.y)
	var corners := [region.position,region.position+Vector2(region.size.x,0),region.end,region.position+Vector2(0,region.size.y)]
	var contour := PackedVector3Array()
	for side in 4:
		var curve := edge(point(face,corners[side]),point(face,corners[(side+1)%4]),seed_value)
		for i in curve.size()-1: contour.append(curve[i])
	return contour

static func patch(cell: Vector2i, grid: Vector2i, arrays_only: bool = false, seed_value: int = 731) -> Dictionary:
	if not valid_grid(grid) or cell.x<0 or cell.y<0 or cell.x>=grid.x or cell.y>=grid.y: return {}
	var face := cell.x/grid.y
	var region := Rect2(Vector2(float(cell.x%grid.y)/grid.y,float(cell.y)/grid.y),Vector2.ONE/grid.y)
	var direction := point(face,region.get_center())
	var goal := Transform3D(frame(direction),direction*RADIUS)
	var inverse := goal.affine_inverse()
	var data := Geometry._buffers()
	var contour := outline(cell,grid,seed_value)
	var projected := PackedVector2Array()
	for p in contour:
		projected.append(Vector2(p.dot(goal.basis.x),-p.dot(goal.basis.y))/p.dot(direction))
	var indices := Geometry2D.triangulate_polygon(projected)
	if indices.is_empty(): return {}
	var surface_points := contour.duplicate()
	# Interior vertices and constrained edge flips prevent long thin ear triangles
	# from becoming nearly tangent to the curved surface at the tab shoulders.
	for y in 4:
		for x in 4:
			var p := point(face,region.position+region.size*Vector2((x+0.5)/4,(y+0.5)/4))
			var uv := Vector2(p.dot(goal.basis.x),-p.dot(goal.basis.y))/p.dot(direction)
			_insert_point(indices,projected,surface_points,uv,p)
	_improve_triangles(indices,projected)
	for i in range(0,indices.size(),3):
		_surface(data,surface_points[indices[i]],surface_points[indices[i+1]],surface_points[indices[i+2]],inverse,face)
	for i in contour.size():
		var a := contour[i]; var b := contour[(i+1)%contour.size()]
		var mid := (a+b).normalized()
		_wall(data,a,mid,inverse,face); _wall(data,mid,b,inverse,face)
	var result := {"arrays":data,"triangles":data.vertices,"goal":goal,"outline3d":contour,"face":face,
		"thickness":THICKNESS,"width":RADIUS*direction.angle_to(point(face,region.position+Vector2(region.size.x,region.size.y*0.5)))*2}
	return result if arrays_only else Geometry.materialize(result)

static func _insert_point(indices: PackedInt32Array, projected: PackedVector2Array, points: PackedVector3Array, uv: Vector2, p: Vector3) -> void:
	for i in range(0,indices.size(),3):
		var a := indices[i]; var b := indices[i+1]; var c := indices[i+2]
		var sides := Vector3((projected[b]-projected[a]).cross(uv-projected[a]),
			(projected[c]-projected[b]).cross(uv-projected[b]),(projected[a]-projected[c]).cross(uv-projected[c]))
		if not ((sides.x>0.000001 and sides.y>0.000001 and sides.z>0.000001) or (sides.x< -0.000001 and sides.y< -0.000001 and sides.z< -0.000001)): continue
		var n := projected.size(); projected.append(uv); points.append(p)
		indices[i+2]=n; indices.append_array(PackedInt32Array([b,c,n,c,a,n])); return

static func _improve_triangles(indices: PackedInt32Array, points: PackedVector2Array) -> void:
	for _pass in 32:
		var edges := {}; var locked := {}; var flipped := false
		for i in range(0,indices.size(),3):
			for side in 3:
				var a := indices[i+side]; var b := indices[i+(side+1)%3]; var c := indices[i+(side+2)%3]
				var key := Vector2i(mini(a,b),maxi(a,b))
				if not edges.has(key): edges[key]=[i,c]; continue
				var j: int=edges[key][0]; var d: int=edges[key][1]
				if locked.has(i) or locked.has(j): continue
				var pa := points[a]; var pb := points[b]; var pc := points[c]; var pd := points[d]
				var tolerance := (pd-pc).length_squared()*0.000001
				if (pd-pc).cross(pa-pc)*(pd-pc).cross(pb-pc)>=-tolerance*tolerance: continue
				var angle := absf((pa-pc).angle_to(pb-pc))+absf((pa-pd).angle_to(pb-pd))
				if angle<=PI+0.0001: continue
				indices[i]=a; indices[i+1]=c; indices[i+2]=d
				indices[j]=b; indices[j+1]=d; indices[j+2]=c
				locked[i]=true; locked[j]=true; flipped=true
		if not flipped: break

static func _surface(data: Dictionary, a: Vector3, b: Vector3, c: Vector3, inverse: Transform3D, face: int) -> void:
	# Subdivide in shared 3D directions; tangent-plane midpoints would split seams.
	var ab := (a+b).normalized(); var bc := (b+c).normalized(); var ca := (c+a).normalized()
	for triangle in [[a,ab,ca],[ab,b,bc],[ca,bc,c],[ab,bc,ca]]:
		var normal: Vector3=(triangle[0]+triangle[1]+triangle[2]).normalized()
		for back in [false,true]:
			var radius := RADIUS+THICKNESS if back else RADIUS
			_triangle(data,triangle[0]*radius,triangle[1]*radius,triangle[2]*radius,normal*(1 if back else -1),not back,inverse,face)

static func _wall(data: Dictionary, a: Vector3, b: Vector3, inverse: Transform3D, face: int) -> void:
	var p := a*RADIUS; var q := b*RADIUS; var pb := a*(RADIUS+THICKNESS); var qb := b*(RADIUS+THICKNESS)
	var outward := (q-p).cross(pb-p).normalized()
	_triangle(data,p,pb,qb,outward,false,inverse,face); _triangle(data,p,qb,q,outward,false,inverse,face)

static func _triangle(data: Dictionary, a: Vector3, b: Vector3, c: Vector3, normal: Vector3, front: bool, inverse: Transform3D, face: int) -> void:
	Geometry._triangle(data,inverse*a,inverse*b,inverse*c,uv_for(a,face),uv_for(b,face),uv_for(c,face),inverse.basis*normal,front)

static func uv_for(point_value: Vector3, face: int) -> Vector2:
	var distance := point_value.dot(CENTRES[face])
	return Vector2(0.5+point_value.dot(RIGHTS[face])/distance*0.5,0.5-point_value.dot(UPS[face])/distance*0.5)

static func ray_surface(origin: Vector3, direction: Vector3) -> Variant:
	var ray := direction.normalized()
	var b := origin.dot(ray); var discriminant := b*b-(origin.length_squared()-RADIUS*RADIUS)
	if discriminant<0: return null
	var distance := -b+sqrt(discriminant)
	if distance<=0 or origin.length()>RADIUS*0.94: return null
	return origin+ray*distance
