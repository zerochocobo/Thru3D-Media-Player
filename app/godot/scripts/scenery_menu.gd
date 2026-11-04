extends "res://scripts/ray_menu.gd"
## One modal ray surface for every mode. The parent menu stays intact while hidden.
signal close_requested
signal command(operation: String, value: Variant)
const Fields := preload("res://scripts/choice_fields.gd")
const SELECTED := Color(0.16,0.31,0.27)
const TextInput := preload("res://scripts/system_text_input.gd")
const BUILTINS := [["cinema","Grand cinema"],["belfast","Belfast sunset"],["morning","Morning sky"],
	["night","Milky Way panorama"],["dark","Dark background"],["passthrough","Passthrough"]]
const CARD := 200000
const BACK := 10100
const ADD := 10101
const MANAGE := 10102
const BULK := 10103
const REMOVE := 10104
const CONFIRM := 10105
const RENAME := 10106
const EDIT := 10107
const SAVE := 10108
const ADJUST := 10109
const CURRENT := 10110
const REVIEW := 10111
const APPROVE := 10112
const SKIP := 10113
const SELECT_ALL := 10114
const MODE := 10200
const RENAMES := 400000
const REMOVES := 600000
var library: Node
var state_provider: Callable
var mode := "global"
var view := "scene"
var page := 0
var selected: Array = []
var bulk := false
var modal := ""
var draft := ""
var rename_id := ""
var choices := Fields.new(self)
var editor := TextInput.new(self)
var _cards: Array = []
var _state := {}
var _scroll := 0.0
var _drag := {}
var _signature := ""
var _poll := 0.0
var _top := .71
var _bottom := -.71
var _notice := ""
const LEFT := -.67
const RIGHT := .67
const CARD_SIZE := Vector2(.43,.28)

func _left(text: String, point: Vector2, size: int = TEXT_BODY, width: float = 1.30, ink: Color = Color.WHITE, parent: Node = self) -> Label3D:
	var label:=_label(_fit_title(text,"",width,size),Vector3(point.x,point.y,.009),size,parent)
	label.horizontal_alignment=HORIZONTAL_ALIGNMENT_LEFT
	label.render_priority=13
	label.modulate=ink
	return label

func _selected_title() -> String:
	var id:=str(_state.get("selected",""))
	if library.assets.has(id): return str(library.assets[id].title)
	for item in BUILTINS:
		if item[0]==id: return I18n.t(item[1])
	return ""

func _danger(target: int,text: String,centre: Vector2,size: Vector2,enabled: bool) -> void:
	_button(target,text,centre,size,enabled)
	var button: Dictionary=_buttons.back()
	button.base_color=Color(.24,.10,.12) if enabled else TILE
	button.foreground=Color(1,.63,.63) if enabled else MUTED
	button.node.material_override.set_shader_parameter("surface_color",button.base_color)
	for child in button.node.get_children():
		if child is Label3D: child.modulate=button.foreground

func _ready() -> void:
	super()
	choices.changed.connect(func(key,value): command.emit("adjust", {"mode":mode,"key":key,"value":value}); refresh())

func open(value: String) -> void:
	mode = value if library.valid_mode(value) else "global"
	view = "scene"; page = 0; modal = ""; bulk = false; selected.clear(); choices.reset(); _notice=""
	visible = true; refresh()

func begin_import() -> void:
	view="import"; page=0; modal=""; bulk=false; selected.clear(); _notice=""; choices.reset(); refresh()

func finish_import(result: Dictionary) -> void:
	modal=""; bulk=false; selected.clear(); page=0
	if not library.reviews.is_empty():
		view="review"; selected=library.reviews.keys().duplicate()
	elif int(result.get("added",0))+int(result.get("existing",0))>0:
		view="manage"
		_notice=I18n.t("Added %d backgrounds")%int(result.added) if int(result.added)>0 else I18n.t("Already in background library")
		var rows: Array=library.rows()
		var ids: Array=result.get("ids",[])
		for i in rows.size():
			if ids.has(str(rows[i].id)): page=i/6
	else: view="import_error"
	if int(result.get("failed",0))>0 and view!="import_error":
		_notice+=(" · " if not _notice.is_empty() else "")+I18n.t("%d images could not be added")%int(result.failed)
	refresh()

