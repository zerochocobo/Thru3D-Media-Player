extends "res://scripts/ray_menu.gd"
## One modal ray surface for every mode. The parent menu stays intact while hidden.
signal close_requested
signal command(operation: String, value: Variant)
const Fields := preload("res://scripts/choice_fields.gd")
static var SELECTED: Color:
	get: return UiTheme.color("selected")
const TextInput := preload("res://scripts/system_text_input.gd")
const SceneBudget := preload("res://scripts/scene_import/scene_import_budget.gd")
const GalleryView := preload("res://scripts/scene_import/scene_gallery_view.gd")
const BUILTINS := [["cinema","Grand cinema"],["private_beach","Private beach"],["belfast","Belfast sunset"],["morning","Morning sky"],
	["night","Milky Way panorama"],["dark","Dark background"],["passthrough","Passthrough"]]
const PREVIEWS := ["cinema","private_beach","belfast","morning","night"]
## Built-in scenes that are modelled rooms, and the two that are no picture at all.
const BUILTIN_SCENES := ["cinema","private_beach"]
const BUILTIN_PLAIN := ["dark","passthrough"]
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
const BEACH_SCREEN := 10115
const BEACH_APPLY := 10116
const BEACH_RESET := 10117
const HELP := 10118
const ISSUES := 10119
## What the add card offers once the viewer can add 3D scenes as well as panoramas.
const ADD_IMAGE := 10120
const ADD_SCENE := 10121
## The two pages of the requirements card.
const HELP_IMAGE := 10122
const HELP_SCENE := 10123
## Makes where the viewer stands the place an imported scene is entered.
const SET_ENTRY := 10124
## Opens the scenes offered for download.
const GALLERY := 10125
const ADDING_CARD := "adding"
var _followed := ""
## Set whenever the scene page is come to afresh: its list then turns to the scene in use.
var _locate := true
## The gallery keeps its place across visits: its page while the app runs, its first scene across restarts.
var gallery_page := 0
var gallery_anchor := ""
var gallery_placed := false
var scene_import: Node
var screen_edit := preload("res://scripts/environments/private_beach_screen_edit.gd").new()
const MODE := 10200
## Atmosphere row: off, then the catalog's themes; how much falls; its recording on or off.
const Atmosphere := preload("res://scripts/atmosphere/atmosphere_catalog.gd")
const ATMOSPHERE := 10300
const ATMOSPHERE_AMOUNT := 10320
const ATMOSPHERE_SOUND := 10321
const MoodLight := preload("res://scripts/passthrough_relight_model.gd")
## The scene page ends in a row of ways into what goes with the scene.
const ENTRY_ATMOSPHERE := 10126
const ENTRY_MOOD := 10127
const MOOD_OPEN := 10128
const ENTRY_ROW := .12
const ENTRY_HEIGHT := .075
const SUB_ROW := .13
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
var _help_return := ""
var _help_scene := true
var _issue_index := 0
## Turning ring on the card that is loading; it animates between refreshes.
var _spinner: Node3D
const SPINNER_DOTS := 10
const SPINNER_SPEED := 5.0
const LEFT := -.67
const RIGHT := .67
const CARD_SIZE := Vector2(.43,.28)
## The scene page fits four cards a row: seven built-in scenes in two rows, then
## three of the viewer's backgrounds beside the add card.
const SCENE_CARD := Vector2(.32,.23)
const SCENE_COLUMNS := 4
const SCENE_PITCH := Vector2(.345,.24)
const SCENE_CUSTOM_PER_PAGE := SCENE_COLUMNS-1
## Scene page rhythm: the title-to-rule gap, rule-to-label, rule-to-first-card centre,
## and the gap from a card row to the next rule.
const SCENE_RULE := Vector4(.165,.05,.215,.035)
## The footer sits below the last rule; its button stays clear of the status line.
const SCENE_FOOTER := Vector2(.065,.12)

func _left(text: String, point: Vector2, size: int = TEXT_BODY, width: float = 1.30, ink: Color = Color(-1, -1, -1, -1), parent: Node = self) -> Label3D:
	var label:=_label(_fit_title(text,"",width,size),Vector3(point.x,point.y,.009),size,parent)
	label.horizontal_alignment=HORIZONTAL_ALIGNMENT_LEFT
	label.render_priority=13
	label.modulate=UiTheme.color("label") if ink.a < 0 else ink
	return label

## What the scene importer reports; empty where it is absent.
func _scene_state() -> Dictionary:
	var state: Variant=_state.get("scene_import")
	return state if state is Dictionary else {}

func _scene_row(id: String) -> Dictionary:
	for row in _scene_state().get("rows",[]):
		if str(row.id)==id: return row
	return {}

func _scene_active() -> bool:
	return mode=="global" and not str(_scene_state().get("active","")).is_empty()

## Everything the viewer added, newest first: panoramas, and 3D scenes where they can be used
## (never in image mode, on the main page or when managing: a press there would put one on show).
## A file still being copied in has a card on the main page only; there is nothing to manage yet.
func _custom_rows(everywhere: bool = false) -> Array:
	var rows: Array=library.rows()
	if mode=="global":
		for row in _scene_state().get("rows",[]):
			if everywhere and str(row.id)==ADDING_CARD: continue
			var item: Dictionary=row.duplicate(); item["scene"]=true; item["created"]=int(row.get("added",0)); rows.append(item)
	rows.sort_custom(func(a,b): return int(a.get("created",0))>int(b.get("created",0)))
	return rows

## After a scene file is picked: the main page, where its card leads the viewer's scenes.
func show_added_scene() -> void:
	mode="global"; view="scene"; modal=""; bulk=false; selected.clear(); page=0; _followed=""
	refresh()

## Asked from the stance row under any menu: straight to the confirmation, over the scene's own page.
func ask_entry() -> void:
	mode="global"; view="adjust"; modal="entry"; bulk=false; selected.clear(); choices.reset(); refresh()

## Asked from the shortcut beside the stance button: the settings of the scene in use.
func show_adjust() -> void:
	mode="global"; view="adjust"; modal=""; bulk=false; selected.clear(); choices.reset(); refresh()

## What is being done to the scene on its way in, in the viewer's language.
func _stage_text() -> String:
	var scenes:=_scene_state()
	var stage:=str(scenes.get("stage",""))
	if stage.is_empty(): return ""
	var progress:=float(scenes.get("stage_progress",-1.0))
	return I18n.t(stage)+(" %d%%"%roundi(progress*100.0) if progress>=0.0 else "…")

## The card that reads as chosen: a 3D scene in use stands in for the dark background beneath it.
func _chosen() -> String:
	if mode=="global":
		for key in ["pending","active"]:
			if not str(_scene_state().get(key,"")).is_empty(): return str(_scene_state()[key])
	var pending:=str(_state.get("pending",""))
	return pending if not pending.is_empty() else str(_state.get("selected",""))

const MILKY_WAY_CREDIT := "ESO/S. Brunier · CC BY 4.0 · "

## Who made the scene in use, where its licence asks that to be said: a gallery scene's author,
## or the Milky Way panorama's. Each card also carries its own credit in its tooltip.
func _credit() -> String:
	var chosen:=_chosen()
	for card in GalleryView.state(self).get("rows",[]):
		if not chosen.is_empty() and str(card.get("id",""))==chosen: return GalleryView.credit(card)
	if chosen=="night": return MILKY_WAY_CREDIT+I18n.t("Preview adapted")
	return ""

