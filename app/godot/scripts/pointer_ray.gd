extends RefCounted
## Shared full ray for the existing menu, world and photo pointers. Picking stays
## with their owners; soft edges and a stable visual width keep the beam unobtrusive.
const SHADER := preload("res://shaders/pointer_ray.gdshader")
static var _overlay_shader: Shader

static func create(color: Color, priority: int, overlay: bool = true) -> MeshInstance3D:
	var line := MeshInstance3D.new()
	line.mesh = ImmediateMesh.new()
	line.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	line.extra_cull_margin = 0.05
	var material := ShaderMaterial.new()
	if overlay and not _overlay_shader:
		_overlay_shader = Shader.new()
		_overlay_shader.code = SHADER.code.replace("render_mode ", "render_mode depth_test_disabled, ")
	material.shader = _overlay_shader if overlay else SHADER
	material.render_priority = priority
	material.set_shader_parameter("ray_color", color)
	line.material_override = material
	line.visible = false
	return line

static func draw(line: MeshInstance3D, origin: Vector3, endpoint: Vector3) -> void:
	# Keep the controller-to-target connection at every distance.
	# The duplicated centre vertices expand per eye in the shader into a soft ribbon.
	var start := line.to_local(origin)
	var end := line.to_local(endpoint)
	var material := line.material_override as ShaderMaterial
	material.set_shader_parameter("ray_start", start)
	material.set_shader_parameter("ray_end", end)
	var mesh := line.mesh as ImmediateMesh
	mesh.clear_surfaces()
	mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)
	for uv in [Vector2(0, 0), Vector2(0, 1), Vector2(1, 0), Vector2(1, 1)]:
		mesh.surface_set_uv(uv)
		# Alpha remains the original full-ray projection weight, never opacity.
		mesh.surface_set_color(Color(1, 1, 1, uv.y))
		mesh.surface_add_vertex(start if uv.y == 0 else end)
	mesh.surface_end()
