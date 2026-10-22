extends RefCounted
## Debug receiver only. Exercises production window gestures with explicit synthetic rays;
## reports them as such, without claiming a physical controller was pressed.
func run(main: Node3D, command: Dictionary) -> Dictionary:
	if not OS.is_debug_build() or main.photo_active: return {"ok": false, "reason": "unavailable"}
	var pip: RefCounted = main.video.pip
	var step := str(command.get("step", "snapshot"))
	var slot := clampi(int(command.get("slot", 1)), 1, 3)
	var head: Variant = main._head_pose()
	if not head is Transform3D: return {"ok": false, "reason": "head_pose"}
	if step == "count": main._on_menu_action("pip_count_%d" % clampi(int(command.get("value", 0)), 0, 3))
	elif step == "camera": main._on_menu_action("pip_slot_%d" % slot)
	elif step == "format":
		main.video.set_projection(int(command.get("projection", main.video.geometry)))
		main.video.set_stereo_layout(int(command.get("layout", main.video.stereo_layout())))
		if command.has("fov"): main.video.set_fisheye_fov(int(command.fov))
		if command.has("swap") and main.video.swap_eyes != bool(command.swap): main.video.toggle_eye_order()
		if command.has("eye"): main.video.set_viewing_eye(int(command.eye))
		if command.has("curve"): main.video.set_screen_curve(float(command.curve))
		if command.has("rotation"): main.video.set_screen_rotation(float(command.rotation))
		if command.has("horizontal"): main.video.set_stereo_alignment("stereo_horizontal", float(command.horizontal))
		if command.has("vertical"): main.video.set_stereo_alignment("stereo_vertical", float(command.vertical))
	elif step == "enabled": pip.compositor.enabled = bool(command.get("enabled", true))
	elif step == "samples":
		if not pip.compositor.request_samples(): return {"ok": false, "reason": "no_sampleable_atlas"}
	elif step == "snapshot": pass
	elif not pip.windows.has(slot): return {"ok": false, "reason": "missing_slot"}
	elif step == "image": pip.load_image(pip.windows[slot], str(command.get("uri", "")))
	elif step == "video": pip._action(slot, "video", 0)
	elif step == "zoom": pip._action(slot, "zoom", float(command.get("value", 1.0)))
	elif step == "shape": pip.windows[slot].set_aspect(clampi(int(command.get("value", 0)), 0, 4))
	elif step == "view":
		if bool(command.get("stereo", false)): return {"ok": false, "reason": "pip_2d_only"}
	elif step == "close": pip.close(slot)
	elif step == "pick":
		var direction := Vector3(float(command.get("x", 0.1)), float(command.get("y", 0.1)), -1).normalized()
		if main.video.geometry == 0:
			var size: Vector2 = main.video._flat.size
			var point := Vector3((float(command.get("u", 0.3)) - 0.5) * size.x, (0.5 - float(command.get("v", 0.7))) * size.y, 0)
			if main.video.screen_curve > 0:
				var radius: float = main.video._curve_radius()
				point = Vector3(sin(point.x / radius) * radius, point.y, (1 - cos(point.x / radius)) * radius)
			direction = (main.video.panel.to_global(point) - (head as Transform3D).origin).normalized()
		else: direction = main.video.panel.global_basis * direction
		pip._action(slot, "select", 0)
		pip.press("right_hand", "trigger_click", [(head as Transform3D).origin, direction], null, head)
		return {"ok": pip.selecting == 0, "kind": "synthetic_ray", "step": step, "slot": slot}
	elif step in ["move", "resize"]:
		var window: Node3D = pip.windows[slot]
		var previous: Transform3D = window.global_transform
		var old_size: Vector2 = window.size
		var zoom: float = window.zoom
		var point: Vector2 = window.corner_point(clampi(int(command.get("corner", 3)), 0, 3)) if step == "resize" else Vector2.ZERO
		var start: Vector3 = window.to_global(Vector3(point.x, point.y, 0.5))
		var direction: Vector3 = -window.global_basis.z
		var pose := Transform3D(window.global_basis, start)
		var input := "trigger_click" if step == "resize" else "grip_click"
		if not pip.press("right_hand", input, [start, direction], pose, head): return {"ok": false, "reason": "ray_miss"}
		if step == "resize":
			point *= 1.3; start = window.to_global(Vector3(point.x, point.y, 0.5))
			pip.update_input({"right_hand": [start, direction]}, {"right_hand": pose}, head, Time.get_ticks_msec())
		else:
			pose.origin += window.global_basis.x * 0.15
			pip.update_input({"right_hand": [pose.origin, -pose.basis.z]}, {"right_hand": pose}, head, Time.get_ticks_msec())
		pip.release("right_hand", input)
		return {"ok": (window.size != old_size if step == "resize" else not window.global_transform.is_equal_approx(previous)) and is_equal_approx(window.zoom, zoom),
			"kind": "synthetic_ray", "step": step, "slot": slot}
	else: return {"ok": false, "reason": "unknown_step"}
	return {"ok": true, "step": step, "slot": slot}
