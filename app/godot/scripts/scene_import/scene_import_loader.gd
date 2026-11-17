extends RefCounted
## User-supplied scenes (glTF/GLB, FBX, Unity scene bundles) as viewing environments. Self-contained: nothing here is
## referenced by the built-in cinema or beach paths.
const Budget := preload("res://scripts/scene_import/scene_import_budget.gd")
const Audit := preload("res://scripts/scene_import/scene_import_audit.gd")
const Layout := preload("res://scripts/scene_import/scene_import_layout.gd")
const Cache := preload("res://scripts/scene_import/scene_import_cache.gd")
const Unity := preload("res://scripts/scene_import/scene_import_unity.gd")
const MAX_JSON_BYTES := 64 * 1024 * 1024
const MAX_SIDECAR_BYTES := 64 * 1024
const MAX_NODES := 100000
const MAX_STORED_TRIANGLES := 8000000
## How the scene's own lights are scaled (see _level); the controller reads LIGHT_ENERGY to dim them.
const LAMP_LEVEL := 0.5
const LAMP_REACH := 2.0
const LAMP_FLOOR := 0.02
const SUN_LEVEL := 1.0
const LIGHT_ENERGY := &"scene_light_energy"

## Set on Android to the plugin's ETC2 encoder: (rgba mip chain, width, height, alpha) -> encoded
## mip chain, empty on failure. Without it decoded textures stay uncompressed (four times larger).
static var texture_encoder: Callable

signal finished(result: Dictionary)
var _task := -1
static var _active := {}
var _progress_lock := Mutex.new()
var _stage := ""
var _fraction := -1.0

## Where the load has got to, for whoever is waiting: a stage name and how far through it
## (0..1, or -1 when the stage cannot say). Safe to call while the worker runs.
func progress() -> Dictionary:
	_progress_lock.lock()
	var state := {"stage": _stage, "fraction": _fraction}
	_progress_lock.unlock()
	return state

func _report(stage: String, fraction: float = -1.0) -> void:
	_progress_lock.lock()
	_stage = stage
	_fraction = fraction
	_progress_lock.unlock()

## Background load; `finished` fires on the main thread. One load at a time; call from the main thread.
## A cached scene is read by the engine's loader threads, anything else is imported on a worker.
func start(path: String, tier: String, options: Dictionary = {}) -> void:
	Unity.ensure_globals()
	# Callables do not keep a RefCounted alive; the task must outlive the caller's variable.
	_active[get_instance_id()] = self
	var cache_dir: String = options.get("cache_dir", Cache.ROOT)
	var entry_key := Cache.key(path, tier) if options.get("use_cache", true) else ""
	if Cache.has(entry_key, cache_dir):
		_report("Loading scene")
		var cached: Node3D = await Cache.restore_async(entry_key, cache_dir)
		if cached:
			finished.emit({"root": cached, "info": cached.get_meta(Cache.META), "cached": true})
			_release.call_deferred(get_instance_id())
			return
	# Worker imports never restore from the cache themselves (see Cache.restore).
	var worker_options := options.duplicate()
	worker_options["restore"] = false
	_task = WorkerThreadPool.add_task(func() -> void: _complete.call_deferred(load_scene(path, tier, worker_options)))

func _complete(result: Dictionary) -> void:
	WorkerThreadPool.wait_for_task_completion(_task)
	finished.emit(result)
	_release.call_deferred(get_instance_id())

static func _release(id: int) -> void:
	_active.erase(id)

