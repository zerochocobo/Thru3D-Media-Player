extends Node3D
## Holographic wrist watch: time, battery and playback progress on the left wrist. Touching the
## face projects a flickering cone of light along the face normal; on top of it a control disc
## parallel to the face carries the timeline ring and the playback keys. Interaction rules live
## in wrist_watch_logic.gd.

const Logic := preload("res://scripts/wrist_watch_logic.gd")
const Menu := preload("res://scripts/ray_menu.gd")
const Icons := preload("res://scripts/menu_icons.gd")
const Methods := preload("res://scripts/platform_methods.gd")
const SHADER := preload("res://shaders/wrist_watch.gdshader")
enum Kind { FACE, RING, BUTTON, GUIDE, CONE, CURSOR, PLATE, TAG }

const FACE_SIZE := 0.05
const RING_WIDTH := 0.02
const GUIDE_WIDTH := 0.005
const PLATE_RADIUS := 0.098
const UNDER_LAYER := 0.014
const CURSOR_SIZE := 0.022
const TAG_SIZE := Vector2(0.05, 0.017)
const READOUT_LIFT := 0.03
const TEXT := Color(0.93, 0.98, 1.0)
const DIM := Color(0.62, 0.78, 0.82)
const GLOW := Color(0.54, 0.93, 0.77, 0.22)
const POLL_MS := 2000
const ICONS := {"rewind": "back", "play": "pause", "forward": "forward", "menu": "menu"}

var logic := Logic.new()
## -> {"level": 0..100 or -1, "charging", "clock24"}; tests inject one.
var status_provider: Callable
## -> {"hour", "minute"}; tests pin the clock.
var clock_provider: Callable = Time.get_time_dict_from_system
var face_reveal := 0.0
var expand := 0.0

var _status := {}
var _polled_ms := -POLL_MS
var _face_root: Node3D
var _face: MeshInstance3D
var _clock: Label3D
var _remaining: Label3D
var _state_icon: MeshInstance3D
var _holo_root: Node3D
var _cone: MeshInstance3D
var _core: MeshInstance3D
var _plate: MeshInstance3D
var _under: MeshInstance3D
var _ring: MeshInstance3D
var _guides: Array[MeshInstance3D] = []
var _buttons := {}
var _readout_root: Node3D
var _readout: Label3D
var _detail: Label3D
var _tag_root: Node3D
var _tag: MeshInstance3D
var _tag_label: Label3D
var _cursor: MeshInstance3D
var _up := Vector3.UP
var _marks_key := ""

func _ready() -> void:
	if not status_provider.is_valid() and Engine.has_singleton("QuestPlayer"):
		var plugin := Engine.get_singleton("QuestPlayer")
		if Methods.supports(plugin, "device_status"):
			status_provider = func() -> Dictionary:
				var parsed: Variant = JSON.parse_string(str(plugin.device_status()))
				return parsed if parsed is Dictionary else {}
	_face_root = _root("WatchFace")
	_face = _quad(_face_root, Vector2.ONE * FACE_SIZE, Kind.FACE, 30)
	_clock = _label(_face_root, 84, 0.000105, 33, true)
	_clock.position = Vector3(0, 0.0015, 0.0006)
	_remaining = _label(_face_root, 40, 0.000105, 33, false)
	_remaining.position = Vector3(0, -0.0068, 0.0006)
	_remaining.modulate = DIM
	_state_icon = _icon(_face_root, "pause", 0.0062, 33)
	_state_icon.position = Vector3(0, 0.0094, 0.0006)
	_holo_root = _root("WatchProjection")
	_cone = _cone_mesh(PLATE_RADIUS * 0.8, 0.016, 0.0, 27)
	_core = _cone_mesh(0.016, 0.005, 1.0, 26)
	_under = _quad(_holo_root, Vector2.ONE * PLATE_RADIUS * 2.0, Kind.PLATE, 28)
	_under.position.z = -UNDER_LAYER
	_under.material_override.set_shader_parameter("seed", 1.0)
	_plate = _quad(_holo_root, Vector2.ONE * PLATE_RADIUS * 2.0, Kind.PLATE, 29)
	_ring = _annulus(Logic.PROGRESS_RING, RING_WIDTH, Kind.RING, 30)
	_ring.material_override.set_shader_parameter("seed", 0.37)
	for offset in [Logic.MEDIUM_ZONE, Logic.FINE_ZONE]:
		_guides.append(_annulus(Logic.PROGRESS_RING + offset, GUIDE_WIDTH, Kind.GUIDE, 30))
	for index in Logic.BUTTONS.size():
		var id: String = Logic.BUTTONS[index]
		var holder := Node3D.new()
		_holo_root.add_child(holder)
		var radius := Logic.button_radius(id)
		var disc := _quad(holder, Vector2.ONE * radius * 2.0 / 0.72, Kind.BUTTON, 31)
		disc.material_override.set_shader_parameter("seed", index * 0.21)
		var glyph := _icon(holder, ICONS[id], radius * (1.0 if id == "play" else 0.95), 32)
		glyph.position.z = 0.0008
		_buttons[id] = {"holder": holder, "disc": disc, "icon": glyph, "scale": 0.0, "icon_key": ICONS[id]}
	# Readouts stand up out of the disc and turn to the viewer, like figures in a projector beam.
	_readout_root = Node3D.new()
	_holo_root.add_child(_readout_root)
	_readout = _label(_readout_root, 72, 0.00015, 33, true)
	_readout.position = Vector3(0, 0.004, 0)
	_detail = _label(_readout_root, 40, 0.00015, 33, false)
	_detail.position = Vector3(0, -0.0085, 0)
	_detail.modulate = DIM
	_tag_root = Node3D.new()
	_holo_root.add_child(_tag_root)
	_tag = _quad(_tag_root, TAG_SIZE, Kind.TAG, 35)
	_tag.material_override.set_shader_parameter("size_m", TAG_SIZE)
	_tag_label = _label(_tag_root, 52, 0.00015, 36, true)
	_tag_label.position.z = 0.0006
	_cursor = _quad(_holo_root, Vector2.ONE * CURSOR_SIZE, Kind.CURSOR, 34)
	visible = false