func dismiss() -> void:
	var was_visible:=visible
	editor.cancel(); choices.reset(); _drag.clear(); super()
	if was_visible: close_requested.emit()

func text_entry_active() -> bool: return editor.active()
func has_pointer_capture() -> bool: return not choices.capture.is_empty() or not _drag.is_empty()
func allows_playback_sticks() -> bool: return false

func navigate_back() -> bool:
	if editor.active(): editor.cancel(); return true
	if not choices.opened.is_empty(): choices.reset()
	elif not modal.is_empty(): modal = ""; selected.clear()
	elif view != "scene": view = "scene"; bulk = false; selected.clear(); page = 0
	else: return false
	refresh(); return true

func _process(delta: float) -> void:
	if not visible or not state_provider.is_valid() or has_pointer_capture() or editor.active(): return
	_poll+=delta
	if _poll<.25: return
	_poll=0
	var latest: Dictionary = state_provider.call(mode)
	var key := str(latest)
	if key != _signature: refresh()

func refresh() -> void:
	if not is_instance_valid(library): return
	_state = state_provider.call(mode) if state_provider.is_valid() else {}
	_signature = str(_state)
	_draw(); arrange_surfaces(); composition_changed.emit()

func _draw() -> void:
	_clear_layout(); choices.begin(mode + view + modal)
	var height:=1.42
	if not modal.is_empty(): height=.76 if modal=="delete" else .58
	elif view in ["manage","review"]:
		var count: int=library.reviews.size() if view=="review" else library.assets.size()
		height=.46+clampi(ceili(count/3.0),1,2)*.30
	elif view=="adjust": height=1.0 if _state.get("choice","")=="cinema" else .62
	elif view in ["import","import_error"]: height=.76
	_top=height/2; _bottom=-_top
	_set_backdrop(Vector2(1.50,height))
	var header_y:=_top-.10
	_button(CLOSE,"",Vector2(.64,header_y),Vector2(.075,.075),true,"close")
	var back:=view!="scene" or not modal.is_empty()
	if back: _glyph(BACK,"up",Vector2(-.65,header_y),.07,true,I18n.t("Back"))
	var title:=I18n.t("Scene")
	if modal=="delete": title=I18n.t("Remove")
	elif modal=="rename": title=I18n.t("Rename")
	elif view=="manage": title=I18n.t("Custom background management")
	elif view=="review": title=I18n.t("Confirm panoramas")
	elif view=="adjust": title=_selected_title()
	elif view in ["import","import_error"]: title=I18n.t("Add panorama")
	_left(title,Vector2(-.54 if back else LEFT,header_y),TEXT_PAGE_TITLE,.80).font=ui_bold_font()
	if modal.is_empty() and view == "scene":
		var modes: Array = library.visible_modes()
		for i in modes.size():
			_button(MODE+i,I18n.t(modes[i].label),Vector2(.12+i*.29,header_y),Vector2(.27,.065),true,"",modes[i].id==mode)
	elif modal.is_empty():
		for descriptor in library.visible_modes():
			if descriptor.id==mode:
				var scope_label:=_label(I18n.t(descriptor.label),Vector3(.51,header_y,.009),TEXT_AUX)
				scope_label.horizontal_alignment=HORIZONTAL_ALIGNMENT_RIGHT; scope_label.modulate=MUTED
	if modal == "delete": _draw_delete()
	elif modal == "rename":
		_button(EDIT,"",Vector2(0,_top-.27),Vector2(1.34,.09))
		_left(draft,Vector2(LEFT+.02,_top-.27),TEXT_BODY,1.25)
		_button(SAVE,I18n.t("Save"),Vector2(.51,_bottom+.09),Vector2(.30,.075),not draft.strip_edges().is_empty(),"",true)
		_button(BACK,I18n.t("Cancel"),Vector2(.16,_bottom+.09),Vector2(.30,.075))
	elif view == "adjust": _draw_adjust()
	elif view in ["import","import_error"]: _draw_import()
	else: _draw_cards()
	if view not in ["import","import_error"]:
		_left(_notice if not _notice.is_empty() else I18n.t(str(_state.get("status",""))),Vector2(LEFT,_bottom+.055),TEXT_AUX,.65 if not modal.is_empty() else 1.30,MUTED)
	# Attribution remains visible whenever the built-in Milky Way thumbnail is displayed.
	if modal.is_empty() and (view == "scene" or _state.get("choice","") == "night"):
		_left("ESO/S. Brunier · CC BY 4.0 · "+I18n.t("Preview adapted"),Vector2(LEFT,_bottom+.018),12,1.30,MUTED)
	choices.finish()

