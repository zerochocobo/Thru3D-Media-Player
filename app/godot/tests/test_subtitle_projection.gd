extends SceneTree
const Patch := preload("res://scripts/projected_subtitles.gd")
const Depth := preload("res://scripts/subtitle_depth.gd")
var failures: Array[String] = []
var checks := 0

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func _initialize() -> void: call_deferred("_run")

func _run() -> void:
	var viewer := Vector3(0.3, 1.6, -0.2)
	for world_scale in [0.5, 1.0, 2.0]:
		for zoom in [-0.5, 0.0, 0.6]:
			var content := Basis.from_euler(Vector3(0.15, -0.4, 0))
			var surface := Transform3D(content, viewer + content * Vector3(0, 0, -zoom * 50))
			for vertical in [false, true]:
				for angle in [-60.0, 0.0, 60.0]:
					var anchor := Depth.anchor(angle, vertical)
					for requested_distance in [0.1, 1.0, 5.0, 10.0]:
						var plane := Patch.projection_plane(surface, anchor, requested_distance, viewer, world_scale)
						var expected_distance: float = clampf(requested_distance, 0.1, 5.0) * world_scale
						check(absf(plane.origin.distance_to(viewer) - expected_distance) < 0.00002, "Physical plane distance follows metres and XR world scale")
						check(plane.basis.orthonormalized().is_equal_approx(content * anchor), "Plane orientation remains anchored to the video")
						for corner in [Vector2(-0.35, -0.35), Vector2(0.35, -0.35), Vector2(-0.35, 0.35), Vector2(0.35, 0.35)]:
							var reference := surface * (anchor * Vector3(corner.x * 50, corner.y * 50, -50))
							var actual := plane * Vector3(corner.x, corner.y, 0)
							check((reference - viewer).normalized().cross((actual - viewer).normalized()).length() < 0.00001,
								"Full patch corners retain their video projection through zoom")
	for failure in failures: push_error(failure)
	print("Subtitle projection geometry checks=%d failures=%d" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
