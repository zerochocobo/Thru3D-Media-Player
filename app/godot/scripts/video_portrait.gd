extends RefCounted
## Single visible surface, borrowing the current video's frame lease. Camera calibration is
## captured on entry; head motion must never recalibrate the source rays.
const GRID := 96
const MIN_DISTANCE := 1.2
const MAX_DISTANCE := 6.0
const CUT_STEP := 0.3 # inverse metres; prototype comfort limit, pending headset validation.
const SLEW := 0.12
var material := ShaderMaterial.new()
var mesh: ArrayMesh
var active := false
var automatic := false # Keep the source screen's distance unless the user opts into size anchoring.
var enhanced := false # Explicit opt-in while combined headset/thermal measurements are pending.
var enhancement: Dictionary = {}
var strength := 1.0
var reference := Vector3.ZERO
var distance := 2.0
var target := 2.0
var _aspect := 0.0
var _frame := -1
var _pts := -1
var _advance_pts := -1
var _bounds := Rect2()
var _candidate := ""
var _stable := 0
var _cut_pending := false
var _shot := -1
var _shot_frame := -1
var classification := "unknown"
var fallback := ""

func reset() -> void:
	active = false; reference = Vector3.ZERO; _frame = -1; _pts = -1; _advance_pts = -1
	_bounds = Rect2(); _candidate = ""; _stable = 0; _cut_pending = false; classification = "unknown"
	fallback = ""
	enhancement = {}
	_shot = -1; _shot_frame = -1

func calibrate(eye: Vector3) -> void:
	reset()
	if not eye.is_finite() or eye.z < 0.15: return
	reference = eye
	distance = clampf(eye.z, MIN_DISTANCE, MAX_DISTANCE) if automatic else eye.z
	target = distance

static func scene(bounds: Rect2, subjects: int, cropped: bool) -> String:
	if subjects != 1 or cropped or bounds.size.y < 0.18 or bounds.size.x < 0.03: return "unknown"
	var top := bounds.position.y <= 0.035
	var bottom := bounds.end.y >= 0.965
	if bounds.position.x <= 0.035 or bounds.end.x >= 0.965: return "unknown"
	if top: return "close" if bottom else "unknown"
	return "half" if bottom else "full"

static func oriented_bounds(values: Array, rotation: int) -> Rect2:
	if values.size() != 4: return Rect2()
	var result := Rect2()
	var first := true
	for u in [float(values[0]), float(values[2])]:
		for v in [float(values[1]), float(values[3])]:
			var p := Vector2(u, v)
			match rotation:
				90: p = Vector2(1.0-v, u)
				180: p = Vector2(1.0-u, 1.0-v)
				270: p = Vector2(v, 1.0-u)
			if not p.is_finite(): return Rect2()
			if first: result = Rect2(p, Vector2.ZERO); first = false
			else: result = result.expand(p)
	return result

func observe(pair: Dictionary, size: Vector2) -> void:
	if not automatic or reference.z <= 0.0: return
	var observation: Dictionary = pair.get("portrait_observation", {})
	var frame := int(pair.get("frame_id", -1))
	var pts := int(pair.get("pts_us", -1))
	var shot := int(pair.get("portrait_shot_id", -1))
	if shot >= 0 and shot != _shot:
		_shot = shot; _shot_frame = frame; _cut_pending = true
		_candidate = ""; _stable = 0; target = distance; _advance_pts = pts
		classification = "unknown" # Even a missing observation must stop the previous shot's slew.
	if observation.is_empty() or frame == _frame or int(observation.get("frame_id", -2)) != frame \
		or int(observation.get("pts_us", -2)) != pts: return
	var bounds := oriented_bounds(observation.get("bounds", []), int(pair.get("rotation_degrees", 0)))
	var kind := scene(bounds, int(observation.get("subjects", 0)), bool(observation.get("cropped", false)))
	# Shot IDs come from full-frame colour, not person position. Legacy/no-ID input retains
	# timeline invalidation only; a walking person must not be mistaken for a camera cut.
	var cut := _pts < 0 or pts < _pts or pts - _pts > 1000000
	_cut_pending = _cut_pending or cut
	if shot >= 0 and frame != _shot_frame: _cut_pending = false # Later confidence uses in-shot slew, not a delayed cut jump.
	_frame = frame; _pts = pts; _bounds = bounds
	_stable = _stable + 1 if kind == _candidate else 1
	_candidate = kind; classification = kind
	if not kind in ["full", "half"]: target = distance; return
	# Require two observations before assigning a size prior. Unknown/close/multiple subjects hold.
	if _stable < 2 and frame != _shot_frame: target = distance; return
	var prior := 1.7 if kind == "full" else 0.9
	target = clampf(prior * reference.z / maxf(0.01, bounds.size.y * size.y), MIN_DISTANCE, MAX_DISTANCE)
	if _cut_pending:
		distance = 1.0 / move_toward(1.0 / distance, 1.0 / target, CUT_STEP)
		_cut_pending = false
		_advance_pts = pts # No extra slew on the frame that applied the bounded jump.

