extends RefCounted
## Each game is its own transaction. The list is reconstructed from these records.
const Session := preload("res://scripts/puzzle/puzzle_session.gd")
const VERSION := 1
const MAX_RECORD_BYTES := 128 * 1024
var directory: String
var last_error := ""
var undo_id := ""

func _init(path: String = "user://puzzles") -> void:
	directory=path

static func valid_id(value: String) -> bool:
	return value.length()==32 and value.is_valid_hex_number(false)

static func digest(bytes: PackedByteArray) -> String:
	var hash := HashingContext.new(); hash.start(HashingContext.HASH_SHA256); hash.update(bytes)
	return hash.finish().hex_encode()

func _path(id: String) -> String: return directory.path_join("games").path_join(id+".json")
func _deleted(id: String) -> bool: return FileAccess.file_exists(_path(id)+".deleted")

## Called on the preparation worker with immutable Image references. No renderer access.
func cache_source(source: Dictionary) -> Dictionary:
	var image: Image=source.get("image")
	if image==null or image.is_empty(): return {}
	image=image.duplicate(); image.clear_mipmaps(); image.convert(Image.FORMAT_RGBA8)
	var image_digest := pixel_digest(image)
	var image_key := _source_key(source,image_digest)
	var depth: Image=source.get("depth")
	if depth!=null:
		depth=depth.duplicate(); depth.clear_mipmaps(); depth.convert(Image.FORMAT_RF)
	var rect: Vector4=source.get("depth_rect",Vector4(0,0,1,1))
	var descriptor := {"image_key":image_key,"title":str(source.get("title","Puzzle")).replace("\n"," ").left(96),
		"projection":str(source.get("projection","flat")),
		"size":[source.size.x,source.size.y],"layout":int(source.get("layout",0)),"swap_eyes":bool(source.get("swap_eyes",false)),
		"kind":str(source.get("kind","flat")),"spatial_disparity":float(source.get("spatial_disparity",0)),
		"relief":float(source.get("relief",0)),"depth_rect":[rect.x,rect.y,rect.z,rect.w],
		"image_digest":image_digest,"depth_digest":pixel_digest(depth) if depth!=null else ""}
	var asset_key := JSON.stringify(descriptor).sha256_text()
	descriptor.asset_key=asset_key
	var assets := directory.path_join("assets").path_join(asset_key)
	if DirAccess.make_dir_recursive_absolute(assets)!=OK: return {}
	if not FileAccess.file_exists(assets.path_join("image.png")):
		if image.save_png(assets.path_join("image.tmp.png"))!=OK: return {}
		if DirAccess.rename_absolute(assets.path_join("image.tmp.png"),assets.path_join("image.png"))!=OK: return {}
	if depth!=null and not FileAccess.file_exists(assets.path_join("depth.exr")):
		if depth.save_exr(assets.path_join("depth.tmp.exr"),true)!=OK: return {}
		if DirAccess.rename_absolute(assets.path_join("depth.tmp.exr"),assets.path_join("depth.exr"))!=OK: return {}
	if not FileAccess.file_exists(assets.path_join("thumb.png")):
		var thumbnail: Image=image.duplicate()
		var layout := int(descriptor.layout)
		if layout!=0:
			var eye := 1 if descriptor.swap_eyes else 0
			var w := image.get_width()/(2 if layout==1 else 1); var h := image.get_height()/(2 if layout==2 else 1)
			thumbnail=image.get_region(Rect2i(eye*w if layout==1 else 0,eye*h if layout==2 else 0,w,h))
		var ratio := minf(160.0/thumbnail.get_width(),160.0/thumbnail.get_height())
		thumbnail.resize(maxi(1,int(thumbnail.get_width()*ratio)),maxi(1,int(thumbnail.get_height()*ratio)),Image.INTERPOLATE_BILINEAR)
		thumbnail.save_png(assets.path_join("thumb.png"))
	return descriptor

func find_unfinished(source: Dictionary) -> Dictionary:
	var image: Image=source.get("image")
	if image==null or image.is_empty(): return {}
	image=image.duplicate(); image.clear_mipmaps(); image.convert(Image.FORMAT_RGBA8)
	var key := _source_key(source,pixel_digest(image))
	var matches: Array[Dictionary]=[]
	for record in unfinished():
		if record.source.image_key!=key: continue
		if record.source.get("projection","flat")!=source.get("projection","flat") or record.source.kind!=source.get("kind","flat"): continue
		matches.append(record)
	for record in matches:
		if int(record.done)>0: return record
	return matches[0] if not matches.is_empty() else {}

static func _source_key(source: Dictionary, image_digest: String) -> String:
	var retained := str(source.get("image_key",""))
	if retained.length()==64 and retained.is_valid_hex_number(false): return retained
	return (str(source.get("uri",""))+":"+image_digest).sha256_text()

static func pixel_digest(image: Image) -> String:
	return ("%dx%d:%d:" % [image.get_width(),image.get_height(),image.get_format()]+digest(image.get_data())).sha256_text()