## frame as in Logic.update. Returns the logic actions for the owner to apply.
func step(frame: Dictionary, delta: float) -> Array[Dictionary]:
	var actions := logic.update(frame, delta)
	var head: Transform3D = frame.get("head", Transform3D.IDENTITY)
	var showing := logic.phase != Logic.Phase.HIDDEN
	face_reveal = move_toward(face_reveal, 1.0 if showing and logic.face_valid else 0.0, delta / (0.38 if showing else 0.2))
	expand = move_toward(expand, 1.0 if logic.expanded() else 0.0, delta / (0.6 if logic.expanded() else 0.2))
	visible = face_reveal > 0.0 or expand > 0.0
	if visible: _present(head, delta)
	return actions

func owns_tip() -> bool:
	return visible and logic.owns_tip()

func _present(head: Transform3D, delta: float) -> void:
	_poll_status()
	var media := logic.media
	var progress := logic.progress()
	var playing := bool(media.get("playing", false))
	_update_marks(media)
	_present_face(head, delta, media, playing)
	_holo_root.visible = expand > 0.0
	if not _holo_root.visible: return
	_holo_root.global_transform = logic.holo
	# Sequence: the beam rises, the disc grows out of it, then the ring and the keys arrive.
	var beam := clampf(expand / 0.35, 0.0, 1.0)
	var disc := clampf((expand - 0.2) / 0.4, 0.0, 1.0)
	var ring := clampf((expand - 0.35) / 0.5, 0.0, 1.0)
	_present_cone(beam)
	_set_params(_plate, {"reveal": _ease_out(disc)})
	_set_params(_under, {"reveal": _ease_out(clampf(disc * 1.2 - 0.2, 0.0, 1.0))})
	var dragging := not logic.scrub.is_empty()
	var ghost := -1.0
	if dragging and float(media.get("duration_ms", 0)) > 0:
		ghost = float(logic.scrub.start) / float(media.duration_ms)
	_set_params(_ring, {"reveal": _ease_out(ring), "progress": progress, "ghost": ghost,
		"hover": 1.0 if logic.hover == "progress" else 0.0, "active": 1.0 if dragging else 0.0})
	for index in _guides.size():
		var material := _guides[index].material_override as ShaderMaterial
		var shown := dragging
		var current := float(material.get_shader_parameter("reveal"))
		material.set_shader_parameter("reveal", move_toward(current, 1.0 if shown else 0.0, delta / 0.25))
		material.set_shader_parameter("active", 1.0 if shown and int(logic.level) > index else 0.0)
	_present_buttons(delta, clampf((expand - 0.3) / 0.7, 0.0, 1.0))
	_present_readout(head, media, dragging, ring)
	_present_cursor(disc)

