extends Node3D
## The reader's wand: it follows the controller ray, its tip glows, and a quick swish leaves a trail.
## Local frame: the handle at the origin, the tip along -z.

const GLOW := """
shader_type spatial;
render_mode unshaded, blend_premul_alpha, cull_disabled, depth_draw_never, shadows_disabled;
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
	// Light adds to what is behind it, but must not make the eye buffer opaque: where the eye buffer is
	// cleared over a page or menu layer (or passthrough), additive blending wrote alpha 1 across the
	// whole quad and showed it as a black square. Coverage follows the light itself.
	ALPHA = clamp(max(ALBEDO.r, max(ALBEDO.g, ALBEDO.b)), 0.0, 1.0);
}
"""
const LENGTH := 0.34
const DEFAULT_GLOW := Color(1.0, 0.85, 0.52)
## The modelled wands (tools/wands/build_wands.py), each LENGTH long with its pommel at the origin.
const STYLES := ["walnut", "gnarled", "ash", "ebony", "rosewood"]
const NAMES := {"walnut": "Walnut wand", "gnarled": "Gnarled wand", "ash": "Ash wand", "ebony": "Ebony wand", "rosewood": "Rosewood wand"}
const DEFAULT_STYLE := "walnut"
static var _library: MeshLibrary
static var _wood: ShaderMaterial
var style := ""
var _body := MeshInstance3D.new()
var tip := Node3D.new()
var _halo := MeshInstance3D.new()
var _trail: CPUParticles3D
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
	_body.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_body)
	set_style(DEFAULT_STYLE)
	tip.position = Vector3(0, 0, -LENGTH)
	add_child(tip)
	# Small: the tip sits between the eyes and the page, and a broad glow would hide the line being read.
	var halo := QuadMesh.new(); halo.size = Vector2.ONE * 0.035
	_halo.mesh = halo; _halo.material_override = glow_material(DEFAULT_GLOW, 1.0)
	tip.add_child(_halo)
	_trail = sparks(48, 0.7, 0.014, Color(1.0, 0.80, 0.42))
	tip.add_child(_trail)
	visible = false

## A known style id, or the default for anything else (an old or hand-edited setting).
static func valid_style(id: String) -> String:
	return id if id in STYLES else DEFAULT_STYLE

## The menu picture of a style: its handle and the start of its shaft, lying corner to corner.
static func picture(id: String) -> Texture2D:
	return load("res://assets/wands/%s.png" % valid_style(id))

func set_style(id: String) -> void:
	id = valid_style(id)
	if id == style: return
	style = id
	if _library == null:
		_library = load("res://assets/wands/wands.res")
		_wood = ShaderMaterial.new()
		_wood.shader = preload("res://assets/wands/wand.gdshader")
		_wood.set_shader_parameter("atlas", load("res://assets/wands/wands.png"))
	_body.mesh = _library.get_item_mesh(_library.find_item_by_name(id))
	_body.material_override = _wood

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

func tint(colour: Color) -> void:
	_halo.material_override.set_shader_parameter("colour",colour)

func _process(delta: float) -> void:
	if not visible or delta <= 0.0: _trail.emitting = false; return
	var now := tip.global_position
	_speed = lerpf(_speed, now.distance_to(_last) / delta, 0.4)
	_last = now
	_trail.emitting = _speed > 0.5
