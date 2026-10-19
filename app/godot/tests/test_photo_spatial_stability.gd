extends SceneTree
const Geometry:=preload("res://scripts/photo_spatial_geometry.gd")
const Scene:=preload("res://scripts/photo_spatial_scene.gd")
const Fixture:=preload("res://tests/test_photo_spatial_scene.gd")
var checks:=0
var failures: Array[String]=[]

func check(ok: bool, message: String) -> void:
	checks+=1
	if not ok: failures.append(message)

func _initialize() -> void: call_deferred("run")

func run() -> void:
	var size:=Vector2(2,1.5)
	# Ground/feet occupy the entire lower edge: the user's failure was missed by the
	# old centred red-rectangle fixture and its small, distant camera offsets.
	var f:=Fixture.fixture()
	f.depth.fill_rect(Rect2i(0,40,80,20),Color(1,0,0))
	for distance in [0.5,1.0,3.0]:
		var reference:=Vector3(-.032,0,distance)
		var data:=Geometry.prepare(f.image,f.depth,f.rect,reference,size)
		var border_error:=0.0; var max_depth:=0.0; var projection_error:=0.0
		for i in data.vertices.size():
			var p: Vector3=data.vertices[i]; var uv: Vector2=data.uv[i]
			max_depth=maxf(max_depth,absf(p.z))
			var target:=Vector2(uv.x-.5,.5-uv.y)*size
			var projected:=reference+(p-reference)*reference.z/(reference.z-p.z)
			projection_error=maxf(projection_error,Vector2(projected.x,projected.y).distance_to(target))
			if uv.x==0 or uv.x==1 or uv.y==0 or uv.y==1:
				border_error=maxf(border_error,p.distance_to(Vector3(target.x,target.y,0)))
		check(border_error<0.00001,"All four photo edges stay on their fixed rectangle at %.1fm"%distance)
		check(max_depth<=minf(.3,distance*.12)+.00001,"Depth relief stays bounded even with a foreground lower half at %.1fm"%distance)
		check(projection_error<.00001,"Bounded geometry preserves reference composition at %.1fm"%distance)
		if distance==3.0:
			var edges:={}
			for i in range(0,data.uv.size(),3):
				for side in 3:
					var a: Vector2=data.uv[i+side]; var b: Vector2=data.uv[i+(side+1)%3]
					if a.x>b.x or (a.x==b.x and a.y>b.y):
						var swap:=a; a=b; b=swap
					var key:=Vector4(a.x,a.y,b.x,b.y)
					edges[key]=int(edges.get(key,0))+1
			var unmatched:=0
			for edge: Vector4 in edges:
				var boundary: bool=(edge.x==edge.z and (edge.x==0 or edge.x==1)) or (edge.y==edge.w and (edge.y==0 or edge.y==1))
				if edges[edge]!=(1 if boundary else 2): unmatched+=1
			check(unmatched==0,"Every internal mesh edge is shared exactly twice; no coarse/fine T-junction cracks")
		var scene:=Scene.new(); root.add_child(scene)
		scene._accept(data)
		var anchor:=Transform3D(Basis.from_euler(Vector3(.15,-.2,.08)),Vector3(.4,1.2,-distance))
		var mesh_id: int=scene.surfaces[0].mesh.get_instance_id()
		var stable:=true; var opaque:=true
		# Cross the old 3.85%-5.5% fade boundary in both directions, then beyond it.
		for x in [-.25,-.17,-.12,-.06,-.03,0,.03,.06,.12,.17,.25]:
			for z in [-.1,0,.1]:
				scene.sync(anchor,size,reference+Vector3(x,.04,z))
				stable=stable and scene.transform.is_equal_approx(anchor) and scene.surfaces[0].mesh.get_instance_id()==mesh_id
				opaque=opaque and scene.visible and is_equal_approx(scene.coverage,1.0)
		check(stable,"Head movement never moves/rescales the world anchor or rebuilds geometry at %.1fm"%distance)
		check(opaque,"Lateral/forward movement never fades back to the old stereo plane at %.1fm"%distance)
		for repeat in 10: scene.sync(anchor,size*1.5,reference)
		var depth_scale:=Geometry.relief_limit(reference,size*1.5)/Geometry.relief_limit(reference,size)
		check(scene.transform.is_equal_approx(anchor.scaled_local(Vector3(1.5,1.5,depth_scale))),"Physical resizing applies once to width, height and bounded depth at %.1fm"%distance)
		scene.free()
	for failure in failures: push_error(failure)
	print("Photo spatial stability: %d checks, %d failures"%[checks,failures.size()])
	quit(0 if failures.is_empty() else 1)
