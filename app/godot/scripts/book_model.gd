extends Node3D
## A physical open book: boards, two blocks of leaves whose thickness follows the reading position,
## two facing pages that dip into the gutter, and one leaf that bends as it turns.
## Local frame: origin at the spine on the page surface, +x right, +y up the page, +z towards the reader.

const PAGE_SHADER := """
shader_type spatial;
render_mode unshaded, cull_disabled;
uniform sampler2D front : source_color, filter_linear_mipmap_anisotropic, repeat_disable;
uniform sampler2D back : source_color, filter_linear_mipmap_anisotropic, repeat_disable;
uniform bool has_front = false;
uniform bool has_back = false;
uniform vec3 paper : source_color = vec3(0.91, 0.89, 0.82);
uniform vec3 light = vec3(1.0);
// A leaf in the air shades the page beneath it just past its free edge, more softly the higher it rises.
uniform float edge = 0.0;
uniform float lift = 0.0;
uniform float shadow = 0.0;
uniform bool sharpened = true;
varying float shade;
varying float across;
void vertex() { shade = COLOR.r; across = VERTEX.x; }
// A page drawn in the eye buffer (a leaf turning) gets far fewer pixels than on its layer, and a
// plain trilinear read softens small type further. Four reads spread over the pixel, each a mip
// level finer, average the type at the pixel's own size instead of a blurred smaller copy.
vec3 sharp(sampler2D page, vec2 uv) {
	vec2 dx = dFdx(uv); vec2 dy = dFdy(uv);
	vec2 gx = dx * 0.5; vec2 gy = dy * 0.5;
	vec3 sum = textureGrad(page, uv + 0.125 * dx + 0.375 * dy, gx, gy).rgb;
	sum += textureGrad(page, uv - 0.375 * dx + 0.125 * dy, gx, gy).rgb;
	sum += textureGrad(page, uv + 0.375 * dx - 0.125 * dy, gx, gy).rgb;
	sum += textureGrad(page, uv - 0.125 * dx - 0.375 * dy, gx, gy).rgb;
	return sum * 0.25;
}
void fragment() {
	// UV.x runs from the spine outwards on both faces, so the verso is mirrored here.
	vec3 colour = paper;
	vec2 verso = vec2(1.0 - UV.x, UV.y);
	if (FRONT_FACING) { if (has_front) colour = sharpened ? sharp(front, UV) : texture(front, UV).rgb; }
	else if (has_back) colour = sharpened ? sharp(back, verso) : texture(back, verso).rgb;
	float beyond = (across - edge) * sign(edge);
	float soft = 0.012 + lift * 1.6;
	float dark = shadow * step(0.0, beyond) * exp(-beyond / soft) * clamp(1.0 - lift * 4.0, 0.35, 1.0);
	ALBEDO = colour * shade * light * (1.0 - 0.5 * dark);
}
"""
const BODY_SHADER := """
shader_type spatial;
render_mode unshaded;
uniform vec3 colour : source_color = vec3(0.2, 0.16, 0.13);
uniform float leaves = 0.0;
uniform vec3 gilt : source_color = vec3(0.86, 0.68, 0.30);
varying vec3 local;
varying vec3 facing;
void vertex() { local = VERTEX; facing = NORMAL; }
void fragment() {
	// The cut edges of a block of leaves read as fine lines along its thickness.
	float lines = mix(1.0, 0.86 + 0.14 * step(0.5, fract(local.z * 900.0)), leaves * (1.0 - abs(facing.z)));
	// Gilded edges: the cut sides of the leaves catch the light.
	vec3 base = mix(colour, gilt * (0.75 + 0.25 * sin(local.y * 40.0 + TIME * 0.6)), leaves * (1.0 - abs(facing.z)) * 0.85);
	ALBEDO = base * lines * (0.78 + 0.22 * max(facing.z, 0.0));
}
"""
const Wand := preload("res://scripts/book_wand.gd")
## A slowly turning circle of light, drawn in the rune ring: rings, a band of runes and a six-pointed star.
const CIRCLE_SHADER := """
shader_type spatial;
render_mode unshaded, blend_premul_alpha, cull_disabled, depth_draw_never, shadows_disabled;
uniform vec3 colour : source_color = vec3(1.0, 0.78, 0.40);
uniform float strength = 0.6;
float line(float d, float w) { return smoothstep(w, 0.0, abs(d)); }
void fragment() {
	vec2 p = UV * 2.0 - 1.0;
	float r = length(p);
	float a = atan(p.y, p.x);
	float turn = TIME * 0.05;
	float light = line(r - 0.95, 0.012) + line(r - 0.80, 0.007) + line(r - 0.55, 0.006) + 0.6 * line(r - 0.50, 0.004);
	// Short strokes between the outer rings, like graduations on an instrument.
	float ticks = step(0.82, r) * step(r, 0.93) * step(0.82, abs(fract((a + turn) / TAU * 72.0) - 0.5) * 2.0);
	// A band of invented letters, counter-rotating.
	float around = (a - turn * 1.6) / TAU * 26.0;
	float seed = fract(sin(floor(around) * 91.7) * 43758.5);
	vec2 g = vec2(fract(around), (r - 0.58) / 0.19);
	float inside = step(0.0, g.y) * step(g.y, 1.0) * step(0.2, g.x) * step(g.x, 0.8);
	float rune = inside * max(step(abs(g.x - 0.3 - 0.4 * seed), 0.025), max(step(abs(g.y - 0.2 - 0.6 * fract(seed * 7.0)), 0.035), step(abs(g.x + g.y - 0.7 - seed * 0.6), 0.03) * step(0.5, fract(seed * 13.0))));
	// Two triangles turning the other way.
	float star = 0.0;
	for (int k = 0; k < 6; k++) {
		float angle = turn * 2.0 + float(k) * TAU / 6.0;
		star += line(dot(p, vec2(cos(angle), sin(angle))) - 0.25, 0.005);
	}
	star *= step(r, 0.50);
	float glow = light + 0.45 * ticks + 0.75 * rune + 0.7 * star + 0.10 * smoothstep(0.95, 0.0, r);
	ALBEDO = colour * strength * glow * smoothstep(1.0, 0.96, r);
	// Light adds to what is behind it, but must not make the eye buffer opaque: where the eye buffer is
	// cleared over a page or menu layer (or passthrough), additive blending wrote alpha 1 across the
	// whole quad and showed it as a black square. Coverage follows the light itself.
	ALPHA = clamp(max(ALBEDO.r, max(ALBEDO.g, ALBEDO.b)), 0.0, 1.0);
}
"""
const COLUMNS := 24
const BLOCK := 0.034 # all leaves together
const BOARD := 0.005
const GUTTER := 0.010

