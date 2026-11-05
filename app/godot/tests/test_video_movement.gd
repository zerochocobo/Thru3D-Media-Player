extends SceneTree
## Production flat-video movement, with synthetic tracking and no decoder or XR session.
const Video := preload("res://scripts/mpv_video_display.gd")
var checks := 0
var failures: Array[String] = []

class InputMain extends "res://scripts/main.gd":
	var head := Transform3D(Basis.IDENTITY, Vector3(0, 1.6, 0))
	var controller := Transform3D.IDENTITY
	var ray: Array = []
	func _head_pose() -> Variant: return head
	func _eye() -> Vector3: return head.origin
	func _move_pose(_hand: String) -> Variant: return controller
	func _ray(_hand: String) -> Variant: return ray

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func _initialize() -> void: call_deferred("run")

func run() -> void:
	var main := InputMain.new()
	var video := Video.new(); video.history_enabled = false
	root.add_child(video); video.set_process(false); main.video = video
	video.local_uri = "file:///movement.mp4"
	video.media.begin(1); video.media.format = {"width": 1920, "height": 1080}
	video.panel.visible = true
	for following in [false, true]:
		main.view_follow.enabled = following
		main.head.basis = Basis.from_euler(Vector3(0.3, 0.4, 0.6)) if following else Basis.IDENTITY
		var frame := main.head if following else Transform3D(Basis.IDENTITY, main.head.origin)
		for curve in [0.0, 0.7]:
			video.screen_curve = curve
			for rotation in [0.0, 90.0]:
				video.screen_rotation = rotation; video._apply_geometry()
				for pitch in [-1.3, -0.6, 0.0, 0.6, 1.3]:
					var basis := Basis(Vector3.RIGHT, pitch)
					var initial := frame * Transform3D(basis, basis * Vector3(0, 0, -3))
					var label := "follow=%s curve=%s rotation=%s pitch=%s" % [following, curve, rotation, pitch]
					video.set_flat_world_pose(initial)
					# Hand-pointer dragging uses this shared route; physical video triggers are UI-only.
					for step in 80:
						main._turn_picture(0.025 if step < 40 else -0.025, 0.0)
						check_pose(video, frame, rotation, "Hand drag " + label)
					var return_offset: Transform3D = initial.affine_inverse() * video.flat_pose
					check(return_offset.origin.length() < 0.0001 and return_offset.basis.get_rotation_quaternion().get_angle() < 0.0001, "Hand drag returns to initial pose: %s offset=%s rotation=%s" % [label, return_offset.origin, return_offset.basis.get_euler()])
					for hand in ["left_hand", "right_hand"]:
						video.set_flat_world_pose(initial)
						for grab in 8:
							var point := video.panel.to_global(Vector3(0.12, -0.08, 0))
							main.controller = main.InterfaceMove.ray_pose(main.head.origin, point - main.head.origin)
							main.ray = [main.head.origin, (point - main.head.origin).normalized()]
							main._begin_interface_move(hand, "grip_click")
							check(not main.interface_move.capture.is_empty(), "Real off-centre video hit starts grip: " + label)
							if main.interface_move.capture.is_empty(): continue
							for step in 12:
								main.controller.basis = Basis(frame.basis.y, 0.025 if grab < 4 else -0.025) * main.controller.basis
								main.interface_move.update(main.controller, main.head, main.view_follow)
								check_pose(video, frame, rotation, "Repeated grip " + hand + " " + label)
							main.interface_move.cancel()
	# Immersive video keeps its independent yaw/pitch projection path.
	main.view_follow.enabled = false; main.head.basis = Basis.IDENTITY
	video.screen_rotation = 90.0
	for geometry in [video.Geometry.Geometry.HALF_EQUIRECT, video.Geometry.Geometry.EQUIRECT_360, video.Geometry.Geometry.FISHEYE]:
		video.geometry = geometry; video._apply_geometry()
		var flat_before: Transform3D = video.flat_pose
		var yaw_before: float = video.view_yaw; var pitch_before: float = video.view_pitch
		main._turn_picture(0.2, 0.1)
		check(is_equal_approx(video.view_yaw, yaw_before + 0.2) and is_equal_approx(video.view_pitch, pitch_before + 0.1), "Immersive projection still turns its view")
		check(video.flat_pose.is_equal_approx(flat_before) and video.screen_rotation == 90.0, "Immersive turn preserves flat placement and explicit content rotation")
		main.ray = [main.head.origin, Vector3.FORWARD]
		main.controller = main.InterfaceMove.ray_pose(main.head.origin, Vector3.FORWARD)
		main._begin_interface_move("right_hand", "grip_click")
		check(not main.interface_move.capture.is_empty() and main.interface_move.capture.targets[0].kind == "immersive", "Immersive grip retains its own routing")
		main.interface_move.cancel()
	main.free(); video.queue_free(); await process_frame
	for failure in failures.slice(0, 20): push_error(failure)
	print("Video movement: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)

func check_pose(video: Node3D, frame: Transform3D, rotation: float, label: String) -> void:
	var world: Transform3D = video.global_transform * video.flat_pose
	var local := frame.affine_inverse() * world
	check(absf(local.basis.x.y) < 0.00001 and local.basis.y.y > 0, label + " stays upright")
	check(absf(local.origin.length() - 3.0) < 0.0001 and is_equal_approx(local.basis.determinant(), 1.0), label + " preserves viewing distance and scale")
	check(video.screen_rotation == rotation and video.screen_scale == 1.0 and video.panel.global_basis.is_equal_approx(world.basis * Basis(Vector3.FORWARD, deg_to_rad(rotation))), label + " preserves explicit content rotation and size")