func _scene_status() -> String:
	var scenes:=_scene_state()
	var pending:=str(scenes.get("pending",""))
	if not pending.is_empty() and not _stage_text().is_empty(): return "%s · %s"%[str(_scene_row(pending).get("title","")),_stage_text()]
	if _scene_active() and not scenes.get("floor_ready",true): return I18n.t("Finding the floor…")
	return I18n.t(str(scenes.get("error","")))

func _selected_title() -> String:
	if _scene_active(): return str(_scene_row(str(_scene_state().active)).get("title",""))
	var id:=str(_state.get("selected",""))
	if library.assets.has(id): return str(library.assets[id].title)
	for item in BUILTINS:
		if item[0]==id: return I18n.t(item[1])
	return ""

func _danger(target: int,text: String,centre: Vector2,size: Vector2,enabled: bool) -> void:
	_button(target,text,centre,size,enabled)
	var button: Dictionary=_buttons.back()
	button.base_color=UiTheme.color("remove_surface") if enabled else TILE
	button.foreground=UiTheme.color("remove_ink") if enabled else MUTED
	button.node.material_override.set_shader_parameter("surface_color",button.base_color)
	for child in button.node.get_children():
		if child is Label3D: child.modulate=button.foreground

func _ready() -> void:
	super()
	choices.changed.connect(_choice_changed)

func _choice_changed(key: String,value: Variant) -> void:
	if view == "beach_screen" and _state.get("screen_edit_locked", false): command.emit("screen_lock_notice", ""); return
	if view=="beach_screen" and screen_edit.values.has(key): screen_edit.values[key]=value
	else: command.emit("adjust", {"mode":mode,"key":key,"value":value})
	refresh()

func begin_beach_screen(head: Transform3D) -> void:
	refresh()
	var parameters: Dictionary = _state.get("beach_screen",{})
	if parameters.is_empty(): return
	screen_edit.begin(parameters,head)
	choices.reset(); view="beach_screen"; _notice=""; refresh()

func open(value: String) -> void:
	mode = value if library.valid_mode(value) else "global"
	view = "scene"; page = 0; modal = ""; bulk = false; selected.clear(); choices.reset(); _notice=""
	_help_return=""; _issue_index=0; _locate=true
	visible = true; refresh()

func begin_import() -> void:
	view="import"; page=0; modal=""; bulk=false; selected.clear(); _notice=""; choices.reset(); refresh()
	_issue_index=0

func finish_import(result: Dictionary) -> void:
	modal=""; bulk=false; selected.clear(); page=0
	if not library.reviews.is_empty():
		view="review"; selected=library.reviews.keys().duplicate()
	elif int(result.get("added",0))+int(result.get("existing",0))>0:
		view="manage"
		_notice=I18n.t("Added %d scenes")%int(result.added) if int(result.added)>0 else I18n.t("Already in My scenes")
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
	elif modal=="requirements": modal=_help_return; _help_return=""
	elif modal=="issues": modal=""
	elif modal=="add": modal=""
	elif not modal.is_empty(): modal = ""; selected.clear()
	elif view=="beach_screen": view="adjust"; screen_edit.values.clear()
	elif view != "scene": view = "scene"; bulk = false; selected.clear(); page = 0; _locate=true
	else: return false
	refresh(); return true

func _process(delta: float) -> void:
	if is_instance_valid(_spinner) and visible: _spinner.rotation.z-=delta*SPINNER_SPEED
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
	if view=="beach_screen" and _state.get("choice","")!="private_beach":
		view="scene"; screen_edit.values.clear()
	_signature = str(_state)
	_draw(); _apply_screen_lock(); arrange_surfaces(); composition_changed.emit()

func _draw() -> void:
	_clear_layout(); choices.begin(mode + view + modal)
	_spinner=null
	var height:=1.42
	if modal.is_empty() and view=="scene": height=_scene_height()
	elif not modal.is_empty(): height=1.02 if modal=="requirements" else .82 if modal=="issues" else .76 if modal=="delete" else .58
	elif view in ["manage","review"]:
		var count: int=library.reviews.size() if view=="review" else _custom_rows(true).size()
		height=.46+clampi(ceili(count/3.0),1,2)*.30
	elif view=="gallery": height=GalleryView.HEIGHT
	elif view=="atmosphere": height=.44
	elif view=="mood": height=.40+(2*SUB_ROW if _state.get("mood_light",{}).get("on",false) else 0.0)
	elif view=="adjust": height=(.74+(.12 if _scene_state().get("baked",false) else 0.0)+(0.0 if _scene_state().get("own_sky",true) else .12)) if _scene_active() else 1.0 if _state.get("choice","")=="cinema" else .87 if _state.get("choice","")=="private_beach" else .62
	elif view=="beach_screen": height=1.12
	elif view in ["import","import_error"]: height=.82
	_top=height/2; _bottom=-_top
	_set_backdrop(Vector2(1.50,height))
	var header_y:=_top-.10
	_button(CLOSE,"",Vector2(.64,header_y),Vector2(.075,.075),true,"close")
	var back:=view!="scene" or not modal.is_empty()
	if back: _glyph(BACK,"up",Vector2(-.65,header_y),.07,true,I18n.t("Back"))
	var title:=I18n.t("Scene")
	if modal=="delete": title=I18n.t("Remove")
	elif modal=="rename": title=I18n.t("Rename")
	elif modal=="requirements": title=I18n.t("Format requirements")
	elif modal=="issues": title=I18n.t("Images not added")
	elif modal=="add": title=I18n.t("Add")
	elif modal=="entry": title=I18n.t("Set as entry point")
	elif view=="gallery": title=I18n.t("Scene gallery")
	elif view=="atmosphere": title=I18n.t("Atmosphere")
	elif view=="mood": title=I18n.t("Screen mood light")
	elif view=="manage": title=I18n.t("Manage my scenes")
	elif view=="review": title=I18n.t("Confirm panoramas")
	elif view=="adjust": title=_selected_title()
	elif view=="beach_screen": title=I18n.t("Screen placement")
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
	if modal=="requirements": _draw_requirements()
	elif modal=="issues": _draw_import_failure()
	elif modal == "delete": _draw_delete()
	elif modal == "add": _draw_add()
	elif modal == "entry":
		_left(I18n.t("Start here, facing this way, whenever this scene opens."),Vector2(LEFT,_top-.24),TEXT_BODY)
		_left(I18n.t("The scene's picture is retaken from this view."),Vector2(LEFT,_top-.32),TEXT_BODY,1.30,MUTED)
		_button(BACK,I18n.t("Cancel"),Vector2(.16,_bottom+.09),Vector2(.30,.075))
		_button(CONFIRM,I18n.t("Confirm"),Vector2(.51,_bottom+.09),Vector2(.30,.075),_scene_active(),"",true)
	elif modal == "rename":
		_button(EDIT,"",Vector2(0,_top-.27),Vector2(1.34,.09))
		_left(draft,Vector2(LEFT+.02,_top-.27),TEXT_BODY,1.25)
		_button(SAVE,I18n.t("Save"),Vector2(.51,_bottom+.09),Vector2(.30,.075),not draft.strip_edges().is_empty(),"",true)
		_button(BACK,I18n.t("Cancel"),Vector2(.16,_bottom+.09),Vector2(.30,.075))
	elif view == "adjust": _draw_adjust()
	elif view == "beach_screen": _draw_beach_screen()
	elif view in ["import","import_error"]: _draw_import()
	elif view == "gallery": GalleryView.draw(self)
	elif view == "atmosphere": _draw_atmosphere(_top-.25)
	elif view == "mood": _draw_mood_light(_top-.25)
	else: _draw_cards()
	if view not in ["import","import_error","beach_screen"] and modal not in ["requirements","issues"]:
		# Why images were turned down belongs with the lists of scenes, not on a scene's own page.
		var show_issues: bool=modal.is_empty() and view in ["scene","manage","review"] and not library.import_progress.get("errors",[]).is_empty()
		var status:=_scene_status()
		if status.is_empty(): status=_notice if not _notice.is_empty() else I18n.t(str(_state.get("status","")))
		_left(status,Vector2(LEFT,_bottom+.055),TEXT_AUX,.65 if not modal.is_empty() else .94 if show_issues else 1.30,MUTED)
		if show_issues: _button(ISSUES,I18n.t("View reasons"),Vector2(.52,_bottom+.055),Vector2(.30,.06))
	# The corner line credits whoever made the scene in use, on every page of this menu.
	if modal.is_empty() and not _credit().is_empty(): _left(_credit(),Vector2(LEFT,_bottom+.018),12,1.30,MUTED)
	choices.finish()

