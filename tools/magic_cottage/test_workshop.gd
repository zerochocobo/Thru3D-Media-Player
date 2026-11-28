extends SceneTree
const Workshop := preload("res://environments/magic_cottage/workshop.gd")
const Discovery := preload("res://environments/magic_cottage/discovery.gd")
const Plant := preload("res://environments/magic_cottage/specimen.gd")
var errors := 0
var checks := 0

func check(ok: bool,reason: String) -> void:
	checks += 1
	if not ok:
		errors += 1
		push_error(reason)

func _initialize() -> void:
	run.call_deferred()

func run() -> void:
	var d := Discovery.new()
	d.directory=""
	d.enter(500,500)
	check(d.keys.size()==20,"20 unordered triples with distinct ingredients")
	var histogram := {}
	for a in 6:
		for b in 6:
			for c in 6:
				if a==b or b==c or a==c: continue
				d.add_dose(a,510)
				d.add_dose(b,510)
				var result:=d.add_dose(c,510)
				var sorted: Array[int]=[a,b,c]
				sorted.sort()
				check(result.key=="%d%d%d"%sorted,"permutation key")
				check(d.failures*5<=d.attempts,"observed failure ceiling")
				histogram[d.effect(result.key)]=true
	check(histogram.size()==20 and Discovery.EFFECTS.size()==20 and Discovery.VERSES.size()==20,"one named and illustrated outcome per combination")
	check(d.recipes.size()==20,"every formula including unstable mixtures can be discovered")
	check(d.hints(10000).is_empty(),"completed recipe book")
	var mix:=Discovery.new()
	mix.directory=""
	for id in [1,1,1,2,2]: mix.add_dose(id,500)
	check(mix.batch==[1,2] and mix.attempts==0,"duplicates cannot spend a slot or count as a failure")
	var fresh := Discovery.new()
	fresh.directory=""
	fresh.enter(100,5000)
	check(fresh.hints(8600).size()==1,"one hour boundary")
	check(fresh.hints(8601).size()==2 and fresh.hints(8601)[0].visible==2,"two separate stale hints")
	var hinted: String=fresh.hints(8601)[0].key
	fresh.add_dose(int(hinted[2]),9000)
	fresh.add_dose(int(hinted[1]),9000)
	fresh.add_dose(int(hinted[0]),9000)
	check(fresh.hints(9001).size()==1 and fresh.hints(9001)[0].key!=hinted,"new discovery replaces hint")
	fresh.advance(1200100)
	check(fresh.stage==1,"intermediate at 20 minutes")
	fresh.water(1200100)
	fresh.water(1200100)
	fresh.advance(2400099)
	check(fresh.stage==1,"no retroactive or stacked watering")
	fresh.advance(2400100)
	check(fresh.stage==2 and fresh.herbs.size()==1,"maturity at exactly one effective hour")
	fresh.enter(2400101,9100)
	check(fresh.stage==0 and not fresh.wet and fresh.herbs.size()==1,"return to sprout")
	fresh.advance(6000100)
	check(fresh.stage==1,"dry plant one millisecond before full hour")
	fresh.advance(6000101)
	check(fresh.stage==2,"dry plant full hour")
	var specimen:=Plant.new()
	var prints:={}
	for species in 10:
		for phase in 3:
			specimen.build(species,phase)
			var vertices: PackedVector3Array=specimen.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
			check(vertices.size()>0,"nonempty stage")
			if phase==2: prints[hash(vertices)]=true
	check(prints.size()==10,"10 distinct mature silhouettes")
	specimen.free()
	var w:=Workshop.new()
	var local_dir: String=OS.get_cmdline_user_args()[0]
	w.archive.directory=local_dir
	root.add_child(w)
	var pose:=Transform3D(Basis.IDENTITY,Workshop.SEAT)
	w.align_to(pose)
	w.tick(.01,w.archive.last_ms,pose)
	var hand:="right_hand"
	for id in ["Atlas","Herbal","Journal","Jug","Dose0","Dose1","Dose2","Dose3","Dose4","Dose5","Kettle","Plant"]:
		check(w.target(ray(w,id))==id,"seated clear target "+id+" got "+w.target(ray(w,id)))
	var pulses: Array = []
	w.pulse.connect(func(h: String, strength: float, seconds: float): pulses.append([h,strength,seconds]))
	w.aim(hand,ray(w,"Atlas"),.016)
	check(w.hovered.get(hand,"")=="Atlas" and w.models.get_node("Atlas").material_overlay==w.hover_tint and pulses.size()==1,"resting on a book lights it and ticks the controller")
	w.aim(hand,ray(w,"Herbal"),.016)
	check(w.models.get_node("Atlas").material_overlay==null and w.models.get_node("Herbal").material_overlay==w.hover_tint and pulses.size()==2,"the glow follows the wand")
	check(w.press(hand,ray(w,"Herbal")) and w.volume.visible and w.volume.kind=="Herbal" and w.volume.entries[0].has("pot"),"the herbal opens on the pot")
	w.release(hand,ray(w,"Herbal"))
	var Spread := preload("res://environments/magic_cottage/folio_spread.gd")
	var pot := Discovery.new()
	pot.effective_ms = 900000
	check(Spread.bloom_hint(pot)=="约 45 分钟后开花 · 浇水后 23 分钟","the pot page says how long a dry pot takes, and with water")
	pot.wet = true
	check(Spread.bloom_hint(pot)=="约 23 分钟后开花","a watered pot counts at double speed")
	pot.stage = 2
	check(Spread.bloom_hint(pot)=="已开花 · 收入图鉴","a flowered pot says so")
	check(w.back() and (w.volume.closing or not w.volume.visible),"B closes an open book")
	w.volume.close()
	check(not w.back(),"B with nothing to end is left to the player")
	w.cancel(hand)
	check(w.press(hand,ray(w,"Jug")),"grab ewer")
	for i in 62: w.aim(hand,ray(w,"Plant"),.016)
	check(w.archive.wet and w.pearls.get_child_count()>0,"pour by proximity")
	check(w.release(hand,ray(w,"Plant")) and w.models.get_node("Jug").visible,"return ewer")
	for i in 3:
		var name:="Dose%d"%i
		check(w.press(hand,ray(w,name)) and w.held.has(hand),"take one distinct ingredient")
		check(w.press("left_hand",ray(w,name)) and not w.held.has("left_hand"),"same object already held")
		w.release("left_hand",null)
		w.aim(hand,ray(w,"Kettle"),.016)
		check(w.release(hand,ray(w,"Kettle")) and w.flying.has(i),"reserve flying ingredient")
		check(w.press(hand,ray(w,name)) and not w.held.has(hand),"cannot duplicate flying dose")
		w.release(hand,null)
		await create_timer(.65).timeout
		if i<2: check(w.dose_busy(i) and w.archive.batch.size()==i+1,"deposited dose locked")
	check(w.archive.recipes.has("012") and not w.dose_busy(0),"three unique throws unlock and replenish")
	check(w.press(hand,ray(w,"Journal")) and w.volume.visible,"the third shelf volume summons the recipes")
	check(w.volume.kind=="Recipe" and w.volume.entries.size()>=2,"historic equation and hint")
	w.release(hand,ray(w,"Journal"))
	var folio=w.volume
	folio.press(hand,"previous")
	check(folio.leaf.held and folio.model.leaf_side!=0,"reader model lifts the leaf")
	folio.aim(hand,[folio.global_position+Vector3.BACK,Vector3(.24,0,-1).normalized()],.16,false)
	folio.release_hand(hand)
	for i in 90: folio._process(.016)
	check(folio.leaf.is_empty() and folio.page==0,"reading-space leaf settles to previous formula")
	folio.press(hand,"next")
	folio.release_hand(hand,true)
	for i in 90: folio._process(.016)
	check(folio.page==0 and folio.leaf.is_empty(),"tracking cancellation returns lifted paper")
	w.archive.advance(w.archive.last_ms+1800000)
	w.redraw_plant()
	check(w.plant_glow.get_child_count()>0,"mature aura")
	for spell in range(-1,10):
		w.display_spell(spell)
		w.tick(2.,w.archive.last_ms,pose)
		check(w.spell==spell,"spell begins")
		if spell==8:
			check(w.wall_ivy.visible and w.wall_ivy.mesh!=null and float(w.ivy_growth.get_shader_parameter("height"))>1.,"paired vines rise above the floor")
		w.tick(6.1,w.archive.last_ms,pose)
		check(w.spell== -2 and w.room.position==Vector3.ZERO,"restores spell "+str(spell))
		if spell==8: check(not w.wall_ivy.visible,"vines clear with the apparition")
	check(w.press(hand,ray(w,"Dose2")),"take for cancel")
	w.cancel(hand)
	check(w.held.is_empty() and w.owners.is_empty(),"tracking cancellation")
	w.volume.close()
	check_casting(w,pose)
	var legacy_dir:=local_dir+"/legacy"
	DirAccess.make_dir_recursive_absolute(legacy_dir)
	var legacy:=ConfigFile.new()
	legacy.set_value("archive","revision",7)
	legacy.set_value("archive","herbs",{0:.43,4:.18,24:.9,49:.2})
	legacy.set_value("archive","recipes",{"000":0,"012":0,"235":7,"025":0})
	legacy.set_value("archive","unlocked_at",8940)
	legacy.save(legacy_dir+"/journal1.cfg")
	var migrated:=Discovery.new()
	migrated.directory=legacy_dir
	migrated.load_journals()
	check(migrated.herbs=={0:true,4:true,9:true},"old colours collapse to three corresponding species")
	check(migrated.recipes=={"012":0,"235":9,"025":10} and migrated.unlocked_at==8940,"keep discoveries and timestamp, including a retired duplicate effect")
	migrated.save()
	var twice:=Discovery.new()
	twice.directory=legacy_dir
	twice.load_journals()
	check(twice.herbs==migrated.herbs,"new species identities migrate only once")
	var restored:=Discovery.new()
	restored.directory=local_dir
	restored.load_journals()
	check(restored.recipes.has("012") and restored.herbs.size()>0,"disk archive reloaded")
	w.queue_free()
	await process_frame
	print("COTTAGE CHECKS ",checks," failures ",errors)
	quit(1 if errors else 0)

