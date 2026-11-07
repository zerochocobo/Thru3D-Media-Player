extends SceneTree

const Video := preload("res://scripts/mpv_video_display.gd")
const Sphere := preload("res://scripts/screen_sphere.gd")
var checks := 0
var failures: Array[String] = []

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func _initialize() -> void: _run.call_deferred()

func _run() -> void:
	var video := Video.new(); root.add_child(video); video.set_process(false)
	video.set_curve_modes_available(true)
	video.panel.visible = true
	video.set_flat_world_pose(Transform3D(Basis.IDENTITY, Vector3(0, 0, -3)))
	for dimensions in [Vector2(1920, 1080), Vector2(1080, 1920)]:
		video.media.format = {"width": dimensions.x, "height": dimensions.y}
		for layout in [[false, false], [true, false], [true, true]]:
			video.stereo_sbs = layout[0]; video.top_bottom = layout[1]
			for mode in ["horizontal", "vertical", "spherical"]:
				video.set_screen_curve_mode(mode)
				for angle in [0.0, 0.1, 90.0, 180.0]:
					video.set_screen_curve(angle)
					for rotation in [0.0, 90.0, 45.0, 180.0]:
						video.set_screen_rotation(rotation)
						video.set_screen_distance(3)
						var context := "%s/%s/%s/%s/%s" % [dimensions, layout, mode, angle, rotation]
						var size: Vector2 = video._flat.size
						var roll := Basis(Vector3.FORWARD, deg_to_rad(rotation))
						var radius: float = video._curve_radius()
						var arrays: Array = video.panel.mesh.surface_get_arrays(0)
						var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
						var finite := true
						var sphere := true
						for i in vertices.size():
							finite = finite and vertices[i].is_finite()
							if mode == "spherical" and angle > 0:
								sphere = sphere and absf(vertices[i].distance_to(Vector3(0, 0, radius)) - radius) < 0.0002
						check(finite and vertices.size() <= 2500, "Finite mobile mesh: " + context)
						if mode == "spherical" and angle > 0:
							check(sphere, "Every vertex belongs to one true sphere: " + context)
							check(is_equal_approx(radius * deg_to_rad(angle), size.length()), "Sphere angle spans its diagonal: " + context)
						for at in [Vector2(0.15, 0.2), Vector2(0.5, 0.5), Vector2(0.85, 0.8)]:
							var flat := Vector3((at.x - 0.5) * size.x, (0.5 - at.y) * size.y, 0)
							var point: Vector3 = video.surface_point(flat)
							var view: Vector3 = roll * flat
							var bent: Vector3 = roll * point
							if angle > 0 and mode != "spherical":
								var span: float = absf(cos(deg_to_rad(rotation))) * size.x + absf(sin(deg_to_rad(rotation))) * size.y if mode == "horizontal" else absf(sin(deg_to_rad(rotation))) * size.x + absf(cos(deg_to_rad(rotation))) * size.y
								check(is_equal_approx(radius * deg_to_rad(angle), span), "Arc spans the selected viewing axis: " + context)
								if mode == "horizontal":
									check(is_equal_approx(bent.y, view.y) and absf(bent.x - radius * sin(view.x / radius)) < 0.0001, "Left/right stays horizontal after rotation: " + context)
								else:
									check(is_equal_approx(bent.x, view.x) and absf(bent.y - radius * sin(view.y / radius)) < 0.0001, "Up/down stays vertical after rotation: " + context)
							check(video.surface_uv(point).distance_to(at) < 0.0001, "UV inverse: " + context)
							var world: Vector3 = video.panel.to_global(point)
							var hit: Variant = video.screen_uv(Vector3.ZERO, world.normalized())
							check(hit != null and hit.distance_to(at) < 0.0003, "Playback ray reaches source pixel: " + context)
							var pip: Dictionary = video.pip.source_hit(Vector3.ZERO, world.normalized())
							check(not pip.is_empty() and (pip.center as Vector2).distance_to(at) < 0.0003, "PiP source selection agrees: " + context)
							for direction in [Vector3.RIGHT, Vector3.UP]:
								var delta := 0.001
								var numerical: Vector3 = (video.surface_point(flat + direction * delta) - video.surface_point(flat - direction * delta)) / (2 * delta)
								check(video.surface_tangent(flat, direction).distance_to(numerical) < 0.002, "Surface attachment tangent: " + context)
						var compatible: bool = angle == 0 or (mode == "horizontal" and rotation in [0.0, 180.0]) or (mode == "vertical" and rotation == 90.0)
						check(video.cylinder_layer_compatible() == compatible, "Only equivalent geometry enters the native cylinder: " + context)
						if angle > 0:
							var corner: Vector3 = video.screen_corner(1)
							var mesh: Mesh = video.panel.mesh
							video.set_screen_distance(12)
							check(video.panel.mesh == mesh and video.screen_corner(1).is_equal_approx(corner), "Push/pull preserves shape: " + context)
							video.set_screen_scale(2)
							check(video.screen_corner(1).distance_to(corner * 2) < 0.0001, "Resize scales the whole surface: " + context)
							video.set_screen_scale(1)
						# A rotated subtitle surface must occupy exactly the movie mesh.
						if angle > 0 and rotation in [90.0, 45.0]:
							var captions: PackedVector3Array = video._upright_subtitle_mesh().surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
							var aligned := captions.size() == vertices.size()
							for i in captions.size():
								if i < vertices.size(): aligned = aligned and (video.subtitle_transform() * captions[i]).distance_to(video.panel.to_global(vertices[i])) < 0.0001
							check(aligned, "Upright captions follow the exact surface: " + context)
	# Half-sphere has no back-face hit or continuation beyond the rectangular patch.
	check(Sphere.hit(Vector2(2, 1), 2, Vector3(0, 0, 5), Vector3.BACK) == null, "A ray pointing away cannot select the sphere")
	check(Sphere.hit(Vector2(2, 1), 2, Vector3(3, 0, 1), Vector3.FORWARD) == null, "Finite patch excludes the surrounding sphere")
	var settings := ConfigFile.new()
	settings.set_value("screen", "curve_mode", "spherical")
	video.restore_screen_curve(settings, "screen")
	check(video.screen_curve_mode == "spherical", "Saved sphere choice restores")
	settings.set_value("screen", "curve_mode", "invalid")
	video.restore_screen_curve(settings, "screen")
	check(video.screen_curve_mode == "horizontal", "Unknown saved choice uses the original mode")
	check(not video.set_screen_curve_mode("invalid"), "Unknown UI choice is rejected")
	video.set_screen_curve_mode("spherical"); video.set_curve_modes_available(false)
	check(video.effective_curve_mode() == "horizontal" and video.screen_curve_mode == "spherical", "Leaving supported scenery suspends the mode without forgetting it")
	video.set_curve_modes_available(true)
	check(video.effective_curve_mode() == "spherical", "Returning restores the selected mode")
	video.free()
	for failure in failures: push_error(failure)
	print("Screen curve modes: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
