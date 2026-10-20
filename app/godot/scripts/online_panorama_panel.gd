extends RefCounted
# Paused pending reliable original-image downloads across the source websites.
const AVAILABLE := false
const I18n := preload("res://scripts/i18n.gd")
const Methods := preload("res://scripts/platform_methods.gd")
const BASE := 27000
const WEB := BASE + 20
const KEY := BASE + 100
const SOURCES := [
	{"name":"NOIRLab", "tag":"20K+ · JPG", "topic":"Night skies", "url":"https://noirlab.edu/public/images/archive/category/360pano/"},
	{"name":"ESO", "tag":"20K+ · JPG", "topic":"Observatories", "url":"https://www.eso.org/public/images/archive/category/360pano/"},
	{"name":"Wikimedia Commons", "tag":"16K+ · JPG", "topic":"Around the world", "url":"https://commons.wikimedia.org/wiki/Category:360%C2%B0_panoramas", "zh":"https://commons.wikimedia.org/wiki/Category:360%C2%B0_panoramas?uselang=zh"},
	{"name":"Poly Haven", "tag":"8K · JPG", "topic":"Nature and interiors", "url":"https://polyhaven.com/hdris", "zh":"https://polyhaven.com/zh/hdris"}
]
const KEYS := ["1234567890", "qwertyuiop", "asdfghjkl.", "zxcvbnm-_@"]
var menu: Node3D
var platform: Object
var opened := false
var browsing := false
var chinese_only := false
var source := -1
var data := {}
var texture: ImageTexture
var web_node: MeshInstance3D
var status_label: Label3D
var hand := ""
var point := Vector2.ZERO
var _time := 0.0
var _layout := ""
var shift := false
var consumed := ""
var _closed := false

func _init(owner: Node3D) -> void: menu = owner
func supported() -> bool: return Methods.supports(platform,"panorama_browse")
func open() -> void:
	opened = true
	if browsing and supported(): platform.panorama_browser_pause(false)
	menu.refresh()
func hide(keep_download: bool = false) -> void:
	cancel()
	opened = false
	if supported():
		if not keep_download: action("download_cancel")
		platform.panorama_browser_pause(true)
func shutdown() -> void:
	hide(); _closed = true
	if supported(): platform.panorama_browser_action("download_cancel",0.0,0.0,"")
	texture = null
func action(operation: String, uv: Vector2 = Vector2.ZERO, value: String = "") -> void:
	if supported(): platform.panorama_browser_action(operation,uv.x,uv.y,value)
func back() -> bool:
	if not opened: return false
	if not hand.is_empty(): cancel(); return true
	if data.get("editing",false): action("keyboard_close"); return true
	if browsing:
		if data.get("can_back",false): action("back")
		else: browsing = false; action("download_cancel"); platform.panorama_browser_pause(true); menu.refresh()
	else: hide(); menu.refresh()
	return true
func tick(delta: float) -> void:
	if _closed or not opened or not menu.visible or not supported(): return
	_time += delta
	if _time < 0.2 or not browsing: return
	_time = 0.0
	var parsed: Variant = JSON.parse_string(platform.panorama_browser_status())
	if parsed is Dictionary: data = parsed
	var frame: PackedByteArray = platform.panorama_browser_frame()
	if not frame.is_empty():
		var image := Image.new()
		if image.load_jpg_from_buffer(frame)==OK:
			if texture==null: texture=ImageTexture.create_from_image(image)
			else: texture.update(image)
			if is_instance_valid(web_node): web_node.material_override.albedo_texture=texture
	var downloaded: Dictionary=data.get("download",{})
	if downloaded.get("state")=="ready" and not str(downloaded.get("uri","")).is_empty() and downloaded.uri!=consumed and hand.is_empty():
		# Opening this directory establishes panoramic intent; ordinary library images retain their own modes.
		_play(downloaded,int(downloaded.width)==2*int(downloaded.height))
		return
	var next := str([data.get("editing",false),data.get("title",""),data.get("download",{}).get("state",""),data.get("download",{}).get("error","")])
	if next!=_layout and hand.is_empty(): menu.refresh()
	if is_instance_valid(status_label): status_label.text=_status()
	menu.composition_changed.emit()