## Two kinds of thing can be added; each opens its own file picker.
func _draw_add() -> void:
	var scenes:=_scene_state()
	var offered:=is_instance_valid(scene_import)
	for option in [[ADD_IMAGE,"panorama","Panorama image","JPG / PNG / WebP · 360° 2:1 · VR180 1:1",-.345,not _state.get("busy",false)],
			[ADD_SCENE,"cube","3D scene","GLB · FBX · Unity scene bundle",.345,offered and not scenes.get("busy",false) and str(scenes.get("pending","")).is_empty()]]:
		_button(option[0],"",Vector2(option[4],_top-.30),Vector2(.65,.22),option[5])
		var node: Node3D=_buttons.back().node
		_icon(option[1],Vector3(0,.035,.007),.085,UiTheme.color("label") if option[5] else MUTED,node)
		_label(I18n.t(option[2]),Vector3(0,-.065,.009),TEXT_BODY,node).modulate=UiTheme.color("label") if option[5] else MUTED
		if offered or option[0]==ADD_IMAGE: _tips[option[0]]=I18n.t(option[3])

func _draw_import() -> void:
	var progress: Dictionary=_state.get("import_progress",{})
	if view=="import_error":
		_draw_import_failure()
		return
	_label(I18n.t("Preparing panorama previews"),Vector3(0,.12,.009),TEXT_TITLE)
	_label(_fit_title(str(progress.get("title","")),"",1.20,TEXT_BODY),Vector3(0,.02,.009),TEXT_BODY).modulate=MUTED
	var total:=maxi(1,int(progress.get("total",1)))
	var completed:=int(progress.get("completed",0))
	_label("%d / %d"%[completed,total],Vector3(0,-.09,.009),TEXT_TITLE)
	var track:=_quad(Vector2(1.02,.012),Vector3(0,-.18,.009),TILE,12); add_child(track); _decorations.append(track)
	var fraction:=maxf(.015,float(completed)/total)
	var fill:=_quad(Vector2(1.02*fraction,.012),Vector3(-.51+fraction*.51,-.18,.012),ACCENT,13); add_child(fill); _decorations.append(fill)

func _paragraph(text: String,point: Vector2,width: float = 1.30) -> Label3D:
	var label:=_label(text,Vector3(point.x,point.y,.009),TEXT_BODY)
	label.horizontal_alignment=HORIZONTAL_ALIGNMENT_LEFT
	label.autowrap_mode=TextServer.AUTOWRAP_WORD_SMART
	label.width=width/label.pixel_size
	label.modulate=MUTED
	return label

func _draw_requirements() -> void:
	# One page per kind of thing that can be added; the scene page only where scenes can be.
	var scenes:=is_instance_valid(scene_import)
	var scene:=scenes and _help_scene
	if scenes:
		_button(HELP_IMAGE,I18n.t("Panorama image"),Vector2(.085,_top-.10),Vector2(.33,.065),true,"",not scene)
		_button(HELP_SCENE,I18n.t("3D scene"),Vector2(.41,_top-.10),Vector2(.30,.065),true,"",scene)
	var limits: Dictionary=SceneBudget.limits(str(_scene_state().get("tier",SceneBudget.LOW)))
	var rows: Array=[
		["3D model",".glb · .fbx"],
		["Unity scene bundle",".unity3d · .assetbundle · .bundle · .ab · .vrcw · .omission"],
		["Limits","≤%d MB · "%(int(limits.file_bytes)/1048576)+I18n.t("≤%s triangles")%I18n.t("%d0K")%(int(limits.triangles)/10000)],
		["Textures",I18n.t("Embedded in the file")],
		["Lights and animation",I18n.t("Not used")]] if scene else [
		["File format","JPG / JPEG · PNG · WebP"],
		["Per-eye projection","360° · 2:1   /   VR180 · 1:1"],
		["Resolution limit",I18n.t("≤8192 px per side · ≤33.5 MP")],
		["File size",I18n.t("≤256 MiB per image")],
		["Example","4096 × 2048 · 8192 × 4096"]]
	for i in rows.size():
		var y:=_top-.27-i*.105
		_left(I18n.t(rows[i][0]),Vector2(LEFT,y),TEXT_BODY,.34,MUTED)
		_left(rows[i][1],Vector2(-.28,y),TEXT_BODY,.95)
	# What makes such a file, for someone who has never made one.
	if scene:
		_left(I18n.t("Exported from Blender, Maya, 3ds Max…"),Vector2(.14,_top-.27),TEXT_AUX,.53,MUTED)
		_left(I18n.t("Far objects are left out beyond that"),Vector2(.14,_top-.27-2*.105),TEXT_AUX,.53,MUTED)
	_rule(_top-.27-rows.size()*.105+.03)
	_left(I18n.t("New to modelling? Let an AI drive Blender for you, then export .glb." if scene else "Stretching an ordinary image does not make it a panorama."),Vector2(LEFT,_top-.27-rows.size()*.105-.035),TEXT_AUX,1.30,MUTED)
	_button(BACK,I18n.t("Got it"),Vector2(.47,_bottom+.09),Vector2(.40,.075))

func _draw_import_failure() -> void:
	var errors: Array=library.import_progress.get("errors",[])
	_issue_index=clampi(_issue_index,0,maxi(0,errors.size()-1))
	var issue: Dictionary=errors[_issue_index] if not errors.is_empty() else {"title":"","reason":library.error}
	_left(str(issue.get("title","")),Vector2(LEFT,_top-.23),TEXT_BODY,1.30)
	_paragraph(I18n.t(str(issue.get("reason",""))),Vector2(LEFT,_top-.39))
	if errors.size()>1:
		_glyph(PREVIOUS,"previous",Vector2(-.12,_bottom+.23),.06,_issue_index>0)
		_glyph(NEXT,"next",Vector2(.12,_bottom+.23),.06,_issue_index<errors.size()-1)
		_label("%d / %d"%[_issue_index+1,errors.size()],Vector3(0,_bottom+.23,.009),TEXT_AUX)
	_button(BACK,I18n.t("Back"),Vector2(-.48,_bottom+.10),Vector2(.34,.075))
	_button(HELP,I18n.t("Format requirements"),Vector2(-.07,_bottom+.10),Vector2(.40,.075))
	_button(ADD,I18n.t("Choose images"),Vector2(.43,_bottom+.10),Vector2(.48,.075))

