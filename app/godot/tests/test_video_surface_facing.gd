extends SceneTree
const Facing := preload("res://scripts/surface_facing.gd")
const Binding := preload("res://scripts/pair_texture_binding.gd")
const Player := preload("res://scripts/mpv_video_display.gd")
const Host := preload("res://scripts/environments/private_beach_environment.gd")
const Mount := preload("res://scripts/environments/private_beach_video.gd")
var failures: Array[String] = []
var checks := 0
var output := ProjectSettings.globalize_path("res://../../build/output/beach-cinema/p1-video")
var viewport: SubViewport
var camera: Camera3D
var quad: MeshInstance3D
var backdrop: MeshInstance3D
var samples: Array = []

func _initialize() -> void: call_deferred("run")
func check(ok: bool,label: String) -> void:
	checks+=1
	if not ok: failures.append(label); printerr("BEACH_VIDEO_FAILED "+label)

func sample(name_: String,back := false) -> Color:
	camera.position=Vector3(0,0,-3 if back else 3); camera.look_at(Vector3.ZERO,Vector3.UP)
	backdrop.position.z=.5 if back else -.5
	for frame in 3: await process_frame
	await RenderingServer.frame_post_draw
	var img := viewport.get_texture().get_image(); img.save_png(output.path_join(name_+".png"))
	var color := img.get_pixel(32,32); samples.append({"name":name_,"rgba":[color.r,color.g,color.b,color.a]})
	return color

func run() -> void:
	DirAccess.make_dir_recursive_absolute(output)
	var player := Player.new()
	player.set_surface_front_only(true) # Deliberately before _ready creates materials.
	root.add_child(player); player.set_process(false)
	for material in [player.material,player._hole_material,player._alignment_border,player._subtitle_material]:
		check(material.shader.code.contains("cull_back") and not material.shader.code.contains("depth_test_disabled"),"Player missed a front-facing surface")
	player.set_surface_front_only(false)
	check(player.material.shader==Binding.PAIR_SHADER,"Player did not restore canonical shader")
	var material := ShaderMaterial.new(); material.shader=Binding.PAIR_SHADER
	material.set_shader_parameter("sharpness",.37); material.set_shader_parameter("stereo_offset",Vector2(.02,.03))
	Facing.apply(material,true)
	var first := material.shader
	check(Facing.source(first)==Binding.PAIR_SHADER,"Derived shader lost canonical identity")
	Facing.apply(material,true); check(material.shader==first,"Repeated toggle rebuilt shader")
	check(is_equal_approx(float(material.get_shader_parameter("sharpness")),.37),"Toggle lost sharpness")
	Binding._use_shader(material,Binding.DECODER_SHADER)
	check(Facing.source(material.shader)==Binding.DECODER_SHADER and material.shader.code.contains("cull_back"),"External texture switch lost culling")
	var binding := Binding.new(); binding.material=material
	var consumer := ShaderMaterial.new(); Facing.apply(consumer,true)
	binding.share_with(consumer,{"sharpness":.37},true)
	check(Facing.source(consumer.shader)==Binding.PORTRAIT_DECODER_SHADER,"Portrait selected RGBA for external source")
	binding.unshare(consumer); binding.material=null
	Binding._use_shader(material,Binding.PAIR_SHADER)
	check(material.shader==first,"RGBA switch did not reuse front shader")
	Facing.apply(material,false)
	check(material.shader==Binding.PAIR_SHADER and material.get_shader_parameter("stereo_offset")==Vector2(.02,.03),"Restoring facing lost source/uniforms")
	var host := Host.new(); root.add_child(host); host.prepare()
	while host.loading: await process_frame
	player.media.format.width=256; player.media.format.height=144
	player.screen_scale=1.4; player.screen_curve=.35; player.curve_radius=6; player.screen_rotation=12
	player._apply_geometry()
	var mount := Mount.new(); var old_pose: Transform3D = player.flat_pose
	var old_scale: float = player.screen_scale
	check(mount.sync(host,player,.8),"Could not mount existing player surface")
	check(player._surface_front_only and player.screen_curve==0,"Mounted player lost physical screen policy")
	check(player.panel.global_position.is_equal_approx(host.screen_layout.center+host.screen_layout.normal*.035),"Mounted surface does not match screen transform")
	check(player._flat.size.x<=20 and mount.picture_fraction<=.641,"Picture fit exceeded requested frame")
	check(host.request_screen({"width":3,"yaw_degrees":15,"pitch_degrees":8}),"Mount resize setup failed")
	while host.screen_loading: await process_frame
	check(mount.sync(host,player,.8),"Could not follow resized screen")
	check(player._flat.size.is_equal_approx(Vector2(2.4,1.35)),"Requested picture fraction did not resize actual video mesh")
	check(player.panel.global_basis.y.is_equal_approx(host.screen_layout.up),"Video ignored physical pitch")
	check(mount._front.material_override==mount._matte,"New screen lost black letterbox mat")
	player.scale=Vector3(-1,1,1); player.position=Vector3(3,.5,2)
	check(mount.sync(host,player,.8) and player.panel.global_basis.determinant()>0,"Parent negative scale inverted physical screen front")
	check(player.panel.global_position.is_equal_approx(host.screen_layout.center+host.screen_layout.normal*.035),"Parent transform displaced mounted video")
	if DisplayServer.get_name()!="headless": await mounted_views(host,player)
	mount.detach()
	check(player.flat_pose.is_equal_approx(old_pose) and is_equal_approx(player.screen_scale,old_scale) and not player._surface_front_only,"Detaching changed ordinary placement/preferences")
	check(is_equal_approx(player.screen_curve,.35) and is_equal_approx(player.curve_radius,6) and is_equal_approx(player.screen_rotation,12),"Detach failed to restore curved/rotated screen preferences")
	host.free(); player.free()
	if DisplayServer.get_name()!="headless": await render_checks(material)
	var report := {"checks":checks,"failures":failures,"samples":samples,
		"scope":"Actual player material setup, existing shader/native texture binding and desktop face/hole rendering; no external EGLImage or XR compositor execution."}
	var file := FileAccess.open(output.path_join("checks-headless.json" if DisplayServer.get_name()=="headless" else "checks-render.json"),FileAccess.WRITE)
	file.store_string(JSON.stringify(report,"\t")); print("BEACH_VIDEO_FACING ",JSON.stringify(report))
	quit(0 if failures.is_empty() else 1)

