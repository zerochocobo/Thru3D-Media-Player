extends RefCounted
## Wrist watch interaction: a glance (back of the left wrist turned to the eyes) shows the face;
## bringing the wrist nearer the eyes projects a slanted cone of light forward along the hand,
## topped by a control disc parallel to the back of the hand. The disc rides on the wrist, but
## locks in place while the right hand works it: covering the left hand makes its tracking drift.
## Every distance is in world metres; callers pass world-scaled poses.

enum Phase { HIDDEN, GLANCE, EXPANDED }
enum Level { COARSE, MEDIUM, FINE }

## Nothing here is destructive: the keys only move within the current video or open the menu.
const BUTTONS := ["rewind", "play", "forward", "menu"]
## Keys sit symmetrically about the centre, the menu straight above play.
const BUTTON_SPOTS := {"rewind": Vector2(-0.044, -0.006), "play": Vector2(0.0, -0.006),
	"forward": Vector2(0.044, -0.006), "menu": Vector2(0.0, 0.046)}
const BUTTON_RADIUS := 0.017
const PLAY_RADIUS := 0.022
const MENU_RADIUS := 0.014
## Keys catch the finger this far beyond their rim and pull the landing marker onto them.
const CATCH_MARGIN := 0.012
## The timeline is the right half of a ring, from twelve o'clock down to six, so the right hand
## drags it straight up and down without reaching around the disc.
const PROGRESS_RING := 0.084
const PROGRESS_START := 0.0          # degrees clockwise from the top of the disc
const PROGRESS_SPAN := 90.0          # half of the arc's sweep
const PROGRESS_BAND := 0.022
## Beyond the arc the finger enters finer scrubbing zones.
const MEDIUM_ZONE := 0.03
const FINE_ZONE := 0.065
const LEVEL_HYSTERESIS := 0.007
const MEDIUM_MS_PER_METRE := 1800000.0  # 18 s per centimetre
const FINE_MS_PER_METRE := 200000.0     # 2 s per centimetre
const SEEK_DEADBAND_MS := 1200
## Finger travel along the arc ignored after touching it, so pressing in never nudges the time.
const GRAB_SLOP := 0.004
## Skip keys: a tap jumps 10 s; held, they repeat and switch to 30 s steps.
const SKIP_SECONDS := 10
const SKIP_FAST_SECONDS := 30
const SKIP_FAST_AFTER := 4
const REPEAT_DELAY := 0.45
const REPEAT_INTERVAL := 0.32
## Consecutive skips build on the last target until playback has had time to catch up.
const SKIP_CHAIN := 1.5

## The disc floats this far out of the back of the hand and this far forward along the fingers.
const HOLO_HEIGHT := 0.06
const HOLO_FORWARD := 0.14
## Re-attaching after a lock eases back instead of jumping.
const FOLLOW_RATE := 10.0

## Glance gates (enter / stay) on the wrist-to-eye distance and the face-to-eye cosine; where the
## head points or where the wrist sits around the body does not matter. Measured on Quest 3: a
## level forearm with the back of the hand up faces the eyes at only 0.15-0.47 (the eyes sit
## 20-30 degrees above the wrist), so the facing gate is loose.
const GLANCE_DISTANCE := Vector2(0.62, 0.72)
const GLANCE_FACING := Vector2(0.25, 0.1)
const GLANCE_HOLD := 0.18
const GLANCE_RELEASE := 0.3
## Quest 3 glances sit at 0.28-0.52 m; at 0.30 m the disc landed in the face, so a modest raise
## is enough.
const CHARGE_FROM := 0.52
const EXPAND_DISTANCE := 0.42
const EXPAND_HOLD := 0.25
const REARM_DISTANCE := 0.48
## Lowering the wrist dismisses the projection quickly; turning the palm up dismisses it at once.
const IDLE_COLLAPSE := 0.5
const FLIP_FACING := -0.2
const FLIP_HOLD := 0.12
## Within this range of the disc the right hand owns it: the disc locks and the pointer yields.
const NEAR_HOLOGRAM := 0.12
## With the right hand this close the tracked wrist is likely covered: the face holds still.
const STEADY_RADIUS := 0.2

