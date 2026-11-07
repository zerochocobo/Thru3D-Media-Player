extends "res://scripts/environments/cinema_locomotion.gd"
## Reuse auditorium movement, body clearance, snap turning and connectivity.
## Only the floor query and beach arc intersections differ from the auditorium.
const Terrain := preload("res://scripts/environments/private_beach_navigation.gd")
var terrain: RefCounted

static func valid_view_record(view: Dictionary) -> bool:
	if view.get("schema",0)!=1 or view.get("mode","") not in ["watch","move"]: return false
	for key in ["x","z","yaw","eye_height"]:
		if not view.get(key) is float and not view.get(key) is int: return false
		if not is_finite(float(view[key])): return false
	return float(view.eye_height)>=.3 and float(view.eye_height)<=2.5

func restore_view(view: Dictionary) -> bool:
	# A saved start need not be reachable from the authored default start, which
	# may now be occupied by the saved screen. Validate against THIS layout.
	if not valid_view_record(view): return false
	var point := Vector3(float(view.x),terrain.ground(float(view.x),float(view.z)),float(view.z))
	var floor := _standing_at(point,.04)
	if not floor.is_finite(): return false
	if _body_blocked(floor,floor.y+.03,floor.y+maxf(EYE_HEIGHT,float(view.eye_height))+HEAD_CLEARANCE): return false
	eye_position=floor+Vector3.UP*float(view.eye_height); yaw=wrapf(float(view.yaw),-PI,PI)
	mode=Mode.MOVE if view.mode=="move" else Mode.WATCH
	selected_seat=""; _has_position=true; suspend()
	return true

func adopt_view(previous: RefCounted,seated := false) -> bool:
	# Called only after a replacement navigation graph is complete. Preserve the
	# latest user position and mode; a screen edit must never teleport the viewer.
	# A lounger holds a seated viewer inside its own collider, so only standing is checked.
	var eye: Vector3 = previous.eye_position
	var floor := Vector3(eye.x,terrain.ground(eye.x,eye.z),eye.z)
	if not seated:
		if not _standing_at(floor,MAX_STEP_HEIGHT).is_finite(): return false
		if _body_blocked(floor,floor.y+.03,maxf(eye.y,floor.y+EYE_HEIGHT)+HEAD_CLEARANCE): return false
	eye_position=eye; yaw=previous.yaw; mode=previous.mode
	selected_seat=previous.selected_seat; movement_speed=previous.movement_speed; _has_position=true
	suspend()
	return true

func configure_beach(description: Dictionary,config: Dictionary,colliders: Array) -> void:
	terrain=Terrain.new(description,config)
	var viewer: Dictionary = config.viewer
	var floor_y: float = terrain.ground(viewer.x,viewer.z)
	var walk: Dictionary = config.walk
	configure({"seats":[{"id":"default_view","eye_position":[viewer.x,floor_y+viewer.eye_height,viewer.z],
		"exit_position":[viewer.x,floor_y,viewer.z],"yaw":0.0}],"default_seat":"default_view",
		"colliders":colliders,"walkable":[{"min":[walk.x_min,0,walk.z_min],"max":[walk.x_max,0,walk.z_max],"height":0.0}]})

func _floor_height(hint: Vector3,tolerance: float) -> float:
	if not hint.is_finite() or terrain==null or not terrain.is_walkable(hint,0.0): return INF
	var height: float = terrain.ground(hint.x,hint.z)
	return height if absf(height-hint.y)<=tolerance+EPSILON else INF

func _standing_at(hint: Vector3,height_tolerance: float) -> Vector3:
	# Exact distance for the whole body circle, in addition to the inherited
	# footprint height samples and collider check. Eight samples alone miss corners.
	if terrain==null or not terrain.is_walkable(hint,BODY_RADIUS): return Vector3.INF
	return super._standing_at(hint,height_tolerance)

func home() -> bool:
	return select_seat("default_view")

func watch_floor(point: Vector3,eye_height: float) -> bool:
	# Arbitrary dry-sand positions, independent of decorative chair count.
	# The eventual XR host supplies tracked height; this method never changes a camera.
	if not is_finite(eye_height) or eye_height<.3 or eye_height>2.5: return false
	var destination := _standing_at(point,MAX_STEP_HEIGHT)
	if not destination.is_finite(): return false
	var source := Vector3(eye_position.x,terrain.ground(eye_position.x,eye_position.z),eye_position.z)
	if not _reachable(source,destination): return false
	if _body_blocked(destination,destination.y+.03,destination.y+maxf(EYE_HEIGHT,eye_height)+HEAD_CLEARANCE): return false
	eye_position=destination+Vector3.UP*eye_height
	selected_seat=""; mode=Mode.WATCH; _has_position=true
	suspend()
	return true

