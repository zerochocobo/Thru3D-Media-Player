extends Node3D
## Reusable scene host; no camera, XR initialization, input or global environment
## side effects. The app presents background_environment only while selected.
signal changed
const Bundle := preload("res://scripts/environments/private_beach_bundle.gd")
const Navigation := preload("res://scripts/environments/private_beach_navigation.gd")
const Movement := preload("res://scripts/environments/private_beach_locomotion.gd")
const Screen := preload("res://scripts/environments/private_beach_screen.gd")
const BUNDLE_PATH := "res://environments/private_beach/beach_bundle.res"
const SAND := preload("res://shaders/private_beach/sand.gdshader")
const WATER := preload("res://shaders/private_beach/water.gdshader")
const PROPS := preload("res://shaders/private_beach/props.gdshader")
const SKY := preload("res://shaders/private_beach/sky.gdshader")

var is_ready := false
var loading := false
var error := ""
var night := false
var presented := false
var elapsed := 0.0
var background_environment: Environment
var backdrop_material: ShaderMaterial
var navigation: RefCounted
var bundle: Resource
var _content: Node3D
var _surfaces: Array[ShaderMaterial] = []
var _animated: Array[ShaderMaterial] = []
var _sky_material: ShaderMaterial
var _sun: DirectionalLight3D
var _wanted := ""
var _requested := ""
var movement: RefCounted
var movement_loading := false
var _movement_thread: Thread
var _scene_generation := 0
var _movement_generation := 0
var _movement_wanted := false
var screen_layout: Dictionary = {}
var screen_loading := false
var screen_error := ""
## Optional live tracked eye in scene coordinates. Invalid tracking rejects
## a screen edit; navigation's fixed standing anchor is not the actual head.
var viewer_position_provider: Callable
var _film_color := Vector3(.10,.16,.25)
var _screen_node: Node3D
var _screen_thread: Thread
var _screen_revision := 0
var _screen_work_revision := 0
var _screen_candidate: Dictionary = {}
var _screen_pending: Dictionary = {}

func _ready() -> void:
	visible=presented and is_ready
	_update_processing()

func prepare(path := BUNDLE_PATH) -> void:
	if path==_wanted and (loading or (is_ready and error.is_empty())): return
	_wanted=path; error=""
	if _requested.is_empty(): _begin_request()
	_update_processing()

func _begin_request() -> void:
	if _wanted.is_empty(): return
	if not ResourceLoader.exists(_wanted):
		error="Beach resources unavailable"; loading=false; changed.emit(); return
	var result := ResourceLoader.load_threaded_request(_wanted,"Resource",true)
	if result!=OK:
		error="Beach resources could not be requested"; loading=false; changed.emit(); return
	_requested=_wanted; loading=true

func set_presented(value: bool) -> void:
	presented=value
	visible=value and is_ready
	_update_processing()

func set_night(value: bool) -> void:
	if night==value: return
	night=value
	_apply_lighting()
	changed.emit()

func set_film_color(value: Color) -> void:
	# Linear-light input, ready for the existing low-frequency film sampler.
	var color := Vector3(clampf(value.r,0,1),clampf(value.g,0,1),clampf(value.b,0,1))
	_film_color=color
	for material in _surfaces: material.set_shader_parameter("film_color",color)

func release() -> void:
	_wanted=""
	_clear_content()
	error=""; elapsed=0
	# Drain a pending threaded request without ever resurrecting a released scene.
	_update_processing()
	changed.emit()

func _clear_content() -> void:
	_scene_generation+=1
	_screen_revision+=1; _screen_pending.clear(); screen_layout.clear()
	screen_loading=false; screen_error=""; _screen_node=null
	_movement_wanted=false; movement=null
	if is_instance_valid(_content):
		remove_child(_content); _content.free()
	_content=null; _sun=null; _sky_material=null
	_surfaces.clear(); _animated.clear()
	bundle=null; navigation=null; background_environment=null; backdrop_material=null
	is_ready=false; visible=false

func _update_processing() -> void:
	set_process(not _requested.is_empty() or _movement_thread!=null or _screen_thread!=null or not _screen_pending.is_empty() or (is_ready and presented))

