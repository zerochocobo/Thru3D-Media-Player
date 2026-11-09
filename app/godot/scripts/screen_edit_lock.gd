extends RefCounted
## User-input guard only. Media loading, geometry setters and saved views keep their semantics.
const CornerControl := preload("res://scripts/screen_lock_control.gd")
const KEYS := ["screen_distance", "screen_scale", "screen_rotation", "screen_curve", "screen_curve_mode",
	"screen_cinema", "screen_preset", "screen_eye_level", "screen_set_default", "cinema_picture_size",
	"video_aspect_preset", "video_aspect_factor", "spatial_match_fov", "portrait_distance", "portrait_scale"]
var host: Node
var control: Node3D
var capture := {}
var blocked_hands := {}
var attempts := {}
var notice := ""
var notice_until := 0
var notice_count := 0
var _explained := false
var _last_notice := -2000

func _init(owner: Node) -> void: host = owner

func applicable() -> bool:
	return not host.photo_active and host.video != null and host.video.geometry == 0 and not host.video.local_uri.is_empty()

func locked() -> bool:
	return applicable() and bool(host.settings.get_value("screen", "edit_locked", false))

func setup() -> void:
	control = CornerControl.new(); host.add_child(control)
	host.menu_composition.register_companion(control)

func notify(message: String) -> void:
	notice = message; notice_until = Time.get_ticks_msec() + 1500; notice_count += 1
	if host.playback_status_overlay: host.playback_status_overlay.refresh()

func deny(hand: String = "", operation: String = "edit") -> bool:
	if not locked(): return false
	var now := Time.get_ticks_msec()
	var key := hand + "/" + operation
	var previous: int = attempts.get(key, -2000)
	attempts[key] = now
	# Continuous input stays silent until released/idle, even after the toast expires.
	if now - previous > 350 and now - _last_notice >= 1500:
		_last_notice = now
		notify("Screen locked" if _explained else "Screen locked\nUnlock at the top-left or in Screen settings")
		_explained = true
		if hand in ["left_hand", "right_hand"]: host._scene_target_pulse(hand)
		if host.player_menu and host.player_menu.has_method("flash_screen_lock"): host.player_menu.flash_screen_lock()
	return true

func guard(key: String, hand: String = "") -> bool:
	return key in KEYS and deny(hand, key)

func set_locked(value: bool) -> void:
	if not applicable(): return
	if value == locked(): return
	var old: bool = host.settings.get_value("screen", "edit_locked", false)
	host.settings.set_value("screen", "edit_locked", value)
	if host.settings.save(host.settings_path) != OK:
		host.settings.set_value("screen", "edit_locked", old)
		notify("Could not save. Try again."); return
	# End captures at their CURRENT value; finishing rotation would snap it and change the picture.
	if not host._grab.is_empty():
		blocked_hands[host._grab.hand] = true
		host._grab.clear(); host._save_screen()
	if not host.interface_move.capture.is_empty() and host.interface_move.capture.targets.any(func(t): return t.node == host.video):
		blocked_hands[host.interface_move.capture.hand] = true
		host._finish_interface_move()
	if host.beach_environment and host.beach_environment.screen_editing():
		for hand in ["left_hand", "right_hand"]:
			if host.beach_environment.scene_held(hand):
				blocked_hands[hand] = true; host.beach_environment.scene_release(hand)
	if host.player_menu:
		if not host.player_menu._adjust_hand.is_empty(): blocked_hands[host.player_menu._adjust_hand] = true
		host.player_menu._finish_adjustment()
		host.player_menu.choices.cancel(host.player_menu.choices.capture.get("hand", ""))
	host._finish_flat_zoom()
	host._video_control_tap.clear()
	host.controller_bindings.reset_inputs(); host.stick_controls.suspend()
	host.video.set_corner_hover(-1)
	attempts.clear()
	notify("Screen locked" if value else "Screen unlocked")
	if host.player_menu: host.player_menu.refresh_values()
	update()

func release_guard(hand: String) -> bool:
	for key in attempts.keys():
		if key.begins_with(hand + "/"): attempts.erase(key)
	return blocked_hands.erase(hand)