func mounted_views(host: Node3D,player: Node3D) -> void:
	# A diagnostic image through the actual player material, not a decoded movie.
	root.size=Vector2i(960,600); root.msaa_3d=Viewport.MSAA_4X
	var picture := Image.create(256,144,false,Image.FORMAT_RGBA8)
	var colors := [Color(.8,.08,.03),Color(.05,.7,.1),Color(.05,.12,.85),Color(.8,.7,.05)]
	for y in 144:
		for x in 256: picture.set_pixel(x,y,colors[x/64]*(1.0 if y<72 else .5))
	var texture := ImageTexture.create_from_image(picture)
	player.material.set_shader_parameter("color_texture",texture)
	player.material.set_shader_parameter("alpha_enabled",false)
	player.panel.visible=true; host.set_presented(true)
	var world := WorldEnvironment.new(); world.environment=host.background_environment; root.add_child(world)
	var view := Camera3D.new(); view.keep_aspect=Camera3D.KEEP_WIDTH; view.fov=80; view.far=2500; view.current=true; root.add_child(view)
	for side in [1.0,-1.0]:
		view.position=host.screen_layout.center+host.screen_layout.normal*5
		if side<0: view.position=host.screen_layout.center-host.screen_layout.normal*5
		view.look_at(host.screen_layout.center,Vector3.UP)
		for frame in 4: await process_frame
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(output.path_join("mounted-front.png" if side>0 else "mounted-back.png"))
	view.free(); world.free()

