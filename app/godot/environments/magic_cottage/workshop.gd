extends Node3D
signal film_library_requested
## Haptic feedback for one controller: strength 0..1 and duration in seconds.
signal pulse(hand: String, strength: float, seconds: float)
const Discovery := preload("discovery.gd")
const Specimen := preload("specimen.gd")
const Folio := preload("folio.gd")
const Wand := preload("res://scripts/book_wand.gd")
const Sound := preload("spell_audio.gd")
const WandSpells := preload("wand_spells.gd")
const Apparitions := preload("room_apparitions.gd")
const SpellSurfaces := preload("spell_surfaces.gd")
const SkyShader := preload("observatory.gdshader")
const Clock := preload("res://scripts/session_usage.gd")
const ARCH := Vector3(0,2.325,-4.97)
const SOIL := Vector3(4.05,1.523,-3.64)
const BROTH := Vector3(3.96,1.09,-.94)
const SEAT := Vector3(0,1.15,1.82)
## Shelf book -> the book it opens. The third shelf volume carries the recipes; the old
## recipe book on the top shelf is retired, and the empty film journal with it.
const BOOKS := {"Atlas":"Atlas","Herbal":"Herbal","Journal":"Recipe"}
## Inner room bounds a carried item stays within, so it never passes behind a wall or cabinet.
const HOLD_MIN := Vector3(-3.75,.30,-4.55)
const HOLD_MAX := Vector3(3.75,3.30,2.40)
## Angle within which a ray appears to guide the wand toward something it can use.
const GUIDE_ANGLE := .11
var archive := Discovery.new()
var room := Node3D.new()
var models: Node3D
var plant := Specimen.new()
var volume := Folio.new()
var skies: Array[ShaderMaterial] = []
var homes := {}
var targets := {}
var held := {}
var flying := {}
var used_tint := StandardMaterial3D.new()
var owners := {}
var wands := {}
var streams := {}
var scene_time := 0.
var age := 0.
var spell := -2
var show_fx: Apparitions
var magic: WandSpells
var spell_surfaces: SpellSurfaces
var eye := Transform3D.IDENTITY
var aligned := false
var ritual := Node3D.new()
var wall_ivy := MeshInstance3D.new()
var ivy_growth := ShaderMaterial.new()
var plant_glow := Node3D.new()
var pearls := Node3D.new()
# The hall's candle and window light is baked into the room's corner colours; an apparition
# tints the whole room through its materials instead of recolouring real-time lights.
var spell_tint := Color.WHITE
var focus_lamps := {}
var beams := {}
## The attic's wand, chosen in its scene settings (book_wand.gd STYLES).
var wand_style := Wand.DEFAULT_STYLE
var open_shelf := ""
## What each hand's wand is resting on; the object glows faintly and the controller ticks once.
var hovered := {}
var hover_tint := StandardMaterial3D.new()
var pour_voice := {}
var last_flash := 0.
var journal_stale := false
var movie := false
var brightness := 1.
var film_pose := Transform3D(Basis.IDENTITY, Vector3(0,1.75,-4.725))
var film_size := Vector2(4.5, 2.55)
var light_fraction := 1.
var room_materials := {}
var room_shaders := {}
var sound := Sound.new()
var kettle_marks := Node3D.new()
var bookmark: MeshInstance3D
var bookmark_time := 0.
var pending_spell := -1