func _draw_import() -> void:
	var progress: Dictionary=_state.get("import_progress",{})
	if view=="import_error":
		_icon("image",Vector3(0,.12,.009),.10,MUTED)
		_label(I18n.t("No panorama was added"),Vector3(0,0,.009),TEXT_TITLE)
		_label(I18n.t(library.error),Vector3(0,-.08,.009),TEXT_BODY).modulate=MUTED
		_button(ADD,I18n.t("Choose images"),Vector2(.37,-.23),Vector2(.45,.075))
		_button(BACK,I18n.t("Back"),Vector2(-.14,-.23),Vector2(.45,.075))
		return
	_label(I18n.t("Preparing panorama previews"),Vector3(0,.12,.009),TEXT_TITLE)
	_label(_fit_title(str(progress.get("title","")),"",1.20,TEXT_BODY),Vector3(0,.02,.009),TEXT_BODY).modulate=MUTED
	var total:=maxi(1,int(progress.get("total",1)))
	var completed:=int(progress.get("completed",0))
	_label("%d / %d"%[completed,total],Vector3(0,-.09,.009),TEXT_TITLE)
	var track:=_quad(Vector2(1.02,.012),Vector3(0,-.18,.009),TILE,12); add_child(track); _decorations.append(track)
	var fraction:=maxf(.015,float(completed)/total)
	var fill:=_quad(Vector2(1.02*fraction,.012),Vector3(-.51+fraction*.51,-.18,.012),ACCENT,13); add_child(fill); _decorations.append(fill)

