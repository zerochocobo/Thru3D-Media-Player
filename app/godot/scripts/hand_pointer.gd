extends RefCounted
## Prefer the runtime's hand aim/select; joint recognition is a portability fallback.
## All distances below are in tracking-space metres; only the output ray is world-scaled.
const POSITION_FLAGS := XRHandTracker.HAND_JOINT_FLAG_POSITION_VALID | XRHandTracker.HAND_JOINT_FLAG_POSITION_TRACKED
## Joint fallback ported from MRTK3 (BSD-3-Clause, third_party/player-licenses/mrtk3.txt):
## thumb-index tip distance over index finger length, pressed at 0.25 and released
## above 0.30 (MRTKHandsAggregatorConfig + ArticulatedHandController hysteresis).
const JOINTS := [XRHandTracker.HAND_JOINT_THUMB_TIP, XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP,
	XRHandTracker.HAND_JOINT_INDEX_FINGER_PHALANX_PROXIMAL, XRHandTracker.HAND_JOINT_INDEX_FINGER_PHALANX_INTERMEDIATE,
	XRHandTracker.HAND_JOINT_INDEX_FINGER_PHALANX_DISTAL]
## Fingertips occlude each other while pinching; runtimes then infer rather than track them.
const JOINT_FLAGS := XRHandTracker.HAND_JOINT_FLAG_POSITION_VALID
const PRESS_RATIO := 0.25
const RELEASE_RATIO := 0.30
## MRTK3 switches on one frame. Two consecutive samples keep that response while a lone
## noisy PICO frame cannot click; brief joint dropouts hold the state instead of cancelling.
const CONFIRM_SAMPLES := 2
const JOINT_HOLD_SECONDS := 0.25
## MRTK3 StabilizedRay half-life, in metres of sample movement rather than seconds.
const RAY_HALF_LIFE := 0.01
var source := "none"
var provider := "none"
var ray: Variant = null
var down := false
var armed := false
var _confirmed := 0
var _lost := 0.0
var _menu_down := false
## PICO documents XR_EXT_hand_interaction only for PICO 4 Ultra, with a 5.13.0 pinch-ray
## defect. A profile that stays silent while joints are tracked is distrusted for this run.
const RUNTIME_SILENCE_SECONDS := 0.5
const RUNTIME_MISSED_PINCHES := 2
const AUDIT_CLOSED_SECONDS := 0.06
var runtime_trusted := true
var _runtime_confirmed := false
var _runtime_silent := 0.0
var _audit_closed := 0.0
var _audit_selected := false
var _audit_missed := 0

const HAND_PROFILES := ["/interaction_profiles/ext/hand_interaction_ext", "/interaction_profiles/microsoft/hand_interaction"]
const SIMPLE_PROFILE := "/interaction_profiles/khr/simple_controller"

static func is_hand_profile(tracker: XRPositionalTracker, allow_simple: bool = false) -> bool:
	return tracker != null and (tracker.get_tracker_profile() in HAND_PROFILES or
		(allow_simple and tracker.get_tracker_profile() == SIMPLE_PROFILE))

## Godot Vendors exposes XR_FB_hand_tracking_aim on a dedicated tracker (default pose).
## Action profiles expose the runtime's mapped aim and trigger_click on left/right_hand.
static func runtime_sample(tracker: XRPositionalTracker, space: Transform3D, scale: float, meta: bool) -> Dictionary:
	var result := {"source": "hand", "provider": "meta_aim" if meta else "hand_profile"}
	if tracker == null: return result
	var selected: Variant = tracker.get_input("index_pinch" if meta else "trigger_click")
	if not selected is bool: return result
	result["pinched"] = selected
	if meta:
		result["menu_pressed"] = tracker.get_input("menu_pressed") == true
		# Palm-facing system/menu gestures own the hand: never select or drag content.
		if tracker.get_input("system_gesture") == true or tracker.get_input("menu_gesture") == true:
			return result
	var pose_name := "default" if meta else "aim"
	if not tracker.has_pose(pose_name): return result
	var pose := tracker.get_pose(pose_name)
	if not pose.has_tracking_data or pose.tracking_confidence == XRPose.XR_TRACKING_CONFIDENCE_NONE: return result
	var transform := pose.transform
	if not transform.is_finite() or not space.is_finite() or not is_finite(scale) or scale <= 0: return result
	var direction := space.basis * -transform.basis.z
	if direction.length_squared() < 0.001: return result
	result["ray"] = [space * (transform.origin * scale), direction.normalized()]
	result["pose"] = Transform3D((space.basis*transform.basis).orthonormalized(),result.ray[0])
	return result

