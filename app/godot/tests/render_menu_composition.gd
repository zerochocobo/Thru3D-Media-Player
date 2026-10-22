extends SceneTree
const Menu := preload("res://scripts/ray_menu.gd")
const Capture := preload("res://scripts/menu_composition.gd")
const Display := preload("res://scripts/xr_display.gd")
## Host rendering has no running native XR session. Stub only that update boundary so the
## actual _process path sees active native menu layers, including any frame-rate policy.
class NativeFrameProbe extends Capture:
	func update() -> void:
		display.set_menu_layers(true)

var failures: Array[String] = []
var checks := 0
var output := ProjectSettings.globalize_path("res://../../build/output/menu-hd/composition")
func _initialize() -> void: call_deferred("run")
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)
func frames(count: int = 1) -> void:
	for i in count:
		await process_frame; await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
## Feed elapsed frame times without waiting for real-time stalls on the desktop.
func _feed(capture: Node, fps: float, seconds: float) -> void:
	for frame in roundi(fps * seconds): capture._process(1.0 / fps)

func slot_with(capture: Node, node: Node) -> Dictionary:
	for slot in capture.slots:
		if slot.used and slot.nodes.has(node): return slot
	return {}

func check_tooltip_overlap(viewport: SubViewport, camera: Camera3D, menu: Node3D, tip_slot: Dictionary) -> void:
	var pose := camera.transform
	var material: ShaderMaterial = tip_slot.hole.material_override
	var priority := material.render_priority
	var half: Vector2 = menu._tooltip.mesh.size * 0.5
	for rotation in [Vector3.ZERO, Vector3(0.35, 0.2, 0), Vector3(-0.35, -0.2, 0)]:
		camera.position = Vector3.ZERO; camera.rotation = rotation
		var lo := Vector2(INF, INF); var hi := Vector2(-INF, -INF)
		for corner in [Vector3(-half.x, -half.y, 0), Vector3(half.x, -half.y, 0), Vector3(-half.x, half.y, 0), Vector3(half.x, half.y, 0)]:
			var pixel := camera.unproject_position(menu._tooltip.to_global(corner))
			lo = lo.min(pixel); hi = hi.max(pixel)
		var area := Rect2i(Vector2i(lo.floor()) - Vector2i(3, 3), Vector2i((hi - lo).ceil()) + Vector2i(7, 7))
		area = area.intersection(Rect2i(Vector2i.ZERO, viewport.size))
		tip_slot.hole.visible = false; await frames()
		var reference := viewport.get_texture().get_image()
		tip_slot.hole.visible = true
		for order in [Capture.HOLE_PRIORITY - 1, Capture.HOLE_PRIORITY, Capture.HOLE_PRIORITY + 1]:
			material.render_priority = order; await frames()
			var actual := viewport.get_texture().get_image()
			var samples := 0; var leaked := 0; var worst := 0.0
			for y in range(area.position.y, area.end.y):
				for x in range(area.position.x, area.end.x):
					if reference.get_pixel(x, y).a > 0.01: continue
					samples += 1
					var residual := actual.get_pixel(x, y).a
					worst = maxf(worst, residual)
					if residual > 0.02: leaked += 1
			check(samples > 100 and leaked == 0, "Production tooltip retains the cleared panel at view %s, draw order %d: %d/%d leaked, residual %.3f" % [rotation, order, leaked, samples, worst])
			actual.save_png(output.path_join("tooltip-mask-%s-%d.png" % [str(rotation), order]))
	material.render_priority = priority; camera.transform = pose
	await frames()

