extends RefCounted
## Unity scene bundles. A native unpacker (native/unity-scene) turns the bundle into a neutral
## container of bulk arrays; this script builds the Godot scene from it. Baked lighting is kept:
## surfaces are unshaded albedo x lightmap, which is also the cheapest thing a headset can draw.
const Layout := preload("res://scripts/scene_import/scene_import_layout.gd")
const CONTAINER_MAGIC := "T3DSCENE"
const MAX_JSON_BYTES := 64 * 1024 * 1024
const FORMATS := {
	"l8": Image.FORMAT_L8, "r8": Image.FORMAT_R8, "rgb8": Image.FORMAT_RGB8, "rgba8": Image.FORMAT_RGBA8,
	"rgbah": Image.FORMAT_RGBAH, "rgbaf": Image.FORMAT_RGBAF,
	"dxt1": Image.FORMAT_DXT1, "dxt5": Image.FORMAT_DXT5, "bptc_rgba": Image.FORMAT_BPTC_RGBA,
	"bptc_rgbfu": Image.FORMAT_BPTC_RGBFU, "rgtc_r": Image.FORMAT_RGTC_R, "rgtc_rg": Image.FORMAT_RGTC_RG,
	"etc": Image.FORMAT_ETC, "etc2_rgb8": Image.FORMAT_ETC2_RGB8, "etc2_rgb8a1": Image.FORMAT_ETC2_RGB8A1,
	"etc2_rgba8": Image.FORMAT_ETC2_RGBA8, "etc2_r11": Image.FORMAT_ETC2_R11, "etc2_rg11": Image.FORMAT_ETC2_RG11,
	"astc_4x4": Image.FORMAT_ASTC_4x4, "astc_8x8": Image.FORMAT_ASTC_8x8,
}
## What other platforms' scripts tell us, matched by serialized field or class name.
const SPAWN_FIELDS := ["ChuShengDian", "spawns", "spawnPoint", "SpawnPoint", "spawnPoints"]
const FLOOR_CLASSES := ["TeleportationArea", "TeleportationAnchor"]
## Baked lightmaps store half range ("dLDR"), so the stored value is doubled.
const LIGHTMAP_SCALE := 2.0
## Unity's sky tint is "0.5 = unchanged": doubled in display space, which is x4.59 in linear light.
const SKY_TINT_SCALE := 4.594794
## Textures are sampled as stored and multiplied in display space, the way the source shows
## them. The GL Compatibility renderer passes an unshaded colour straight to the screen
## (measured: 0.5 in, 0.5 out); the other renderers expect linear light, hence the two outputs.
const OUTPUT_DISPLAY := "shown * exposure"
const OUTPUT_LINEAR := "pow(max(shown * exposure, vec3(0.0)), vec3(2.2))"
const SURFACE_SHADER := """shader_type spatial;
render_mode unshaded, %s, %s;
uniform sampler2D albedo_map : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform vec4 albedo_color = vec4(1.0);
uniform vec4 albedo_st = vec4(1.0, 1.0, 0.0, 0.0);
uniform sampler2D light_map : hint_default_white, filter_linear, repeat_disable;
uniform float light_scale = 0.0;
uniform vec3 flat_light = vec3(1.0);
uniform sampler2D emission_map : hint_default_black, filter_linear_mipmap, repeat_enable;
uniform vec3 emission_color = vec3(0.0);
uniform float alpha_cutoff = 0.0;
uniform float exposure = 1.0;
uniform float bake_strength = 1.0;
// The playing screen as a light: set once for every imported surface (see ensure_globals).
global uniform vec3 scene_import_screen_position;
global uniform vec3 scene_import_screen_normal;
global uniform vec3 scene_import_screen_color;
global uniform float scene_import_screen_range;
varying vec3 screen_lit;
void vertex() {
	vec3 to_screen = scene_import_screen_position - (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float away = max(length(to_screen), 0.001);
	vec3 toward = to_screen / away;
	float facing = max(dot(normalize(MODEL_NORMAL_MATRIX * NORMAL), toward), 0.0);
	float in_front = max(dot(scene_import_screen_normal, -toward), 0.0);
	float reach = away / max(scene_import_screen_range, 0.001);
	screen_lit = scene_import_screen_color * facing * in_front / (1.0 + 8.0 * reach * reach);
}
void fragment() {
	vec2 uv = UV * albedo_st.xy + albedo_st.zw;
	vec4 base = texture(albedo_map, uv) * albedo_color;
	vec3 light = light_scale > 0.0 ? mix(vec3(1.0), texture(light_map, UV2).rgb * light_scale, bake_strength) : flat_light;
	vec3 shown = base.rgb * (light + screen_lit) + texture(emission_map, uv).rgb * emission_color;
	ALBEDO = %s;
%s}
"""
const SKY_SHADER := """shader_type sky;
uniform sampler2D panorama : source_color, filter_linear, repeat_enable;
uniform vec3 tint = vec3(1.0);
uniform float rotation = 0.0;
void sky() {
	// Back into the source's left-handed frame, then undo its rotation about the vertical axis.
	vec3 d = vec3(EYEDIR.x, EYEDIR.y, -EYEDIR.z);
	vec2 turned = vec2(cos(rotation) * d.x + sin(rotation) * d.z, -sin(rotation) * d.x + cos(rotation) * d.z);
	vec2 uv = vec2(0.5 - atan(turned.y, turned.x) / TAU, 1.0 - acos(clamp(d.y, -1.0, 1.0)) / PI);
	COLOR = texture(panorama, uv).rgb * tint;
}
"""