static func is_optical(tracker: XRHandTracker) -> bool:
	return tracker != null and tracker.has_tracking_data and tracker.hand_tracking_source in [
		XRHandTracker.HAND_TRACKING_SOURCE_UNKNOWN, XRHandTracker.HAND_TRACKING_SOURCE_UNOBSTRUCTED]

## Motion gestures need the physical pinch, not the origin of the runtime's aim ray.
## Missing joints must not invalidate the independent official click/select path.
static func pinch_position(tracker: XRHandTracker, space: Transform3D, scale: float) -> Variant:
	if not is_optical(tracker) or not space.is_finite() or not is_finite(scale) or scale <= 0: return null
	var point := Vector3.ZERO
	for joint in [XRHandTracker.HAND_JOINT_THUMB_TIP, XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP]:
		if tracker.get_hand_joint_flags(joint) & POSITION_FLAGS != POSITION_FLAGS: return null
		var tip := tracker.get_hand_joint_transform(joint).origin
		if not tip.is_finite(): return null
		point += tip * 0.5
	return space * (point * scale)

## Reference placement needs a tracked palm position, independently of wrist/aim orientation.
static func palm_position(tracker: XRHandTracker, space: Transform3D, scale: float) -> Variant:
	if not is_optical(tracker) or not space.is_finite() or not is_finite(scale) or scale<=0: return null
	var joint := XRHandTracker.HAND_JOINT_PALM
	if tracker.get_hand_joint_flags(joint)&POSITION_FLAGS!=POSITION_FLAGS: return null
	var point := tracker.get_hand_joint_transform(joint).origin
	return space*(point*scale) if point.is_finite() else null

## The physical wrist carries roll even when the runtime stabilizes its aim ray.
static func grip_pose(tracker: XRHandTracker, space: Transform3D, scale: float) -> Variant:
	if not is_optical(tracker) or not space.is_finite() or not is_finite(scale) or scale<=0: return null
	var joint := XRHandTracker.HAND_JOINT_WRIST
	var flags := POSITION_FLAGS | XRHandTracker.HAND_JOINT_FLAG_ORIENTATION_VALID | XRHandTracker.HAND_JOINT_FLAG_ORIENTATION_TRACKED
	if tracker.get_hand_joint_flags(joint)&flags!=flags: return null
	var pose := tracker.get_hand_joint_transform(joint)
	if not pose.is_finite() or absf(pose.basis.determinant())<0.001: return null
	return Transform3D((space.basis*pose.basis).orthonormalized(),space*(pose.origin*scale))

const OPEN_FINGERS := [
	[XRHandTracker.HAND_JOINT_INDEX_FINGER_PHALANX_PROXIMAL, XRHandTracker.HAND_JOINT_INDEX_FINGER_PHALANX_INTERMEDIATE, XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP],
	[XRHandTracker.HAND_JOINT_MIDDLE_FINGER_PHALANX_PROXIMAL, XRHandTracker.HAND_JOINT_MIDDLE_FINGER_PHALANX_INTERMEDIATE, XRHandTracker.HAND_JOINT_MIDDLE_FINGER_TIP],
	[XRHandTracker.HAND_JOINT_RING_FINGER_PHALANX_PROXIMAL, XRHandTracker.HAND_JOINT_RING_FINGER_PHALANX_INTERMEDIATE, XRHandTracker.HAND_JOINT_RING_FINGER_TIP],
	[XRHandTracker.HAND_JOINT_PINKY_FINGER_PHALANX_PROXIMAL, XRHandTracker.HAND_JOINT_PINKY_FINGER_PHALANX_INTERMEDIATE, XRHandTracker.HAND_JOINT_PINKY_FINGER_TIP]]

