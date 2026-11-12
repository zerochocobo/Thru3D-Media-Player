extends SceneTree
## Scrolling keeps drawn rows: settings pages draw every row once and only move them; plain file
## lists and grids recycle one line at a time into the same target slots. Each check compares the
## recycled state with a fresh draw at the same scroll, and that captured rows keep their layer bit.
const Library := preload("res://scripts/library_menu.gd")
const Capture := preload("res://scripts/menu_composition.gd")
const Display := preload("res://scripts/xr_display.gd")
var failures: Array[String] = []
var checks := 0

class RecentCatalog extends RefCounted:
	func list_recent() -> Array[Dictionary]:
		var result: Array[Dictionary] = []
		for index in 12: result.append({"uri": "file:///recent/%d.mp4" % index, "title": "Recent %d" % index, "position_ms": 1000})
		return result
	func lookup(uri: String) -> Dictionary: return {"uri": uri}

func _initialize() -> void: call_deferred("run")

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func frames(count := 1) -> void:
	for i in count:
		await process_frame; await RenderingServer.frame_post_draw

## Target -> row title of every visible row button, as the ray would choose it.
func shown_rows(library: Node) -> Dictionary:
	var result := {}
	for button in library._buttons:
		if not library._row_target(int(button.target)) or not button.node.is_visible_in_tree(): continue
		var index: int = library._row_index(int(button.target) - Library.ROW_BASE)
		var label: Label3D = button.node.get_child(0)
		result[int(index)] = [str(library.rows[index].title), label.text]
	return result

## Render bit -> how many list nodes carry it, after checking each node sits in the slot of that bit.
func plane_counts(library: Node, capture: Node) -> Dictionary:
	var result := {}
	for node in library._list.find_children("*", "VisualInstance3D", true, false):
		if node.has_meta("menu_eye_buffer") or not node.is_visible_in_tree(): continue
		var holders: Array = capture.slots.filter(func(slot): return slot.used and slot.nodes.has(node))
		var bit: int = holders[0].camera.cull_mask if holders.size() == 1 else -1
		if bit != node.layers: bit = -2
		result[bit] = result.get(bit, 0) + 1
	return result