func load_source(descriptor: Dictionary, materialize: bool = true) -> Dictionary:
	if not _valid_source(descriptor): return {}
	var assets := directory.path_join("assets").path_join(str(descriptor.asset_key))
	var image := Image.new()
	if not FileAccess.file_exists(assets.path_join("image.png")): return {}
	if image.load(assets.path_join("image.png"))!=OK or image.is_empty(): return {}
	image.convert(Image.FORMAT_RGBA8)
	if pixel_digest(image)!=descriptor.image_digest: return {}
	var depth: Image
	if descriptor.kind=="relief":
		depth=Image.new()
		if not FileAccess.file_exists(assets.path_join("depth.exr")): return {}
		if depth.load(assets.path_join("depth.exr"))!=OK or depth.is_empty(): return {}
		depth.convert(Image.FORMAT_RF)
		if pixel_digest(depth)!=descriptor.depth_digest: return {}
	var r: Array=descriptor.depth_rect
	return {"texture":ImageTexture.create_from_image(image) if materialize else null,"image":image,"size":Vector2(descriptor.size[0],descriptor.size[1]),
		"projection":str(descriptor.get("projection","flat")),
		"title":descriptor.title,"image_key":descriptor.image_key,"layout":int(descriptor.layout),"swap_eyes":descriptor.swap_eyes,"kind":descriptor.kind,
		"spatial_disparity":float(descriptor.spatial_disparity),"depth":depth,"depth_rect":Vector4(r[0],r[1],r[2],r[3]),"relief":float(descriptor.relief)}

func thumbnail(descriptor: Dictionary) -> Texture2D:
	if not _valid_source(descriptor): return null
	var path := directory.path_join("assets").path_join(str(descriptor.asset_key)).path_join("thumb.png")
	if not FileAccess.file_exists(path): return null
	var image := Image.new()
	if image.load(path)!=OK: return null
	return ImageTexture.create_from_image(image)

static func _valid_source(d: Dictionary) -> bool:
	if d.get("projection","flat") not in ["flat","sphere"]: return false
	if d.get("projection","flat")=="sphere" and (d.get("kind")!="flat" or d.get("layout")!=0 or d.get("relief")!=0): return false
	for key in ["image_key","asset_key","image_digest"]:
		if not d.get(key) is String or d[key].length()!=64 or not d[key].is_valid_hex_number(false): return false
	if not d.get("title") is String or d.get("kind") not in ["flat","relief","stereo"]: return false
	if not d.get("depth_digest") is String or (d.kind=="relief" and (d.depth_digest.length()!=64 or not d.depth_digest.is_valid_hex_number(false))): return false
	if not (d.get("layout") is int or d.get("layout") is float) or d.layout!=int(d.layout) or int(d.layout) not in [0,1,2] or not d.get("swap_eyes") is bool: return false
	for key in ["size","depth_rect"]:
		if not d.get(key) is Array or d[key].size()!=(2 if key=="size" else 4): return false
		for n in d[key]:
			if not (n is float or n is int) or not is_finite(float(n)): return false
	if d.size[0]<=0 or d.size[1]<=0 or d.size[0]>32768 or d.size[1]>32768: return false
	for key in ["relief","spatial_disparity"]:
		if not (d.get(key) is float or d.get(key) is int) or not is_finite(float(d[key])): return false
	return d.relief>=0 and d.relief<=0.04 and absf(d.spatial_disparity)<=1

func _read(path: String) -> Dictionary:
	if not FileAccess.file_exists(path): return {}
	var file := FileAccess.open(path,FileAccess.READ)
	if not file or file.get_length()>MAX_RECORD_BYTES: return {}
	var parser := JSON.new()
	if parser.parse(file.get_as_text())!=OK: return {}
	var parsed: Variant=parser.data
	if not parsed is Dictionary or parsed.get("version")!=VERSION or not valid_id(str(parsed.get("id",""))): return {}
	if not parsed.get("source") is Dictionary or not _valid_source(parsed.source): return {}
	if not parsed.get("snapshot") is Dictionary or not Session.valid_snapshot(parsed.snapshot): return {}
	if parsed.snapshot.get("projection","flat")!=parsed.source.get("projection","flat"): return {}
	for key in ["created","updated"]:
		if not (parsed.get(key) is float or parsed.get(key) is int) or not is_finite(float(parsed[key])): return {}
	return parsed

func get_game(id: String) -> Dictionary:
	if not valid_id(id) or _deleted(id): return {}
	var record := _read(_path(id))
	if record.is_empty(): record=_read(_path(id)+".prev")
	return record if record.get("id","")==id else {}

func unfinished() -> Array[Dictionary]:
	return _list_games(false)

func history() -> Array[Dictionary]:
	return _list_games(true)

func image_uri(source: Dictionary) -> String:
	if not _valid_source(source): return ""
	return "file://"+ProjectSettings.globalize_path(directory.path_join("assets").path_join(str(source.asset_key)).path_join("image.png"))