## Set on Android to the plugin bridge: (bundle_path, output_path, max_texture, max_sky_texture) -> error text, empty on success.
static var unpacker: Callable
## Desktop tool used when no bridge is set.
static var unpacker_executable := ""

var _file: FileAccess
var _scene: Dictionary
var _textures := {}
var _shaders := {}
var _materials := {}
var _ambient := Color(0.5, 0.5, 0.5)

static var _globals_ready := false
const SCREEN_GLOBALS := [["scene_import_screen_position", RenderingServer.GLOBAL_VAR_TYPE_VEC3, Vector3.ZERO],
	["scene_import_screen_normal", RenderingServer.GLOBAL_VAR_TYPE_VEC3, Vector3(0, 0, 1)],
	["scene_import_screen_color", RenderingServer.GLOBAL_VAR_TYPE_VEC3, Vector3.ZERO],
	["scene_import_screen_range", RenderingServer.GLOBAL_VAR_TYPE_FLOAT, 10.0]]

## The surface shader reads the screen light from global uniforms; they must exist before it compiles.
static func ensure_globals() -> void:
	# Tracked here: asking the engine which globals exist is an editor-only call.
	if _globals_ready: return
	_globals_ready = true
	for entry in SCREEN_GLOBALS: RenderingServer.global_shader_parameter_add(entry[0], entry[1], entry[2])

## Where the playing screen is and what it throws, in display-space colour; black turns it off.
static func set_screen_light(position: Vector3, normal: Vector3, colour: Vector3, reach: float) -> void:
	RenderingServer.global_shader_parameter_set("scene_import_screen_position", position)
	RenderingServer.global_shader_parameter_set("scene_import_screen_normal", normal)
	RenderingServer.global_shader_parameter_set("scene_import_screen_color", colour)
	RenderingServer.global_shader_parameter_set("scene_import_screen_range", reach)

## Viewer-side look controls for a scene built here: overall brightness, and how much of the
## source's baked lighting to keep (0 shows plain surface colour, useful when the bake is poor).
static func set_look(root: Node, exposure: float, bake_strength: float) -> void:
	var seen := {}
	for node in root.find_children("*", "MeshInstance3D", true, false):
		var mesh: Mesh = (node as MeshInstance3D).mesh
		if mesh == null: continue
		for surface in mesh.get_surface_count():
			var material := mesh.surface_get_material(surface) as ShaderMaterial
			if material == null or seen.has(material): continue
			seen[material] = true
			material.set_shader_parameter("exposure", exposure)
			material.set_shader_parameter("bake_strength", clampf(bake_strength, 0.0, 1.0))

static func is_bundle(path: String) -> bool:
	var file := FileAccess.open(path, FileAccess.READ)
	return file != null and file.get_length() > 64 and file.get_buffer(8) == "UnityFS".to_ascii_buffer() + PackedByteArray([0])

## Returns {root, actions, sky, warnings} or {error}.
func read(path: String, limits: Dictionary, work_dir: String) -> Dictionary:
	# The unpacker is native code: it needs real paths, not user:// ones.
	work_dir = ProjectSettings.globalize_path(work_dir)
	path = ProjectSettings.globalize_path(path)
	DirAccess.make_dir_recursive_absolute(work_dir)
	var container := work_dir.path_join("unpack-%d-%d.t3ds" % [OS.get_process_id(), Time.get_ticks_usec()])
	var problem := _unpack(path, container, int(limits.texture_size), int(limits.get("sky_width", 4096)))
	var result := {"error": problem} if not problem.is_empty() else read_container(container, limits)
	_file = null
	DirAccess.remove_absolute(container)
	return result

