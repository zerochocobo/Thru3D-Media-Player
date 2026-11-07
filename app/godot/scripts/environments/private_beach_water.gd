extends RefCounted
## Shared with the desktop study so both draw the same coast-following water.
static func mesh(config: Dictionary) -> ArrayMesh:
	# One connected strip follows the exact coastline, with dense rows at the
	# swash and coarse rows offshore. No rectangular side-plane intersections.
	var coast: Array=config.shore.points
	var columns: Array[Vector2]=[]
	for x in [-2000.0,-1000.0,-700.0,-500.0]: columns.append(Vector2(x,coast[0][1]))
	for segment in range(coast.size()-1):
		var a:=Vector2(coast[segment][0],coast[segment][1])
		var b:=Vector2(coast[segment+1][0],coast[segment+1][1])
		var count:=maxi(1,ceili(a.distance_to(b)/2.0))
		for i in range(count): columns.append(a.lerp(b,float(i)/count))
	columns.append(Vector2(coast[-1][0],coast[-1][1]))
	for x in [500.0,700.0,1000.0,2000.0]: columns.append(Vector2(x,coast[-1][1]))
	var offsets: Array[float]=[-2200,-1200,-500,-200,-80,-40,-20,-10,-5,-2,0,1,2,3]
	var vertices:=PackedVector3Array(); var normals:=PackedVector3Array(); var indices:=PackedInt32Array()
	for inland in offsets:
		for column in columns:
			var y:=float(config.shore.sea_level)+maxf(inland,0.0)*float(config.terrain.land_slope)
			vertices.append(Vector3(column.x,y,column.y+inland)); normals.append(Vector3.UP)
	var width:=columns.size()
	for row in range(offsets.size()-1):
		for col in range(width-1):
			var a:=row*width+col
			indices.append_array(PackedInt32Array([a,a+1,a+width,a+1,a+width+1,a+width]))
	var arrays: Array=[]; arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX]=vertices; arrays[Mesh.ARRAY_NORMAL]=normals; arrays[Mesh.ARRAY_INDEX]=indices
	var result:=ArrayMesh.new(); result.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,arrays)
	return result
