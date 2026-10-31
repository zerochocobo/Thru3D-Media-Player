extends SceneTree
## Real GL pixel regression for ordinary 2D / RVM / portrait color equivalence.
## Input is already display RGB, as required after MPV's HDR-to-SDR conversion.
## Android decoding, OES and HDR tone mapping itself require device validation.
const Binding := preload("res://scripts/pair_texture_binding.gd")
const Portrait := preload("res://scripts/video_portrait.gd")
var failures: Array[String] = []
var checks := 0

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func _initialize() -> void: call_deferred("run")

func sample(view: SubViewport) -> Color:
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	return view.get_texture().get_image().get_pixel(32, 32)

func difference(a: Color, b: Color) -> float:
	return maxf(maxf(absf(a.r-b.r), absf(a.g-b.g)), maxf(absf(a.b-b.b), absf(a.a-b.a)))

func run() -> void:
	var view := SubViewport.new(); view.size = Vector2i(64,64); view.own_world_3d = true
	view.transparent_bg = true; view.render_target_update_mode = SubViewport.UPDATE_ALWAYS; root.add_child(view)
	var camera := Camera3D.new(); camera.position.z = 2
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL; camera.size = 2; view.add_child(camera)
	var panel := MeshInstance3D.new(); view.add_child(panel)
	var colors := Image.create_empty(32,32,false,Image.FORMAT_RGBA8)
	var masks := Image.create_empty(64,32,false,Image.FORMAT_R8); masks.fill(Color.WHITE)
	var shapes := Image.create_empty(32,32,false,Image.FORMAT_R8); shapes.fill(Color(2.0/3.0,0,0))
	var textures := [ImageTexture.create_from_image(colors), ImageTexture.create_from_image(masks), ImageTexture.create_from_image(shapes)]
	var pair := {"session_id":1,"logical_session_id":1,"generation":1,"frame_id":3,"pts_us":100000,
		"format_revision":1,"effect_revision":1,"model_generation":1,"slot_token":8,
		"color_texture_id":RenderingServer.texture_get_native_handle(textures[0].get_rid()),
		"alpha_texture_id":RenderingServer.texture_get_native_handle(textures[1].get_rid()),
		"portrait_texture_id":RenderingServer.texture_get_native_handle(textures[2].get_rid()),
		"width":32,"height":32,"input_width":32,"input_height":32,"alpha_width":64,"alpha_height":32,
		"rotation_degrees":0,"model_content_rect":[0,0,1,1],"stereo_sbs":false,
		"alpha_slot_token":8,"alpha_frame_id":3,"alpha_pts_us":100000,
		"portrait_slot_token":8,"portrait_frame_id":3,"portrait_pts_us":100000,
		"source_pts_verified":true,"immutable_color_frame":true,"pair_identity_verified":true,
		"alpha_fence_ready":true,"alpha_gpu_uploaded":true,"alpha_texture_format":"GL_R8_numeric"}
	var binding := Binding.new(); var base := ShaderMaterial.new(); base.shader = Binding.PAIR_SHADER
	check(binding.bind(base,pair), "Native color/mask/shape lease binds")
	var portrait := Portrait.new(); portrait.automatic = false
	for swatch in [Color(.2,.2,.2), Color(.5,.5,.5), Color(.8,.8,.8), Color(.8,.3,.2), Color(.2,.6,.9)]:
		colors.fill(swatch); textures[0].update(colors)
		panel.mesh = QuadMesh.new(); panel.mesh.size = Vector2(2,2); panel.material_override = base
		base.set_shader_parameter("alpha_enabled",false)
		var opaque := await sample(view)
		check(difference(opaque,swatch) < .025, "Ordinary 2D keeps display RGB %s -> %s" % [swatch,opaque])
		base.set_shader_parameter("alpha_enabled",true)
		for alpha in [0.0,.5,1.0]:
			masks.fill(Color(alpha,0,0)); textures[1].update(masks)
			panel.mesh = QuadMesh.new(); panel.mesh.size = Vector2(2,2); panel.material_override = base
			var cutout := await sample(view)
			var expected := Color(opaque.r*alpha, opaque.g*alpha, opaque.b*alpha, alpha)
			check(difference(cutout,expected) < .009, "RVM changes opacity only: %s mask %.1f -> %s" % [swatch,alpha,cutout])
			portrait.update(binding,panel,Vector2(2,2),Vector3(0,0,2))
			for relief in [0.0,.18]:
				portrait.material.set_shader_parameter("portrait_relief",relief)
				var shaped := await sample(view)
				check(difference(shaped,cutout) < .009, "Portrait keeps RVM pixels: %s mask %.1f relief %.2f -> %s" % [swatch,alpha,relief,shaped])
		# Toggling back must restore exactly the same opaque source, not retain a color transform.
		panel.mesh = QuadMesh.new(); panel.mesh.size = Vector2(2,2); panel.material_override = base
		base.set_shader_parameter("alpha_enabled",false)
		check(difference(await sample(view),opaque) < .004, "Disabling Alpha restores original pixels")
	binding.unbind(); view.free()
	for failure in failures: push_error(failure)
	print("Video color paths GLES checks=%d failures=%d (desktop; Android HDR decoding not tested)" % [checks,failures.size()])
	quit(0 if failures.is_empty() else 1)