func _draw_cards() -> void:
	_cards.clear()
	if view == "scene":
		for item in BUILTINS:
			if library.allowed(mode,item[0]): _cards.append({"id":item[0],"title":I18n.t(item[1]),"builtin":true})
		var builtin_count:=_cards.size()
		_left(I18n.t("Built-in scenes"),Vector2(LEFT,.475),TEXT_BODY,1.0)
		_left(I18n.t("My backgrounds") + " · %d" % library.assets.size(),Vector2(LEFT,-.195),TEXT_BODY,.50)
		_button(MANAGE,I18n.t("Manage"),Vector2(.52,-.195),Vector2(.30,.065))
		var rows: Array = library.rows()
		page=clampi(page,0,maxi(0,ceili(rows.size()/2.0)-1))
		for item in rows.slice(page*2,page*2+2): _cards.append(item)
		for i in builtin_count: _card(_cards[i],i,Vector2(-.47+(i%3)*.47,.31-(i/3)*.30))
		var start := _cards.size() - mini(2,rows.size()-page*2)
		for i in range(start,_cards.size()): _card(_cards[i],i,Vector2(-.47+(i-start)*.47,-.39))
		_button(ADD,"",Vector2(.47,-.39),CARD_SIZE,not _state.get("busy",false))
		var add_card: Node3D=_buttons.back().node
		_icon("plus",Vector3(0,.018,.007),.06,MUTED,add_card)
		_left(I18n.t("Add panorama"),Vector2(-.185,-.114),TEXT_AUX,.37,MUTED if _state.get("busy",false) else Color.WHITE,add_card)
		if _state.get("choice","") not in ["dark","passthrough"]: _button(ADJUST,I18n.t("Adjust"),Vector2(.52,-.58),Vector2(.30,.065))
		if not library.reviews.is_empty(): _button(REVIEW,I18n.t("Review")+" (%d)"%library.reviews.size(),Vector2(-.16,-.58),Vector2(.52,.065))
		elif _state.get("can_import",false): _button(CURRENT,I18n.t("Use current panorama"),Vector2(-.16,-.58),Vector2(.70,.065),not _state.get("busy",false))
		else: _left(_selected_title(),Vector2(LEFT,-.58),TEXT_AUX,.88,MUTED)
		_paging(ceili(rows.size()/2.0),-.195,-.04)
	else:
		_cards=library.review_rows() if view=="review" else library.rows()
		var pages:=maxi(1,ceili(_cards.size()/6.0)); page=clampi(page,0,pages-1)
		if view=="review":
			_left(I18n.t("Are these panorama images?"),Vector2(LEFT,_top-.23),TEXT_BODY,1.30,MUTED)
			_button(APPROVE,I18n.t("Confirm adding (%d)")%selected.size(),Vector2(.43,_bottom+.12),Vector2(.47,.07),not selected.is_empty(),"",true)
			_button(SKIP,I18n.t("Skip selected"),Vector2(-.05,_bottom+.12),Vector2(.42,.07),not selected.is_empty())
		else:
			_left(I18n.t("%d selected")%selected.size() if bulk else "",Vector2(LEFT,_top-.23),TEXT_AUX,.45,MUTED)
			if not bulk:
				_left(I18n.t("%d backgrounds")%library.assets.size(),Vector2(LEFT,_top-.23),TEXT_AUX,.45,MUTED)
				_button(ADD,I18n.t("Add panorama"),Vector2(.13,_top-.23),Vector2(.32,.065),not _state.get("busy",false))
			else: _button(SELECT_ALL,I18n.t("Select all"),Vector2(.13,_top-.23),Vector2(.32,.065))
		if view!="review": _button(BULK,I18n.t("Done" if bulk else "Select multiple"),Vector2(.51,_top-.23),Vector2(.32,.065),not _state.get("busy",false))
		if bulk and view!="review": _danger(REMOVE,I18n.t("Remove selected"),Vector2(.47,_bottom+.12),Vector2(.40,.07),not selected.is_empty() and not _state.get("busy",false))
		for i in range(page*6,mini(_cards.size(),page*6+6)):
			var slot:=i-page*6
			_card(_cards[i],i,Vector2(-.47+(slot%3)*.47,_top-.42-(slot/3)*.30))
		_paging(pages,_bottom+.12)

