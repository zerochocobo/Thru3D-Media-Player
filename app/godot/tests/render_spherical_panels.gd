extends SceneTree
const Player := preload("res://scripts/player_menu.gd")
const Library := preload("res://scripts/library_menu.gd")
const Capture := preload("res://scripts/menu_composition.gd")
const I18n := preload("res://scripts/i18n.gd")
var failures: Array[String] = []
var checks := 0
var output := OS.get_environment("THRU3D_SPHERICAL_PREVIEWS")
var state := {"has_video": true, "title": "Travel journal · 旅行日记", "playing": true, "playback_state": "playing",
	"source_uri": "file:///layout.mp4", "position_ms": 120000, "duration_ms": 600000, "geometry": 0,
	"audio_available": true, "volume": 80, "alpha_requested": true, "capabilities_available": true,
	"layer_available": true, "grade_on_layer": true, "alpha_fps": 30, "playback_speed": 1.0,
	"source_size": "3840 × 2160", "codec": "hevc"}

class Catalog extends RefCounted:
	func list_recent() -> Array[Dictionary]:
		var rows: Array[Dictionary] = []
		for index in 16: rows.append({"uri": "file:///video-%d.mp4" % index, "title": "Travel %02d · 旅行日记" % index, "position_ms": index * 11000})
		return rows

func _initialize() -> void: run.call_deferred()
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)
func frames() -> void:
	for index in 3:
		await process_frame; await RenderingServer.frame_post_draw

func run() -> void:
	if output.is_empty(): quit(2); return
	DirAccess.make_dir_recursive_absolute(output)
	var viewport := SubViewport.new(); viewport.size = Vector2i(1600, 1200); viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS; root.add_child(viewport)
	var origin := Node3D.new(); viewport.add_child(origin)
	var camera := Camera3D.new(); camera.fov = 90; origin.add_child(camera)
	var world := WorldEnvironment.new(); world.environment = Environment.new(); viewport.add_child(world)
	world.environment.background_mode = Environment.BG_COLOR; world.environment.background_color = Color(0.035, 0.04, 0.05)
	var display := preload("res://scripts/xr_display.gd").new(); display.configure(viewport, world.environment, null, true)
	var menu := Player.new(); origin.add_child(menu); menu.set_process(false); menu.state_provider = func(): return state
	menu.position = Vector3(0, -0.45, -1.4); menu.set_layout_viewer(camera.global_transform); menu.toggle()
	var library := Library.new(); origin.add_child(library); library.catalog = Catalog.new(); library.set_process(false)
	menu.expanded_library = library; library.reparent(menu, false)
	for language in ["en", "zh", "zh_Hant", "ja"]:
		I18n.use(language)
		for mode in ["bar", "settings", "settings-alpha", "screen", "playback-choices", "compact", "expanded", "error"]:
			library.visible = false; menu._reset_navigation(); state.erase("error")
			state.geometry = 1 if mode == "settings-alpha" else 0
			if mode in ["settings", "settings-alpha", "playback-choices"]: menu.section = 1
			if mode == "screen": menu._adjustment = "screen"
			if mode == "error": state.error = "The network connection was lost"; menu._failure_open = true
			menu.refresh()
			if mode == "screen":
				check(menu._buttons.filter(func(item): return item.target >= Player.SCREEN_CURVE and item.target < Player.SCREEN_CURVE + Player.Surface.CURVES.size()).size() == Player.Surface.CURVES.size(), "Screen curves use the current inline options")
			if mode == "playback-choices":
				var openers: Array = menu.choices.targets.keys().filter(func(id): return menu.choices.targets[id].get("kind", "") == "open" and menu.choices.targets[id].get("key", "") == "playback_mode")
				check(openers.size() == 1, "Playback mode has a dropdown entry")
				if openers.size() == 1:
					var item: Dictionary = menu._buttons.filter(func(button): return button.target == openers[0])[0]
					var ray_origin: Vector3 = item.node.to_global(Vector3(0, 0, 0.4))
					var ray_direction: Vector3 = -item.node.global_basis.z
					menu.press_pointer("right_hand", ray_origin, ray_direction, true)
					menu.release_pointer("right_hand", ray_origin, ray_direction, true)
				check(not menu.choices.popup.is_empty() and menu.choices.targets.values().any(func(item): return item.get("kind", "") == "choose" and item.get("key", "") == "playback_mode"), "Ray opens the actual playback mode dropdown")
			if mode in ["compact", "expanded"]:
				library.playback_expanded = mode == "expanded"; library.set_compact(mode == "compact"); library.visible = true; library.refresh()
			await frames()
			# The complete interactive footprints fit in the camera, including floating actions.
			for owner in [menu, library] if library.visible else [menu]:
				for button in owner._buttons:
					if not button.node.is_visible_in_tree(): continue
					var half: Vector2 = button.rect.size / 2
					for p in [Vector3(-half.x, -half.y, 0), Vector3(half.x, half.y, 0)]:
						var projected := camera.unproject_position(button.node.to_global(p))
						check(Rect2(Vector2.ZERO, Vector2(viewport.size)).has_point(projected), "%s/%s target %d stays visible" % [language, mode, button.target])
			var image := viewport.get_texture().get_image()
			check(image.save_png(output.path_join("%s-%s.png" % [language, mode])) == OK, "Save actual menu preview")
			var capture := Capture.new(); viewport.add_child(capture)
			capture.configure(origin, camera, display, [menu, library], false, true); capture.set_process(false)
			capture.update(); await frames(); capture.update(); await frames()
			check(capture.snapshot().active, "Compositor capture active for " + mode)
			check(capture.snapshot().layers <= Capture.MAX_GROUPS, "Spherical layout respects the layer budget")
			if mode == "playback-choices": check(capture.snapshot().layers >= 3, "Raised choices keep a separate compositor layer")
			var surfaces: Array = [menu._backdrop]
			for surface in menu._popup_surfaces: surfaces.append(surface.get_child(0))
			if library.visible: surfaces.append(library._backdrop)
			for surface in surfaces:
				var found := false
				for slot in capture.slots:
					if slot.used and slot.nodes.has(surface):
						found = true
						check(slot.layer.global_basis.z.angle_to(surface.global_basis.z) < 0.01, "Compositor retains each surface's independent normal")
				check(found, "%s/%s surface has a compositor layer" % [language, mode])
			capture.free(); await process_frame
	var report := {"checks": checks, "failures": failures, "state": "passed" if failures.is_empty() else "failed", "headset_verified": false}
	var file := FileAccess.open(output.path_join("verification.json"), FileAccess.WRITE); file.store_string(JSON.stringify(report, "  ")); file.close()
	for failure in failures: push_error(failure)
	print("Spherical panel GPU previews: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