func _present_face(head: Transform3D, delta: float, media: Dictionary, playing: bool) -> void:
	_face_root.visible = face_reveal > 0.0 and logic.face_valid
	if not _face_root.visible: return
	# On the wrist, its dial turned so text stays upright for the viewer.
	var normal := logic.face.basis.y.normalized()
	var wanted := head.basis.y - normal * head.basis.y.dot(normal)
	if wanted.length_squared() > 0.0001: _up = _up.slerp(wanted.normalized(), clampf(delta * 12.0, 0.0, 1.0)).normalized()
	var up := (_up - normal * _up.dot(normal)).normalized()
	_face_root.global_transform = Transform3D(Basis(up.cross(normal).normalized(), up, normal), logic.face.origin)
	var level := int(_status.get("level", -1))
	_set_params(_face, {"reveal": face_reveal, "progress": _media_progress(), "playing": 1.0 if playing else 0.0,
		"hover": logic.charge, "ripple": float(logic.ripples.get("face", 10.0)),
		"battery": level / 100.0 if level >= 0 else -1.0, "emit": maxf(expand, logic.charge * 0.6)})
	_set_text(_clock, _clock_text())
	var duration := int(media.get("duration_ms", 0))
	_set_text(_remaining, "-" + _time(duration - int(media.get("position_ms", 0))) if duration > 0 else "")
	# The time stays readable on the face while it projects.
	var text_fade := clampf(face_reveal * 1.6 - 0.6, 0.0, 1.0)
	_clock.modulate.a = text_fade; _remaining.modulate.a = text_fade * 0.9
	_clock.outline_modulate.a = GLOW.a * text_fade; _remaining.outline_modulate.a = GLOW.a * text_fade
	# Only an interruption is worth a glyph; a running video needs none.
	_state_icon.visible = not playing
	(_state_icon.material_override as StandardMaterial3D).albedo_color = Color(TEXT, text_fade * 0.85)

func _present_cone(beam: float) -> void:
	_cone.visible = beam > 0.0 and logic.face_valid
	_core.visible = _cone.visible
	if not _cone.visible: return
	# Both ends ride on the wrist, so the beam keeps its shape.
	var apex := logic.holo.affine_inverse() * logic.face.origin
	_set_params(_cone, {"reveal": _ease_out(beam), "apex": apex})
	_set_params(_core, {"reveal": _ease_out(clampf(beam * 1.4, 0.0, 1.0)), "apex": apex})

func _present_buttons(delta: float, keys: float) -> void:
	var depth := logic.tip_local.z
	for index in Logic.BUTTONS.size():
		var id: String = Logic.BUTTONS[index]
		var entry: Dictionary = _buttons[id]
		# The centre key lands first, then the outer ones in turn.
		var order := index
		var t := clampf(keys * 1.6 - order * 0.12, 0.0, 1.0)
		var hovered := logic.hover == id
		var target := _ease_back(t) * (1.12 if hovered else 1.0)
		entry.scale = lerpf(float(entry.scale), target, clampf(delta * 18.0, 0.0, 1.0)) if t >= 1.0 else _ease_back(t)
		var holder: Node3D = entry.holder
		var pos := Logic.button_position(id)
		# Keys rise out of the disc as they arrive and sink a little when pressed.
		holder.position = Vector3(pos.x, pos.y, (1.0 - t) * -0.02 + (-0.004 if logic.pressed == id else 0.0))
		holder.scale = Vector3.ONE * maxf(0.001, float(entry.scale))
		var enabled := logic.button_enabled(id)
		var approach := 0.0
		if hovered and logic.tip_valid: approach = logic.approach()
		_set_params(entry.disc, {"reveal": t, "hover": 1.0 if hovered and enabled else 0.0, "approach": approach,
			"ripple": float(logic.ripples.get(id, 10.0)), "enabled": 1.0 if enabled else 0.0,
			"active": 1.0 if logic.pressed == id else 0.0})
		var key := ("pause" if bool(logic.media.get("playing", false)) else "play") if id == "play" else str(entry.icon_key)
		_set_icon(entry.icon, key)
		var tone := TEXT if enabled else DIM
		(entry.icon.material_override as StandardMaterial3D).albedo_color = Color(tone, t * (1.0 if enabled else 0.35))

