extends SceneTree
## Capture each enchantment using the workshop's real input, room meshes and renderer.
const Workshop := preload("res://environments/magic_cottage/workshop.gd")
const Spells := Workshop.WandSpells
var stage := Workshop.new()
var camera := Camera3D.new()
var output: String

func _initialize() -> void:
	run.call_deferred()

func sample(hand: String, source: Vector3, dest: Vector3) -> Array:
	var ray := [source,source.direction_to(dest)]
	stage.aim(hand,ray,.016)
	stage.press(hand,ray)
	return ray

func advance(time: float) -> void:
	stage.tick(time,stage.archive.last_ms,camera.global_transform)

func photo(name_of_plate: String) -> void:
	await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_jpg(output.path_join(name_of_plate+".jpg"),.94)

func run() -> void:
	output = OS.get_cmdline_user_args()[0]
	DirAccess.make_dir_recursive_absolute(output)
	var world := WorldEnvironment.new()
	world.environment = Environment.new()
	world.environment.background_mode = Environment.BG_COLOR
	world.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	world.environment.ambient_light_color = Color("#fce5cf")
	world.environment.ambient_light_energy = .52
	root.add_child(world)
	stage.archive.directory = ""
	root.add_child(stage)
	root.add_child(camera)
	stage.align_to(Transform3D(Basis.IDENTITY,Workshop.SEAT))
	var cost_us := []
	for kind in range(Spells.FIRE,Spells.MOON+1):
		stage.display_spell(kind)
		advance(1.)
		var dest := Vector3(2.77,2.21,-4.90)
		var travel := Vector3(.14,-.04,-1.).normalized()
		var upshot := .12
		match kind:
			Spells.ROSES: upshot=.33
			Spells.BELLS: dest.y=2.48
			Spells.VORTEX: dest=Vector3(-2.77,2.23,-4.90)
			Spells.FISH: dest=Vector3(1.24,2.23,-4.97)
			Spells.STARS: dest=Vector3(2.90,2.48,-4.97)
			Spells.GATES: dest=Vector3(.25,2.48,-4.97)
		camera.position = dest-travel*2.95+Vector3(-.58,.10,0)
		camera.look_at(dest+Vector3.UP*upshot)
		camera.fov = 43.
		var source := dest-travel*3.25+Vector3(.33,-.43,0)
		var left := dest+Vector3(-.50,-.17,0)
		var right := dest+Vector3(.64,.17,0)
		if kind in [Spells.GATES,Spells.STARS,Spells.BELLS]: dest=left
		var before := Time.get_ticks_usec()
		var r := sample("right_hand",source,dest)
		cost_us.append(Time.get_ticks_usec()-before)
		if kind != Spells.FISH: stage.release("right_hand",r)
		var m := stage.magic.marks[0]
		match kind:
			Spells.FIRE:
				advance(m.flight*.76)
				await photo("fire-flight")
				advance(m.flight*.24+.24)
			Spells.FROST,Spells.ROSES,Spells.VORTEX: advance(1.08)
			Spells.LIGHTNING: advance(.055)
			Spells.BELLS,Spells.GATES,Spells.STARS:
				advance(.32)
				if kind==Spells.STARS:
					for offset in [Vector3(-.28,.37,0),Vector3(.08,-.09,0),Vector3(.32,.25,0)]:
						var link := sample("left_hand",source,left+Vector3.RIGHT*.49+offset)
						stage.release("left_hand",link)
						advance(.30)
				var r2 := sample("right_hand",source,right)
				stage.release("right_hand",r2)
				advance(.74)
			Spells.FISH:
				advance(.12)
				stage.release("right_hand",r)
				advance(m.flight*.84)
				var swimming := m.origin.lerp(m.point,.84)+Vector3.UP*.20*sin(.84*PI)
				camera.position=swimming+Vector3(-1.03,.22,.80)
				camera.look_at(swimming)
			Spells.MOON: advance(m.flight*.91)
		await photo("wand-%d"%kind)
		for hand in stage.wands: stage.cancel(hand)
	print("Cast sampling times in microseconds ",cost_us)
	stage.queue_free()
	await process_frame
	quit()
