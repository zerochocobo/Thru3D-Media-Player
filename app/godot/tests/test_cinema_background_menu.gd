extends SceneTree
const Menu:=preload("res://scripts/scenery_menu.gd")
const Catalog:=preload("res://scripts/background_library.gd")
const I18n:=preload("res://scripts/i18n.gd")
var checks:=0
var failures: Array=[]
var events: Array=[]
func check(value: bool,text: String) -> void:
	checks+=1
	if not value: failures.append(text); printerr(text)
func target(menu: Node3D,key: String,value: Variant=null,kind: String="choose") -> int:
	for id in menu.choices.targets:
		var item: Dictionary=menu.choices.targets[id]
		if item.get("kind")==kind and item.get("key")==key and (kind=="open" or item.get("value")==value): return id
	return -1
func button(menu: Node3D,id: int) -> Dictionary:
	for item in menu._buttons:
		if item.target==id: return item
	return {}
func origin(menu: Node3D,id: int) -> Vector3:
	var item:=button(menu,id)
	return item.node.global_position+item.node.global_basis.z*.5 if not item.is_empty() else Vector3.ZERO
func tap(menu: Node3D,id: int) -> void:
	var point:=origin(menu,id)
	menu.press_pointer("left_hand",point,-menu.global_basis.z,true)
	menu.release_pointer("left_hand",point,-menu.global_basis.z,true)
func _initialize() -> void: _run.call_deferred()
func _run() -> void:
	I18n.use("en")
	var state: Dictionary={"selected":"cinema","choice":"cinema","cinema_ready":true,"cinema_lights":"auto","cinema_interaction":"watch","cinema_viewing_brightness":"low","cinema_screen_light":true,"status":""}
	var library:=Catalog.new(); library.directory=ProjectSettings.globalize_path("res://../../build/output/cinema-menu-fixture"); root.add_child(library)
	var menu:=Menu.new(); menu.library=library; menu.state_provider=func(_mode): return state
	menu.command.connect(func(operation,value):
		if operation=="adjust": events.append([value.key,value.value]); state[value.key]=value.value
		elif operation=="home": events.append(["cinema_home",true]))
	root.add_child(menu); menu.open("global")
	check(menu._cards.any(func(item): return item.id=="cinema" and item.title=="Grand cinema"),"Scene cards include final cinema name")
	check(not menu._buttons.any(func(item): return item.target in [menu.FREE_MOVEMENT,menu.CINEMA_LIGHTS]),"Cinema shortcuts leave the shared footer")
	tap(menu,menu.ADJUST)
	check(menu.view=="adjust","Scene adjustment opens by ray")
	check(target(menu,"background_yaw",null,"open")<0,"Cinema has no panorama direction field")
	check(target(menu,"cinema_interaction","move")>=0,"Movement lives in scene adjustments")
	check(target(menu,"cinema_screen_light",false)>=0,"Screen light is an independent switch")
	for level in ["soft","dim","low"]:
		tap(menu,target(menu,"cinema_viewing_brightness",null,"open")); tap(menu,target(menu,"cinema_viewing_brightness",level))
		check(events.back()==["cinema_viewing_brightness",level],"Ray dispatches viewing brightness "+level)
	tap(menu,target(menu,"cinema_screen_light",false))
	check(events.back()==["cinema_screen_light",false],"Ray dispatches screen light")
	var before:=events.size(); var move:=target(menu,"cinema_interaction","move"); var point:=origin(menu,move)
	menu.press_pointer("left_hand",point,-menu.global_basis.z,true)
	check(events.size()==before,"Choice waits for trigger release")
	menu.release_pointer("right_hand",point,-menu.global_basis.z,true)
	check(events.size()==before,"Other hand cannot commit capture")
	menu.release_pointer("left_hand",point,-menu.global_basis.z,true)
	check(events.back()==["cinema_interaction","move"],"Owning hand enables movement")
	tap(menu,menu.CURRENT)
	check(events.back()==["cinema_home",true],"Return to start uses the existing setting action")
	state.cinema_ready=false; state.status="Loading cinema…"; menu.choices.reset(); menu.refresh()
	check(not button(menu,menu.CURRENT).enabled,"Loading disables return to start")
	for value in ["watch","move"]: check(not button(menu,target(menu,"cinema_interaction",value)).enabled,"Loading disables interaction "+value)
	before=events.size(); tap(menu,target(menu,"cinema_interaction","watch")); tap(menu,menu.CURRENT)
	check(events.size()==before,"Loading cannot dispatch disabled actions")
	state.cinema_ready=true; state.status=""
	for language in ["zh","zh_Hant","ja","en"]:
		I18n.use(language); menu.refresh()
		for value in ["watch","move"]:
			var control:=button(menu,target(menu,"cinema_interaction",value))
			var label: Label3D=control.node.get_child(0)
			check(menu.text_width(label.text,int(label.font_size/menu.TEXT_RASTER_SCALE))<=control.rect.size.x,"Interaction text fits "+language+value)
			check(int(menu.ray_hit(origin(menu,int(control.target)),-menu.global_basis.z).get("target",-1))==int(control.target),"Interaction target remains unobstructed "+language+value)
		for text in ["Scene","Image mode","Cinema lighting","Viewing brightness","Free movement","Return to start"]:
			check(language=="en" or I18n.t(text)!=text,"Translation exists "+language+text)
	menu.free(); library.free()
	print("CINEMA_BACKGROUND_MENU checks=%d failures=%d"%[checks,failures.size()]); quit(0 if failures.is_empty() else 1)