static func _unpack(bundle: String, container: String, max_texture: int, max_sky: int) -> String:
	if unpacker.is_valid(): return str(unpacker.call(bundle, container, max_texture, max_sky))
	if unpacker_executable.is_empty() or not FileAccess.file_exists(unpacker_executable):
		return "Unity scenes are not supported on this build"
	var output: Array = []
	var code := OS.execute(unpacker_executable, [bundle, container, str(max_texture), str(max_sky)], output, true)
	if code == 0: return ""
	var reason := str(output[0]).strip_edges() if not output.is_empty() else ""
	return "Scene could not be read" if code != 1 or reason.is_empty() else reason.left(200)

func read_container(container: String, limits: Dictionary) -> Dictionary:
	_file = FileAccess.open(container, FileAccess.READ)
	if _file == null or _file.get_length() < 24 or _file.get_buffer(8) != CONTAINER_MAGIC.to_ascii_buffer():
		return {"error": "Scene could not be read"}
	var json_at := _file.get_64()
	var json_size := _file.get_64()
	if json_size <= 0 or json_size > MAX_JSON_BYTES or json_at < 24 or json_at + json_size > _file.get_length():
		return {"error": "Scene could not be read"}
	_file.seek(json_at)
	var parser := JSON.new()
	if parser.parse(_file.get_buffer(json_size).get_string_from_utf8()) != OK or not parser.data is Dictionary:
		return {"error": "Scene could not be read"}
	_scene = parser.data
	for key in ["textures", "materials", "surfaces", "renderers", "behaviours", "lightmaps"]:
		if not _scene.get(key) is Array: return {"error": "Scene could not be read"}
	var ambient: Variant = _scene.get("ambient")
	if ambient is Array and ambient.size() == 3: _ambient = Color(ambient[0], ambient[1], ambient[2])

	var root := Node3D.new()
	root.name = "ImportedScene"
	var spawn: Variant = _spawn()
	var floors := {}
	for behaviour in _scene.behaviours:
		if behaviour is Dictionary and behaviour.get("class") in FLOOR_CLASSES: floors[int(behaviour.get("object", -1))] = behaviour
	var kept := _within_budget(limits, spawn)
	var with_renderer := {}
	var drawn := 0
	for entry in kept.renderers:
		var instance := _instance(entry)
		if instance == null: continue
		var object := int(entry.get("object", -1))
		if floors.has(object):
			instance.name = "%s_%s" % [Layout.FLOOR, instance.name]
			with_renderer[object] = true
		root.add_child(instance)
		drawn += 1
	# Walkable areas that are collider-only still define the floor.
	for object in floors:
		if with_renderer.has(object) or not floors[object].get("collider_surfaces") is Array: continue
		var shape := _mesh(floors[object].collider_surfaces, [], -1)
		if shape == null: continue
		var area := MeshInstance3D.new()
		area.name = "%s_%s" % [Layout.FLOOR, _node_name(floors[object].get("name"))]
		area.mesh = shape
		area.transform = _transform(floors[object].get("transform"))
		area.visible = false
		root.add_child(area)
	if spawn != null:
		# The script gives a position; which way its author meant "forward" is not knowable,
		# so the viewer starts out facing the middle of what was kept.
		var marker := Node3D.new()
		marker.name = Layout.SPAWN
		var toward: Vector3 = kept.centre - (spawn as Transform3D).origin
		toward.y = 0.0
		marker.transform = Transform3D(Basis.looking_at(toward.normalized()) if toward.length() > 0.5 else Basis.IDENTITY, (spawn as Transform3D).origin)
		root.add_child(marker)
	if drawn == 0:
		root.free()
		return {"error": "Scene holds no usable geometry"}
	var warnings: Array = _scene.get("warnings", []) if _scene.get("warnings") is Array else []
	return {"root": root, "sky": _sky(), "warnings": warnings,
		"actions": {"meshes_culled": kept.culled, "lights_removed": 0, "textures_resized": 0, "textures_kept_compressed": 0}}

# ---- descriptors

