extends SceneTree
const Memory := preload("res://scripts/file_mode_memory.gd")
var checks := 0
var failures: Array[String] = []
var folder := "user://gallery-click-%d" % Time.get_ticks_usec()
var entries: Array[Dictionary] = []
var fixture := 0
var app: Node3D
var head := Transform3D.IDENTITY

class Harness extends "res://scripts/main.gd":
	var rays := {}
	func _ray(hand: String) -> Variant: return rays.get(hand)

class DepthHost extends RefCounted:
	func prepare_photo_3d(_id: int, _strength: float) -> bool: return true
	func cancel_photo(_id: int) -> void: pass
	func release_photo(_id: int) -> void: pass

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func _initialize() -> void: run.call_deferred()

func settle() -> void:
	var deadline := Time.get_ticks_msec() + 5000
	while app.photo.loading and Time.get_ticks_msec() < deadline: await create_timer(0.01).timeout
	if app.photo.loading or not app.photo.error.is_empty():
		push_error("Photo click fixture failed to load: %s" % app.photo.error)
		quit(2)

func open_full(layout: int, distance: float = 3.0, curve: float = 0.0) -> void:
	fixture += 1
	app.xr_camera.global_transform = head
	app._grab.clear(); app._controller_consumed.clear(); app.controller_bindings.restore_all()
	app.recent_menu.dismiss(); app.photo_menu.dismiss(); app.interface_move.cancel(); app.photo_hands.cancel()
	var photo: Node3D = app.photo
	photo.close_image(); photo.platform = null; photo.auto_depth = false; photo.spatial_preferred = false
	photo.mode_memory = Memory.new(folder.path_join("modes-%d" % fixture))
	photo.set_layout_mode(0)
	photo.open_image(entries[0].uri, "0.png", entries); await settle()
	photo.set_projection(0); photo.set_stereo_layout(0); photo.set_screen_scale(1.0)
	photo.set_layout_mode(layout); photo.gallery._process(0.01)
	photo.gallery.activate(0); await settle()
	photo.finish_transition(); photo.gallery._process(1.0)
	photo.gallery.set_focus_distance(distance); photo.set_screen_curve(curve); photo.gallery._process(0.01)

func aim(hand: String, direction: Variant = null) -> Array:
	var origin: Vector3 = app.xr_camera.global_position
	var ray := [origin, (app.photo.gallery.focus_pose.origin - origin).normalized() if direction == null else direction]
	app.rays[hand] = ray
	return ray

func press(hand: String) -> void: app._on_controller_button("trigger_click", hand)
func release(hand: String) -> void: app._on_controller_release("trigger_click", hand)

func curved_edge() -> Vector3:
	var photo: Node3D = app.photo
	var x: float = photo._flat.size.x * 0.495
	var point := Vector3(x, 0, 0)
	if photo.screen_curve > 0:
		var radius: float = photo._curve_radius()
		point = Vector3(sin(x / radius) * radius, 0, (1.0 - cos(x / radius)) * radius)
	return (photo.panel.to_global(point) - app.xr_camera.global_position).normalized()

func enable_3d() -> void:
	var photo: Node3D = app.photo
	photo.platform = DepthHost.new()
	var depth := Image.create(518, 518, false, Image.FORMAT_RF); depth.fill(Color(0.7, 0, 0))
	var pair := Image.create(480, 160, false, Image.FORMAT_RGBA8); pair.fill(Color.WHITE)
	check(photo.set_depth(true), "Production photo conversion accepts the expanded source")
	photo._finish_depth(photo._display_request, {"image": depth, "rect": Vector4(0, 0, 1, 1),
		"stereo_image": pair, "strength": photo.depth_strength}, false)
	check(photo.depth_enabled and photo.material.get_shader_parameter("photo_stereo")
		and not photo.portrait_presentation_active(), "Generated 3D uses its stereo pair without portrait mode")

func jitter_checks(layout: int, hand: String) -> void:
	for distance in [1.5, 3.0, 8.0]:
		await open_full(layout, distance)
		var ray := aim(hand); var pose: Transform3D = app.photo.gallery.focus_pose
		press(hand)
		check(app.photo.gallery.capture.get("hand", "") == hand, "Physical trigger captures full photo: %d/%s/%s" % [layout, hand, distance])
		app.photo.gallery.update_pointer(hand, ray[0], ray[1].rotated(Vector3.UP, 0.009))
		check(not app.photo.gallery.capture.get("moved", true) and app.photo.gallery.focus_pose.is_equal_approx(pose),
			"Half-degree click jitter keeps the photo still at %.1fm" % distance)
		app.photo.gallery.update_pointer(hand, ray[0], ray[1])
		release(hand)
		check(app.photo.gallery.returning, "A click survives transient jitter at %.1fm" % distance)
	await open_full(layout)
	var ray := aim(hand); var pose: Transform3D = app.photo.gallery.focus_pose
	press(hand)
	app.xr_camera.global_position += Vector3(0.03, 0, 0)
	app.photo.gallery.update_pointer(hand, ray[0], ray[1])
	check(not app.photo.gallery.capture.get("moved", true) and app.photo.gallery.focus_pose.is_equal_approx(pose),
		"Head movement alone never commits picture dragging")
	release(hand)
	check(app.photo.gallery.returning, "A stationary controller click survives headset translation")