func _card(item: Dictionary,index: int,point: Vector2) -> void:
	var id:=str(item.id)
	var active: bool = selected.has(id) if bulk or view=="review" else id == str(_state.get("selected",""))
	_button(CARD+index,"",point,CARD_SIZE)
	var node: Node3D=_buttons.back().node
	if active:
		_buttons.back().base_color=ACCENT; node.material_override.set_shader_parameter("surface_color",ACCENT)
		var inset:=_quad(CARD_SIZE-Vector2.ONE*.005,Vector3(0,0,.003),TILE,11)
		inset.material_override.set_shader_parameter("corner_radius",.012); node.add_child(inset)
	var texture: Texture2D = load("res://backgrounds/previews/"+id+".jpg") if item.get("builtin",false) and id in ["cinema","belfast","morning","night"] else library.texture(id)
	if texture:
		var image:=MeshInstance3D.new(); var mesh:=QuadMesh.new(); mesh.size=Vector2(.414,.233); image.mesh=mesh
		image.position=Vector3(0,.018,.006); image.material_override=_material(Color.WHITE,12); image.material_override.albedo_texture=texture
		if texture.get_width()>texture.get_height()*1.78:
			var crop: float=(16.0/9.0)/(float(texture.get_width())/texture.get_height())
			image.material_override.uv1_scale=Vector3(crop,1,1); image.material_override.uv1_offset=Vector3((1-crop)/2,0,0)
		node.add_child(image)
	else: _icon("passthrough" if id=="passthrough" else "circle",Vector3(0,.018,.007),.065,MUTED,node)
	var caption:=str(item.title)
	if view=="review": caption+=" · "+("VR180" if item.get("geometry",3)==1 else "360°")
	var has_actions:=view=="manage" and not bulk
	_left(caption,Vector2(-.185,-.114),TEXT_AUX,.25 if has_actions else .37,Color.WHITE,node)
	_tips[CARD+index]=str(item.title)
	if active:
		var badge:=_quad(Vector2(.035,.035),Vector3(.17,.095,.012),ACCENT,14)
		badge.material_override.set_shader_parameter("corner_radius",.0175); node.add_child(badge)
		_icon("check",Vector3(.17,.095,.015),.024,Color(.04,.1,.08),node).material_override.render_priority=16
	if has_actions:
		for action in [[RENAMES+index,"edit",.11,"Rename"],[REMOVES+index,"trash",.18,"Remove"]]:
			var centre:=point+Vector2(float(action[2]),-.114)
			_glyph(int(action[0]),str(action[1]),centre,.047,true,I18n.t(str(action[3])))
			_buttons.back().rect=Rect2(centre-Vector2.ONE*.030,Vector2.ONE*.060)
			_buttons.back().node.position.z=.017
			_buttons.back().node.material_override.render_priority=14
			_buttons.back().node.material_override.set_shader_parameter("surface_color",Color(TILE,0))
			for child in _buttons.back().node.get_children():
				if child is MeshInstance3D: child.material_override.render_priority=15
	if view == "manage" and not item.get("modes",[]).is_empty():
		var names: Array=[]
		for binding in item.modes:
			for descriptor in library.visible_modes():
				if descriptor.id==binding: names.append(I18n.t(descriptor.label))
		if not names.is_empty():
			var caption_width:=minf(.27,text_width(" · ".join(names),12)+.025)
			var badge_centre: float=-.194+caption_width/2
			var badge:=_quad(Vector2(caption_width,.036),Vector3(badge_centre,.097,.012),PANEL,14)
			badge.material_override.set_shader_parameter("corner_radius",.008); node.add_child(badge)
			_label(" · ".join(names),Vector3(badge_centre,.097,.015),12,node).render_priority=16

func _paging(pages: int,y: float,x: float = -.63) -> void:
	if pages<=1: return
	_glyph(PREVIOUS,"previous",Vector2(x,y),.06,page>0)
	_glyph(NEXT,"next",Vector2(x+.20,y),.06,page<pages-1)
	_label("%d / %d"%[page+1,pages],Vector3(x+.10,y,.009),TEXT_AUX)

func _draw_delete() -> void:
	_left(I18n.t("Remove selected backgrounds?"),Vector2(LEFT,_top-.24),TEXT_TITLE)
	_left(I18n.t("Original images are kept"),Vector2(LEFT,_top-.33),TEXT_BODY,1.30,MUTED)
	var y:=_top-.43
	for descriptor in library.MODES:
		if selected.has(str(library.bindings.get(descriptor.id,{}).get("id",""))):
			_left(I18n.t(descriptor.label)+" → "+I18n.t("Grand cinema" if descriptor.default=="cinema" else "Belfast sunset"),Vector2(LEFT,y),TEXT_BODY); y-=.07
	_button(BACK,I18n.t("Cancel"),Vector2(.16,_bottom+.10),Vector2(.30,.075))
	_danger(CONFIRM,I18n.t("Remove"),Vector2(.51,_bottom+.10),Vector2(.30,.075),not _state.get("busy",false))