func _process(delta: float) -> void:
	_poll_screen()
	if _movement_thread!=null and not _movement_thread.is_alive():
		var prepared: RefCounted = _movement_thread.wait_to_finish()
		_movement_thread=null; movement_loading=false
		if _movement_generation==_scene_generation and is_ready and _movement_wanted:
			if prepared.navigation_ready: movement=prepared
			else: error="Beach navigation unavailable"
			changed.emit()
		elif _movement_wanted: prepare_movement()
		_update_processing()
	if not _requested.is_empty():
		var status := ResourceLoader.load_threaded_get_status(_requested)
		if status!=ResourceLoader.THREAD_LOAD_IN_PROGRESS:
			var path := _requested
			var loaded: Resource = ResourceLoader.load_threaded_get(path) if status==ResourceLoader.THREAD_LOAD_LOADED else null
			_requested=""; loading=false
			if path==_wanted:
				if loaded is Bundle:
					error=loaded.validate()
					if error.is_empty(): _install(loaded)
				else: error="Beach bundle could not be loaded"
				changed.emit()
			elif not _wanted.is_empty(): _begin_request()
			_update_processing()
	if not is_ready or not presented: return
	elapsed+=delta
	for material in _animated: material.set_shader_parameter("study_time",elapsed)

func _exit_tree() -> void:
	if _screen_thread!=null:
		_screen_thread.wait_to_finish(); _screen_thread=null
	if _movement_thread!=null:
		_movement_thread.wait_to_finish(); _movement_thread=null
	# Normal release drains asynchronously. Destruction during a load must still
	# consume the request so the loader does not retain its result indefinitely.
	if not _requested.is_empty():
		ResourceLoader.load_threaded_get(_requested)
		_requested=""
	_clear_content()

func prepare_movement() -> void:
	if not is_ready: return
	_movement_wanted=true
	if movement!=null or _movement_thread!=null: return
	if _screen_thread!=null: movement_loading=true; return
	var colliders := _collider_snapshot()
	_movement_generation=_scene_generation
	_movement_thread=Thread.new()
	var result := _movement_thread.start(_prepare_movement.bind(bundle.navigation.duplicate(true),bundle.config.duplicate(true),colliders))
	if result!=OK:
		_movement_thread=null; error="Beach navigation worker unavailable"
	else: movement_loading=true
	_update_processing()

func _collider_snapshot(exclude_screen := false) -> Array:
	var colliders: Array = []
	# Snapshot actual authored model bounds on the main thread. The worker reads
	# only dictionaries and arrays; it never touches scene nodes or rendering.
	for node in _content.find_children("*","MeshInstance3D",true,false):
		var name_ := str(node.name)
		if not (name_.begins_with("Study_") or name_.begins_with("Table_") or name_.begins_with("Support_") or name_.begins_with("Foot_") or name_.begins_with("Screen_") or name_.begins_with("BayRock_") or name_=="Lamp"): continue
		if name_.begins_with("Support_") or name_.begins_with("Foot_") or name_.begins_with("Screen_"):
			if exclude_screen or _screen_node!=null: continue
		var box: AABB = global_transform.affine_inverse()*node.global_transform*node.get_aabb()
		# Thin front faces get a minimal volume; exact back/feet remain separate.
		box=box.grow(.002)
		colliders.append({"id":name_,"min":[box.position.x,box.position.y,box.position.z],"max":[box.end.x,box.end.y,box.end.z]})
	if not exclude_screen and _screen_node!=null:
		_append_boxes(colliders,Screen.collider_boxes(screen_layout,_screen_node))
	return colliders

static func _append_boxes(colliders: Array,boxes: Array[AABB]) -> void:
	for box in boxes:
		colliders.append({"id":"screen_dynamic","min":[box.position.x,box.position.y,box.position.z],"max":[box.end.x,box.end.y,box.end.z]})

func request_screen(changes: Dictionary,restore_view: Dictionary = {}) -> bool:
	# Discrete edit/drag-release API. Keep the old complete layout while preparing
	# connectivity, then swap geometry, uniforms and movement in one main-loop step.
	if not is_ready: screen_error="Beach is not ready"; return false
	if not restore_view.is_empty() and (presented or not Movement.valid_view_record(restore_view)):
		screen_error="Saved viewing position is unavailable"; return false
	var settings: Dictionary = bundle.config.duplicate(true)
	settings.screen=desired_screen_parameters()
	var candidate := Screen.solve(settings,navigation.ground,changes)
	if candidate.has("error"): screen_error=candidate.error; return false
	var node := Screen.geometry(candidate,navigation.ground)
	var boxes := Screen.collider_boxes(candidate,node); node.free()
	var colliders := _collider_snapshot(true)
	for box in boxes:
		for collider in colliders:
			var low := _vector(collider.min); var high := _vector(collider.max)
			if box.intersects(AABB(low,high-low)):
				screen_error="Screen or support intersects a prop"; return false
	var conflict := _screen_viewer_conflict(boxes,restore_view)
	if not conflict.is_empty(): screen_error=conflict; return false
	_append_boxes(colliders,boxes)
	_screen_revision+=1; screen_error=""; screen_loading=true
	_screen_pending={"layout":candidate,"colliders":colliders,"boxes":boxes,"restore_view":restore_view.duplicate(true)}
	_start_screen_worker(); changed.emit()
	return true