func run() -> void:
	var viewport := SubViewport.new(); viewport.size = Vector2i(800, 600); viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS; root.add_child(viewport)
	var origin := Node3D.new(); viewport.add_child(origin)
	var camera := Camera3D.new(); camera.position = Vector3(0, 0, 1.6); origin.add_child(camera)
	var world := WorldEnvironment.new(); world.environment = Environment.new(); viewport.add_child(world)
	var display := Display.new(); display.configure(viewport, world.environment, null, true)
	var library := Library.new(); origin.add_child(library); library.set_process(false)
	var capture := Capture.new(); viewport.add_child(capture)
	capture.configure(origin, camera, display, [library], false, true); capture.set_process(false)
	library.visible = true

	# Settings: one drawn list for the whole scroll.
	library._activate(Library.NAV_BASE + Library.Section.SETTINGS)
	library._activate(Library.TAB_BASE + Library.DISPLAY_TAB)
	await frames(2); capture.update()
	check(library._full_list() and library._max_scroll() > 0, "Display settings scroll as one full list")
	var settings_list: Node3D = library._list
	for i in 120: library.stick_scroll(-1.0, 1.0 / 72.0)
	check(library._list == settings_list, "Scrolling settings keeps the drawn rows")
	check(library.scroll > 1.0, "Settings scrolled: %.2f" % library.scroll)
	var moved := shown_rows(library)
	library.scroll = roundf(library.scroll); library._place_list(); moved = shown_rows(library)
	library.refresh()
	check(shown_rows(library) == moved, "Scrolled settings rows match a fresh draw")
	check(moved.size() == Library.VISIBLE_ROWS, "Settings show %d rows: %d" % [Library.VISIBLE_ROWS, moved.size()])
	for index in moved: check(moved[index][1].begins_with(moved[index][0].left(4)), "Settings row %d shows its title: %s" % [index, moved[index]])

	# Files: list and grid recycle lines.
	library.section = Library.Section.LOCAL
	library._local_stack = [{"id": "internal", "title": "Internal", "path": "/sdcard"}]
	var entries := []
	for i in 667: entries.append({"title": "Shot_%04d.jpg" % i, "uri": "file:///sdcard/Shots/%04d.jpg" % i, "size": 1000 + i})
	library._local_entries = entries
	for mode in ["list", "grid"]:
		library.view_mode = mode; library.scroll = 0.0; library.refresh()
		await frames(2); capture.update(); await frames(1); capture.update()
		check(library._recycled(), "%s recycles rows" % mode)
		for i in 4: capture.update()
		library.stick_scroll(-1.0, 0.2 / 72.0); capture.update()
		var rendering: Array = capture.slots.filter(func(slot): return slot.used and slot.raw.render_target_update_mode == SubViewport.UPDATE_ONCE)
		check(rendering.size() == 1 and rendering[0].index == 0 and capture.slots.filter(func(slot): return slot.used).size() >= 2,
			"%s scrolling re-renders only the list's slot: %s" % [mode, rendering.map(func(slot): return slot.index)])
		var list: Node3D = library._list
		var children := list.get_child_count()
		var buttons: int = library._buttons.size()
		for step in [-1.0, -1.0, -1.0, 1.0, -1.0]:
			for i in 50:
				library.stick_scroll(step, 1.0 / 72.0); capture.update()
		check(library._list == list, "%s scrolling keeps its list node" % mode)
		check(library.scroll >= 5.0, "%s scrolled several lines: %.2f" % [mode, library.scroll])
		check(list.get_child_count() == children and library._buttons.size() == buttons,
			"%s recycling neither leaks nor drops rows: %d/%d children, %d/%d buttons" % [mode, list.get_child_count(), children, library._buttons.size(), buttons])
		var captured := capture.slots.filter(func(slot): return slot.used and slot.nodes.has(list.get_child(0)))
		check(captured.size() == 1, "%s rows stay in one captured slot" % mode)
		if captured.size() == 1:
			var bit: int = captured[0].camera.cull_mask
			var wrong := 0
			for node in list.find_children("*", "VisualInstance3D", true, false):
				if not node.has_meta("menu_eye_buffer") and node.layers != bit: wrong += 1
			check(wrong == 0, "%s recycled rows carry the slot's render bit: %d wrong" % [mode, wrong])
		library.scroll = roundf(library.scroll); library._place_list()
		var recycled := shown_rows(library)
		check(recycled.size() == (Library.VISIBLE_ROWS if mode == "list" else Library.GRID_LINES * Library.COLS),
			"%s shows a full page: %d" % [mode, recycled.size()])
		for index in recycled: check(recycled[index][1].begins_with(recycled[index][0].left(6)), "%s row %d shows its title: %s" % [mode, index, recycled[index]])
		library.refresh()
		check(shown_rows(library) == recycled, "%s recycled rows match a fresh draw" % mode)
		# A jump past the drawn window (scrollbar) still recycles every row.
		library._set_scroll(400.0 / library._cols())
		library.scroll = roundf(library.scroll); library._place_list()
		var jumped := shown_rows(library)
		library.refresh()
		check(shown_rows(library) == jumped and not jumped.is_empty(), "%s jump matches a fresh draw" % mode)

	# Recent list rows raise their select/location/remove buttons onto a plane of their own; both
	# planes scroll, while the side column keeps its capture.
	library.catalog = RecentCatalog.new(); library.section = Library.Section.RECENT
	library.view_mode = "list"; library.scroll = 0.0; library.refresh()
	await frames(2); capture.update(); await frames(1); capture.update()
	for i in 4: capture.update()
	var list_slots: Array = capture.slots.filter(func(slot): return slot.used and slot.nodes.any(func(node): return library._list.is_ancestor_of(node))).map(func(slot): return slot.index)
	check(library._max_scroll() > 0 and list_slots.size() >= 2, "Recent list spans several planes: %s" % [list_slots])
	library.stick_scroll(-1.0, 0.2 / 72.0); capture.update()
	var repainted: Array = capture.slots.filter(func(slot): return slot.used and slot.raw.render_target_update_mode == SubViewport.UPDATE_ONCE).map(func(slot): return slot.index)
	repainted.sort(); list_slots.sort()
	check(repainted == list_slots, "Recent list scrolling re-renders every list plane only: %s of %s" % [repainted, list_slots])
	# Once its rows have been recycled away, the raised buttons' old slot still repaints instead of
	# keeping their last capture over the list.
	while library.scroll < 3.0: library.stick_scroll(-1.0, 1.0 / 72.0); capture.update()
	library.stick_scroll(-1.0, 0.2 / 72.0); capture.update()
	repainted = capture.slots.filter(func(slot): return slot.used and slot.raw.render_target_update_mode == SubViewport.UPDATE_ONCE).map(func(slot): return slot.index)
	repainted.sort()
	check(library.scroll < library._max_scroll() and repainted == list_slots, "Recycled recent rows keep re-rendering every list plane: %s of %s at %.2f" % [repainted, list_slots, library.scroll])
	# Recycled rows keep their raised buttons on the buttons' plane, as a fresh collect groups them.
	var recycled_planes := plane_counts(library, capture)
	capture.invalidate(); capture.update()
	var fresh_planes := plane_counts(library, capture)
	check(recycled_planes == fresh_planes and recycled_planes.size() >= 2, "Recycled recent rows keep each node's plane: %s, fresh %s" % [recycled_planes, fresh_planes])

	if failures.is_empty(): print("MENU_SCROLL_ROWS_OK checks=%d" % checks)
	else:
		for failure in failures: printerr("FAIL: " + failure)
	quit(0 if failures.is_empty() else 1)