func _draw_cards() -> void:
	_cards.clear()
	if view == "scene":
		for item in BUILTINS:
			if library.allowed(mode,item[0]): _cards.append({"id":item[0],"title":I18n.t(item[1]),"builtin":true})
		var builtin_count:=_cards.size()
		_rule(_top-SCENE_RULE.x)
		# The built-in scenes say so on their cards; the viewer's own follow under their heading.
		var builtin_y:=_top-SCENE_RULE.x-SCENE_RULE.w-SCENE_CARD.y*.5
		var rows: Array = _custom_rows()
		var custom_rule:=builtin_y-(_builtin_rows(builtin_count)-1)*SCENE_PITCH.y-SCENE_CARD.y*.5-SCENE_RULE.w
		_rule(custom_rule)
		var label_y:=custom_rule-SCENE_RULE.y
		var custom_y:=custom_rule-SCENE_RULE.z
		_left(I18n.t("My scenes") + " · %d" % rows.size(),Vector2(LEFT,label_y),TEXT_BODY,.28)
		_button(MANAGE,I18n.t("Manage"),Vector2(.52,label_y),Vector2(.30,.065))
		# More scenes to add to these come from the gallery: its way in sits with the viewer's own scenes, left of Manage.
		var gallery_shown: bool=mode=="global" and not GalleryView.state(self).get("rows",[]).is_empty()
		if gallery_shown:
			_button(GALLERY,"",Vector2(.20,label_y),Vector2(.31,.065))
			var gallery_button: Node3D=_buttons.back().node
			var gallery_text:=I18n.t("Scene gallery")
			var gallery_width:=text_width(gallery_text,TEXT_BODY)
			_icon("download",Vector3(-gallery_width*.5-.012,0,.006),.034,UiTheme.color("label"),gallery_button)
			_label(gallery_text,Vector3(.022,0,.006),TEXT_BODY,gallery_button).modulate=UiTheme.color("label")
		_glyph(HELP,"info",Vector2(-.01 if gallery_shown else .29,label_y),.055,true,I18n.t("Format requirements"))
		var per_page := SCENE_CUSTOM_PER_PAGE
		# A scene on its way in is followed to its card once, wherever the viewer had paged to.
		var arriving:=str(_scene_state().get("pending","")) if mode=="global" else ""
		if arriving!=_followed:
			_followed=arriving
			var at:=rows.find_custom(func(row): return str(row.id)==arriving)
			if at>=0: page=at/per_page
		elif _locate:
			# Coming to this page: start where the scene in use is, however many pages in that is.
			var chosen:=_chosen()
			var here:=rows.find_custom(func(row): return str(row.id)==chosen)
			if here>=0: page=here/per_page
		_locate=false
		var pages:=ceili(rows.size()/float(per_page))
		page=clampi(page,0,maxi(0,pages-1))
		for item in rows.slice(page*per_page,page*per_page+per_page): _cards.append(item)
		for i in builtin_count: _card(_cards[i],i,_scene_slot(i%SCENE_COLUMNS,builtin_y-(i/SCENE_COLUMNS)*SCENE_PITCH.y),SCENE_CARD)
		var start := _cards.size() - mini(per_page,rows.size()-page*per_page)
		for i in range(start,_cards.size()): _card(_cards[i],i,_scene_slot(i-start,custom_y),SCENE_CARD)
		# The add card follows the backgrounds on this page, settling in the last column once it fills.
		_button(ADD,"",_scene_slot(_cards.size()-start,custom_y),SCENE_CARD,not _state.get("busy",false))
		var add_card: Node3D=_buttons.back().node
		var add_layout := _card_layout(SCENE_CARD)
		_icon("plus",Vector3(0,add_layout.image_y,.007),.06,MUTED,add_card)
		_left(I18n.t("Add"),add_layout.caption,TEXT_AUX,add_layout.caption_width,MUTED if _state.get("busy",false) else UiTheme.color("label"),add_card)
		_tips[ADD]=I18n.t("Panorama image")+" · "+I18n.t("3D scene")
		_paging(pages,label_y,-.31 if gallery_shown else -.04)
		var entry_rule:=custom_y-SCENE_CARD.y*.5-SCENE_RULE.w
		_rule(entry_rule)
		_draw_entries(entry_rule-ENTRY_ROW*.5)
		var extra_y:=entry_rule-ENTRY_ROW-EXTRA_ROW*.5+.01
		if not library.reviews.is_empty(): _button(REVIEW,I18n.t("Review")+" (%d)"%library.reviews.size(),Vector2(LEFT+.26,extra_y),Vector2(.52,.065))
		elif _state.get("can_import",false): _button(CURRENT,I18n.t("Use current panorama"),Vector2(LEFT+.35,extra_y),Vector2(.70,.065),not _state.get("busy",false))
	else:
		_cards=library.review_rows() if view=="review" else _custom_rows(true)
		var pages:=maxi(1,ceili(_cards.size()/6.0)); page=clampi(page,0,pages-1)
		if view=="review":
			_left(I18n.t("Are these panorama images?"),Vector2(LEFT,_top-.23),TEXT_BODY,1.15,MUTED)
			_glyph(HELP,"info",Vector2(.64,_top-.23),.055,true,I18n.t("Format requirements"))
			_button(APPROVE,I18n.t("Confirm adding (%d)")%selected.size(),Vector2(.43,_bottom+.12),Vector2(.47,.07),not selected.is_empty(),"",true)
			_button(SKIP,I18n.t("Skip selected"),Vector2(-.05,_bottom+.12),Vector2(.42,.07),not selected.is_empty())
		else:
			_left(I18n.t("%d selected")%selected.size() if bulk else "",Vector2(LEFT,_top-.23),TEXT_AUX,.45,MUTED)
			if not bulk:
				_left(I18n.t("%d scenes")%_cards.size(),Vector2(LEFT,_top-.23),TEXT_AUX,.45,MUTED)
				_button(ADD,I18n.t("Add"),Vector2(.13,_top-.23),Vector2(.32,.065),not _state.get("busy",false))
				_tips[ADD]=I18n.t("Panorama image")+" · "+I18n.t("3D scene")
				_glyph(HELP,"info",Vector2(-.16,_top-.23),.055,true,I18n.t("Format requirements"))
			else: _button(SELECT_ALL,I18n.t("Select all"),Vector2(.13,_top-.23),Vector2(.32,.065))
		if view!="review": _button(BULK,I18n.t("Done" if bulk else "Select multiple"),Vector2(.51,_top-.23),Vector2(.32,.065),not _state.get("busy",false))
		if bulk and view!="review": _danger(REMOVE,I18n.t("Remove selected"),Vector2(.47,_bottom+.12),Vector2(.40,.07),not selected.is_empty() and not _state.get("busy",false))
		for i in range(page*6,mini(_cards.size(),page*6+6)):
			var slot:=i-page*6
			_card(_cards[i],i,Vector2(-.47+(slot%3)*.47,_top-.42-(slot/3)*.30))
		_paging(pages,_bottom+.12)