func _draw_adjust() -> void:
	var choice:=str(_state.get("choice",""))
	var rows: Array=[]
	if choice=="cinema":
		rows=[{"key":"cinema_lights","value":_state.get("cinema_lights","auto"),"choices":[{"value":"auto","label":"Auto lights"},{"value":"on","label":"Lights on"},{"value":"off","label":"Lights off"}]},
			{"key":"cinema_interaction","value":_state.get("cinema_interaction","watch"),"choices":[{"value":"watch","label":"Watch"},{"value":"move","label":"Free movement"}]},
			{"key":"cinema_viewing_brightness","value":_state.get("cinema_viewing_brightness","low"),"choices":[{"value":"soft","label":"Soft light"},{"value":"dim","label":"Dim"},{"value":"low","label":"Low light"}]},
			{"key":"cinema_screen_light","value":_state.get("cinema_screen_light",true),"choices":[],"switch":true}]
		_button(CURRENT,I18n.t("Return to start"),Vector2(.44,_bottom+.13),Vector2(.46,.075),bool(_state.get("cinema_ready",true)))
	elif choice not in ["dark","passthrough"]:
		rows=[{"key":"background_yaw","value":_state.get("yaw",0),"choices":range(0,360,45).map(func(x): return {"value":x,"label":str(x)+"°"})},
			{"key":"background_brightness","value":_state.get("brightness",1.0),"choices":[{"value":.5,"label":"50%"},{"value":.75,"label":"75%"},{"value":1.0,"label":"100%"},{"value":1.25,"label":"125%"}]}]
	var names: Array=["Cinema lighting","Cinema interaction","Viewing brightness","Screen ambient light"] if choice=="cinema" else ["Direction","Brightness"]
	for i in rows.size():
		var y:=_top-.25-i*.13
		_left(I18n.t(names[i]),Vector2(LEFT,y),TEXT_BODY,.43)
		choices.field(null,rows[i],Vector2(.61 if rows[i].get("switch",false) else .25,y),.11 if rows[i].get("switch",false) else .82,.07)
	if choice=="cinema" and not _state.get("cinema_ready",true):
		for button in _buttons:
			if not choices.targets.has(button.target): continue
			button.enabled=false; button.foreground=MUTED
			for child in button.node.get_children():
				if child is Label3D: child.modulate=MUTED

func _activate(target: int) -> void:
	if choices.action(target): return
	if target==CLOSE: dismiss(); return
	if target==BACK: navigate_back(); return
	if target in [NEXT,PREVIOUS]: page+=1 if target==NEXT else -1; refresh(); return
	if target>=MODE and target<MODE+library.visible_modes().size(): mode=library.visible_modes()[target-MODE].id; page=0
	elif target==MANAGE: view="manage"; page=0
	elif target==ADD: command.emit("add",null); return
	elif target==CURRENT:
		command.emit("home" if view=="adjust" else "use_current",mode); return
	elif target==ADJUST: view="adjust"
	elif target==REVIEW: view="review"; page=0; selected=library.reviews.keys().duplicate()
	elif target==APPROVE:
		var count:=selected.size()
		if library.approve_reviews(selected):
			_notice=I18n.t("Added %d backgrounds")%count
			selected=library.reviews.keys().duplicate(); view="manage" if selected.is_empty() else "review"; page=0
	elif target==SKIP:
		library.skip_reviews(selected); selected=library.reviews.keys().duplicate()
		if selected.is_empty(): view="manage"; page=0
	elif target==BULK: bulk=not bulk; selected.clear()
	elif target==SELECT_ALL: selected=library.assets.keys().duplicate()
	elif target==REMOVE: modal="delete"
	elif target==CONFIRM: command.emit("remove",selected.duplicate()); modal=""; selected.clear(); bulk=false
	elif target>=RENAMES and target<RENAMES+_cards.size():
		rename_id=str(_cards[target-RENAMES].id); draft=str(_cards[target-RENAMES].title); modal="rename"; _edit_name()
	elif target>=REMOVES and target<REMOVES+_cards.size(): selected=[str(_cards[target-REMOVES].id)]; modal="delete"
	elif target==EDIT: _edit_name()
	elif target==SAVE: _save_name()
	elif target>=CARD and target<CARD+_cards.size():
		var id:=str(_cards[target-CARD].id)
		if bulk or view=="review":
			if selected.has(id): selected.erase(id)
			else: selected.append(id)
		else: command.emit("select",{"mode":mode,"id":id})
	refresh()

