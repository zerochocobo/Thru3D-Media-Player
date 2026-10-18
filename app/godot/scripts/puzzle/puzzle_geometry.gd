extends RefCounted
## Immutable, closed solids. All pieces sample one image/depth coordinate system.
const EDGE_SAMPLES := 32

static func joint_profile() -> PackedVector2Array:
	# Round head and narrow neck, with real re-entrant shoulders on both sides.
	var profile := PackedVector2Array([Vector2.ZERO,Vector2(0.32,0)])
	var curves := [
		[Vector2(0.43,0),Vector2(0.43,0.065),Vector2(0.41,0.10)],
		[Vector2(0.35,0.12),Vector2(0.35,0.22),Vector2(0.42,0.25)],
		[Vector2(0.46,0.29),Vector2(0.54,0.29),Vector2(0.58,0.25)],
		[Vector2(0.65,0.22),Vector2(0.65,0.12),Vector2(0.59,0.10)],
		[Vector2(0.57,0.065),Vector2(0.57,0),Vector2(0.68,0)]]
	for curve in curves:
		var start := profile[profile.size()-1]
		for step in range(1,7):
			var t := float(step)/6; var u := 1-t
			profile.append(start*u*u*u+curve[0]*3*u*u*t+curve[1]*3*u*t*t+curve[2]*t*t*t)
	profile.append(Vector2(1,0))
	for i in profile.size(): profile[i].y*=0.65
	return profile

static func outline(cell: Vector2i, grid: Vector2i, seed_value: int = 1) -> PackedVector2Array:
	var points := PackedVector2Array()
	var profile := joint_profile()
	for side in 4:
		for i in EDGE_SAMPLES:
			var p := profile[i] if side<2 else profile[EDGE_SAMPLES-i]
			match side:
				0: points.append(_horizontal(cell.y,cell.x,p,grid,seed_value,float(i)/EDGE_SAMPLES))
				1: points.append(_vertical(cell.y,cell.x+1,p,grid,seed_value,float(i)/EDGE_SAMPLES))
				2: points.append(_horizontal(cell.y+1,cell.x,p,grid,seed_value,1.0-float(i)/EDGE_SAMPLES))
				3: points.append(_vertical(cell.y,cell.x,p,grid,seed_value,1.0-float(i)/EDGE_SAMPLES))
	return points

static func _sign_for(a: int, b: int, seed_value: int) -> float:
	return 1.0 if ((a * 73856093) ^ (b * 19349663) ^ seed_value) & 1 else -1.0

static func _horizontal(row: int, column: int, p: Vector2, grid: Vector2i, seed_value: int, border_t: float) -> Vector2:
	if row==0 or row==grid.y: p=Vector2(border_t,0)
	return Vector2((column+p.x)/grid.x,(row+p.y*_sign_for(row,column,seed_value))/grid.y)

static func _vertical(row: int, column: int, p: Vector2, grid: Vector2i, seed_value: int, border_t: float) -> Vector2:
	if column==0 or column==grid.x: p=Vector2(border_t,0)
	return Vector2((column+p.y*_sign_for(column,row,seed_value+11))/grid.x,(row+p.x)/grid.y)

static func sample_depth(image: Image, uv: Vector2, rect: Vector4 = Vector4(0, 0, 1, 1)) -> float:
	if image == null or image.is_empty(): return 0.0
	var p := Vector2(rect.x, rect.y) + uv.clamp(Vector2.ZERO, Vector2.ONE) * Vector2(rect.z, rect.w)
	var x := clampf(p.x * (image.get_width() - 1), 0, image.get_width() - 1)
	var y := clampf(p.y * (image.get_height() - 1), 0, image.get_height() - 1)
	var x0 := int(x); var y0 := int(y)
	var x1 := mini(x0 + 1, image.get_width() - 1); var y1 := mini(y0 + 1, image.get_height() - 1)
	var value := lerpf(lerpf(image.get_pixel(x0, y0).r, image.get_pixel(x1, y0).r, x - x0),
		lerpf(image.get_pixel(x0, y1).r, image.get_pixel(x1, y1).r, x - x0), y - y0)
	return clampf(value, 0.0, 1.0) if is_finite(value) else 0.0