const EXTRA_ROW := .085

func _builtin_rows(count: int) -> int:
	return maxi(1,ceili(count/float(SCENE_COLUMNS)))

## Panel height that wraps the built-in rows, one row of the viewer's scenes, the row of
## entries and the footer.
func _scene_height() -> float:
	var count:=0
	for item in BUILTINS: if library.allowed(mode,item[0]): count+=1
	var height:=SCENE_RULE.x+SCENE_RULE.w+SCENE_CARD.y+(_builtin_rows(count)-1)*SCENE_PITCH.y+SCENE_RULE.w
	height+=SCENE_RULE.z+SCENE_CARD.y*.5+SCENE_RULE.w+ENTRY_ROW+SCENE_FOOTER.y
	if not library.reviews.is_empty() or _state.get("can_import",false): height+=EXTRA_ROW
	return height

## What goes with the scene, each showing how it stands: the scene's own settings, the weather
## around the viewer, and the screen's glow. The glow switches in place; its arrow opens the rest.
func _draw_entries(y: float) -> void:
	var entries: Array=[{"target":ADJUST,"icon":"settings","text":I18n.t("Adjust")+" · "+_selected_title(),
		"enabled":_state.get("choice","") not in ["dark","passthrough"] or _scene_active()}]
	if _state.has("atmosphere"):
		var chosen:=str(_state.atmosphere.get("theme",""))
		var shown: Dictionary={"label":"Off","icon":"atmosphere_off"}
		for theme in Atmosphere.THEMES:
			if str(theme.id)==chosen: shown=theme
		entries.append({"target":ENTRY_ATMOSPHERE,"icon":str(shown.icon),"text":I18n.t("Atmosphere")+" · "+I18n.t(str(shown.label)),"on":not chosen.is_empty()})
	if _state.has("mood_light"):
		var lit: bool=_state.mood_light.on
		entries.append({"target":ENTRY_MOOD,"icon":"ambient_light","text":I18n.t("Screen mood light")+" · "+I18n.t("On" if lit else "Off"),"on":lit,"more":MOOD_OPEN})
	var gap:=.025
	var width:=(RIGHT-LEFT-gap*2)/3.0
	for i in entries.size():
		var entry: Dictionary=entries[i]
		var left:=LEFT+i*(width+gap)
		var more:=int(entry.get("more",NONE))
		var body:=width-(ENTRY_HEIGHT+.01 if more!=NONE else 0.0)
		var enabled: bool=entry.get("enabled",true)
		_button(int(entry.target),"",Vector2(left+body*.5,y),Vector2(body,ENTRY_HEIGHT),enabled)
		var button: Dictionary=_buttons.back()
		var on: bool=entry.get("on",false)
		var ink:=ACCENT if on else UiTheme.color("label") if enabled else UiTheme.color("disabled_ink")
		_icon(str(entry.icon),Vector3(-body*.5+.04,0,.006),.036,ink,button.node)
		_left(str(entry.text),Vector2(-body*.5+.075,0),TEXT_AUX,body-.075-(.02 if more!=NONE else .05),ink,button.node)
		_tips[int(entry.target)]=str(entry.text)
		if more!=NONE: _glyph(more,"next",Vector2(left+width-ENTRY_HEIGHT*.5,y),ENTRY_HEIGHT,true,I18n.t("Screen mood light"))
		else: _icon("next",Vector3(body*.5-.03,0,.006),.026,ink if enabled else UiTheme.color("disabled_ink"),button.node)

## The screen's glow, for videos and browser pages alike: a switch, then its range and brightness.
func _draw_mood_light(y: float) -> void:
	var light: Dictionary=_state.get("mood_light",{})
	if light.is_empty(): return
	_left(I18n.t("Videos and web pages"),Vector2(LEFT,y),TEXT_BODY,.80)
	choices.field(null,{"key":"mood_light","value":light.on,"choices":[],"switch":true,
		"hint":"The picture's colours glow around the screen. Over passthrough they also tint the room."},Vector2(.61,y),.11,.07)
	if not light.on: return
	var keys:=["ambient_range","ambient_brightness"]
	for i in keys.size():
		y-=SUB_ROW
		var limits: Vector2=MoodLight.PERCENT_LIMITS[keys[i]]
		var preset: float=MoodLight.PERCENT_DEFAULTS[keys[i]]
		_left(I18n.t(["Light range","Light brightness"][i]),Vector2(LEFT,y),TEXT_BODY,.40)
		choices.field(null,{"slider":true,"key":keys[i],"value":light[keys[i]],"span":Vector3(limits.x,limits.y,5),"unit":"%","decimals":0,
			"tick":preset,"reset_value":preset,"reset_when_changed":true},Vector2(.25,y),.82,.07)

## The themes, how much of one, and its sound.
func _draw_atmosphere(y: float) -> void:
	if not _state.has("atmosphere"): return
	var air: Dictionary=_state.atmosphere
	var themes: Array=[{"id":"","label":"Off","icon":"atmosphere_off"}]+Atmosphere.THEMES
	for i in themes.size():
		_button(ATMOSPHERE+i,"",Vector2(LEFT+.046+i*.105,y),Vector2(.092,.072),true,str(themes[i].icon),str(themes[i].id)==str(air.get("theme","")))
		# A picture's folder keeps its own choice.
		_tips[ATMOSPHERE+i]=I18n.t(str(themes[i].label))+(" · "+I18n.t("This folder") if air.get("folder",false) else "")
	var amount:=int(air.get("amount",Atmosphere.DEFAULT_AMOUNT))
	_glyph(ATMOSPHERE_AMOUNT,"amount_%d"%amount,Vector2(.49,y),.07,true,I18n.t("Amount")+" · "+I18n.t(["Low","Medium","High"][amount]))
	_glyph(ATMOSPHERE_SOUND,"volume_low" if air.get("sound",true) else "mute",Vector2(.60,y),.07,true,I18n.t("Ambient sound"))

func _rule(y: float) -> void:
	var line:=_quad(Vector2(1.34,.003),Vector3(0,y,.006),UiTheme.color("divider"),11); add_child(line); _decorations.append(line)

func _scene_slot(column: int,y: float) -> Vector2:
	return Vector2(-SCENE_PITCH.x*(SCENE_COLUMNS-1)*.5+column*SCENE_PITCH.x,y)

## Picture, caption and badge placement for a card of this size; text keeps its size.
static func _card_layout(size: Vector2) -> Dictionary:
	var image := Vector2(size.x-.016,(size.x-.016)*9.0/16.0)
	var image_y := size.y*.5-.008-image.y*.5
	return {"image":image,"image_y":image_y,"caption":Vector2(-size.x*.5+.03,image_y-image.y*.5-.024),
		"caption_width":size.x-.06,"badge":Vector2(size.x*.5-.045,size.y*.5-.045)}

