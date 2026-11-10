extends RefCounted
## Session-only adapter. Unlocked input takes the existing paths unchanged.
const Hand := preload("res://scripts/hand_pointer.gd")
const Gesture := preload("res://scripts/hand_lock_gesture.gd")
const Indicator := preload("res://scripts/hand_lock_indicator.gd")
const Log := preload("res://scripts/diagnostic_log.gd")
const HANDS := ["left_hand", "right_hand"]
enum Source { NONE, BARE, CONTROLLER, UNKNOWN }
var host: Node
var locked := false
var recovery := Gesture.new()
var indicator: Node3D
var panel_capture := {}
var release_guards := {}
var _blocked := {}
## Hands raised when the lock engaged; they must leave the recovery region before offering a target.
var _settling := {}
var _sources := {}
var _known_bare := {}

func _init(owner: Node) -> void: host = owner

func setup() -> void:
	indicator = Indicator.new(); indicator.name = "HandUnlock"
	host.add_child(indicator)
	if host.menu_composition: host.menu_composition.register_companion(indicator)

func context() -> bool:
	if host.photo_active or host.video == null or host.video.local_uri.is_empty(): return false
	if host.puzzle_game and host.puzzle_game.active: return false
	if host.player_menu and host.player_menu.has_expanded_library(): return false
	var menu: Node3D = host._active_menu()
	return menu == null or menu == host.player_menu or menu == host.vr_passthrough_menu

func effective() -> bool: return locked and context()

## Profiles name an action route, not necessarily the physical device behind it.
static func classify(optical: bool, controller_skeleton: bool, meta: bool, hand_profile: bool, physical_pose: bool, previous_hand: bool) -> Source:
	if controller_skeleton: return Source.CONTROLLER
	if optical or meta: return Source.BARE
	if physical_pose and not hand_profile: return Source.CONTROLLER
	if previous_hand: return Source.UNKNOWN
	if physical_pose: return Source.CONTROLLER
	return Source.NONE

func source(hand: String) -> Source:
	if hand not in HANDS: return Source.NONE
	var joints: XRHandTracker = host._hand_tracker(hand)
	var action: XRPositionalTracker = host._hand_action_tracker(hand)
	var controller_skeleton := joints != null and joints.has_tracking_data and joints.hand_tracking_source == XRHandTracker.HAND_TRACKING_SOURCE_CONTROLLER
	var profile_hand := Hand.is_hand_profile(action)
	var physical := action != null and action.has_pose("aim") and action.get_pose("aim").has_tracking_data
	var meta: XRPositionalTracker = host._meta_aim_tracker(hand)
	var meta_active := meta != null and meta.has_pose("default") and meta.get_pose("default").has_tracking_data
	var previous: bool = _known_bare.get(hand, false)
	# A valid controller route wins over an inactive/stale Meta tracker, not over optical hands.
	var kind := classify(Hand.is_optical(joints), controller_skeleton, meta_active and not (physical and not profile_hand), profile_hand, physical, previous)
	if kind == Source.BARE: _known_bare[hand] = true
	elif kind == Source.CONTROLLER: _known_bare.erase(hand)
	return kind

func bare(hand: String) -> bool: return source(hand) in [Source.BARE, Source.UNKNOWN]

func blocked(hand: String) -> bool:
	if hand not in HANDS: return false
	if release_guards.has(hand) and source(hand) != Source.CONTROLLER: return true
	return effective() and bare(hand)

func watch_allowed() -> bool:
	return not recovery.holding and panel_capture.is_empty()

func _cancel_input(hand: String) -> void:
	# Opt-in cancellation: existing release/save semantics remain unchanged elsewhere.
	host._cinema_move_hands.erase(hand)
	for key in host._controller_consumed.keys():
		if str(key).begins_with(hand + "/"): host._controller_consumed.erase(key)
	if host.player_menu: host.player_menu.cancel_for_hand_lock(hand)
	if host.cinema_environment and host.cinema_environment.has_method("cancel_for_hand_lock"):
		host.cinema_environment.cancel_for_hand_lock(hand)
	if host._grab.get("hand", "") == hand and not host._grab.has("rotate"):
		host._grab = {}
		if host._viewer(): host._viewer().set_corner_hover(-1)
	host._cancel_pointer(hand)

func sync_context() -> void:
	# Remember positively observed hands before a later lock/tracking dropout.
	for hand in HANDS: source(hand)
	if not locked and release_guards.is_empty() and panel_capture.is_empty(): return
	for hand in HANDS:
		var stopped := blocked(hand)
		if stopped and not _blocked.get(hand, false): _cancel_input(hand)
		_blocked[hand] = stopped
	if not host._input_focused() or not context():
		cancel_candidates()

func cancel_candidates() -> void:
	if not panel_capture.is_empty(): release_guards[panel_capture.hand] = true
	recovery.reset(); panel_capture.clear()
	if is_instance_valid(indicator): indicator.visible = false
	if host.player_menu: host.player_menu.set_hand_lock_progress(0.0)