## Touch depths above the disc; the finger triggers before it covers the key.
const ARM_DEPTH := 0.03
const PRESS_DEPTH := 0.012
const RELEASE_DEPTH := 0.022
const SCRUB_RELEASE_DEPTH := 0.045

var phase := Phase.HIDDEN
var holo := Transform3D.IDENTITY
var face := Transform3D.IDENTITY
var face_valid := false
var tip_local := Vector3.ZERO
var tip_valid := false
var hover := ""
var pressed := ""
var scrub := {}
var level := Level.COARSE
## True while the right hand holds the disc in place.
var locked := false
## 0..1 while the wrist approaches the eyes; drives the face's build-up glow.
var charge := 0.0
## Seconds jumped by the current run of skips, for the readout.
var skip_total := 0
## Seconds since the last press, per target, for press ripples.
var ripples := {}
var media := {}
## Last glance measurements, for diagnostics.
var metrics := {}

var _glance_time := 0.0
var _lost_time := 0.0
var _idle_time := 0.0
var _near_time := 0.0
var _rearmed := true
var _armed := false
var _repeat_time := 0.0
var _repeats := 0
var _skip_target := -1
var _skip_age := INF
var _facing := 0.0
var _flip_time := 0.0
var _wrist_filter := PoseFilter.new()
var _tip_filter := PoseFilter.new()
var _face_rotation := Quaternion.IDENTITY

## One-euro style smoothing: steady when still, responsive when moving.
class PoseFilter extends RefCounted:
	const MIN_CUTOFF := 1.6
	const BETA := 12.0
	var value: Variant = null
	func reset() -> void: value = null
	func apply(sample: Vector3, delta: float) -> Vector3:
		if value == null or delta <= 0.0:
			value = sample; return sample
		var speed: float = (sample - value).length() / delta
		var cutoff := MIN_CUTOFF + BETA * speed
		var alpha := 1.0 / (1.0 + 1.0 / (TAU * cutoff * delta))
		value = (value as Vector3).lerp(sample, alpha)
		return value

## frame: {head: Transform3D, wrist: Transform3D or null (face origin, +Y out of the back of the
## hand, +Z toward the elbow), tip: Vector3 or null, enabled: bool, media: {...}}.
## Returns actions: {op, ...}.
func update(frame: Dictionary, delta: float) -> Array[Dictionary]:
	var actions: Array[Dictionary] = []
	media = frame.get("media", {})
	for key in ripples.keys(): ripples[key] = float(ripples[key]) + delta
	_skip_age += delta
	var head: Transform3D = frame.get("head", Transform3D.IDENTITY)
	var wrist: Variant = frame.get("wrist")
	var tip: Variant = frame.get("tip")
	if not frame.get("enabled", false):
		_reset(); return actions
	tip_valid = tip is Vector3
	var tip_world := _tip_filter.apply(tip, delta) if tip_valid else Vector3.ZERO
	if not tip_valid: _tip_filter.reset()
	if tip_valid and phase == Phase.EXPANDED: tip_local = holo.affine_inverse() * tip_world
	locked = phase == Phase.EXPANDED and owns_tip()
	face_valid = wrist is Transform3D
	if face_valid: _smooth_face(wrist, tip_world, delta)
	else: _wrist_filter.reset()
	var glancing := face_valid and _glance(head, phase != Phase.HIDDEN)
	_glance_time = _glance_time + delta if glancing else 0.0
	_lost_time = 0.0 if glancing else _lost_time + delta
	var distance := head.origin.distance_to(face.origin) if face_valid else INF
	if distance > REARM_DISTANCE: _rearmed = true
	match phase:
		Phase.HIDDEN:
			# Hiding the face re-arms the projection, however close the wrist stayed.
			_rearmed = true
			if _glance_time >= GLANCE_HOLD: phase = Phase.GLANCE
		Phase.GLANCE:
			if _lost_time >= GLANCE_RELEASE:
				phase = Phase.HIDDEN
			elif _rearmed and glancing and distance < EXPAND_DISTANCE:
				_near_time += delta
				if _near_time >= EXPAND_HOLD: _expand(head)
			else: _near_time = 0.0
		Phase.EXPANDED:
			# Turning the wrist over closes the disc straight away, unless a finger is working it.
			_flip_time = _flip_time + delta if face_valid and not locked and scrub.is_empty() and _facing < FLIP_FACING else 0.0
			if _flip_time >= FLIP_HOLD:
				_collapse(); _flip_time = 0.0
			else:
				if face_valid and not locked:
					holo = holo.interpolate_with(_placement(head), clampf(delta * FOLLOW_RATE, 0.0, 1.0))
				if tip_valid: tip_local = holo.affine_inverse() * tip_world
				_update_expanded(delta, actions)
	var reach := clampf((CHARGE_FROM - distance) / (CHARGE_FROM - EXPAND_DISTANCE), 0.0, 1.0)
	charge = 0.0 if phase != Phase.GLANCE or not _rearmed else reach * 0.7 + clampf(_near_time / EXPAND_HOLD, 0.0, 1.0) * 0.3
	return actions