func allowed() -> bool:
	if not applicable() or not host._input_focused() or not host.video.panel.visible or host.video.pip.blocked(): return false
	if not host.interface_move.capture.is_empty() or not host._grab.is_empty(): return false
	if host._vr_passthrough_active() or host._watch_owned or (host.puzzle_game and host.puzzle_game.active): return false
	var menu: Node3D = host._active_menu()
	return menu == null or (menu == host.player_menu and not host._menu_captured(menu))

func hit(ray: Variant) -> bool:
	if ray == null or not allowed(): return false
	if host._beach_active() and (host.beach_environment.beach.firework_hit(ray[0], ray[1]) or host.beach_environment.beach.handheld_ray_hit(ray[0], ray[1])): return false
	if host.video.corner_at(ray[0], ray[1]) != CornerControl.upper_left_corner(host.video): return false
	var distance: float = ray[0].distance_to(host.video.panel.to_global(host.video.screen_corner(CornerControl.upper_left_corner(host.video))))
	var menu: Node3D = host._active_menu()
	if menu:
		var menu_hit: Dictionary = menu.pointer_hit(ray[0], ray[1])
		if not menu_hit.is_empty() and float(menu_hit.distance) <= distance: return false
	if not host.video.pip.hit(ray[0], ray[1]).is_empty(): return false
	return true

func press(hand: String) -> bool:
	if blocked_hands.has(hand): return true
	if not capture.is_empty(): return true
	if not hit(host._ray(hand)): return false
	capture = {"hand": hand, "uri": host.video.local_uri, "session": host.video.media.session_id, "cancelled": false}
	host._video_control_tap.clear(); host.stick_controls.suspend()
	update(); return true

func release(hand: String) -> bool:
	if capture.get("hand", "") != hand: return false
	var tap := capture; capture = {}
	if not tap.cancelled and hit(host._ray(hand)) and host.video.local_uri == tap.uri and host.video.media.session_id == tap.session:
		set_locked(not locked())
	host.stick_controls.suspend(); return true

func cancel(hand: String) -> void:
	if capture.get("hand", "") == hand: capture.clear()
	blocked_hands.erase(hand)

func update() -> void:
	if not capture.is_empty() and (not hit(host._ray(capture.hand)) or host.video.local_uri != capture.uri or host.video.media.session_id != capture.session): capture.cancelled = true
	if not is_instance_valid(control): return
	var hits := {}
	for hand in ["left_hand", "right_hand", "mouse"]: hits[hand] = hit(host._ray(hand))
	control.sync(host.video, hits.values().has(true), locked())
	if control.visible:
		for hand in hits:
			var ray: Variant = host._ray(hand)
			control.update_pointer(hand, ray[0] if hits[hand] else Vector3.ZERO, ray[1] if hits[hand] else Vector3.ZERO, hits[hand])

func caption() -> String:
	return notice if applicable() and host._input_focused() and Time.get_ticks_msec() < notice_until else ""


func beach_attempt(ray: Variant, hand: String, corners_only: bool) -> bool:
	if not locked() or ray == null or not host.beach_environment: return false
	var beach: Node3D = host.beach_environment.beach
	# Keep the scene's existing firework/snack priority ahead of screen resizing.
	if corners_only:
		if beach.firework_hit(ray[0], ray[1]): return false
		var held: Dictionary = beach.handheld.get("held", {}).get(hand, {})
		if held.get("kind", "") in ["fruit", "drink", "skewer"]: return false
		if held.is_empty() and beach.handheld_ray_hit(ray[0], ray[1]): return false
	var target: Dictionary = beach.screen_hit(ray[0], ray[1])
	if target.is_empty() or (corners_only and not target.get("corner", false)): return false
	return deny(hand, "beach_screen")


func beach_hover_allowed(ray: Variant) -> bool:
	return not locked() or ray == null or not host.beach_environment or host.beach_environment.beach.firework_hit(ray[0], ray[1]) or host.beach_environment.beach.screen_hit(ray[0], ray[1]).is_empty()