func _ready() -> void:
	used_tint.transparency=BaseMaterial3D.TRANSPARENCY_ALPHA
	used_tint.shading_mode=BaseMaterial3D.SHADING_MODE_UNSHADED
	used_tint.albedo_color=Color(.055,.035,.055,.72)
	hover_tint.shading_mode=BaseMaterial3D.SHADING_MODE_UNSHADED
	hover_tint.transparency=BaseMaterial3D.TRANSPARENCY_ALPHA
	hover_tint.blend_mode=BaseMaterial3D.BLEND_MODE_ADD
	hover_tint.albedo_color=Color(.20,.15,.08,1.)
	add_child(room)
	models = load("res://environments/magic_cottage/workshop.res").instantiate()
	spell_surfaces = load("res://environments/magic_cottage/spell_surfaces.res")
	room.add_child(models)
	for node in models.get_children():
		homes[str(node.name)] = node.position
		if node is MeshInstance3D: prepare_room_materials(node)
	for id in ["Atlas","Herbal","Journal","Jug","Coffer"]:
		targets[id] = [homes[id],.24 if id!="Coffer" else .31]
	models.get_node("Recipe").visible = false
	for i in 6:
		var id := "Dose%d"%i
		targets[id] = [homes[id],.195]
	targets["Plant"] = [SOIL,.31]
	targets["Kettle"] = [BROTH,.47]
	targets["MirrorSeal"] = [Vector3(-2.70,1.19,-4.66),.22]
	var atlas: Texture2D = load("res://environments/magic_cottage/star-atlas.jpg")
	for pos in [ARCH,Vector3(-3.50,1.99,-5.18),Vector3(3.50,1.99,-5.18)]:
		var surface := MeshInstance3D.new()
		var plane := QuadMesh.new()
		plane.size = Vector2(5.32,4.46) if pos==ARCH else Vector2(1.26,2.60)
		surface.mesh = plane
		surface.position = pos
		var mat := ShaderMaterial.new()
		mat.shader = SkyShader
		mat.set_shader_parameter("charts",atlas)
		mat.set_shader_parameter("pane",signf(pos.x))
		surface.material_override = mat
		room.add_child(surface)
		skies.append(mat)
	room.add_child(plant)
	var pigment := ShaderMaterial.new()
	pigment.shader = preload("botanical.gdshader")
	plant.material_override = pigment
	room.add_child(kettle_marks)
	bookmark = gem(room,.029,Color("#ffdf83"))
	bookmark.visible = false
	room.add_child(plant_glow)
	room.add_child(pearls)
	room.add_child(ritual)
	ivy_growth.shader = preload("ivy_growth.gdshader")
	wall_ivy.mesh = load("res://environments/magic_cottage/wall_ivy.res")
	wall_ivy.material_override = ivy_growth
	wall_ivy.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	wall_ivy.visible = false
	room.add_child(wall_ivy)
	add_child(volume)
	volume.archive = archive
	volume.atlas = atlas
	for hand in ["left_hand","right_hand"]:
		var wand := Wand.new()
		wand.set_style(wand_style)
		add_child(wand)
		wands[hand] = wand
		var dot := gem(room,.021,Color("#ffe7a1"))
		dot.visible = false
		focus_lamps[hand] = dot
		beams[hand] = beam()
	volume.closed.connect(func():
		if open_shelf!="": models.get_node(open_shelf).visible = true
		open_shelf = "")
	room.add_child(sound)
	archive.load_journals()
	archive.enter(Clock.milliseconds(),wall())
	redraw_plant()
	if OS.is_debug_build(): diagnose()

## Debug builds only: [debug] cottage_* keys in the player's settings strip one cost at a time for
## headset A/B (flat skies, no room model). Release builds never read them.
func diagnose() -> void:
	var config := ConfigFile.new()
	if config.load(archive.directory.get_base_dir().path_join("player_settings.cfg")) != OK: return
	if bool(config.get_value("debug","cottage_flat_sky",false)):
		var flat := StandardMaterial3D.new()
		flat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		flat.albedo_color = Color(.011,.020,.063)
		for node in room.get_children():
			if node is MeshInstance3D and node.material_override is ShaderMaterial and skies.has(node.material_override): node.material_override = flat
	if bool(config.get_value("debug","cottage_no_room",false)): models.visible = false
	print("COTTAGE_DIAGNOSE ", {"flat_sky":config.get_value("debug","cottage_flat_sky",false),"no_room":not models.visible})

func wall() -> int:
	return int(Time.get_unix_time_from_system())

func set_wand_style(style: String) -> void:
	wand_style = Wand.valid_style(style)
	for wand in wands.values(): wand.set_style(wand_style)

## A thin guide ray from the wand tip; aim() stretches it to what the wand is about to use.
func beam() -> MeshInstance3D:
	var item := MeshInstance3D.new()
	var rod := CylinderMesh.new()
	rod.top_radius = .0026
	rod.bottom_radius = .0026
	rod.height = 1.
	rod.radial_segments = 6
	rod.rings = 0
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(1.,.90,.62,.5)
	rod.material = mat
	item.mesh = rod
	item.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	item.visible = false
	add_child(item)
	return item