func _present_readout(head: Transform3D, media: Dictionary, dragging: bool, ring: float) -> void:
	var fade := clampf(ring * 1.5 - 0.5, 0.0, 1.0)
	var duration := int(media.get("duration_ms", 0))
	if dragging:
		var delta_ms := int(logic.scrub_value()) - int(float(logic.scrub.start))
		_set_text(_readout, ("+" if delta_ms >= 0 else "-") + _time(absi(delta_ms)))
		_set_text(_detail, "")
	else:
		_set_text(_readout, _time(int(media.get("position_ms", 0))) if duration > 0 else "")
		# A run of skips shows how far it has moved.
		var skipping := minf(float(logic.ripples.get("rewind", 10.0)), float(logic.ripples.get("forward", 10.0))) < 1.2
		var jumped := ("+" if logic.skip_total >= 0 else "-") + "%ds" % absi(logic.skip_total)
		_set_text(_detail, jumped if skipping else (_time(duration) if duration > 0 else ""))
	# A panel standing beyond the far rim, turned to the eyes.
	var far := Vector3(0, Logic.PROGRESS_RING + RING_WIDTH * 0.5 + 0.022, READOUT_LIFT)
	_billboard(_readout_root, logic.holo * far, head)
	_readout.modulate.a = fade; _detail.modulate.a = fade * 0.9
	_readout.outline_modulate.a = GLOW.a * fade; _detail.outline_modulate.a = GLOW.a * fade
	# A tag stands on the scrub head so the target time is where the finger is.
	_tag_root.visible = dragging
	if dragging:
		var head_point := Logic.arc_point(logic.progress())
		var spot := Vector3(head_point.x, head_point.y, 0.026)
		_billboard(_tag_root, logic.holo * spot, head)
		_set_text(_tag_label, _time(int(logic.scrub_value())))
		_set_params(_tag, {"reveal": fade})

func _present_cursor(disc: float) -> void:
	var local := logic.tip_local
	var near := logic.tip_valid and local.z < 0.08 and local.z > -0.03 and Vector2(local.x, local.y).length() < Logic.PROGRESS_RING + Logic.FINE_ZONE + 0.03
	if not near:
		_cursor.visible = false; return
	# The landing marker snaps onto the key or arc that will take the touch, and closes in as the
	# finger nears the trigger depth, so nothing has to be covered to be aimed at.
	var landing := logic.landing()
	var target := Vector3(landing.x, landing.y, 0.0035)
	_cursor.position = _cursor.position.lerp(target, 0.5) if _cursor.visible else target
	var pressing := not logic.pressed.is_empty() or not logic.scrub.is_empty()
	_set_params(_cursor, {"reveal": disc, "approach": 1.0 if pressing else logic.approach()})

func _billboard(node: Node3D, world: Vector3, head: Transform3D) -> void:
	var toward := head.origin - world
	if toward.length_squared() < 0.0001: return
	var z := toward.normalized()
	var x := Vector3.UP.cross(z)
	if x.length_squared() < 0.0001: x = head.basis.x
	x = x.normalized()
	node.global_transform = Transform3D(Basis(x, z.cross(x).normalized(), z), world)

func _media_progress() -> float:
	var duration := float(logic.media.get("duration_ms", 0))
	return clampf(float(logic.media.get("position_ms", 0)) / duration, 0.0, 1.0) if duration > 0 else 0.0

func _update_marks(media: Dictionary) -> void:
	var duration := float(media.get("duration_ms", 0))
	var values := PackedFloat32Array()
	if duration > 0:
		for row in media.get("bookmarks", []):
			var at := float(row.get("position_ms", -1)) if row is Dictionary else float(row)
			if at >= 0 and values.size() < 16: values.append(clampf(at / duration, 0.0, 1.0))
	var key := str(values)
	if key == _marks_key: return
	_marks_key = key
	var count := values.size()
	values.resize(16)
	for target in [_ring.material_override, _face.material_override]:
		target.set_shader_parameter("marks", values)
		target.set_shader_parameter("mark_count", count)

func _poll_status() -> void:
	var now := Time.get_ticks_msec()
	if now - _polled_ms < POLL_MS: return
	_polled_ms = now
	_status = status_provider.call() if status_provider.is_valid() else {}

func _clock_text() -> String:
	var now: Dictionary = clock_provider.call()
	var hour := int(now.get("hour", 0))
	var minute := int(now.get("minute", 0))
	if bool(_status.get("clock24", true)): return "%02d:%02d" % [hour, minute]
	return "%d:%02d" % [12 if hour % 12 == 0 else hour % 12, minute]

static func _time(ms: int) -> String:
	var seconds := maxi(0, ms) / 1000
	if seconds >= 3600: return "%d:%02d:%02d" % [seconds / 3600, seconds / 60 % 60, seconds % 60]
	return "%d:%02d" % [seconds / 60, seconds % 60]

static func _ease_out(t: float) -> float:
	return 1.0 - pow(1.0 - clampf(t, 0.0, 1.0), 3.0)

