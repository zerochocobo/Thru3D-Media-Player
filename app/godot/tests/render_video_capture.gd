extends SceneTree
const Menu := preload("res://scripts/player_menu.gd")
const Overlay := preload("res://scripts/capture_overlay.gd")
const I18n := preload("res://scripts/i18n.gd")
var failures: Array[String] = []
var checks := 0

func check(value: bool, message: String) -> void:
	checks += 1
	if not value: failures.append(message)

func _initialize() -> void: call_deferred("run")

func run() -> void:
	var output := ProjectSettings.globalize_path("res://../../build/output/original-capture/ui")
	DirAccess.make_dir_recursive_absolute(output)
	var viewport := SubViewport.new()
	viewport.size = Vector2i(1280, 900); viewport.own_world_3d = true; viewport.transparent_bg = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS; root.add_child(viewport)
	var camera := Camera3D.new(); camera.fov = 60; viewport.add_child(camera)
	var state := {"has_video": true, "geometry": 1, "playing": true, "playback_state": "playing", "stereo": true,
		"source_uri": "file:///travel.mp4", "title": "Travel · VR180", "position_ms": 30000, "duration_ms": 600000,
		"capture": {"available": true, "ready": true}}
	var menu := Menu.new(); menu.state_provider = func(): return state
	menu.favorite_provider = func(): return {"enabled": true, "selected": false}
	camera.add_child(menu); menu.position = Vector3(0, -0.25, -1.55)
	var overlay := Overlay.new(); camera.add_child(overlay)
	for language in ["en", "zh", "zh_Hant", "ja"]:
		I18n.use(language)
		for stage in ["hover", "recording", "paused-hidden", "saved-hidden", "exporting-hidden", "cancelling-hidden", "exists-hidden", "exists-long-hidden"]:
			menu.update_pointer("right_hand", Vector3.ZERO, Vector3.ZERO, false)
			overlay.update_pointer("right_hand", Vector3.ZERO, Vector3.ZERO, false)
			state.capture = {"available": true, "ready": true, "recording": stage in ["recording", "paused-hidden"], "paused": stage == "paused-hidden", "duration_ms": 72500}
			if stage == "saved-hidden": state.capture.notice = I18n.t("Saved to %s") % "Pictures/Thru3D" + "\nscreenshot_20261024_153012_345.jpg\n" + I18n.t("Find it in Library → Local")
			if stage in ["exporting-hidden", "cancelling-hidden"]: state.capture.merge({"clip_busy": true, "export_progress": 42, "export_cancellable": true, "export_cancelling": stage == "cancelling-hidden"})
			if stage == "exists-hidden": state.capture.notice = I18n.t("Already saved") + "\nMovies/Thru3D\nTravel_00-04-00.000--00-08-00.000.mkv"
			if stage == "exists-long-hidden": state.capture.notice = I18n.t("Already saved") + "\nMovies/Thru3D\n" + "影片".repeat(26) + "_00-04-00.000--00-08-00.000.mkv"
			menu.visible = not stage.ends_with("hidden")
			menu._capture_open = true; menu._capture_leave_ms = Time.get_ticks_msec(); menu.refresh()
			overlay.sync(state.capture)
			if stage in ["exporting-hidden", "cancelling-hidden"]:
				var button: Dictionary = overlay._buttons.filter(func(item): return item.target == Overlay.CANCEL)[0]
				var point: Vector2 = button.rect.get_center()
				overlay.update_pointer("right_hand", overlay.to_global(Vector3(point.x, point.y, 0.2)), -overlay.global_basis.z, true)
				check(button.enabled == (stage == "exporting-hidden"), language + " cancel action disabled while cleaning")
				if stage == "exporting-hidden": check(overlay._hover.get("right_hand", -1) == Overlay.CANCEL, language + " actual cancel ray hit")
				check(not menu.visible and overlay.visible, language + " clip cancel survives hidden transport")
			if stage == "hover":
				var button: Dictionary = menu._buttons.filter(func(item): return item.target == Menu.CAPTURE_RECORD)[0]
				var point: Vector2 = button.rect.get_center()
				menu.update_pointer("right_hand", menu.to_global(Vector3(point.x, point.y, 0.2)), -menu.global_basis.z, true)
				check(menu._hover.get("right_hand", -1) == Menu.CAPTURE_RECORD, language + " actual popup ray hit")
			if stage == "paused-hidden":
				var button: Dictionary = overlay._buttons.filter(func(item): return item.target == Overlay.STOP)[0]
				var point: Vector2 = button.rect.get_center()
				overlay.update_pointer("right_hand", overlay.to_global(Vector3(point.x, point.y, 0.2)), -overlay.global_basis.z, true)
				check(overlay._hover.get("right_hand", -1) == Overlay.STOP, language + " independent stop ray hit")
				check(not menu.visible and overlay.visible, language + " recording survives hidden transport")
			await process_frame
			for frame in 6: await RenderingServer.frame_post_draw
			var image := viewport.get_texture().get_image()
			if stage.begins_with("exists"):
				var label: Label3D = overlay._labels.filter(func(item): return item.text == state.capture.notice)[0]
				check(label.get_aabb().size.x <= 0.52, language + " full saved filename wraps within the status area")
			check(image.save_png(output.path_join(language + "-" + stage + ".png")) == OK, "Save " + stage)
			if stage in ["recording", "paused-hidden"]:
				var centre := camera.unproject_position(overlay.global_position)
				check(image.get_pixelv(Vector2i(centre)).a > 0.9, language + " indicator covers the transparent video underlay")
				var time_centre := Vector2i(camera.unproject_position(overlay._time.global_position))
				var ink := 0
				for y in range(time_centre.y - 12, time_centre.y + 12):
					for x in range(time_centre.x - 35, time_centre.x + 35):
						var pixel := image.get_pixel(x, y)
						if minf(pixel.r, minf(pixel.g, pixel.b)) > 0.65: ink += 1
				check(ink > 10, language + " clock has visible glyphs: " + str(ink))
	var report := {"state": "passed" if failures.is_empty() else "failed", "checks": checks, "failures": failures,
		"scope": "Production Godot capture controls and independent overlay; desktop OpenGL, no headset verification"}
	var file := FileAccess.open(output.path_join("verification.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "\t")); file.close()
	for failure in failures: push_error(failure)
	print("Capture UI render: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
