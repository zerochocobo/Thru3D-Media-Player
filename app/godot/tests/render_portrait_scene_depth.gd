extends SceneTree
## Real desktop GLES rendering of the portrait mesh among an imported scene's blended surfaces:
## glass and leaves behind the person must stay behind, a blended surface in front still covers.
## Headsets (Adreno) skip the depth prepass; run once more with
## rendering/driver/depth_prepass/enable=false in an override.cfg to see their path on a desktop.
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
func quad(view: SubViewport, z: float, size: Vector2, offset: float, color: Color) -> MeshInstance3D:
	var node := MeshInstance3D.new(); var mesh := QuadMesh.new(); mesh.size = size; node.mesh = mesh
	var material := StandardMaterial3D.new(); material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA; material.albedo_color = color
	node.material_override = material; node.position = Vector3(offset, 0, z); view.add_child(node)
	return node
func difference(a: Color, b: Color) -> float:
	return maxf(absf(a.r-b.r), maxf(absf(a.g-b.g), absf(a.b-b.b)))
func run() -> void:
	var view := SubViewport.new(); view.size = Vector2i(320,240); view.own_world_3d = true
	view.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(view)
	var camera := Camera3D.new(); camera.position.z = 2; camera.fov = 60
	view.add_child(camera)
	# An opaque room wall far behind, as the scene's first pass.
	var wall := MeshInstance3D.new(); var wall_mesh := QuadMesh.new(); wall_mesh.size = Vector2(20,20); wall.mesh = wall_mesh
	var wall_material := StandardMaterial3D.new(); wall_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	wall_material.albedo_color = Color(.1,.1,.1); wall.material_override = wall_material; wall.position.z = -3; view.add_child(wall)
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
	check(portrait.material.next_pass == portrait.core and portrait.core.shader != null \
		and portrait.core.shader.code.contains("PORTRAIT_CORE"),"Portrait carries its opaque body pass")
	var alone := await frame(view)
	var body := Vector2i(160,120)
	var outside := Vector2i(30,120)
	# Glass right behind the person (inside the relief) and opaque-alpha leaves behind, both blended.
	var glass := quad(view, -.4, Vector2(6,6), 0, Color(1,0,0,.5))
	var leaves := quad(view, -.2, Vector2(.8,.8), 0, Color(0,0,1,1))
	var behind := await frame(view)
	check(difference(behind.get_pixel(body.x,body.y), alone.get_pixel(body.x,body.y)) < .03,
		"Blended glass and leaves behind the person stay behind the body")
	check(behind.get_pixel(outside.x,outside.y).r > .4,"Glass still shows beside the person")
	# The mask's solid core lands on about x 112..208, y 58..182 from the reference eye.
	var body_error := 0.0
	for y in range(66,176,5):
		for x in range(118,204,5):
			body_error = maxf(body_error,difference(behind.get_pixel(x,y),alone.get_pixel(x,y)))
	check(body_error < .03,"No part of the solid body shows the surfaces behind it (max %.3f)" % body_error)
	glass.free(); leaves.free()
	# A blended surface in front of the person still covers them.
	var front := quad(view, .6, Vector2(.3,.3), 0, Color(0,1,0,.5))
	var covered := await frame(view)
	var seen := covered.get_pixel(body.x,body.y); var original := alone.get_pixel(body.x,body.y)
	check(seen.g > original.g + .08 and seen.r < original.r - .05,"A blended surface in front still covers the person")
	front.free()
	# Reassigning the portrait material's uniforms reaches the opaque body on the next update.
	portrait.distance = 1.4
	portrait.update(binding,panel,Vector2(2,1.5),Vector3(0,0,2))
	check(is_equal_approx(float(portrait.core.get_shader_parameter("portrait_distance")),1.4),"Body pass follows the portrait distance")
	binding.unbind()
	var detached: Variant = RenderingServer.material_get_param(portrait.core.get_rid(),"color_texture")
	check(not (detached is RID and detached.is_valid()),"Retirement detaches the body pass's frame")
	var out := ProjectSettings.globalize_path("res://../../build/output/portrait-scene-depth")
	DirAccess.make_dir_recursive_absolute(out)
	alone.save_png(out.path_join("alone.png")); behind.save_png(out.path_join("behind.png")); covered.save_png(out.path_join("front.png"))
	view.free()
	print("Portrait scene depth GLES checks=%d failures=%d prepass=%s (desktop; XR and Android pending)" % [checks,failures.size(),
		ProjectSettings.get_setting("rendering/driver/depth_prepass/enable")])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)
