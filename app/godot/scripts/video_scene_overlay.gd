extends RefCounted
## The retained auditorium is a background to the cutout, including its 50 m VR sphere.
## Reuse RayMenu's opt-in depth-free shader variant without changing the decoder material.
var material := ShaderMaterial.new()
var source: ShaderMaterial
var _shaders := {}
var _uniforms := {}

func restore(panel: MeshInstance3D) -> void:
	if panel.material_override == material: panel.material_override = source

func clear(panel: MeshInstance3D, binding: RefCounted) -> void:
	restore(panel)
	if source: binding.unshare(material)
	source = null

func apply(panel: MeshInstance3D, binding: RefCounted, portrait: bool) -> void:
	if not binding.material or not panel.material_override is ShaderMaterial: return
	source = panel.material_override
	var shader := source.shader
	if not shader: return
	if not _shaders.has(shader):
		var overlay := Shader.new()
		overlay.code = shader.code.replace("depth_prepass_alpha", "depth_draw_never").replace("render_mode ", "render_mode depth_test_disabled, ")
		_shaders[shader] = overlay
		_uniforms[shader] = shader.get_shader_uniform_list().map(func(item): return str(item.name)).filter(func(key): return key not in ["color_texture", "alpha_texture", "portrait_texture"])
	var parameters := {}
	for key in _uniforms[shader]: parameters[key] = source.get_shader_parameter(key)
	# The binding owns texture leases, updates decoder/RGBA variants, and clears this
	# consumer before retiring a frame. Never copy borrowed native texture handles.
	binding.share_with(material, parameters, portrait, _shaders[shader])
	material.render_priority = source.render_priority
	panel.material_override = material