func _card(item: Dictionary,index: int,point: Vector2,size: Vector2 = CARD_SIZE) -> void:
	var id:=str(item.id)
	var scene: bool = item.get("scene",false)
	var pending := str(_scene_state().get("pending","")) if scene else str(_state.get("pending",""))
	var loading: bool = not bulk and view!="review" and id==pending
	# A press answers at once: the chosen card takes the highlight while its scene loads.
	var active: bool = selected.has(id) if bulk or view=="review" else id == _chosen()
	_button(CARD+index,"",point,size,id!=ADDING_CARD)
	var node: Node3D=_buttons.back().node
	var layout := _card_layout(size)
	if active:
		_buttons.back().base_color=ACCENT; node.material_override.set_shader_parameter("surface_color",ACCENT)
		var inset:=_quad(size-Vector2.ONE*.005,Vector3(0,0,.003),TILE,11)
		inset.material_override.set_shader_parameter("corner_radius",.012); node.add_child(inset)
	# The beach's image lives with its resources, so builds without the scene do not carry it.
	var preview_path: String="res://environments/private_beach/preview.jpg" if id=="private_beach" else "res://backgrounds/previews/"+id+".jpg"
	var texture: Texture2D = load(preview_path) if item.get("builtin",false) and id in PREVIEWS else library.texture(id)
	if scene: texture = scene_import.thumbnail(id) if item.get("thumb",false) and is_instance_valid(scene_import) else null
	if texture:
		var image:=MeshInstance3D.new(); var mesh:=QuadMesh.new(); mesh.size=layout.image; image.mesh=mesh
		image.position=Vector3(0,layout.image_y,.006); image.material_override=_material(Color.WHITE,12); image.material_override.albedo_texture=texture
		if texture.get_width()>texture.get_height()*1.78:
			var crop: float=(16.0/9.0)/(float(texture.get_width())/texture.get_height())
			image.material_override.uv1_scale=Vector3(crop,1,1); image.material_override.uv1_offset=Vector3((1-crop)/2,0,0)
		node.add_child(image)
	elif not (scene and loading): _icon("cube" if scene else "passthrough" if id=="passthrough" else "circle",Vector3(0,layout.image_y,.007),.065,MUTED,node)
	if loading: _loading_overlay(node,layout,_stage_text() if scene else "")
	var caption:=str(item.title)
	if view=="review": caption+=" · "+("VR180" if item.get("geometry",3)==1 else "360°")
	var has_actions:=view=="manage" and not bulk
	_left(caption,layout.caption,TEXT_AUX,layout.caption_width-(.12 if has_actions else 0.0),UiTheme.color("label"),node)
	_tips[CARD+index]=str(item.title)
	if id=="night" and item.get("builtin",false): _tips[CARD+index]+=" · "+MILKY_WAY_CREDIT+I18n.t("Preview adapted")
	var kind_right:=-size.x*.5+.01
	if view!="review":
		# Every card says what it is: a 3D scene, or a panorama and its projection. The built-in
		# ones say so too; the plain backgrounds are only that.
		var builtin: bool=item.get("builtin",false)
		var solid: bool=scene or id in BUILTIN_SCENES
		var plain: bool=builtin and id in BUILTIN_PLAIN
		var kind:="" if plain else "3D" if solid else "VR180" if item.get("geometry",3)==1 else "360°"
		if builtin: kind+=("" if plain else " · ")+I18n.t("Built-in")
		var kind_width:=text_width(kind,14)+(.03 if plain else .066)
		var kind_centre:=Vector3(-size.x*.5+.02+kind_width*.5,layout.badge.y+.002,.012)
		var chip:=_quad(Vector2(kind_width,.042),kind_centre,PANEL,14)
		chip.material_override.set_shader_parameter("corner_radius",.008); node.add_child(chip)
		if not plain: _icon("cube" if solid else "panorama",kind_centre+Vector3(-kind_width*.5+.025,0,.003),.026,UiTheme.color("label"),node).material_override.render_priority=16
		_label(kind,kind_centre+Vector3(0.0 if plain else .015,0,.003),14,node).render_priority=16
		kind_right=kind_centre.x+kind_width*.5
		if not plain: _tips[CARD+index]+=" · "+I18n.t("3D scene" if solid else "Panorama image")
	if scene:
		# The card names the scene; its cost and whether it was cut down to fit stay in the tooltip.
		var summary: Dictionary = item.get("summary",{}).get(str(_scene_state().get("tier","")),{}) if item.get("summary") is Dictionary else {}
		if not summary.is_empty(): _tips[CARD+index]+=" · "+I18n.t("%d triangles")%int(summary.get("triangles",0))
		if int(summary.get("culled",0))>0 or not (summary.get("over_budget",[]) as Array).is_empty():
			_tips[CARD+index]+=" · "+I18n.t("Reduced to fit this headset")
			_icon("info",Vector3(kind_right+.025,layout.badge.y+.002,.012),.03,UiTheme.color("remove_ink"),node)
	if active:
		var badge:=_quad(Vector2(.035,.035),Vector3(layout.badge.x,layout.badge.y,.012),ACCENT,14)
		badge.material_override.set_shader_parameter("corner_radius",.0175); node.add_child(badge)
		_icon("check",Vector3(layout.badge.x,layout.badge.y,.015),.024,UiTheme.color("scene_check"),node).material_override.render_priority=16
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
			var caption_width:=minf(.22,text_width(" · ".join(names),12)+.025)
			var badge_centre: float=kind_right+.01+caption_width/2
			var badge:=_quad(Vector2(caption_width,.036),Vector3(badge_centre,.097,.012),PANEL,14)
			badge.material_override.set_shader_parameter("corner_radius",.008); node.add_child(badge)
			_label(" · ".join(names),Vector3(badge_centre,.097,.015),12,node).render_priority=16

func _loading_overlay(card: Node3D,layout: Dictionary,stage: String = "") -> void:
	var shade:=MeshInstance3D.new(); var mesh:=QuadMesh.new(); mesh.size=layout.image; shade.mesh=mesh
	shade.position=Vector3(0,layout.image_y,.008); shade.material_override=_material(Color(0,0,0,.45),13); card.add_child(shade)
	# With a stage to name, the spinner moves up and the stage reads beneath it.
	_spinner=Node3D.new(); _spinner.position=Vector3(0,layout.image_y+(.022 if not stage.is_empty() else 0.0),.010); card.add_child(_spinner)
	if not stage.is_empty(): _label(_fit_title(stage,"",layout.image.x-.02,12),Vector3(0,layout.image_y-.045,.012),12,card).render_priority=15
	for index in SPINNER_DOTS:
		var angle := TAU*index/SPINNER_DOTS
		var dot:=_quad(Vector2.ONE*.014,Vector3(cos(angle),sin(angle),0)*.036,Color(1,1,1,.15+.85*index/float(SPINNER_DOTS-1)),14)
		dot.material_override.set_shader_parameter("corner_radius",.007); _spinner.add_child(dot)

func _paging(pages: int,y: float,x: float = -.63) -> void:
	if pages<=1: return
	_glyph(PREVIOUS,"previous",Vector2(x,y),.06,page>0)
	_glyph(NEXT,"next",Vector2(x+.20,y),.06,page<pages-1)
	_label("%d / %d"%[page+1,pages],Vector3(x+.10,y,.009),TEXT_AUX)

