extends Node3D
signal visual_changed
## Shared side-view hand artwork and vector targets; animation changes UVs and transforms.
const INK := Color(0.90, 0.94, 0.98)
const ACCENT := Color(0.36, 0.88, 0.72)
const OPEN := '<path d="M91 226L81 198Q51 179 39 145Q33 130 44 126Q52 122 61 135L76 154L73 66Q72 48 83 48Q94 48 96 65L99 116L103 32Q105 17 116 20Q126 22 126 39L125 114L138 45Q141 31 151 35Q161 39 158 55L147 124L165 75Q171 62 180 69Q188 75 182 90L163 158Q154 185 146 199L143 226"/><path d="M94 165Q116 150 140 163M94 226H143"/>'
const SIDE_PINCH := preload("res://assets/gestures/pinch_side_atlas.png")
const WRIST_X := [604.0, 568.5, 543.5] # Wrist centres in each 724px square frame.
const ARROW := '<path d="M30 128H218M174 83L219 128L174 173"/>'
const PANEL := '<rect x="18" y="40" width="220" height="150" rx="12"/><path d="M40 160L90 100L134 140L175 82L217 160"/><circle cx="70" cy="74" r="10"/>'
static var textures := {}
var kind := "select"
var phase := 0.0
var animate := true
var left: MeshInstance3D
var right: MeshInstance3D
var target: MeshInstance3D
var arrow: MeshInstance3D
var second_arrow: MeshInstance3D

func _ready() -> void:
	# Animated every frame: stays in the eye buffer instead of repainting a menu compositor layer.
	set_meta("menu_eye_buffer", true)
	target = sheet("panel", PANEL, Vector2(0.31, 0.24), Color(0.35, 0.48, 0.53))
	left = sheet("open", OPEN, Vector2.ONE * 0.29, INK)
	right = sheet("open", OPEN, Vector2.ONE * 0.29, INK)
	left.material_override.render_priority = 16
	right.material_override.render_priority = 16
	arrow = sheet("arrow", ARROW, Vector2(0.21, 0.07), ACCENT)
	second_arrow = sheet("arrow", ARROW, Vector2(0.16, 0.06), ACCENT)
	arrow.material_override.render_priority = 17
	second_arrow.material_override.render_priority = 17
	show_phase(0)

func sheet(key: String, path: String, size: Vector2, color: Color) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	var mesh := QuadMesh.new(); mesh.size = size; node.mesh = mesh
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	material.render_priority = 14
	material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	material.albedo_color = color; material.albedo_texture = texture(key, path)
	node.material_override = material
	add_child(node)
	return node

static func texture(key: String, path: String) -> Texture2D:
	if not textures.has(key):
		var image := Image.new()
		image.load_svg_from_string('<svg xmlns="http://www.w3.org/2000/svg" width="256" height="256" viewBox="0 0 256 256"><g fill="none" stroke="white" stroke-width="9" stroke-linecap="round" stroke-linejoin="round">' + path + '</g></svg>')
		image.fix_alpha_edges()
		image.generate_mipmaps()
		textures[key] = ImageTexture.create_from_image(image)
	return textures[key]

func _process(delta: float) -> void:
	if animate and is_visible_in_tree(): show_phase(fmod(phase + delta / 3.0, 1.0))

func show_phase(value: float) -> void:
	visual_changed.emit()
	phase = value
	if not is_instance_valid(left): return
	var engaged := value > 0.16 and value < 0.82
	var progress := smoothstep(0.22, 0.7, value)
	var release := smoothstep(0.82, 1.0, value)
	var movement := progress * (1.0 - release)
	var pinch := texture("open", OPEN)
	var pose := 2 if engaged else (1 if value > 0.08 and value < 0.90 else 0)
	for hand in [left, right]:
		hand.material_override.albedo_texture = pinch if kind == "palm" else SIDE_PINCH
		hand.material_override.albedo_color = INK if kind == "palm" else Color.WHITE
		hand.material_override.uv1_scale = Vector3.ONE if kind == "palm" else Vector3(1.0 / 3.0, 1, 1)
		hand.material_override.uv1_offset = Vector3.ZERO if kind == "palm" else Vector3(float(pose) / 3.0, 0, 0)
	left.visible = kind == "zoom"
	right.position = Vector3(0.04, -0.02, 0.014)
	left.position = Vector3(-0.16, -0.02, 0.014)
	left.scale = Vector3(-1, 1, 1)
	target.position = Vector3(0, 0.035, 0)
	target.scale = Vector3.ONE
	arrow.position = Vector3(0.04, 0.135, 0.02)
	arrow.visible = kind in ["zoom", "swipe", "palm", "drag"]
	second_arrow.visible = false
	arrow.rotation.z = 0
	match kind:
		"zoom":
			left.position.x = -0.1 - movement * 0.13
			right.position.x = 0.1 + movement * 0.13
			target.scale = Vector3.ONE * (0.7 + movement * 0.35)
			arrow.visible = engaged
			second_arrow.visible = engaged
			arrow.position = Vector3(0.12 + movement * 0.06, 0.14, 0.02)
			arrow.mesh.size = Vector2(0.16, 0.06)
			second_arrow.position = Vector3(-0.12 - movement * 0.06, 0.14, 0.02)
			second_arrow.rotation.z = PI
		"swipe", "palm":
			right.position.x = 0.16 - movement * 0.26
			target.position.x = -movement * 0.13
			arrow.rotation.z = PI
		"drag":
			right.position = Vector3(-0.07 + movement * 0.18, -0.06 + movement * 0.10, 0.014)
			target.position = Vector3(movement * 0.18 - 0.08, movement * 0.10, 0)
			arrow.rotation.z = 0.5
		"controls":
			target.scale = Vector3.ONE * (0.85 + 0.15 * movement)
			target.material_override.albedo_color = Color(0.35, 0.48, 0.53).lerp(ACCENT, movement)
		_:
			target.material_override.albedo_color = Color(0.35, 0.48, 0.53).lerp(ACCENT, movement)
	if kind != "palm":
		var wrist_offset: float = (WRIST_X[1] - WRIST_X[pose]) / float(SIDE_PINCH.get_height()) * right.mesh.size.x
		right.position.x += wrist_offset
		left.position.x -= wrist_offset
