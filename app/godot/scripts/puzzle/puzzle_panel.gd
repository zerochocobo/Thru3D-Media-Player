extends "res://scripts/ray_menu.gd"
signal requested(operation: String)
const ROWS := 4
const Session := preload("res://scripts/puzzle/puzzle_session.gd")
var count := 0
var total := Session.DEFAULT_COUNT
var preparing := false
var mode := "game"
var records: Array[Dictionary]=[]
var page := 0
var can_start := false
var standing := false
var has_game := false
var can_undo := false
var status := ""
var deleting := ""
var scroll_ready := false
var thumbnail_provider: Callable
var drag := {}
var spherical := false
var current_spherical := false
var mode_enabled := false
var piece_count := Session.DEFAULT_COUNT
var random_rotation := false
var history_mode := false

func difficulty_counts() -> Array: return Session.SPHERE_COUNTS if current_spherical else Session.FLAT_COUNTS

func _place_device_status(_centre: Vector2) -> void: pass

func layout_height() -> float:
	if not deleting.is_empty(): return 0.36
	if mode=="hub": return 0.83
	if mode=="setup": return 0.49
	if mode=="help": return (0.40 if spherical else 0.54)+(0.12 if random_rotation else 0.0)
	if mode=="game": return 0.50
	if mode=="exit_confirm": return 0.36
	return 0.40

func _draw() -> void:
	_clear_layout()
	var height := layout_height()
	var width := 0.60 if mode in ["setup","complete"] else 0.86
	_set_backdrop(Vector2(width,height),Vector2.ZERO); _block_rays(_backdrop,Vector2(width,height))
	_round(4,"close",Vector2(width*0.5-0.055,height*0.5-0.055),0.065,true,false,I18n.t("Close"))
	if not deleting.is_empty():
		_label(I18n.t("Delete this game?"),Vector3(0,0.09,0.006),24)
		for record in records:
			if record.id==deleting: _label(str(record.source.title).left(25),Vector3(0,0.025,0.006),18).modulate=MUTED; break
		_button(30,I18n.t("Delete"),Vector2(-0.13,-0.065),Vector2(0.22,0.08),true,"trash")
		_button(31,I18n.t("Cancel"),Vector2(0.13,-0.065),Vector2(0.22,0.08),true)
		return
	if preparing:
		_label(I18n.t("Loading…")+"   %d / %d" % [count,total],Vector3(0,0.07,0.006),22)
	elif mode=="setup":
		_label(I18n.t("Enter puzzle game"),Vector3(-0.025,0.19,0.006),21)
		_button(10,I18n.t("Seated"),Vector2(-0.135,0.10),Vector2(0.24,0.075),true,"seated",not standing)
		_button(11,I18n.t("Standing"),Vector2(0.135,0.10),Vector2(0.24,0.075),true,"standing",standing)
		var counts := difficulty_counts()
		for i in counts.size(): _button(50+i,I18n.t("%d pieces") % counts[i],Vector2((i-1)*0.18,0.005),Vector2(0.165,0.065),true,"",piece_count==counts[i])
		_label(I18n.t("Piece orientation"),Vector3(-0.19,-0.085,0.006),16)
		_button(60,I18n.t("Upright"),Vector2(0.005,-0.085),Vector2(0.15,0.065),true,"",not random_rotation)
		_button(61,I18n.t("Random"),Vector2(0.185,-0.085),Vector2(0.15,0.065),true,"",random_rotation)
		_button(17,I18n.t("Start"),Vector2(0,-0.185),Vector2(0.28,0.07),can_start,"play",true)
	elif mode=="exit_confirm":
		_label(I18n.t("Exit puzzle?"),Vector3(0,0.075,0.006),24)
		_button(29,I18n.t("Exit puzzle"),Vector2(-0.16,-0.06),Vector2(0.28,0.075))
		_button(32,I18n.t("Continue"),Vector2(0.16,-0.06),Vector2(0.28,0.075),true,"play",true)
	elif mode=="complete":
		_label(I18n.t("Puzzle complete"),Vector3(0,0.11,0.006),24)
		_label("%d / %d" % [count,total],Vector3(0,0.04,0.006),19)
		_button(15,I18n.t("Play again"),Vector2(-0.135,-0.065),Vector2(0.24,0.075),true,"repeat_all")
		_button(28,I18n.t("Exit puzzle"),Vector2(0.135,-0.065),Vector2(0.24,0.075))
	elif mode=="hub": _draw_hub()
	elif mode=="sky":
		_label(I18n.t("Sky view"),Vector3(0,0.14,0.006),23)
		var faces := ["Front","Right","Back side","Left","Top","Bottom"]
		for i in 6: _button(40+i,I18n.t(faces[i]),Vector2((i%3-1)*0.23,0.055-(i/3)*0.085),Vector2(0.21,0.07))
		_button(24,I18n.t("Reset sky"),Vector2(-0.16,-0.13),Vector2(0.25,0.065),true,"recenter")
		_button(3,I18n.t("Back"),Vector2(0.10,-0.13),Vector2(0.24,0.065))
	elif mode=="help":
		var top := height*0.5
		_label(I18n.t("Puzzle controls"),Vector3(0,top-0.06,0.006),23)
		_label(I18n.t("Point + trigger / pinch: grab"),Vector3(0,top-0.14,0.006),19)
		_label(I18n.t("Point at the sky, then release" if spherical else "Aim at board, then release"),Vector3(0,top-0.20,0.006),19)
		if not spherical:
			_label(I18n.t("Frame: grip / pinch to move"),Vector3(0,top-0.26,0.006),19)
			_label(I18n.t("Resize: corner / two-hand pinch"),Vector3(0,top-0.32,0.006),19)
		if random_rotation:
			_label(I18n.t("A: Clockwise / X: Counterclockwise"),Vector3(0,top-(0.26 if spherical else 0.38),0.006),19)
			_label(I18n.t("Hand: turn wrist in 90° steps"),Vector3(0,top-(0.32 if spherical else 0.44),0.006),19)
		_label(I18n.t("Menu / B / Y: game panel"),Vector3(0,-top+0.14,0.006),19)
		_button(3,I18n.t("Back"),Vector2(0,-top+0.06),Vector2(0.22,0.065))
	else:
		_label(I18n.t("360° Puzzle" if spherical else "Puzzle")+"   %d / %d" % [count,total],Vector3(0,0.14,0.006),24)
		_button(3,I18n.t("Continue"),Vector2(-0.20,0.045),Vector2(0.28,0.075),true,"play",true)
		_button(6,I18n.t("Seated" if standing else "Standing"),Vector2(0.13,0.045),Vector2(0.28,0.075))
		var icons := ["image","help","music"]
		var ids := [1,8,9]
		var tips := ["Reference","Help","Music"]
		if spherical:
			if not standing: icons.append("globe"); ids.append(23); tips.append("Sky view")
			icons.append("ambience"); ids.append(25); tips.append("Background")
		for i in icons.size(): _round(ids[i],icons[i],Vector2((i-(icons.size()-1)*0.5)*0.12,-0.065),0.073,true,false,I18n.t(tips[i]))
		_button(28,I18n.t("Exit puzzle"),Vector2(0,-0.17),Vector2(0.30,0.065))
	if not status.is_empty() and mode not in ["help","sky","setup"]: _label(I18n.t(status),Vector3(0,-height*0.5+0.035,0.008),17)