func _draw_delete() -> void:
	_left(I18n.t("Remove selected scenes?"),Vector2(LEFT,_top-.24),TEXT_TITLE)
	_left(I18n.t("Original images are kept" if selected.any(func(id): return _scene_row(str(id)).is_empty()) else "Original files are kept"),Vector2(LEFT,_top-.33),TEXT_BODY,1.30,MUTED)
	var y:=_top-.43
	for descriptor in library.MODES:
		if selected.has(str(library.bindings.get(descriptor.id,{}).get("id",""))):
			_left(I18n.t(descriptor.label)+" → "+I18n.t("Grand cinema" if descriptor.default=="cinema" else "Belfast sunset"),Vector2(LEFT,y),TEXT_BODY); y-=.07
	_button(BACK,I18n.t("Cancel"),Vector2(.16,_bottom+.10),Vector2(.30,.075))
	_danger(CONFIRM,I18n.t("Remove"),Vector2(.51,_bottom+.10),Vector2(.30,.075),not _state.get("busy",false))

func _draw_adjust() -> void:
	var choice:=str(_state.get("choice",""))
	var rows: Array=[]
	var names: Array=["Direction","Brightness"]
	if _scene_active():
		var scenes:=_scene_state()
		rows=[{"key":"scene_screen_light","value":scenes.get("screen_light",.7),"choices":[{"value":0.0,"label":"Off"},{"value":.35,"label":"Low"},{"value":.7,"label":"Medium"},{"value":1.0,"label":"High"}]}]
		rows.append({"key":"scene_play_dim","value":scenes.get("play_dim",1.0),"choices":[{"value":1.0,"label":"100%"},{"value":.5,"label":"50%"},{"value":.25,"label":"25%"},{"value":.1,"label":"10%"}]})
		names=["Screen ambient light","Scene brightness during playback"]
		_button(CURRENT,I18n.t("Return to start"),Vector2(-.04,_bottom+.13),Vector2(.46,.075))
		_button(SET_ENTRY,I18n.t("Set as entry point"),Vector2(.44,_bottom+.13),Vector2(.46,.075))
		_tips[SET_ENTRY]=I18n.t("Start here, facing this way, whenever this scene opens.")
		if scenes.get("baked",false):
			rows.append({"key":"scene_bake","value":scenes.get("bake",1.0),"choices":[{"value":0.0,"label":"Off"},{"value":.5,"label":"50%"},{"value":1.0,"label":"100%"}]})
			names.append("Baked lighting")
		if not scenes.get("own_sky",true):
			# A scene that came without a sky can have any panorama behind it.
			var skies: Array=[{"value":"","label":"Dark background"}]
			for item in BUILTINS:
				if item[0] in ["belfast","morning","night"]: skies.append({"value":item[0],"label":item[1]})
			for row in library.rows(): skies.append({"value":str(row.id),"label":str(row.title)})
			var behind:=str(scenes.get("backdrop",""))
			rows.append({"key":"scene_backdrop","value":behind if skies.any(func(option): return option.value==behind) else "","choices":skies})
			names.append("Background")
	elif choice=="cinema":
		rows=[{"key":"cinema_lights","value":_state.get("cinema_lights","auto"),"choices":[{"value":"auto","label":"Auto lights"},{"value":"on","label":"Lights on"},{"value":"off","label":"Lights off"}]},
			{"key":"cinema_interaction","value":_state.get("cinema_interaction","watch"),"choices":[{"value":"watch","label":"Watch"},{"value":"move","label":"Free movement"}]},
			{"key":"cinema_viewing_brightness","value":_state.get("cinema_viewing_brightness","low"),"choices":[{"value":"soft","label":"Soft light"},{"value":"dim","label":"Dim"},{"value":"low","label":"Low light"}]},
			{"key":"cinema_screen_light","value":_state.get("cinema_screen_light",true),"choices":[],"switch":true}]
		_button(CURRENT,I18n.t("Return to start"),Vector2(.44,_bottom+.13),Vector2(.46,.075),bool(_state.get("cinema_ready",true)))
	elif choice=="private_beach":
		rows=[{"key":"beach_time_mode","value":_state.get("beach_time_mode","auto"),"choices":[{"value":"auto","label":"Auto"},{"value":"day","label":"Day"},{"value":"night","label":"Night"}]},
			{"key":"cinema_interaction","value":_state.get("cinema_interaction","watch"),"choices":[{"value":"watch","label":"Watch"},{"value":"move","label":"Free movement"}]},
			{"key":"beach_screen_light","value":_state.get("beach_screen_light",1.0),"choices":[{"value":0.0,"label":"Off"},{"value":.5,"label":"Low"},{"value":1.0,"label":"Medium"},{"value":1.6,"label":"High"}]}]
		_button(BEACH_SCREEN,I18n.t("Screen placement"),Vector2(-.22,_bottom+.13),Vector2(.46,.075),bool(_state.get("cinema_ready",false)))
		_button(CURRENT,I18n.t("Return to start"),Vector2(.44,_bottom+.13),Vector2(.46,.075),bool(_state.get("cinema_ready",false)))
	elif choice not in ["dark","passthrough"]:
		rows=[{"key":"background_yaw","value":_state.get("yaw",0),"choices":range(0,360,45).map(func(x): return {"value":x,"label":str(x)+"°"})},
			{"key":"background_brightness","value":_state.get("brightness",1.0),"choices":[{"value":.5,"label":"50%"},{"value":.75,"label":"75%"},{"value":1.0,"label":"100%"},{"value":1.25,"label":"125%"}]}]
	if not _scene_active() and choice=="cinema": names=["Cinema lighting","Cinema interaction","Viewing brightness","Screen ambient light"]
	elif not _scene_active() and choice=="private_beach": names=["Time of day","Cinema interaction","Screen ambient light"]
	for i in rows.size():
		var y:=_top-.25-i*.13
		_left(I18n.t(names[i]),Vector2(LEFT,y),TEXT_BODY,.43)
		choices.field(null,rows[i],Vector2(.61 if rows[i].get("switch",false) else .25,y),.11 if rows[i].get("switch",false) else .82,.07)
	if choice in ["cinema","private_beach"] and not _state.get("cinema_ready",true):
		for button in _buttons:
			if not choices.targets.has(button.target): continue
			button.enabled=false; button.foreground=MUTED
			for child in button.node.get_children():
				if child is Label3D: child.modulate=MUTED

func _draw_beach_screen() -> void:
	var busy: bool = _state.get("beach_screen_loading",false)
	var rows := [
		["width","Screen width",Vector3(1,20,.5),"m"],
		["distance","Forward / back",Vector3(-40,40,.5),"m"],
		["tilt","Tilt",Vector3(-15,15,1),"°"]]
	for i in rows.size():
		var row: Array=rows[i]; var y:=_top-.26-i*.13
		_left(I18n.t(row[1]),Vector2(LEFT,y),TEXT_BODY,.40)
		choices.field(null,{"slider":true,"key":row[0],"value":screen_edit.values.get(row[0],0),"span":row[2],"unit":row[3],"nudge_step":row[2].z},Vector2(.25,y),.82,.07)
	if busy:
		for button in _buttons:
			if choices.targets.has(button.target): button.enabled=false
	_button(BEACH_RESET,I18n.t("Reset"),Vector2(-.38,_bottom+.15),Vector2(.26,.075),not busy)
	_button(BACK,I18n.t("Back" if busy else "Cancel"),Vector2(0,_bottom+.15),Vector2(.26,.075))
	_button(BEACH_APPLY,I18n.t("Apply"),Vector2(.44,_bottom+.15),Vector2(.46,.075),not busy and _state.get("cinema_ready",false))
	var error:=str(_state.get("beach_screen_error",""))
	var status: String="Applying…" if busy else ""
	if not busy and not error.is_empty():
		if "water" in error or "ground" in error: status="Keep the screen on dry sand"
		elif "intersects" in error or "reachable" in error: status="Not enough space here"
		elif "tracking" in error: status="Head tracking unavailable"
		else: status="Could not move screen"
	_left(I18n.t(status),Vector2(LEFT,_bottom+.045),TEXT_AUX,1.30,MUTED)

