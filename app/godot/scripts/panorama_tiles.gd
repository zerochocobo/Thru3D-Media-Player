extends Node3D
## A bounded, original-pixel detail cache over the inexpensive full-sphere fallback.
const Methods := preload("res://scripts/platform_methods.gd")
const Info := preload("res://scripts/image_info.gd")
const SHADER := preload("res://shaders/panorama_tile.gdshader")
const TILE := 1024
const MAX_TILES := 32 # At most ~172 MiB RGBA8+mips, independent of original dimensions.
var photo: Node3D
var platform: Object
var source := ""
var dimensions := Vector2i.ZERO
var session := 0
var tiles := {}
var details := {}
var wanted: Array[Vector2i] = []
var failed := {}
var pending := Vector2i(-1,-1)
var _clock := 0.0
var _thread: Thread
var _tile_job := {}
var error := ""

func configure(info: Dictionary, host: Object) -> void:
	clear()
	platform=host; source=str(info.get("region_source",""))
	dimensions=Vector2i(int(info.get("width",0)),int(info.get("height",0)))
	if dimensions.x!=dimensions.y*2 or dimensions.x<8192 or int(info.get("orientation",1))!=1: source=""
	if Info.panorama_rect(info)!=Vector4(0,0,1,1): source=""
func clear() -> void:
	if _thread: _thread.wait_to_finish(); _thread=null
	if session>0 and Methods.supports(platform,"panorama_regions_close"): platform.panorama_regions_close(session)
	session=0; pending=Vector2i(-1,-1); wanted.clear(); failed.clear(); _tile_job={}
	for detail in details.values(): detail.free()
	details.clear()
	for tile in tiles.values(): tile.free()
	tiles.clear(); source=""; error=""; visible=false
func _exit_tree() -> void: clear()
func active() -> bool:
	return not source.is_empty() and photo!=null and photo.panel.visible and photo.geometry==3 and not photo.stereo_sbs \
		and not photo.loading and not photo._transition_active and not photo.gallery.overview() \
		and Methods.supports(platform,"panorama_regions_open")
static func core_rect(size: Vector2i, cell: Vector2i) -> Rect2i:
	var start:=cell*TILE
	return Rect2i(start,Vector2i(mini(TILE,size.x-start.x),mini(TILE,size.y-start.y)))
static func direction(uv: Vector2) -> Vector3:
	var longitude: float=(uv.x-0.5)*TAU
	var latitude: float=(0.5-uv.y)*PI
	return Vector3(sin(longitude)*cos(latitude),sin(latitude),-cos(longitude)*cos(latitude))
static func priority_cells(size: Vector2i, forward: Vector3, eye: Vector3 = Vector3.ZERO) -> Array[Vector2i]:
	if size.x<1 or size.y<1 or not forward.is_finite() or forward.length_squared()<0.1: return []
	var candidates: Array[Dictionary]=[]
	for row in ceili(float(size.y)/TILE):
		for column in ceili(float(size.x)/TILE):
			var cell:=Vector2i(column,row)
			var rect:=core_rect(size,cell)
			var centre: Vector2=(Vector2(rect.position)+Vector2(rect.size)*0.5)/Vector2(size)
			var ray: Vector3=direction(centre)*50.0-eye
			var score: float=ray.normalized().dot(forward.normalized())
			if score>0.15: candidates.append({"cell":cell,"score":score})
	candidates.sort_custom(func(a: Dictionary,b: Dictionary): return float(a.score)>float(b.score))
	var result: Array[Vector2i]=[]
	for index in mini(MAX_TILES,candidates.size()): result.append(candidates[index].cell)
	return result