## Palm motion uses optical joints independently of the optional pointing/aim pose.
static func palm_sample(tracker: XRHandTracker, hand: String, head: Transform3D, space: Transform3D, scale: float,
		meta_aim: XRPositionalTracker = null, interaction: XRPositionalTracker = null) -> Dictionary:
	if not is_optical(tracker) or not head.is_finite() or not space.is_finite() or not is_finite(scale) or scale <= 0: return {}
	var required := [XRHandTracker.HAND_JOINT_PALM, XRHandTracker.HAND_JOINT_WRIST, XRHandTracker.HAND_JOINT_THUMB_TIP,
		OPEN_FINGERS[0][0], OPEN_FINGERS[0][2], OPEN_FINGERS[3][0]]
	var points := {}
	for joint in required:
		if tracker.get_hand_joint_flags(joint) & POSITION_FLAGS != POSITION_FLAGS: return {}
		var point := tracker.get_hand_joint_transform(joint).origin
		if not point.is_finite(): return {}
		points[joint] = point
	var index: Vector3 = points[OPEN_FINGERS[0][0]]
	var pinky: Vector3 = points[OPEN_FINGERS[3][0]]
	var width := index.distance_to(pinky)
	if width < 0.035 or width > 0.13: return {}
	var wrist: Vector3 = points[XRHandTracker.HAND_JOINT_WRIST]
	var extended := 0
	for finger in OPEN_FINGERS:
		var valid := true
		for joint in finger:
			if tracker.get_hand_joint_flags(joint) & POSITION_FLAGS != POSITION_FLAGS:
				valid = false; break
			var point := tracker.get_hand_joint_transform(joint).origin
			if not point.is_finite(): valid = false; break
			points[joint] = point
		if not valid: continue
		var root: Vector3 = points[finger[0]]; var middle: Vector3 = points[finger[1]]; var tip: Vector3 = points[finger[2]]
		if (middle-root).length() >= 0.006 and (tip-middle).length() >= 0.006 \
			and (middle-root).normalized().dot((tip-middle).normalized()) >= 0.35 \
			and tip.distance_to(wrist) >= root.distance_to(wrist) + width * 0.30: extended += 1
	# A relaxed open hand often has a bent/partly occluded little finger.
	var open := extended >= 3
	var pinched: bool = points[XRHandTracker.HAND_JOINT_THUMB_TIP].distance_to(points[XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP]) < width * 0.3
	var blocked := false
	var provider := "joints"
	if meta_aim != null:
		provider = "meta_aim"
		pinched = pinched or meta_aim.get_input("index_pinch") == true
		blocked = meta_aim.get_input("system_gesture") == true or meta_aim.get_input("menu_gesture") == true or meta_aim.get_input("menu_pressed") == true
	elif is_hand_profile(interaction, true):
		provider = "hand_profile"
		pinched = pinched or interaction.get_input("trigger_click") == true
	var position: Vector3 = space * (points[XRHandTracker.HAND_JOINT_PALM] * scale)
	var normal: Vector3 = space.basis * (index-pinky).cross(points[XRHandTracker.HAND_JOINT_PALM]-wrist)
	if hand == "left_hand": normal = -normal
	var forward := -head.basis.z; forward.y = 0
	if forward.length_squared() < 0.001 or normal.length_squared() < 0.000001: return {}
	forward = forward.normalized()
	var right := forward.cross(Vector3.UP)
	var offset := (position-head.origin) / scale
	var in_front := offset.dot(forward) >= 0.08 and offset.dot(forward) <= 1.1 \
		and absf(offset.dot(right)) <= 0.8 and offset.y >= -0.8 and offset.y <= 0.4
	var facing_dot := normal.normalized().dot((head.origin-position).normalized())
	# Side-on sweeps are natural too; runtime system gestures retain priority.
	var facing := facing_dot < 0.65
	return {"tracked": true, "open": open, "pinched": pinched, "blocked": blocked,
		"eligible": in_front and facing and open and not pinched and not blocked,
		"position": position, "provider": provider, "space": space,
		"extended": extended, "in_front": in_front, "facing_dot": facing_dot}

## `trust_runtime` is the pointer's audit of the hand profile (see `_audit_runtime`).
static func sample(tracker: XRHandTracker, hand: String, head: Transform3D, space: Transform3D, scale: float,
		meta_aim: XRPositionalTracker = null, interaction: XRPositionalTracker = null, trust_runtime: bool = true) -> Dictionary:
	if not is_optical(tracker): return {}
	# A temporarily invalid official pose cancels, rather than changing recognizer mid-pinch.
	if meta_aim != null: return runtime_sample(meta_aim, space, scale, true)
	var joints := joint_sample(tracker, hand, head, space, scale)
	if trust_runtime and is_hand_profile(interaction, true):
		var result := runtime_sample(interaction, space, scale, false)
		# Joint geometry audits runtimes that advertise hand selection without delivering it.
		if joints.has("ratio"): result["joint_ratio"] = joints.ratio
		return result
	return joints