func show_beam(hand: String, from: Vector3, to: Vector3, strength: float) -> void:
	var item: MeshInstance3D = beams[hand]
	var length := from.distance_to(to)
	item.visible = length > .05
	if not item.visible: return
	item.global_transform = Transform3D(Basis(Quaternion(Vector3.UP,(to-from)/length)).scaled_local(Vector3(1.,length,1.)),(from+to)*.5)
	(item.mesh.material as StandardMaterial3D).albedo_color.a = strength

## The usable thing closest to the ray within GUIDE_ANGLE, as [id, distance along the ray], or [].
func near_target(ray: Array) -> Array:
	var r := local_ray(ray)
	var best := GUIDE_ANGLE
	var found := []
	for id in targets:
		var center: Vector3 = targets[id][0]+node_offset(id)
		var v := center-Vector3(r[0])
		var depth := v.dot(r[1])
		if depth<=.2: continue
		var miss := maxf(0.,(v-Vector3(r[1])*depth).length()-float(targets[id][1]))
		var angle := atan2(miss,depth)
		if angle<best:
			best = angle
			found = [id,depth]
	return found

## Furthest an item carried along this room ray can sit while staying inside HOLD_MIN..HOLD_MAX.
func hold_reach(origin: Vector3, dir: Vector3) -> float:
	var reach := INF
	for axis in 3:
		if absf(dir[axis])<.0001: continue
		var wall: float = HOLD_MAX[axis] if dir[axis]>0. else HOLD_MIN[axis]
		reach = minf(reach,(wall-origin[axis])/dir[axis])
	return maxf(.35,reach)

## B: close an open book, otherwise end a wand ability early. False when there is nothing to end.
func back() -> bool:
	if volume.visible:
		volume.close(true)
		return true
	if spell >= WandSpells.FIRE:
		reset_spell()
		sound.cue("attune",BROTH,-9.,.72,2)
		return true
	return false

func open_book(id: String) -> void:
	if open_shelf!="": models.get_node(open_shelf).visible = true
	var shelf: Node3D = models.get_node(id)
	open_shelf = id
	volume.open(BOOKS[id],eye,wall(),shelf.global_transform)
	shelf.visible = false
	journal_stale = wall()-archive.unlocked_at>3600

func gem(parent: Node, radius: float, color: Color) -> MeshInstance3D:
	var item := MeshInstance3D.new()
	var orb := SphereMesh.new()
	orb.radius = radius
	orb.height = radius*2.
	orb.radial_segments = 8
	orb.rings = 4
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = color
	orb.material = mat
	item.mesh = orb
	parent.add_child(item)
	return item

func clear(parent: Node) -> void:
	for node in parent.get_children():
		parent.remove_child(node)
		node.queue_free()

func redraw_plant() -> void:
	plant.build(archive.species,archive.stage)
	plant.position = SOIL
	clear(plant_glow)
	clear(pearls)
	if archive.wet:
		for i in 9:
			gem(pearls,.006+(i%3)*.002,Color("#a7eaff"))
	if archive.stage == 2:
		for i in 7:
			var star := gem(plant_glow,.0045+(i%3)*.001,Specimen.PALETTE[archive.species])
			star.scale = Vector3(.7,1.7,.7)

func align_to(pose: Transform3D, yaw := 0.) -> void:
	var front := -pose.basis.z
	front.y = 0.
	if front.length_squared() < .01: return
	var basis_y := Basis(Vector3.UP,yaw)*Basis.looking_at(front.normalized())
	global_transform = Transform3D(basis_y,pose.origin-basis_y*SEAT)
	eye = pose
	aligned = true

func present(shown: bool) -> void:
	if visible and not shown:
		for hand in wands: cancel(hand)
		volume.close()
		if open_shelf!="": models.get_node(open_shelf).visible = true
		open_shelf = ""
		sound.quiet()
		if spell >= WandSpells.FIRE: reset_spell()
	visible = shown
	if shown and pending_spell >= 0:
		var id := pending_spell
		pending_spell = -1
		display_spell(id)

func local_ray(ray: Array) -> Array:
	return [room.to_local(ray[0]),(room.global_transform.basis.inverse()*Vector3(ray[1])).normalized()]

func node_offset(id: String) -> Vector3:
	var group := "Dresser" if id=="Plant" else "Kettle" if id=="Kettle" else id
	if not homes.has(group): return Vector3.ZERO
	return Vector3(models.get_node(group).position)-Vector3(homes[group])

