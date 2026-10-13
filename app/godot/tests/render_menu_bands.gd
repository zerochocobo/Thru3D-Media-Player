extends SceneTree
## Debug text-band prototype (menu_composition.debug_bands) on the host capture path.
const Menu := preload("res://scripts/ray_menu.gd")
const Capture := preload("res://scripts/menu_composition.gd")
const Display := preload("res://scripts/xr_display.gd")
var failures: Array[String] = []
var checks := 0
var output := ProjectSettings.globalize_path("res://../../build/output/menu-hd/bands")
func _initialize() -> void: call_deferred("run")
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)
func frames(count: int = 1) -> void:
	for i in count:
		await process_frame; await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
func run() -> void:
	DirAccess.make_dir_recursive_absolute(output)
	var viewport := SubViewport.new(); viewport.size = Vector2i(1400, 1000)
	viewport.own_world_3d = true; viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var origin := Node3D.new(); viewport.add_child(origin)
	var camera := Camera3D.new(); camera.fov = 70; camera.position.z = 1.4; origin.add_child(camera)
	var world := WorldEnvironment.new(); world.environment = Environment.new(); viewport.add_child(world)
	var display := Display.new(); display.configure(viewport, world.environment, null, true)
	var menu := Menu.new(); viewport.add_child(menu); menu.visible = true
	menu._set_backdrop(Vector2(1.55, 1.08))
	menu._label("最近播放 Recent", Vector3(-0.5, 0.45, 0.006), 23)
	menu._button(42, "Select", Vector2(0.4, 0.1), Vector2(0.25, 0.08), true)
	menu._label("显示质量", Vector3(-0.5, 0.1, 0.006), 18)
	menu._button(43, "全部", Vector2(0.4, -0.45), Vector2(0.2, 0.07), true, "", true)
	var side := Node3D.new(); side.transform = Transform3D(Basis(Vector3.UP, deg_to_rad(24)), Vector3(-0.98, 0, 0.12))
	menu.add_child(side)
	side.add_child(menu._quad(Vector2(0.44, 1.08), Vector3.ZERO, menu.PANEL, 10))
	menu._button(44, "Side", Vector2(0, 0.1), Vector2(0.35, 0.10), true, "folder", false, side)
	await frames(1)

	var capture := Capture.new(); capture.debug_bands = true; viewport.add_child(capture)
	capture.configure(origin, camera, display, [menu], false, true); capture.set_process(false)
	capture.update(); await frames(3)
	capture.update(); await frames(2)
	var total := 0
	for kind in Capture.BAND_POOLS: total += int(Capture.BAND_POOLS[kind].count) + int(Capture.BAND_POOLS[kind].has("block"))
	check(capture.bands.size() == total, "Band layers are allocated")
	for index in [0, 1]:
		var slot: Dictionary = capture.slots[index]
		check(slot.raw.size == Vector2i(16, 16) and not slot.used and slot.layer.layer_viewport == null,
			"Replaced slot %d stays unused, tiny and unsubmitted" % index)
	var used: Array = capture.bands.filter(func(b): return b.used and b.kind == "panel")
	var side_used: Array = capture.bands.filter(func(b): return b.used and b.kind == "tall")
	# Title, button row, label row and bottom row: three or four bands, never the whole panel height.
	check(used.size() >= 2 and used.size() <= 4, "Text rows take a few bands: %d" % used.size())
	var band_height: float = used[0].rect.size.y if not used.is_empty() else 0.0
	check(used.size() * band_height < 1.08, "Bands cover less than the panel height")
	var title: Label3D = menu._labels[0]
	check(title.layers & int(Capture.BAND_POOLS.panel.bit) != 0 and title.layers & 1 != 0, "Panel nodes draw in the eye buffer and the bands")
	check(side_used.size() == 1, "The side column's single row takes one side band: %d" % side_used.size())
	check(side.get_child(0).layers & int(Capture.BAND_POOLS.tall.bit) != 0 and side.get_child(0).layers & int(Capture.BAND_POOLS.panel.bit) == 0,
		"Side nodes use only the side band bit")
	check(used.all(func(b): return b.hole.material_override.render_priority == Capture.BAND_HOLE_PRIORITY), "Band holes clear after panel content")
	for kind in Capture.BAND_POOLS:
		var orders: Array = capture.bands.filter(func(b): return b.kind == kind).map(func(b): return b.layer.sort_order)
		check(orders.all(func(o): return o == orders[0] and o < 0), "%s bands share one order below the eye buffer" % kind)
	var snap: Dictionary = capture.snapshot()
	check(snap.bands == used.size() + side_used.size() and snap.band_overflow == 0, "Snapshot reports bands")
	for index in side_used.size():
		side_used[index].raw.get_texture().get_image().save_png(output.path_join("side_%d.png" % index))
	for index in used.size():
		used[index].raw.get_texture().get_image().save_png(output.path_join("band_%d.png" % index))
		var image: Image = used[index].raw.get_texture().get_image()
		var opaque := 0
		for x in range(0, image.get_width(), 64): opaque += int(image.get_pixel(x, image.get_height() / 2).a > 0.9)
		# The footer controls sit below the panel; their band is transparent between buttons.
		if index == 0: check(opaque > image.get_width() / 64 / 2, "The title band captures the opaque panel behind its text")
	viewport.get_texture().get_image().save_png(output.path_join("eye.png"))
	check(not snap.band_block, "Sparse pages need no merge block")
	# A dense list: twelve rows 0.07 m apart need more bands than the pool; they merge into a block.
	for row in 12: menu._label("Row %d 行" % row, Vector3(-0.3, 0.35 - row * 0.07, 0.006), 18)
	await frames(2) # Label3D bounds exist after the first draw.
	capture.invalidate(); capture.update(); await frames(3)
	capture.update(); await frames(2)
	var dense: Dictionary = capture.snapshot()
	check(dense.band_block and dense.band_overflow == 0, "Dense rows merge into the block without overflow: %s" % [dense])
	var block: Dictionary = capture.bands.filter(func(b): return b.block)[0]
	check(block.layer.sort_order == capture.bands.filter(func(b): return b.kind == "panel" and not b.block)[0].layer.sort_order,
		"The block shares the panel bands' order")
	block.raw.get_texture().get_image().save_png(output.path_join("block.png"))
	print("Menu bands: %d checks, %d failures" % [checks, failures.size()])
	for failure in failures: print("FAIL: " + failure)
	quit(1 if failures.size() else 0)