func owns_tip() -> bool:
	if not scrub.is_empty() or not pressed.is_empty(): return true
	if not tip_valid or phase != Phase.EXPANDED: return false
	return tip_local.z < NEAR_HOLOGRAM and tip_local.z > -0.06 and Vector2(tip_local.x, tip_local.y).length() < PROGRESS_RING + FINE_ZONE + 0.04

func expanded() -> bool: return phase == Phase.EXPANDED

func scrub_value() -> float:
	return float(scrub.get("value", 0.0))

## Shown progress 0..1 (the scrub preview while dragging, the skip target while skipping).
func progress() -> float:
	var duration := float(media.get("duration_ms", 0))
	if duration <= 0.0: return 0.0
	var position := float(media.get("position_ms", 0))
	if not scrub.is_empty(): position = float(scrub.value)
	elif _skip_target >= 0 and _skip_age < SKIP_CHAIN: position = _skip_target
	return clampf(position / duration, 0.0, 1.0)

## Where the landing marker sits on the disc: on the caught key, on the arc, or under the finger.
func landing() -> Vector2:
	if hover in BUTTONS: return button_position(hover)
	if not scrub.is_empty(): return arc_point(progress())
	var planar := Vector2(tip_local.x, tip_local.y)
	if hover == "progress": return arc_point(clampf(arc_fraction(planar), 0.0, 1.0))
	return planar

## 0 far above the disc .. 1 at the trigger depth.
func approach() -> float:
	return clampf((ARM_DEPTH * 2.0 - tip_local.z) / (ARM_DEPTH * 2.0 - PRESS_DEPTH), 0.0, 1.0)

func button_enabled(id: String) -> bool:
	return bool(media.get("has_video", true)) if id == "play" else true

static func button_position(id: String) -> Vector2:
	return BUTTON_SPOTS[id]

static func button_radius(id: String) -> float:
	return PLAY_RADIUS if id == "play" else (MENU_RADIUS if id == "menu" else BUTTON_RADIUS)

## Arc fraction 0 (start, top) .. 1 (end, bottom) for a point on the disc; points on the other
## half fall well outside 0..1.
static func arc_fraction(planar: Vector2) -> float:
	var angle := wrapf(rad_to_deg(atan2(planar.x, planar.y)) - PROGRESS_START, -90.0, 270.0)
	return angle / (PROGRESS_SPAN * 2.0)

static func arc_point(fraction: float) -> Vector2:
	var angle := deg_to_rad(PROGRESS_START + PROGRESS_SPAN * 2.0 * fraction)
	return Vector2(sin(angle), cos(angle)) * PROGRESS_RING

func _reset() -> void:
	phase = Phase.HIDDEN
	hover = ""; pressed = ""; scrub = {}; charge = 0.0; locked = false
	_glance_time = 0.0; _lost_time = 0.0; _idle_time = 0.0; _near_time = 0.0
	_armed = false; _rearmed = true; _skip_target = -1; _skip_age = INF
	face_valid = false; tip_valid = false
	_wrist_filter.reset(); _tip_filter.reset()
	_face_rotation = Quaternion.IDENTITY