func set_moving(enabled: bool) -> bool:
	if enabled and selected_seat.is_empty() and mode==Mode.WATCH and _has_position:
		# Free watching may use seated/tracked height, not the fixed standing offset
		# assumed by the original auditorium's non-seat transition.
		var point := Vector3(eye_position.x,terrain.ground(eye_position.x,eye_position.z),eye_position.z)
		var destination := _standing_at(point,MAX_STEP_HEIGHT)
		if not destination.is_finite(): return false
		eye_position=destination+Vector3.UP*EYE_HEIGHT
		mode=Mode.MOVE; suspend(); return true
	return super.set_moving(enabled)

func arc_target(origin: Vector3,direction: Vector3) -> Dictionary:
	if mode!=Mode.MOVE or not origin.is_finite() or not direction.is_finite() or direction.length_squared()<.000001: return {}
	# Same throw speed, gravity and time sampling as cinema_environment.gd.
	var points := PackedVector3Array([origin])
	var velocity := direction.normalized()*8.5
	var previous := origin
	for index in range(1,41):
		var time := index*.075
		var point := origin+velocity*time+Vector3.DOWN*4.9*time*time
		var hit := _arc_segment(previous,point)
		if not hit.is_empty():
			points.append(hit.position); hit["points"]=points
			var destination := _standing_at(hit.position,.04) if hit.kind=="floor" else Vector3.INF
			hit["valid"]=destination.is_finite() and _reachable(eye_position-Vector3.UP*EYE_HEIGHT,destination)
			return hit
		points.append(point); previous=point
	return {"kind":"none","valid":false,"points":points}

func _arc_segment(start: Vector3,end: Vector3) -> Dictionary:
	var direction := end-start
	var distance := direction.length()
	if distance<.00001: return {}
	direction/=distance
	var nearest := INF
	var result := {}
	var indices := {}
	var low := _hash_key(start.min(end)-Vector3.ONE*.035)
	var high := _hash_key(start.max(end)+Vector3.ONE*.035)
	for x in range(low.x,high.x+1):
		for z in range(low.y,high.y+1):
			for index in _collider_hash.get(Vector2i(x,z),[]): indices[index]=true
	for index in indices:
		var box: AABB = _colliders[index].grow(.035)
		var d := _ray_box(start,direction,box.position,box.end,distance)
		if d>=0 and d<nearest:
			nearest=d; result={"kind":"blocked","position":start+direction*d}
	# Split across short spans of the piecewise-linear height field, then bisect
	# the first crossing. This queries the visual mesh's triangle interpolation.
	var count := maxi(1,ceili(distance/.07))
	var a := start
	for index in range(1,count+1):
		var b := start.lerp(end,float(index)/count)
		if a.y>=terrain.ground(a.x,a.z) and b.y<=terrain.ground(b.x,b.z):
			for iteration in range(12):
				var middle := (a+b)*.5
				if middle.y>terrain.ground(middle.x,middle.z): a=middle
				else: b=middle
			var hit := (a+b)*.5
			hit.y=terrain.ground(hit.x,hit.z)
			if start.distance_to(hit)<nearest: result={"kind":"floor","position":hit,"floor_y":hit.y}
			break
		a=b
	return result

static func _ray_box(origin: Vector3,direction: Vector3,minimum: Vector3,maximum: Vector3,limit: float) -> float:
	# Slab intersection from cinema_environment.gd, bounded to this arc segment.
	var near := 0.0
	var far := limit
	for axis in 3:
		if absf(direction[axis])<.00001:
			if origin[axis]<minimum[axis] or origin[axis]>maximum[axis]: return -1.0
			continue
		var first := (minimum[axis]-origin[axis])/direction[axis]
		var last := (maximum[axis]-origin[axis])/direction[axis]
		near=maxf(near,minf(first,last)); far=minf(far,maxf(first,last))
		if near>far: return -1.0
	return near if far>=0 and near<=limit else -1.0