## Returns {root, info, cached} or {error}. `info` is also stored on the root as metadata.
## Options: limits (Dictionary), cache_dir (String), use_cache (bool), cull (bool).
func load_scene(path: String, tier: String, options: Dictionary = {}) -> Dictionary:
	Unity.ensure_globals()
	var limits: Dictionary = options.get("limits", Budget.limits(tier))
	var cache_dir: String = options.get("cache_dir", Cache.ROOT)
	var use_cache: bool = options.get("use_cache", true)
	var unity := Unity.is_bundle(path)
	var problem := _preflight_bundle(path, limits) if unity else _preflight(path, limits)
	if not problem.is_empty(): return {"error": problem}
	var entry_key := Cache.key(path, tier)
	if use_cache and options.get("restore", true):
		var cached := Cache.restore(entry_key, cache_dir)
		if cached: return {"root": cached, "info": cached.get_meta(Cache.META), "cached": true}
	# Each source ends as the same thing: a detached tree plus what was done to fit the tier.
	_report("Unpacking scene" if unity else "Reading model")
	var source := Unity.new().read(path, limits, cache_dir.path_join("work")) if unity else _read_model(path, limits)
	if source.has("error"): return {"error": source.error}
	_report("Preparing scene")
	var root: Node3D = source.root
	var actions: Dictionary = source.actions
	var stats := Audit.audit(root)
	# Decoded images are four times the size of GPU-compressed ones; step the size down until they fit.
	var edge := int(limits.texture_size)
	while not unity and int(stats.texture_bytes) > int(limits.texture_bytes) and edge > 256:
		edge /= 2
		var shrunk := _shrink_textures(Audit.drawables(root), edge)
		actions.textures_resized += shrunk.textures_resized
		stats = Audit.audit(root)
	actions.texture_size = edge
	var layout := Layout.resolve(root, stats.bounds, _sidecar(path))
	if options.get("cull", true) and _over(stats, limits):
		actions.meshes_culled += _cull(root, (layout.spawn as Transform3D).origin, limits)
		stats = Audit.audit(root)
	var over: Array[String] = []
	for name in ["triangles", "batches", "texture_bytes"]:
		if int(stats[name]) > int(limits[name]): over.append(name)
	var info := {"version": Cache.VERSION, "tier": tier, "name": path.get_file(), "stats": stats,
		"layout": layout, "actions": actions, "over_budget": over, "source": "unity" if unity else "fbx" if _fbx(path) else "gltf",
		"sky": source.get("sky"), "warnings": source.get("warnings", [])}
	root.set_meta(Cache.META, info)
	if use_cache:
		_report("Saving scene")
		Cache.store(entry_key, root, {"name": info.name, "tier": tier, "triangles": stats.triangles,
			"batches": stats.batches, "texture_bytes": stats.texture_bytes, "over_budget": over}, cache_dir)
	return {"root": root, "info": info, "cached": false}

static func _fbx(path: String) -> bool:
	return path.get_extension().to_lower() == "fbx"

## glTF and FBX come through the engine's two readers and leave as the same tree.
func _read_model(path: String, limits: Dictionary) -> Dictionary:
	var fbx := _fbx(path)
	var document: GLTFDocument = FBXDocument.new() if fbx else GLTFDocument.new()
	var state: GLTFState = FBXState.new() if fbx else GLTFState.new()
	state.handle_binary_image = GLTFState.HANDLE_BINARY_EMBED_AS_UNCOMPRESSED
	var result := document.append_from_file(path, state)
	if result != OK: return {"error": "Model could not be loaded (%s)" % error_string(result)}
	var root := document.generate_scene(state) as Node3D
	if root == null: return {"error": "Model contains no 3D scene"}
	# FBX has no header to count from: its size is only known once it is read.
	if fbx and int(Audit.audit(root).triangles) > MAX_STORED_TRIANGLES:
		root.free()
		return {"error": "Scene is too detailed for this headset"}
	var actions := {"lights_removed": _strip(root, int(limits.lights), fbx), "meshes_culled": 0}
	var items := Audit.drawables(root)
	# Kept lights are unshadowed fill: surface detail maps (normal, roughness, metal...) would only add memory.
	actions.detail_maps_dropped = _drop_detail_maps(items)
	_report("Processing textures")
	actions.merge(_shrink_textures(items, int(limits.texture_size)))
	actions.textures_compressed = _compress_textures(items)
	return {"root": root, "actions": actions}

const DETAIL_SLOTS := [BaseMaterial3D.TEXTURE_NORMAL, BaseMaterial3D.TEXTURE_ROUGHNESS, BaseMaterial3D.TEXTURE_METALLIC,
	BaseMaterial3D.TEXTURE_AMBIENT_OCCLUSION, BaseMaterial3D.TEXTURE_HEIGHTMAP, BaseMaterial3D.TEXTURE_CLEARCOAT,
	BaseMaterial3D.TEXTURE_RIM, BaseMaterial3D.TEXTURE_FLOWMAP, BaseMaterial3D.TEXTURE_SUBSURFACE_SCATTERING,
	BaseMaterial3D.TEXTURE_SUBSURFACE_TRANSMITTANCE, BaseMaterial3D.TEXTURE_BACKLIGHT, BaseMaterial3D.TEXTURE_REFRACTION]

