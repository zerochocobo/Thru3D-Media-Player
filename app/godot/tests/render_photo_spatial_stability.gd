extends SceneTree
const Geometry:=preload("res://scripts/photo_spatial_geometry.gd")
const Scene:=preload("res://scripts/photo_spatial_scene.gd")
const Fixture:=preload("res://tests/test_photo_spatial_scene.gd")
var checks:=0
var failures: Array[String]=[]
var output:="res://../../build/output/photo-spatial/stability-render"
var view: SubViewport
var camera: Camera3D
var records: Array=[]

func check(ok: bool, message: String) -> void:
	checks+=1
	if not ok: failures.append(message)

func capture(path: String) -> Image:
	for frame in 3: await RenderingServer.frame_post_draw
	var image:=view.get_texture().get_image()
	if not path.is_empty(): image.save_png(output.path_join(path+".png"))
	return image

func lit(image: Image, point: Vector2) -> bool:
	var p:=Vector2i(point.round())
	if p.x<0 or p.y<0 or p.x>=image.get_width() or p.y>=image.get_height(): return false
	var c:=image.get_pixelv(p)
	return maxf(c.r,maxf(c.g,c.b))>.04

func _initialize() -> void: call_deferred("run")

func run() -> void:
	if not OS.get_environment("PHOTO_SPATIAL_STABILITY_OUTPUT").is_empty(): output=OS.get_environment("PHOTO_SPATIAL_STABILITY_OUTPUT")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(output))
	view=SubViewport.new(); view.size=Vector2i(800,640); view.own_world_3d=true
	view.render_target_update_mode=SubViewport.UPDATE_ALWAYS; view.msaa_3d=Viewport.MSAA_2X; root.add_child(view)
	var world:=WorldEnvironment.new(); var environment:=Environment.new()
	environment.background_mode=Environment.BG_COLOR; environment.background_color=Color.BLACK
	world.environment=environment; view.add_child(world)
	camera=Camera3D.new(); camera.near=.03; view.add_child(camera); camera.current=true
	var f:=Fixture.fixture()
	f.depth.fill_rect(Rect2i(0,35,80,25),Color(1,0,0))
	var pair:=Image.create(640,240,false,Image.FORMAT_RGBA8)
	pair.blit_rect(f.image,Rect2i(0,0,320,240),Vector2i.ZERO)
	pair.fill_rect(Rect2i(320,0,320,240),Color.GREEN)
	var size:=Vector2(1.2,.9)
	for distance in [1.0,3.0]:
		camera.fov=rad_to_deg(2*atan(.9/(2*distance)*1.65))
		var pose:=Transform3D(Basis.from_euler(Vector3(.05,-.08,.04)),Vector3(.2,.1,-distance))
		for native_pair in [false,true]:
			camera.fov=rad_to_deg(2*atan(.9/(2*distance)*1.65))
			var reference:=Vector3(-.032,0,distance)
			var scene:=Scene.new(); view.add_child(scene)
			scene._accept(Geometry.prepare(pair if native_pair else f.image,f.depth,f.rect,reference,size,native_pair))
			for head in [Vector3(-.2,0,0),Vector3.ZERO,Vector3(.2,0,0),Vector3(0,.12,0)]:
				var eye: Vector3=reference+head
				camera.transform=pose*Transform3D(Basis(),eye)
				camera.look_at(pose.origin)
				scene.sync(pose,size,eye)
				var name:="%s-%dm-x%+d-y%+d"%["apple" if native_pair else "converted",distance,roundi(head.x*100),roundi(head.y*100)]
				var image:=await capture(name)
				var missed:=0; var leaked:=0; var samples:=0
				# Probe the fixed plane's projected edges, not the mesh's deformed UV bounds.
				# A foreground covering the whole bottom must not bend/expand that edge.
				var centre:=camera.unproject_position(pose.origin)
				for i in range(2,19):
					var t:=float(i)/20.0
					for uv in [Vector2(t,0),Vector2(t,1),Vector2(0,t),Vector2(1,t)]:
						var edge:=camera.unproject_position(pose*Vector3((uv.x-.5)*size.x,(.5-uv.y)*size.y,0))
						var inward:=(centre-edge).normalized()
						if not lit(image,edge+inward*4): missed+=1
						if lit(image,edge-inward*3): leaked+=1
						samples+=1
				check(scene.coverage==1 and scene.visible,"No stereo fallback: "+name)
				check(missed==0 and leaked==0,"Fixed, filled rectangle under asymmetric bottom depth: "+name)
				records.append({"name":name,"coverage":scene.coverage,"edge_samples":samples,"missing_inside":missed,"outside_leaks":leaked})
			for scale in [.5,1.5]:
				var shown_size: Vector2=size*scale
				# Frame the resized portal completely; a cropped viewport cannot probe its outer edge.
				camera.fov=rad_to_deg(2*atan(shown_size.y/(2*distance)*1.9))
				camera.transform=pose*Transform3D(Basis(),reference); camera.look_at(pose.origin)
				scene.sync(pose,shown_size,reference)
				var name:="%s-%dm-scale%d"%["apple" if native_pair else "converted",distance,roundi(scale*100)]
				var image:=await capture(name)
				var missed:=0; var leaked:=0
				var centre:=camera.unproject_position(pose.origin)
				for t in [.2,.4,.6,.8]:
					for uv in [Vector2(t,0),Vector2(t,1),Vector2(0,t),Vector2(1,t)]:
						var edge:=camera.unproject_position(pose*Vector3((uv.x-.5)*shown_size.x,(.5-uv.y)*shown_size.y,0))
						var inward:=(centre-edge).normalized()
						if not lit(image,edge+inward*4): missed+=1
						if lit(image,edge-inward*3): leaked+=1
				check(missed==0 and leaked==0,"Explicit resize retains its fixed photo boundary: "+name)
				var expected:=Geometry.relief_limit(reference,shown_size)/Geometry.relief_limit(reference,size)
				check(absf(scene.transform.basis.z.length()-expected)<.00001,"Explicit resize uses the new physical depth bound: "+name)
				# Compare with the original flat photograph from the calibration eye. A depth-only
				# scale can keep the border intact while visibly warping interior texture details.
				scene.visible=false
				var flat:=Scene.new(); view.add_child(flat)
				flat._accept(Geometry.prepare(pair if native_pair else f.image,f.depth,f.rect,reference,size,native_pair,0))
				flat.sync(pose,shown_size,reference)
				var original:=await capture(name+"-flat-reference")
				flat.free(); scene.visible=true
				var error_sum:=0.0; var changed:=0; var count:=0
				for y in range(0,image.get_height(),3):
					for x in range(0,image.get_width(),3):
						var a:=image.get_pixel(x,y); var b:=original.get_pixel(x,y)
						var difference:=maxf(absf(a.r-b.r),maxf(absf(a.g-b.g),absf(a.b-b.b)))
						error_sum+=difference; count+=1
						if difference>.04: changed+=1
				var mean_error:=error_sum/count; var changed_fraction:=float(changed)/count
				check(mean_error<.001 and changed_fraction<.002,"Resized spatial image preserves the flat reference composition: "+name)
				records.append({"name":name,"coverage":scene.coverage,"missing_inside":missed,"outside_leaks":leaked,"depth_scale":expected,
					"reference_mean_rgb_error":mean_error,"reference_changed_fraction":changed_fraction})
			scene.free()
	view.free(); await process_frame
	FileAccess.open(output.path_join("result.json"),FileAccess.WRITE).store_string(JSON.stringify({"checks":checks,"failures":failures,"views":records,"scope":"Desktop perspective cameras, synthetic foreground at lower boundary, rotated world anchor, left-eye reference; no headset validation"},"\t"))
	for failure in failures: push_error(failure)
	print("Photo spatial stability render: %d checks, %d failures"%[checks,failures.size()])
	quit(0 if failures.is_empty() else 1)
