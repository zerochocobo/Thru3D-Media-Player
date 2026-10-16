extends SceneTree
## Compositor slot shapes follow the real menu planes: the compositor reads every slot pixel each
## frame, so a short control bar must not occupy the square library slot.
const Library := preload("res://scripts/library_menu.gd")
const Player := preload("res://scripts/player_menu.gd")
const Capture := preload("res://scripts/menu_composition.gd")
const Display := preload("res://scripts/xr_display.gd")
var failures: Array[String] = []
var checks := 0

func _initialize() -> void: call_deferred("run")

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func frames(count := 1) -> void:
	for i in count:
		await process_frame; await RenderingServer.frame_post_draw

func settle(capture: Node) -> void:
	await frames(2); capture.update(); await frames(1); capture.update()

func used(capture: Node) -> Array:
	return capture.slots.filter(func(slot): return slot.used)

func pixels(slots: Array) -> int:
	return slots.reduce(func(total, slot): return total + slot.raw.size.x * slot.raw.size.y, 0)

func run() -> void:
	var viewport := SubViewport.new(); viewport.size = Vector2i(800, 600); viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS; root.add_child(viewport)
	var origin := Node3D.new(); viewport.add_child(origin)
	var camera := Camera3D.new(); camera.position = Vector3(0, 0, 1.6); origin.add_child(camera)
	var world := WorldEnvironment.new(); world.environment = Environment.new(); viewport.add_child(world)
	var display := Display.new(); display.configure(viewport, world.environment, null, true)
	var state := {"has_video": true, "source_uri": "file:///disk/4.mp4", "title": "Sample.mp4", "playing": true,
		"position_ms": 90000, "duration_ms": 180000, "seekable": true}
	var library := Library.new(); origin.add_child(library)
	var player := Player.new(); origin.add_child(player); player.set_process(false); player.state_provider = func(): return state
	player.expanded_library = library
	var capture := Capture.new(); viewport.add_child(capture)
	capture.configure(origin, camera, display, [library, player], false, true); capture.set_process(false)

	library.visible = true
	library._activate(Library.NAV_BASE + Library.Section.SETTINGS)
	await settle(capture)
	var browsing := used(capture)
	check(browsing.map(func(slot): return slot.index) == [0, 1], "Library uses the panel and side-column slots: " + str(browsing.map(func(slot): return slot.index)))
	for slot in browsing:
		var density: float = slot.raw.size.x / slot.layer.quad_size.x
		check(density >= Capture.DENSITY * 0.95, "Library keeps its capture density: %.0f px/m" % density)
		check(absf(slot.layer.quad_size.aspect() - slot.rect.size.aspect()) < 0.1, "Slot shape fits its plane: %s for %s" % [slot.layer.quad_size, slot.rect.size])
	check(pixels(browsing) < 7_600_000, "Library layers stay under 7.6 MP: %d" % pixels(browsing))
	check(browsing.all(func(slot): return (slot.camera.cull_mask & Capture.GROUP_MASK) == slot.camera.cull_mask and slot.camera.cull_mask != 0),
		"Each slot captures one menu render bit")

	library.dismiss(); library.visible = false
	player.visible = true; player._reset_navigation(); player.refresh()
	await settle(capture)
	var bar := used(capture)
	check(bar.size() == 1 and bar[0].index == 4, "The control bar takes the bar slot")
	check(pixels(bar) < 2_400_000, "The control bar reads under 2.4 MP: %d" % pixels(bar))
	check(bar[0].raw.size.x / bar[0].layer.quad_size.x >= Capture.DENSITY * 0.95, "The bar keeps the capture density")
	check(capture.slots[0].layer.quad_size.x < 0.001, "The library slot stays parked during playback")
	player.section = 1; player.refresh()
	await settle(capture)
	check(used(capture).map(func(slot): return slot.index) == [0], "Bar plus settings panel moves to the panel slot")
	check(capture.slots[4].layer.quad_size.x < 0.001, "The idle bar slot parks")
	player.section = 0; player.refresh()
	await settle(capture)
	check(used(capture).map(func(slot): return slot.index) == [4] and used(capture)[0].rect.size.y < 0.7,
		"Closing settings returns to the bar slot without its grown rectangle")

	# On a headset the player's popups sit on their own tilted plane. Closed, that plane must not
	# keep a (transparent) layer the compositor reads every frame.
	var upper := Node3D.new(); upper.transform = Transform3D(Basis(Vector3.RIGHT, deg_to_rad(-12)), Vector3(0, 0.6, 0.05))
	player.add_child(upper)
	upper.add_child(player._quad(Vector2(1.1, 0.6), Vector3.ZERO, player.PANEL, 10))
	player._label("Upper popup", Vector3(0, 0, 0.004), 20, upper)
	player.composition_layout_changed.emit()
	await settle(capture)
	check(used(capture).size() == 2 and used(capture).all(func(slot): return slot.layer.quad_size.x > 0.1), "An open upper surface gets its own layer")
	upper.visible = false
	player.composition_changed.emit()
	await settle(capture)
	var parked: Array = capture.slots.filter(func(slot): return slot.used and slot.empty)
	check(parked.size() == 1 and parked[0].layer.quad_size.x < 0.001 and not parked[0].hole.visible, "A hidden plane parks its slot")
	check(capture.snapshot().layers == 1, "Only the bar is reported as a live layer")
	upper.visible = true
	player.composition_changed.emit()
	await settle(capture)
	check(used(capture).all(func(slot): return not slot.empty and slot.layer.quad_size.x > 0.1), "Showing the plane again restores its layer")
	upper.queue_free(); await frames(1)

	var low := Capture.new(); viewport.add_child(low)
	low.configure(origin, camera, display, [], true, true); low.set_process(false)
	for index in Capture.SLOT_METRES.size():
		var high_size: Vector2i = capture.slots[index].raw.size
		var low_size: Vector2i = low.slots[index].raw.size
		check(absf(float(low_size.x) / high_size.x - Capture.LOW_END_SCALE) < 0.02, "Low-end slot %d scales to %.2f: %s" % [index, Capture.LOW_END_SCALE, low_size])
	for failure in failures: push_error(failure)
	print("Menu slots: %d checks, %d failures" % [checks, failures.size()])
	quit(1 if not failures.is_empty() else 0)
