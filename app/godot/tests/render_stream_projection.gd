extends SceneTree
const StreamProjection :=  preload("res://scripts/stream_projection.gd")
var failures: Array[String] = []
var checks := 0
func _initialize() -> void: run.call_deferred()
func check(value: bool, message: String) -> void:
	checks += 1
	if not value: failures.append(message)

func oracle(mesh: ArrayMesh, direction: Vector3, eye: int) -> Vector2:
	var a := mesh.surface_get_arrays(0)
	var vertices: PackedVector3Array = a[Mesh.ARRAY_VERTEX]
	var indices: PackedInt32Array = a[Mesh.ARRAY_INDEX]
	var colors: PackedColorArray = a[Mesh.ARRAY_COLOR]
	var uv: PackedVector2Array = a[Mesh.ARRAY_TEX_UV]
	for i in range(0, indices.size(), 3):
		var x := indices[i]; var y := indices[i+1]; var z := indices[i+2]
		if roundi(colors[x].r) != eye: continue
		var hit: Variant = Geometry3D.ray_intersects_triangle(Vector3.ZERO, direction, vertices[x], vertices[y], vertices[z])
		if hit == null: continue
		var weight := Geometry3D.get_triangle_barycentric_coords(hit, vertices[x], vertices[y], vertices[z])
		return uv[x]*weight.x+uv[y]*weight.y+uv[z]*weight.z
	return Vector2(-1, -1)

func run() -> void:
	var input := ProjectSettings.globalize_path("res://../../android/player-plugin/build/test-projection")
	var output := ProjectSettings.globalize_path("res://../../build/output/stream-projection-render")
	DirAccess.make_dir_recursive_absolute(output)
	var vp := SubViewport.new(); vp.size = Vector2i(257,257); vp.own_world_3d = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS; root.add_child(vp)
	var camera := Camera3D.new(); camera.fov = 70; vp.add_child(camera)
	var surface := MeshInstance3D.new(); vp.add_child(surface)
	for file in ["youtube-vr180-avc.mp4", "youtube-vr180-av1.mp4", "youtube-vr180-vp9.webm", "youtube-eac-vp9.webm", "eac-synthetic-lr", "eac-synthetic-tb", "eac-synthetic-custom"]:
		var fixture: String = "youtube-eac-vp9.webm" if file.begins_with("eac-synthetic") else file
		var data: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(input.path_join(fixture + ".json")))
		if file.begins_with("eac-synthetic"):
			data.stereo_mode = 1 if file.ends_with("tb") else 3 if file.ends_with("custom") else 2
			if data.stereo_mode == 3:
				data.meshes.append(data.meshes[0].duplicate(true))
				for eye in 2:
					for i in range(3, data.meshes[eye].vertices.size(), 5):
						data.meshes[eye].vertices[i] = (float(data.meshes[eye].vertices[i])+eye)*0.5
		var mesh := StreamProjection.mesh(data); surface.mesh = mesh
		var stereo := StreamProjection.stereo(data)
		var tb: bool = int(data.stereo_mode) == 1
		var texture_image := Image.create(1024,512,false,Image.FORMAT_RGB8)
		for y in 512:
			for x in 1024:
				texture_image.set_pixel(x,y,Color(float(x % (512 if stereo and not tb else 1024))/(512 if stereo and not tb else 1024),float(y % (256 if tb else 512))/(256 if tb else 512),0.8 if stereo and (y>=256 if tb else x>=512) else 0.2))
		var texture := ImageTexture.create_from_image(texture_image)
		for pipeline in ["video_rvm_pair", "video_rvm_pair_oes"]:
			var shader := Shader.new()
			shader.code = FileAccess.get_file_as_string("res://shaders/"+pipeline+".gdshader").replace("samplerExternalOES", "sampler2D")
			var material := ShaderMaterial.new(); material.shader = shader; surface.material_override = material
			material.set_shader_parameter("color_texture", texture); material.set_shader_parameter("alpha_enabled", false)
			material.set_shader_parameter("projection_mesh",true); material.set_shader_parameter("video_geometry",int(data.geometry))
			material.set_shader_parameter("top_bottom",tb); material.set_shader_parameter("projection_uv_packed",int(data.stereo_mode)==3)
			material.set_shader_parameter("stereo_sbs",stereo); material.set_shader_parameter("sharpness",0.5)
			material.set_shader_parameter("source_size",Vector2(1024,512))
			for eye in (2 if stereo else 1):
				material.set_shader_parameter("viewing_eye",eye+1)
				var directions := [Vector2(-40,0),Vector2.ZERO,Vector2(40,0)]
				if data.geometry == 3:
					directions = [Vector2(-90,0),Vector2.ZERO,Vector2(90,0),Vector2(180,0),Vector2(0,90),Vector2(0,-90),Vector2(45,30),Vector2(-45,-30)]
				for direction in directions:
					camera.rotation = Vector3(deg_to_rad(direction.y),deg_to_rad(direction.x),0)
					await RenderingServer.frame_post_draw; await RenderingServer.frame_post_draw
					var rendered := vp.get_texture().get_image()
					var center := rendered.get_pixel(128,128)
					var expected := oracle(mesh,-camera.basis.z,eye)
					if int(data.stereo_mode)==3: expected.x=expected.x*2-eye
					var label := str([file,pipeline,eye,direction])
					check(expected.x>=0,"Reference ray intersects "+label)
					check(absf(center.r-expected.x)<0.035 and absf(center.g-expected.y)<0.035,"GPU UV matches independent triangle ray "+label+str([center,expected]))
					check(absf(center.b-(0.8 if eye==1 else 0.2))<0.03,"Eye isolation "+label)
					if direction == Vector2.ZERO: rendered.save_png(output.path_join(file+"-"+pipeline+"-eye%d.png"%eye))
	FileAccess.open(output.path_join("verification.json"),FileAccess.WRITE).store_string(JSON.stringify({"checks":checks,"failures":failures},"\t"))
	vp.free()
	for failure in failures: push_error(failure)
	print("Stream projection render checks=%d failures=%d"%[checks,failures.size()])
	quit(0 if failures.is_empty() else 1)