func edge_checks(layout: int, hand: String) -> void:
	for curve in [0.0, 0.35, 0.7, 1.0]:
		await open_full(layout, 3.0, curve)
		var ray := aim(hand, curved_edge())
		var surface: Variant = app.photo.screen_hit(ray[0], ray[1])
		var hit: Dictionary = app.photo.gallery.ray_hit(ray[0], ray[1])
		check(surface != null and hit.get("index", -1) == 0, "Visible photo edge is clickable at curvature %.2f" % curve)
		if not hit.is_empty() and surface != null:
			check(hit.point.distance_to(surface) < 0.001, "Gallery pointer endpoint lies on the actual curved surface")
		press(hand); release(hand)
		check(app.photo.gallery.returning, "A stationary edge click closes the expanded photo")
		await open_full(layout, 3.0, curve)
		ray = aim(hand, curved_edge()); press(hand)
		app.rays[hand] = [ray[0], ray[1].rotated(Vector3.UP, -0.009)]
		app.xr_camera.global_position += Vector3(0.03, 0, 0)
		check(app.photo.screen_hit(app.rays[hand][0], app.rays[hand][1]) == null, "Combined click fixture drifts just outside the visible edge")
		release(hand)
		check(app.photo.gallery.returning, "Curved edge capture tolerates small release drift and head movement together")
	await open_full(layout, 3.0, 1.0)
	aim(hand, Vector3.UP); press(hand)
	check(not app.photo.gallery.has_capture(), "Pressing outside the photo never acquires a full-photo click")
	release(hand); check(not app.photo.gallery.returning, "An uncaptured outside click cannot close the photo")

func drag_checks(layout: int, hand: String) -> void:
	for distance in [1.5, 3.0, 8.0]:
		await open_full(layout, distance)
		var ray := aim(hand); press(hand)
		app.rays[hand] = [ray[0], ray[1].rotated(Vector3.UP, 0.04)]
		app.photo.gallery.update_pointer(hand, app.rays[hand][0], app.rays[hand][1])
		check(app.photo.gallery.capture.get("moved", false), "Deliberate dragging still starts at %.1fm" % distance)
		check(is_equal_approx(app.photo.gallery.focus_pose.origin.distance_to(app.xr_camera.global_position), distance),
			"Dragging retains its original viewing radius")
		var other := "left_hand" if hand == "right_hand" else "right_hand"
		check(not app.photo.gallery.release_pointer(other, ray[0], ray[1]) and app.photo.gallery.has_capture(),
			"The other hand cannot release or close a held photo")
		app.rays[hand] = ray; release(hand)
		check(not app.photo.gallery.returning and app.photo.gallery.focus == 0 and not app.photo.gallery.has_capture(),
			"Returning to the press position after a real drag never becomes a close click")
	await open_full(layout)
	var ray := aim(hand); var pose: Transform3D = app.photo.gallery.focus_pose
	press(hand); app.rays[hand] = [ray[0], ray[1].rotated(Vector3.UP, 0.04)]
	app.photo.gallery.update_pointer(hand, app.rays[hand][0], app.rays[hand][1])
	app.xr_camera.global_position += Vector3(0.03, 0, 0)
	app.photo.gallery.update_pointer(hand, app.rays[hand][0], app.rays[hand][1])
	check(app.photo.gallery.capture.get("moved", false) and is_equal_approx(app.photo.gallery.focus_pose.origin.distance_to(app.xr_camera.global_position), 3.0),
		"After drag commitment the picture retains its distance from the live eye position")
	release(hand); check(not app.photo.gallery.returning, "Head movement during a real drag never enables collapse")
	await open_full(layout)
	ray = aim(hand); pose = app.photo.gallery.focus_pose
	press(hand); app.photo.gallery.update_pointer(hand, ray[0] + Vector3(1, 0, 0), ray[1])
	check(not app.photo.gallery.has_capture() and app.photo.gallery.focus_pose.is_equal_approx(pose), "A tracking jump cancels without moving the photo")
	release(hand); check(not app.photo.gallery.returning, "Cancelled tracking cannot collapse the photo")
	press(hand); app.photo.gallery.update_pointer(hand, ray[0], ray[1], false); release(hand)
	check(not app.photo.gallery.returning and not app.photo.gallery.has_capture(), "Lost tracking cannot turn into a click")

func stereo_checks(layout: int, hand: String) -> void:
	for stereo in ["generated", "sbs", "tb"]:
		await open_full(layout, 8.0, 1.0)
		if stereo == "generated": enable_3d()
		else: app.photo.set_stereo_layout(1 if stereo == "sbs" else 2)
		var ray := aim(hand, curved_edge()); press(hand)
		app.rays[hand] = [ray[0], ray[1].rotated(Vector3.UP, -0.009)]
		app.xr_camera.global_position += Vector3(0.03, 0, 0)
		release(hand)
		check(app.photo.gallery.returning, "Far curved stereo click survives aim/head jitter: " + stereo)

func run() -> void:
	DirAccess.make_dir_recursive_absolute(folder)
	for index in 2:
		var image := Image.create(240, 160, false, Image.FORMAT_RGBA8); image.fill(Color.WHITE if index == 0 else Color.GREEN)
		var path := ProjectSettings.globalize_path(folder.path_join("%d.png" % index)); image.save_png(path)
		entries.append({"uri": "file://" + path, "title": "%d.png" % index, "kind": "image"})
	app = Harness.new(); app.settings_path = folder.path_join("settings.cfg"); root.add_child(app)
	app.set_process(false); app.photo.gallery.set_process(false); app.photo.history_enabled = false
	app.photo_active = true; app.player_menu = app.photo_menu; head = app.xr_camera.global_transform
	for layout in [2, 3]:
		for hand in ["left_hand", "right_hand"]:
			await jitter_checks(layout, hand)
			await edge_checks(layout, hand)
			await drag_checks(layout, hand)
			await stereo_checks(layout, hand)
	app.queue_free(); await process_frame
	for failure in failures: push_error(failure)
	print("Photo gallery clicks: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