func desired_screen_parameters() -> Dictionary:
	if not _screen_pending.is_empty(): return _screen_pending.layout.parameters.duplicate(true)
	if _screen_thread!=null and _screen_work_revision==_screen_revision: return _screen_candidate.layout.parameters.duplicate(true)
	return screen_layout.get("parameters",{}).duplicate(true)

func _screen_hits_viewer(boxes: Array[AABB]) -> bool:
	return not _screen_viewer_conflict(boxes).is_empty()

func _screen_viewer_conflict(boxes: Array[AABB],restore_view: Dictionary = {}) -> String:
	var eye := Vector3(bundle.config.viewer.x,0,bundle.config.viewer.z)
	eye.y=navigation.ground(eye.x,eye.z)+bundle.config.viewer.eye_height
	if movement!=null: eye=movement.eye_position
	if not restore_view.is_empty():
		eye=Vector3(float(restore_view.x),0,float(restore_view.z))
		eye.y=navigation.ground(eye.x,eye.z)+float(restore_view.eye_height)
	elif viewer_position_provider.is_valid():
		var tracked: Variant = viewer_position_provider.call()
		if not tracked is Vector3 or not tracked.is_finite(): return "Head tracking unavailable"
		eye=tracked
	var bottom: float = navigation.ground(eye.x,eye.z)
	for box in boxes:
		if box.end.y<bottom+.03 or box.position.y>maxf(eye.y,bottom+Movement.EYE_HEIGHT)+Movement.HEAD_CLEARANCE: continue
		var closest := Vector2(clampf(eye.x,box.position.x,box.end.x),clampf(eye.z,box.position.z,box.end.z))
		if closest.distance_to(Vector2(eye.x,eye.z))<=Movement.BODY_RADIUS: return "Screen or support intersects the current viewer"
	return ""

func _start_screen_worker() -> void:
	if _screen_pending.is_empty() or _screen_thread!=null or _movement_thread!=null: return
	_screen_candidate=_screen_pending; _screen_pending={}
	_screen_work_revision=_screen_revision
	_screen_thread=Thread.new()
	var result := _screen_thread.start(_prepare_movement.bind(bundle.navigation.duplicate(true),bundle.config.duplicate(true),_screen_candidate.colliders))
	if result!=OK:
		_screen_thread=null; _screen_candidate.clear(); screen_loading=false; screen_error="Screen navigation worker unavailable"
	_update_processing()

func _poll_screen() -> void:
	var notify := false
	if _screen_thread!=null and not _screen_thread.is_alive():
		var prepared: RefCounted = _screen_thread.wait_to_finish(); _screen_thread=null
		if _screen_work_revision==_screen_revision and is_ready:
			screen_loading=false
			var restore_view: Dictionary = _screen_candidate.get("restore_view",{})
			var conflict := _screen_viewer_conflict(_screen_candidate.boxes,restore_view)
			# The viewer can move during preparation. Validate their latest position.
			if not prepared.navigation_ready: screen_error="Screen navigation unavailable"
			elif not conflict.is_empty(): screen_error=conflict
			elif not restore_view.is_empty() and (presented or not prepared.restore_view(restore_view)): screen_error="Saved viewing position is unavailable"
			elif restore_view.is_empty() and movement!=null and not prepared.adopt_view(movement): screen_error="Current viewing position is no longer reachable"
			else:
				_commit_screen(_screen_candidate.layout)
				if movement!=null or _movement_wanted: movement=prepared; movement_loading=false
			notify=true
		_screen_candidate={}
		if not is_ready: movement_loading=false
	_start_screen_worker()
	if _screen_thread==null and _movement_wanted and movement==null and is_ready: prepare_movement()
	_update_processing()
	# Observers may queue another edit. Clear the finished candidate before emit.
	if notify: changed.emit()

