extends SceneTree

const Surface := preload("res://scripts/media_surface.gd")
const Photo := preload("res://scripts/photo_display.gd")
var failures: Array[String] = []
var checks := 0

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func _initialize() -> void: _run.call_deferred()

func _run() -> void:
	var surface := Surface.new()
	root.add_child(surface)
	var shader := Shader.new()
	shader.code = "shader_type spatial; render_mode unshaded; void fragment() { ALBEDO = vec3(1.0); }"
	surface.initialize_surface(shader)
	surface._screen_base = Vector2(3.2, 1.35)
	surface.set_screen_scale(1)
	surface.panel.visible = true
	surface.set_flat_world_pose(Transform3D(Basis.IDENTITY, Vector3(0, 0, -3)))
	for angle in [0.0, 0.1, 30.0, 76.4, 120.0, 160.0, 180.0]:
		surface.set_screen_curve(angle)
		var radius := surface._curve_radius()
		var corner := surface.screen_corner(1)
		var mesh := surface.panel.mesh
		for distance in [0.1, 2.0, 10.0, 50.0]:
			surface.set_screen_distance(distance)
			check(surface.screen_corner(1).is_equal_approx(corner) and surface.panel.mesh == mesh,
				"Moving distance does not reshape or rebuild the screen at %s degrees / %sm" % [angle, distance])
		if angle > 0:
			check(is_equal_approx(rad_to_deg(surface._flat.size.x / radius), angle), "Mesh spans the requested arc")
			surface.set_screen_scale(2)
			check(is_equal_approx(surface._curve_radius(), radius * 2) and surface.screen_corner(1).is_equal_approx(corner * 2), "Resizing scales the whole curved shape")
			surface.set_screen_scale(1)
		for uv in [Vector2(0.05, 0.2), Vector2(0.5, 0.5), Vector2(0.95, 0.8)]:
			var local := surface.surface_point(Vector3((uv.x - 0.5) * 3.2, (0.5 - uv.y) * 1.35, 0))
			var world := surface.panel.to_global(local)
			var hit: Variant = surface.screen_hit(Vector3.ZERO, world.normalized())
			check(hit != null and surface.surface_uv(surface.panel.to_local(hit)).distance_to(uv) < 0.0001, "Wide curved screen retains ray-to-UV mapping at %s / %s" % [angle, uv])
	surface.set_screen_curve(999)
	check(surface.screen_curve == 180, "Ordinary arc stops at a half cylinder")
	surface.set_screen_curve(NAN)
	check(surface.screen_curve == 180, "Invalid adjustment preserves the last valid arc")
	surface.set_screen_curve(47)
	surface.cycle_screen_curve()
	check(surface.screen_curve == 60, "Custom arc cycles to the next shortcut")
	var settings := ConfigFile.new()
	settings.set_value("screen", "curve", 0.7)
	surface.screen_distance = 2
	surface.restore_screen_curve(settings, "screen")
	surface._shape_screen()
	check(is_equal_approx(surface._curve_radius(), 2.0 / 0.7), "Legacy coefficient preserves its initial actual radius")
	var migrated := surface.screen_curve
	surface.set_screen_distance(8)
	check(surface.screen_curve == migrated and is_equal_approx(surface._curve_radius(), 2.0 / 0.7), "Migrated legacy curve no longer tracks distance")
	settings.set_value("screen", "curve_degrees", migrated)
	surface.restore_screen_curve(settings, "screen")
	surface._shape_screen()
	check(is_equal_approx(surface.screen_curve, migrated), "Degree setting takes priority over old coefficient")
	var host := preload("res://scripts/main.gd").new()
	host.video = surface
	host.settings.set_value("appearance", "cinema_curve", 0.7)
	check(is_equal_approx(host._cinema_curve(32), rad_to_deg(32.0 / 35.0)), "Legacy cinema Medium retains its original 35m radius")
	check(host._cinema_curve(12.8) <= rad_to_deg(12.8 / 24.0), "Cinema legacy arc is bounded when picture shrinks")
	check(is_equal_approx(host._cinema_curve(32), rad_to_deg(32.0 / 35.0)), "Cinema remembers the chosen arc after bounded shrinking")
	host.free()
	surface.free()
	var photo := Photo.new()
	root.add_child(photo)
	photo.set_process(false)
	photo._size = Vector2(2400, 1000)
	photo._apply_geometry()
	photo.set_screen_curve(160)
	for rotation in [0.0, 45.0, 90.0]:
		photo.set_screen_rotation(rotation)
		var radius := photo._curve_radius()
		var corner := photo.screen_corner(1)
		photo.set_screen_distance(0.1)
		photo.set_screen_distance(30)
		check(is_equal_approx(photo._curve_radius(), radius) and photo.screen_corner(1).is_equal_approx(corner), "Rotated photo curve stays fixed when distance changes")
		check(is_equal_approx(rad_to_deg(Surface.curve_span(photo._flat.size, deg_to_rad(rotation)) / radius), 160), "Photo bend uses horizontal rotated span")
	photo.free()
	for failure in failures: push_error(failure)
	print("Screen curve: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
