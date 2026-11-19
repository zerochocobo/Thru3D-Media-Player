extends RefCounted
## Runtimes with simultaneous hands and controllers (PICO enterprise mixed interaction) keep
## reporting an optical hand while that hand holds a controller. A controller in use owns its
## hand; one left lying still hands it back to gestures after IDLE_SECONDS.
const Hand := preload("res://scripts/hand_pointer.gd")
const MOVE_METRES := 0.01
const TURN_RADIANS := deg_to_rad(3.0)
const IDLE_SECONDS := 3.0
const ANALOG := 0.1
var _anchor := {}
var _idle := {}

func engaged(hand: String) -> bool: return _idle.has(hand)

## A button signal can arrive before this frame's update.
func touch(hand: String) -> void:
	if _candidate(XRServer.get_tracker(hand) as XRPositionalTracker) != null: _idle[hand] = 0.0

func update(hand: String, delta: float) -> void:
	var tracker := XRServer.get_tracker(hand) as XRPositionalTracker
	var pose: Variant = _candidate(tracker)
	if pose == null:
		_anchor.erase(hand); _idle.erase(hand)
		return
	var active := _analog_active(tracker)
	var anchor: Variant = _anchor.get(hand)
	if anchor == null or (anchor as Transform3D).origin.distance_to(pose.origin) > MOVE_METRES \
		or Quaternion((anchor as Transform3D).basis.orthonormalized()).angle_to(Quaternion(pose.basis.orthonormalized())) > TURN_RADIANS:
		# The first sample only anchors: a controller resting on a table never engages.
		if anchor != null: active = true
		_anchor[hand] = pose
	if active: _idle[hand] = 0.0
	elif _idle.has(hand):
		_idle[hand] += delta
		if _idle[hand] >= IDLE_SECONDS: _idle.erase(hand)

## Only a physical controller profile with a tracked aim pose counts.
static func _candidate(tracker: XRPositionalTracker) -> Variant:
	if tracker == null: return null
	var profile := str(tracker.get_tracker_profile())
	if profile.is_empty() or Hand.is_hand_profile(tracker, true): return null
	if not tracker.has_pose("aim"): return null
	var pose := tracker.get_pose("aim")
	if not pose.has_tracking_data or pose.tracking_confidence == XRPose.XR_TRACKING_CONFIDENCE_NONE: return null
	return pose.transform if pose.transform.is_finite() else null

static func _analog_active(tracker: XRPositionalTracker) -> bool:
	for name in ["trigger", "grip"]:
		var value: Variant = tracker.get_input(name)
		if (value is float or value is int) and float(value) > ANALOG: return true
	var stick: Variant = tracker.get_input("primary")
	return stick is Vector2 and (stick as Vector2).length() > ANALOG * 2
