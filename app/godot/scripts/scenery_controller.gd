extends Node
## Coordinates modal ownership and transactional presentation using the existing renderers.
const Catalog := preload("res://scripts/background_library.gd")
const Background := preload("res://scripts/app_background.gd")
var app: Node
var library := Catalog.new()
var menu: Node3D
var _return: Dictionary = {}
var _return_rig := Transform3D.IDENTITY
var _pending: Dictionary = {}
var _delete: Array = []
var _error := ""
var _picker := false
var _picker_parent: Node
var _picker_pose := Transform3D.IDENTITY
var _picker_compact := false
var _dialog: FileDialog
var _migrations := {}
var _epochs := {}
var _targets := {}
var _manager_import := false
var _current_requests := {}
var _last_current := ""
var use_native_dialogs := not Engine.has_singleton("QuestPlayer")

func setup(owner: Node, target: Node3D) -> void:
	app=owner; menu=target
	_targets={"global":app.background,"image":app.photo_background}
	if Engine.has_singleton("QuestPlayer"): library.platform=Engine.get_singleton("QuestPlayer")
	library.directory=ProjectSettings.globalize_path(app.settings_path.get_base_dir().path_join("background_library")).simplify_path()
	add_child(library); library.load_catalog()
	menu.library=library; menu.state_provider=snapshot
	menu.command.connect(_command); menu.close_requested.connect(close)
	library.changed.connect(func():
		if menu.visible: menu.refresh()
		if app.photo_menu.visible: app.photo_menu.refresh_values())
	library.imported.connect(_imported)
	library.import_failed.connect(_import_failed)
	library.import_finished.connect(func(result):
		if _manager_import:
			_manager_import=false; menu.finish_import(result))
	app.recent_menu.background_images_selected.connect(_files_selected)
	app.recent_menu.background_picker_cancelled.connect(_picker_cancelled)
	for mode in library.visible_modes():
		var background: Node=_background(mode.id)
		var section: String=mode.section
		var choice:=str(app.settings.get_value(section,"background",mode.default))
		var saved_id:=str(app.settings.get_value(section,"background_asset_id",""))
		if choice=="custom" and library.assets.has(saved_id):
			select(mode.id,saved_id)
		elif choice=="custom":
			var path:=str(app.settings.get_value(section,"custom_path",""))
			if background._owns_custom(path) and FileAccess.file_exists(path):
				_migrations[mode.id]=path
				library.import_source({"path":path,"orientation":int(app.settings.get_value(section,"custom_orientation",1)),"geometry":3},str(app.settings.get_value(section,"custom_title","Panorama")),"activate/"+str(mode.id)+"/0",true)
			else:
				library.bind(mode.id,background.choice if library.allowed(mode.id,background.choice) else library.fallback(mode.id),background.yaw,background.brightness)
		else:
			library.bind(mode.id,choice if library.allowed(mode.id,choice) else library.fallback(mode.id),background.yaw,background.brightness)

func _background(mode: String) -> Node:
	return _targets.get(mode)

func open(_source: Node3D = null) -> void:
	if _picker: return
	if menu.visible: menu.dismiss(); return
	_return.clear()
	_return_rig=app.xr_origin.global_transform
	for panel in [app.recent_menu,app.video_menu,app.photo_menu,app.music_menu]:
		if is_instance_valid(panel):
			_return[panel]=panel.visible
			panel.clear_pointer_visuals(); panel.visible=false
	app.stick_controls.suspend(); app.interface_move.cancel(); app._grab.clear()
	app.photo_hands.cancel(); app.photo_swipe.cancel(); app.memory_swipe.cancel()
	if app.photo: app.photo.gallery.cancel_all()
	if app.cinema_environment: app.cinema_environment.suspend()
	app._place_menu(menu,true)
	menu.open("image" if _source==app.photo_menu or app.photo_active else "global")

func close() -> void:
	if _picker: return
	var rig: Transform3D=app.xr_origin.global_transform
	var relocated:=not rig.is_equal_approx(_return_rig)
	for panel in _return:
		if not is_instance_valid(panel): continue
		panel.visible=bool(_return[panel]) and not app._cinema_interaction_owns() and not app._vr_passthrough_active()
		if panel.visible and relocated:
			# Hidden menus missed the hall's visible-menu placement pass. The cinema
			# transport owns its own lock conversion; other locks follow the rig frame.
			if panel!=app.video_menu and panel.get_meta("space_locked",false):
				var delta:=rig*_return_rig.affine_inverse()
				for key in ["space_pose","space_head"]:
					if panel.get_meta(key,null) is Transform3D: panel.set_meta(key,delta*panel.get_meta(key))
			app._place_menu(panel,true)
	_return.clear(); app.stick_controls.suspend()
	app._menu_touched_ms=Time.get_ticks_msec()
	if app.menu_composition: app.menu_composition.invalidate()

