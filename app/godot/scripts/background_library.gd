extends Node
## Shared, content-addressed private panoramas. Modes reference assets, never source paths.
signal changed
signal imported(id: String, mode: String, activate: bool)
signal import_failed(mode: String, message: String)
signal import_finished(result: Dictionary)
var import_progress := {}
const Background := preload("res://scripts/app_background.gd")
const Info := preload("res://scripts/image_info.gd")
const Rules := preload("res://scripts/panorama_background_rules.gd")
const Methods := preload("res://scripts/platform_methods.gd")
const MODES := [{"id":"global", "label":"Global", "default":"cinema", "hidden":false,"section":"appearance","cinema":true},
	{"id":"image", "label":"Image mode", "default":"belfast", "hidden":false,"section":"photo_background","cinema":false},
	{"id":"reading", "label":"Reading mode", "default":"", "hidden":true,"section":"reading_background","cinema":false}]
var directory := "user://background_library"
var assets: Dictionary = {}
var reviews: Dictionary = {}
var bindings: Dictionary = {}
var platform: Object
var error := ""
var busy := false
var _queue: Array[Dictionary] = []
var _job := {}
var _thread: Thread
var _request := 0
var _connected: Object
var _textures := {}
var _recovered := false

func visible_modes() -> Array:
	return MODES.filter(func(mode): return not mode.hidden)

func fallback(mode: String) -> String:
	for item in MODES:
		if item.id == mode: return str(item.default)
	return ""

func valid_mode(mode: String) -> bool:
	return visible_modes().any(func(item): return item.id == mode)

func mode_definition(mode: String) -> Dictionary:
	for item in MODES:
		if item.id==mode: return item
	return {}

func valid_id(id: String) -> bool:
	if id.length() != 64: return false
	for c in id:
		if not c in "0123456789abcdef": return false
	return true

func image_path(id: String) -> String:
	return directory.path_join(id + ".image") if valid_id(id) else ""

func thumbnail_path(id: String) -> String:
	return directory.path_join(id + ".jpg") if valid_id(id) else ""

func load_catalog() -> void:
	for suffix in ["catalog.json", "catalog.bak"]:
		var path:=directory.path_join(suffix)
		var input:=FileAccess.open(path,FileAccess.READ) if FileAccess.file_exists(path) else null
		var value: Variant=null
		if input and input.get_length()<=8*1024*1024:
			var parser:=JSON.new()
			if parser.parse(input.get_as_text())==OK: value=parser.data
		if not value is Dictionary or value.get("version", 0) != 1 or not value.get("assets") is Dictionary or not value.get("bindings") is Dictionary: continue
		for id in value.assets:
			var item: Variant = value.assets[id]
			if not valid_id(str(id)) or not item is Dictionary or not FileAccess.file_exists(image_path(str(id))): continue
			if not valid_id(str(item.get("sha256",""))) or int(item.get("bytes",0))<=0 or not item.get("title") is String or int(item.get("orientation",0)) not in range(1,9): continue
			assets[id] = item.duplicate(true)
		bindings.clear()
		for mode in value.bindings:
			var binding: Variant=value.bindings[mode]
			if binding is Dictionary and binding.get("id") is String:
				bindings[str(mode)]={"id":str(binding.id),"yaw":fposmod(float(binding.get("yaw",0)),360),"brightness":clampf(float(binding.get("brightness",1)),.5,1.25)}
		_recovered=suffix=="catalog.bak"
		return

func save_catalog() -> bool:
	if DirAccess.make_dir_recursive_absolute(directory) != OK: return false
	var pending := directory.path_join("catalog.pending")
	var path := directory.path_join("catalog.json")
	var backup := directory.path_join("catalog.bak")
	var file := FileAccess.open(pending, FileAccess.WRITE)
	if not file: return false
	file.store_string(JSON.stringify({"version":1,"assets":assets,"bindings":bindings})); file.flush()
	var ok := file.get_error() == OK; file.close()
	if not ok: return false
	if FileAccess.file_exists(path):
		if _recovered:
			if DirAccess.rename_absolute(path,directory.path_join("catalog.corrupt-%d.json"%Time.get_ticks_usec()))!=OK: return false
		else:
			if FileAccess.file_exists(backup) and DirAccess.remove_absolute(backup) != OK: return false
			if DirAccess.rename_absolute(path, backup) != OK: return false
	if DirAccess.rename_absolute(pending, path) == OK: _recovered=false; return true
	if FileAccess.file_exists(backup): DirAccess.rename_absolute(backup, path)
	return false