func check_casting(w: Workshop,pose: Transform3D) -> void:
	var start := Workshop.SEAT+Vector3(.24,-.20,-.17)
	var r := [start,(Vector3(.88,2.22,-4.97)-start).normalized()]
	var other := [start,(Vector3(-1.,2.14,-4.97)-start).normalized()]
	for key: String in Discovery.FORMULAS:
		var effect: int = Discovery.FORMULAS[key]
		if effect<10: continue
		for ch in key: w.deposit(int(ch))
		check(w.spell==effect and w.magic.kind==effect,"three ingredients grant "+Discovery.EFFECTS[effect])
		w.aim("left_hand",r,.016)
		w.aim("right_hand",other,.016)
		check(w.press("left_hand",r) and w.magic.marks.size()==1,"trigger casts "+key)
		var mark:=w.magic.marks[0]
		check(mark.point.distance_to(mark.origin)>1. and absf(mark.point.z+4.97)<.4,"spell strikes the front of the room")
		w.tick(.34,w.archive.last_ms,pose)
		var strokes:=0
		for count in w.magic.counts: strokes+=count
		check(strokes>6,"visible spell geometry "+key)
		if effect==w.WandSpells.FISH:
			var previous:=mark.guide
			w.aim("left_hand",other,.016)
			check(mark.held and previous.distance_to(mark.guide)>.15,"held fish follows wrist")
		w.release("left_hand",other)
		check(not mark.held and w.press("right_hand",other) and w.magic.marks.size()==2,"other hand casts independently")
		if effect==w.WandSpells.FISH:
			w.cancel("right_hand")
			check(w.magic.marks.size()==1 and w.magic.marks[0]==mark,"tracking loss releases only its guided fish")
		else: w.release("right_hand",other)
		w.tick(1.,w.archive.last_ms,pose)
		if effect==w.WandSpells.GATES:
			w.press("right_hand",r)
			w.release("right_hand",r)
			check(w.magic.marks.size()==1,"third gate starts a fresh pair")
		elif effect==w.WandSpells.FIRE:
			check(mark.arrived and w.magic.flash>0.,"fireball bursts at the impact and warms the room")
		elif effect==w.WandSpells.MOON:
			check(mark.arrived,"moon reached the wall and is returning")
		check(w.press("left_hand",ray(w,"Jug")) and w.held.has("left_hand"),"real prop has priority over a cast")
		w.cancel("left_hand")
		w.set_film(true)
		check(not w.press("right_hand",r),"movie surface keeps its normal trigger")
		w.set_film(false)
		w.tick(29.,w.archive.last_ms,pose)
		check(w.spell== -2 and w.magic.marks.is_empty() and w.magic.counts.count(0)==w.magic.counts.size(),"temporary ability expires and clears marks")
	w.display_spell(w.WandSpells.FIRE)
	w.press("right_hand",r)
	w.display_spell(w.WandSpells.FROST)
	check(w.magic.marks.is_empty(),"brewing replaces an active enchantment")
	w.release("right_hand",r)
	w.press("right_hand",r)
	w.present(false)
	check(w.owners.is_empty() and w.spell== -2 and w.magic.marks.is_empty(),"temporary passthrough clears ability and input")
	w.present(true)

func ray(w: Workshop,id: String) -> Array:
	var origin:=Workshop.SEAT+Vector3(.22,-.21,-.16)
	var center: Vector3=w.targets[id][0]
	return [origin,(center-origin).normalized()]
