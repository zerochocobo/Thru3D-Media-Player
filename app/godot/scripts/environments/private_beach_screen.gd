extends RefCounted
## Runtime counterpart of tools/beach/beach_layout.py. Metres, scene-local Y up.
## Returns a complete candidate; invalid input never mutates the current scene.

static func solve(config: Dictionary,ground: Callable,changes: Dictionary) -> Dictionary:
	var s: Dictionary = config.screen.duplicate(true)
	for key in changes:
		if key not in ["width","center_x","center_z","yaw_degrees","pitch_degrees"]:
			return {"error":"Unknown screen parameter: "+str(key)}
		if not (changes[key] is float or changes[key] is int) or not is_finite(float(changes[key])):
			return {"error":"Screen parameters must be finite numbers"}
		s[key]=float(changes[key])
	if s.width<3 or s.width>20 or absf(s.pitch_degrees)>s.max_pitch_degrees:
		return {"error":"Study support range: width 3–20 m, pitch ±15°"}
	var yaw := deg_to_rad(float(s.yaw_degrees)); var pitch := deg_to_rad(float(s.pitch_degrees))
	var right := Vector3(cos(yaw),0,-sin(yaw))
	var up := Vector3(sin(yaw)*sin(pitch),cos(pitch),cos(yaw)*sin(pitch))
	var normal := right.cross(up).normalized()
	var w := float(s.width); var h := w/float(s.aspect)
	var center := Vector3(s.center_x,ground.call(s.center_x,s.center_z)+s.bottom_clearance+h/2,s.center_z)
	var corners := PackedVector3Array([center-right*w/2-up*h/2,center+right*w/2-up*h/2,
		center+right*w/2+up*h/2,center-right*w/2+up*h/2])
	var profile := Vector3.ZERO
	var profiles: Array = s.support_profiles
	for i in range(profiles.size()-1):
		var a: Array = profiles[i]; var b: Array = profiles[i+1]
		if w>=a[0] and w<=b[0]:
			var t := smoothstep(float(a[0]),float(b[0]),w)
			profile=Vector3(a[1],a[2],a[3]).lerp(Vector3(b[1],b[2],b[3]),t); break
	var footprint := PackedVector3Array()
	for i in 4:
		var a := corners[i]; var b := corners[(i+1)%4]
		var count := maxi(1,ceili(Vector2(a.x-b.x,a.z-b.z).length()/.25))
		for j in range(count+1): footprint.append(a.lerp(b,float(j)/count))
	var supports: Array = []
	for side in [-1.0,1.0]:
		var anchor: Vector3 = center+right*side*w*.46+up*h*.35-normal*.16
		var feet := PackedVector3Array()
		for rear in [0.0,-profile.y]:
			var foot: Vector3 = center+right*side*w*.46-up*h/2+normal*(-.16+rear)
			foot.y=ground.call(foot.x,foot.z); feet.append(foot)
			for sign_ in [-1.0,1.0]: footprint.append(foot+right*sign_*profile.z/2)
		supports.append({"anchor":anchor,"feet":feet})
	var clearance := INF
	for point in footprint:
		var terrain: Dictionary = config.terrain
		# ground() clamps its sampling domain; reject overhangs instead of clamping supports.
		if point.x<terrain.x_min+.2 or point.x>terrain.x_max-.2 or point.z<terrain.z_min+.2 or point.z>terrain.z_max-.2:
			return {"error":"Screen or support leaves the modeled ground"}
		clearance=minf(clearance,shore_distance(config,point)-.125)
	var bottom := INF
	for point in [corners[0],corners[1]]: bottom=minf(bottom,point.y-ground.call(point.x,point.z))
	if clearance<s.uprush_clearance or bottom<.1:
		return {"error":"Screen or support is too close to water or terrain"}
	return {"parameters":s,"center":center,"corners":corners,"supports":supports,"section":profile.x,
		"foot_width":profile.z,"uprush_clearance":clearance,"minimum_bottom_clearance":bottom,
		"right":right,"up":up,"normal":normal,"half_size":Vector2(w,h)*.5}

static func shore_distance(config: Dictionary,point: Vector3) -> float:
	var closest := INF
	var shore: Dictionary = config.shore
	var points: Array = shore.points
	var p := Vector2(point.x,point.z)
	var shore_z := float(points[0][1] if p.x<points[0][0] else points[-1][1])+float(shore.uprush_offset)
	for i in range(points.size()-1):
		var a := Vector2(points[i][0],points[i][1]+shore.uprush_offset)
		var b := Vector2(points[i+1][0],points[i+1][1]+shore.uprush_offset)
		var segment := b-a
		var t := clampf((p-a).dot(segment)/segment.length_squared(),0,1)
		closest=minf(closest,p.distance_to(a+segment*t))
		if p.x>=a.x and p.x<=b.x: shore_z=lerpf(a.y,b.y,(p.x-a.x)/(b.x-a.x))
	return closest if p.y>=shore_z else -closest