func select(mode: String,id: String,advance: bool = true) -> void:
	if not library.allowed(mode,id) or not _targets.has(mode) or _delete.has(id): return
	if advance: _epochs[mode]=int(_epochs.get(mode,0))+1
	_error=""
	if library.assets.has(id) and not FileAccess.file_exists(library.image_path(id)):
		_error="Background unavailable"; _delete.clear(); menu.refresh(); return
	if _pending.has(mode): _pending[mode].next=id; return
	var current: Node=_background(mode)
	var candidate:=Background.new()
	candidate.choice="custom" if library.assets.has(id) else id
	var binding: Dictionary=library.bindings.get(mode,{})
	candidate.yaw=float(binding.get("yaw",current.yaw)); candidate.brightness=float(binding.get("brightness",current.brightness))
	if library.assets.has(id):
		var asset: Dictionary=library.assets[id]
		candidate.set_library_asset(library.image_path(id),str(asset.title),int(asset.orientation))
	add_child(candidate)
	_pending[mode]={"id":id,"next":id,"candidate":candidate,"started":Time.get_ticks_msec()}
	if id=="cinema" and app.cinema_environment:
		# Preload without presenting or relocating the rig before commit.
		app.cinema_environment.prepare()
	menu.refresh()

func _process(_delta: float) -> void:
	for mode in _pending.keys():
		var job: Dictionary=_pending[mode]
		var candidate: Node=job.candidate
		var timed_out: bool=Time.get_ticks_msec()-int(job.started)>60000
		if candidate.loading and not timed_out: continue
		if str(job.id)!=str(job.next):
			candidate.queue_free(); _pending.erase(mode); select(mode,str(job.next),false); continue
		var wanted: String="custom" if library.assets.has(str(job.id)) else str(job.id)
		var failed: bool=not candidate.error.is_empty() or timed_out or candidate.choice!=wanted
		if job.id=="cinema" and app.cinema_environment:
			if app.cinema_environment.loading and not timed_out: continue
			failed=not app.cinema_environment.is_ready
		if Time.get_ticks_msec()-int(job.started)>60000: failed=true
		var committed:=false
		if failed: _error="Background unavailable"; _delete.clear()
		elif library.bind(mode,str(job.id),candidate.yaw,candidate.brightness):
			_background(mode).adopt(candidate); _persist(mode)
			app._update_background(); committed=true
		else: _error="Could not save background"; _delete.clear()
		if _current_requests.has(mode) and str(_current_requests[mode].get("id",""))==str(job.id): _current_requests[mode].error="" if committed else _error
		candidate.queue_free(); _pending.erase(mode)
		if menu.visible: menu.refresh()
		if app.photo_menu.visible: app.photo_menu.refresh_values()
	if not _delete.is_empty() and _pending.is_empty():
		if not library.remove_assets(_delete): _error="Could not save background"
		_delete.clear()

func _persist(mode: String) -> void:
	var background: Node=_background(mode)
	var section: String=str(library.mode_definition(mode).section)
	for property in ["choice","custom_path","custom_title","custom_orientation","yaw","brightness"]:
		var key: String={"choice":"background","yaw":"background_yaw","brightness":"background_brightness"}.get(property,property)
		app.settings.set_value(section,key,background.get(property))
	app.settings.set_value(section,"background_asset_id",str(library.bindings.get(mode,{}).get("id","")))
	app.settings.save(app.settings_path)

func _imported(id: String,mode: String,activate: bool) -> void:
	var token:=mode
	if mode.begins_with("activate/"):
		var parts:=mode.split("/")
		if parts.size()!=3 or int(parts[2])!=int(_epochs.get(parts[1],0)): return
		mode=parts[1]
	if _current_requests.has(mode) and _current_requests[mode].token==token: _current_requests[mode].id=id
	if _migrations.has(mode):
		var expected:=str(_migrations[mode]); _migrations.erase(mode)
		if _pending.has(mode) or (_background(mode).custom_path!=expected and _background(mode).choice=="custom"): return
	if activate and library.valid_mode(mode): select(mode,id)

func import_current(source: Dictionary,title: String,mode: String) -> void:
	if not library.valid_mode(mode) or source.is_empty(): return
	_epochs[mode]=int(_epochs.get(mode,0))+1
	var token: String="activate/"+mode+"/"+str(_epochs[mode])
	_current_requests[mode]={"source":source.duplicate(true),"serial":app.photo._serial,"token":token,"id":"","error":""}; _last_current=mode
	library.import_source(source,title,token,true)

func _import_failed(token: String,message: String) -> void:
	for mode in _current_requests:
		if _current_requests[mode].token==token: _current_requests[mode].error=message

