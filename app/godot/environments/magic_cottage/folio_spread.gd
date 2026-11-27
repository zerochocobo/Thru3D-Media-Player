extends Node
## Typeset one spread into two GPU textures. Refresh once per edit or page change.
const Menu := preload("res://scripts/ray_menu.gd")
const Plant := preload("specimen.gd")
const Discovery := preload("discovery.gd")
var ink := Color("#422a36")
var heading := Color("#683647")
var pages := Node3D.new()
var marks := Node3D.new()
var views: Array[SubViewport] = []

func _ready() -> void:
	var paper_world := World3D.new()
	var environment := Environment.new()
	environment.background_mode=Environment.BG_COLOR
	environment.background_color=Color("#deca9f")
	environment.ambient_light_source=Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color=Color.WHITE
	environment.ambient_light_energy=.76
	paper_world.environment=environment
	for side in [-1.,1.]:
		var view:=SubViewport.new()
		view.world_3d=paper_world
		view.size=Vector2i(720,834)
		view.render_target_update_mode=SubViewport.UPDATE_DISABLED
		add_child(view)
		var camera:=Camera3D.new()
		camera.projection=Camera3D.PROJECTION_ORTHOGONAL
		camera.size=.451
		camera.position=Vector3(side*.195,0,1.)
		view.add_child(camera)
		camera.current=true
		views.append(view)
	views[0].add_child(pages)
	pages.add_child(marks)
	for x in [-.195,.195]:
		slab(pages,Vector3(x,0,0),Vector3(.392,.451,.02),Color("#e4cf9d"))
		slab(pages,Vector3(x,.130,.016),Vector3(.235,.0018,.002),Color("#916f44"))
	var lamp:=DirectionalLight3D.new()
	lamp.rotation_degrees=Vector3(-38,-28,0)
	lamp.light_energy=.65
	pages.add_child(lamp)

func slab(parent: Node, pos: Vector3, size: Vector3, colour: Color) -> void:
	var part := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = size
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = colour
	box.material = mat
	if is_equal_approx(size.z,.02):
		var vellum := ShaderMaterial.new()
		vellum.shader = preload("vellum.gdshader")
		box.material = vellum
	part.mesh = box
	part.position = pos
	parent.add_child(part)

func label(value: String,x: float,y: float, size: float,color: Color) -> void:
	var text := Label3D.new()
	text.text = value
	text.font = Menu.ui_font()
	text.font_size = 48
	text.pixel_size = size/48.
	text.outline_size = 0
	text.modulate = color
	text.position = Vector3(x,y,.027)
	marks.add_child(text)

func icon(id: int, x: float, y: float) -> void:
	var item := Sprite3D.new()
	item.texture = load("res://environments/magic_cottage/ingredients.png")
	item.hframes = 6
	item.frame = id
	item.pixel_size = .00040
	item.position = Vector3(x,y,.028)
	marks.add_child(item)

func equation(entry: Dictionary, y: float, paired: bool) -> void:
	var key: String = entry.key
	for i in 3:
		var x := -.325+i*.122
		if i < int(entry.visible): icon(int(key[i]),x,y)
		else: label("?",x,y,.038 if paired else .047,heading)
		if i<2: label("+",x+.061,y,.022,ink)
	var id: int = Discovery.FORMULAS[key]
	label(Discovery.EFFECTS[id],.193,y+(.03 if paired else 0.),.025 if paired else .032,heading)
	var verse: String = Discovery.VERSES[id]
	verse = verse.replace("绕着炉火","\n绕着炉火").replace("一同浮起","\n一同浮起").replace("卷入黑洞","\n卷入黑洞").replace("一样滑过","一样\n滑过").replace("窗棂生长","窗棂\n生长").replace("在空中巡游","\n在空中巡游")
	if verse.length()>9 and not "\n" in verse: verse = verse.left(6)+"\n"+verse.substr(6)
	label(verse,.193,y-.033 if paired else -.058,.016 if paired else .021,ink)
	if int(entry.visible)==3 and id in [10,12,19]:
		label("双窗来袭 · 击退四只",.193,-.116,.014,heading)

