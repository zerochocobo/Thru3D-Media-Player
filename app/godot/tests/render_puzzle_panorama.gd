extends SceneTree
const Sphere := preload("res://scripts/puzzle/puzzle_sphere.gd")
const Session := preload("res://scripts/puzzle/puzzle_session.gd")
const Piece := preload("res://scripts/puzzle/puzzle_piece.gd")
const Geometry := preload("res://scripts/video_geometry.gd")
const SkyEnvironment := preload("res://scripts/puzzle/puzzle_sky.gd")
const PuzzlePanel := preload("res://scripts/puzzle/puzzle_panel.gd")
const I18n := preload("res://scripts/i18n.gd")
var checks := 0
var failures: Array[String]=[]
var viewport: SubViewport
var camera: Camera3D
var output := ProjectSettings.globalize_path("res://../../build/output/puzzle-p2/render")
func _initialize() -> void: call_deferred("_run")
func check(ok: bool, message: String) -> void:
	checks+=1
	if not ok: failures.append(message); push_error(message)
func capture(name_value: String) -> Image:
	await process_frame; await RenderingServer.frame_post_draw; await RenderingServer.frame_post_draw
	var image := viewport.get_texture().get_image(); image.save_png(output.path_join(name_value+".png")); return image
func difference(a: Image,b: Image) -> float:
	var sum := 0.0; var count := 0
	for y in range(30,738,3):
		for x in range(30,994,3):
			var delta := a.get_pixel(x,y)-b.get_pixel(x,y)
			sum+=maxf(absf(delta.r),maxf(absf(delta.g),absf(delta.b))); count+=1
	return sum/count
func _run() -> void:
	DirAccess.make_dir_recursive_absolute(output)
	viewport=SubViewport.new(); viewport.size=Vector2i(1024,768); viewport.own_world_3d=true
	viewport.render_target_update_mode=SubViewport.UPDATE_ALWAYS; root.add_child(viewport)
	var world := WorldEnvironment.new(); world.environment=Environment.new(); world.environment.background_mode=Environment.BG_COLOR
	world.environment.background_color=Color(0.015,0.022,0.03); viewport.add_child(world)
	camera=Camera3D.new(); viewport.add_child(camera); camera.fov=85
	var image := Image.create(1024,512,false,Image.FORMAT_RGBA8)
	for y in 512:
		for x in 1024:
			var d := Vector3(sin((float(x)/1024-0.5)*TAU)*sin(float(y)/512*PI),cos(float(y)/512*PI),-cos((float(x)/1024-0.5)*TAU)*sin(float(y)/512*PI))
			var color := Color(0.38+d.x*0.22,0.42+d.y*0.24,0.45+d.z*0.25)
			if (x%128<4 or y%128<4) and y>24 and y<488: color=color.lightened(0.15)
			image.set_pixel(x,y,color)
	image.generate_mipmaps()
	var texture := ImageTexture.create_from_image(image)
	var source := {"image":image,"texture":texture,"size":Vector2(1024,512),"projection":"sphere"}
	var session := Session.new(); viewport.add_child(session); session.configure(source,Vector2i(12,2))
	for piece in session.pieces: piece.visible=true; piece.placed=true; piece.transform=piece.goal
	session.sky.guide.visible=false
	var reference := MeshInstance3D.new(); reference.mesh=SkyEnvironment.inside_mesh(Sphere.RADIUS,128,64); viewport.add_child(reference)
	var material := ShaderMaterial.new(); material.shader=preload("res://shaders/puzzle_piece.gdshader"); material.set_shader_parameter("image_texture",texture)
	reference.material_override=material; reference.visible=false
	var metrics := {}
	for face in 6:
		camera.look_at(Sphere.CENTRES[face],Sphere.UPS[face])
		var composed := await capture("01-completed-%d" % face)
		session.visible=false; reference.visible=true
		var expected := await capture("02-reference-%d" % face)
		var error := difference(composed,expected); metrics[str(face)]=error
		check(error<0.028,"Completed cube sky matches the source panorama for direction %d (error %.4f)" % [face,error])
		session.visible=true; reference.visible=false
	for piece in session.pieces: piece.placed=false
	session.sky.guide.visible=true; session.scatter(false); camera.look_at(Vector3(0,-0.35,-1))
	var seated := await capture("03-seated-night")
	session.cycle_backdrop(); var slate := await capture("04-seated-slate")
	session.cycle_backdrop(); var light := await capture("05-seated-light")
	check(difference(seated,slate)>0.03 and difference(slate,light)>0.1,"Contrast backgrounds visibly change the unfinished sky")
	session.scatter(true); camera.look_at(Vector3.RIGHT); await capture("06-standing-side")
	session.visible=false
	var piece := Piece.new(); viewport.add_child(piece); piece.configure(0,Sphere.patch(Vector2i(0,0),Vector2i(12,2)),source); piece.scale=Vector3.ONE*0.32
	camera.position=Vector3(0.46,0.25,0.78); camera.look_at(Vector3.ZERO)
	var thickness := await capture("07-curved-thickness")
	var body_pixels := 0
	for y in range(50,718,2):
		for x in range(50,974,2):
			var p := thickness.get_pixel(x,y)
			if p.r>p.g*1.12 and p.g>p.b*1.12 and p.r>0.16: body_pixels+=1
	check(body_pixels>30,"The curved tile's solid sidewall has actual rendered pixels")
	piece.visible=false
	var pair := Node3D.new(); viewport.add_child(pair); pair.scale=Vector3.ONE*0.35
	var neighbours := []
	for x in 2:
		var patch := Sphere.patch(Vector2i(x,0),Vector2i(12,2))
		var neighbour := Piece.new(); pair.add_child(neighbour); neighbour.configure(x,patch,source)
		neighbour.transform=patch.goal; neighbour.position.x+=(-0.12 if x==0 else 0.12); neighbours.append(neighbour)
	camera.position=Vector3(0,0.30,0.40); camera.look_at(Vector3(0,0.30,-0.7))
	var apart := await capture("10-interlocking-pair")
	for neighbour in neighbours: neighbour.transform=Sphere.patch(Vector2i(neighbour.piece_id,0),Vector2i(12,2)).goal
	var joined := await capture("11-pair-joined")
	check(difference(apart,joined)>0.005,"Matching traditional tabs and sockets visibly close when joined")
	pair.visible=false
	var panel := PuzzlePanel.new(); viewport.add_child(panel); panel.position=Vector3.ZERO; panel.visible=true; panel.spherical=true; panel.count=8; panel.total=24; panel.status="Saved"
	camera.position=Vector3(0,0,2); camera.basis=Basis.IDENTITY; camera.projection=Camera3D.PROJECTION_ORTHOGONAL; camera.size=0.78
	for language in ["zh","en","ja"]:
		I18n.use(language); panel.refresh(); await capture("08-game-"+language)
	I18n.use("zh"); panel.mode="sky"; panel.refresh(); await capture("09-sky-controls")
	check(panel._buttons.any(func(b):return b.target==44) and panel._buttons.any(func(b):return b.target==45),"Sky controls expose top and bottom without overhead reach")
	var file := FileAccess.open(output.path_join("report.json"),FileAccess.WRITE)
	file.store_string(JSON.stringify({"image_error_by_view":metrics,"sidewall_pixels":body_pixels,"checks":checks,"failures":failures},"\t")); file.close()
	viewport.queue_free(); await process_frame
	print("Puzzle panorama render: %d checks, %d failures" % [checks,failures.size()]); quit(0 if failures.is_empty() else 1)
