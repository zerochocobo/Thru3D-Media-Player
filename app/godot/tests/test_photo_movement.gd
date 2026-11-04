extends SceneTree
const Photo := preload("res://scripts/photo_display.gd")
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
	# Use production movement routing without starting decoders, XR or the full app.
	var main := InputMain.new()
	var photo := Photo.new(); root.add_child(photo); photo.set_process(false)
	main.photo = photo; main.photo_active = true
	photo.local_uri = "file:///movement.jpg"; photo.panel.visible = true
	photo.screen_rotation = 90.0
	for following in [false, true]:
		main.view_follow.enabled = following
		main.head.basis = Basis.from_euler(Vector3(0.3, 0.4, 0.6)) if following else Basis.IDENTITY
		var frame := main.head if following else Transform3D(Basis.IDENTITY, main.head.origin)
		for pitch in [-0.6, 0.6]:
			var basis := Basis(Vector3.RIGHT, pitch)
			photo.set_flat_world_pose(frame * Transform3D(basis, basis * Vector3(0, 0, -3)))
			for step in 80:
				main._turn_picture(0.025 if step < 40 else -0.025, 0.0)
				var local: Transform3D = frame.affine_inverse() * photo.flat_pose
				check(absf(local.basis.x.y) < 0.00001, "Trigger side drag stays level: follow=%s pitch=%s step=%d" % [following, pitch, step])
				check(is_equal_approx(local.origin.length(), 3.0) and is_equal_approx(local.basis.determinant(), 1.0), "Trigger drag preserves distance and scale")
			# Repeated off-centre grip drags after raising/lowering the photo.
			photo.set_flat_world_pose(frame * Transform3D(basis, basis * Vector3(0, 0, -3)))
			for grab in 8:
				var start := photo.panel.to_global(Vector3(0.12, -0.08, 0))
				main.controller = main.InterfaceMove.ray_pose(main.head.origin, start - main.head.origin)
				main.ray = [main.head.origin, (start - main.head.origin).normalized()]
				main._begin_interface_move("right_hand", "grip_click")
				check(not main.interface_move.capture.is_empty(), "Actual photo hit starts grip movement")
				for step in 12:
					main.controller.basis = Basis(frame.basis.y, 0.025 if grab < 4 else -0.025) * main.controller.basis
					main.interface_move.update(main.controller, main.head, main.view_follow)
					var local: Transform3D = frame.affine_inverse() * photo.flat_pose
					check(absf(local.basis.x.y) < 0.00001, "Repeated off-centre grip stays level: follow=%s pitch=%s grab=%d step=%d" % [following, pitch, grab, step])
					check(is_equal_approx(local.origin.length(), 3.0), "Grip drag keeps centre distance")
				main.interface_move.cancel()
			check(photo.screen_rotation == 90.0 and photo.screen_scale == 1.0, "Movement preserves explicit image rotation and size")
	main.free(); photo.queue_free(); await process_frame
	for failure in failures: push_error(failure)
	print("Photo movement: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