var page_size := Vector2(0.42, 0.56)
var paper := Color(0.91, 0.89, 0.82)
var cover := Color(0.20, 0.16, 0.13)
## Position through the book, 0..1: leaves move from the right block to the left one.
var progress := 0.0
## Reading one page at a time: the left side is only the back of the leaves already read.
var single := false
## Paper brightness, 0..1: dimmer paper in a dark scene keeps the lenses from glaring.
## Brightness and warmth over every sheet: multiplies the paper and its printing.
var light := Color.WHITE
## Which side the turning leaf is over: 1 the right, -1 the left, 0 while no leaf is in the air.
var leaf_side := 0
## How a leaf goes over: 0 curls up and over (standing tall at the middle of the turn), 1 stays low
## over the pages (a reader sitting close never has a page rise towards the face), 2 is not shown at
## all (the pages change at once; a leaf held with the trigger still shows, low).
var turn_style := 0
const CURL := 0
const LOW := 1
const INSTANT := 2
## How high a low leaf rises, as a share of the curl's.
const LOW_RISE := 0.16
## The paper makes no sound.
var quiet := false

var _left := MeshInstance3D.new()
var _right := MeshInstance3D.new()
var _leaf := MeshInstance3D.new()
var _blocks: Array[MeshInstance3D] = []
var _boards: Array[MeshInstance3D] = []
var _spine := MeshInstance3D.new()
var _aura := MeshInstance3D.new()
var _riffle: Array[MeshInstance3D] = []
var _sound := AudioStreamPlayer3D.new()
var _mark := MeshInstance3D.new()
## Bookmark tabs over the top edge of a marked page: [left, right].
var _tabs: Array[MeshInstance3D] = []
var _motes: CPUParticles3D
var _sparks: CPUParticles3D
var _page_shader := Shader.new()
var _body_shader := Shader.new()