## Position and rotation both low-passed. With the right hand close the left hand is probably
## covered and its tracking guesses, so the face holds still instead of following the guess.
func _smooth_face(raw: Transform3D, tip_world: Vector3, delta: float) -> void:
	# Only once projected: a right hand resting near the wrist must not stall the raise.
	var covered := phase == Phase.EXPANDED and tip_valid and _wrist_filter.value != null and tip_world.distance_to(_wrist_filter.value) < STEADY_RADIUS
	if _wrist_filter.value != null and (locked or covered): return
	var rotation := raw.basis.orthonormalized().get_rotation_quaternion()
	if _wrist_filter.value == null: _face_rotation = rotation
	else: _face_rotation = _face_rotation.slerp(rotation, clampf(delta * 14.0, 0.0, 1.0)).normalized()
	face = Transform3D(Basis(_face_rotation), _wrist_filter.apply(raw.origin, delta))

func _glance(head: Transform3D, staying: bool) -> bool:
	var index := 1 if staying else 0
	var to_eye := head.origin - face.origin
	var distance := to_eye.length()
	if distance < 0.05 or distance > GLANCE_DISTANCE[index]:
		metrics = {"distance": snappedf(distance, 0.01)}
		return false
	var toward := to_eye / distance
	var facing := face.basis.y.normalized().dot(toward)
	_facing = facing
	var gaze := (-head.basis.z).normalized().dot(-toward)
	metrics = {"distance": snappedf(distance, 0.01), "facing": snappedf(facing, 0.01), "gaze": snappedf(gaze, 0.01)}
	return facing > GLANCE_FACING[index]

func _expand(head: Transform3D) -> void:
	holo = _placement(head)
	phase = Phase.EXPANDED
	_armed = false; _idle_time = 0.0; _near_time = 0.0; _rearmed = false
	hover = ""; pressed = ""; scrub = {}
	ripples["face"] = 0.0

## The disc lies parallel to the back of the hand, out of it and forward along the fingers, so
## the right hand works beyond the left fingertips instead of over the left hand. Only its
## in-plane turn follows the head, so the keys stay upright however the wrist twists.
func _placement(head: Transform3D) -> Transform3D:
	var normal := face.basis.y.normalized()
	var fingers := -face.basis.z
	fingers = (fingers - normal * fingers.dot(normal)).normalized()
	var origin := face.origin + normal * HOLO_HEIGHT + fingers * HOLO_FORWARD
	# The head's up projected onto the disc; when the head tilts down this already points to the
	# far side, and only a head level with a level disc needs the far-side fallback.
	var up := head.basis.y - normal * head.basis.y.dot(normal)
	if up.length_squared() < 0.01:
		var away := origin - head.origin
		up = away - normal * away.dot(normal)
	if up.length_squared() < 0.0001: up = fingers
	up = up.normalized()
	return Transform3D(Basis(up.cross(normal).normalized(), up, normal), origin)

func _collapse() -> void:
	phase = Phase.GLANCE if face_valid else Phase.HIDDEN
	hover = ""; pressed = ""; scrub = {}; _near_time = 0.0; locked = false

func _update_expanded(delta: float, actions: Array[Dictionary]) -> void:
	_idle_time = 0.0 if owns_tip() or _lost_time == 0.0 else _idle_time + delta
	if not tip_valid:
		# Lost tracking cancels a drag instead of committing whatever the last frame showed.
		if not scrub.is_empty(): actions.append({"op": "scrub_end"})
		scrub = {}; pressed = ""; hover = ""; _armed = false
	else:
		var planar := Vector2(tip_local.x, tip_local.y)
		var depth := tip_local.z
		if not scrub.is_empty():
			_drag(planar, depth, actions)
		else:
			hover = _target(planar) if depth < ARM_DEPTH * 2.0 and depth > -0.04 else ""
			if not pressed.is_empty():
				if depth > RELEASE_DEPTH or hover != pressed: _release()
				elif pressed in ["rewind", "forward"]: _repeat(delta, actions)
			elif depth > ARM_DEPTH:
				_armed = true
			elif _armed and depth < PRESS_DEPTH and depth > -0.04 and not hover.is_empty():
				_armed = false
				_press(hover, planar, actions)
	if _idle_time >= IDLE_COLLAPSE and scrub.is_empty(): _collapse()

## The nearest key within its catch margin wins; the arc is caught along its band.
func _target(planar: Vector2) -> String:
	var best := ""
	var best_gap := INF
	for id in BUTTONS:
		var gap := planar.distance_to(button_position(id)) - button_radius(id)
		if gap < CATCH_MARGIN and gap < best_gap:
			best = id; best_gap = gap
	if not best.is_empty(): return best
	var fraction := arc_fraction(planar)
	if absf(planar.length() - PROGRESS_RING) < PROGRESS_BAND and fraction > -0.05 and fraction < 1.05: return "progress"
	return ""