func bind(mode: String, id: String, yaw: float = 0, brightness: float = 1) -> bool:
	if not valid_mode(mode) or not allowed(mode, id): return false
	var old := bindings.duplicate(true)
	bindings[mode] = {"id":id,"yaw":yaw,"brightness":brightness}
	if not save_catalog(): bindings = old; error = "Could not save background"; changed.emit(); return false
	changed.emit(); return true

func allowed(mode: String, id: String) -> bool:
	if id == "private_beach" and not Background.private_beach_available(): return false
	return valid_mode(mode) and (assets.has(id) or id in ["belfast","morning","night","dark","passthrough"] or (mode_definition(mode).get("cinema",false) and id in ["cinema","private_beach"]))

func rows() -> Array:
	var result: Array = []
	for id in assets:
		var item: Dictionary = assets[id].duplicate(true); item["id"] = id
		item["modes"] = []
		for mode in bindings:
			if bindings[mode].get("id", "") == id: item.modes.append(mode)
		result.append(item)
	result.sort_custom(func(a,b): return int(a.get("created",0)) < int(b.get("created",0)))
	return result

func texture(id: String) -> Texture2D:
	if _textures.has(id): return _textures[id]
	if not assets.has(id) and not reviews.has(id): return null
	if not FileAccess.file_exists(thumbnail_path(id)): return null
	var image := Image.load_from_file(thumbnail_path(id))
	if image == null: return null
	image.generate_mipmaps()
	_textures[id] = ImageTexture.create_from_image(image)
	if _textures.size()>12: _textures.erase(_textures.keys()[0])
	return _textures[id]

func review_rows() -> Array:
	var result: Array=[]
	for id in reviews:
		var item: Dictionary=reviews[id].duplicate(true); item["id"]=id; result.append(item)
	return result

func approve_reviews(ids: Array) -> bool:
	var old:=assets.duplicate(true)
	for id in ids:
		if reviews.has(id): assets[id]=reviews[id]
	if not save_catalog(): assets=old; return false
	for id in ids: reviews.erase(id)
	changed.emit(); return true

func skip_reviews(ids: Array) -> void:
	for id in ids:
		if not reviews.has(id): continue
		reviews.erase(id); _textures.erase(id)
		if not assets.has(id): DirAccess.remove_absolute(image_path(id)); DirAccess.remove_absolute(thumbnail_path(id))
	changed.emit()

func rename_asset(id: String, title: String) -> bool:
	var clean := title.strip_edges().replace("\n", " ").replace("\r", " ").left(80)
	if not assets.has(id) or clean.is_empty(): return false
	var previous: String = assets[id].title
	assets[id].title = clean
	if not save_catalog(): assets[id].title = previous; return false
	changed.emit(); return true

func remove_assets(ids: Array) -> bool:
	if busy: return false
	var old_assets := assets.duplicate(true); var old_bindings := bindings.duplicate(true)
	for id in ids:
		if not assets.has(id): continue
		assets.erase(id)
		for mode in bindings:
			if bindings[mode].get("id", "") == id: bindings[mode].id = fallback(mode)
	if not save_catalog(): assets = old_assets; bindings = old_bindings; return false
	# Publish reference changes before unlinking private assets. No original paths are retained.
	changed.emit()
	for id in ids:
		if not old_assets.has(id) or assets.has(id): continue
		_textures.erase(id)
		DirAccess.remove_absolute(image_path(str(id))); DirAccess.remove_absolute(thumbnail_path(str(id)))
	return true