func _drop_detail_maps(items: Array[Dictionary]) -> int:
	var dropped := 0
	for material in Audit.materials(items):
		if not material is BaseMaterial3D: continue
		material.normal_enabled = false
		material.ao_enabled = false
		material.heightmap_enabled = false
		# The factors assumed their maps (glTF metal defaults to 1): left alone, ambient shows such a surface black.
		material.metallic = 0.0
		material.roughness = 1.0
		for slot in DETAIL_SLOTS:
			if material.get_texture(slot) != null:
				material.set_texture(slot, null)
				dropped += 1
		if material.emission_enabled:
			# A surface that lights itself would wash out with the player's ambient on top:
			# occlusion takes off the ambient it already supplies and leaves the screen's light alone.
			var own := clampf(material.emission.get_luminance() * material.emission_energy_multiplier, 0.0, 1.0)
			var shade := Image.create(1, 1, false, Image.FORMAT_R8)
			shade.set_pixel(0, 0, Color(1.0 - own, 0, 0))
			material.ao_enabled = true
			material.ao_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_RED
			material.ao_texture = ImageTexture.create_from_image(shade)
	return dropped

## Decoded textures to ETC2 through the platform encoder, when there is one.
func _compress_textures(items: Array[Dictionary]) -> int:
	if texture_encoder.is_null(): return 0
	# Each distinct texture once, with alpha looked for only where it can show.
	var alpha := {}
	for material in Audit.materials(items):
		if not material is BaseMaterial3D: continue
		for slot in BaseMaterial3D.TEXTURE_MAX:
			var texture: Texture2D = material.get_texture(slot)
			if texture != null: alpha[texture] = alpha.get(texture, false) or slot == BaseMaterial3D.TEXTURE_ALBEDO
	var replaced := {}
	var count := 0
	for texture in alpha:
		_report("Compressing textures", float(replaced.size()) / alpha.size())
		replaced[texture] = _compressed(texture, alpha[texture])
		if replaced[texture] != texture: count += 1
	for material in Audit.materials(items):
		if not material is BaseMaterial3D: continue
		for slot in BaseMaterial3D.TEXTURE_MAX:
			var texture: Texture2D = material.get_texture(slot)
			if texture != null and replaced[texture] != texture: material.set_texture(slot, replaced[texture])
	return count

static func _compressed(texture: Texture2D, may_have_alpha: bool) -> Texture2D:
	var image := texture.get_image()
	if image == null or image.is_empty() or image.is_compressed(): return texture
	var width := image.get_width() - image.get_width() % 4
	var height := image.get_height() - image.get_height() % 4
	if width < 4 or height < 4: return texture
	var alpha := may_have_alpha and image.detect_alpha() != Image.ALPHA_NONE
	image.convert(Image.FORMAT_RGBA8)
	if width != image.get_width() or height != image.get_height(): image.resize(width, height, Image.INTERPOLATE_BILINEAR)
	image.generate_mipmaps()
	var encoded: Variant = texture_encoder.call(image.get_data(), width, height, alpha)
	if not encoded is PackedByteArray or encoded.is_empty(): return texture
	var packed := Image.create_from_data(width, height, true, Image.FORMAT_ETC2_RGBA8 if alpha else Image.FORMAT_ETC2_RGB8, encoded)
	return ImageTexture.create_from_image(packed) if packed != null and not packed.is_empty() else texture

func _preflight_bundle(path: String, limits: Dictionary) -> String:
	return "Model file too large" if FileAccess.get_size(path) > int(limits.file_bytes) else ""

static func _over(stats: Dictionary, limits: Dictionary) -> bool:
	return int(stats.triangles) > int(limits.triangles) or int(stats.batches) > int(limits.batches)

