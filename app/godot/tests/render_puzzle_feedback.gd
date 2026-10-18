extends SceneTree
const Fireworks := preload("res://scripts/puzzle/puzzle_fireworks.gd")
const Session := preload("res://scripts/puzzle/puzzle_session.gd")
const PuzzlePanel := preload("res://scripts/puzzle/puzzle_panel.gd")
const I18n := preload("res://scripts/i18n.gd")
var checks := 0
var failures: Array[String]=[]
var output := ProjectSettings.globalize_path("res://../../build/output/puzzle-feedback/render")
var viewport: SubViewport
func _initialize() -> void: call_deferred("_run")
func check(ok: bool, message: String) -> void:
	checks+=1
	if not ok: failures.append(message); push_error(message)
func frame(name_value: String) -> Image:
	await process_frame; await RenderingServer.frame_post_draw; await RenderingServer.frame_post_draw
	var picture := viewport.get_texture().get_image(); picture.save_png(output.path_join(name_value+".png")); return picture
func difference(a: Image,b: Image) -> int:
	var changed := 0
	for y in a.get_height():
		for x in a.get_width():
			var one := a.get_pixel(x,y); var two := b.get_pixel(x,y)
			if absf(one.r-two.r)+absf(one.g-two.g)+absf(one.b-two.b)>0.12: changed+=1
	return changed
func _run() -> void:
	DirAccess.make_dir_recursive_absolute(output); I18n.use("zh")
	viewport=SubViewport.new(); viewport.size=Vector2i(1280,960); viewport.own_world_3d=true; viewport.render_target_update_mode=SubViewport.UPDATE_ALWAYS; root.add_child(viewport)
	var environment := WorldEnvironment.new(); environment.environment=Environment.new(); environment.environment.background_mode=Environment.BG_COLOR; environment.environment.background_color=Color(0.02,0.025,0.04); viewport.add_child(environment)
	var camera := Camera3D.new(); camera.position=Vector3(0,1.6,0); camera.fov=90; viewport.add_child(camera)
	var image := Image.create(320,160,false,Image.FORMAT_RGB8)
	for y in 160:
		for x in 320: image.set_pixel(x,y,Color(0.25+float(x)/700,0.35+float(y)/500,0.52))
	for spherical in [false,true]:
		var prefix := "pano-" if spherical else "flat-"
		var source := {"texture":ImageTexture.create_from_image(image),"size":Vector2(320,160),"projection":"sphere" if spherical else "flat"}
		var session := Session.new(); viewport.add_child(session); session.configure(source,Session.grid_for_source(source,24)); session.global_position=camera.global_position+(Vector3.ZERO if spherical else Vector3.FORWARD*1.8)
		for piece in session.pieces: piece.stop_motion(); piece.placed=true; piece.visible=true; piece.transform=piece.goal
		var panel := PuzzlePanel.new(); viewport.add_child(panel); panel.mode="complete"; panel.count=24; panel.total=24; panel.visible=true; panel.refresh()
		panel.global_transform=Transform3D(Basis.IDENTITY,camera.global_position+Vector3(0,-0.50,-1.8)) if spherical else session.menu_anchor(0.28)
		var effect := Fireworks.new(); viewport.add_child(effect)
		effect.configure(camera.global_transform,null,session.global_position if spherical else null,null if spherical else session.frame_world_pose(),session.board_size)
		effect.set_process(false); effect.mesh.visible=false
		var baseline := await frame(prefix+"00-finished")
		effect.mesh.visible=true; effect.sample(0.20); var ascent := await frame(prefix+"01-ascent")
		check(difference(baseline,ascent)>20,"Rocket ascent is visible in the actual 3D renderer: "+prefix)
		effect.sample(1.05); var burst := await frame(prefix+"02-fireworks")
		var pixels := difference(baseline,burst)
		check(pixels>250 and pixels<1280*960/12,"Fireworks are visible without becoming a full-view flash: "+prefix)
		camera.position.x+=0.12; await frame(prefix+"03-side-view"); camera.position.x-=0.12
		effect.sample(2.49); var ended := await frame(prefix+"04-faded")
		check(difference(baseline,ended)<10,"Every real rendered spark fades away: "+prefix)
		print(prefix+" changed spark pixels=",pixels)
		effect.queue_free(); panel.queue_free(); session.queue_free(); await process_frame
	viewport.queue_free(); await process_frame
	print("Puzzle feedback render: %d checks, %d failures" % [checks,failures.size()]); quit(0 if failures.is_empty() else 1)