func _init() -> void:
	_page_shader.code = PAGE_SHADER
	_body_shader.code = BODY_SHADER
	for side in 2:
		var block := MeshInstance3D.new(); block.mesh = BoxMesh.new(); block.material_override = _body(true); _blocks.append(block); add_child(block)
		var board := MeshInstance3D.new(); board.mesh = BoxMesh.new(); board.material_override = _body(false); _boards.append(board); add_child(board)
	_spine.mesh = BoxMesh.new(); _spine.material_override = _body(false); add_child(_spine)
	for sheet in [_left, _right, _leaf]:
		var material := ShaderMaterial.new(); material.shader = _page_shader
		sheet.material_override = material; add_child(sheet)
	_leaf.visible = false
	# Blank leaves that flutter over when the book is opened far from where it lay.
	for i in 3:
		var flutter := MeshInstance3D.new(); var material := ShaderMaterial.new(); material.shader = _page_shader
		flutter.material_override = material; flutter.visible = false
		_riffle.append(flutter); add_child(flutter)
	_sound.stream = rustle(); _sound.volume_db = -8.0; _sound.unit_size = 2.5; _sound.max_polyphony = 3
	add_child(_sound)
	# Light behind the tome, a ribbon marker, dust adrift around it and sparks off a turning leaf.
	_aura.mesh = QuadMesh.new(); _aura.material_override = Wand.glow_material(Color(1.0, 0.78, 0.42), 0.16, -2); add_child(_aura)
	_mark.mesh = QuadMesh.new()
	var silk := StandardMaterial3D.new(); silk.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED; silk.albedo_color = Color(0.60, 0.09, 0.12); silk.cull_mode = BaseMaterial3D.CULL_DISABLED
	_mark.material_override = silk; add_child(_mark)
	for side in 2:
		var tab := MeshInstance3D.new(); tab.mesh = QuadMesh.new(); tab.material_override = silk; tab.visible = false
		tab.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_tabs.append(tab); add_child(tab)
	_motes = Wand.sparks(60, 8.0, 0.035, Color(1.0, 0.86, 0.55))
	_motes.emission_shape = CPUParticles3D.EMISSION_SHAPE_RING; _motes.emission_ring_axis = Vector3(0, 0, 1)
	_motes.gravity = Vector3(0, 0.01, 0); _motes.initial_velocity_min = 0.01; _motes.initial_velocity_max = 0.06
	_motes.preprocess = 6.0
	add_child(_motes)
	_sparks = Wand.sparks(90, 0.9, 0.04, Color(1.0, 0.82, 0.45))
	_sparks.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX; _sparks.gravity = Vector3(0, -0.25, 0); _sparks.initial_velocity_max = 0.5
	add_child(_sparks)
	rebuild()

func _ready() -> void:
	_motes.emitting = true

func _body(leaves: bool) -> ShaderMaterial:
	var material := ShaderMaterial.new(); material.shader = _body_shader
	material.set_shader_parameter("leaves", 1.0 if leaves else 0.0)
	return material

## Depth of the page surface below the flat plane: leaves curve down into the binding.
func _dip(x: float) -> float:
	return -GUTTER * exp(-x / (page_size.x * 0.085))

