extends SceneTree
## Run with --write-movie and --fixed-fps 30 to record the real positional audio mix.
const Workshop := preload("res://environments/magic_cottage/workshop.gd")
const Spells := Workshop.WandSpells
var stage:=Workshop.new()
var camera:=Camera3D.new()
var output: String

func _initialize() -> void: run.call_deferred()

func run() -> void:
	output=OS.get_cmdline_user_args()[0]
	var world:=WorldEnvironment.new()
	world.environment=Environment.new()
	world.environment.background_mode=Environment.BG_COLOR
	world.environment.ambient_light_source=Environment.AMBIENT_SOURCE_COLOR
	world.environment.ambient_light_color=Color("#fce5cf")
	world.environment.ambient_light_energy=.48
	root.add_child(world)
	stage.archive.directory=""
	root.add_child(stage)
	root.add_child(camera)
	camera.position=Workshop.SEAT
	camera.fov=54.
	camera.look_at(Workshop.BROTH)
	stage.align_to(Transform3D(Basis.IDENTITY,Workshop.SEAT))
	stage.deposit(0)
	stage.deposit(2)
	var hand:="right_hand"
	var gaze:=Workshop.BROTH
	var point:=Workshop.BROTH
	var saved:=false
	for frame in 770:
		var source:=Workshop.SEAT+Vector3(.23,-.22,-.18)
		if frame<20: point=stage.targets.Dose5[0]
		elif frame<70: point=Workshop.BROTH
		else: point=Vector3(-3.5,1.99,-4.90)
		var target_age:=0.
		if stage.magic and stage.magic.raid:
			var raid:=stage.magic.raid
			if not raid.foes.is_empty():
				var foe:=raid.foes[0]
				target_age=raid.time-foe.born
				point=raid.path(foe,target_age+.35)
			elif raid.finished_at>=0.:
				point=Vector3(0,2.07,-4.9)
				if raid.time-raid.finished_at>2.3:
					print("Captured ward ",raid.hits," repelled, ",raid.escaped," escaped")
					break
		gaze=gaze.lerp(point,.065)
		camera.look_at(gaze)
		var ray:=[source,source.direction_to(point)]
		stage.aim(hand,ray,1./30.)
		if frame==15: stage.press(hand,ray)
		if frame==34: stage.release(hand,ray)
		if frame==96 or (target_age>1.75 and frame%15==0):
			stage.press(hand,ray)
			stage.release(hand,ray)
		stage.tick(1./30.,stage.archive.last_ms,camera.global_transform)
		await process_frame
		if not saved and stage.magic and stage.magic.raid and target_age>1.78 and not stage.magic.marks.is_empty():
			await RenderingServer.frame_post_draw
			root.get_texture().get_image().save_jpg(output.path_join("ward-in-play.jpg"),.94)
			saved=true
	stage.queue_free()
	await process_frame
	quit()