func set_locked(value: bool, origin: String = "controller") -> void:
	if locked == value: return
	if value and not context(): return
	locked = value
	cancel_candidates()
	_settling.clear()
	for hand in HANDS:
		if bare(hand):
			release_guards[hand] = true
			if value: _settling[hand] = true
			_cancel_input(hand)
	# Preserve the current wrist hold until its finger leaves; other changes cancel it.
	if host.wrist_watch and origin != "watch": host.wrist_watch.logic._reset()
	if host.player_menu:
		# Bare hands cannot close the controls once locked, so no submenu may stay open.
		# Locked hands were cancelled above; dismiss() keeps its ordinary close semantics otherwise.
		if value and origin != "controller" and host.player_menu.visible: host.player_menu.dismiss()
		host.player_menu.refresh_values()
		host.player_menu.refresh_hand_lock_icon(locked)
	Log.record("viewing_hand_lock", {"locked": locked, "origin": origin})

func _panel_hit(hand: String) -> bool:
	if not host.player_menu or not host.player_menu.visible: return false
	if not host.hand_pointers.has(hand): return false
	var ray: Variant = host.hand_pointers[hand].ray
	return ray != null and int(host.player_menu.ray_hit(ray[0], ray[1]).get("target", -1)) == host.player_menu.HAND_LOCK and context()

func press(action: String, hand: String) -> bool:
	if blocked(hand): return true
	if action != "trigger_click" or locked or not bare(hand) or not _panel_hit(hand): return false
	if panel_capture.is_empty(): panel_capture = {"hand": hand, "elapsed": 0.0}
	return true

func release(hand: String) -> bool:
	if blocked(hand): return true
	if panel_capture.get("hand", "") != hand: return false
	panel_capture.clear()
	if host.player_menu: host.player_menu.set_hand_lock_progress(0.0)
	return true

func _sample(hand: String, inputs: Dictionary) -> Dictionary:
	var input: Dictionary = inputs.get(hand, {})
	var pointer: RefCounted = host.hand_pointers.get(hand)
	var ray: Variant = pointer.ray if pointer else null
	var point: Variant = input.get("position")
	if point == null and ray != null: point = ray[0]
	var system := false
	var meta: XRPositionalTracker = host._meta_aim_tracker(hand)
	if meta: system = meta.get_input("system_gesture") == true or meta.get_input("menu_gesture") == true
	return {"hand": hand, "tracked": input.get("tracked", false) and input.get("sample_valid", true) and source(hand) == Source.BARE,
		"point": point, "ray": ray, "down": input.get("down", false), "blocked": system}

## Called with raw, already recognized input before ANY ordinary hand dispatch.
func filter(inputs: Dictionary, delta: float) -> Dictionary:
	if not locked and release_guards.is_empty() and panel_capture.is_empty(): return inputs
	var result := inputs.duplicate()
	var consumed := {}
	for hand in HANDS:
		var kind := source(hand)
		if OS.is_debug_build() and kind != _sources.get(hand, Source.NONE):
			_sources[hand] = kind
			Log.record("hand_lock_source", {"hand": hand, "kind": kind, "locked": locked, "viewing": context()})
		if release_guards.has(hand):
			var raw: Dictionary = inputs.get(hand, {})
			if kind == Source.CONTROLLER: release_guards.erase(hand)
			else:
				consumed[hand] = true
				if raw.get("tracked", false) and raw.get("sample_valid", true) and not raw.get("down", false): release_guards.erase(hand)
	if not panel_capture.is_empty():
		var hand: String = panel_capture.hand
		var raw: Dictionary = inputs.get(hand, {})
		consumed[hand] = true
		if not host._input_focused() or not _panel_hit(hand) or not raw.get("tracked", false) or not raw.get("sample_valid", true) or not raw.get("down", false):
			panel_capture.clear()
			release_guards[hand] = true
			host.player_menu.set_hand_lock_progress(0.0)
		else:
			panel_capture.elapsed += clampf(delta, 0.0, 0.05)
			host.player_menu.set_hand_lock_progress(minf(1.0, panel_capture.elapsed / Gesture.HOLD))
			if panel_capture.elapsed >= Gesture.HOLD: set_locked(true, "panel")
	if effective() and host._input_focused() and host.xr_camera and host._head_tracked():
		var watch_busy: bool = host.wrist_watch != null and host.wrist_watch.owns_tip()
		var watch_shown: bool = host.wrist_watch != null and host.wrist_watch.visible and host._watch_enabled()
		var head: Transform3D = host.xr_camera.global_transform
		for hand in _settling.keys():
			var rest := _sample(hand, inputs)
			if not (rest.tracked and rest.point is Vector3 and Gesture.eligible(rest.point, head, XRServer.world_scale)):
				_settling.erase(hand)
		var candidate := recovery.hand
		if watch_busy: recovery.reset(); candidate = ""
		elif candidate.is_empty():
			for hand in ["right_hand", "left_hand"]:
				if (hand == "left_hand" and watch_shown) or _settling.has(hand): continue
				var sample := _sample(hand, inputs)
				if sample.tracked and sample.point is Vector3 and not sample.blocked \
					and Gesture.eligible(sample.point, host.xr_camera.global_transform, XRServer.world_scale):
					candidate = hand; break
		if not candidate.is_empty() and not (candidate == "left_hand" and watch_shown):
			var sample := _sample(candidate, inputs)
			if recovery.update(sample, host.xr_camera.global_transform, XRServer.world_scale, delta):
				set_locked(false, "gesture"); consumed[candidate] = true
			if is_instance_valid(indicator): indicator.sync(recovery, sample.ray, XRServer.world_scale)
		else:
			recovery.reset()
			if is_instance_valid(indicator): indicator.visible = false
	else:
		recovery.reset()
		if is_instance_valid(indicator): indicator.visible = false
	for hand in inputs:
		if consumed.has(hand) or blocked(hand): result.erase(hand)
	return result