func run() -> void:
	DirAccess.make_dir_recursive_absolute(output)
	var viewport := SubViewport.new(); viewport.size = Vector2i(1400, 1000)
	viewport.own_world_3d = true; viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var origin := Node3D.new(); viewport.add_child(origin)
	var camera := Camera3D.new(); camera.fov = 70; origin.add_child(camera)
	var world := WorldEnvironment.new(); world.environment = Environment.new(); viewport.add_child(world)
	var display := Display.new(); display.configure(viewport, world.environment, null, true)
	viewport.transparent_bg = true
	var background := MeshInstance3D.new(); background.mesh = QuadMesh.new(); background.mesh.size = Vector2(12, 12)
	background.position.z = -5
	var background_material := StandardMaterial3D.new(); background_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	background_material.albedo_color = Color(0.04, 0.05, 0.06); background.material_override = background_material
	viewport.add_child(background)
	var menu := Menu.new(); viewport.add_child(menu); menu.visible = true
	menu._label("高清菜单 中文笔画 Menu 0123456789", Vector3(0, 0.28, 0.006), 23)
	menu._button(42, "Select", Vector2(0, 0), Vector2(0.25, 0.10), true, "folder")
	menu._round(44, "close", Vector2(0.4, -0.3), 0.09, true, false, "Tip")
	var side := Node3D.new(); side.transform = Transform3D(Basis(Vector3.UP, deg_to_rad(24)), Vector3(-0.91, 0, 0.12))
	menu.add_child(side)
	var side_background := menu._quad(Vector2(0.44, 1.08), Vector3.ZERO, menu.PANEL, 10); side.add_child(side_background)
	menu._button(43, "Side", Vector2(0, 0.1), Vector2(0.35, 0.10), true, "folder", false, side)
	# A raised popup like choice_fields: higher render priority, a separate plane.
	var popup: MeshInstance3D = menu._quad(Vector2(0.5, 0.3), Vector3(0.3, 0.1, 0.028), menu.PANEL, 30); menu.add_child(popup)
	menu._label("弹层 Popup", Vector3(0.3, 0.1, 0.039), 20).render_priority = 32
	var live := MeshInstance3D.new(); live.mesh = QuadMesh.new(); live.mesh.size = Vector2(0.1, 0.1)
	live.position = Vector3(-0.4, -0.3, 0.014); live.set_meta("menu_eye_buffer", true); menu.add_child(live)

	var original_eye_mask := camera.cull_mask
	var unavailable := Capture.new(); viewport.add_child(unavailable)
	unavailable.configure(origin, camera, display, [menu], false)
	check(not unavailable.enabled and not unavailable.is_processing() and unavailable.slots.is_empty() and unavailable.get_child_count() == 0,
		"Without native quad layers no capture or compositor resources exist")
	check(camera.cull_mask == original_eye_mask and menu._buttons[0].node.layers == 1, "Fallback keeps the eye-buffer menu")
	check(unavailable.snapshot().fallback == "native_quad_unavailable", "Fallback reason is visible in diagnostics")
	unavailable.queue_free(); await process_frame

	var capture := Capture.new(); viewport.add_child(capture)
	capture.configure(origin, camera, display, [menu], false, true); capture.set_process(false)
	capture.update(); await frames(2)
	capture._painted_ms = Time.get_ticks_msec() + 100000 # keep the low-rate refresh out of the policy checks
	capture.update(); await frames(2); capture.update()
	var initial: Dictionary = capture.snapshot()
	check(initial.active and initial.layers == 3, "Main panel, side column and popup each get a layer: " + str(initial))
	check((camera.cull_mask & Capture.GROUP_MASK) == 0, "Eye buffer excludes captured geometry")
	var main_slot := slot_with(capture, menu._backdrop)
	var side_slot := slot_with(capture, side_background)
	var popup_slot := slot_with(capture, popup)
	check(not main_slot.is_empty() and not side_slot.is_empty() and not popup_slot.is_empty() and main_slot != side_slot and main_slot != popup_slot,
		"Planes are grouped separately")
	check(slot_with(capture, menu._buttons[0].node.get_child(0)) == main_slot, "Labels on a panel share its layer")
	check(popup_slot.layer.sort_order > main_slot.layer.sort_order and popup_slot.layer.sort_order > side_slot.layer.sort_order,
		"Popup layer composites over the panels")
	check(main_slot.layer.sort_order > -8 and popup_slot.layer.sort_order < 0, "Menu layers sit between video and eye buffer")
	check(side_slot.layer.global_basis.z.angle_to(side_background.global_basis.z) < 0.01, "Side layer keeps its angle")
	check(live.layers == 1, "Live animation stays in the eye buffer")
	check(main_slot.layer.sort_order >= Capture.ORDER_BASE and main_slot.layer.alpha_blend and not main_slot.layer.enable_hole_punch, "Coverage mask instead of rectangular hole")
	for slot in [main_slot, side_slot, popup_slot]:
		var image: Image = slot.raw.get_texture().get_image()
		image.save_png(output.path_join("layer-%d.png" % slot.index))
		var submitted: Image = slot.submit.get_texture().get_image()
		check(image.get_data() == submitted.get_data(), "Swapchain copy preserves the capture: " + str(slot.index))
		var pixels: Vector2 = Vector2(slot.raw.size)
		check(absf(pixels.x / pixels.y - slot.layer.quad_size.x / slot.layer.quad_size.y) < 0.001, "Layer aspect equals pixel aspect")
		check(pixels.x / slot.layer.quad_size.x >= Capture.DENSITY * 0.9, "Dense capture: " + str(pixels.x / slot.layer.quad_size.x) + " px/m, slot " + str(slot.index) + " rect " + str(slot.rect.size))
	var main_image: Image = main_slot.raw.get_texture().get_image()
	var white := 0
	for y in range(0, main_image.get_height(), 3):
		for x in range(0, main_image.get_width(), 3):
			var c := main_image.get_pixel(x, y)
			if c.r > 0.75 and c.g > 0.75 and c.b > 0.75: white += 1
	check(white > 200, "Capture contains visible glyphs")
	var inside: Vector3 = main_slot.layer.global_transform.affine_inverse() * menu.to_global(Vector3(0.2, -0.1, 0))
	var uv := Vector2(inside.x / main_slot.layer.quad_size.x + 0.5, 0.5 - inside.y / main_slot.layer.quad_size.y)
	check(main_image.get_pixelv(Vector2i(uv * Vector2(main_image.get_size()))).a > 0.99, "Panel plate is opaque in the capture")
	check(main_slot.submit.render_target_update_mode == SubViewport.UPDATE_DISABLED, "Swapchain stops updating after a repaint")

	var projection := viewport.get_texture().get_image()
	projection.save_png(output.path_join("projection-mask.png"))
	check(projection.get_pixel(5, 5).a > 0.99, "Empty margins preserve the background")
	var centre := camera.unproject_position(menu.to_global(Vector3(0.2, -0.1, 0)))
	check(projection.get_pixelv(Vector2i(centre)).a < 0.01, "Menu coverage clears the eye buffer")
	# Shader 2D->3D video uses the transparent pass at -10. A nearby portrait panel
	# must be cleared after it draws, or it fills the menu hole over the native menu.
	var video := MeshInstance3D.new(); video.mesh = QuadMesh.new(); video.mesh.size = Vector2(0.45, 1.1)
	var video_material := StandardMaterial3D.new()
	video_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	video_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	video_material.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	video_material.render_priority = -10; video_material.albedo_color = Color(0.9, 0.1, 0.1, 1.0)
	video.material_override = video_material; viewport.add_child(video)
	for distance in [1.5, 1.2, 0.8]:
		video.position = Vector3(0.2, -0.13, -distance)
		await frames()
		projection = viewport.get_texture().get_image()
		check(projection.get_pixelv(Vector2i(centre)).a < 0.01, "Near portrait shader video cannot refill menu hole at " + str(distance))
	video.queue_free(); await frames()
	var controller := MeshInstance3D.new(); controller.mesh = BoxMesh.new(); controller.mesh.size = Vector3(0.12, 0.12, 0.10)
	controller.position = Vector3(0.2, -0.13, -0.9)
	var red := StandardMaterial3D.new(); red.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED; red.albedo_color = Color(0.8, 0.1, 0.1)
	controller.material_override = red; viewport.add_child(controller)
	await frames()
	projection = viewport.get_texture().get_image(); projection.save_png(output.path_join("controller.png"))
	var foreground := projection.get_pixelv(Vector2i(camera.unproject_position(controller.position)))
	check(foreground.r > 0.7 and foreground.a > 0.99, "Input model in front survives the hole")
	controller.queue_free()

	# Head motion alone must not re-render anything: the compositor reprojects the quads.
	var repaints: int = capture.repaints
	for step in 6:
		camera.position = Vector3(0.05 * step, 0.02 * step, 0.03 * step); camera.rotation.y = 0.02 * step
		capture.update(); await frames()
	check(capture.repaints == repaints, "Head motion causes no repaint")
	check(main_slot.raw.render_target_update_mode == SubViewport.UPDATE_DISABLED, "Idle capture does not render")
	# Hover tip: layout signal regroups but keeps slots and swapchain sizes.
	var sizes: Array = capture.slots.map(func(slot): return slot.raw.size)
	var tip_ray: Vector3 = menu._buttons[1].node.to_global(Vector3(0, 0, 1))
	menu.update_pointer("right_hand", tip_ray, -menu._buttons[1].node.global_basis.z, true)
	capture.update(); await frames()
	var tip_slot := slot_with(capture, menu._tooltip)
	check(menu._tooltip and menu._tooltip.visible and not tip_slot.is_empty() and tip_slot.nodes.has(menu._tooltip.get_child(0)) \
		and tip_slot.layer.sort_order>main_slot.layer.sort_order, "Tooltip and its text are captured above the main layer")
	check(capture.repaints == repaints + 1, "Hover repaints once")
	capture.update(); capture.update(); await frames()
	check(capture.repaints == repaints + 1, "Steady hover does not keep repainting")
	# The low-rate check repaints only when something it captures changed.
	capture._painted_ms = 0
	capture.update(); await frames()
	check(capture.repaints == repaints + 1, "Keepalive skips an unchanged menu")
	var quiet_label := menu._tooltip.get_child(0) as Label3D
	quiet_label.text += " "
	capture._painted_ms = 0
	capture.update(); await frames()
	check(capture.repaints == repaints + 2, "Keepalive repaints text changed without a signal")
	capture.update(); await frames()
	check(capture.repaints == repaints + 2, "Keepalive settles after the repaint")
	repaints = capture.repaints - 1
	capture._painted_ms = Time.get_ticks_msec() + 100000
	check(capture.slots.map(func(slot): return slot.raw.size) == sizes, "Hover keeps allocated slot sizes even when its dedicated layer activates")
	check(menu._pointers.right_hand.dot.layers == 1 and menu._pointers.right_hand.line.layers == 1, "Pointer stays in the eye buffer")
	await check_tooltip_overlap(viewport, camera, menu, tip_slot)
	var ray: Vector3 = menu._buttons[2].node.to_global(Vector3(0, 0, 1))
	check(menu.ray_hit(ray, -menu._buttons[2].node.global_basis.z).get("target") == 43, "Angled side ray geometry remains live")
	# Rebuild: new nodes join, old references drop.
	menu._clear_layout()
	menu._button(90, "Updated", Vector2(0, 0), Vector2(0.35, 0.10))
	capture.update(); await frames()
	check(slot_with(capture, menu._buttons[0].node) == main_slot, "Rebuilt menu joins the same layer")
	menu.dismiss(); capture.update()
	check(not main_slot.hole.visible and menu._backdrop.layers == 1 and not capture.snapshot().active, "Closing restores meshes and hides layers")
	check(main_slot.layer.quad_size.x < 0.001 and main_slot.layer.layer_viewport == main_slot.submit, "Closed slot shrinks but keeps its viewport and swapchain")
	check(main_slot.raw.render_target_update_mode == SubViewport.UPDATE_DISABLED and main_slot.submit.render_target_update_mode == SubViewport.UPDATE_DISABLED, "Hidden capture stops rendering")
	menu.visible = true; capture.update(); await frames()
	check(menu._buttons[0].node.layers != 1, "Reopened menu returns to layers")
	var slow_frame_pixels: Array = capture.snapshot().pixels
	var probe := NativeFrameProbe.new(); viewport.add_child(probe); probe.set_process(false)
	probe.enabled = true; probe.display = display; probe.fallback_reason = ""
	for fps in [25.0, 10.0, 1.0, 0.25]:
		_feed(probe, fps, 12.0)
		check(probe.enabled and display.menu_layers and probe.fallback_reason.is_empty(),
			"Slow frames never disable native menu layers: %.2f FPS" % fps)
	probe.queue_free(); await process_frame
	capture.update()
	check(capture.enabled and menu._buttons[0].node.layers != 1 and capture.snapshot().pixels == slow_frame_pixels,
		"The rendered menu retains its layer masks and fixed capture density")
	capture.shutdown("test_complete")
	check(menu._buttons[0].node.layers == 1 and camera.cull_mask == original_eye_mask and not capture.is_processing() and main_slot.layer.quad_size.x < 0.001,
		"Explicit cleanup restores the eye-buffer menu and parks layers")
	capture.update()
	check(capture.snapshot().fallback == "test_complete" and menu._buttons[0].node.layers == 1, "Explicit cleanup stays off for the session")
	var report := {"scope": "Planar menu capture, grouping, masks and update policy on desktop OpenGL; native XR submission pending", "checks": checks, "failures": failures, "capture": initial}
	FileAccess.open(output.path_join("verification.json"), FileAccess.WRITE).store_string(JSON.stringify(report, "\t"))
	for failure in failures: push_error(failure)
	print("Menu composition: %d checks, %d failures" % [checks, failures.size()])
	quit(1 if not failures.is_empty() else 0)