func render_checks(material: ShaderMaterial) -> void:
	viewport=SubViewport.new(); viewport.size=Vector2i(64,64); viewport.own_world_3d=true; viewport.transparent_bg=true
	viewport.render_target_update_mode=SubViewport.UPDATE_ALWAYS; root.add_child(viewport)
	camera=Camera3D.new(); camera.projection=Camera3D.PROJECTION_ORTHOGONAL; camera.size=2; viewport.add_child(camera)
	quad=MeshInstance3D.new(); var mesh := QuadMesh.new(); mesh.size=Vector2(2,2); quad.mesh=mesh
	quad.material_override=material; viewport.add_child(quad)
	backdrop=MeshInstance3D.new(); var box := BoxMesh.new(); box.size=Vector3(4,4,.1); backdrop.mesh=box
	var blue := StandardMaterial3D.new(); blue.shading_mode=BaseMaterial3D.SHADING_MODE_UNSHADED; blue.albedo_color=Color(.1,.3,.7)
	backdrop.material_override=blue; viewport.add_child(backdrop)
	var rgb := Image.create(16,16,false,Image.FORMAT_RGBA8); rgb.fill(Color(.8,.2,.05))
	var alpha := Image.create(32,16,false,Image.FORMAT_R8); alpha.fill(Color.WHITE)
	var rgb_owner := ImageTexture.create_from_image(rgb); var alpha_owner := ImageTexture.create_from_image(alpha)
	await RenderingServer.frame_post_draw
	var pair := {"session_id":1,"logical_session_id":1,"generation":1,"frame_id":7,"pts_us":233333,
		"format_revision":2,"effect_revision":2,"model_generation":3,"slot_token":8,
		"color_texture_id":RenderingServer.texture_get_native_handle(rgb_owner.get_rid()),
		"alpha_texture_id":RenderingServer.texture_get_native_handle(alpha_owner.get_rid()),
		"width":16,"height":16,"input_width":16,"input_height":16,"alpha_width":32,"alpha_height":16,
		"rotation_degrees":0,"model_content_rect":[0,0,1,1],"stereo_sbs":false,"alpha_slot_token":8,
		"alpha_frame_id":7,"alpha_pts_us":233333,"source_pts_verified":true,"immutable_color_frame":true,
		"pair_identity_verified":true,"alpha_fence_ready":true,"alpha_gpu_uploaded":true,"alpha_texture_format":"GL_R8_numeric"}
	var binding := Binding.new()
	check(binding.bind(material,pair),"Actual native texture bind failed")
	material.set_shader_parameter("alpha_enabled",false); material.set_shader_parameter("sharpness",0)
	var ordinary := await sample("ordinary-front")
	Facing.apply(material,true)
	check(RenderingServer.material_get_param(material.get_rid(),"color_texture")==binding.color_rid,"Face toggle lost native texture lease")
	var front := await sample("beach-front")
	check(front.is_equal_approx(ordinary),"Front-facing variant changed picture pixels")
	var back := await sample("beach-back",true)
	check(back.b>back.r and back.a>.95,"Back face displayed mirrored movie")
	Facing.apply(material,false)
	var restored := await sample("ordinary-back",true)
	check(restored.is_equal_approx(ordinary),"Ordinary back face not restored")
	for cycle in 3:
		binding.unbind(); Facing.apply(material,true)
		check(binding.bind(material,pair) and material.shader.code.contains("cull_back"),"Next frame lost culling or native ownership")
	var secondary := ShaderMaterial.new(); binding.share_with(secondary)
	check(secondary.shader==Binding.PAIR_SHADER,"Beach facing leaked into ordinary shared picture")
	binding.unshare(secondary); binding.unbind()
	check(RenderingServer.material_get_param(material.get_rid(),"color_texture")==null,"Unbind retained borrowed texture")
	var hole := ShaderMaterial.new(); hole.shader=load("res://shaders/video_layer_hole.gdshader"); Facing.apply(hole,true)
	quad.material_override=hole
	var hole_front := await sample("hole-front")
	var hole_back := await sample("hole-back",true)
	check(hole_front.a<.05 and hole_back.a>.95,"Hole did not clear front only")
	# A foreground object must cover the hole; shader still performs depth tests.
	var block := MeshInstance3D.new(); var cube := BoxMesh.new(); cube.size=Vector3(.5,.5,.1); block.mesh=cube; block.position.z=.2
	var red := StandardMaterial3D.new(); red.shading_mode=BaseMaterial3D.SHADING_MODE_UNSHADED; red.albedo_color=Color(1,0,0)
	block.material_override=red; viewport.add_child(block)
	var occluded := await sample("hole-occluded")
	check(occluded.r>.9 and occluded.a>.95,"Hole erased foreground geometry")
	viewport.free()