func _status() -> String:
	var file: Dictionary = data.get("download",{})
	if file.get("state")=="loading":
		var count := float(file.get("bytes",0))/1048576.0
		var total := float(file.get("total",0))/1048576.0
		return I18n.t("Downloading image")+"  %.1f / %.1f MB" % [count,total] if total>0 else I18n.t("Downloading image")+"  %.1f MB" % count
	if file.get("state")=="ready": return "%d × %d" % [int(file.width),int(file.height)]
	return I18n.t(str(file.get("error",data.get("status",""))))
func draw() -> void:
	_layout = str([data.get("editing",false),data.get("title",""),data.get("download",{}).get("state",""),data.get("download",{}).get("error","")])
	web_node=null; status_label=null
	if not browsing: _directory(); return
	_web()
func _directory() -> void:
	menu._set_backdrop(Vector2(1.70,1.10))
	menu._button(BASE+1,"",Vector2(-0.73,0.46),Vector2(0.09,0.07),true,"up")
	menu._label(I18n.t("Online panoramas"),Vector3(0,0.46,0.006),25)
	menu._button(menu.CLOSE,"",Vector2(0.73,0.46),Vector2(0.09,0.07),true,"close")
	for index in 2:
		menu._button(BASE+2+index,I18n.t("All websites" if index==0 else "Chinese interfaces"),Vector2(-0.24+index*0.48,0.31),Vector2(0.44,0.08),true,"",chinese_only==(index==1))
	var shown := 0
	for index in SOURCES.size():
		var item: Dictionary=SOURCES[index]
		if chinese_only and not item.has("zh"): continue
		var centre := Vector2(-0.39+(shown%2)*0.78,0.105-(shown/2)*0.26)
		menu._button(BASE+10+index,"",centre,Vector2(0.72,0.225),supported())
		var node: Node3D=menu._buttons.back().node
		menu._label(I18n.t(item.name),Vector3(0,0.054,0.007),22,node)
		menu._label(str(item.tag),Vector3(0,0.0,0.007),17,node).modulate=menu.ACCENT
		menu._label(I18n.t(item.topic),Vector3(0,-0.055,0.007),16,node).modulate=menu.MUTED
		shown+=1
	if not supported(): menu._label(I18n.t("Web browsing is unavailable on this device"),Vector3(0,-0.40,0.008),17)
func web_rect() -> Rect2: return Rect2(-0.86,-0.38,1.72,1.032)
func _web() -> void:
	var editing: bool=data.get("editing",false)
	menu._set_backdrop(Vector2(1.94,1.95 if editing else 1.42),Vector2(0,-0.12 if editing else 0.13))
	for spec in [[1,-0.85,"up"],[4,-0.71,"back"],[5,-0.57,"refresh"],[9,0.41,"image"],[6,0.55,"minus"],[7,0.69,"plus"]]:
		menu._button(BASE+int(spec[0]),"",Vector2(float(spec[1]),0.75),Vector2(0.10,0.08),true,str(spec[2]))
	menu._button(menu.CLOSE,"",Vector2(0.85,0.75),Vector2(0.10,0.08),true,"close")
	menu._label(menu._fit_title(I18n.t(SOURCES[source].name),"",0.88,22),Vector3(0,0.75,0.009),22)
	var rect:=web_rect()
	menu._button(WEB,"",rect.get_center(),rect.size)
	web_node=MeshInstance3D.new(); var mesh:=QuadMesh.new(); mesh.size=rect.size; web_node.mesh=mesh
	web_node.position=Vector3(rect.get_center().x,rect.get_center().y,0.007)
	var mat: StandardMaterial3D=menu._material(Color.WHITE,13); mat.albedo_texture=texture; web_node.material_override=mat
	menu.add_child(web_node); menu._decorations.append(web_node)
	status_label=menu._label(_status(),Vector3(0,-0.44,0.008),16)
	var file: Dictionary=data.get("download",{})
	if file.get("state")=="loading": menu._button(BASE+8,I18n.t("Cancel"),Vector2(0,-0.55),Vector2(0.40,0.075))
	if file.get("state")=="ready":
		menu._button(BASE+30,"360°",Vector2(-0.22,-0.56),Vector2(0.36,0.08),int(file.width)==2*int(file.height),"globe",true)
		menu._button(BASE+31,I18n.t("Flat"),Vector2(0.22,-0.56),Vector2(0.36,0.08),true,"image")
	if editing:
		for row in 4:
			for column in 10:
				var key: String=KEYS[row][column]
				menu._button(KEY+row*10+column,key.to_upper() if shift else key,Vector2(-0.73+column*0.16,-0.64-row*0.085),Vector2(0.15,0.075))
		for spec in [[40,"⇧",-0.67],[41,"␣",-0.32],[42,"⌫",0.03],[43,"↵",0.38],[44,"↓",0.73]]:
			menu._button(KEY+int(spec[0]),str(spec[1]),Vector2(float(spec[2]),-1.0),Vector2(0.27,0.075))