func _item(list_name: String, index: Variant) -> Dictionary:
	var list: Array = _scene[list_name]
	if not (index is float or index is int) or index < 0 or index >= list.size() or not list[int(index)] is Dictionary: return {}
	return list[int(index)]

static func _transform(value: Variant) -> Transform3D:
	if not value is Array or value.size() != 12: return Transform3D.IDENTITY
	for number in value:
		if not (number is float or number is int) or not is_finite(number): return Transform3D.IDENTITY
	return Transform3D(Vector3(value[0], value[1], value[2]), Vector3(value[3], value[4], value[5]),
		Vector3(value[6], value[7], value[8]), Vector3(value[9], value[10], value[11]))

static func _node_name(value: Variant) -> String:
	var text := str(value).validate_node_name().left(64)
	return text if not text.is_empty() else "Object"

func _spawn() -> Variant:
	for behaviour in _scene.behaviours:
		if not behaviour is Dictionary or not behaviour.get("fields") is Dictionary: continue
		for field in SPAWN_FIELDS:
			var value: Variant = behaviour.fields.get(field)
			if value is Array and not value.is_empty(): value = value[0]
			if value is Dictionary and value.get("transform") is Array:
				return Transform3D(Basis.IDENTITY, _transform(value.transform).origin)
	return null

## Drops whole renderers, farthest from the viewer first, before any geometry is read.
func _within_budget(limits: Dictionary, spawn: Variant) -> Dictionary:
	var entries: Array[Dictionary] = []
	var total := AABB()
	var triangles := 0
	var batches := 0
	for renderer in _scene.renderers:
		if not renderer is Dictionary or not renderer.get("surfaces") is Array: continue
		var xform := _transform(renderer.get("transform"))
		var box := AABB()
		var count := 0
		var parts := 0
		for part in renderer.surfaces:
			var surface := _item("surfaces", part.get("surface") if part is Dictionary else null)
			var bounds: Variant = surface.get("bounds")
			if surface.is_empty() or not bounds is Array or bounds.size() != 6: continue
			var local := AABB(Vector3(bounds[0], bounds[1], bounds[2]), Vector3(bounds[3] - bounds[0], bounds[4] - bounds[1], bounds[5] - bounds[2])).abs()
			box = xform * local if parts == 0 else box.merge(xform * local)
			count += int(surface.get("triangles", 0))
			parts += 1
		if parts == 0: continue
		total = box if entries.is_empty() else total.merge(box)
		triangles += count
		batches += parts
		entries.append({"renderer": renderer, "box": box, "triangles": count, "batches": parts})
	var origin: Vector3 = (spawn as Transform3D).origin if spawn != null else total.get_center()
	for entry in entries:
		var box: AABB = entry.box
		entry.distance = origin.distance_to(origin.clamp(box.position, box.end))
	entries.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.distance > b.distance)
	var culled := 0
	var renderers: Array[Dictionary] = []
	for index in entries.size():
		var entry := entries[index]
		# The nearest object always stays: an over-budget scene is reported, never emptied.
		if index < entries.size() - 1 and (triangles > int(limits.triangles) or batches > int(limits.batches)):
			triangles -= entry.triangles
			batches -= entry.batches
			culled += 1
		else:
			renderers.append(entry.renderer)
	var centre := Vector3.ZERO
	var weight := 0.0
	for entry in entries:
		if not renderers.has(entry.renderer): continue
		centre += (entry.box as AABB).get_center() * float(entry.triangles)
		weight += float(entry.triangles)
	return {"renderers": renderers, "culled": culled, "centre": centre / weight if weight > 0.0 else total.get_center()}

# ---- geometry

func _bytes(where: Variant, element: int, count: int) -> PackedByteArray:
	if not where is Dictionary: return PackedByteArray()
	var offset: Variant = where.get("offset")
	var size: Variant = where.get("size")
	if not (offset is float or offset is int) or not (size is float or size is int): return PackedByteArray()
	if offset < 24 or size != count * element or offset + size > _file.get_length(): return PackedByteArray()
	_file.seek(int(offset))
	return _file.get_buffer(int(size))