func target(ray: Array, only := "") -> String:
	var r := local_ray(ray)
	var best := film_distance(r)
	var found := ""
	for id in targets:
		if only!="" and only!=id: continue
		var center: Vector3 = targets[id][0]+node_offset(id)
		var v := center-Vector3(r[0])
		var depth := v.dot(r[1])
		if depth<=0.: continue
		var d := (v-Vector3(r[1])*depth).length()
		var radius: float = targets[id][1]
		if d>radius: continue
		var hit := depth-sqrt(maxf(0.,radius*radius-d*d))
		if hit<best:
			found = id
			best = hit
	return found

func dose_busy(id: int) -> bool:
	if id in archive.batch or flying.has(id): return true
	for h in held.values():
		if h.id=="Dose%d"%id: return true
	return false

func refresh_shelf() -> void:
	for id in Discovery.MATERIALS.size():
		models.get_node("Dose%d"%id).material_overlay = used_tint if dose_busy(id) else hover_tint if hovered.values().has("Dose%d"%id) else null

## The scene object that glows for a target, or null (the movie surface and empty space have none).
func hover_node(id: String) -> GeometryInstance3D:
	if id=="Plant": return plant
	if id=="" or not homes.has(id): return null
	return models.get_node(id) as GeometryInstance3D

func set_hover(hand: String, id: String) -> void:
	var was: String = hovered.get(hand,"")
	if was==id: return
	if id=="": hovered.erase(hand)
	else:
		hovered[hand] = id
		pulse.emit(hand,.10,.018)
	for each in [was,id]:
		if each=="" or each.begins_with("Dose"): continue
		var node := hover_node(each)
		if node: node.material_overlay = hover_tint if hovered.values().has(each) else null
	refresh_shelf()

func film_distance(r: Array) -> float:
	if not movie: return INF
	return screen_distance_in_ray(r,film_pose,film_size)

func screen_distance_in_ray(r: Array, pose: Transform3D, size: Vector2) -> float:
	var inverse := pose.affine_inverse()
	var start: Vector3 = inverse * Vector3(r[0])
	var point: Variant = Plane(Vector3.BACK, 0.).intersects_ray(start, inverse.basis * Vector3(r[1]))
	if point == null or absf(point.x) > size.x * .5 or absf(point.y) > size.y * .5: return INF
	return start.distance_to(point)

func film_in_ray(r: Array) -> bool:
	return is_finite(film_distance(r))

func idle_mirror(ray: Array) -> float:
	if movie or volume.visible or spell >= WandSpells.FIRE: return INF
	return screen_distance_in_ray(local_ray(ray),preload("film_screen.gd").HOME,Vector2(4.5,2.55))

func press(hand: String,ray: Variant) -> bool:
	if not visible or ray==null or owners.has(hand): return false
	if volume.visible:
		# An open book takes every press: on a page it turns, anywhere else it goes back to the shelf.
		var action := volume.hit(ray)
		if action!="":
			volume.press(hand,action)
			pulse.emit(hand,.15,.025)
		else:
			volume.close(true)
			pulse.emit(hand,.20,.03)
		owners[hand] = true
		return true
	var id := target(ray)
	if spell >= WandSpells.FIRE and not volume.visible:
		var r := local_ray(ray)
		var tip: Vector3 = r[0]+r[1]*Wand.LENGTH
		var can_cast := id in ["","Plant","Kettle"]
		if not can_cast and magic.raid:
			var center: Vector3=targets[id][0]+node_offset(id)
			var reach:=maxf(0.,tip.distance_to(center)-float(targets[id][1]))
			can_cast=magic.raid.first_hit(tip,tip+Vector3(r[1])*reach,.07)!=null
		if can_cast:
			if film_in_ray(r): return false
			magic.cast(hand,tip,r[1],models)
			pulse.emit(hand,.40,.05)
			owners[hand] = true
			return true
	if id=="":
		if not is_finite(idle_mirror(ray)): return false
		owners[hand] = "film_library"
		return true
	if id=="Jug" or id.begins_with("Dose"):
		if id.begins_with("Dose") and (dose_busy(int(id.right(1))) or flying.size()+archive.batch.size()>=3):
			owners[hand] = true
			return true
		if id=="Jug":
			for h in held:
				if held[h].id=="Jug": return false
		var source: MeshInstance3D = models.get_node(id)
		var item := MeshInstance3D.new()
		item.mesh = source.mesh
		for surface in source.mesh.get_surface_count():
			item.set_surface_override_material(surface,source.get_surface_override_material(surface))
		room.add_child(item)
		item.position = source.position
		if id=="Jug": source.visible=false
		held[hand]={"id":id,"node":item,"depth":item.global_position.distance_to(ray[0]),"pour":0.}
		set_hover(hand,"")
		refresh_shelf()
		pulse.emit(hand,.30,.04)
	elif BOOKS.has(id):
		open_book(id)
		pulse.emit(hand,.25,.04)
	elif id=="Coffer": sound.cue("coffer",homes.Coffer)
	elif id=="MirrorSeal": scene_time = (floorf(scene_time/8.)+1.)*8.
	else: return false
	owners[hand] = true
	return true

