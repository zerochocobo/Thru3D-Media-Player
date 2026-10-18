extends SceneTree
const Geometry := preload("res://scripts/puzzle/puzzle_geometry.gd")
const Session := preload("res://scripts/puzzle/puzzle_session.gd")
var checks := 0
var failures: Array[String] = []

func _initialize() -> void: call_deferred("_run")
func check(ok: bool, message: String) -> void:
	checks+=1
	if not ok: failures.append(message); push_error(message)

func key(point: Vector3) -> String:
	return "%d,%d,%d" % [roundi(point.x*1000000),roundi(point.y*1000000),roundi(point.z*1000000)]

func verify_solid(result: Dictionary, name_value: String) -> void:
	check(not result.is_empty(),name_value+" generated")
	if result.is_empty(): return
	var arrays: Array=result.mesh.surface_get_arrays(0)
	var points: PackedVector3Array=arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array=arrays[Mesh.ARRAY_NORMAL]
	var edges := {}; var winding := true; var finite := true
	for point in points: finite=finite and point.is_finite()
	for i in range(0,points.size(),3):
		winding=winding and (points[i+1]-points[i]).cross(points[i+2]-points[i]).dot(normals[i]) < 0
		for j in 3:
			var a := key(points[i+j]); var b := key(points[i+(j+1)%3])
			var edge := a+"/"+b if a<b else b+"/"+a
			edges[edge]=int(edges.get(edge,0))+1
	check(points.size()>100 and finite,name_value+" finite nonempty triangles")
	check(winding,name_value+" clockwise faces with outward normals")
	check(edges.values().all(func(count):return count==2),name_value+" closed manifold, front/back/side boundaries match")
	check(result.mesh.get_aabb().size.z>=float(result.thickness)*0.99,name_value+" real physical thickness")

func _run() -> void:
	check(Session.grid_for_source({"size":Vector2(300,100)},12)==Vector2i(6,2),"A wide image cuts into square pieces using total count rather than a fixed 4x3 grid")
	check(Session.grid_for_source({"size":Vector2(100,300)},12)==Vector2i(2,6),"A portrait image rotates the layout to preserve piece shape")
	check(Session.grid_for_source({"size":Vector2(300,200)},24)==Vector2i(6,4),"24 pieces adapt to a 3:2 photo with square cells")
	check(Session.grid_for_source({"size":Vector2(160,120)},12)==Vector2i(4,3),"Spatial single-eye dimensions determine the physical cut")
	check(Session.grid_for_source({"projection":"sphere"},54)==Vector2i(18,3),"Sky difficulty uses 3x3 patches on each cube face")
	var grid := Vector2i(4,3)
	var a := Geometry.outline(Vector2i(1,1),grid,12)
	var b := Geometry.outline(Vector2i(2,1),grid,12)
	check(a==Geometry.outline(Vector2i(1,1),grid,12),"Deterministic contours")
	check(a!=Geometry.outline(Vector2i(1,1),grid,13),"New seed changes tabs")
	var shared := true
	for i in range(1,Geometry.EDGE_SAMPLES):
		shared=shared and a[Geometry.EDGE_SAMPLES+i].is_equal_approx(b[4*Geometry.EDGE_SAMPLES-i])
	check(shared,"Adjacent pieces share the exact reversed edge")
	var neck := false
	for i in range(1,Geometry.EDGE_SAMPLES): neck=neck or a[i].x<a[i-1].x
	check(neck,"Flat pieces use traditional round-headed joints with a narrow re-entrant neck")
	var depth := Image.create(32,32,false,Image.FORMAT_RF)
	for y in 32:
		for x in 32: depth.set_pixel(x,y,Color(float(x+y)/62,0,0))
	verify_solid(Geometry.flat(Vector2i(1,1),grid,Vector2(1.2,0.8)),"Flat piece")
	var relief := Geometry.flat(Vector2i(1,1),grid,Vector2(1.2,0.8),{"depth":depth,"relief":0.03})
	verify_solid(relief,"Relief piece")
	check(relief.mesh.get_aabb().size.z>0.02,"Depth produces actual surface relief")
	verify_solid(Geometry.shell(Rect2(0.44,0.38,0.12,0.2)),"Curved shell")
	check(Geometry.flat(Vector2i.ZERO,Vector2i.ZERO,Vector2.ONE).is_empty(),"Reject invalid grid")
	check(is_zero_approx(Geometry.sample_depth(null,Vector2.ONE)),"Missing depth has a flat surface")
	depth.set_pixel(0,0,Color(NAN,0,0)); check(is_zero_approx(Geometry.sample_depth(depth,Vector2.ZERO)),"Nonfinite depth is bounded")
	var image := Image.create(48,32,false,Image.FORMAT_RGB8); image.fill(Color(0.4,0.6,0.7))
	var session := Session.new(); root.add_child(session)
	check(session.configure({"texture":ImageTexture.create_from_image(image),"size":Vector2(48,32)}),"Production session builds 12 pieces")
	session.position=Vector3(0.3,1.4,-2.0); session.rotation.y=0.4
	var piece: MeshInstance3D=session.pieces[0]
	var origin: Vector3=piece.global_position+session.global_basis.z
	var direction: Vector3=-session.global_basis.z
	check(session.grab("right",origin,direction),"Ray acquires an actual triangle")
	check(not session.grab("left",origin,direction),"Second hand cannot steal a held piece")
	check(not session.release("right"),"Wrong position stays loose")
	check(not piece.placed and session.completed()==0,"No progress for wrong placement")
	piece.transform=piece.goal
	piece.position.x+=0.025
	check(session.can_snap(piece),"Small positional error fits magnetic tolerance")
	piece.rotation.z=deg_to_rad(30)
	check(not session.can_snap(piece),"Wrong rotation does not snap")
	piece.rotation=Vector3.ZERO
	var other: MeshInstance3D=session.pieces[1]
	other.transform=piece.goal
	check(not session.can_snap(other),"Wrong piece never fits another piece's goal")
	other.transform=other.parked
	origin=piece.global_position+session.global_basis.z
	check(session.grab("right",origin,direction),"Grab near the correct slot")
	session.update_grab("right",origin,direction)
	check(not piece.placed,"Candidate preview never commits while still held")
	check(session.hint.visible,"Candidate target is visible")
	check(session.release("right"),"Release snaps and locks the correct piece")
	check(not session.release("right") and session.completed()==1,"Repeated release counts only once")
	await piece.motion.finished
	check(piece.transform.is_equal_approx(piece.goal),"Snap animation reaches exact shared target coordinates")
	other.transform=other.goal
	origin=other.global_position+session.global_basis.z
	check(session.grab("left",origin,direction),"Acquire another piece")
	session.cancel("left")
	check(not session.release("left") and not other.placed,"Tracking cancellation cannot become a successful placement")
	session.set_paused(true)
	check(not session.grab("left",origin,direction),"Modal pause blocks game grabs")
	session.set_paused(false); session.scatter(true)
	check(piece.placed and piece.transform.is_equal_approx(piece.goal),"Posture/layout change preserves completed pieces")
	session.queue_free(); await process_frame
	print("Puzzle core: %d checks, %d failures" % [checks,failures.size()])
	quit(0 if failures.is_empty() else 1)