## Cheap structural checks before the engine parses anything.
func _preflight(path: String, limits: Dictionary) -> String:
	var extension := path.get_extension().to_lower()
	if extension not in ["glb", "gltf", "fbx"]: return "Unsupported scene format"
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null: return "Model unavailable"
	var size := file.get_length()
	if size > int(limits.file_bytes): return "Model file too large"
	if extension == "fbx":
		# Binary files open with a fixed signature, text ones name their header section early on.
		var head := file.get_buffer(mini(size, 4096)).get_string_from_ascii()
		return "" if head.begins_with("Kaydara FBX Binary") or head.contains("FBXHeaderExtension") else "Unsupported scene format"
	var text := ""
	if extension == "glb":
		if size < 20: return "Invalid GLB header"
		var header := file.get_buffer(20)
		if header.decode_u32(0) != 0x46546c67 or header.decode_u32(4) != 2 or header.decode_u32(8) > size:
			return "Invalid GLB header"
		var length := int(header.decode_u32(12))
		if length <= 0 or length > size - 20 or length > MAX_JSON_BYTES or header.decode_u32(16) != 0x4e4f534a:
			return "Invalid GLB scene data"
		text = file.get_buffer(length).get_string_from_utf8()
	else:
		if size > MAX_JSON_BYTES: return "Invalid glTF scene data"
		text = file.get_as_text()
	var parser := JSON.new()
	if parser.parse(text) != OK or not parser.data is Dictionary: return "Invalid glTF scene data"
	var gltf: Dictionary = parser.data
	var nodes: Variant = gltf.get("nodes", [])
	var accessors: Variant = gltf.get("accessors", [])
	var meshes: Variant = gltf.get("meshes", [])
	if not nodes is Array or not accessors is Array or not meshes is Array: return "Invalid glTF scene data"
	if nodes.size() > MAX_NODES: return "Scene has too many objects"
	var triangles := 0.0
	for mesh in meshes:
		if not mesh is Dictionary or not mesh.get("primitives") is Array: return "Invalid glTF scene data"
		for primitive in mesh.primitives:
			if not primitive is Dictionary: return "Invalid glTF scene data"
			var attributes: Variant = primitive.get("attributes")
			var index: Variant = primitive.get("indices", attributes.get("POSITION") if attributes is Dictionary else null)
			if not (index is float or index is int) or index < 0 or index >= accessors.size(): continue
			var accessor: Variant = accessors[int(index)]
			var count: Variant = accessor.get("count") if accessor is Dictionary else null
			if count is float or count is int: triangles += maxf(float(count), 0.0) / 3.0
	if triangles > MAX_STORED_TRIANGLES: return "Scene is too detailed for this headset"
	return ""

func _sidecar(path: String) -> Dictionary:
	var file := FileAccess.open(path.get_basename() + ".scene.json", FileAccess.READ)
	if file == null or file.get_length() > MAX_SIDECAR_BYTES: return {}
	var parser := JSON.new()
	return parser.data if parser.parse(file.get_as_text()) == OK and parser.data is Dictionary else {}

## Cameras and animation never drive the viewer here; lights are capped and unshadowed.
func _strip(root: Node3D, lights_allowed: int, fbx: bool = false) -> int:
	var removed := 0
	for node in root.find_children("*", "Camera3D", true, false) + root.find_children("*", "AnimationPlayer", true, false):
		_detach(node)
	var lights: Array[Light3D] = []
	for node in root.find_children("*", "Light3D", true, false):
		if node.visible and (node as Light3D).light_energy > 0.0: lights.append(node)
		else:
			_detach(node)
			removed += 1
	# FBX keeps a lamp's whole output (Blender writes its watts unchanged, as it does a sun's strength);
	# glTF gives it per steradian. Brought to glTF's terms, a sun keeps the same weight beside lamps.
	if fbx:
		for light in lights: if not light is DirectionalLight3D: light.light_energy /= 4.0 * PI
	_level(lights)
	# The brightest are kept, judged by what each gives at arm's length (a sun the same everywhere).
	lights.sort_custom(func(a: Light3D, b: Light3D) -> bool: return _strength(a) > _strength(b))
	for light in lights.slice(lights_allowed):
		_detach(light)
		removed += 1
	return removed

static func _strength(light: Light3D) -> float:
	return light.light_energy if light is DirectionalLight3D else light.light_energy / (LAMP_REACH * LAMP_REACH)