func rebuild() -> void:
	# Even at the first or last page a side keeps enough leaves to hold the dip of the gutter above its board.
	var least := GUTTER + 0.003
	var thickness := [BLOCK * clampf(progress, 0.0, 1.0) + least, BLOCK * (1.0 - clampf(progress, 0.0, 1.0)) + least]
	for side in 2:
		var direction := -1.0 if side == 0 else 1.0
		var block: BoxMesh = _blocks[side].mesh
		# The leaves dip into the binding near the spine; the block stands only where they lie flat.
		var inner := page_size.x * 0.34
		block.size = Vector3(page_size.x - inner - 0.002, page_size.y - 0.004, thickness[side])
		_blocks[side].position = Vector3(direction * (inner + (page_size.x - inner - 0.002) * 0.5), 0, -thickness[side] * 0.5 - 0.0008)
		_blocks[side].material_override.set_shader_parameter("colour", paper * 0.93 * light * (0.35 if single and side == 0 else 1.0))
		var board: BoxMesh = _boards[side].mesh
		board.size = Vector3(page_size.x + 0.012, page_size.y + 0.024, BOARD)
		_boards[side].position = Vector3(direction * (page_size.x * 0.5 + 0.006), 0, -thickness[side] - BOARD * 0.5 - 0.0008)
		_boards[side].material_override.set_shader_parameter("colour", cover)
	var spine: BoxMesh = _spine.mesh
	spine.size = Vector3(0.014, page_size.y + 0.024, BLOCK + least + BOARD)
	_spine.position = Vector3(0, 0, -(BLOCK + least + BOARD) * 0.5 - GUTTER - 0.001)
	_spine.material_override.set_shader_parameter("colour", cover * 0.85)
	var aura: QuadMesh = _aura.mesh
	aura.size = Vector2(page_size.x * 4.6, page_size.y * 2.6)
	_aura.position = Vector3(0, 0, -BLOCK - 0.05)
	var mark: QuadMesh = _mark.mesh
	mark.size = Vector2(0.011, 0.075)
	_mark.position = Vector3(0.013, -page_size.y * 0.5 - 0.03, -0.006)
	for side in 2:
		(_tabs[side].mesh as QuadMesh).size = Vector2(0.024, 0.06)
		# Out over the top edge near the outer corner, a hair in front of the paper and its sharp layer.
		_tabs[side].position = Vector3((-1.0 if side == 0 else 1.0) * page_size.x * 0.82, page_size.y * 0.5 + 0.012, 0.004)
	_motes.emission_ring_inner_radius = Vector2(page_size.x, page_size.y * 0.5).length() * 1.12
	_motes.emission_ring_radius = _motes.emission_ring_inner_radius * 1.55
	_motes.emission_ring_height = 0.3
	_sparks.emission_box_extents = Vector3(0.004, page_size.y * 0.5, 0.004)
	_left.mesh = _sheet(-1.0, 0.0)
	_right.mesh = _sheet(1.0, 0.0)
	for sheet in [_left, _right, _leaf] + _riffle:
		sheet.material_override.set_shader_parameter("paper", paper)
		# Reading one page at a time, the leaves already read lie in shadow instead of glaring blank.
		sheet.material_override.set_shader_parameter("light", _rgb(light) * (0.3 if single and sheet == _left else 1.0))

static func _rgb(colour: Color) -> Vector3: return Vector3(colour.r, colour.g, colour.b)

## A resting page on one side of the spine. Its texture always reads left to right.
func _sheet(direction: float, lift: float) -> ArrayMesh:
	var points := PackedVector2Array()
	for column in COLUMNS + 1:
		var s := page_size.x * column / COLUMNS
		points.append(Vector2(direction * s, _dip(s) + lift))
	return _ribbon(points, direction < 0)

## Builds a strip from a cross-section (x, z) running outwards from the spine.
func _ribbon(section: PackedVector2Array, mirrored: bool, lifted: bool = false) -> ArrayMesh:
	var vertices := PackedVector3Array(); var uvs := PackedVector2Array(); var colours := PackedColorArray(); var indices := PackedInt32Array()
	var half := page_size.y * 0.5
	for column in section.size():
		var u := float(column) / (section.size() - 1)
		# Paper darkens where it turns away into the binding.
		var slope := 0.0
		if column + 1 < section.size(): slope = absf(section[column + 1].y - section[column].y) / maxf(absf(section[column + 1].x - section[column].x), 0.0001)
		var shade := clampf(1.0 - slope * 0.55, 0.62, 1.0) * (0.86 + 0.14 * smoothstep(0.0, 0.16, u))
		# A leaf in the air is lit along its whole length; only its bound edge stays in the gutter's shade.
		if lifted: shade = 0.90 + 0.10 * smoothstep(0.0, 0.12, u)
		for row in 2:
			vertices.append(Vector3(section[column].x, half if row == 0 else -half, section[column].y))
			uvs.append(Vector2(1.0 - u if mirrored else u, float(row)))
			colours.append(Color(shade, shade, shade))
		if column == 0: continue
		var base := column * 2
		# Clockwise seen from the reader, on either side of the spine.
		if mirrored: indices.append_array([base - 2, base - 1, base, base, base - 1, base + 1])
		else: indices.append_array([base - 2, base, base - 1, base, base + 1, base - 1])
	var arrays := []; arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices; arrays[Mesh.ARRAY_TEX_UV] = uvs; arrays[Mesh.ARRAY_COLOR] = colours; arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new(); mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh

