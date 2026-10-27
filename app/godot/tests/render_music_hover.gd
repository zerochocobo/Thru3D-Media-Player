extends SceneTree
## Exercise real library rays and the production capture before the first redraw as well as
## after GPU rendering: an unchanged final picture alone misses the one-frame XR size jump.
const Library := preload("res://scripts/library_menu.gd")
const Quick := preload("res://scripts/music_quick_controls.gd")
const Capture := preload("res://scripts/menu_composition.gd")
var checks := 0
var failures: Array[String] = []
var output := ProjectSettings.globalize_path("res://../../build/output/music-hover-20261027")

func _initialize() -> void: run.call_deferred()
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)
func frame() -> void:
	await process_frame; await RenderingServer.frame_post_draw
func settle(capture: Node) -> void:
	await frame(); capture.update(); await frame(); capture.update()
func button(menu: Node, target: int) -> Dictionary:
	for item in menu._buttons:
		if item.target == target: return item
	return {}
func hover(menu: Node3D, target: int, hand: String) -> void:
	var node: Node3D = button(menu, target).node
	menu.update_pointer(hand, Vector3.ZERO, node.global_position.normalized(), true)
func slot_with(capture: Node, node: Node) -> Dictionary:
	for slot in capture.slots:
		if slot.used and slot.nodes.has(node): return slot
	return {}
func geometry(slot: Dictionary) -> Array:
	return [slot.index, slot.key, slot.rect, slot.relative, slot.layer.global_transform,
		slot.layer.quad_size, slot.camera.global_transform, slot.camera.size, slot.raw.size]
func preserved(menu: Node, controls: Dictionary, list_id: int) -> bool:
	if menu._list.get_instance_id() != list_id: return false
	for target in controls:
		var current := button(menu, target)
		if current.is_empty() or current.node.get_instance_id() != controls[target]: return false
	return true

func scenario(low_end: bool, view: String) -> void:
	var name := ("low-" if low_end else "quest3-") + view
	var viewport := SubViewport.new(); viewport.size = Vector2i(1000, 900)
	viewport.own_world_3d = true; viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS; root.add_child(viewport)
	var origin := Node3D.new(); viewport.add_child(origin)
	var camera := Camera3D.new(); origin.add_child(camera)
	var menu := Library.new(); origin.add_child(menu); menu.set_process(false)
	menu.visible = true; menu.section = Library.Section.LOCAL; menu.view_mode = view
	var audio := {"audio_title": "A calm evening.mp3", "audio_active": true, "audio_current": "sample", "audio_paused": false}
	menu.background_audio_provider = func(): return audio
	for i in range(28):
		menu._local_entries.append({"uri": "file:///sample-%02d.mp4" % i, "title": "Sample %02d.mp4" % i, "kind": "video"})
	menu.refresh(); menu._set_scroll(1.0, false)
	# Normal pointer processing applies disabled/selected colours before the reference capture.
	menu.update_pointer("left_hand", Vector3.ZERO, Vector3.FORWARD, false)
	menu.update_pointer("right_hand", Vector3.ZERO, Vector3.FORWARD, false)
	var capture := Capture.new(); viewport.add_child(capture)
	capture.configure(origin, camera, null, [menu], low_end, true); capture.set_process(false)
	await frame(); await frame(); capture.update(); await settle(capture)
	var main := slot_with(capture, menu._backdrop)
	var side := slot_with(capture, button(menu, Library.NAV_BASE + Library.Section.LOCAL).node)
	var main_geometry := geometry(main); var side_geometry := geometry(side)
	var pose := menu.global_transform; var scroll: float = menu.scroll
	var rows: Array = menu.rows.duplicate(true); var list_id: int = menu._list.get_instance_id()
	var controls := {}
	for item in menu._buttons:
		if item.target != Library.MUSIC_OPEN: controls[item.target] = item.node.get_instance_id()
	# Top 80% excludes only the floating footer. All file pixels must stay fixed.
	var region := Rect2i(Vector2i.ZERO, Vector2i(main.raw.size.x, int(main.raw.size.y * 0.8)))
	var baseline: PackedByteArray = main.raw.get_texture().get_image().get_region(region).get_data()
	main.raw.get_texture().get_image().save_png(output.path_join(name + "-before.png"))
	var fixed_sizes: Array = capture.slots.map(func(slot): return slot.raw.size)
	for hand in ["left_hand", "right_hand"]:
		for cycle in range(2):
			hover(menu, Library.MUSIC_OPEN, hand)
			menu.music_quick._entered[hand] = Time.get_ticks_msec() - Quick.ENTER_MS - 1
			hover(menu, Library.MUSIC_OPEN, hand); capture.update()
			check(menu.music_quick.expanded and geometry(main) == main_geometry and geometry(side) == side_geometry,
				name + ": first hover frame preserves both panels' capture size, depth and pose")
			check(preserved(menu, controls, list_id) and menu.rows == rows and menu.scroll == scroll and menu.global_transform == pose,
				name + ": hover preserves file nodes, data, scroll and menu pose")
			var popup := slot_with(capture, button(menu, Quick.PLAY).node)
			check(not popup.is_empty() and popup.index != main.index and popup.index != side.index,
				name + ": expanded transport uses an existing popup slot")
			check(capture.slots.map(func(slot): return slot.raw.size) == fixed_sizes and capture.slots.size() == Capture.SLOT_METRES.size(),
				name + ": retains the existing five fixed capture viewport sizes")
			await settle(capture)
			check(geometry(main) == main_geometry and main.raw.get_texture().get_image().get_region(region).get_data() == baseline,
				name + ": rendered file panel remains pixel-identical")
			if cycle == 0 and hand == "left_hand":
				main.raw.get_texture().get_image().save_png(output.path_join(name + "-expanded-panel.png"))
				popup.raw.get_texture().get_image().save_png(output.path_join(name + "-music.png"))
			hover(menu, Quick.PLAY, hand)
			audio.audio_paused = not audio.audio_paused; audio.audio_title = "Another track.mp3" if cycle == 0 else "A calm evening.mp3"
			menu.refresh_background_audio(); capture.update()
			check(geometry(main) == main_geometry and preserved(menu, controls, list_id),
				name + ": playback/title updates leave the file panel intact")
			var play: Dictionary = button(menu, Quick.PLAY)
			check(play.node.get_child(1).material_override.albedo_texture == menu.Icons.texture("play" if audio.audio_paused else "pause"),
				name + ": transport still shows the current play state")
			menu.music_quick._last_inside = Time.get_ticks_msec() - Quick.LEAVE_MS - 1
			menu.update_pointer(hand, Vector3.ZERO, Vector3.FORWARD, false); capture.update()
			check(not menu.music_quick.expanded and geometry(main) == main_geometry and geometry(side) == side_geometry,
				name + ": collapse preserves both panels on its first frame")
			check(preserved(menu, controls, list_id) and menu._ray_blockers.all(func(item): return is_instance_valid(item.node)),
				name + ": repeated hover leaves no freed ray blockers or rebuilt file nodes")
			await settle(capture)
			check(main.raw.get_texture().get_image().get_region(region).get_data() == baseline,
				name + ": collapsed file panel stays pixel-identical")
	capture.shutdown("test_complete"); viewport.queue_free(); await process_frame

func run() -> void:
	DirAccess.make_dir_recursive_absolute(output)
	for low_end in [false, true]:
		for view in ["grid", "list"]: await scenario(low_end, view)
	for failure in failures: push_error(failure)
	print("Music hover rendering: %d checks, %d failures" % [checks, failures.size()])
	quit(1 if not failures.is_empty() else 0)