## Exporters scale light strengths their own way (Blender's watts arrive as thousands of candela and
## washed a room out on a headset), so only the ratios between a scene's lights are kept: its
## strongest lamp gives LAMP_LEVEL at LAMP_REACH metres. Suns share that scale (glTF gives lamps in
## candela and suns in lux, so a dim moon beside bright lamps stays dim), up to SUN_LEVEL; a scene
## lit only by suns has its strongest at SUN_LEVEL. Each lamp ends where it falls to LAMP_FLOOR of
## that level, so it draws only the meshes near it.
func _level(lights: Array[Light3D]) -> void:
	var peak := {}
	for light in lights:
		var kind := light is DirectionalLight3D
		peak[kind] = maxf(peak.get(kind, 0.0), light.light_energy)
	var scale: float = LAMP_LEVEL * LAMP_REACH * LAMP_REACH / peak[false] if peak.has(false) else SUN_LEVEL / peak.get(true, 1.0)
	for light in lights:
		light.shadow_enabled = false
		light.light_indirect_energy = 0.0
		light.light_specular = 0.0
		if light is DirectionalLight3D:
			light.light_energy = minf(light.light_energy * scale, SUN_LEVEL)
		else:
			light.light_energy *= scale
			light.set_param(Light3D.PARAM_ATTENUATION, 2.0)
			light.set_param(Light3D.PARAM_RANGE, minf(light.get_param(Light3D.PARAM_RANGE), sqrt(light.light_energy / (LAMP_LEVEL * LAMP_FLOOR))))
		light.set_meta(LIGHT_ENERGY, light.light_energy)

static func _detach(node: Node) -> void:
	var parent := node.get_parent()
	if parent == null: return
	for child in node.get_children():
		if child is Node3D and node is Node3D: child.transform = node.transform * child.transform
		node.remove_child(child)
		parent.add_child(child)
	parent.remove_child(node)
	node.free()

func _shrink_textures(items: Array[Dictionary], limit: int) -> Dictionary:
	var replaced := {}
	var counts := {"textures_resized": 0, "textures_kept_compressed": 0}
	for material in Audit.materials(items):
		if not material is BaseMaterial3D: continue
		for slot in BaseMaterial3D.TEXTURE_MAX:
			var texture: Texture2D = material.get_texture(slot)
			if texture == null: continue
			if not replaced.has(texture): replaced[texture] = _shrunk(texture, limit, counts)
			if replaced[texture] != texture: material.set_texture(slot, replaced[texture])
	return counts

static func _shrunk(texture: Texture2D, limit: int, counts: Dictionary) -> Texture2D:
	var largest := maxi(texture.get_width(), texture.get_height())
	var image := texture.get_image()
	if image == null or image.is_empty(): return texture
	if image.is_compressed():
		if largest > limit: counts.textures_kept_compressed += 1
		return texture
	if largest <= limit and image.has_mipmaps(): return texture
	if largest > limit:
		while maxi(image.get_width(), image.get_height()) >= limit * 2: image.shrink_x2()
		largest = maxi(image.get_width(), image.get_height())
		if largest > limit:
			image.resize(maxi(image.get_width() * limit / largest, 1), maxi(image.get_height() * limit / largest, 1), Image.INTERPOLATE_BILINEAR)
		counts.textures_resized += 1
	image.generate_mipmaps()
	return ImageTexture.create_from_image(image)

## Drops the farthest geometry first until the triangle and batch limits hold.
func _cull(root: Node3D, origin: Vector3, limits: Dictionary) -> int:
	var items := Audit.drawables(root)
	var triangles := 0
	var batches := 0
	for item in items:
		triangles += item.triangles
		batches += item.batches
		var box: AABB = item.bounds
		item.distance = origin.distance_to(origin.clamp(box.position, box.end))
	items.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.distance > b.distance)
	var culled := 0
	# The nearest object always stays: an over-budget scene is reported, never emptied.
	for item in items.slice(0, maxi(items.size() - 1, 0)):
		if triangles <= int(limits.triangles) and batches <= int(limits.batches): break
		var node: Node3D = item.node
		if node == root or String(node.name).to_lower().begins_with(Layout.FLOOR): continue
		triangles -= item.triangles
		batches -= item.batches
		culled += 1
		if node.get_child_count() == 0:
			node.get_parent().remove_child(node)
			node.free()
		elif node is MeshInstance3D: node.mesh = null
		else: node.multimesh = null
	return culled