func current_image_state(source: Dictionary) -> Dictionary:
	var result: Dictionary={"background_notice":""}
	for mode in ["image","global"]:
		var prefix: String="photo_background" if mode=="image" else "photo_global_background"
		var request: Dictionary=_current_requests.get(mode,{})
		var matches: bool=not source.is_empty() and source==request.get("source",{}) and int(request.get("serial",-1))==app.photo._serial
		var id:=str(request.get("id",""))
		var saving: bool=matches and str(request.get("error","")).is_empty() and ((id.is_empty() and library.busy and request.get("token","")=="activate/"+mode+"/"+str(_epochs.get(mode,0))) or (not id.is_empty() and str(_pending.get(mode,{}).get("next",""))==id))
		var applied: bool=matches and not id.is_empty() and str(library.bindings.get(mode,{}).get("id",""))==id and not saving
		result[prefix+"_applied"]=applied; result[prefix+"_saving"]=saving
		result[prefix+"_error"]=str(request.get("error","")) if matches else ""
		if matches and mode==_last_current:
			if saving: result.background_notice="Saving image background…" if mode=="image" else "Saving global background…"
			elif not str(request.error).is_empty(): result.background_notice=str(request.error)
			elif applied: result.background_notice="Image background set" if mode=="image" else "Global background set"
	return result

func snapshot(mode: String) -> Dictionary:
	var background: Node=_background(mode)
	var state: Dictionary=app._library_settings()
	var selected: String=str(library.bindings.get(mode,{}).get("id",background.choice))
	var status:=_error if not _error.is_empty() else library.error
	if library.busy or _pending.has(mode): status="Loading…"
	elif background.choice=="cinema" and app.cinema_environment and not app.cinema_environment.is_ready:
		status="Loading cinema…" if app.cinema_environment.loading else str(app.cinema_environment.error)
	elif status.is_empty():
		if mode!=("image" if app.photo_active else "global"): status="Saved for this mode"
		elif app.temporary_passthrough: status="Temporary passthrough active"
		elif (app.photo_active and app.photo.geometry!=0) or (not app.photo_active and app.video.geometry!=0): status="Saved; visible after immersive viewing"
	state.merge({"selected":selected,"choice":background.choice,"yaw":background.yaw,"brightness":background.brightness,
		"busy":library.busy or not _pending.is_empty(),"status":status,"can_import":app.photo_active and app.photo.can_background(),"catalog":library.assets,"reviews":library.reviews,"import_progress":library.import_progress},true)
	return state

func _command(operation: String,value: Variant) -> void:
	match operation:
		"select": select(str(value.mode),str(value.id))
		"use_current": import_current(app.photo.background_source(),app.photo.display_name,str(value))
		"add": _begin_import()
		"home": app._on_setting_changed("cinema_home",true)
		"remove":
			_delete=value.duplicate()
			for mode in library.bindings:
				if value.has(library.bindings[mode].get("id","")) and library.valid_mode(mode): select(mode,library.fallback(mode))
		"adjust":
			var mode:=str(value.mode); var key:=str(value.key)
			if key.begins_with("cinema_"): app._on_setting_changed(key,value.value)
			else:
				var background: Node=_background(mode)
				if key=="background_yaw": background.set_yaw(float(value.value))
				elif key=="background_brightness": background.set_brightness(float(value.value))
				library.bind(mode,str(library.bindings.get(mode,{}).get("id",background.choice)),background.yaw,background.brightness)
				_persist(mode)

func _begin_import() -> void:
	if library.busy or _picker: return
	if use_native_dialogs:
		if not _dialog:
			_dialog=FileDialog.new(); _dialog.use_native_dialog=true; _dialog.access=FileDialog.ACCESS_FILESYSTEM
			_dialog.file_mode=FileDialog.FILE_MODE_OPEN_FILES; _dialog.filters=PackedStringArray(["*.jpg,*.jpeg,*.png,*.webp;Panorama"])
			_dialog.files_selected.connect(func(paths):
				var files: Array=[]
				for path in paths: files.append({"uri":path,"title":str(path).get_file()})
				_import_files(files))
			add_child(_dialog)
		_dialog.popup_centered_ratio(.75); return
	_picker=true; menu.visible=false
	var picker: Node3D=app.recent_menu
	_picker_parent=picker.get_parent(); _picker_pose=picker.transform; _picker_compact=picker.compact
	picker.begin_background_picker()
	if picker.get_parent()!=app: picker.reparent(app,true)
	picker.set_compact(false); app._place_menu(picker,true); picker.visible=true; picker.refresh()

func _return_from_picker() -> void:
	var picker: Node3D=app.recent_menu
	picker.visible=false
	if is_instance_valid(_picker_parent) and picker.get_parent()!=_picker_parent: picker.reparent(_picker_parent,false)
	picker.set_compact(_picker_compact); picker.transform=_picker_pose
	_picker=false; menu.visible=true; menu.refresh(); app.stick_controls.suspend()

func _files_selected(files: Array) -> void:
	if not _picker: return
	_return_from_picker(); _import_files(files)

func _import_files(files: Array) -> void:
	if files.is_empty(): return
	_manager_import=true; _error=""
	library.import_files(files); menu.begin_import()
	app._place_menu(menu,true)

func _picker_cancelled() -> void:
	if _picker: _return_from_picker()