func _activate(target: int) -> void:
	if _screen_lock_target(target): command.emit("screen_lock_notice", ""); return
	if choices.action(target): return
	if target in [BEACH_APPLY,BEACH_RESET] and has_pointer_capture(): return
	if target==BEACH_SCREEN: command.emit("edit_beach_screen",null); return
	if target==BEACH_APPLY: command.emit("apply_beach_screen",screen_edit.candidate()); refresh(); return
	if target==BEACH_RESET: screen_edit.reset(_state.beach_screen_default); refresh(); return
	if target==CLOSE: dismiss(); return
	if target==BACK: navigate_back(); return
	if target==ADD_SCENE and not is_instance_valid(scene_import): return
	if target in [ADD_IMAGE,ADD_SCENE]:
		modal=""; command.emit("add" if target==ADD_IMAGE else "scene_add",null); refresh(); return
	if target==HELP:
		# Opens on 3D scenes, except from where a panorama is being confirmed or was turned down.
		_help_scene=modal!="issues" and view not in ["review","import_error"]
		_help_return=modal; modal="requirements"; refresh(); return
	if target in [HELP_IMAGE,HELP_SCENE]: _help_scene=target==HELP_SCENE; refresh(); return
	if target==SET_ENTRY: modal="entry"; refresh(); return
	if target==GALLERY: view="gallery"; page=gallery_page; bulk=false; selected.clear(); refresh(); return  # GalleryView.draw places the first visit
	if target==CONFIRM and modal=="entry":
		modal=""; _notice=I18n.t("Entry point saved"); command.emit("scene_set_entry",null); refresh(); return
	if target==ISSUES: modal="issues"; _issue_index=0; refresh(); return
	if target in [NEXT,PREVIOUS]:
		if modal=="issues" or view=="import_error": _issue_index+=1 if target==NEXT else -1
		else: page+=1 if target==NEXT else -1
		refresh(); return
	if target==ENTRY_ATMOSPHERE: view="atmosphere"; refresh(); return
	if target==MOOD_OPEN: view="mood"; refresh(); return
	if target==ENTRY_MOOD:
		command.emit("adjust",{"mode":mode,"key":"mood_light","value":not bool(_state.get("mood_light",{}).get("on",false))}); refresh(); return
	if target>=ATMOSPHERE and target<=ATMOSPHERE+Atmosphere.THEMES.size():
		command.emit("atmosphere",{"mode":mode,"key":"theme","value":"" if target==ATMOSPHERE else str(Atmosphere.THEMES[target-ATMOSPHERE-1].id)}); refresh(); return
	if target==ATMOSPHERE_AMOUNT:
		command.emit("atmosphere",{"mode":mode,"key":"amount","value":(int(_state.get("atmosphere",{}).get("amount",Atmosphere.DEFAULT_AMOUNT))+1)%Atmosphere.AMOUNTS.size()}); refresh(); return
	if target==ATMOSPHERE_SOUND:
		command.emit("atmosphere",{"mode":mode,"key":"sound","value":not _state.get("atmosphere",{}).get("sound",true)}); refresh(); return
	if target>=MODE and target<MODE+library.visible_modes().size(): mode=library.visible_modes()[target-MODE].id; page=0; _locate=true
	elif target==MANAGE: view="manage"; page=0
	elif target==ADD:
		modal="add"
	elif target==CURRENT:
		command.emit("scene_home" if view=="adjust" and _scene_active() else "home" if view=="adjust" else "use_current",mode); return
	elif target==ADJUST: view="adjust"
	elif target==REVIEW: view="review"; page=0; selected=library.reviews.keys().duplicate()
	elif target==APPROVE:
		var count:=selected.size()
		if library.approve_reviews(selected):
			_notice=I18n.t("Added %d scenes")%count
			selected=library.reviews.keys().duplicate(); view="manage" if selected.is_empty() else "review"; page=0
	elif target==SKIP:
		library.skip_reviews(selected); selected=library.reviews.keys().duplicate()
		if selected.is_empty(): view="manage"; page=0
	elif target==BULK: bulk=not bulk; selected.clear()
	elif target==SELECT_ALL: selected=_cards.map(func(card): return str(card.id))
	elif target==REMOVE: modal="delete"
	elif target==CONFIRM:
		var scenes: Array=selected.filter(func(id): return not _scene_row(str(id)).is_empty())
		var images: Array=selected.filter(func(id): return not scenes.has(id))
		if not images.is_empty(): command.emit("remove",images)
		if not scenes.is_empty(): command.emit("scene_remove",scenes)
		modal=""; selected.clear(); bulk=false
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
		elif id==ADDING_CARD: return
		elif view=="gallery": GalleryView.activate(self,_cards[target-CARD])
		elif _cards[target-CARD].get("scene",false): command.emit("scene_select",id)
		else: command.emit("select",{"mode":mode,"id":id})
	refresh()

func _edit_name() -> void:
	var target := rename_id
	editor.begin("background_name",draft,80,func(value): draft=value; refresh(),func(value): draft=value; _save_name(), Callable(),
		func(): return visible and modal == "rename" and rename_id == target)
	if editor.custom: editor.editor.select_all()

func _save_name() -> void:
	draft=editor.finish("background_name",draft).strip_edges()
	if not _scene_row(rename_id).is_empty():
		if not draft.is_empty(): command.emit("scene_rename",{"id":rename_id,"title":draft}); modal=""; refresh()
		return
	if library.rename_asset(rename_id,draft): modal=""; refresh()

func stick_scroll(y: float,delta: float) -> void:
	if choices.stick_scroll(y,delta) or not modal.is_empty() or has_pointer_capture(): return
	if not is_finite(y) or absf(y)<.3: _scroll=0; return
	_scroll-=y*delta*3
	if absf(_scroll)>=1: page+=1 if _scroll>0 else -1; _scroll=0; refresh()

func press_pointer(hand: String,origin: Vector3,direction: Vector3,tracked: bool) -> bool:
	if tracked and _screen_lock_target(int(ray_hit(origin,direction).get("target",NONE))): command.emit("screen_lock_notice", hand); return true
	if choices.press(hand,origin,direction,tracked): return true
	var hit:=ray_hit(origin,direction) if tracked else {}
	if modal.is_empty() and view in ["scene","manage","review","gallery"] and not hit.is_empty() and hit.point.y<_top-.17 and hit.point.y>_bottom+.17:
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
	app_actions.release(hand)
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


func _screen_lock_target(target: int) -> bool:
	return bool(_state.get("screen_edit_locked", false)) and (target in [BEACH_SCREEN, BEACH_APPLY, BEACH_RESET] or (view == "beach_screen" and choices.targets.has(target)))

func _apply_screen_lock() -> void:
	for button in _buttons:
		if not _screen_lock_target(int(button.target)): continue
		button.enabled = false; button["hover_disabled"] = true
		_tips[button.target] = I18n.t("Unlock to adjust")
		for child in button.node.get_children():
			if child is Label3D: child.modulate = MUTED