func _edit_name() -> void:
	var target := rename_id
	editor.begin("background_name",draft,80,func(value): draft=value; refresh(),func(value): draft=value; _save_name(), Callable(),
		func(): return visible and modal == "rename" and rename_id == target)
	if editor.custom: editor.editor.select_all()

func _save_name() -> void:
	draft=editor.finish("background_name",draft).strip_edges()
	if library.rename_asset(rename_id,draft): modal=""; refresh()

func stick_scroll(y: float,delta: float) -> void:
	if choices.stick_scroll(y,delta) or not modal.is_empty() or has_pointer_capture(): return
	if not is_finite(y) or absf(y)<.3: _scroll=0; return
	_scroll-=y*delta*3
	if absf(_scroll)>=1: page+=1 if _scroll>0 else -1; _scroll=0; refresh()

func press_pointer(hand: String,origin: Vector3,direction: Vector3,tracked: bool) -> bool:
	if choices.press(hand,origin,direction,tracked): return true
	var hit:=ray_hit(origin,direction) if tracked else {}
	if modal.is_empty() and view in ["scene","manage","review"] and not hit.is_empty() and hit.point.y<_top-.27 and hit.point.y>_bottom+.17:
		var id: String=str(_cards[int(hit.target)-CARD].id) if int(hit.target)>=CARD and int(hit.target)<CARD+_cards.size() else ""
		_drag={"hand":hand,"target":int(hit.target),"id":id,"y":hit.point.y,"page":page,"moved":false}; return true
	return super(hand,origin,direction,tracked)

func update_pointer(hand: String,origin: Vector3,direction: Vector3,tracked: bool) -> void:
	super(hand,origin,direction,tracked); choices.update(hand,origin,direction,tracked)
	if _drag.get("hand","")!=hand: return
	if not tracked: _drag.clear(); return
	var point: Variant=project_pointer(origin,direction,Transform3D.IDENTITY)
	if point==null: return
	if absf(point.y-float(_drag.y))>.04:
		_drag.moved=true; page=int(_drag.page)+roundi((point.y-float(_drag.y))/.18); refresh()

func release_pointer(hand: String,origin: Vector3,direction: Vector3,tracked: bool) -> void:
	if choices.capture.get("hand","")==hand: choices.release(hand,origin,direction,tracked); return
	if _drag.get("hand","")!=hand: return
	var drag:=_drag.duplicate(); _drag.clear()
	var hit:=ray_hit(origin,direction) if tracked else {}
	if not drag.moved and int(hit.get("target",NONE))==int(drag.target):
		var index: int=int(drag.target)-CARD
		if not str(drag.get("id","")).is_empty() and (index<0 or index>=_cards.size() or str(_cards[index].id)!=str(drag.id)): return
		_activate(int(drag.target))

func cancel_pointer(hand: String) -> void:
	choices.cancel(hand)
	if _drag.get("hand","")==hand: _drag.clear()
	super(hand)