static func geometry(layout: Dictionary,ground: Callable) -> Node3D:
	var root := Node3D.new(); root.name="AdjustableScreen"
	var front := StandardMaterial3D.new(); front.shading_mode=BaseMaterial3D.SHADING_MODE_UNSHADED
	front.albedo_color=Color(.42,.52,.63); front.cull_mode=BaseMaterial3D.CULL_BACK
	var dark := StandardMaterial3D.new(); dark.albedo_color=Color(.035,.04,.045); dark.roughness=.85
	var corners: PackedVector3Array = layout.corners
	var back := PackedVector3Array()
	for p in corners: back.append(p-layout.normal*.075)
	_quad(root,"Screen_Front",corners,front)
	_quad(root,"Screen_OpaqueBack",PackedVector3Array([back[3],back[2],back[1],back[0]]),dark)
	for i in 4:
		var j := (i+1)%4
		_quad(root,"Screen_Edge_"+str(i),PackedVector3Array([corners[j],corners[i],back[i],back[j]]),dark)
	for i in layout.supports.size():
		var support: Dictionary = layout.supports[i]
		for j in support.feet.size():
			var foot: Vector3 = support.feet[j]
			_rod(root,"Support_%s_%s"%[i,j],foot,support.anchor,layout.section/2,dark)
			var a: Vector3 = foot-layout.right*layout.foot_width/2
			var b: Vector3 = foot+layout.right*layout.foot_width/2
			a.y=ground.call(a.x,a.z)+.025; b.y=ground.call(b.x,b.z)+.025
			_rod(root,"Foot_%s_%s"%[i,j],a,b,.035,dark)
	return root

static func _quad(root: Node3D,name_: String,points: PackedVector3Array,material: Material) -> void:
	var mesh := ArrayMesh.new(); var arrays: Array = []; arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX]=points
	# Godot front faces use clockwise winding (opposite Blender source faces).
	arrays[Mesh.ARRAY_INDEX]=PackedInt32Array([0,2,1,0,3,2])
	var normal := (points[1]-points[0]).cross(points[3]-points[0]).normalized()
	arrays[Mesh.ARRAY_NORMAL]=PackedVector3Array([normal,normal,normal,normal])
	arrays[Mesh.ARRAY_TEX_UV]=PackedVector2Array([Vector2(0,1),Vector2(1,1),Vector2(1,0),Vector2(0,0)])
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,arrays)
	var node := MeshInstance3D.new(); node.name=name_; node.mesh=mesh; node.material_override=material; root.add_child(node)

static func _rod(root: Node3D,name_: String,a: Vector3,b: Vector3,radius: float,material: Material) -> void:
	var mesh := CylinderMesh.new(); mesh.top_radius=radius; mesh.bottom_radius=radius
	mesh.height=a.distance_to(b); mesh.radial_segments=10; mesh.rings=1
	var node := MeshInstance3D.new(); node.name=name_; node.mesh=mesh; node.material_override=material
	var up := (b-a).normalized()
	var right := Vector3.RIGHT if absf(up.x)<.9 else Vector3.FORWARD
	var back := right.cross(up).normalized(); right=up.cross(back).normalized()
	node.transform=Transform3D(Basis(right,up,back),(a+b)*.5); root.add_child(node)

static func collider_boxes(layout: Dictionary,root: Node3D) -> Array[AABB]:
	var result: Array[AABB] = []
	# Split rotated panels so their empty bounding-box corners do not become a wall.
	var w: float = layout.half_size.x*2; var h: float = layout.half_size.y*2
	var columns := ceili(w/.5) if absf(layout.right.z)>.001 else 1
	var rows := ceili(h/.5) if absf(layout.up.z)+absf(layout.up.x)>.001 else 1
	for x in columns:
		for y in rows:
			var a: Vector3 = layout.corners[0]+layout.right*(w*x/columns)+layout.up*(h*y/rows)
			var box := AABB(a,Vector3.ZERO)
			for point in [a,a+layout.right*w/columns,a+layout.up*h/rows,a+layout.right*w/columns+layout.up*h/rows]:
				box=box.expand(point); box=box.expand(point-layout.normal*.075)
			result.append(box.grow(.002))
	for node in root.get_children():
		if str(node.name).begins_with("Support_") or str(node.name).begins_with("Foot_"):
			result.append((node.transform*node.get_aabb()).grow(.002))
	return result
