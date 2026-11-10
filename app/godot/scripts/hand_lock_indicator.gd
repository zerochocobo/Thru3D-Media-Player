extends Node3D
## Small recovery target; no input surface or physics collider, so it cannot hit content.
signal composition_changed
signal composition_layout_changed
func composition_root() -> Node3D: return self
const Icons := preload("res://scripts/menu_icons.gd")
const RING_SHADER := "shader_type spatial; render_mode unshaded, cull_disabled, depth_draw_never; uniform float progress = 0.0; uniform vec4 tint : source_color = vec4(0.35,0.95,0.8,1.0); void fragment(){ vec2 p=UV-vec2(0.5); float r=length(p); float a=mod(atan(p.x,-p.y)+6.2831853,6.2831853)/6.2831853; float edge=smoothstep(0.39,0.41,r)*(1.0-smoothstep(0.46,0.48,r)); ALBEDO=tint.rgb; ALPHA=edge*(a<progress?1.0:0.18); }"
var icon: MeshInstance3D
var ring: MeshInstance3D
var cursor: MeshInstance3D
var line: MeshInstance3D

static func make_ring(parent: Node3D, diameter: float) -> MeshInstance3D:
	var mesh := MeshInstance3D.new()
	mesh.mesh = QuadMesh.new(); mesh.mesh.size = Vector2.ONE * diameter
	var shader := Shader.new(); shader.code = RING_SHADER
	var material := ShaderMaterial.new(); material.shader = shader
	mesh.material_override = material; mesh.position.z = 0.002
	mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mesh)
	return mesh

static func flat_material(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.albedo_color = color
	return material

func _ready() -> void:
	ring = make_ring(self, 0.12)
	icon = MeshInstance3D.new(); icon.mesh = QuadMesh.new(); icon.mesh.size = Vector2.ONE * 0.072
	icon.material_override = flat_material(Color(0.8, 1.0, 0.94))
	icon.material_override.albedo_texture = Icons.texture("hand_locked")
	icon.position.z = 0.003; add_child(icon)
	cursor = MeshInstance3D.new(); cursor.mesh = SphereMesh.new()
	cursor.mesh.radius = 0.0035; cursor.mesh.height = 0.007
	cursor.material_override = flat_material(Color.WHITE); add_child(cursor)
	cursor.set_meta("menu_eye_buffer", true)
	line = MeshInstance3D.new(); line.mesh = ImmediateMesh.new()
	line.material_override = flat_material(Color(0.6, 0.9, 0.85, 0.8)); add_child(line)
	line.set_meta("menu_eye_buffer", true)
	for node in [icon, cursor, line]: node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	visible = false

func sync(gesture: RefCounted, ray: Variant, world_scale: float) -> void:
	var was_visible := visible
	visible = gesture.shown and ray != null
	if was_visible != visible: composition_layout_changed.emit()
	if not visible: return
	global_transform = gesture.target
	scale = Vector3.ONE * world_scale
	ring.material_override.set_shader_parameter("progress", gesture.progress)
	icon.material_override.albedo_color = Color(0.45, 1.0, 0.8) if gesture.hit else Color(0.8, 0.85, 0.88)
	cursor.global_position = gesture.cursor
	cursor.visible = gesture.cursor.is_finite()
	var end: Vector3 = to_local(gesture.cursor)
	var direction: Vector3 = global_basis.inverse() * ray[1]
	line.mesh.clear_surfaces()
	line.mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	line.mesh.surface_add_vertex(end - direction.normalized() * 0.1)
	line.mesh.surface_add_vertex(end)
	line.mesh.surface_end()
	composition_changed.emit()