func _commit_screen(layout: Dictionary) -> void:
	var node := Screen.geometry(layout,navigation.ground)
	# Remove authored screen pieces only once; subsequent edits own one subtree.
	if _screen_node!=null: _screen_node.free()
	else:
		for mesh in _content.find_children("*","MeshInstance3D",true,false):
			var name_ := str(mesh.name)
			if name_.begins_with("Screen_") or name_.begins_with("Support_") or name_.begins_with("Foot_"): mesh.free()
	_screen_node=node; _content.add_child(node); screen_layout=layout
	for material in _surfaces:
		material.set_shader_parameter("screen_origin",layout.center)
		material.set_shader_parameter("screen_right",layout.right)
		material.set_shader_parameter("screen_up",layout.up)
		material.set_shader_parameter("screen_normal",layout.normal)
		material.set_shader_parameter("screen_half_size",layout.half_size)

static func _prepare_movement(description: Dictionary,config: Dictionary,colliders: Array) -> RefCounted:
	var prepared := Movement.new()
	prepared.configure_beach(description,config,colliders)
	return prepared

func _vector(value: Array) -> Vector3:
	return Vector3(value[0],value[1],value[2])

func _material(shader: Shader) -> ShaderMaterial:
	var material := ShaderMaterial.new(); material.shader=shader
	var config: Dictionary = bundle.config
	var layout: Dictionary = bundle.layout
	var coast := PackedVector2Array()
	for point in config.shore.points: coast.append(Vector2(point[0],point[1]))
	material.set_shader_parameter("coast_count",coast.size())
	while coast.size()<16: coast.append(coast[-1])
	material.set_shader_parameter("coast",coast)
	material.set_shader_parameter("sea_level",config.shore.sea_level)
	material.set_shader_parameter("land_slope",config.terrain.land_slope)
	material.set_shader_parameter("uprush_offset",config.shore.uprush_offset)
	material.set_shader_parameter("sun_direction",_vector(layout.sun_direction))
	material.set_shader_parameter("film_color",_film_color)
	material.set_shader_parameter("screen_origin",_vector(layout.screen.center))
	material.set_shader_parameter("screen_half_size",Vector2(config.screen.width,config.screen.width/config.screen.aspect)*.5)
	var corners: Array = layout.screen.corners
	var right := (_vector(corners[1])-_vector(corners[0])).normalized()
	var up := (_vector(corners[3])-_vector(corners[0])).normalized()
	material.set_shader_parameter("screen_right",right); material.set_shader_parameter("screen_up",up)
	material.set_shader_parameter("screen_normal",right.cross(up).normalized())
	var lx := float(config.furniture.lamp[0]); var lz := float(config.furniture.lamp[1])
	material.set_shader_parameter("lamp_position",Vector3(lx,navigation.ground(lx,lz)+.8,lz))
	_surfaces.append(material)
	return material

