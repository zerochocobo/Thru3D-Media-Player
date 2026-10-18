extends SceneTree
const Geometry := preload("res://scripts/puzzle/puzzle_geometry.gd")
const Piece := preload("res://scripts/puzzle/puzzle_piece.gd")
var viewport: SubViewport
var camera: Camera3D
var piece: MeshInstance3D
var checks := 0
var failures: Array[String] = []
var output := ProjectSettings.globalize_path("res://../../build/output/puzzle-p0/render")

func _initialize() -> void: call_deferred("_run")
func check(ok: bool, message: String) -> void:
	checks+=1
	if not ok: failures.append(message); push_error(message)

func image_pair() -> Image:
	var image := Image.create(512,160,false,Image.FORMAT_RGB8)
	for eye in 2:
		for y in 160:
			for x in 256:
				var color := Color(0.08+0.15*float(y)/160,0.3+0.35*float(y)/160,0.7)
				if y>94: color=Color(0.14,0.42,0.23)
				if Vector2(x-(119+eye*18),y-76).length()<37: color=Color(0.92,0.45,0.13)
				if x%38<2 or y%32<2: color=color.lightened(0.14)
				image.set_pixel(x+eye*256,y,color)
	return image

func capture(name_value: String) -> Image:
	await process_frame
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var image := viewport.get_texture().get_image()
	image.save_png(output.path_join(name_value+".png")); return image

func changed_pixels(a: Image,b: Image) -> int:
	var count := 0
	for y in range(80,640,2):
		for x in range(120,900,2):
			var difference := a.get_pixel(x,y)-b.get_pixel(x,y)
			if maxf(absf(difference.r),maxf(absf(difference.g),absf(difference.b)))>0.04: count+=1
	return count

func _run() -> void:
	DirAccess.make_dir_recursive_absolute(output)
	viewport=SubViewport.new(); viewport.size=Vector2i(1024,720); viewport.own_world_3d=true
	viewport.render_target_update_mode=SubViewport.UPDATE_ALWAYS; root.add_child(viewport)
	var world := WorldEnvironment.new(); world.environment=Environment.new()
	world.environment.background_mode=Environment.BG_COLOR; world.environment.background_color=Color(0.025,0.035,0.05)
	viewport.add_child(world)
	camera=Camera3D.new(); viewport.add_child(camera); camera.position=Vector3(0.52,0.2,0.75); camera.look_at(Vector3.ZERO)
	var pair := image_pair()
	var mono := pair.get_region(Rect2i(0,0,256,160)); mono.generate_mipmaps()
	var texture := ImageTexture.create_from_image(mono)
	piece=Piece.new(); viewport.add_child(piece)
	piece.configure(0,Geometry.flat(Vector2i(1,1),Vector2i(3,3),Vector2(1.8,1.2),{"thickness":0.025}),{"texture":texture})
	var flat := await capture("01-flat-thickness")
	var body_pixels := 0
	for y in range(100,620,2):
		for x in range(120,900,2):
			var p := flat.get_pixel(x,y)
			if p.r>0.18 and p.r<0.78 and p.g>0.15 and p.b>0.12 and p.r>p.g and p.g>p.b: body_pixels+=1
	check(body_pixels>60,"Visible physical sidewall has real pixels")
	var depth := Image.create(64,40,false,Image.FORMAT_RF)
	for y in 40:
		for x in 64:
			var value := maxf(0,1-Vector2(float(x)/64-0.5,float(y)/40-0.5).length()*3)
			depth.set_pixel(x,y,Color(value,0,0))
	piece.configure(0,Geometry.flat(Vector2i(1,1),Vector2i(3,3),Vector2(1.8,1.2),{"depth":depth,"relief":0.04,"thickness":0.025}),{"texture":texture})
	var relief := await capture("02-relief")
	check(changed_pixels(flat,relief)>500,"Relief moves the actual rendered surface, without extra eye-shift shader")
	pair.generate_mipmaps()
	piece.configure(0,Geometry.flat(Vector2i.ZERO,Vector2i.ONE,Vector2(0.8,0.5)),
		{"texture":ImageTexture.create_from_image(pair),"layout":1,"kind":"stereo"})
	camera.position=Vector3(0.18,0.08,1.0); camera.look_at(Vector3.ZERO)
	piece.material_override.set_shader_parameter("test_eye",0)
	var left := await capture("03-spatial-left")
	piece.material_override.set_shader_parameter("test_eye",1)
	var right := await capture("04-spatial-right")
	check(changed_pixels(left,right)>800,"Native left and right eye textures remain separate")
	piece.material_override.set_shader_parameter("swap_eyes",true)
	var swapped := await capture("05-spatial-swapped")
	check(changed_pixels(left,swapped)<10,"Eye swap reproduces the opposite eye without recropping each piece")
	var top_bottom := Image.create(256,320,false,Image.FORMAT_RGB8)
	top_bottom.blit_rect(pair,Rect2i(0,0,256,160),Vector2i.ZERO)
	top_bottom.blit_rect(pair,Rect2i(256,0,256,160),Vector2i(0,160)); top_bottom.generate_mipmaps()
	piece.configure(0,Geometry.flat(Vector2i.ZERO,Vector2i.ONE,Vector2(0.8,0.5)),
		{"texture":ImageTexture.create_from_image(top_bottom),"layout":2,"kind":"stereo"})
	piece.material_override.set_shader_parameter("test_eye",0)
	check(changed_pixels(left,await capture("07-top-bottom-left"))<10,"Top/bottom left eye matches its side-by-side equivalent")
	piece.material_override.set_shader_parameter("test_eye",1)
	check(changed_pixels(right,await capture("08-top-bottom-right"))<10,"Top/bottom right eye matches its side-by-side equivalent")
	piece.configure(0,Geometry.shell(Rect2(0.44,0.38,0.12,0.2),2.5,0.025),{"texture":texture})
	camera.position=Vector3(0.65,0.3,2.0); camera.look_at(Vector3.ZERO)
	await capture("06-curved-shell")
	var report := {"checks":checks,"failures":failures,"body_pixels":body_pixels,"relief_changed_pixels":changed_pixels(flat,relief),
		"stereo_changed_pixels":changed_pixels(left,right),"limits":"Desktop eye override and synthetic fixtures; headset comfort and runtime multiview not validated."}
	FileAccess.open(output.path_join("report.json"),FileAccess.WRITE).store_string(JSON.stringify(report,"\t"))
	print("Puzzle render: %d checks, %d failures" % [checks,failures.size()])
	quit(0 if failures.is_empty() else 1)