func import_source(source: Dictionary, title: String, mode: String = "", activate: bool = false) -> bool:
	if source.is_empty(): return false
	if not busy: error=""
	var job: Dictionary={"source":source.duplicate(true),"title":title,"mode":mode,"activate":activate}
	if source.has("path"):
		# Pin a displayed image's cache file before navigation can release its path.
		var input:=FileAccess.open(str(source.path),FileAccess.READ)
		if not input:
			error=Rules.READ; import_failed.emit(mode,error); changed.emit(); return false
		job["input"]=input
	if not busy: import_progress={"total":0,"completed":0,"added":0,"existing":0,"review":0,"failed":0,"title":"","ids":[],"errors":[]}
	import_progress.total+=1
	_queue.append(job)
	busy = true; changed.emit()
	return true

func import_files(files: Array) -> void:
	for file in files:
		if file is Dictionary: import_source({"uri":str(file.get("uri",""))}, str(file.get("title","Panorama")))

func _process(_delta: float) -> void:
	if _thread and not _thread.is_alive():
		var result: Dictionary = _thread.wait_to_finish(); _thread = null
		var accepted:=false
		var needs_review:=false
		var existed:=false
		if result.has("id"):
			var id := str(result.id)
			var fresh := not assets.has(id)
			existed=not fresh
			if fresh and result.get("review",false):
				reviews[id]=result.entry
			elif fresh: assets[id] = result.entry
			if reviews.has(id): needs_review=true; accepted=true
			elif not fresh or save_catalog():
				accepted=true; imported.emit(id, str(_job.mode), bool(_job.activate))
			else:
				assets.erase(id); error = Rules.SAVE
				DirAccess.remove_absolute(image_path(id)); DirAccess.remove_absolute(thumbnail_path(id))
		else: error = str(result.get("error", Rules.DECODE))
		_finish_import_job(accepted,needs_review,str(result.get("id","")),existed)
	if not _job.is_empty() or _thread: return
	if _queue.is_empty():
		if busy:
			busy = false; changed.emit(); import_finished.emit(import_progress.duplicate(true))
		return
	_job = _queue.pop_front()
	import_progress.title=str(_job.title); changed.emit()
	var source: Dictionary = _job.source
	if source.has("path"): _start_copy(source,_job.get("input")); return
	var uri := str(source.get("uri", ""))
	if Methods.supports(platform, "open_background_image"):
		if _connected != platform:
			_connected = platform; platform.connect("background_image_ready", _on_ready)
		_request = int(platform.open_background_image(uri))
		if _request > 0: return
	else:
		var path := uri.trim_prefix("file://").uri_decode() if uri.begins_with("file://") else uri
		if FileAccess.file_exists(path): _start_copy({"path":path}); return
	error = Rules.READ; _finish_import_job(false)

func _finish_import_job(accepted: bool, review: bool = false, id: String = "", existing: bool = false) -> void:
	import_progress.completed+=1
	var kind: String="review" if review else ("existing" if accepted and existing else ("added" if accepted else "failed"))
	import_progress[kind]+=1
	if accepted: import_progress.ids.append(id)
	else:
		import_progress.errors.append({"title":str(_job.get("title","")),"reason":error})
		import_failed.emit(str(_job.get("mode","")),error)
	_release_request(); _job.clear(); changed.emit()

func _on_ready(id: int, payload: String) -> void:
	if id != _request or _job.is_empty(): return
	var info: Variant = JSON.parse_string(payload)
	if not info is Dictionary or info.get("state", "") != "ready":
		error = Rules.READ; _finish_import_job(false); return
	_start_copy(info)

func _start_copy(source: Dictionary,pinned: FileAccess = null) -> void:
	var input := pinned if pinned else FileAccess.open(str(source.get("path","")), FileAccess.READ)
	if not input:
		error = Rules.READ; _finish_import_job(false); return
	_thread = Thread.new()
	if _thread.start(_copy.bind(input, source.duplicate(true), str(_job.title))) != OK:
		_thread = null; error = "Background unavailable"; _finish_import_job(false)

