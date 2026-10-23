extends SceneTree
const PipWindow := preload("res://scripts/video_pip_window.gd")
var checks := 0
var failures: Array[String] = []
var viewport: SubViewport
var camera: Camera3D
var window: Node3D
var output := ProjectSettings.globalize_path("res://../../build/output/video-pip")
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)
func draw() -> Image:
	await process_frame; await RenderingServer.frame_post_draw; await RenderingServer.frame_post_draw
	return viewport.get_texture().get_image()
func pixel(image: Image, point: Vector2) -> Color:
	return image.get_pixelv(Vector2i(camera.unproject_position(window.to_global(Vector3(point.x,point.y,0)))))
func _initialize() -> void: call_deferred("run")
func run() -> void:
	DirAccess.make_dir_recursive_absolute(output)
	viewport=SubViewport.new(); viewport.size=Vector2i(1024,1024); viewport.transparent_bg=true; viewport.own_world_3d=true
	viewport.render_target_update_mode=SubViewport.UPDATE_ALWAYS; root.add_child(viewport)
	camera=Camera3D.new(); camera.projection=Camera3D.PROJECTION_ORTHOGONAL; camera.size=0.65; viewport.add_child(camera)
	window=PipWindow.new(); viewport.add_child(window); window.position.z=-2
	var source:=Image.create(320,160,false,Image.FORMAT_RGBA8); source.fill(Color.WHITE)
	var texture:=ImageTexture.create_from_image(source)
	for mode in ["image","video"]:
		if mode=="image": window.show_image(texture)
		else:
			window.restore_video(); window.frame.visible=true; window.picture.set_shader_parameter("color_texture",texture)
			window.picture.set_shader_parameter("alpha_enabled",false); window.crop_parameters()
		for dimensions in [Vector2(0.48,0.24),Vector2(0.24,0.48)]:
			window.set_size(dimensions); window.controls=false; window.refresh()
			var image:=await draw()
			var x: float=dimensions.x/2; var y: float=dimensions.y/2; var feather: float=window.edge_feather().x*dimensions.x
			check(pixel(image,Vector2.ZERO).a>0.99 and pixel(image,Vector2.ZERO).r>0.98,"The centre stays opaque and sharp")
			for sign_axis in [-1,1]:
				var outer:=pixel(image,Vector2(sign_axis*(x-feather*0.1),0)).a
				var middle:=pixel(image,Vector2(sign_axis*(x-feather*0.5),0)).a
				var inner:=pixel(image,Vector2(sign_axis*(x-feather*1.1),0)).a
				check(outer<0.12 and middle>0.25 and middle<0.75 and inner>0.99,"Both side edges fade smoothly into transparency")
				check(pixel(image,Vector2(0,sign_axis*(y-feather*0.1))).a<0.12,"Top and bottom use the same physical feather width")
			check(window._decorations.is_empty(),"A resting frame has no opaque border meshes")
			image.save_png(output.path_join("soft-edge-%s-%s.png" % [mode,"wide" if dimensions.x>dimensions.y else "tall"]))
	window.identified=true; window.refresh()
	check(window._decorations.size()==4 and not window.controls_root.visible,"Identification shows corner cues without a hard outline or toolbar")
	window.identified=false; window.set_size(Vector2(0.48,0.24)); window.refresh()
	var edges := preload("res://scripts/video_pip_edges.gd")
	var whole := Rect2(2,2,512,256)
	var centre := edges.coverage(whole,edges.centre(whole,window.edge_feather()))
	var cut := edges.hole(centre,window.size)
	var background:=MeshInstance3D.new(); background.mesh=QuadMesh.new(); background.mesh.size=Vector2.ONE
	var background_material:=StandardMaterial3D.new(); background_material.shading_mode=BaseMaterial3D.SHADING_MODE_UNSHADED
	background.material_override=background_material; background.position.z=-2.1; viewport.add_child(background)
	for backdrop in [Color.TRANSPARENT,Color(0.2,0.4,0.65),Color(0.7,0.3,0.1)]:
		background.visible=backdrop.a>0; background_material.albedo_color=backdrop
		window.set_compositor(false)
		var reference:=await draw()
		window.set_compositor(true,cut,true)
		var hybrid:=await draw()
		check(pixel(hybrid,Vector2.ZERO).a<0.01,"Only the native centre punches a hole")
		check(window.soft_rim.visible and window.soft_rim.material_override==window.picture,"Ring borrows the exact video material and source lease")
		check(window.soft_rim.position==Vector3.ZERO,"Ring and native centre share one plane")
		var max_error:=0.0
		var mismatches:=0
		# Compare actual production ring pixels against full shared-texture rendering.
		# The native centre is an opaque-white stand-in, not an OpenXR runtime test.
		for yi in range(-130,131,2):
			for xi in range(-250,251,2):
				var point:=Vector2(xi,yi)*0.001
				var uv:=Vector2(point.x/window.size.x+0.5,0.5-point.y/window.size.y)
				var actual:=pixel(hybrid,point)
				if centre.has_point(uv):
					# Only compare the opaque overlap/centre here: the ring outside is
					# independently compared RGBA, including its original background.
					actual=Color(actual.r+1-actual.a,actual.g+1-actual.a,actual.b+1-actual.a,1)
				var expected:=pixel(reference,point)
				var error:=maxf(absf(actual.r-expected.r),maxf(absf(actual.g-expected.g),maxf(absf(actual.b-expected.b),absf(actual.a-expected.a))))
				max_error=maxf(max_error,error)
				if error>0.035: mismatches+=1
		check(mismatches==0,"Hybrid centre/ring matches full video over background %s (max error %.4f, mismatches %d)" % [backdrop,max_error,mismatches])
		hybrid.save_png(output.path_join("inward-ring-%s.png" % ("transparent" if backdrop.a==0 else ("blue" if backdrop.b>0.5 else "warm"))))
	window.set_compositor(false)
	check(not window.soft_rim.visible,"Shared texture fallback hides the extra ring")
	viewport.queue_free(); await process_frame
	for failure in failures: push_error(failure)
	print("Video PiP soft edges: %d checks, %d failures" % [checks,failures.size()])
	quit(0 if failures.is_empty() else 1)
