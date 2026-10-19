extends SceneTree
const Scene:=preload("res://scripts/photo_spatial_scene.gd")
const Fixture:=preload("res://tests/test_photo_spatial_scene.gd")
var checks:=0
var failures: Array[String]=[]
var output:="res://../../build/output/photo-spatial/render"
var viewport: SubViewport
var camera: Camera3D

func check(ok: bool, message: String) -> void:
	checks+=1
	if not ok: failures.append(message)

func capture(name: String) -> Image:
	for i in 3: await RenderingServer.frame_post_draw
	var picture:=viewport.get_texture().get_image()
	picture.save_png(output.path_join(name+".png"))
	return picture

func centroid(image: Image) -> Vector2:
	var total:=Vector2.ZERO; var count:=0
	for y in range(35,image.get_height()-35):
		for x in range(35,image.get_width()-35):
			var c:=image.get_pixel(x,y)
			if c.r>.65 and c.g<.18 and c.b<.12: total+=Vector2(x,y); count+=1
	return total/maxi(1,count)

func _initialize() -> void: call_deferred("run")
func run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(output))
	viewport=SubViewport.new(); viewport.size=Vector2i(640,480); viewport.own_world_3d=true
	viewport.render_target_update_mode=SubViewport.UPDATE_ALWAYS; viewport.msaa_3d=Viewport.MSAA_2X
	root.add_child(viewport)
	var environment:=WorldEnvironment.new(); var sky:=Environment.new()
	sky.background_mode=Environment.BG_COLOR; sky.background_color=Color.BLACK; environment.environment=sky; viewport.add_child(environment)
	camera=Camera3D.new(); camera.fov=32; camera.near=.05; viewport.add_child(camera); camera.current=true
	var f:=Fixture.fixture()
	for y in range(12,42):
		for x in range(24,296): f.image.set_pixel(x,y,Color.WHITE if (x/2+y/2)%2==0 else Color(.08,.08,.08))
	var quad:=MeshInstance3D.new(); var flat:=QuadMesh.new(); flat.size=Vector2(2,1.5); quad.mesh=flat; quad.position.z=-3
	var material:=StandardMaterial3D.new(); material.shading_mode=BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_texture=ImageTexture.create_from_image(f.image); material.texture_filter=BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	quad.material_override=material; viewport.add_child(quad)
	var original:=await capture("01-original")
	quad.visible=false
	var scene:=Scene.new(); viewport.add_child(scene)
	scene.begin(f.image,f.depth,f.rect,Vector3(0,0,3),Vector2(2,1.5),false)
	var deadline:=Time.get_ticks_msec()+30000
	while not scene.prepared and scene.error.is_empty() and Time.get_ticks_msec()<deadline: await create_timer(.01).timeout
	check(scene.prepared,"Production scene prepares under OpenGL")
	if not scene.prepared: quit(1); return
	scene.sync(Transform3D(Basis(),Vector3(0,0,-3)),Vector2(2,1.5),Vector3(0,0,3))
	var centre:=await capture("02-spatial-centre")
	var difference:=0.0; var samples:=0
	var original_edge:=0.0; var spatial_edge:=0.0
	for y in range(57,78):
		for x in range(100,540):
			var a:=original.get_pixel(x,y); var b:=centre.get_pixel(x,y)
			difference+=absf(a.r-b.r)+absf(a.g-b.g)+absf(a.b-b.b); samples+=3
			original_edge+=absf(a.r-original.get_pixel(x-1,y).r)
			spatial_edge+=absf(b.r-centre.get_pixel(x-1,y).r)
	check(difference/maxi(1,samples)<.06,"Reference-view fine pattern stays close to original pixels")
	check(spatial_edge/maxf(original_edge,.001)>.85,"Reference-view edge contrast retains at least 85 percent")
	var left: Image; var right: Image; var up: Image
	for entry in [["03-head-left",Vector3(-.08,0,0)],["04-head-right",Vector3(.08,0,0)],["05-head-up",Vector3(0,.08,0)]]:
		camera.position=entry[1]
		scene.sync(Transform3D(Basis(),Vector3(0,0,-3)),Vector2(2,1.5),camera.position+Vector3(0,0,3))
		var picture:=await capture(entry[0])
		if entry[0]=="03-head-left": left=picture
		elif entry[0]=="04-head-right": right=picture
		else: up=picture
		var black:=0
		for y in range(90,390):
			for x in range(95,545):
				var c:=picture.get_pixel(x,y)
				if maxf(c.r,maxf(c.g,c.b))<.025: black+=1
		check(black<12,"No black disocclusion holes in the photo interior: "+entry[0])
	check(centroid(left).x>centroid(centre).x+15 and centroid(right).x<centroid(centre).x-15,"Foreground changes viewpoint in the correct direction under lateral translation")
	var flat_shift:=480.0/(2.0*tan(deg_to_rad(camera.fov)*0.5))*.08/3.0
	check(centroid(left).x-centroid(centre).x>flat_shift+0.5,"Foreground motion exceeds a flat photo's motion, demonstrating internal depth parallax")
	check(centroid(up).y>centroid(centre).y+15,"Vertical translation also changes content viewpoint")
	var native_pair:=Image.create(640,240,false,Image.FORMAT_RGBA8)
	native_pair.blit_rect(f.image,Rect2i(0,0,320,240),Vector2i.ZERO)
	native_pair.fill_rect(Rect2i(320,0,320,240),Color.GREEN)
	scene.begin(native_pair,f.depth,f.rect,Vector3(0,0,3),Vector2(2,1.5),true)
	deadline=Time.get_ticks_msec()+30000
	while not scene.prepared and scene.error.is_empty() and Time.get_ticks_msec()<deadline: await create_timer(.01).timeout
	camera.position=Vector3.ZERO
	scene.sync(Transform3D(Basis(),Vector3(0,0,-3)),Vector2(2,1.5),Vector3(0,0,3))
	var native_image:=await capture("06-apple-spatial-centre")
	check(native_image.get_pixel(320,240).r>.65 and native_image.get_pixel(320,240).g<.2,"Apple scene renders its original left eye, without mixing the right eye")
	var report:={"checks":checks,"failures":failures,"reference_mae":difference/maxi(1,samples),"edge_contrast_ratio":spatial_edge/maxf(original_edge,.001),
		"centroids":{"centre":str(centroid(centre)),"left":str(centroid(left)),"right":str(centroid(right)),"up":str(centroid(up))},"resources":scene.report,
		"scope":"Desktop OpenGL synthetic fixture; not Android GPU timing or headset comfort validation"}
	scene.clear(); scene.queue_free(); quad.queue_free(); await process_frame
	camera.position=Vector3.ZERO
	var photo:=Fixture.Photo.new(); viewport.add_child(photo); photo.set_process(false)
	photo.view_camera=camera; photo.flat_pose=Transform3D(Basis(),Vector3(0,0,-3)); photo.screen_curve=0
	photo.screen_scale=2.0/photo._screen_dimensions(4.0/3.0).x
	photo._size=Vector2(320,240); photo._texture=ImageTexture.create_from_image(f.image)
	photo._display_request=1; photo._display_result={"image":f.image}; photo._display_depth_data={"image":f.depth,"rect":f.rect}
	photo.depth_requested=true; photo.depth_enabled=true
	photo.material.set_shader_parameter("photo_texture",photo._texture)
	photo._apply_geometry(); photo.panel.visible=true; photo.set_spatial(true)
	deadline=Time.get_ticks_msec()+30000
	while not photo._spatial.prepared and photo.spatial_requested and Time.get_ticks_msec()<deadline: await create_timer(.01).timeout
	photo._process_spatial()
	var production:=await capture("07-player-spatial")
	check(production.get_pixel(320,240).r>.65 and photo.material.get_shader_parameter("spatial_hidden"),"Production PhotoDisplay renders the scene while suppressing its original plane")
	var anchor: Transform3D=photo._spatial.transform
	for x in [-.20,.12,.20]:
		camera.position=Vector3(x,0,0); camera.look_at(Vector3(0,0,-3))
		photo._process_spatial()
		await capture("07-player-head-%+dcm"%roundi(x*100))
		check(photo._spatial.visible and photo._spatial.coverage==1 and photo.material.get_shader_parameter("spatial_hidden") \
			and photo._spatial.transform.is_equal_approx(anchor),"Production head movement keeps the same world anchor and never reveals the original plane at %+.0fcm"%(x*100))
	camera.transform=Transform3D.IDENTITY; photo._process_spatial()
	photo.set_spatial(false)
	var restored:=await capture("08-player-original-restored")
	check(restored.get_pixel(320,240).r>.65 and not photo.material.get_shader_parameter("spatial_hidden"),"Production exit restores the original photo pixels")
	photo.queue_free(); await process_frame
	camera.position=Vector3(0,.26,1.2); camera.fov=60
	viewport.size=Vector2i(1200,900)
	for lang in ["en","zh","zh_Hant","ja"]:
		Fixture.I18n.use(lang)
		var menu:=Fixture.Menu.new(); viewport.add_child(menu)
		menu.state_provider=func():return {"has_image":true,"geometry":0,"spatial_available":true,"spatial_requested":true,"spatial_ready":true,"count":1,"index":0}
		menu.visible=true; menu._mode_open=true; menu.refresh()
		var entry: Dictionary=menu._buttons.filter(func(b):return b.target==Fixture.Menu.PHOTO_SPATIAL)[0]
		check(entry.enabled and entry.node.global_position.y>0.65,"Spatial action fits above the projection picker in "+lang)
		await capture("menu-"+lang)
		menu.free()
	viewport.queue_free(); await process_frame
	report.checks=checks
	FileAccess.open(output.path_join("result.json"),FileAccess.WRITE).store_string(JSON.stringify(report,"\t"))
	for failure in failures: push_error(failure)
	print("Photo spatial render: %d checks, %d failures"%[checks,failures.size()])
	quit(0 if failures.is_empty() else 1)
