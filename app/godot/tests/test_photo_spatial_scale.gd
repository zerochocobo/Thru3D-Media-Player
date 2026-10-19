extends SceneTree
const Geometry:=preload("res://scripts/photo_spatial_geometry.gd")
const Scene:=preload("res://scripts/photo_spatial_scene.gd")
const Fixture:=preload("res://tests/test_photo_spatial_scene.gd")
var checks:=0
var failures: Array[String]=[]
var records: Array=[]

func check(ok: bool, message: String) -> void:
	checks+=1
	if not ok: failures.append(message)

func _initialize() -> void: call_deferred("run")

func peak(data: Dictionary) -> float:
	var value:=0.0
	for p: Vector3 in data.vertices: value=maxf(value,p.z)
	return value

func run() -> void:
	var f:=Fixture.fixture()
	var eye:=Vector3(0,0,3)
	var landscape: Dictionary
	for portrait in [false,true]:
		var image: Image=f.image.duplicate(); var depth: Image=f.depth.duplicate()
		if portrait: image.rotate_90(CLOCKWISE); depth.rotate_90(CLOCKWISE)
		var size:=Vector2(1.5,2) if portrait else Vector2(2,1.5)
		var reference:=Geometry.prepare(image,depth,f.rect,eye,size)
		if not portrait: landscape=reference
		else:
			check(is_equal_approx(peak(reference),peak(landscape)),"Rotating photo, depth and display together preserves peak physical relief")
			check(reference.triangles==landscape.triangles,"Landscape and portrait share the same geometry budget")
		for native in [false,true]:
			for dimensions in [Vector2i(16,12),Vector2i(320,240),Vector2i(1001,751),Vector2i(2048,1536),Vector2i(4096,3072)]:
				if portrait: dimensions=Vector2i(dimensions.y,dimensions.x)
				var color:=image.duplicate(); color.resize(dimensions.x,dimensions.y,Image.INTERPOLATE_LANCZOS)
				if native:
					var pair:=Image.create(dimensions.x*2,dimensions.y,false,Image.FORMAT_RGBA8)
					pair.fill(Color.GREEN); pair.blit_rect(color,Rect2i(Vector2i.ZERO,dimensions),Vector2i.ZERO); color=pair
				var data:=Geometry.prepare(color,depth,f.rect,eye,size,native)
				var name:="%s/%s/%dx%d"%["apple" if native else "converted","portrait" if portrait else "landscape",dimensions.x,dimensions.y]
				check(data.vertices==reference.vertices,"All geometry matches across source resolutions: "+name)
				check(data.uv==reference.uv and data.gradient_half_cells==reference.gradient_half_cells,"Texture rounding never changes mesh sampling or physical edge protection: "+name)
				check(data.triangles<=Geometry.MAX_TRIANGLES and data.color.get_width()*data.color.get_height()<=Geometry.MAX_PIXELS,"Existing memory and triangle budgets hold: "+name)
				records.append({"name":name,"vertices_identical":data.vertices==reference.vertices,"triangles":data.triangles,"peak_relief_m":peak(data),"limit_m":data.relief_limit_m,"gain":data.span})
	var last_peak:=0.0; var last_ratio:=-1.0
	for size in [Vector2(.8,.6),Vector2(2,1.5),Vector2(4,3)]:
		var data:=Geometry.prepare(f.image,f.depth,f.rect,eye,size)
		var current:=peak(data)
		check(current>last_peak,"A physically larger display increases relief until the physical limit")
		if last_ratio>=0: check(absf(current/data.relief_limit_m-last_ratio)<.00001,"Changing display size changes the physical amplitude, not the depth curve")
		last_peak=current; last_ratio=current/data.relief_limit_m
	var close:=Geometry.prepare(f.image,f.depth,f.rect,Vector3(0,0,.5),Vector2(2,1.5))
	check(peak(close)<peak(landscape) and peak(close)<=.06,"Near displays retain the reference-distance comfort bound")
	var flat:=Geometry.prepare(f.image,f.depth,f.rect,eye,Vector2(2,1.5),false,0)
	check(peak(flat)==0,"Zero diagnostic gain remains a flat scene")
	var scene:=Scene.new(); root.add_child(scene); scene._accept(landscape)
	var mesh_id: int=scene.surfaces[0].mesh.get_instance_id()
	for scale in [.5,1.5]:
		var size: Vector2=Vector2(2,1.5)*scale
		var rebuilt:=Geometry.prepare(f.image,f.depth,f.rect,eye,size)
		for offset in [Vector3(-.2,0,0),Vector3(.2,.1,-.2)]:
			scene.sync(Transform3D.IDENTITY,size,eye+offset)
			check(absf(peak(landscape)*scene.transform.basis.z.length()-peak(rebuilt))<.00001,"Explicit resizing matches newly prepared physical depth and ignores current head position")
			check(scene.surfaces[0].mesh.get_instance_id()==mesh_id,"Resizing reuses the existing mesh")
	scene.free(); await process_frame
	var output:="res://../../build/output/photo-spatial-scale"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(output))
	FileAccess.open(output.path_join("geometry-result.json"),FileAccess.WRITE).store_string(JSON.stringify({"checks":checks,"failures":failures,"cases":records,"scope":"Production geometry with identical normalized depth; isolates scale from inference and texture quality"},"\t"))
	for failure in failures: push_error(failure)
	print("Photo spatial display scale: %d checks, %d failures"%[checks,failures.size()])
	quit(0 if failures.is_empty() else 1)