func _install(loaded: Resource) -> void:
	var model := loaded.terrain.instantiate() as Node3D
	var props := loaded.props.instantiate() as Node3D
	error=_validate_scene(model,props)
	if not error.is_empty():
		if model: model.free()
		if props: props.free()
		return
	_clear_content()
	bundle=loaded
	navigation=Navigation.new(bundle.navigation,bundle.config)
	screen_layout=Screen.solve(bundle.config,navigation.ground,{})
	_content=Node3D.new(); _content.name="BeachContent"; add_child(_content)
	_content.add_child(model); _content.add_child(props)
	var sand := _material(SAND); var water := _material(WATER)
	water.set_shader_parameter("day_reflection",bundle.textures.day_reflection)
	_animated.assign([sand,water])
	for key in ["micro_color","micro_normal","macro_color","cliff_color","cliff_normal"]: sand.set_shader_parameter(key,bundle.textures[key])
	sand.set_shader_parameter("sand_surface",bundle.textures.sand_surface)
	var sand_bounds: Array=bundle.sand_surface.bounds_xz_size
	sand.set_shader_parameter("sand_surface_world",Vector4(sand_bounds[0],sand_bounds[1],sand_bounds[2],sand_bounds[3]))
	sand.set_shader_parameter("sand_slope_range",bundle.sand_surface.slope_range)
	sand.set_shader_parameter("sand_compaction_range",bundle.sand_surface.compaction_range)
	sand.set_shader_parameter("cliff_tile",bundle.config.perimeter.rock_tile_metres)
	sand.set_shader_parameter("cliff_saturation",bundle.config.perimeter.rock_saturation)
	sand.set_shader_parameter("cliff_tint",_vector(bundle.config.perimeter.rock_tint_linear))
	water.set_shader_parameter("beach_micro_color",bundle.textures.micro_color)
	water.set_shader_parameter("beach_macro_color",bundle.textures.macro_color)
	var worlds := PackedVector4Array(); var atlas := PackedVector4Array()
	for tile in bundle.mask_tiles:
		worlds.append(Vector4(tile.world[0],tile.world[1],tile.world[2],tile.world[3]))
		atlas.append(Vector4(tile.pixels[0],tile.pixels[1],tile.pixels[2],tile.pixels[3])/1024)
	for material in [sand,water]:
		material.set_shader_parameter("use_static_mask",true)
		material.set_shader_parameter("static_mask",bundle.textures.static_mask)
		material.set_shader_parameter("mask_world",worlds); material.set_shader_parameter("mask_atlas",atlas)
	# Ground visibility is an X/Z projection, not lighting for the rock above
	# it. Otherwise a boulder's own footprint shadow is painted onto its top.
	var rock_surface:=sand.duplicate() as ShaderMaterial
	rock_surface.set_shader_parameter("use_static_mask",false); _surfaces.append(rock_surface)
	for node in model.find_children("*","MeshInstance3D",true,false):
		if node.name=="Beach_Terrain" or str(node.name).begins_with("Beach_Perimeter_"): node.material_override=sand
		if str(node.name).begins_with("BayRock_"): node.material_override=rock_surface
		if node.name=="Sea_P0_FiniteProxy" or str(node.name).begins_with("Chair_") or str(node.name).begins_with("Table_") or node.name=="Lamp":
			node.get_parent().remove_child(node); node.free()
		elif node.name=="Screen_Front":
			var neutral := StandardMaterial3D.new()
			neutral.shading_mode=BaseMaterial3D.SHADING_MODE_UNSHADED
			neutral.albedo_color=Color(.42,.52,.63); neutral.cull_mode=BaseMaterial3D.CULL_BACK
			node.material_override=neutral
	var prop_materials: Array[ShaderMaterial] = []
	for kind in range(5):
		var material := _material(PROPS); material.set_shader_parameter("surface_kind",kind)
		for key in ["wood_color","rock_color","rock_normal","rock_arm"]: material.set_shader_parameter(key,bundle.textures[key])
		prop_materials.append(material)
	for node in props.find_children("*","MeshInstance3D",true,false):
		for index in node.mesh.get_surface_count():
			var source: Material = node.mesh.surface_get_material(index)
			var kind := ["P1_Wood","P1_Cloth","P1_Metal","P1_Rock","P2_Diffuser"].find(source.resource_name)
			if kind<0:
				error="Unknown beach material: "+source.resource_name; _clear_content(); return
			node.set_surface_override_material(index,prop_materials[kind])
	var sea := MeshInstance3D.new(); sea.name="Beach_Water"
	sea.mesh=water_mesh(bundle.config); sea.material_override=water; _content.add_child(sea)
	_sky_material=ShaderMaterial.new(); _sky_material.shader=SKY
	backdrop_material=ShaderMaterial.new()
	backdrop_material.shader=preload("res://shaders/private_beach/sky_backdrop.gdshader")
	_sky_material.set_shader_parameter("day_panorama",bundle.textures.day_sky)
	backdrop_material.set_shader_parameter("day_panorama",bundle.textures.day_sky)
	var sky := Sky.new(); sky.sky_material=_sky_material; sky.radiance_size=Sky.RADIANCE_SIZE_32
	background_environment=Environment.new()
	background_environment.background_mode=Environment.BG_SKY; background_environment.sky=sky
	background_environment.ambient_light_source=Environment.AMBIENT_SOURCE_COLOR
	background_environment.ambient_light_color=Color(.55,.65,.78)
	_sun=DirectionalLight3D.new(); _content.add_child(_sun)
	_sun.look_at(-_vector(bundle.layout.sun_direction),Vector3.UP)
	_sun.light_color=Color(1,.94,.85); _sun.shadow_enabled=false
	is_ready=true; visible=presented
	_apply_lighting()
	_update_processing()