func _list_games(completed: bool) -> Array[Dictionary]:
	var records: Array[Dictionary]=[]
	var folder := DirAccess.open(directory.path_join("games"))
	if not folder: return records
	var seen := {}
	for name in folder.get_files():
		var id := name.get_slice(".",0)
		if not valid_id(id) or seen.has(id): continue
		seen[id]=true
		var record := get_game(id)
		if record.is_empty(): continue
		var done := 0
		for piece in record.snapshot.pieces:
			if piece.placed: done+=1
		if (done==record.snapshot.pieces.size())!=completed: continue
		record["done"]=done; record["total"]=record.snapshot.pieces.size(); records.append(record)
	records.sort_custom(func(a,b):return a.updated>b.updated if a.updated!=b.updated else a.id<b.id)
	return records

func create_game(source: Dictionary, snapshot: Dictionary) -> String:
	var id := Crypto.new().generate_random_bytes(16).hex_encode()
	var now := Time.get_unix_time_from_system()
	var record := {"version":VERSION,"id":id,"source":source,"snapshot":snapshot,"created":now,"updated":now}
	return id if _write(record) else ""

func save_game(id: String, snapshot: Dictionary) -> bool:
	var record := get_game(id)
	if record.is_empty(): last_error="Save unavailable"; return false
	record.snapshot=snapshot; record.updated=Time.get_unix_time_from_system()
	return _write(record)

func _write(record: Dictionary) -> bool:
	last_error="Save failed"
	var id := str(record.get("id",""))
	if not valid_id(id) or _deleted(id) or not _valid_source(record.source) or not Session.valid_snapshot(record.snapshot): return false
	if record.source.get("projection","flat")!=record.snapshot.get("projection","flat"): return false
	if FileAccess.file_exists(directory) or FileAccess.file_exists(directory.path_join("games")): return false
	if DirAccess.make_dir_recursive_absolute(directory.path_join("games"))!=OK: return false
	var path := _path(id); var text := JSON.stringify(record)
	if text.to_utf8_buffer().size()>MAX_RECORD_BYTES: return false
	var file := FileAccess.open(path+".tmp",FileAccess.WRITE)
	if not file: return false
	file.store_string(text); file.flush(); var error := file.get_error(); file.close()
	if error!=OK or _read(path+".tmp").is_empty(): return false
	# Never rotate a corrupt current file over the previous good snapshot.
	if not _read(path).is_empty():
		if DirAccess.copy_absolute(path,path+".prev.tmp")!=OK: return false
		if DirAccess.rename_absolute(path+".prev.tmp",path+".prev")!=OK: return false
	if DirAccess.rename_absolute(path+".tmp",path)!=OK: return false
	last_error=""; return true

func delete_game(id: String) -> bool:
	if get_game(id).is_empty(): return false
	var file := FileAccess.open(_path(id)+".deleted.tmp",FileAccess.WRITE)
	if not file: last_error="Delete failed"; return false
	file.store_string(id); file.flush(); var error := file.get_error(); file.close()
	if error!=OK or DirAccess.rename_absolute(_path(id)+".deleted.tmp",_path(id)+".deleted")!=OK:
		last_error="Delete failed"; return false
	undo_id=id; last_error=""; return true

func undo_delete() -> bool:
	if not valid_id(undo_id) or not _deleted(undo_id): return false
	if DirAccess.remove_absolute(_path(undo_id)+".deleted")!=OK: return false
	undo_id=""; return true

func preferences() -> Dictionary:
	var path := directory.path_join("preferences.json")
	if not FileAccess.file_exists(path): return {}
	var parser := JSON.new()
	if parser.parse(FileAccess.get_file_as_string(path))!=OK: return {}
	var value: Variant=parser.data
	return value if value is Dictionary else {}

func mode_enabled() -> bool:
	var value: Variant=preferences().get("enabled",false)
	return value is bool and value

func set_mode_enabled(value: bool) -> bool: return _save_preferences({"enabled":value})

func standing_mode(spherical: bool) -> bool:
	var values := preferences()
	return bool(values.get("sphere_standing" if spherical else "flat_standing",values.get("standing",false)))

func remember(standing: bool, count: int = 0, spherical: bool = false, random_rotation: Variant = null) -> void:
	var values := preferences()
	var changes := {"standing":standing,"flat_standing":bool(values.get("flat_standing",values.get("standing",false))),
		"sphere_standing":bool(values.get("sphere_standing",values.get("standing",false)))}
	changes["sphere_standing" if spherical else "flat_standing"]=standing
	if count>0: changes["sphere_count" if spherical else "flat_count"]=count
	if random_rotation is bool: changes["sphere_random_rotation" if spherical else "flat_random_rotation"]=random_rotation
	_save_preferences(changes)

func _save_preferences(changes: Dictionary) -> bool:
	if DirAccess.make_dir_recursive_absolute(directory)!=OK: return false
	var values := preferences(); values.merge(changes,true)
	var path := directory.path_join("preferences.json")
	var file := FileAccess.open(path+".tmp",FileAccess.WRITE)
	if not file: return false
	file.store_string(JSON.stringify(values)); file.flush(); var error := file.get_error(); file.close()
	return error==OK and DirAccess.rename_absolute(path+".tmp",path)==OK