func _press(target: String, planar: Vector2, actions: Array[Dictionary]) -> void:
	if target != "progress" and not button_enabled(target): return
	pressed = target
	ripples[target] = 0.0
	match target:
		"progress":
			var start := float(media.get("position_ms", 0))
			scrub = {"start": start, "value": start, "angle": atan2(planar.x, planar.y), "slop": 0.0, "engaged": false}
			level = Level.COARSE
			actions.append({"op": "scrub_begin"})
		"rewind", "forward":
			_repeats = 0; _repeat_time = 0.0
			if _skip_age >= SKIP_CHAIN: skip_total = 0
			_skip(target, SKIP_SECONDS, actions)
		"play":
			actions.append({"op": "play"})
		"menu":
			actions.append({"op": "menu"})
			_collapse()

func _release() -> void:
	pressed = ""; _armed = false

func _repeat(delta: float, actions: Array[Dictionary]) -> void:
	_repeat_time += delta
	var due := REPEAT_DELAY + _repeats * REPEAT_INTERVAL
	if _repeat_time < due: return
	_repeats += 1
	ripples[pressed] = 0.0
	_skip(pressed, SKIP_FAST_SECONDS if _repeats >= SKIP_FAST_AFTER else SKIP_SECONDS, actions)

func _skip(target: String, seconds: int, actions: Array[Dictionary]) -> void:
	var duration := int(media.get("duration_ms", 0))
	var base := _skip_target if _skip_target >= 0 and _skip_age < SKIP_CHAIN else int(media.get("position_ms", 0))
	var step := seconds * 1000 * (-1 if target == "rewind" else 1)
	var goal := base + step
	if duration > 0: goal = clampi(goal, 0, maxi(0, duration - 500))
	else: goal = maxi(0, goal)
	skip_total += (goal - base) / 1000
	_skip_target = goal
	_skip_age = 0.0
	actions.append({"op": "seek", "position_ms": goal, "skip": seconds * signi(step)})

func _drag(planar: Vector2, depth: float, actions: Array[Dictionary]) -> void:
	if depth > SCRUB_RELEASE_DEPTH:
		_finish_drag(actions); return
	var angle := atan2(planar.x, planar.y)
	var step := wrapf(angle - float(scrub.angle), -PI, PI)
	scrub.angle = angle
	level = _level_for(planar.length() - PROGRESS_RING)
	var travel := step * PROGRESS_RING
	if not scrub.engaged:
		scrub.slop = float(scrub.slop) + travel
		if absf(float(scrub.slop)) < GRAB_SLOP: return
		scrub.engaged = true
		travel = float(scrub.slop) - signf(float(scrub.slop)) * GRAB_SLOP
	var duration := float(media.get("duration_ms", 0))
	var rate := duration / (deg_to_rad(PROGRESS_SPAN * 2.0) * PROGRESS_RING)
	if level >= Level.MEDIUM: rate = minf(rate, MEDIUM_MS_PER_METRE)
	if level == Level.FINE: rate = minf(rate, FINE_MS_PER_METRE)
	scrub.value = clampf(float(scrub.value) + travel * rate, 0.0, maxf(0.0, duration - 500.0))

func _level_for(offset: float) -> Level:
	var medium := MEDIUM_ZONE + (-LEVEL_HYSTERESIS if level >= Level.MEDIUM else LEVEL_HYSTERESIS)
	var fine := FINE_ZONE + (-LEVEL_HYSTERESIS if level == Level.FINE else LEVEL_HYSTERESIS)
	if offset > fine: return Level.FINE
	if offset > medium: return Level.MEDIUM
	return Level.COARSE

func _finish_drag(actions: Array[Dictionary]) -> void:
	if absf(float(scrub.value) - float(scrub.start)) >= SEEK_DEADBAND_MS:
		actions.append({"op": "seek", "position_ms": int(scrub.value)})
	actions.append({"op": "scrub_end"})
	scrub = {}; pressed = ""; _armed = false; level = Level.COARSE
