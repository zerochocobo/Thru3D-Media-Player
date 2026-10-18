extends SceneTree
const Depth := preload("res://scripts/subtitle_depth.gd")
const Menu := preload("res://scripts/player_menu.gd")
var failures: Array[String] = []
var state := {"has_video": true, "geometry": 1, "subtitle_distance": 5.0, "subtitle_position": 0.0}
var saves: Array = []
var checks := 0

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func _initialize() -> void: call_deferred("_run")

func _run() -> void:
	var settings := ConfigFile.new()
	check(Depth.restore_position(settings) == 0, "New settings default to centre")
	for index in 5:
		settings.set_value("subtitles", "position", index)
		check(is_equal_approx(Depth.elevation(Depth.restore_position(settings)), [0.488, 0.244, 0.0, -0.244, -0.488][index]), "Legacy position retains its angle")
	settings.set_value("subtitles", "elevation_degrees", 45.0)
	check(Depth.restore_position(settings) == 45, "New angle overrides legacy index")
	var restored := ConfigFile.new()
	restored.parse(settings.encode_to_text())
	check(Depth.restore_position(restored) == 45, "Angle persists across reload")
	check(Depth.position(INF) == 0 and Depth.position(-100) == -60 and Depth.position(100) == 60, "Angle validation")
	for angle in [-60.0, 0.0, 60.0]:
		var direction := Basis(Vector3.RIGHT, Depth.elevation(angle)) * Vector3.FORWARD
		check(is_equal_approx(direction.y, sin(deg_to_rad(angle))), "Positive angle points up, negative down")
	check(Depth.distance(15) == 5 and is_equal_approx(Depth.distance(0.1), 0.1), "Distance bounds are 0.1m to 5m")
	for old_distance in [-1.0, 0.0, 0.1]:
		check(is_equal_approx(Depth.distance(old_distance), 0.1) and Depth.slider_fraction(old_distance) == 0, "Values below 0.1m clamp to the lower endpoint")
	for near_distance in [0.5, 0.99]:
		check(Depth.distance(near_distance) == near_distance and Depth.slider_fraction(near_distance) > 0, "Submeter distances remain available for projection tests")
	check(Depth.distance(INF) == Depth.DEFAULT and Depth.distance(NAN) == Depth.DEFAULT, "Non-finite distances restore the default")
	check(is_equal_approx(Depth.slider_distance(0), 0.1) and Depth.slider_distance(1) == 5 and is_equal_approx(Depth.slider_distance(-1), 0.1), "Distance rail spans 0.1m to 5m")
	var distance_row := Depth.slider_row("subtitle_distance", 0.1)
	check(distance_row.span == Vector3(0.1, 5, 0.1) and is_equal_approx(distance_row.value, 0.1), "Shared menu distance row allows the nearest test distance")
	var menu := Menu.new()
	menu.state_provider = func(): return state
	menu.adjustment_requested.connect(func(key, value): state[key] = value.value if value is Dictionary else value)
	menu.setting_requested.connect(func(key, value): state[key] = value.value if value is Dictionary else value; saves.append([key, value]))
	root.add_child(menu)
	menu.toggle()
	menu._activate(110)
	check(menu.choices.sliders.is_empty() and not menu._subtitle_appearance_open, "CC opens with appearance collapsed")
	menu._activate(Menu.SUBTITLE_APPEARANCE)
	check(menu.choices.sliders.size() == 4 and menu.choices.opened.is_empty(), "CC uses sync, angle, distance and text-size sliders")
	for target in menu.choices.sliders.keys():
		var slider: Dictionary = menu.choices.sliders[target]
		var key: String = menu.choices.targets[target].key
		var centre: Vector3 = menu.to_local(slider.node.global_position)
		var start := Vector3(centre.x + slider.left, centre.y, 1)
		var end := Vector3(start.x + slider.width, start.y, 1)
		var before := saves.size()
		check(menu.press_pointer("right", menu.to_global(start), -menu.global_basis.z, true), "Ray captures rail")
		check(is_equal_approx(state[key], slider.span.x) and saves.size() == before and menu.has_pointer_capture(), "Press previews lower endpoint without saving")
		menu.update_pointer("left", menu.to_global(end), -menu.global_basis.z, true)
		check(is_equal_approx(state[key], slider.span.x), "Other hand cannot change captured slider")
		menu.refresh_values()
		menu.update_pointer("right", menu.to_global(end), -menu.global_basis.z, true)
		check(is_equal_approx(state[key], slider.span.y), "Drag survives menu redraw and reaches upper endpoint")
		menu.release_pointer("left", Vector3.ZERO, Vector3.ZERO, false)
		check(menu.has_pointer_capture(), "Other hand cannot release captured rail")
		menu.release_pointer("right", Vector3.ZERO, Vector3.ZERO, false)
		check(saves.size() == before + 1 and not menu.has_pointer_capture(), "Tracking loss commits last preview once")
	# Closing an active drag also saves once.
	var target: int = menu.choices.sliders.keys().filter(func(id): return menu.choices.targets[id].key == "subtitle_position")[0]
	var slider: Dictionary = menu.choices.sliders[target]
	var centre: Vector3 = menu.to_local(slider.node.global_position)
	var point := Vector3(centre.x + slider.left + slider.width / 2, centre.y, 1)
	menu.press_pointer("right", menu.to_global(point), -menu.global_basis.z, true)
	check(state.subtitle_position == 0, "Angle midpoint returns to centre")
	var before := saves.size()
	menu.dismiss()
	check(saves.size() == before + 1 and not menu.has_pointer_capture(), "Dismiss saves and clears slider capture")
	state.geometry = 0
	state.source_uri = "file:///movie.mkv"
	state.subtitle_track = 1
	state.subtitle_options = []
	for index in 8: state.subtitle_options.append({"id": index + 1, "title": "Track %d" % index, "codec": "hdmv_pgs_subtitle"})
	menu.subtitle_requested.connect(func(id): state.subtitle_track = id)
	menu.toggle(); menu._activate(110); menu._activate(Menu.SUBTITLE_APPEARANCE)
	check(menu.choices.sliders.size() == 3 and not menu.choices.targets.values().any(func(item): return item.get("key") == "subtitle_style"), "PGS has sync, size and position with no text-only style")
	var blocker: Dictionary = menu._ray_blockers[0]
	var top: float = blocker.node.position.y + blocker.rect.size.y / 2.0
	for point_local in [Vector3(-0.51, top - 0.35, 1), Vector3(0, top - 0.23, 1), Vector3(0, 0.30, 1)]:
		var origin := menu.to_global(point_local)
		var hit := menu.ray_hit(origin, -menu.global_basis.z)
		check(not hit.is_empty() and not hit.enabled and hit.target == menu.NONE, "Panel margin/row gap stops the ray")
		check(menu.press_pointer("right", origin, -menu.global_basis.z, true) and menu._subtitle_open and menu.visible, "Blank press is consumed without dismissing subtitles")
	var row: Dictionary = menu._buttons.filter(func(button): return button.target == Menu.SUBTITLE_ROW + 2)[0]
	var row_origin: Vector3 = row.node.to_global(Vector3(0, 0, 1))
	check(menu.ray_hit(row_origin, -menu.global_basis.z).target == row.target, "Track in front of the surface stays selectable")
	menu.press_pointer("right", row_origin, -menu.global_basis.z, true)
	menu.release_pointer("right", row_origin, -menu.global_basis.z, true)
	check(state.subtitle_track == 2 and menu._subtitle_open and menu._subtitle_appearance_open, "Selecting a track retains the adjustment panel")
	menu.stick_scroll(-1, 0.5)
	check(menu._subtitle_offset > 0 and not menu.allows_playback_sticks(), "Many-track list scrolls while playback shortcuts remain isolated")
	menu._activate(Menu.SUBTITLE_AUTO)
	check(state.subtitle_auto_load == false and menu._subtitle_open, "Automatic loading switch changes only its setting and stays open")
	menu._activate(Menu.SUBTITLE_CLOSE)
	check(not menu._subtitle_open and menu.visible and menu.allows_playback_sticks(), "Explicit close returns to the normal transport bar")
	menu.free()
	for failure in failures: push_error(failure)
	print("Subtitle slider checks=", checks, " failures=", failures.size())
	quit(0 if failures.is_empty() else 1)