## Thumb-index distance normalized by index finger length; INF when joints cannot say.
static func pinch_ratio(tracker: XRHandTracker) -> float:
	var points: Array[Vector3] = []
	for joint in JOINTS:
		if tracker == null or tracker.get_hand_joint_flags(joint) & JOINT_FLAGS != JOINT_FLAGS: return INF
		var point := tracker.get_hand_joint_transform(joint).origin
		if not point.is_finite(): return INF
		points.append(point)
	var finger := points[2].distance_to(points[3]) + points[3].distance_to(points[4]) + points[4].distance_to(points[1])
	if finger < 0.04 or finger > 0.14: return INF
	return points[0].distance_to(points[1]) / finger

## MRTK3 HandRay dynamic pivot: a head-relative shoulder estimate that follows the hand.
static func ray_pivot(hand: String, head: Transform3D, knuckle: Vector3, scale: float) -> Vector3:
	var basis := head.basis.orthonormalized()
	var local := basis.inverse() * (knuckle - head.origin) / scale
	var right := hand == "right_hand"
	var x := clampf((0.03 if right else -0.03) + 0.65 * local.x, 0.08 if right else -0.15, 0.15 if right else -0.08)
	var y := clampf(-0.1 + minf(0.65 * local.y, 0), -0.6, -0.2)
	return head.origin + basis * (Vector3(x, y, -0.08) * scale)

static func joint_sample(tracker: XRHandTracker, hand: String, head: Transform3D, space: Transform3D, scale: float) -> Dictionary:
	# Preserve optical ownership on invalid joints; never fall back to an emulated trigger.
	var result := {"source": "hand", "provider": "joints"}
	var ratio := pinch_ratio(tracker)
	if not is_finite(ratio) or not head.is_finite() or not space.is_finite() or not is_finite(scale) or scale <= 0: return result
	# The knuckle does not move as the fingers close, so selecting does not pull the ray.
	var knuckle := space * (tracker.get_hand_joint_transform(XRHandTracker.HAND_JOINT_INDEX_FINGER_PHALANX_PROXIMAL).origin * scale)
	var direction := knuckle - ray_pivot(hand, head, knuckle, scale)
	var forward := -head.basis.z
	forward.y = 0
	if forward.length_squared() < 0.001: return result
	# Resting hands and hands behind the head must not accidentally open the player.
	if not knuckle.is_finite() or direction.length() < 0.05 * scale or (knuckle - head.origin).dot(forward.normalized()) < 0.08 * scale:
		return result
	result["ray"] = [knuckle, direction.normalized()]
	result["ratio"] = ratio
	result["scale"] = scale
	return result

func update(input: Dictionary, delta: float) -> Dictionary:
	var next_source := str(input.get("source", "none"))
	var next_provider := str(input.get("provider", "joints" if next_source == "hand" else next_source))
	var native := next_source == "hand" and next_provider in ["meta_aim", "hand_profile"]
	var next_ray: Variant = input.get("ray")
	var ratio := float(input.get("ratio", INF))
	if next_ray != null and (not next_ray[0].is_finite() or not next_ray[1].is_finite() or next_ray[1].length_squared() < 0.001):
		next_ray = null
	if next_source == "hand" and ((native and not input.get("pinched") is bool) or (not native and not is_finite(ratio))): next_ray = null
	if next_source == "hand" and next_provider == "hand_profile" and runtime_trusted: _audit_runtime(input, delta)
	var changed := next_source != source or next_provider != provider
	if not native and next_source == "hand" and not changed and ray != null and next_ray == null:
		_lost += clampf(delta, 0, 0.1)
		if _lost < JOINT_HOLD_SECONDS:
			return {"pressed": false, "released": false, "cancelled": false, "menu": false}
	_lost = 0
	var cancelled := changed or (ray != null and next_ray == null)
	if cancelled:
		down = false
		armed = false
		_confirmed = 0
	source = next_source
	provider = next_provider
	var was_tracked := ray != null
	if next_ray != null and source == "hand" and not native and was_tracked and not changed:
		var half := RAY_HALF_LIFE * float(input.get("scale", 1.0))
		ray = [_decay(ray[0], next_ray[0], half), _decay(ray[1], next_ray[1], RAY_HALF_LIFE).normalized()]
	else:
		ray = next_ray
	var menu_down: bool = native and next_provider == "meta_aim" and input.get("menu_pressed", false) == true
	var event := {"pressed": false, "released": false, "cancelled": cancelled,
		"menu": menu_down and not _menu_down and not changed}
	_menu_down = menu_down
	if source != "hand" or ray == null: return event
	if native:
		# Runtime selection is already recognized/debounced. Do not add joint thresholds,
		# the fallback's 60ms delay, or another ray filter to the official result.
		var pinched: bool = input.pinched
		if not armed:
			if not pinched: armed = true
		elif pinched != down:
			down = pinched
			event["pressed" if down else "released"] = true
		return event
	# Reacquisition while pinching cannot activate anything. First open, then pinch.
	var opening := ratio > RELEASE_RATIO
	var closing := ratio <= PRESS_RATIO
	if (not armed and opening) or (armed and not down and closing) or (down and opening):
		_confirmed += 1
		if _confirmed >= CONFIRM_SAMPLES:
			_confirmed = 0
			if not armed:
				armed = true
			elif down:
				down = false
				event.released = true
			else:
				down = true
				event.pressed = true
	else:
		_confirmed = 0
	return event