func activate(target: int) -> bool:
	if not opened: return false
	if target==menu.CLOSE: hide(); menu.refresh(); return true
	if target>=KEY and target<KEY+45:
		var value:=target-KEY
		if value<40:
			var key: String=KEYS[value/10][value%10]; action("text",Vector2.ZERO,key.to_upper() if shift else key)
		elif value==40: shift=not shift; menu.refresh()
		elif value==41: action("text",Vector2.ZERO," ")
		elif value==42: action("backspace")
		elif value==43: action("enter")
		else: action("keyboard_close")
		return true
	if target<BASE or target>BASE+31: return true
	match target-BASE:
		1:
			if browsing: cancel(); action("download_cancel"); platform.panorama_browser_pause(true); browsing=false
			else: hide()
			menu.refresh()
		2,3: chinese_only=target==BASE+3; menu.refresh()
		4: action("back")
		5: action("reload")
		6: action("zoom_out")
		7: action("zoom_in")
		8: action("download_cancel")
		9: action("open_image")
		10,11,12,13:
			if not supported(): return true
			source=target-BASE-10; browsing=true; data={}; texture=null
			var item: Dictionary=SOURCES[source]
			platform.panorama_browse(str(item.get("zh",item.url)) if I18n.language in ["zh","zh_Hant"] or chinese_only else str(item.url))
			menu.refresh()
		30,31:
			var item: Dictionary=data.get("download",{}).duplicate(true)
			if item.get("state")!="ready": return true
			_play(item,target==BASE+30)
	return true
func _play(downloaded: Dictionary, spherical: bool) -> void:
	var item:=downloaded.duplicate(true)
	consumed=str(item.get("uri",""))
	item["website"]=I18n.t(SOURCES[source].name)
	hide(true); menu.refresh(); menu.online_image_requested.emit(item,spherical)
func uv(p: Vector3) -> Vector2:
	var rect:=web_rect(); return Vector2((p.x-rect.position.x)/rect.size.x,1.0-(p.y-rect.position.y)/rect.size.y)
func press(owner: String, origin: Vector3, direction: Vector3, tracked: bool) -> bool:
	if not hand.is_empty(): return true
	if not opened or not browsing or not tracked: return false
	var hit: Dictionary=menu.ray_hit(origin,direction)
	if int(hit.get("target",-1))!=WEB: return false
	hand=owner; point=uv(hit.point); action("down",point); return true
func move(owner: String, origin: Vector3, direction: Vector3, tracked: bool) -> void:
	if owner!=hand: return
	if not tracked or not menu.visible: cancel(); return
	var p: Variant=menu.project_pointer(origin,direction,Transform3D.IDENTITY)
	if p==null: cancel(); return
	point=uv(p); action("move",point)
func release(owner: String, origin: Vector3, direction: Vector3, tracked: bool) -> bool:
	if owner!=hand: return false
	var p: Variant=menu.project_pointer(origin,direction,Transform3D.IDENTITY) if tracked else null
	if p==null or not web_rect().has_point(Vector2(p.x,p.y)): cancel()
	else: action("up",uv(p)); hand=""
	return true
func cancel() -> void:
	if not hand.is_empty(): action("cancel",point)
	hand=""
func scroll(amount: float, delta: float) -> void:
	if browsing and hand.is_empty() and absf(amount)>0.2: action("scroll",Vector2(0,-amount*delta*6.0))