func paint(kind: String,entries: Array,page: int,archive: Discovery,atlas: Texture2D) -> void:
	for child in marks.get_children():
		marks.remove_child(child)
		child.queue_free()
	var title: String = {"Recipe":"魔药配方","Herbal":"草木志","Atlas":"群星图谱","Journal":"影像札记"}[kind]
	label(title,-.193,.162,.030,heading)
	label("‹",-.345,-.164,.043,heading)
	label("›",.345,-.164,.043,heading)
	label("%d / %d" % [page+1,maxi(1,entries.size())],.19,-.171,.015,ink)
	var entry: Dictionary = {} if entries.is_empty() else entries[page]
	if kind == "Recipe" and not entry.is_empty():
		for x in [-.195,.195]:
			slab(marks,Vector3(x,0,.018),Vector3(.313,.0018,.001),Color("#946d46"))
		if entry.has("second"):
			equation(entry,.068,true)
			equation(entry.second,-.065,true)
		else:
			equation(entry,.065,false)
			label("已验" if entry.visible==3 else "未竟手稿",-.193,-.083,.018,heading)
	elif kind == "Herbal":
		if entry.has("pot"):
			pot(archive)
		elif entry.is_empty():
			label("初叶待录",.194,.025,.032,ink)
		else:
			var plant := Plant.new()
			marks.add_child(plant)
			plant.position = Vector3(-.19,-.102,.065)
			plant.scale = Vector3.ONE*.39
			plant.build(entry.id,2)
			label(Discovery.SPECIES[entry.id],.19,.045,.035,ink)
			label("已育成  %d / 10"%archive.herbs.size(),.19,-.035,.019,heading)
	elif kind == "Atlas":
		var art := Sprite3D.new()
		art.texture = atlas
		art.hframes = 8
		art.vframes = 8
		art.frame = page
		art.pixel_size = .00084
		art.position = Vector3(-.19,-.004,.025)
		marks.add_child(art)
		label("星图  %02d"%(page+1),.19,.02,.033,ink)
	elif kind == "Journal":
		label("藏星阁",.19,.07,.037,heading)
		label("以星为幕\n以夜为镜",.19,-.028,.025,ink)
	for view in views: view.render_target_update_mode=SubViewport.UPDATE_ONCE

## The pot on the dresser: its plant as it is now, a growth track with three stages, water, and the
## ten-slot collection.
func pot(archive: Discovery) -> void:
	var plant := Plant.new()
	marks.add_child(plant)
	plant.position = Vector3(-.19,-.102,.065)
	plant.scale = Vector3.ONE*.39
	plant.build(archive.species,archive.stage)
	var known := archive.herbs.has(archive.species)
	label(Discovery.SPECIES[archive.species] if known else "未名新芽",.19,.105,.030,heading)
	var grown := clampf(float(archive.effective_ms)/Discovery.FULL,0.,1.)
	const LEFT := .055
	const WIDTH := .27
	slab(marks,Vector3(LEFT+WIDTH*.5,.040,.020),Vector3(WIDTH,.010,.001),Color("#cdb487"))
	if grown>0.: slab(marks,Vector3(LEFT+WIDTH*grown*.5,.040,.021),Vector3(WIDTH*grown,.010,.001),Color("#6f9a4c"))
	var marks_at := [0.,float(Discovery.MIDDLE)/Discovery.FULL,1.]
	var names := ["新芽","抽叶","开花"]
	for i in 3:
		var reached := archive.stage>=i
		slab(marks,Vector3(LEFT+WIDTH*marks_at[i],.040,.022),Vector3(.016,.022,.001),Color("#6f9a4c") if reached else Color("#a88c62"))
		label(names[i],LEFT+WIDTH*marks_at[i],.006,.014,heading if reached else ink)
	label("已浇透 · 生长加倍" if archive.wet else "提壶浇水 · 生长加倍",.19,-.030,.017,ink if archive.wet else heading)
	for i in Discovery.SPECIES.size():
		var x := LEFT+.012+(i%5)*.0615
		var y := -.105-(i/5)*.036
		slab(marks,Vector3(x,y,.020),Vector3(.030,.030,.001),Plant.PALETTE[i] if archive.herbs.has(i) else Color("#c9b083"))
	label("已育成  %d / 10"%archive.herbs.size(),.19,-.072,.014,ink)

func side(index: int) -> Texture2D:
	return views[index].get_texture()