func aim(hand: String,ray: Variant,delta: float) -> void:
	if not wands.has(hand): return
	if ray==null or not visible:
		cancel(hand)
		return
	wands[hand].aim(ray[0],ray[1])
	if spell >= WandSpells.FIRE:
		var wand_ray := local_ray(ray)
		magic.track(hand,room.to_local(wands[hand].tip.global_position),wand_ray[1])
	var dest := ""
	var pointed := ""
	if held.has(hand): dest = "Plant" if held[hand].id=="Jug" else "Kettle"
	var paper: Dictionary = volume.aim(hand,[wands[hand].tip.global_position,ray[1]],delta,not held.has(hand) and not owners.has(hand)) if volume.visible else {}
	if paper.is_empty():
		pointed = target(ray,dest)
	set_hover(hand,"" if held.has(hand) else pointed)
	var dot: Node3D = focus_lamps[hand]
	var mirror_depth := idle_mirror(ray) if pointed=="" and paper.is_empty() and not held.has(hand) else INF
	dot.visible = pointed!="" or not paper.is_empty() or is_finite(mirror_depth)
	if not paper.is_empty():
		dot.global_position=paper.point+volume.global_basis.z*.005
		dot.scale=Vector3.ONE*.24
	elif pointed!="":
		dot.scale=Vector3.ONE
		var center: Vector3 = targets[pointed][0]+node_offset(pointed)
		dot.position = center + (room.to_local(ray[0])-center).normalized()*float(targets[pointed][1])
	elif is_finite(mirror_depth):
		dot.scale=Vector3.ONE
		dot.global_position=ray[0]+ray[1]*(mirror_depth-.028)
	wands[hand].cast(pointed!="" or is_finite(mirror_depth) or held.has(hand) or volume.turn_hand==hand)
	var tip: Vector3 = wands[hand].tip.global_position
	if held.has(hand) or volume.closing: beams[hand].visible = false
	elif dot.visible: show_beam(hand,tip,dot.global_position,.65)
	else:
		var near := near_target(ray) if not volume.visible else []
		if near.is_empty(): beams[hand].visible = false
		else: show_beam(hand,tip,ray[0]+Vector3(ray[1])*float(near[1]),.38)
	if not held.has(hand): return
	var h: Dictionary = held[hand]
	var r := local_ray(ray)
	var pos: Vector3 = r[0]+Vector3(r[1])*minf(float(h.depth),hold_reach(r[0],r[1]))
	if pointed=="Plant": pos = plant.position+Vector3(-.03,.31,-.23)
	if pointed=="Kettle": pos = BROTH+node_offset("Kettle")+Vector3(-.20,.50,.22)
	var item: MeshInstance3D = h.node
	item.position = item.position.lerp(pos,1.-exp(-delta*14.))
	var pouring: bool = h.id=="Jug" and item.position.distance_to(plant.position+Vector3.UP*.21)<.34
	item.rotation.x = lerp_angle(item.rotation.x,1.03 if pouring else 0.,minf(delta*9.,1.))
	if pouring:
		h.pour += delta
		if not streams.has(hand):
			var stream := Node3D.new()
			room.add_child(stream)
			for i in 11: gem(stream,.0075+.0025*(i%3),Color("#9fdcf2"))
			streams[hand]=stream
		var lip := item.position+item.basis*Vector3(0,.16,.20)
		var earth := plant.position+Vector3(.015,.02,.018)
		# A spout arc: water leaves the lip level and curves down into the soil, drops moving along it.
		var bend := Vector3(earth.x,lip.y,earth.z).lerp(lip,.35)
		var stream: Node3D = streams[hand]
		for i in stream.get_child_count():
			var u := fposmod(float(i)/stream.get_child_count()+scene_time*2.4,1.)
			var drop: Node3D = stream.get_child(i)
			drop.position = lip.lerp(bend,u).lerp(bend.lerp(earth,u),u)
		var voice: Dictionary = pour_voice.get(hand,{})
		if voice.is_empty() or scene_time-float(voice.at)>1.35:
			pour_voice[hand] = {"token":sound.cue("pour",earth,-10.,1.,1),"at":scene_time}
		if h.pour>.38 and not archive.wet:
			archive.water(Clock.milliseconds())
			redraw_plant()
			pulse.emit(hand,.50,.12)
	else:
		h.pour = 0.
		stop_stream(hand)