static func _ease_back(t: float) -> float:
	t = clampf(t, 0.0, 1.0)
	var c := 1.70158
	return 1.0 + (c + 1.0) * pow(t - 1.0, 3.0) + c * pow(t - 1.0, 2.0)

func _set_text(label: Label3D, text: String) -> void:
	if label.text != text: label.text = text

func _set_icon(node: MeshInstance3D, key: String) -> void:
	if node.get_meta("icon", "") == key: return
	node.set_meta("icon", key)
	(node.material_override as StandardMaterial3D).albedo_texture = Icons.texture(key)

func _set_params(node: MeshInstance3D, values: Dictionary) -> void:
	var material := node.material_override as ShaderMaterial
	for key in values: material.set_shader_parameter(key, values[key])

func _root(title: String) -> Node3D:
	var node := Node3D.new()
	node.name = title
	node.top_level = true
	add_child(node)
	return node

func _material(kind: Kind, priority: int) -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = SHADER
	material.render_priority = priority
	material.set_shader_parameter("kind", kind)
	return material

func _quad(parent: Node3D, size: Vector2, kind: Kind, priority: int) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	var mesh := QuadMesh.new()
	mesh.size = size
	node.mesh = mesh
	node.material_override = _material(kind, priority)
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(node)
	return node

func _surface(arrays: Array, primitive: Mesh.PrimitiveType, kind: Kind, priority: int) -> MeshInstance3D:
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(primitive, arrays)
	var node := MeshInstance3D.new()
	node.mesh = mesh
	node.material_override = _material(kind, priority)
	node.material_override.set_shader_parameter("reveal", 0.0)
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_holo_root.add_child(node)
	return node

## A flat arc along the timeline's sweep; UV.x runs from its start to its end, UV.y inner to outer.
func _annulus(radius: float, width: float, kind: Kind, priority: int) -> MeshInstance3D:
	var steps := 96
	var vertices := PackedVector3Array()
	var uvs := PackedVector2Array()
	for i in steps + 1:
		var u := float(i) / steps
		var angle := deg_to_rad(Logic.PROGRESS_START + Logic.PROGRESS_SPAN * 2.0 * u)
		var direction := Vector3(sin(angle), cos(angle), 0)
		vertices.append(direction * (radius - width * 0.5)); uvs.append(Vector2(u, 0))
		vertices.append(direction * (radius + width * 0.5)); uvs.append(Vector2(u, 1))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	return _surface(arrays, Mesh.PRIMITIVE_TRIANGLE_STRIP, kind, priority)

## A unit cone the shader bends from the live face up to the disc rim: VERTEX = (cos, sin, v).
func _cone_mesh(top_radius: float, bottom_radius: float, style: float, priority: int) -> MeshInstance3D:
	var around := 64
	var rows := 12
	var vertices := PackedVector3Array()
	var indices := PackedInt32Array()
	for row in rows + 1:
		for i in around + 1:
			var a := float(i) / around * TAU
			vertices.append(Vector3(sin(a), cos(a), float(row) / rows))
	for row in rows:
		for i in around:
			var a := row * (around + 1) + i
			var b := a + around + 1
			indices.append_array([a, b, a + 1, a + 1, b, b + 1])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_INDEX] = indices
	var node := _surface(arrays, Mesh.PRIMITIVE_TRIANGLES, Kind.CONE, priority)
	_set_params(node, {"base_radius": top_radius, "apex_radius": bottom_radius, "seed": style})
	# The shader moves vertices well outside the unit mesh.
	node.custom_aabb = AABB(Vector3(-0.5, -0.5, -0.5), Vector3.ONE)
	return node

func _label(parent: Node3D, font_size: int, pixel: float, priority: int, bold: bool) -> Label3D:
	var label := Label3D.new()
	label.font = Menu.ui_bold_font() if bold else Menu.ui_font()
	label.font_size = font_size
	label.pixel_size = pixel
	label.outline_size = 10
	label.outline_modulate = GLOW
	label.modulate = TEXT
	label.render_priority = priority
	label.outline_render_priority = priority - 1
	label.double_sided = false
	label.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	parent.add_child(label)
	return label

func _icon(parent: Node3D, key: String, size: float, priority: int) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	var mesh := QuadMesh.new()
	mesh.size = Vector2.ONE * size
	node.mesh = mesh
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.render_priority = priority
	material.albedo_texture = Icons.texture(key)
	node.material_override = material
	node.set_meta("icon", key)
	parent.add_child(node)
	return node