static func flat(cell: Vector2i, grid: Vector2i, size: Vector2, options: Dictionary = {}) -> Dictionary:
	if grid.x < 1 or grid.y < 1 or cell.x < 0 or cell.y < 0 or cell.x >= grid.x or cell.y >= grid.y \
		or not size.is_finite() or size.x <= 0 or size.y <= 0: return {}
	var contour := outline(cell, grid, int(options.get("seed", 1)))
	var triangles := Geometry2D.triangulate_polygon(contour)
	if triangles.is_empty(): return {}
	var centre := Vector2((cell.x + 0.5) / grid.x, (cell.y + 0.5) / grid.y)
	var thickness := clampf(float(options.get("thickness", 0.012)), 0.004, 0.05)
	var relief := clampf(float(options.get("relief", 0.0)), 0, 0.04)
	var depth: Image = options.get("depth")
	var rect: Vector4 = options.get("depth_rect", Vector4(0, 0, 1, 1))
	var config := {"centre":centre, "size":size, "depth":depth, "rect":rect, "relief":relief}
	var data := _buffers()
	var subdivisions := 2 if relief > 0 and depth != null else 0
	var inset := 0.988
	var bevel_depth := minf(thickness*0.12,0.0015)
	var top_contour := PackedVector2Array()
	for point in contour: top_contour.append(centre+(point-centre)*inset)
	for i in range(0, triangles.size(), 3):
		var a := contour[triangles[i]]; var b := contour[triangles[i + 1]]; var c := contour[triangles[i + 2]]
		_front(data, top_contour[triangles[i]], top_contour[triangles[i+1]], top_contour[triangles[i+2]], config, subdivisions)
		_front(data, a, b, c, config, subdivisions, -thickness)
	for i in contour.size():
		var a := contour[i]; var b := contour[(i + 1) % contour.size()]
		var ai := top_contour[i]; var bi := top_contour[(i+1)%contour.size()]
		# Match the front's refined boundary so the relief remains watertight.
		for j in (1 << subdivisions):
			var u := _edge_sample(a,b,j,subdivisions)
			var v := _edge_sample(a,b,j+1,subdivisions)
			var p := _surface_point(u, config)-Vector3.BACK*bevel_depth
			var q := _surface_point(v, config)-Vector3.BACK*bevel_depth
			var ui := _edge_sample(ai,bi,j,subdivisions); var vi := _edge_sample(ai,bi,j+1,subdivisions)
			var pi := _surface_point(ui,config); var qi := _surface_point(vi,config)
			var pb := _flat_point(u, config, -thickness); var qb := _flat_point(v, config, -thickness)
			var outward := Vector3(v.y - u.y, v.x - u.x, 0).normalized()
			_triangle(data, p, pb, qb, u, u, v, outward, false)
			_triangle(data, p, qb, q, u, v, v, outward, false)
			_triangle(data,pi,p,q,ui,u,v,(outward+Vector3.BACK).normalized(),false)
			_triangle(data,pi,q,qi,ui,v,vi,(outward+Vector3.BACK).normalized(),false)
	var result := {"outline":contour, "centre_uv":centre, "triangles":data.vertices,
		"width":size.x / grid.x, "thickness":thickness, "relief":relief, "arrays":data}
	return result if options.get("arrays_only",false) else materialize(result)

static func materialize(result: Dictionary) -> Dictionary:
	# Only this step talks to the renderer; worker jobs return plain packed arrays.
	var mesh := _mesh(result.arrays)
	result["mesh"]=mesh; result["aabb"]=mesh.get_aabb(); result.erase("arrays")
	return result

static func _flat_point(uv: Vector2, config: Dictionary, z: float) -> Vector3:
	var p: Vector2 = (uv - config.centre) * config.size
	return Vector3(p.x, -p.y, z)

static func _surface_point(uv: Vector2, config: Dictionary) -> Vector3:
	return _flat_point(uv, config, sample_depth(config.depth, uv, config.rect) * float(config.relief))

static func _edge_sample(a: Vector2, b: Vector2, index: int, levels: int) -> Vector2:
	# Match _front's midpoint arithmetic exactly, including under the tab neck.
	if index==0: return a
	if index==(1<<levels): return b
	var mid := (a+b)*0.5; var half := 1<<(levels-1)
	return _edge_sample(a,mid,index,levels-1) if index<=half else _edge_sample(mid,b,index-half,levels-1)

