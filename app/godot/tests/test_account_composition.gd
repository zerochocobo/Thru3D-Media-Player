extends SceneTree
const Menu := preload("res://scripts/library_menu.gd")
const Platform := preload("res://tests/account_platform_fixture.gd")
const Capture := preload("res://scripts/menu_composition.gd")
var checks := 0
var failures: Array[String] = []
var evidence: Array = []
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)
func _initialize() -> void: run.call_deferred()
func slot_for(capture: Node, node: Node) -> Dictionary:
	for slot in capture.slots:
		if slot.used and slot.nodes.has(node): return slot
	return {}
func focus_color(menu: Node3D) -> Color:
	return menu._buttons.filter(func(button): return button.target == menu.account_panel.BASE + 29)[0].base_color
func render_slot(capture: Node, node: Node, name: String) -> void:
	if not OS.get_cmdline_user_args().has("--render"): return
	for i in 3: await process_frame; await RenderingServer.frame_post_draw; capture.update()
	var slot := slot_for(capture, node)
	var output := ProjectSettings.globalize_path("res://../../build/output/cloud-login-comfort/captures")
	DirAccess.make_dir_recursive_absolute(output)
	check(slot.raw.get_texture().get_image().save_png(output.path_join(name + ".png")) == OK, "Save actual menu capture " + name)
func run() -> void:
	for low in [false, true]:
		var world := Node3D.new(); root.add_child(world)
		var camera := Camera3D.new(); world.add_child(camera)
		var menu := Menu.new(); world.add_child(menu); menu.set_process(false)
		var platform := Platform.new(); menu.attach_platform(platform); menu.section = Menu.Section.RECENT; menu.toggle()
		var capture := Capture.new(); world.add_child(capture)
		capture.configure(world, camera, null, [menu], low, true); capture.set_process(false); capture.update()
		var baseline := slot_for(capture, menu._backdrop)
		var original_size: Vector2 = baseline.layer.quad_size
		var original_pixels: Vector2i = baseline.raw.size
		var original_density := float(original_pixels.x) / original_size.x
		var fixed_sizes: Array = capture.slots.map(func(slot): return slot.raw.size)
		await render_slot(capture, menu._backdrop, "before-%s" % low)
		for pass_index in 3:
			var panel: RefCounted = menu.account_panel
			panel.start("cloud", "quark_open")
			var state: Dictionary = platform.account_sessions[panel.session]
			var desktop := pass_index == 1
			state.state = "web"
			state.web = {"renderer": "gecko", "surface_id": "fixture", "width": 1200 if desktop else 440,
				"height": 720 if desktop else 600, "desktop": desktop, "status": "", "navigation": 1}
			panel.poll(); capture.update()
			check(focus_color(menu) == menu.TILE, "Focus starts inactive")
			panel.action(panel.BASE + 29); capture.update()
			check(focus_color(menu) == menu.ACCENT, "Selecting a focus region has green active feedback")
			panel.web_press("right_hand", Vector3.ZERO); panel.web_release("right_hand", Vector3.ZERO); capture.update()
			check(focus_color(menu) == menu.ACCENT, "Applied focus remains green after selection ends")
			await render_slot(capture, menu._buttons.filter(func(button): return button.target == panel.BASE + 29)[0].node, "focus-%s-%d" % [low, pass_index])
			panel.action(panel.BASE + 29); capture.update()
			check(focus_color(menu) == menu.TILE, "Exiting focus clears its active feedback")
			if pass_index == 1:
				menu._activate(menu.CLOSE); capture.update(); menu.toggle()
			else: panel.action(panel.BASE)
			capture.update()
			var restored := slot_for(capture, menu._backdrop)
			var restored_size: Vector2 = restored.layer.quad_size
			var density := float(restored.raw.size.x) / restored_size.x
			check(restored_size.is_equal_approx(original_size), "Leaving login restores the normal menu capture bounds")
			check(is_equal_approx(density, original_density), "Leaving login restores the original text capture density")
			check(restored.raw.size == original_pixels and capture.slots.map(func(slot): return slot.raw.size) == fixed_sizes, "No swapchain resize or extra provider is needed")
			check(menu._backdrop.material_override.get_shader_parameter("surface_color") == menu.PANEL, "Restored menu retains its panel background")
			evidence.append({"low_end": low, "visit": pass_index, "before_density": original_density, "after_density": density,
				"before_size": [original_size.x, original_size.y], "after_size": [restored_size.x, restored_size.y]})
			await render_slot(capture, menu._backdrop, "after-%s-%d" % [low, pass_index])
		world.free(); platform.free(); await process_frame
	var output := ProjectSettings.globalize_path("res://../../build/output/cloud-login-comfort")
	DirAccess.make_dir_recursive_absolute(output)
	FileAccess.open(output.path_join("composition-evidence.json"), FileAccess.WRITE).store_string(JSON.stringify(evidence, "\t"))
	print("Account composition: %d checks, %d failures" % [checks, failures.size()])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)