func stop_stream(hand: String) -> void:
	if streams.has(hand):
		streams[hand].queue_free()
		streams.erase(hand)
	if pour_voice.has(hand):
		sound.stop_voice(int(pour_voice[hand].token))
		pour_voice.erase(hand)

func release(hand: String,ray: Variant) -> bool:
	var open_films: bool = owners.get(hand) is String
	if not owners.erase(hand): return false
	if open_films:
		if ray!=null and is_finite(idle_mirror(ray)) and target(ray)=="": film_library_requested.emit()
		return true
	volume.release_hand(hand,ray==null)
	if spell == WandSpells.FISH:
		if ray == null: magic.untrack(hand)
		else:
			var r := local_ray(ray)
			magic.release_fish(hand,r[0]+r[1]*Wand.LENGTH,r[1],models)
	if not held.has(hand): return true
	var h: Dictionary = held[hand]
	held.erase(hand)
	stop_stream(hand)
	var item: MeshInstance3D = h.node
	if h.id=="Jug": models.get_node("Jug").visible=true
	if h.id=="Jug" or ray==null or target(ray,"Kettle")!="Kettle" or flying.size()+archive.batch.size()>=3:
		item.queue_free()
		refresh_shelf()
		return true
	var id := int(str(h.id).right(1))
	flying[id] = hand
	var finish := BROTH+node_offset("Kettle")
	var tween := create_tween()
	var start := item.position
	tween.tween_method(func(t: float):
		item.position = start.lerp(finish,t)+Vector3.UP*(.54*sin(PI*t))
		item.rotation.z=t*2.8
		item.scale=Vector3.ONE*(1.-.82*t)
	,0.,1.,.53)
	tween.tween_callback(func():
		item.queue_free()
		var thrower: String = flying.get(id,"")
		flying.erase(id)
		deposit(id)
		if thrower!="": pulse.emit(thrower,.35,.06)
	)
	return true

func deposit(id: int) -> void:
	var result := archive.add_dose(id,wall())
	refresh_shelf()
	clear(kettle_marks)
	for index in archive.batch.size():
		var bead := gem(kettle_marks,.042,Color.from_hsv(float(archive.batch[index])/6.,.7,1.))
		bead.position = BROTH+Vector3(-.23,.09,.09-index*.17)
	if result.is_empty(): sound.cue("ingredient",BROTH,-5.,.88+.10*archive.batch.size())
	else:
		display_spell(result.effect)
		if result.new: bookmark_time=6.
		if volume.visible and volume.kind=="Recipe": volume.rebuild(wall(),result.new)

func cancel(hand: String) -> void:
	volume.release_hand(hand,true)
	if magic: magic.untrack(hand)
	owners.erase(hand)
	stop_stream(hand)
	if wands.has(hand):
		wands[hand].visible = false
		focus_lamps[hand].visible = false
		beams[hand].visible = false
	set_hover(hand,"")
	if held.has(hand):
		if held[hand].id=="Jug": models.get_node("Jug").visible=true
		held[hand].node.queue_free()
		held.erase(hand)
		refresh_shelf()