static func _front(data: Dictionary, a: Vector2, b: Vector2, c: Vector2, config: Dictionary, levels: int, floor_depth: float = INF) -> void:
	if levels > 0:
		var ab := (a + b) * 0.5; var bc := (b + c) * 0.5; var ca := (c + a) * 0.5
		_front(data, a, ab, ca, config, levels - 1, floor_depth); _front(data, ab, b, bc, config, levels - 1, floor_depth)
		_front(data, ca, bc, c, config, levels - 1, floor_depth); _front(data, ab, bc, ca, config, levels - 1, floor_depth)
	else:
		if is_finite(floor_depth):
			_triangle(data,_flat_point(a,config,floor_depth),_flat_point(b,config,floor_depth),_flat_point(c,config,floor_depth),a,b,c,Vector3.FORWARD,false)
		else:
			_triangle(data, _surface_point(a, config), _surface_point(b, config), _surface_point(c, config), a, b, c, Vector3.BACK, true)

static func shell(region: Rect2, radius: float = 2.5, thickness: float = 0.025, steps: int = 10) -> Dictionary:
	if radius <= 0 or thickness <= 0 or steps < 2 or not region.has_area(): return {}
	var data := _buffers()
	var anchor := _direction(region.get_center()) * radius
	for y in steps:
		for x in steps:
			var a := _shell_uv(region,x,y,steps)
			var b := _shell_uv(region,x+1,y,steps)
			var c := _shell_uv(region,x+1,y+1,steps)
			var d := _shell_uv(region,x,y+1,steps)
			for back in [false, true]:
				var r := radius + thickness if back else radius
				var normal := _direction((a + c) * 0.5) * (1 if back else -1)
				_triangle(data, _direction(a) * r - anchor, _direction(b) * r - anchor, _direction(c) * r - anchor, a,b,c,normal,not back)
				_triangle(data, _direction(a) * r - anchor, _direction(c) * r - anchor, _direction(d) * r - anchor, a,c,d,normal,not back)
	var contour := PackedVector2Array()
	for side in 4:
		for i in steps:
			var p := Vector2i(i,0) if side == 0 else (Vector2i(steps,i) if side == 1 else (Vector2i(steps-i,steps) if side == 2 else Vector2i(0,steps-i)))
			contour.append(_shell_uv(region,p.x,p.y,steps))
	for i in contour.size():
		var a := contour[i]; var b := contour[(i + 1) % contour.size()]
		var p := _direction(a) * radius - anchor; var q := _direction(b) * radius - anchor
		var pb := _direction(a) * (radius + thickness) - anchor; var qb := _direction(b) * (radius + thickness) - anchor
		var normal := (pb-p).cross(q-p).normalized()
		_triangle(data,p,pb,qb,a,a,b,normal,false); _triangle(data,p,qb,q,a,b,b,normal,false)
	var mesh := _mesh(data)
	return {"mesh":mesh, "triangles":data.vertices, "anchor":anchor, "thickness":thickness, "aabb":mesh.get_aabb()}

static func _direction(uv: Vector2) -> Vector3:
	var longitude := (uv.x - 0.5) * TAU; var latitude := (0.5 - uv.y) * PI
	return Vector3(sin(longitude)*cos(latitude), sin(latitude), -cos(longitude)*cos(latitude))

static func _shell_uv(region: Rect2, x: int, y: int, steps: int) -> Vector2:
	return region.position+region.size*Vector2(float(x)/steps,float(y)/steps)

static func _buffers() -> Dictionary:
	return {"vertices":PackedVector3Array(), "normals":PackedVector3Array(), "uv":PackedVector2Array(), "colors":PackedColorArray()}

static func _triangle(data: Dictionary, a: Vector3, b: Vector3, c: Vector3, au: Vector2, bu: Vector2, cu: Vector2, desired: Vector3, front: bool) -> void:
	var normal := (b-a).cross(c-a).normalized()
	if normal.length_squared() < 0.5: return
	if normal.dot(desired) < 0:
		var point := b; b=c; c=point
		var uv := bu; bu=cu; cu=uv
		normal = -normal
	# Godot uses clockwise front faces. Normals point out of the closed volume.
	data.vertices.append_array(PackedVector3Array([a,c,b]))
	data.normals.append_array(PackedVector3Array([normal,normal,normal]))
	data.uv.append_array(PackedVector2Array([au,cu,bu]))
	var marker := Color(1,1,1,1 if front else 0)
	data.colors.append_array(PackedColorArray([marker,marker,marker]))

static func _mesh(data: Dictionary) -> ArrayMesh:
	var arrays := []; arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX]=data.vertices; arrays[Mesh.ARRAY_NORMAL]=data.normals
	arrays[Mesh.ARRAY_TEX_UV]=data.uv; arrays[Mesh.ARRAY_COLOR]=data.colors
	var mesh := ArrayMesh.new(); mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,arrays)
	return mesh
