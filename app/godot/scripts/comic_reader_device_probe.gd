extends RefCounted
# Shell-only Debug commands arrive through the existing protected diagnostics receiver.
# Synthetic rays still use the real photo projection, bubble hit test and dwell state machine.
var until := 0
var uv := Vector2.ZERO
func active() -> bool: return OS.is_debug_build() and Time.get_ticks_msec() < until
func rays(photo: Node3D, normal: Array) -> Array:
	if not active(): return normal
	var point: Vector3 = photo.panel.to_global(photo.comic.position(uv))
	var normal_axis: Vector3 = photo.panel.global_basis.z.normalized()
	return [[point + normal_axis, -normal_axis]]

func click_field(menu: Node3D, command: Dictionary) -> bool:
	if not menu.visible or menu._adjustment != "comic_voice": return false
	for target in menu.choices.targets:
		var item: Dictionary = menu.choices.targets[target]
		if item.get("key") != command.get("key") or item.get("kind") != command.get("kind"): continue
		if item.get("kind") == "choose" and item.get("value") != command.get("value"): continue
		for button: Dictionary in menu._buttons:
			if button.target != target: continue
			var normal: Vector3 = menu.global_basis.z.normalized()
			var origin: Vector3 = button.node.global_position + normal
			menu.press_pointer("right", origin, -normal, true)
			menu.release_pointer("right", origin, -normal, true)
			return true
	return false

func run(app: Node, command: Dictionary) -> void:
	if not OS.is_debug_build(): return
	var reader = app.photo.comic
	var clicked := false
	match str(command.get("step", "status")):
		"options":
			for key in command.get("options", {}): reader.preferences.set_option(key, command.options[key])
			reader.configure()
			if command.get("options", {}).has("comic_enabled"): reader.set_enabled(reader.preferences.enabled)
		"hover":
			uv = Vector2(float(command.get("x", .5)), float(command.get("y", .5)))
			until = Time.get_ticks_msec() + clampi(int(command.get("ms", 2500)), 0, 10000)
		"leave": until = 0; reader.stop()
		"preview": reader.preview()
		"menu": app._show_player_menu(); app.photo_menu._activate(app.photo_menu.PHOTO_COMIC_VOICE)
		"field": clicked = click_field(app.photo_menu, command)
		"preview_button":
			if app.photo_menu.visible and app.photo_menu._adjustment == "comic_voice":
				app.photo_menu._activate(app.photo_menu.PHOTO_COMIC_PREVIEW); clicked = true
	var native: Variant = JSON.parse_string(app.platform_plugin.comic_reader_status(reader.epoch, -1))
	var ray_hits := []
	for hand in ["right_hand", "left_hand"]:
		var ray: Variant = app._ray(hand)
		if ray == null: ray_hits.append({"hand": hand, "tracked": false}); continue
		var point: Vector2 = app.photo._inspect_uv(ray[0], ray[1])
		ray_hits.append({"hand": hand, "tracked": true, "uv": [point.x, point.y], "hit": reader.hit(reader.pages, reader.rects, point).get("key", "")})
	var report := {"native": native, "state": reader.state, "enabled": reader.enabled,
		"clicked": clicked, "choice_opened": app.photo_menu.choices.opened, "choice_fields": app.photo_menu.choices.targets.values(),
		"readable": reader.readable_count(), "candidates": reader.candidate_count(), "blocked": reader.blocked, "ray_hits": ray_hits,
		"guides_visible": is_instance_valid(reader.guide) and reader.guide.visible,
		"speech": reader.speech_state, "latency": reader.latency, "dwell_target": reader.dwell.target,
		"dwell_progress": reader.dwell.progress, "read_requests": reader.read_requests,
		"ray_injected": active(), "photo_loading": app.photo.loading, "photo_active": app.photo_active,
		"menu": app._active_menu() != null, "focused": app._input_focused(),
		"preferences": reader.preferences.snapshot([]), "rects": reader.rects.map(func(rect): return [rect.position.x, rect.position.y, rect.size.x, rect.size.y])}
	DirAccess.make_dir_recursive_absolute("user://diagnostics")
	var file := FileAccess.open("user://diagnostics/comic_" + str(command.request_key).validate_filename() + ".json", FileAccess.WRITE)
	if file: file.store_string(JSON.stringify(report, "  "))
