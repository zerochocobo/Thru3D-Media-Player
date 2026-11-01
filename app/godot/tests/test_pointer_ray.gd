extends SceneTree
const Ray := preload("res://scripts/pointer_ray.gd")
const Feedback := preload("res://scripts/controller_feedback.gd")
const Gallery := preload("res://scripts/photo_gallery.gd")
const MonoShader := preload("res://shaders/menu_zero_parallax_ray.gdshader")
var checks := 0
var failures: Array[String] = []

class Menu extends "res://scripts/ray_menu.gd":
	var selected := 0
	func _activate(_target: int) -> void: selected += 1

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func _initialize() -> void: call_deferred("run")

func full_ray(line: MeshInstance3D, origin: Vector3, end: Vector3, label: String) -> void:
	var vertices: PackedVector3Array = line.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var start := line.to_global(vertices[0])
	check(start.is_equal_approx(origin), label + ": full ray stays attached to the hand")
	check(line.to_global(vertices[1]).is_equal_approx(end), label + ": original endpoint retained")
	check(is_equal_approx(start.distance_to(end), origin.distance_to(end)), label + ": full near/far distance, no truncation")

func run() -> void:
	var owner := Node3D.new(); root.add_child(owner)
	owner.transform = Transform3D(Basis(Vector3.UP, 0.4).scaled(Vector3(1.7, 1.2, 1.4)), Vector3(0.2, 1.5, -0.7))
	var feedback := Feedback.new(); owner.add_child(feedback)
	var gallery := Gallery.new(); gallery.photo = owner; owner.add_child(gallery)
	var menu := Menu.new(); owner.add_child(menu); menu.visible = true; menu.ray_max_distance = 100.0
	menu._button(1, "", Vector2.ZERO, Vector2(0.3, 0.2))
	var target: Vector3 = menu._buttons[0].node.global_position
	for distance: float in [0.02, 0.1, 0.4, 2.0, 20.0, 60.0]:
		var origin := target + menu.global_basis.z.normalized() * distance
		var direction := (target-origin).normalized()
		var pose := Transform3D(Basis.IDENTITY, origin)
		for hand in ["left_hand", "right_hand"]:
			var label := "%s at %.2fm" % [hand, distance]
			menu.update_pointer(hand, origin, direction, true)
			var pointer: Dictionary = menu._pointers[hand]
			check(menu._hover[hand] == 1 and pointer.dot.visible, label + ": full input ray still hits the button")
			full_ray(pointer.line, origin, menu.to_global(menu.to_local(target)+Vector3(0,0,0.006)), "menu " + label)
			var before: int = menu.selected
			check(menu.press_pointer(hand, origin, direction, true) and menu.selected == before+1, label + ": trigger activates the same target")
			feedback.update_hand(hand, pose, [origin, direction], target, true, false, 0.01)
			full_ray(feedback.hands[hand].nodes.line, origin, target, "world " + label)
			gallery._show_pointer(hand, origin, {"point":target})
			full_ray(gallery._pointers[hand].line, origin, target, "photo " + label)
			check(gallery._pointers[hand].dot.visible, label + ": gallery retains its dot")
	menu.cancel_pointer("left_hand")
	check(not menu._pointers.left_hand.line.visible and not menu._pointers.left_hand.dot.visible, "Tracking loss clears menu graphics")
	gallery._show_pointer("left_hand", Vector3.ZERO, {})
	check(not gallery._pointers.left_hand.line.visible and not gallery._pointers.left_hand.dot.visible, "Gallery miss keeps existing hide policy")
	feedback.update_hand("left_hand", Transform3D.IDENTITY, [Vector3.ZERO, Vector3.FORWARD], null, true, false, 0.01)
	check(feedback.hands.left_hand.nodes.line.visible and not feedback.hands.left_hand.nodes.dot.visible, "World miss keeps a faint ray without a false dot")
	owner.queue_free(); await process_frame
	if "--render" in OS.get_cmdline_user_args(): await pixels()
	for failure in failures: push_error(failure)
	print("Pointer ray: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)

func frames() -> void:
	for i in 3: await process_frame; await RenderingServer.frame_post_draw

func sample(image: Image, point: Vector2, radius: int = 2) -> float:
	var alpha := 0.0
	for y in range(maxi(0, int(point.y)-radius), mini(image.get_height(), int(point.y)+radius+1)):
		for x in range(maxi(0, int(point.x)-radius), mini(image.get_width(), int(point.x)+radius+1)):
			alpha = maxf(alpha, image.get_pixel(x,y).a)
	return alpha

func pixels() -> void:
	var output := ProjectSettings.globalize_path("res://../../build/output/pointer-ray")
	DirAccess.make_dir_recursive_absolute(output)
	var view := SubViewport.new(); view.size = Vector2i(1200, 900); view.own_world_3d = true
	view.transparent_bg = true; view.render_target_update_mode = SubViewport.UPDATE_ALWAYS; root.add_child(view)
	var camera := Camera3D.new(); camera.near = 0.005; camera.far = 200.0; view.add_child(camera)
	var line := Ray.create(Color(0.2,0.9,1.0,0.5), 126); view.add_child(line); line.show()
	for distance: float in [0.1, 2.0, 40.0]:
		# Equal angular coverage at three distances makes width/opacity comparable.
		var origin := Vector3(-0.35,-0.15,-1.0) * distance
		var end := Vector3(0.35,0.15,-1.0) * distance
		Ray.draw(line, origin, end)
		await frames()
		var image := view.get_texture().get_image()
		check(image.save_png(output.path_join("ray-%sm.png" % distance)) == OK, "Save full ray preview")
		for fraction: float in [0.02, 0.25, 0.5, 0.75, 0.98]:
			check(sample(image, camera.unproject_position(origin.lerp(end,fraction))) > 0.2, "Ray is continuously visible at %sm / %s" % [distance,fraction])
		var beginning := sample(image, camera.unproject_position(origin.lerp(end,0.02)))
		var middle := sample(image, camera.unproject_position(origin.lerp(end,0.8)))
		check(middle > 0.2 and middle < 0.65, "Translucent ray is visible at %sm: %s" % [distance,middle])
		check(beginning > middle * 0.6, "Hand end is not faded away at %sm" % distance)
		var across := camera.unproject_position(origin.lerp(end,0.8)) + Vector2(0,5)
		check(sample(image, across, 0) < 0.01, "Soft ray remains narrow at %sm" % distance)
	# A full ray can start on or behind the eye plane while still pointing at the page.
	for hand_z: float in [0.1, 0.0, -0.001, -0.02]:
		var start := Vector3(-0.2,-0.15,hand_z)
		var end := Vector3(0.3,0.15,-2.0)
		Ray.draw(line, start, end)
		await frames()
		var image := view.get_texture().get_image()
		check(sample(image,camera.unproject_position(start.lerp(end,0.65)))>0.2,"Near-plane clipping preserves the forward ray when hand z=%s" % hand_z)
	# Compile and render the production mono shader with explicit stereo eye poses.
	# Only substitute built-in matrices/offsets unavailable to a desktop Camera3D.
	var shader := Shader.new()
	shader.code = MonoShader.code.replace("shader_type spatial;", "shader_type spatial;\nuniform mat4 test_view;\nuniform vec3 test_eye;").replace("VIEW_MATRIX", "test_view").replace("EYE_OFFSET", "test_eye")
	var material := line.material_override as ShaderMaterial; material.shader = shader
	var origin := Vector3(-0.35,-0.2,-0.3); var end := Vector3(0.3,0.15,-2.0)
	Ray.draw(line, origin, end)
	for side in [-1.0, 1.0]:
		var eye := Vector3(side*0.032,0,0)
		material.set_shader_parameter("test_view", Projection(Transform3D(Basis.IDENTITY,eye).affine_inverse()))
		material.set_shader_parameter("test_eye", eye)
		await frames()
		var image := view.get_texture().get_image()
		check(image.save_png(output.path_join("mono-%s.png" % side)) == OK, "Save stereo projection preview")
		check(sample(image,camera.unproject_position(end),3)>0.15,"Mono ray joins the same reticle centre in either eye")
		check(sample(image,camera.unproject_position(origin.lerp(end,0.1)-eye*0.9))>0.15,"Mono ray remains visible near the tracked hand")
		var at := 0.8
		var projected := origin.lerp(end,at)-eye*(1.0-at)
		check(sample(image,camera.unproject_position(projected))>0.15,"Mono middle retains the full ray's original stereo interpolation")
	view.queue_free(); await process_frame
