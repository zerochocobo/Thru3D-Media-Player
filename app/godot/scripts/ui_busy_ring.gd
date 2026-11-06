extends RefCounted
## Shared video/photo/browser preparation indicator, animated by the shader clock.
static var shader: Shader
static func create(parent: Node3D,diameter: float,color: Color) -> MeshInstance3D:
	if not shader:
		shader=Shader.new()
		shader.code="""shader_type spatial;
render_mode unshaded, depth_draw_never, cull_disabled;
uniform vec4 tint : source_color;
void fragment() {
	vec2 p = UV * 2.0 - 1.0;
	float r = length(p);
	float lag = mod(atan(p.y, p.x) + TIME * 5.0, 6.2831853);
	float ring = smoothstep(0.78, 0.83, r) * (1.0 - smoothstep(0.93, 0.98, r));
	ALBEDO = tint.rgb;
	ALPHA = tint.a * ring * clamp(1.0 - lag / 4.2, 0.0, 1.0);
}"""
	var node:=MeshInstance3D.new();var mesh:=QuadMesh.new()
	mesh.size=Vector2.ONE*diameter*1.15;node.mesh=mesh;node.position=Vector3(0,0,0.005)
	var material:=ShaderMaterial.new();material.shader=shader
	material.set_shader_parameter("tint",color);material.render_priority=13
	node.material_override=material;node.visible=false;parent.add_child(node)
	return node