func _copy(input: FileAccess, source: Dictionary, title: String) -> Dictionary:
	var bytes := input.get_length()
	if bytes > Rules.MAX_BYTES: return {"error":Rules.FILE_SIZE}
	if bytes <= 0: return {"error":Rules.FORMAT}
	if DirAccess.make_dir_recursive_absolute(directory)!=OK: return {"error":Rules.SAVE}
	# Hash precisely the bytes in our private snapshot, in one pass. The source may be
	# renamed, unlinked from a media cache, or replaced while the user navigates away.
	var snapshot:=directory.path_join("source_%d.pending"%Time.get_ticks_usec())
	var output:=FileAccess.open(snapshot,FileAccess.WRITE)
	if not output: return {"error":Rules.SAVE}
	var hash := HashingContext.new(); hash.start(HashingContext.HASH_SHA256)
	var ok:=true
	while input.get_position() < bytes:
		var chunk := input.get_buffer(mini(65536, bytes - input.get_position()))
		if chunk.is_empty(): ok=false; break
		hash.update(chunk); output.store_buffer(chunk)
		if output.get_error()!=OK: ok=false; break
	output.flush(); ok=ok and output.get_error()==OK; output.close(); input.close()
	if not ok: DirAccess.remove_absolute(snapshot); return {"error":Rules.SAVE}
	var result:=_decode_snapshot(snapshot,source,title,bytes,hash.finish().hex_encode())
	DirAccess.remove_absolute(snapshot)
	return result

func _decode_snapshot(path: String,source: Dictionary,title: String,bytes: int,digest: String) -> Dictionary:
	var input:=FileAccess.open(path,FileAccess.READ)
	if not input: return {"error":Rules.READ}
	var header := Info.read_header(path)
	var issue := Rules.file_issue(bytes,header)
	if not issue.is_empty(): return {"error":issue}
	var size := Vector2(header.width,header.height)
	var orientation := int(source.get("orientation", header.get("orientation",1)))
	if orientation not in range(1,9): return {}
	if orientation >= 5: size = Vector2(size.y,size.x)
	var geometry := int(source.get("geometry",1 if is_equal_approx(size.x/size.y,1.0) and not header.get("panorama",false) else 3))
	if not Info.panorama_rect(header).is_equal_approx(Vector4(0,0,1,1)): return {"error":Rules.CROP}
	var review: bool=not source.has("geometry") and not header.get("panorama",false)
	var stereo := bool(source.get("stereo",false)); var top_bottom := bool(source.get("top_bottom",false))
	if not Background.source_supported(size,geometry,stereo,top_bottom): return {"error":Rules.RATIO}
	var recipe := [orientation,geometry,stereo,top_bottom,bool(source.get("swap_eyes",false)),1]
	var id := (str(bytes)+":"+digest+":"+JSON.stringify(recipe)).sha256_text()
	var entry: Dictionary={"title":title.get_basename().left(80),"bytes":bytes,"sha256":digest,"recipe":recipe,
		"orientation":1 if stereo or geometry==1 else orientation,"created":int(Time.get_unix_time_from_system()),"geometry":geometry}
	if FileAccess.file_exists(image_path(id)) and FileAccess.file_exists(thumbnail_path(id)):
		return {"id":id,"entry":entry,"review":review}
	if DirAccess.make_dir_recursive_absolute(directory) != OK: return {}
	var partial := directory.path_join(id + ".pending")
	var job := {"path":partial,"orientation":orientation,"copy":true,"title":title,"generation":0,"source":source,
		"geometry":geometry,"stereo":stereo,"top_bottom":top_bottom,"swap_eyes":bool(source.get("swap_eyes",false)),"mipmaps":false}
	var decoded := Background._read_custom(input,job)
	if not decoded.has("image"): DirAccess.remove_absolute(partial); return {"error":str(decoded.get("error",Rules.DECODE))}
	var image: Image = decoded.image
	image.clear_mipmaps(); image.resize(512,256,Image.INTERPOLATE_LANCZOS)
	var stored: bool=FileAccess.file_exists(image_path(id))
	if image.save_jpg(thumbnail_path(id),0.85) != OK or (not stored and DirAccess.rename_absolute(partial,image_path(id)) != OK):
		DirAccess.remove_absolute(partial); DirAccess.remove_absolute(thumbnail_path(id)); return {"error":Rules.SAVE}
	if stored: DirAccess.remove_absolute(partial)
	entry.orientation=int(decoded.orientation)
	return {"id":id,"entry":entry,"review":review}

func _release_request() -> void:
	if _request > 0 and platform: platform.release_background_image(_request)
	_request = 0

func _exit_tree() -> void:
	if _thread: _thread.wait_to_finish(); _thread = null
	_release_request()
