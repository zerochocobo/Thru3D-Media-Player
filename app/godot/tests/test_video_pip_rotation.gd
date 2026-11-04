extends SceneTree
const Fixture := preload("res://tests/test_video_pip.gd")
const Recipe := preload("res://scripts/pip_screenshot.gd")
const Atlas := preload("res://scripts/video_pip_compositor.gd")
var checks := 0
var failures: Array[String] = []

class FlatSurface extends Fixture.Surface:
	var dimensions := Vector2(1920, 1080)
	func _source_size() -> Vector2: return dimensions

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func _initialize() -> void: call_deferred("run")

func run() -> void:
	var video := FlatSurface.new(); root.add_child(video)
	var pip: RefCounted = video.pip
	var head := Transform3D(Basis.IDENTITY, Vector3(0, 1.6, 0))
	var still := ImageTexture.create_from_image(Image.create(32, 32, false, Image.FORMAT_RGBA8))
	for geometry in [1, 2, 3]:
		video.geometry = geometry; video._apply_geometry()
		pip.set_count(3, head); pip.sync()
		var selected := [Vector3.FORWARD, Vector3(0.35, 0.2, -1).normalized(), Vector3(-0.4, -0.3, -1).normalized()]
		var poses: Array = []
		for slot in [1, 2, 3]:
			var window: Node3D = pip.windows[slot]
			window.crop_basis = pip.view_basis(selected[slot - 1]); window.zoom = float(slot)
			poses.append(window.global_transform)
		for rotation in [Vector3.ZERO, Vector3(0, 0, 90), Vector3(0, 0, -90), Vector3(0.45, -0.6, 38), Vector3(-0.7, 0.8, -52), Vector3.ZERO]:
			video.view_yaw = rotation.y; video.view_pitch = rotation.x
			video.set_screen_rotation(rotation.z); pip.sync()
			for slot in [1, 2, 3]:
				var window: Node3D = pip.windows[slot]
				var forward: Vector3 = window.picture.get_shader_parameter("pip_forward")
				var up: Vector3 = video.panel.global_basis * window.picture.get_shader_parameter("pip_up")
				var world_forward: Vector3 = video.panel.global_basis * selected[slot - 1]
				var expected_up := (Vector3.UP - world_forward * Vector3.UP.dot(world_forward)).normalized()
				check(forward.is_equal_approx(selected[slot - 1]), "Rotation keeps the selected source point: %s/%s/%s" % [geometry, slot, rotation])
				check(up.is_equal_approx(expected_up), "Crop camera stays world upright while movie rotates: %s/%s/%s" % [geometry, slot, rotation])
				check(window.global_transform.is_equal_approx(poses[slot - 1]) and window.zoom == float(slot), "Rotation preserves window placement and zoom")
				var recipe: Dictionary = Recipe.snapshot(video).windows[slot - 1]
				check(Vector3(recipe.crop[6], recipe.crop[7], recipe.crop[8]).is_equal_approx(window.picture.get_shader_parameter("pip_up")), "Capture consumes the displayed rotated crop")
		var first: Node3D = pip.windows[1]
		var before := Atlas.parameters(first.picture, Atlas.WINDOW)
		video.set_screen_rotation(70); pip.sync()
		check(before != Atlas.parameters(first.picture, Atlas.WINDOW), "Rotation invalidates native atlas crop key even on a paused source")
		# Preview and outline use the same transformed axes, without committing hover.
		pip.selecting = 1
		var point: Vector3 = video.panel.to_global(selected[1] * video.SPHERE_RADIUS)
		pip.candidate = pip.source_hit(video.panel.global_position, (point - video.panel.global_position).normalized())
		pip._draw_selection(); pip.sync()
		var arrays: Array = pip._outline.mesh.surface_get_arrays(0)
		var tangent: Vector2 = first.tangent()
		var preview := Basis(first.picture.get_shader_parameter("pip_right"), first.picture.get_shader_parameter("pip_up"), -first.picture.get_shader_parameter("pip_forward"))
		var expected: Vector3 = video.panel.to_global((preview * Vector3(-tangent.x, tangent.y, -1)).normalized() * (video.SPHERE_RADIUS - 0.01))
		check(pip._outline.to_global(arrays[Mesh.ARRAY_VERTEX][0]).distance_to(expected) < 0.0001, "Selection outline matches rotated preview")
		check((-first.crop_basis.z).is_equal_approx(selected[0]), "Hover does not change committed source point")
		pip.cancel_interaction(); pip.sync()
		check((first.picture.get_shader_parameter("pip_forward") as Vector3).is_equal_approx(selected[0]), "Cancel restores the committed point with current orientation")
		first.show_image(still)
		var image_pose: Transform3D = first.global_transform
		video.set_screen_rotation(-30); pip.sync()
		check(first.global_transform == image_pose and first.image_mode, "Image windows remain independent of movie rotation")
		first.restore_video(); pip.sync()
		check((first.picture.get_shader_parameter("pip_up") as Vector3).is_equal_approx(first.sampling_basis().y), "Returning to video immediately uses current rotation")
		# Stable pole fallback must remain finite and orthonormal.
		video.panel.global_basis = Basis.IDENTITY
		for direction in [Vector3.UP, Vector3.DOWN]:
			first.crop_basis = pip.view_basis(direction); first.crop_parameters()
			var sample: Basis = first.sampling_basis()
			check(sample.is_finite() and is_equal_approx(sample.determinant(), 1.0) and (-sample.z).is_equal_approx(direction), "Pole crop remains a valid camera basis")
		pip.clear()
	check_flat(video, head)
	pip.clear(); video.queue_free(); await process_frame
	for failure in failures: push_error(failure)
	print("Video PiP rotation: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)

func check_flat(video: Node3D, head: Transform3D) -> void:
	var pip: RefCounted = video.pip
	var still := ImageTexture.create_from_image(Image.create(32, 32, false, Image.FORMAT_RGBA8))
	video.geometry = 0
	for dimensions in [Vector2(1920, 1080), Vector2(1080, 1920), Vector2(1000, 1000)]:
		video.dimensions = dimensions
		for layout in [[false, false, false], [true, false, false], [true, true, false], [true, false, true], [true, true, true]]:
			video.stereo_sbs = layout[0]; video.top_bottom = layout[1]; video.stereo_half = layout[2]
			video.set_screen_rotation(0); pip.set_count(3, head); pip.sync()
			var poses: Array = []
			var centers: Array = []
			for slot in [1, 2, 3]:
				var window: Node3D = pip.windows[slot]
				window.zoom = float(slot); window.crop_center = Vector2(0.3, 0.6) if slot == 1 else Vector2(0.99, 0.01)
				poses.append(window.global_transform); centers.append(window.flat_crop().center)
			for angle in [0, 90, -90, 37, -53, 0]:
				video.set_screen_rotation(angle); pip.sync()
				for slot in [1, 2, 3]:
					var window: Node3D = pip.windows[slot]
					var right: Vector3 = window.picture.get_shader_parameter("pip_right")
					var down: Vector3 = window.picture.get_shader_parameter("pip_up")
					var aspect: float = window.source_aspect
					# Independent invariant: mapping a UV step back onto the main screen
					# yields world horizontal/down, with unchanged physical scale.
					var world_right: Vector3 = video.panel.global_basis * Vector3(right.x * aspect, -right.y, 0)
					var world_down: Vector3 = video.panel.global_basis * Vector3(down.x * aspect, -down.y, 0)
					check(world_right.is_equal_approx(Vector3.RIGHT * aspect) and world_down.is_equal_approx(Vector3.DOWN), "Flat crop rotates without stretching for source/layout/angle %s/%s/%s" % [dimensions, layout, angle])
					check((window.picture.get_shader_parameter("pip_center") as Vector2).is_equal_approx(centers[slot - 1]), "Rotation never moves the crop centre, including edge selections")
					check(window.global_transform.is_equal_approx(poses[slot - 1]) and window.zoom == float(slot), "Flat movie rotation keeps all window placements and zooms")
			var first: Node3D = pip.windows[1]
			var before := Atlas.parameters(first.picture, Atlas.WINDOW)
			video.set_screen_rotation(45); pip.sync()
			check(before != Atlas.parameters(first.picture, Atlas.WINDOW), "Paused flat crop invalidates native atlas parameters")
			first.show_image(still)
			video.set_screen_rotation(-45); pip.sync()
			check(first.global_transform.is_equal_approx(poses[0]), "Image window remains fixed while flat movie rotates")
			first.restore_video(); pip.sync()
			check((first.picture.get_shader_parameter("pip_right") as Vector3).y > 0, "Returning to flat video uses its latest rotation")
			# Straight and curved screens draw selection with the same rotated UVs.
			for curve in [0.0, 0.7]:
				video.screen_curve = curve; video._apply_geometry(); pip.sync()
				pip.selecting = 1; pip.candidate = {"center": Vector2(0.5, 0.5)}
				pip._draw_selection(); pip.sync()
				var arrays: Array = pip._outline.mesh.surface_get_arrays(0)
				var local: Vector3 = video.panel.to_local(pip._outline.to_global(arrays[Mesh.ARRAY_VERTEX][0]))
				if curve > 0:
					var radius: float = video._curve_radius()
					local.x = atan2(local.x, radius - (local.z - 0.004)) * radius
				var uv := Vector2(local.x / video._flat.size.x + 0.5, 0.5 - local.y / video._flat.size.y)
				var span: Vector2 = first.picture.get_shader_parameter("pip_span")
				var right: Vector3 = first.picture.get_shader_parameter("pip_right")
				var down: Vector3 = first.picture.get_shader_parameter("pip_up")
				check(uv.distance_to(Vector2(0.5, 0.5) - Vector2(right.x, right.y) * span.x / 2 - Vector2(down.x, down.y) * span.y / 2) < 0.0001, "Flat/curved selection outline matches the displayed rotated crop")
				pip.cancel_interaction()
			video.screen_curve = 0; pip.clear()
