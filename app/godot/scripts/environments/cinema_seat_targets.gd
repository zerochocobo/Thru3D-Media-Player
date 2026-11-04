extends RefCounted
## Selection volumes are separate from body colliders. Query only the descending
## arc, then choose its closest chair centre, not the first chair it brushes past.

const CELL := 2.0
const ASSIST := 0.12
const HOLD_EXTRA := 0.06
# Squared-distance score tolerance: a small boundary crossing, never a full seat.
const HOLD_SCORE := 0.06
const HOLD_MS := 120
const MARKER_LIFT := 0.025
const CUSHION_HEIGHT := 0.47

var _targets: Dictionary = {}
var _hash: Dictionary = {}

func configure(seats: Dictionary, design: Dictionary) -> void:
	_targets.clear(); _hash.clear()
	var half := float(design.get("seat_pitch", .9)) * .5
	var front := float(design.get("seat_front", .42))
	var rear := float(design.get("seat_rear", .38))
	var top := float(design.get("seat_back_top", 1.16))
	for id in seats:
		var value: Variant = seats[id].eye_position
		var eye := Vector3(float(value[0]), float(value[1]), float(value[2]))
		if not eye.is_finite(): continue
		var floor_y := eye.y - float(design.get("seated_eye_height", 1.2))
		var line := eye.z + float(design.get("seat_line_from_eye", .1))
		var cushion := Vector3(eye.x, floor_y + CUSHION_HEIGHT, line - .05)
		var back := Vector3(eye.x, floor_y + .9, line + (rear + .1) * .5)
		var zones: Array[AABB] = [
			AABB(Vector3(eye.x - half, floor_y + .32, line - front), Vector3(half * 2, .34, front + .12)),
			AABB(Vector3(eye.x - half, floor_y + .66, line + .1), Vector3(half * 2, maxf(.01, top - .66), rear - .1))]
		_targets[id] = {"zones": zones, "anchors": [cushion, back], "marker": cushion}
		var lo := _key(Vector3(eye.x - half - HOLD_EXTRA, 0, line - front - ASSIST - HOLD_EXTRA))
		var hi := _key(Vector3(eye.x + half + HOLD_EXTRA, 0, line + rear + ASSIST + HOLD_EXTRA))
		for x in range(lo.x, hi.x + 1):
			for z in range(lo.y, hi.y + 1):
				var key := Vector2i(x, z)
				if not _hash.has(key): _hash[key] = []
				_hash[key].append(id)

func marker(id: String) -> Vector3:
	return _targets[id].marker

func collect(start: Vector3, end: Vector3, point_count: int, candidates: Dictionary, held: String = "") -> void:
	if end.y >= start.y or start.distance_squared_to(end) < .000001: return
	var lo := _key(start.min(end)); var hi := _key(start.max(end))
	var seen := {}
	for x in range(lo.x, hi.x + 1):
		for z in range(lo.y, hi.y + 1):
			for id in _hash.get(Vector2i(x, z), []): seen[id] = true
	for id in seen:
		var target: Dictionary = _targets[id]
		for index in target.zones.size():
			var box: AABB = target.zones[index]
			var margin := Vector3(0, ASSIST, ASSIST)
			var normal := _interval(start, end, AABB(box.position - margin, box.size + margin * 2))
			var interval := normal
			if str(id) == held:
				interval = _interval(start, end, AABB(box.position - margin, box.size + margin * 2).grow(HOLD_EXTRA))
			if interval.x < 0: continue
			var anchor: Vector3 = target.anchors[index]
			var along := clampf((anchor - start).dot(end - start) / start.distance_squared_to(end), interval.x, interval.y)
			var point := start.lerp(end, along)
			var score := point.distance_squared_to(anchor)
			if candidates.has(id) and float(candidates[id].score) <= score: continue
			candidates[id] = {"id": str(id), "score": score, "point": point, "point_count": point_count,
				"hold_only": normal.x < 0}

func choose(candidates: Dictionary, held: String = "") -> Dictionary:
	var best := {}
	for candidate in candidates.values():
		if candidate.hold_only: continue
		if best.is_empty() or float(candidate.score) < float(best.score): best = candidate
	if candidates.has(held) and (best.is_empty() or float(candidates[held].score) <= float(best.score) + HOLD_SCORE):
		var retained: Dictionary = candidates[held].duplicate()
		retained["retained"] = best.get("id", "") != held or retained.hold_only
		return retained
	return best

static func _key(point: Vector3) -> Vector2i:
	return Vector2i(floori(point.x / CELL), floori(point.z / CELL))

static func _interval(start: Vector3, end: Vector3, box: AABB) -> Vector2:
	var near := 0.0; var far := 1.0
	var delta := end - start
	for axis in 3:
		if absf(delta[axis]) < .00001:
			if start[axis] < box.position[axis] or start[axis] > box.end[axis]: return Vector2(-1, -1)
			continue
		var a := (box.position[axis] - start[axis]) / delta[axis]
		var b := (box.end[axis] - start[axis]) / delta[axis]
		near = maxf(near, minf(a, b)); far = minf(far, maxf(a, b))
		if near > far: return Vector2(-1, -1)
	return Vector2(near, far)