## Debug A/B: the leaves' supersampled read against a plain trilinear one.
func set_sharp(on: bool) -> void:
	for sheet in [_left, _right, _leaf] + _riffle: sheet.material_override.set_shader_parameter("sharpened", on)

## Shows a bookmark tab over each open page that carries one.
func set_marked(left: bool, right: bool) -> void:
	if _tabs.size() == 2: _tabs[0].visible = left; _tabs[1].visible = right

func set_pages(left: Texture2D, right: Texture2D) -> void:
	_show(_left, "front", left)
	_show(_right, "front", right)

func _show(sheet: MeshInstance3D, face: String, texture: Texture2D) -> void:
	sheet.material_override.set_shader_parameter(face, texture)
	sheet.material_override.set_shader_parameter("has_" + face, texture != null)

## The turning leaf carries the page leaving the right side on its front and the page arriving on the
## left on its back. [amount] runs 0 (lying on the right) to 1 (lying on the left).
func set_leaf(front: Texture2D, back: Texture2D) -> void:
	_show(_leaf, "front", front); _show(_leaf, "back", back)

func turn(amount: float) -> void:
	if amount <= 0.0 or amount >= 1.0:
		leaf_side = 0
		_leaf.visible = false; _sparks.emitting = false
		for sheet in [_left, _right]: sheet.material_override.set_shader_parameter("shadow", 0.0)
		return
	var section := _bend(amount)
	_leaf.mesh = _ribbon(section, false, true)
	var tip := section[section.size() - 1]
	leaf_side = 1 if tip.x > 0.0 else -1
	_sparks.position = Vector3(tip.x, 0, tip.y)
	_sparks.emitting = true
	_leaf.material_override.set_shader_parameter("light", _rgb(light) * (1.0 - 0.06 * sin(PI * amount)))
	_leaf.visible = true
	# The leaf darkens the page it is leaving or landing on, just beyond its free edge.
	for sheet in [_left, _right]:
		var material: ShaderMaterial = sheet.material_override
		var under: bool = (sheet == _right) == (tip.x > 0.0)
		material.set_shader_parameter("shadow", sin(PI * amount) * 0.9 if under else 0.0)
		material.set_shader_parameter("edge", tip.x if absf(tip.x) > 0.001 else 0.001)
		material.set_shader_parameter("lift", maxf(tip.y, 0.0))

## The cross-section of a leaf [amount] of the way over, from the spine out to its free edge.
func _bend(amount: float) -> PackedVector2Array:
	# The free edge leads and the bound edge follows, so the leaf bows over instead of swinging flat.
	var outer := PI * smoothstep(0.0, 1.0, minf(1.0, amount * 1.32))
	var inner := PI * smoothstep(0.0, 1.0, maxf(0.0, (amount - 0.24) / 0.76))
	var section := PackedVector2Array()
	var point := Vector2(0, _dip(0.0) * (1.0 - sin(PI * amount)) + 0.0006)
	var step := page_size.x / COLUMNS
	section.append(point)
	for column in COLUMNS:
		var along := (column + 0.5) / COLUMNS
		var angle := lerpf(inner, outer, pow(along, 0.8))
		point += Vector2(cos(angle), sin(angle)) * step
		# Resting leaves follow the dip of the gutter; a lifted one straightens out of it.
		section.append(Vector2(point.x, maxf(point.y, _dip(absf(point.x)) + 0.0006)))
	if turn_style != CURL:
		# The same sweep pressed flat: the leaf folds over close to the pages instead of standing up.
		for i in section.size():
			var rest := _dip(absf(section[i].x)) + 0.0006
			section[i].y = rest + maxf(section[i].y - rest, 0.0) * LOW_RISE
	return section