func _draw_hub() -> void:
	_label(I18n.t("Puzzle mode"),Vector3(-0.19,0.35,0.006),24)
	_button(12,I18n.t("Off"),Vector2(0.13,0.35),Vector2(0.09,0.065),true,"",not mode_enabled)
	_button(13,I18n.t("On"),Vector2(0.24,0.35),Vector2(0.09,0.065),true,"",mode_enabled)
	_label(I18n.t("2D photos and 360° panoramas"),Vector3(0,0.295,0.006),17).modulate=MUTED
	_label(I18n.t("Puzzle history" if history_mode else "Unfinished games")+"  ·  %d" % records.size(),Vector3(0,0.24,0.006),19)
	if history_mode: _round(27,"back",Vector2(-0.34,0.24),0.06,true,false,I18n.t("Back"))
	else: _round(26,"history",Vector2(0.34,0.24),0.06,true,false,I18n.t("Puzzle history"))
	page=clampi(page,0,maxi(0,(records.size()-1)/ROWS))
	for row in ROWS:
		var index := page*ROWS+row
		if index>=records.size(): break
		var record: Dictionary=records[index]
		var y := 0.14-row*0.11
		_button(100+row,"",Vector2(-0.04,y),Vector2(0.65,0.078))
		if history_mode: _glyph(100+row,"image",Vector2(0.25,y),0.04,true,I18n.t("Open image"))
		if thumbnail_provider.is_valid():
			var texture: Texture2D=thumbnail_provider.call(record.source)
			if texture:
				var cover := _quad(Vector2(0.075,0.060),Vector3(-0.31,y,0.008),Color.WHITE,12)
				cover.material_override=StandardMaterial3D.new(); cover.material_override.shading_mode=BaseMaterial3D.SHADING_MODE_UNSHADED
				cover.material_override.albedo_texture=texture; add_child(cover); _decorations.append(cover)
		var title := str(record.source.title)
		while title.length()>1 and text_width(title,19)>0.46: title=title.left(title.length()-1)
		_label(title,Vector3(-0.04,y+0.016,0.008),19)
		var local_time := int(record.get("updated",0))+int(Time.get_time_zone_from_system().bias)*60
		var date := Time.get_datetime_string_from_unix_time(local_time).replace("T"," ").substr(5,11)
		var posture := I18n.t("Standing" if record.snapshot.standing else "Seated")
		if record.source.get("projection","flat")=="sphere": posture="360° "+posture
		var detail := "%d / %d  ·  %s  ·  %s" % [record.done,record.total,posture,date]
		if history_mode: detail=I18n.t("%d pieces") % record.total+"  ·  "+posture+"  ·  "+date
		_label(detail,Vector3(-0.04,y-0.018,0.008),14).modulate=MUTED
		_glyph(200+row,"trash",Vector2(0.34,y),0.065,true,I18n.t("Delete"))
	if records.is_empty(): _label(I18n.t("No puzzle history" if history_mode else "No unfinished games"),Vector3(0,-0.07,0.006),20).modulate=MUTED
	_round(20,"previous",Vector2(-0.15,-0.34),0.062,page>0)
	_label("%d / %d" % [page+1,maxi(1,ceili(float(records.size())/ROWS))],Vector3(0,-0.34,0.006),17)
	_round(21,"next",Vector2(0.15,-0.34),0.062,(page+1)*ROWS<records.size())
	if has_game: _round(3,"play",Vector2(0.30,-0.34),0.062,true,false,I18n.t("Continue"))
	if can_undo: _round(22,"undo",Vector2(-0.30,-0.34),0.062,true,false,I18n.t("Undo"))