func _validate_scene(model: Node3D,props: Node3D) -> String:
	if model==null or props==null: return "Beach geometry has no spatial root"
	for scene in [model,props]:
		if not scene.find_children("*","Camera3D",true,false).is_empty() or not scene.find_children("*","Light3D",true,false).is_empty():
			return "Beach geometry must not carry cameras or lights"
	for name_ in ["Beach_Terrain","Screen_Front","Beach_Perimeter_Sea","Beach_Perimeter_Right","Beach_Perimeter_Rear","Beach_Perimeter_Left"]:
		if model.find_children(name_,"MeshInstance3D",true,false).size()!=1: return "Beach mesh missing: "+name_
	for node in model.find_children("*","MeshInstance3D",true,false):
		if node.name!="Beach_Terrain" and not str(node.name).begins_with("Beach_Perimeter_") and not str(node.name).begins_with("BayRock_"): continue
		for surface in node.mesh.get_surface_count():
			var data: Array=node.mesh.surface_get_arrays(surface)
			if data[Mesh.ARRAY_COLOR]==null or data[Mesh.ARRAY_COLOR].is_empty(): return "Beach rock coverage missing"
	var meshes := props.find_children("*","MeshInstance3D",true,false)
	for required in ["Study_Chair_0","Study_Chair_1","Study_NearRock","Study_Table","Study_Lantern"]:
		if props.find_children(required,"MeshInstance3D",true,false).size()!=1: return "Beach prop missing: "+required
	for node in meshes:
		for index in node.mesh.get_surface_count():
			var material: Material = node.mesh.surface_get_material(index)
			if material==null or material.resource_name not in ["P1_Wood","P1_Cloth","P1_Metal","P1_Rock","P2_Diffuser"]:
				return "Unknown beach prop material"
			var arrays: Array = node.mesh.surface_get_arrays(index)
			if arrays[Mesh.ARRAY_COLOR]==null or arrays[Mesh.ARRAY_COLOR].is_empty(): return "Beach static visibility missing"
	return ""

static func water_mesh(config: Dictionary) -> ArrayMesh:
	# One connected strip follows the exact coastline, with dense rows at the
	# swash and coarse rows offshore. No rectangular side-plane intersections.
	var coast: Array=config.shore.points
	var columns: Array[Vector2]=[]
	for x in [-2000.0,-1000.0,-700.0,-500.0]: columns.append(Vector2(x,coast[0][1]))
	for segment in range(coast.size()-1):
		var a:=Vector2(coast[segment][0],coast[segment][1])
		var b:=Vector2(coast[segment+1][0],coast[segment+1][1])
		var count:=maxi(1,ceili(a.distance_to(b)/2.0))
		for i in range(count): columns.append(a.lerp(b,float(i)/count))
	columns.append(Vector2(coast[-1][0],coast[-1][1]))
	for x in [500.0,700.0,1000.0,2000.0]: columns.append(Vector2(x,coast[-1][1]))
	var offsets: Array[float]=[-2200,-1200,-500,-200,-80,-40,-20,-10,-5,-2,0,1,2,3]
	var vertices:=PackedVector3Array(); var normals:=PackedVector3Array(); var indices:=PackedInt32Array()
	for inland in offsets:
		for column in columns:
			var y:=float(config.shore.sea_level)+maxf(inland,0.0)*float(config.terrain.land_slope)
			vertices.append(Vector3(column.x,y,column.y+inland)); normals.append(Vector3.UP)
	var width:=columns.size()
	for row in range(offsets.size()-1):
		for col in range(width-1):
			var a:=row*width+col
			indices.append_array(PackedInt32Array([a,a+1,a+width,a+1,a+width+1,a+width]))
	var arrays: Array=[]; arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX]=vertices; arrays[Mesh.ARRAY_NORMAL]=normals; arrays[Mesh.ARRAY_INDEX]=indices
	var mesh:=ArrayMesh.new(); mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,arrays)
	return mesh

func _apply_lighting() -> void:
	if not is_ready: return
	var level := 0.0 if night else 1.0
	for material in _surfaces: material.set_shader_parameter("day_mix",level)
	_sky_material.set_shader_parameter("day_mix",level)
	backdrop_material.set_shader_parameter("day_mix",level)
	_sun.light_energy=0.0 if night else 1.1
	background_environment.ambient_light_energy=.06 if night else .4