func display_spell(id: int) -> void:
	reset_spell()
	# A dose still in flight can land while the camera view is up; show it on return.
	if not visible:
		pending_spell = id
		return
	spell = id
	age = 0.
	if id >= WandSpells.FIRE:
		if not magic:
			magic = WandSpells.new()
			magic.surfaces = spell_surfaces
			magic.sound = sound
			room.add_child(magic)
			magic.set_room_light(brightness*light_fraction)
		magic.activate(id)
		for wand: Wand in wands.values(): wand.tint(WandSpells.TINT[id-WandSpells.FIRE])
		sound.cue("attune",BROTH,-5.,1.,2)
		return
	var source := BROTH
	if id in [1,3,5,6]: source = Vector3(3.5,1.99,-4.94)
	elif id in [2,7]: source = ARCH
	elif id in [0,8,9]: source = Vector3(0,2.75,-2.)
	sound.cue("brew_fail" if id<0 else Sound.SCENES[id],source,-5.,1.,2)
	wall_ivy.visible = id==8
	if wall_ivy.visible: ivy_growth.set_shader_parameter("height",0.)
	if id>=0:
		if not show_fx:
			show_fx=Apparitions.new()
			room.add_child(show_fx)
			show_fx.set_room_light(brightness*light_fraction)
		show_fx.open(id)
	for i in (17 if id==-1 else 0):
		var shape := Node3D.new()
		ritual.add_child(shape)
		gem(shape,.09,Color("#29242e"))
	for mat in skies: mat.set_shader_parameter("spell",id)

func reset_spell() -> void:
	if spell >= WandSpells.FIRE:
		magic.clear_magic()
		for wand: Wand in wands.values(): wand.tint(Wand.DEFAULT_GLOW)
	sound.quiet()
	spell = -2
	age = 0.
	wall_ivy.visible = false
	if show_fx: show_fx.stop()
	if spell_tint != Color.WHITE or last_flash > 0.:
		spell_tint = Color.WHITE
		last_flash = 0.
		apply_room_light()
	room.position = Vector3.ZERO
	for id in homes: models.get_node(id).position=homes[id]
	clear(ritual)
	for mat in skies: mat.set_shader_parameter("spell",-2)

func tick(delta: float, now: int, pose: Variant) -> void:
	if archive.advance(now):
		redraw_plant()
		if volume.visible and volume.kind=="Herbal": volume.rebuild(wall())
	if not visible: return
	if pose!=null: eye = pose
	scene_time += delta
	bookmark_time = maxf(0.,bookmark_time-delta)
	bookmark.visible = bookmark_time>0.
	if bookmark.visible:
		bookmark.position = Vector3(homes.Journal)+node_offset("Journal")+Vector3(.14,.32+.038*sin(scene_time*3.),0)
	if spell!=-2 and not (spell >= WandSpells.FIRE and volume.visible):
		age += delta
		if age >= (magic.expires_at if spell >= WandSpells.FIRE else 8.): reset_spell()
		elif spell >= WandSpells.FIRE:
			magic.step(delta,BROTH)
			if not is_equal_approx(magic.flash,last_flash):
				last_flash = magic.flash
				apply_room_light()
			# The wand's colour drains back toward plain gold as the ability runs out.
			var left := clampf((magic.expires_at-magic.elapsed)/magic.expires_at,0.,1.)
			for wand: Wand in wands.values(): wand.tint(Wand.DEFAULT_GLOW.lerp(WandSpells.TINT[spell-WandSpells.FIRE],.25+.75*left))
	if spell==0:
		var lift := pow(sin(PI*age/8.),2.)
		# The viewer rises with the settle: the floor and walls fall away while the furniture
		# drifts around eye height. A playing film keeps the shallow drop so it barely moves.
		var drop := .24 if movie else .80
		room.position.y = -drop*lift
		for id in homes:
			# The hearth and its fire stay on the floor; a floating stone plinth read as a mistake.
			if id in ["Shell","Lead","MirrorSeal","Kettle","Fire"]: continue
			var rise := drop if id=="Settle" else .79+.12*sin(age*1.2+float(str(id).length()))
			models.get_node(id).position=Vector3(homes[id])+Vector3.UP*lift*rise
	plant.position=SOIL+node_offset("Plant")
	kettle_marks.position=node_offset("Kettle")
	if wall_ivy.visible:
		ivy_growth.set_shader_parameter("height",4.50*smoothstep(0.,3.65,age)*(1.-smoothstep(6.2,8.,age)))
	if spell>=0 and spell<10:
		show_fx.step(spell,age,movie,sound)
		var strength:=smoothstep(0.,1.30,age)*(1.-smoothstep(6.4,8.,age))
		spell_tint=Color.WHITE.lerp(Apparitions.TONES[spell],strength*.45)
		apply_room_light()
	for i in ritual.get_child_count():
		var piece: Node3D=ritual.get_child(i)
		var t := age+i*.79
		match spell:
			-1:
				var rise:=fposmod(age*.67+i*.11,1.)
				piece.position=BROTH+Vector3(sin(t*2.)*.18,.1+rise*1.5,cos(t)*.16)
				piece.scale=Vector3.ONE*(.4+rise*1.8)*minf(1.,(8.-age))
	for i in pearls.get_child_count():
		var bead: Node3D=pearls.get_child(i)
		var s := (.038+archive.stage*.052)
		bead.position=plant.position+Vector3(cos(i*2.4)*s,.08+(i%4)*(.012+archive.stage*.024),sin(i*2.4)*s)
		bead.scale=Vector3.ONE*(.60+.45*pow(.5+.5*sin(scene_time*3.1+i),4.))
	for i in plant_glow.get_child_count():
		var p: Node3D=plant_glow.get_child(i)
		var a:=scene_time*(.4+.04*(archive.species%5))+i*TAU/7.
		p.position=plant.position+Vector3(cos(a)*.22,.15+fposmod(scene_time*.09+i*.047,.47),sin(a)*.22)
	models.get_node("Fire").scale.y=1.+.12*sin(scene_time*9.)
	for mat in skies:
		mat.set_shader_parameter("clock",scene_time)
		mat.set_shader_parameter("age",age)
	if volume.visible and volume.kind=="Recipe" and journal_stale!=(wall()-archive.unlocked_at>3600):
		journal_stale = not journal_stale
		volume.rebuild(wall())