## Blank leaves fluttering across while the book falls open at a distant page: [phase] runs 0..1.
func riffle(phase: float, direction: int) -> void:
	for i in _riffle.size():
		var amount := clampf(phase * 1.7 - i * 0.35, 0.0, 1.0)
		if direction < 0: amount = 1.0 - amount
		var flutter := _riffle[i]
		# A leaf lying almost flat would hide the page under it: it shows only once it is clearly in the air.
		flutter.visible = amount > 0.05 and amount < 0.95 and phase < 1.0
		if flutter.visible:
			# Each leaf rides a little above the last so they never cut through one another.
			var section := _bend(amount)
			for point in section.size(): section[point].y += 0.0008 * (i + 1) * sin(PI * amount)
			flutter.mesh = _ribbon(section, false, true)

## The first fluttering leaf carries the page that was open; the last brings the page it opens at.
## A leaf shows its front lying on the right and its back lying on the left.
func set_riffle(direction: int, leaving: Texture2D, arriving: Texture2D) -> void:
	for i in _riffle.size():
		var first := i == 0; var last := i == _riffle.size() - 1
		_show(_riffle[i], "front", (leaving if first else null) if direction > 0 else (arriving if last else null))
		_show(_riffle[i], "back", (arriving if last else null) if direction > 0 else (leaving if first else null))

## Paper rustle: a short burst of crackling band-limited noise, made once and pitched per turn.
static func rustle() -> AudioStreamWAV:
	var rate := 22050
	var length := int(rate * 0.42)
	var data := PackedByteArray(); data.resize(length * 2)
	var random := RandomNumberGenerator.new(); random.seed = 7
	var low := 0.0; var slow := 0.0; var crackle := 1.0
	for i in length:
		var t := float(i) / rate
		low = lerpf(low, random.randf_range(-1.0, 1.0), 0.45)
		slow = lerpf(slow, low, 0.04)
		if i % 90 == 0: crackle = random.randf_range(0.35, 1.0)
		var envelope := smoothstep(0.0, 0.05, t) * exp(-maxf(t - 0.07, 0.0) * 9.0)
		var value := clampf((low - slow) * crackle * envelope * 1.6, -1.0, 1.0)
		data.encode_s16(i * 2, int(value * 32000.0))
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS; stream.mix_rate = rate; stream.stereo = false; stream.data = data
	return stream

func sound(pitch: float, loud: float = 0.0) -> void:
	if quiet: return
	_sound.pitch_scale = pitch; _sound.volume_db = -8.0 + loud
	_sound.play()

## A spray of light off the new page, for the first page of a chapter.
func flare() -> void:
	_sparks.position = Vector3(page_size.x * 0.5, 0, 0.01)
	_sparks.restart(); _sparks.emitting = true

## Where a ray meets the open pages: {"side": -1 | 1, "uv": Vector2} or empty. [margin] widens the
## pages for gestures that may stray a little past their edges.
func hit(origin: Vector3, direction: Vector3, margin: float = 1.0) -> Dictionary:
	var inverse := global_transform.affine_inverse()
	var start: Vector3 = inverse * origin
	var ray: Vector3 = inverse.basis * direction
	if ray.z >= -0.00001 or start.z <= 0: return {}
	var point: Vector3 = start + ray * (-start.z / ray.z)
	if absf(point.x) > page_size.x * margin or absf(point.y) > page_size.y * 0.5 * margin: return {}
	var side := -1 if point.x < 0 else 1
	return {"side": side, "uv": Vector2(point.x / page_size.x + 1.0 if side < 0 else point.x / page_size.x, 0.5 - point.y / page_size.y),
		"distance": start.distance_to(point), "point": global_transform * point}