func _arrays(surface: Dictionary, shaded: bool) -> Array:
	var vertices := int(surface.get("vertices", 0))
	var triangles := int(surface.get("triangles", 0))
	if vertices <= 0 or triangles <= 0: return []
	var positions := _bytes(surface.get("position"), 12, vertices)
	var indices := _bytes(surface.get("index"), 4, triangles * 3)
	if positions.is_empty() or indices.is_empty(): return []
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = positions.to_vector3_array()
	arrays[Mesh.ARRAY_INDEX] = indices.to_int32_array()
	if not shaded: return arrays
	var normals := _bytes(surface.get("normal"), 12, vertices)
	if not normals.is_empty(): arrays[Mesh.ARRAY_NORMAL] = normals.to_vector3_array()
	var uv := _bytes(surface.get("uv"), 8, vertices)
	if not uv.is_empty(): arrays[Mesh.ARRAY_TEX_UV] = uv.to_vector2_array()
	var uv2 := _bytes(surface.get("uv2"), 8, vertices)
	if not uv2.is_empty(): arrays[Mesh.ARRAY_TEX_UV2] = uv2.to_vector2_array()
	return arrays

## `materials` pairs with `surfaces`; an empty list builds bare collision geometry.
func _mesh(surfaces: Array, materials: Array, lightmap: int) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	for index in surfaces.size():
		var arrays := _arrays(_item("surfaces", surfaces[index]), not materials.is_empty())
		if arrays.is_empty(): continue
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		if not materials.is_empty():
			mesh.surface_set_material(mesh.get_surface_count() - 1, _material(materials[index], lightmap, arrays[Mesh.ARRAY_TEX_UV2] != null))
	return mesh if mesh.get_surface_count() > 0 else null

func _instance(renderer: Dictionary) -> MeshInstance3D:
	var surfaces := []
	var materials := []
	for part in renderer.surfaces:
		if not part is Dictionary: continue
		surfaces.append(part.get("surface"))
		materials.append(part.get("material"))
	var lightmap: Variant = renderer.get("lightmap", -1)
	var mesh := _mesh(surfaces, materials, int(lightmap) if lightmap is float or lightmap is int else -1)
	if mesh == null: return null
	var instance := MeshInstance3D.new()
	instance.name = _node_name(renderer.get("name"))
	instance.mesh = mesh
	instance.transform = _transform(renderer.get("transform"))
	return instance

# ---- textures and materials

func _texture(index: Variant) -> Texture2D:
	var entry := _item("textures", index)
	if entry.is_empty(): return null
	var key := int(index)
	if _textures.has(key): return _textures[key]
	var texture: ImageTexture = null
	var width := int(entry.get("width", 0))
	var height := int(entry.get("height", 0))
	var where: Variant = entry.get("data")
	if FORMATS.has(entry.get("format")) and width > 0 and height > 0 and width <= 16384 and height <= 16384 and where is Dictionary:
		var size := int(where.get("size", 0))
		var data := _bytes(where, 1, size)
		if not data.is_empty():
			var image := Image.create_from_data(width, height, entry.get("mipmaps") == true, FORMATS[entry.format], data)
			if image != null and not image.is_empty(): texture = ImageTexture.create_from_image(image)
	_textures[key] = texture
	return texture

func _shader(blend: String, cull: String, alpha: String) -> Shader:
	var key := "%s|%s|%s" % [blend, cull, alpha]
	if not _shaders.has(key):
		var shader := Shader.new()
		var display := RenderingServer.get_current_rendering_method() == "gl_compatibility"
		shader.code = SURFACE_SHADER % [blend, cull, OUTPUT_DISPLAY if display else OUTPUT_LINEAR, alpha]
		_shaders[key] = shader
	return _shaders[key]