func set_film(active: bool) -> void:
	if active==movie: return
	movie=active
	sound.set_movie(active)
	skies[0].set_shader_parameter("playing",movie)

func set_brightness(value: float) -> void:
	if is_equal_approx(brightness,value): return
	brightness=value
	apply_room_light()

func prepare_room_materials(item: MeshInstance3D) -> void:
	if item.mesh == null: return
	for surface in item.mesh.get_surface_count():
		var sheen := item.get_active_material(surface) as ShaderMaterial
		if sheen:
			if not room_shaders.has(sheen): room_shaders[sheen] = sheen.duplicate()
			item.set_surface_override_material(surface, room_shaders[sheen])
			continue
		var base := item.get_active_material(surface) as BaseMaterial3D
		if base == null: continue
		if not room_materials.has(base): room_materials[base] = base.duplicate()
		item.set_surface_override_material(surface, room_materials[base])

func fade_lights(target_fraction: float, delta: float) -> void:
	var next := move_toward(light_fraction, target_fraction, delta * .85)
	if is_equal_approx(next, light_fraction): return
	light_fraction = next
	apply_room_light()

func apply_room_light() -> void:
	var level := brightness * light_fraction
	# Matches the dimming the room had when its colour and its real-time lights both followed the level.
	var baked := pow(level, 1.23)
	# A fireball burst warms nearby stone the way its old point light did, now through the materials.
	var tint := Color(spell_tint.r*(1.+.55*last_flash),spell_tint.g*(1.+.36*last_flash),spell_tint.b*(1.+.16*last_flash))
	for base: BaseMaterial3D in room_materials:
		var material: BaseMaterial3D = room_materials[base]
		var color := base.albedo_color
		material.albedo_color = Color(color.r * baked * tint.r, color.g * baked * tint.g, color.b * baked * tint.b, color.a)
		material.emission_energy_multiplier = base.emission_energy_multiplier * level
	for mat: ShaderMaterial in room_shaders.values(): mat.set_shader_parameter("room_light", Vector3(baked*tint.r, baked*tint.g, baked*tint.b))
	for mat in skies: mat.set_shader_parameter("brightness", level)
	ivy_growth.set_shader_parameter("room_light",level)
	plant.material_override.set_shader_parameter("room_light",level)
	if show_fx: show_fx.set_room_light(level)
	if magic: magic.set_room_light(level)
