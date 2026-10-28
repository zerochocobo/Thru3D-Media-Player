extends SceneTree
## Real desktop GLES rendering of the imported shape, reference rays, soft Alpha and leases.
## The synthetic shape isolates geometry; Android RVM/mip generation and XR remain device checks.
const Portrait := preload("res://scripts/video_portrait.gd")
const Binding := preload("res://scripts/pair_texture_binding.gd")
var failures: Array[String] = []
var checks := 0
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)
func _initialize() -> void: call_deferred("run")
func frame(view: SubViewport) -> Image:
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	return view.get_texture().get_image()
func centroid(im: Image) -> float:
	var sum := 0.0; var total := 0.0
	for x in im.get_width():
		var weight := im.get_pixel(x, im.get_height()/2).g
		sum += weight*x; total += weight
	return sum/maxf(.001,total)
func run() -> void:
	var view := SubViewport.new(); view.size = Vector2i(320,240); view.own_world_3d = true
	view.transparent_bg = true; view.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(view)
	var camera := Camera3D.new(); camera.position.z = 2; camera.fov = 60
	view.add_child(camera)
	var panel := MeshInstance3D.new(); view.add_child(panel)
	var color := Image.create_empty(320,240,false,Image.FORMAT_RGBA8)
	var mask := Image.create_empty(640,320,false,Image.FORMAT_R8)
	var shape := Image.create_empty(320,320,false,Image.FORMAT_R8); shape.fill(Color(2.0/3.0,0,0))
	for y in 240:
		for x in 320: color.set_pixel(x,y,Color(float(x)/319,.7,float(y)/239,1))
	for y in 320:
		for x in 320:
			var u := (x+.5)/320.0; var v := ((y+.5)/320.0-.125)/.75
			var a := smoothstep(.23,.27,u)*(1.0-smoothstep(.73,.77,u)) if v>.1 and v<.9 else 0.0
			mask.set_pixel(x,y,Color(a,0,0)); mask.set_pixel(x+320,y,Color(a,0,0))
	var textures := [ImageTexture.create_from_image(color),ImageTexture.create_from_image(mask),ImageTexture.create_from_image(shape)]
	var pair := {"session_id":1,"logical_session_id":1,"generation":1,"frame_id":3,"pts_us":100000,
		"format_revision":1,"effect_revision":1,"model_generation":1,"slot_token":8,
		"color_texture_id":RenderingServer.texture_get_native_handle(textures[0].get_rid()),
		"alpha_texture_id":RenderingServer.texture_get_native_handle(textures[1].get_rid()),
		"portrait_texture_id":RenderingServer.texture_get_native_handle(textures[2].get_rid()),
		"width":320,"height":240,"input_width":320,"input_height":320,"alpha_width":640,"alpha_height":320,
		"rotation_degrees":0,"model_content_rect":[0,.125,1,.75],"stereo_sbs":false,
		"alpha_slot_token":8,"alpha_frame_id":3,"alpha_pts_us":100000,
		"portrait_slot_token":8,"portrait_frame_id":3,"portrait_pts_us":100000,
		"source_pts_verified":true,"immutable_color_frame":true,"pair_identity_verified":true,
		"alpha_fence_ready":true,"alpha_gpu_uploaded":true,"alpha_texture_format":"GL_R8_numeric"}
	var binding := Binding.new(); var base := ShaderMaterial.new(); base.shader = Binding.PAIR_SHADER
	check(binding.bind(base,pair),"Current frame and shape bind together")
	var portrait := Portrait.new(); portrait.automatic = false
	portrait.update(binding,panel,Vector2(2,1.5),Vector3(0,0,2))
	portrait.material.set_shader_parameter("portrait_relief",0.0)
	var flat := await frame(view)
	check(flat.get_pixel(160,120).a>.98 and flat.get_pixel(80,120).a<.01,"Original alpha keeps opaque body and transparent contour")
	var full_mask := mask.duplicate(); full_mask.fill(Color.WHITE); textures[1].update(full_mask)
	var clipped := await frame(view)
	check(clipped.get_pixel(160,194).a>.98 and clipped.get_pixel(160,197).a>.01 and clipped.get_pixel(160,197).a<.95,
		"Source-clipped body fades narrowly at the lower source edge")
	textures[1].update(mask)
	portrait.material.set_shader_parameter("portrait_distance",1.2)
	portrait.material.set_shader_parameter("portrait_relief",.18)
	var near_image := await frame(view)
	var max_error := 0.0
	for y in range(48,192,7):
		for x in range(110,210,5):
			var a := flat.get_pixel(x,y); var b := near_image.get_pixel(x,y)
			max_error = maxf(max_error,maxf(absf(a.r-b.r),maxf(absf(a.b-b.b),absf(a.a-b.a))))
	check(max_error < .025,"Reference-view colour and soft contour survive distance/relief changes")
	camera.position.x = .2
	var side := await frame(view)
	var pixels_per_metre := 240.0 / (2.0*tan(deg_to_rad(30.0)))
	var expected := -.2 / 1.02 * pixels_per_metre
	check(absf(centroid(side)-centroid(near_image)-expected)<2.0,"Actual moved camera projects geometric parallax")
	# Model crop outside the ROI remains transparent, rather than stretching a border texel.
	base.set_shader_parameter("model_content_rect",Vector4(-.5,0,2,1))
	binding.share_with(portrait.material,{},true)
	var cropped := await frame(view)
	check(cropped.get_pixel(280,120).a < .01,"ROI exterior is transparent")
	for key in ["portrait_frame_id","portrait_slot_token","portrait_pts_us"]:
		var wrong := pair.duplicate(true); wrong[key] += 1
		check(not Binding._valid(wrong),"Reject mismatched shape " + key)
	binding.unbind()
	check(not binding.portrait_rid.is_valid() and not binding.color_rid.is_valid() and not binding.alpha_rid.is_valid(),"Retirement detaches all native wrappers")
	panel.visible = false
	# Exercise the real viewer's material/geometry transitions, not only its mesh helper.
	var video := preload("res://scripts/mpv_video_display.gd").new(); view.add_child(video); video.set_process(false)
	video.view_camera = camera; video.geometry = 0; video.stereo_sbs = false; video.alpha_requested = true
	video._remember_file = false; video.flat_pose = Transform3D.IDENTITY; video._rvm_alpha = true
	video.media.format = {"width":320,"height":240}; video.media.last_pair = pair
	check(video._binding.bind(video.material,pair),"Viewer borrows the complete portrait lease")
	video._apply_geometry(); video.panel.visible = true
	check(video.portrait.active and video.panel.mesh == video.portrait.mesh and video.panel.material_override == video.portrait.material,"Viewer selects displaced mesh and portrait material")
	var reference: Vector3 = video.portrait.reference
	camera.position.x += .15; video._sync_portrait()
	check(video.portrait.reference == reference,"Head movement cannot recalibrate the source camera")
	video.screen_curve = .4; video._apply_geometry()
	check(not video.portrait.active and video.panel.mesh == video._curved and video.panel.material_override == video.material,"Curved screen falls back to the existing Alpha surface")
	video.screen_curve = 0; video._apply_geometry()
	check(video.portrait.active,"Returning to flat restores the mesh")
	video.geometry = 1; video._apply_geometry()
	check(not video.portrait.active and video.panel.mesh == video._hemisphere,"Leaving portrait preserves immersive geometry")
	video._binding.unbind(); video.free()
	var out := ProjectSettings.globalize_path("res://../../build/output/portrait-enhanced-20261028")
	DirAccess.make_dir_recursive_absolute(out)
	flat.save_png(out.path_join("portrait-reference.png")); side.save_png(out.path_join("portrait-side.png"))
	view.free()
	print("Video portrait GLES checks=%d failures=%d (desktop; XR and Android pending)" % [checks,failures.size()])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)