func advance(pts: int) -> void:
	var dt := clampf(float(pts - _advance_pts) / 1000000.0, 0.0, 0.1) if _advance_pts >= 0 else 0.0
	_advance_pts = pts
	# Use presentation timestamps, so pauses and repeated XR draws cannot drift the anchor.
	if automatic and _pts >= 0 and pts >= _pts and pts-_pts <= 1000000:
		distance = 1.0 / move_toward(1.0 / distance, 1.0 / target, SLEW * dt)

static func point(uv: Vector2, eye: Vector3, size: Vector2, depth: float) -> Vector3:
	var p := (uv - Vector2(0.5, 0.5)) * size * Vector2(1, -1)
	p = Vector2(eye.x, eye.y) + (p - Vector2(eye.x, eye.y)) * depth / eye.z
	return Vector3(p.x, p.y, eye.z - depth)

func geometry(size: Vector2) -> ArrayMesh:
	var aspect := size.x / maxf(0.01, size.y)
	if mesh and is_equal_approx(aspect, _aspect): return mesh
	_aspect = aspect
	var cols := GRID if aspect >= 1.0 else maxi(8, roundi(GRID * aspect))
	var rows := GRID if aspect < 1.0 else maxi(8, roundi(GRID / aspect))
	var vertices := PackedVector3Array()
	var uv := PackedVector2Array()
	var indices := PackedInt32Array()
	for y in rows + 1:
		for x in cols + 1:
			var p := Vector2(float(x) / cols, float(y) / rows)
			uv.append(p); vertices.append(Vector3(p.x - 0.5, 0.5 - p.y, 0.0))
	for y in rows:
		for x in cols:
			var a := y * (cols + 1) + x
			indices.append_array([a, a+cols+2, a+1, a, a+cols+1, a+cols+2])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices; arrays[Mesh.ARRAY_TEX_UV] = uv; arrays[Mesh.ARRAY_INDEX] = indices
	mesh = ArrayMesh.new(); mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh

func update(binding: RefCounted, panel: MeshInstance3D, size: Vector2, eye: Vector3) -> bool:
	if reference.z <= 0.0: calibrate(eye)
	if reference.z <= 0.0: active = false; return false
	observe(binding.ticket, size)
	enhancement = binding.ticket.get("portrait_depth", {}).duplicate(true)
	advance(int(binding.ticket.get("pts_us", 0)))
	binding.share_with(material, {}, true)
	material.render_priority = -10
	material.set_shader_parameter("portrait_size", size)
	material.set_shader_parameter("portrait_reference", reference)
	material.set_shader_parameter("portrait_distance", distance)
	var relief := minf(0.18, minf(distance * 0.08, size.y * distance / reference.z * 0.12)) * strength
	material.set_shader_parameter("portrait_relief", relief)
	panel.mesh = geometry(size)
	# GPU displacement must not be culled using the original unit plane's bounds.
	var bounds := AABB(point(Vector2.ZERO, reference, size, MIN_DISTANCE-0.36), Vector3.ZERO)
	for d in [MIN_DISTANCE-0.36, MAX_DISTANCE, distance, maxf(0.8, distance-relief*1.5)]:
		for uv in [Vector2.ZERO, Vector2.ONE, Vector2(0,1), Vector2(1,0)]:
			bounds = bounds.expand(point(uv, reference, size, d))
	panel.custom_aabb = bounds.grow(0.05)
	panel.material_override = material
	active = true
	fallback = ""
	return true

func snapshot() -> Dictionary:
	return {"requested": true, "active": active, "automatic": automatic, "strength": strength,
		"enhanced_requested": enhanced, "enhancement": enhancement,
		"distance_m": distance, "target_m": target, "classification": classification,
		"source_layout": "mono", "presentation": "portrait_mesh" if active else "portrait_flat",
		"reference": [reference.x, reference.y, reference.z], "grid": GRID, "fallback": fallback, "device_validation": "pending"}
