extends SceneTree
const Workshop := preload("res://environments/magic_cottage/workshop.gd")
const Spells := Workshop.WandSpells
const Raid := Spells.Raid
var w := Workshop.new()
var pose := Transform3D(Basis.IDENTITY,Workshop.SEAT)
var passed := 0
var failed := 0

func check(value: bool, message: String) -> void:
	if value: passed+=1
	else:
		failed+=1
		push_error(message)

func _initialize() -> void: run.call_deferred()

func shoot(hand: String, point: Vector3) -> bool:
	var origin := Workshop.SEAT+Vector3(.16 if hand=="right_hand" else -.16,-.21,-.17)
	var ray := [origin,origin.direction_to(point)]
	w.aim(hand,ray,.033)
	var ok := w.press(hand,ray)
	w.release(hand,ray)
	return ok

func run() -> void:
	w.archive.directory=""
	root.add_child(w)
	w.align_to(pose)
	check(w.sound.clips.size()==38 and not w.sound.clips.values().has(null),"all original audio assets are loadable")
	var unique := {}
	for clip: AudioStreamWAV in w.sound.clips.values():
		unique[hash(clip.data)]=true
		check(not clip.stereo and clip.get_length()>.15,"localizable mono cue with duration")
	check(unique.size()==38,"38 distinct recordings")
	var token:=w.sound.cue("window_open",Vector3.LEFT*3.5,-6.,1.,2)
	var slot:=w.sound.tokens.find(token)
	w.set_film(true)
	check(w.sound.sources[slot].position.x<0. and w.sound.sources[slot].volume_db== -16.,"left window source ducks for film")
	w.set_film(false)
	check(w.sound.sources[slot].volume_db== -6.,"original gain restored")
	check_surfaces()
	for id in [Spells.FIRE,Spells.LIGHTNING,Spells.MOON]:
		w.display_spell(id)
		check(w.magic.raid==null,"brewing alone leaves the room quiet")
		shoot("right_hand",Vector3(.6,2.8,-4.90))
		var raid:=w.magic.raid
		check(raid!=null and raid.foes[0].position==raid.window(0),"first cast opens the left window")
		var maximum:=0
		var from_left:=false
		var from_right:=false
		var saw_chain:=false
		for frame in 660:
			w.tick(1./30.,w.archive.last_ms,pose)
			maximum=maxi(maximum,raid.foes.size())
			for foe in raid.foes:
				from_left=from_left or foe.position.x<0.
				from_right=from_right or foe.position.x>0.
			if frame%12==0 and not raid.foes.is_empty():
				var foe:=raid.foes[0]
				var age:=raid.time-foe.born
				if age>.75 and (id!=Spells.LIGHTNING or raid.foes.size()>1 or raid.next==Raid.COUNT or age>4.):
					var lead:=0. if id==Spells.LIGHTNING else .38
					shoot("right_hand" if frame%24==0 else "left_hand",raid.path(foe,age+lead))
					if not w.magic.marks.is_empty() and w.magic.marks.back().forks.size()>1: saw_chain=true
			if raid.finished_at>=0.: break
		print("WINDOWS outcome ",id,": ",raid.hits,"/6; peak ",maximum)
		check(raid.finished_at>=0. and raid.hits>=Raid.GOAL and raid.hits+raid.escaped==6,"real aimed casts can win "+str(id))
		check(from_left and from_right and maximum<=3,"two entrances with bounded population")
		if id==Spells.LIGHTNING: check(saw_chain,"lightning can chain between live scarabs")
	w.display_spell(Spells.FIRE)
	w.tick(28.,w.archive.last_ms,pose)
	shoot("right_hand",Vector3(.4,2.8,-4.9))
	var quiet_raid:=w.magic.raid
	while quiet_raid.finished_at<0. and quiet_raid.time<24.: w.tick(.1,w.archive.last_ms,pose)
	check(quiet_raid.escaped==6 and quiet_raid.hits==0,"late first cast allows a full encounter and loss")
	w.display_spell(Spells.MOON)
	shoot("right_hand",Vector3(.6,2.8,-4.9))
	var active:=w.magic.raid
	w.volume.open("Recipe",pose,w.wall())
	w.tick(3.,w.archive.last_ms,pose)
	check(active.time==0. and w.age==0.,"reading freezes the encounter and the enchantment")
	w.volume.close()
	w.present(false)
	check(w.magic.raid==null and w.sound.tokens.count(0)==w.Sound.VOICES,"suspension silences emitters and clears visitors")
	w.queue_free()
	await process_frame
	print("RAID CHECKS ",passed+failed," failures ",failed)
	quit(1 if failed else 0)

func check_surfaces() -> void:
	for model: MeshInstance3D in w.models.get_children():
		var tree:=TriangleMesh.new()
		tree.create_from_faces(model.mesh.get_faces())
		var box:=model.get_aabb()
		var center:=box.get_center()
		var reach:=box.size.length()+1.
		for axis in [Vector3(.87,.09,.47),Vector3(-.35,.43,.82),Vector3(.19,-.89,.41)]:
			var direction:=Vector3(axis).normalized()
			var start:=center-direction*reach
			var expected:=tree.intersect_ray(start,direction)
			var actual:=w.spell_surfaces.nearest(model.name,start,direction,reach*2.)
			check(actual.is_empty()==expected.is_empty() and (actual.is_empty() or Vector3(actual.position).distance_to(expected.position)<.003),"baked picking agrees with mesh "+str(model.name))
