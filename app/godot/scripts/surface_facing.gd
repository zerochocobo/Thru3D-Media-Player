extends RefCounted
## Opt-in front-facing variants of the existing video shaders. Canonical source
## and decoder/texture identity stay intact; no duplicated shader implementation.
const FLAG := &"surface_front_faces_only"
static var _variants := {}
static var _sources := {}

static func source(shader: Shader) -> Shader:
	return _sources.get(shader,shader)

static func for_material(material: ShaderMaterial,shader: Shader) -> Shader:
	shader=source(shader)
	if shader==null or not bool(material.get_meta(FLAG,false)): return shader
	if _variants.has(shader): return _variants[shader]
	var pattern := RegEx.new(); pattern.compile("render_mode\\s+([^;]+);")
	var match_ := pattern.search(shader.code)
	if match_==null: return shader
	var modes := PackedStringArray()
	for item in match_.get_string(1).split(","):
		var mode := item.strip_edges()
		# The physical screen/back and nearby props must occlude subtitles and
		# cutouts too. Ordinary floating media keeps its original depth policy.
		if mode in ["cull_disabled","cull_front","cull_back","depth_test_disabled"]: continue
		modes.append(mode)
	modes.append("cull_back")
	var variant := Shader.new()
	variant.code=shader.code.substr(0,match_.get_start())+"render_mode "+", ".join(modes)+";"+shader.code.substr(match_.get_end())
	variant.resource_name=shader.resource_name+"_front_faces"
	_variants[shader]=variant; _sources[variant]=shader
	return variant

static func apply(material: ShaderMaterial,enabled: bool) -> void:
	if material==null: return
	if not enabled and not material.has_meta(FLAG): return
	if enabled: material.set_meta(FLAG,true)
	else: material.remove_meta(FLAG)
	var shader := for_material(material,material.shader)
	if shader==material.shader: return
	# This is the SAME material and SAME live frame lease. Keep raw texture RIDs
	# in place; do not claim, duplicate or retire native slots during a face toggle.
	var values := {}
	if material.shader:
		for uniform in material.shader.get_shader_uniform_list():
			var name := str(uniform.name)
			values[name]=RenderingServer.material_get_param(material.get_rid(),name)
	material.shader=shader
	for name in values:
		if values[name]!=null: RenderingServer.material_set_param(material.get_rid(),name,values[name])