## MRTK3 StabilizedRay.DynamicExpDecay: jitter is damped, deliberate motion passes.
static func _decay(from: Vector3, to: Vector3, half_life: float) -> Vector3:
	return from.lerp(to, 1.0 - pow(0.5, from.distance_to(to) / half_life))

func _audit_runtime(input: Dictionary, delta: float) -> void:
	var joint_ratio := float(input.get("joint_ratio", INF))
	# Without a tracked joint pinch there is no better recognizer to fall back to.
	if not is_finite(joint_ratio):
		_runtime_silent = 0; _audit_closed = 0
		return
	if input.get("ray") == null or not input.get("pinched") is bool:
		_runtime_silent += clampf(delta, 0, 0.1)
		if _runtime_silent >= RUNTIME_SILENCE_SECONDS: runtime_trusted = false
		return
	_runtime_silent = 0
	if input.pinched:
		_audit_selected = true; _runtime_confirmed = true
	if _runtime_confirmed: return
	if joint_ratio <= PRESS_RATIO:
		_audit_closed += clampf(delta, 0, 0.035)
	elif joint_ratio > RELEASE_RATIO:
		if _audit_closed >= AUDIT_CLOSED_SECONDS and not _audit_selected:
			_audit_missed += 1
			if _audit_missed >= RUNTIME_MISSED_PINCHES: runtime_trusted = false
		_audit_closed = 0; _audit_selected = false

## Sweeps are displacement gestures. Finger articulation never arms this recognizer.
static func sweep_sample(tracker: XRHandTracker, head: Transform3D, space: Transform3D, scale: float,
		meta_aim: XRPositionalTracker = null, interaction: XRPositionalTracker = null) -> Dictionary:
	if not is_optical(tracker) or not head.is_finite() or not space.is_finite() or not is_finite(scale) or scale <= 0: return {}
	var palm := XRHandTracker.HAND_JOINT_PALM
	if tracker.get_hand_joint_flags(palm) & POSITION_FLAGS != POSITION_FLAGS: return {}
	var local := tracker.get_hand_joint_transform(palm).origin
	if not local.is_finite(): return {}
	var position := space * (local * scale)
	var offset := head.basis.inverse() * (position - head.origin) / scale
	var pinched := false; var blocked := false
	var provider := "joints"
	if meta_aim:
		provider = "meta_aim"; pinched = meta_aim.get_input("index_pinch") == true
		blocked = meta_aim.get_input("system_gesture") == true or meta_aim.get_input("menu_gesture") == true or meta_aim.get_input("menu_pressed") == true
	elif is_hand_profile(interaction, true):
		provider = "hand_profile"; pinched = interaction.get_input("trigger_click") == true
	var thumb := XRHandTracker.HAND_JOINT_THUMB_TIP; var index := XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP
	if tracker.get_hand_joint_flags(thumb) & POSITION_FLAGS == POSITION_FLAGS and tracker.get_hand_joint_flags(index) & POSITION_FLAGS == POSITION_FLAGS:
		pinched = pinched or tracker.get_hand_joint_transform(thumb).origin.distance_to(tracker.get_hand_joint_transform(index).origin) < 0.022
	return {"tracked": true, "position": position, "provider": provider, "space": space,
		"eligible": offset.z < -0.08 and offset.z > -1.2 and absf(offset.x) < 0.95 and offset.y > -0.85 and offset.y < 0.5,
		"pinched": pinched, "blocked": blocked}
