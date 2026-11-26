extends Node3D
## The reader's wand: it follows the controller ray, its tip glows, and a quick swish leaves a trail.
## Local frame: the handle at the origin, the tip along -z.

const GLOW := """
shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, shadows_disabled;
uniform vec3 colour : source_color = vec3(1.0, 0.82, 0.45);
uniform float strength = 1.0;
void vertex() {
	// Face the viewer wherever the wand points, keeping the size the scene gave it.
	float size = length(MODEL_MATRIX[0].xyz);
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(INV_VIEW_MATRIX[0] * size, INV_VIEW_MATRIX[1] * size, INV_VIEW_MATRIX[2] * size, MODEL_MATRIX[3]);
}
void fragment() {
	float d = length(UV - vec2(0.5)) * 2.0;
	float core = smoothstep(1.0, 0.0, d);
	ALBEDO = colour * strength * (core * core * core + 0.35 * core);
}
"""
const LENGTH := 0.34
var tip := Node3D.new()
var _halo := MeshInstance3D.new()
var _trail := CPUParticles3D.new()
var _last := Vector3.ZERO
var _speed := 0.0

static func glow_material(colour: Color, strength: float, priority: int = 20) -> ShaderMaterial:
	var shader := Shader.new(); shader.code = GLOW
	var material := ShaderMaterial.new(); material.shader = shader
	material.set_shader_parameter("colour", colour); material.set_shader_parameter("strength", strength)
	material.render_priority = priority
	return material

static func sparks(amount: int, lifetime: float, size: float, colour: Color) -> CPUParticles3D:
	var particles := CPUParticles3D.new()
	particles.amount = amount; particles.lifetime = lifetime; particles.local_coords = false; particles.emitting = false
	particles.direction = Vector3.UP; particles.spread = 180.0; particles.gravity = Vector3(0, -0.12, 0)
	particles.initial_velocity_min = 0.02; particles.initial_velocity_max = 0.14
	particles.scale_amount_min = 0.4; particles.scale_amount_max = 1.0
	var fade := Curve.new(); fade.add_point(Vector2(0, 1)); fade.add_point(Vector2(1, 0)); particles.scale_amount_curve = fade
	var quad := QuadMesh.new(); quad.size = Vector2.ONE * size
	particles.mesh = quad; particles.material_override = glow_material(colour, 1.4)
	return particles

func _init() -> void:
	var shaft := MeshInstance3D.new()
	var wood := CylinderMesh.new(); wood.top_radius = 0.0035; wood.bottom_radius = 0.0095; wood.height = LENGTH; wood.radial_segments = 10; wood.rings = 1
	shaft.mesh = wood
	# The cylinder's axis is +y: lay it along -z with the thin end forward.
	shaft.transform = Transform3D(Basis(Vector3.RIGHT, -PI * 0.5), Vector3(0, 0, -LENGTH * 0.5))
	var bark := StandardMaterial3D.new(); bark.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED; bark.albedo_color = Color(0.23, 0.15, 0.10)
	shaft.material_override = bark
	add_child(shaft)
	var grip := MeshInstance3D.new()
	var band := CylinderMesh.new(); band.top_radius = 0.0105; band.bottom_radius = 0.0115; band.height = 0.018; band.radial_segments = 10
	grip.mesh = band; grip.transform = Transform3D(Basis(Vector3.RIGHT, -PI * 0.5), Vector3(0, 0, -0.07))
	var gold := StandardMaterial3D.new(); gold.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED; gold.albedo_color = Color(0.83, 0.66, 0.30)
	grip.material_override = gold
	add_child(grip)
	tip.position = Vector3(0, 0, -LENGTH)
	add_child(tip)
	# Small: the tip sits between the eyes and the page, and a broad glow would hide the line being read.
	var halo := QuadMesh.new(); halo.size = Vector2.ONE * 0.035
	_halo.mesh = halo; _halo.material_override = glow_material(Color(1.0, 0.85, 0.52), 1.0)
	tip.add_child(_halo)
	_trail = sparks(48, 0.7, 0.014, Color(1.0, 0.80, 0.42))
	tip.add_child(_trail)
	visible = false

func aim(origin: Vector3, direction: Vector3) -> void:
	if direction.length_squared() < 0.0001: visible = false; return
	var forward := direction.normalized()
	var up := Vector3.UP if absf(forward.dot(Vector3.UP)) < 0.98 else Vector3.FORWARD
	global_transform = Transform3D(Basis.looking_at(forward, up), origin)
	visible = true

## Brighter while a spell is being cast (a page is in the air).
func cast(active: bool) -> void:
	_halo.material_override.set_shader_parameter("strength", 2.2 if active else 1.0)
	_halo.scale = Vector3.ONE * (1.8 if active else 1.0)

func _process(delta: float) -> void:
	if not visible or delta <= 0.0: _trail.emitting = false; return
	var now := tip.global_position
	_speed = lerpf(_speed, now.distance_to(_last) / delta, 0.4)
	_last = now
	_trail.emitting = _speed > 0.5
