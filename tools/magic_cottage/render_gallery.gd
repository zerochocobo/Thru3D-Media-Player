extends SceneTree
## Contact sheets are rendered by the same mesh generator, shaders and book used in VR.
const Workshop := preload("res://environments/magic_cottage/workshop.gd")
const Plant := preload("res://environments/magic_cottage/specimen.gd")
var out: String
var camera:=Camera3D.new()

func _initialize() -> void:
	run.call_deferred()

func photo(file: String) -> void:
	await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_jpg(out+"/"+file+".jpg",.93)

func run() -> void:
	out=OS.get_cmdline_user_args()[0]
	var world:=WorldEnvironment.new()
	world.environment=Environment.new()
	world.environment.background_mode=Environment.BG_COLOR
	world.environment.background_color=Color("#1a1721")
	world.environment.ambient_light_source=Environment.AMBIENT_SOURCE_COLOR
	world.environment.ambient_light_color=Color("#ffeddd")
	world.environment.ambient_light_energy=.55
	root.add_child(world)
	var w:=Workshop.new()
	w.archive.directory=""
	root.add_child(w)
	root.add_child(camera)
	camera.position=Workshop.SEAT
	camera.fov=67
	camera.look_at(Vector3(0,1.71,-4.8))
	w.align_to(Transform3D(Basis.IDENTITY,Workshop.SEAT))
	w.tick(.2,w.archive.last_ms,camera.global_transform)
	await photo("runtime-seat")
	camera.fov=46
	w.volume.open("Recipe",camera.global_transform,w.wall())
	camera.look_at(w.volume.global_position)
	await photo("runtime-recipe-hint")
	w.volume.rebuild(w.wall()+3601,true)
	await photo("runtime-recipe-two-hints")
	for id in [0,1,2]: w.archive.add_dose(id,w.wall())
	w.volume.rebuild(w.wall())
	w.volume.page=0
	w.volume.draw()
	await photo("runtime-recipe-known")
	w.volume.press("right_hand","next")
	w.volume.leaf.amount=.48
	w.volume.model.turn(.48)
	await photo("runtime-turn")
	w.volume.close()
	w.display_spell(1)
	w.tick(2.,w.archive.last_ms,camera.global_transform)
	camera.position=Vector3(1.3,1.55,-2.3)
	camera.look_at(Vector3(3.5,1.90,-5.10))
	camera.fov=52
	await photo("runtime-visitor")
	w.reset_spell()
	for id in [4,6]:
		w.archive.species=id
		w.archive.stage=2
		w.redraw_plant()
		camera.position=w.room.to_global(Workshop.SOIL+Vector3(-.75,.47,.54))
		camera.look_at(w.room.to_global(Workshop.SOIL+Vector3.UP*.21))
		camera.fov=48
		await photo("runtime-moonvine" if id==4 else "runtime-lantern")
	w.queue_free()
	await process_frame
	world.environment.ambient_light_energy=.86
	var light:=DirectionalLight3D.new()
	light.rotation_degrees=Vector3(-48,-24,0)
	light.light_energy=.9
	root.add_child(light)
	camera.projection=Camera3D.PROJECTION_ORTHOGONAL
	camera.size=1.82
	camera.position=Vector3(0,2.30,8.)
	camera.look_at(Vector3(0,.61,0))
	var plants:=Node3D.new()
	root.add_child(plants)
	var names:=Node3D.new()
	plants.add_child(names)
	for id in 10:
		var plant:=Plant.new()
		plants.add_child(plant)
		plant.position=Vector3((id%5-2)*.54,.69-floorf(id/5.)*.77,0)
		plant.build(id,2)
		var caption:=Label3D.new()
		caption.font=preload("res://scripts/ray_menu.gd").ui_font()
		caption.text=Workshop.Discovery.SPECIES[id]
		caption.font_size=40
		caption.pixel_size=.00083
		caption.modulate=Color("#d8c8ab")
		caption.outline_size=0
		caption.position=plant.position+Vector3.DOWN*.055
		names.add_child(caption)
	await photo("runtime-herbarium")
	plants.queue_free()
	await process_frame
	quit()