func _material(index: Variant, lightmap: int, has_uv2: bool) -> Material:
	var key := "%s|%d|%s" % [str(index), lightmap, has_uv2]
	if _materials.has(key): return _materials[key]
	var entry := _item("materials", index)
	var floats: Dictionary = entry.get("floats", {}) if entry.get("floats") is Dictionary else {}
	var colors: Dictionary = entry.get("colors", {}) if entry.get("colors") is Dictionary else {}
	var maps: Dictionary = entry.get("textures", {}) if entry.get("textures") is Dictionary else {}
	var shader_name := str(entry.get("shader", ""))
	var keywords: Array = entry.get("keywords", []) if entry.get("keywords") is Array else []
	# Standard: _Mode 0 opaque, 1 cutout, 2 fade, 3 transparent. URP: _Surface 1 transparent, _AlphaClip.
	var mode := int(floats.get("_Mode", 0))
	var transparent := mode >= 2 or int(floats.get("_Surface", 0)) == 1 or shader_name.contains("Transparent") or shader_name.contains("Particles")
	var cutout := not transparent and (mode == 1 or int(floats.get("_AlphaClip", 0)) == 1 or keywords.has("_ALPHATEST_ON"))
	var additive := shader_name.contains("Additive")
	var blend := "blend_add, depth_draw_never" if additive else "blend_mix, depth_draw_never" if transparent else "blend_mix, depth_draw_opaque"
	var cull := "cull_disabled" if int(floats.get("_Cull", 2)) == 0 or transparent else "cull_back"
	var alpha := "\tALPHA = base.a;\n" if transparent else "\tif (base.a < alpha_cutoff) discard;\n" if cutout else ""
	var material := ShaderMaterial.new()
	material.shader = _shader(blend, cull, alpha)
	material.resource_name = str(entry.get("name", ""))
	var albedo: Variant = maps.get("_MainTex", maps.get("_BaseMap"))
	if albedo is Dictionary:
		material.set_shader_parameter("albedo_map", _texture(albedo.get("texture")))
		var scale: Variant = albedo.get("scale")
		var offset: Variant = albedo.get("offset")
		if scale is Array and offset is Array and scale.size() == 2 and offset.size() == 2:
			material.set_shader_parameter("albedo_st", Vector4(scale[0], scale[1], offset[0], offset[1]))
	var tint: Variant = colors.get("_Color", colors.get("_BaseColor", colors.get("_TintColor")))
	if tint is Array and tint.size() == 4: material.set_shader_parameter("albedo_color", Color(tint[0], tint[1], tint[2], tint[3]))
	if cutout: material.set_shader_parameter("alpha_cutoff", float(floats.get("_Cutoff", 0.5)))
	var glow: Variant = colors.get("_EmissionColor")
	if keywords.has("_EMISSION") and glow is Array and glow.size() >= 3:
		material.set_shader_parameter("emission_color", Vector3(glow[0], glow[1], glow[2]))
		var emission: Variant = maps.get("_EmissionMap")
		if emission is Dictionary: material.set_shader_parameter("emission_map", _texture(emission.get("texture")))
		else: material.set_shader_parameter("emission_map", _white())
	var light := _texture(lightmap) if lightmap >= 0 and has_uv2 else null
	if light != null:
		material.set_shader_parameter("light_map", light)
		material.set_shader_parameter("light_scale", LIGHTMAP_SCALE)
	else:
		# No bake for this object: unlit shaders show as authored, lit ones get the scene's ambient level.
		var unlit := shader_name.contains("Unlit") or shader_name.contains("Particles") or transparent
		material.set_shader_parameter("flat_light", Vector3.ONE if unlit else Vector3(_ambient.r, _ambient.g, _ambient.b) * 2.0)
	_materials[key] = material
	return material

var _white_texture: ImageTexture
func _white() -> ImageTexture:
	if _white_texture == null:
		var image := Image.create(1, 1, false, Image.FORMAT_RGB8)
		image.fill(Color.WHITE)
		_white_texture = ImageTexture.create_from_image(image)
	return _white_texture

func _sky() -> Sky:
	var entry := _item("materials", _scene.get("sky_material"))
	if entry.is_empty() or not str(entry.get("shader", "")).contains("Panoramic"): return null
	var maps: Dictionary = entry.get("textures", {}) if entry.get("textures") is Dictionary else {}
	var floats: Dictionary = entry.get("floats", {}) if entry.get("floats") is Dictionary else {}
	var colors: Dictionary = entry.get("colors", {}) if entry.get("colors") is Dictionary else {}
	var main: Variant = maps.get("_MainTex")
	var panorama := _texture(main.get("texture")) if main is Dictionary else null
	if panorama == null: return null
	var shader := Shader.new()
	shader.code = SKY_SHADER
	var material := ShaderMaterial.new()
	material.shader = shader
	material.set_shader_parameter("panorama", panorama)
	material.set_shader_parameter("rotation", deg_to_rad(float(floats.get("_Rotation", 0.0))))
	var tint: Variant = colors.get("_Tint")
	var colour := (Color(tint[0], tint[1], tint[2]) if tint is Array and tint.size() >= 3 else Color(0.5, 0.5, 0.5)).srgb_to_linear()
	var exposure := float(floats.get("_Exposure", 1.0)) * SKY_TINT_SCALE
	material.set_shader_parameter("tint", Vector3(colour.r, colour.g, colour.b) * exposure)
	var sky := Sky.new()
	sky.sky_material = material
	return sky