func _process(delta: float) -> void:
	visible=active()
	if not visible:
		if session>0:
			var original:=source; clear(); source=original
		return
	if session==0:
		session=int(platform.panorama_regions_open(source))
		if session<=0: error="Panorama detail unavailable"; return
	_update_materials()
	_clock-=delta
	if _clock<=0:
		_clock=0.2
		var basis: Basis=global_basis.inverse()
		var forward: Vector3=basis*(-photo.view_camera.global_basis.z) if photo.view_camera else Vector3.FORWARD
		var eye: Vector3=to_local(photo.view_camera.global_position) if photo.view_camera else Vector3.ZERO
		wanted=priority_cells(dimensions,photo._detail_direction if photo.inspect else forward, Vector3.ZERO if photo.inspect else eye)
		for cell in tiles.keys():
			if not wanted.has(cell):
				tiles[cell].free(); tiles.erase(cell)
				details[cell].free(); details.erase(cell)
	if _thread:
		if _thread.is_alive(): return
		var image: Image=_thread.wait_to_finish(); _thread=null
		if image!=null and wanted.has(pending): _install(pending,image,_tile_job)
		elif image==null: failed[pending]=true; error="Panorama detail unavailable"
		pending=Vector2i(-1,-1); _tile_job={}
	var report: Variant=JSON.parse_string(platform.panorama_regions_status(session))
	if not report is Dictionary: return
	if report.get("state")=="error": error="Panorama detail unavailable"; return
	if pending.x>=0:
		if report.get("state") not in ["tile","tile_error"]: return
		if Vector2i(int(report.get("column",-1)),int(report.get("row",-1)))!=pending: return
		if report.state=="tile_error": failed[pending]=true; error="Panorama detail unavailable"; pending=Vector2i(-1,-1)
		else:
			_tile_job=report
			_thread=Thread.new()
			if _thread.start(_decode.bind(str(report.path)))!=OK:
				_thread=null; failed[pending]=true; pending=Vector2i(-1,-1); error="Panorama detail unavailable"
			return
	for cell in wanted:
		if not tiles.has(cell) and not failed.has(cell):
			if platform.panorama_regions_request(session,cell.x,cell.y): pending=cell
			break
static func _decode(path: String) -> Image:
	var image:=Image.new()
	if image.load_png_from_buffer(FileAccess.get_file_as_bytes(path))!=OK or image.get_width()>TILE+4 or image.get_height()>TILE+4: return null
	image.generate_mipmaps()
	return image
static func patch_mesh(size: Vector2i, cell: Vector2i, decoded: Rect2i) -> ArrayMesh:
	var core:=core_rect(size,cell)
	var columns:=maxi(2,ceili(float(core.size.x)/size.x*144))
	var rows:=maxi(2,ceili(float(core.size.y)/size.y*72))
	var vertices:=PackedVector3Array(); var uvs:=PackedVector2Array(); var indices:=PackedInt32Array()
	for row in rows+1:
		for column in columns+1:
			var pixel:=Vector2(core.position)+Vector2(core.size)*Vector2(float(column)/columns,float(row)/rows)
			vertices.append(direction(pixel/Vector2(size))*50.0)
			uvs.append((pixel-Vector2(decoded.position))/Vector2(decoded.size))
	for row in rows:
		for column in columns:
			var a:=row*(columns+1)+column; var b:=a+columns+1
			indices.append_array(PackedInt32Array([a,b,a+1,a+1,b,b+1]))
	var arrays:=[]; arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX]=vertices; arrays[Mesh.ARRAY_TEX_UV]=uvs; arrays[Mesh.ARRAY_INDEX]=indices
	var mesh:=ArrayMesh.new(); mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,arrays)
	return mesh
func _install(cell: Vector2i, image: Image, report: Dictionary) -> void:
	if tiles.has(cell): return
	var tile:=MeshInstance3D.new()
	var rect:=Rect2i(int(report.x),int(report.y),int(report.width),int(report.height))
	tile.mesh=patch_mesh(dimensions,cell,rect)
	var material:=ShaderMaterial.new(); material.shader=SHADER; material.render_priority=-9
	material.set_shader_parameter("tile_texture",ImageTexture.create_from_image(image))
	tile.material_override=material; add_child(tile); tiles[cell]=tile
	# The loupe shares the same original-pixel texture, rather than magnifying the base preview.
	var detail:=MeshInstance3D.new(); detail.mesh=photo._detail.mesh
	var magnifier:=ShaderMaterial.new(); magnifier.shader=SHADER; magnifier.render_priority=3
	magnifier.set_shader_parameter("tile_texture",material.get_shader_parameter("tile_texture"))
	magnifier.set_shader_parameter("detail_projection",true)
	magnifier.set_shader_parameter("full_size",Vector2(dimensions))
	var core:=core_rect(dimensions,cell)
	magnifier.set_shader_parameter("core_rect",Vector4(core.position.x,core.position.y,core.size.x,core.size.y))
	magnifier.set_shader_parameter("decoded_rect",Vector4(rect.position.x,rect.position.y,rect.size.x,rect.size.y))
	detail.material_override=magnifier; photo._detail.add_child(detail); details[cell]=detail
	_update_materials()
func _update_materials() -> void:
	for tile in tiles.values():
		tile.material_override.set_shader_parameter("opacity",photo.material.get_shader_parameter("presentation_opacity"))
		tile.visible=photo._reveal_seconds==0
	for detail in details.values():
		detail.visible=visible and photo.inspect
		for key in ["detail_forward","detail_right","detail_up","content_zoom"]:
			detail.material_override.set_shader_parameter(key,photo._detail_material.get_shader_parameter(key))