func _activate(target: int) -> void:
	if mode=="setup":
		if target in [10,11]: standing=target==11; refresh(); return
		if target in [60,61]: random_rotation=target==61; refresh(); return
		if target in range(50,53): piece_count=difficulty_counts()[target-50]; refresh(); return
		if target==17: requested.emit("start"); return
	if target>=40 and target<46: requested.emit("view:"+str(target-40)); return
	if target>=100 and target<104: requested.emit(("picture:" if history_mode else "resume:")+str(records[page*ROWS+target-100].id)); return
	if target>=200 and target<204:
		deleting=str(records[page*ROWS+target-200].id); refresh(); return
	if target==30: requested.emit("delete:"+deleting); deleting=""; return
	if target==31: deleting=""; refresh(); return
	if target in [20,21]: page+=(-1 if target==20 else 1); refresh(); return
	var actions := {1:"reference",3:"continue",4:"close",6:"posture",8:"help",9:"music",12:"mode_off",13:"mode_on",15:"again",22:"undo",23:"sky",24:"recenter",25:"background",26:"history",27:"hub",28:"confirm_exit",29:"exit",32:"back"}
	if actions.has(target): requested.emit(actions[target])

func scroll_axis(axis: float) -> void:
	if not drag.is_empty(): scroll_ready=false; return
	if absf(axis)<0.25: scroll_ready=true
	elif scroll_ready and absf(axis)>0.65 and mode=="hub" and deleting.is_empty():
		scroll_ready=false; page+=(-1 if axis>0 else 1); refresh()

func press_pointer(hand: String, origin: Vector3, direction: Vector3, tracked: bool) -> bool:
	if not drag.is_empty(): return true
	var hit := ray_hit(origin,direction) if tracked else {}
	if mode=="hub" and deleting.is_empty() and not hit.is_empty() and int(hit.target) in range(100,104):
		drag={"hand":hand,"target":int(hit.target),"id":str(records[page*ROWS+int(hit.target)-100].id),"y":hit.point.y,"page":page,"moved":false}
		update_pointer(hand,origin,direction,tracked); return true
	return super(hand,origin,direction,tracked)

func update_pointer(hand: String, origin: Vector3, direction: Vector3, tracked: bool) -> void:
	super(hand,origin,direction,tracked)
	if drag.get("hand","")!=hand: return
	if not tracked: drag.clear(); scroll_ready=false; return
	var point: Variant=project_pointer(origin,direction,Transform3D.IDENTITY)
	if point==null: return
	if absf(point.y-float(drag.y))>0.025: drag.moved=true
	if drag.moved:
		var next := clampi(int(drag.page)+roundi((point.y-float(drag.y))/0.16),0,maxi(0,(records.size()-1)/ROWS))
		if page!=next: page=next; refresh()

func release_pointer(hand: String, origin: Vector3, direction: Vector3, tracked: bool) -> void:
	if drag.get("hand","")!=hand: return
	var captured := drag.duplicate(); drag.clear(); scroll_ready=false
	var hit := ray_hit(origin,direction) if tracked else {}
	var index := page*ROWS+int(captured.target)-100
	if not captured.moved and int(hit.get("target",NONE))==int(captured.target) and index<records.size() and records[index].id==captured.id: _activate(int(captured.target))

func cancel_pointer(hand: String) -> void:
	if drag.get("hand","")==hand: drag.clear(); scroll_ready=false
	super(hand)

func has_pointer_capture() -> bool: return not drag.is_empty()
