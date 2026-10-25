extends SceneTree
const Menu := preload("res://scripts/player_menu.gd")
var failures: Array[String] = []
var checks := 0

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func origin(menu: Node3D, target: int) -> Vector3:
	for button in menu._buttons:
		if button.target == target: return button.node.global_position + button.node.global_basis.z
	return Vector3.ZERO

func tap(menu: Node3D, target: int) -> void:
	var point := origin(menu, target)
	check(point != Vector3.ZERO, "Control exists: " + str(target))
	menu.press_pointer("left_hand", point, -menu.global_basis.z, true)
	menu.release_pointer("left_hand", point, -menu.global_basis.z, true)

func button(menu: Node3D, target: int) -> Dictionary:
	return menu._buttons.filter(func(item): return item.target == target)[0]

func check_two_marker_creation() -> void:
	var markers := [{"id": "a", "position_ms": 10000}, {"id": "b", "position_ms": 30000}]
	var state := {"has_video": true, "bookmarks": markers, "bookmark_loops": [], "bookmark_scope": "two-markers", "bookmark_ready": true, "bookmark_seekable": true, "duration_ms": 120000}
	var menu := Menu.new(); menu.state_provider = func(): return state
	root.add_child(menu); menu.toggle(); menu.set_process(false)
	var requests: Array = []
	menu.bookmark_loop_requested.connect(func(op, payload, _scope):
		requests.append([op, payload])
		if op == "save": state.bookmark_loops = [{"id": "saved", "a": payload.a, "b": payload.b, "a_ms": 10000, "b_ms": 30000}])
	tap(menu, menu.BookmarkMenu.LIST); tap(menu, menu.BookmarkMenu.NEW_LOOP)
	check(not button(menu, menu.BookmarkMenu.SAVE).enabled, "Empty two-marker draft cannot save")
	check(menu._tips[menu.BookmarkMenu.SAVE] == menu.I18n.t("Choose start bookmark"), "Disabled save explains missing A on hover")
	var point := origin(menu, menu.BookmarkMenu.SAVE)
	menu.update_pointer("right_hand", point, -menu.global_basis.z, true)
	check(menu._tooltip.visible and menu._tooltip.get_child(0).text == menu.I18n.t("Choose start bookmark"), "Disabled save actually shows its reason through the ray pointer")
	menu.update_pointer("right_hand", point, -menu.global_basis.z, false)
	tap(menu, menu.BookmarkMenu.EDIT_A); tap(menu, menu.BookmarkMenu.ROW)
	check(menu.bookmarks.editing.a == "a" and menu.bookmarks.picker == "b", "Two-marker A selection advances to B")
	check(button(menu, menu.BookmarkMenu.ROW).node.material_override.get_shader_parameter("surface_color") == menu.SELECTED, "Chosen A stays visibly selected while picking B")
	check(not button(menu, menu.BookmarkMenu.SAVE).enabled, "A alone cannot save")
	check(menu._tips[menu.BookmarkMenu.SAVE] == menu.I18n.t("Choose end bookmark"), "Disabled save explains missing B on hover")
	tap(menu, menu.BookmarkMenu.EDIT_B); tap(menu, menu.BookmarkMenu.ROW + 1)
	var save := button(menu, menu.BookmarkMenu.SAVE)
	check(menu.bookmarks.editing.b == "b" and save.enabled, "Exactly two valid markers enable save")
	check(save.base_color == menu.ACCENT and save.node.material_override.get_shader_parameter("surface_color") == menu.ACCENT, "Ready save has a visible accent surface without hovering")
	tap(menu, menu.BookmarkMenu.SAVE)
	check(requests.size() == 1 and requests[0][0] == "save" and requests[0][1].a == "a" and requests[0][1].b == "b", "Two-marker check sends the chosen pair once")
	check(menu.bookmarks.editing.is_empty() and menu.bookmarks.targets[menu.BookmarkMenu.LOOP_ROW].id == "saved", "Saving two-marker draft displays its complete range")
	# Endpoint selection must also accept the timeline markers the user already sees.
	state.bookmark_loops = []; menu.refresh()
	tap(menu, menu.BookmarkMenu.NEW_LOOP)
	check(menu._labels.any(func(label): return label.text == "← " + menu.I18n.t("Choose start bookmark") and label.horizontal_alignment == HORIZONTAL_ALIGNMENT_LEFT and label.position.x < 0 and is_equal_approx(label.position.y, 0.49)), "Start guidance stays above the editor and aligns left")
	point = origin(menu, menu.BookmarkMenu.GROUP)
	menu.press_pointer("left_hand", point, -menu.global_basis.z, true)
	menu.bookmarks.picker = "b"; menu.refresh()
	menu.release_pointer("left_hand", point, -menu.global_basis.z, true)
	check(menu.bookmarks.editing.a.is_empty() and menu.bookmarks.editing.b.is_empty(), "Changing the endpoint cancels a held timeline selection")
	tap(menu, menu.BookmarkMenu.EDIT_A)
	tap(menu, menu.BookmarkMenu.GROUP)
	check(menu.bookmarks.editing.get("a") == "a" and menu.bookmarks.picker == "b", "Timeline bookmark chooses A without seeking")
	menu.refresh_values()
	check(not button(menu, menu.BookmarkMenu.GROUP).enabled, "Value refresh cannot re-enable A as its own B candidate")
	check(menu._labels.any(func(label): return label.text == "← " + menu.I18n.t("Choose end bookmark") and label.horizontal_alignment == HORIZONTAL_ALIGNMENT_LEFT and label.position.x < 0 and is_equal_approx(label.position.y, 0.49)), "After choosing A, the editor's left-aligned guidance advances to B")
	tap(menu, menu.BookmarkMenu.GROUP + 1)
	check(menu.bookmarks.editing.get("b") == "b" and button(menu, menu.BookmarkMenu.SAVE).enabled and requests.size() == 1, "Timeline bookmark chooses B without saving or starting playback")
	tap(menu, menu.BookmarkMenu.CANCEL_EDIT)
	# A dense timeline group opens its points without resetting the current draft.
	state.duration_ms = 7200000; menu.refresh()
	tap(menu, menu.BookmarkMenu.NEW_LOOP); tap(menu, menu.BookmarkMenu.ROW)
	tap(menu, menu.BookmarkMenu.GROUP)
	check(menu.bookmarks.editing.get("a") == "a" and menu.bookmarks.picker == "b" and menu.bookmarks.subset.size() == 2, "Timeline cluster preserves A and offers exact B choices")
	tap(menu, menu.BookmarkMenu.ROW + 1)
	check(menu.bookmarks.editing.get("b") == "b" and button(menu, menu.BookmarkMenu.SAVE).enabled, "Cluster choice completes the existing draft")
	tap(menu, menu.BookmarkMenu.CANCEL_EDIT)
	state.duration_ms = 120000
	# A point less than two seconds after A must explain why it cannot become B.
	state.bookmark_loops = []; markers[1].position_ms = 11500; menu.refresh()
	tap(menu, menu.BookmarkMenu.NEW_LOOP); tap(menu, menu.BookmarkMenu.ROW)
	var invalid := button(menu, menu.BookmarkMenu.ROW + 1)
	check(not invalid.enabled and invalid.get("hover_disabled", false), "Too-close B remains disabled but exposes hover feedback")
	check(menu._tips.get(menu.BookmarkMenu.ROW + 1) == menu.I18n.t("Invalid loop range"), "Too-close B explains minimum loop length")
	point = origin(menu, menu.BookmarkMenu.ROW + 1)
	menu.update_pointer("right_hand", point, -menu.global_basis.z, true)
	check(menu._tooltip.visible and menu._tooltip.get_child(0).text == menu.I18n.t("Invalid loop range"), "Too-close B actually exposes the minimum length reason on hover")
	menu.update_pointer("right_hand", point, -menu.global_basis.z, false)
	tap(menu, menu.BookmarkMenu.ROW + 1); tap(menu, menu.BookmarkMenu.SAVE)
	check(menu.bookmarks.editing.b.is_empty() and requests.size() == 1, "Invalid endpoint cannot silently select or save")
	markers[1].position_ms = 12000; menu.refresh()
	tap(menu, menu.BookmarkMenu.ROW + 1)
	check(button(menu, menu.BookmarkMenu.SAVE).enabled, "Exactly two-second range is allowed")
	menu.free()

func _initialize() -> void: run.call_deferred()

func run() -> void:
	check_two_marker_creation()
	var markers: Array = []; var loops: Array = []
	for index in 14: markers.append({"id": str(index), "position_ms": 10000 * (index + 1)})
	for index in 7: loops.append({"id": "loop" + str(index), "a": str(index * 2), "b": str(index * 2 + 1), "a_ms": 10000 * (index * 2 + 1), "b_ms": 10000 * (index * 2 + 2)})
	var state := {"has_video": true, "bookmarks": markers, "bookmark_loops": loops, "bookmark_scope": "manager", "bookmark_ready": true, "bookmark_seekable": true, "duration_ms": 180000, "capture": {"loop_available": true}}
	var menu := Menu.new(); menu.state_provider = func(): return state
	root.add_child(menu); menu.toggle(); menu.set_process(false)
	var requests: Array = []
	menu.bookmark_loop_requested.connect(func(op, payload, _scope): requests.append([op, payload]))
	tap(menu, menu.BookmarkMenu.LIST)
	var export_ray := origin(menu, menu.BookmarkMenu.LOOP_EXPORT)
	check(menu.ray_hit(export_ray, -menu.global_basis.z).get("target") == menu.BookmarkMenu.LOOP_EXPORT, "Export icon owns its ray target beside edit and delete")
	var page_ray := origin(menu, menu.BookmarkMenu.LOOP_DOWN)
	check(menu.ray_hit(page_ray, -menu.global_basis.z).get("target") == menu.BookmarkMenu.LOOP_DOWN, "Export icons do not cover loop pagination")
	tap(menu, menu.BookmarkMenu.LOOP_EXPORT)
	check(requests.size() == 1 and requests[0][0] == "export" and requests[0][1].id == "loop0" and menu.bookmarks.opened, "Export icon sends the selected loop definition without dismissing its list")
	state.capture.merge({"clip_busy": true, "loop_exports": {"loop0": 42}}); menu.refresh_values()
	check(button(menu, menu.BookmarkMenu.LOOP_EXPORT).node.get_child(0).text == "42%" and not button(menu, menu.BookmarkMenu.LOOP_EXPORT + 1).enabled, "Per-loop progress replaces the icon and blocks another export")
	tap(menu, menu.BookmarkMenu.LOOP_EXPORT)
	check(requests.size() == 1, "Saving progress cannot submit another request")
	state.capture.merge({"clip_busy": false, "loop_exports": {}}); menu.refresh_values(); requests.clear()
	var many: Array = []
	for index in 500: many.append({"id": "many" + str(index), "a": "0", "b": "1", "a_ms": 10000, "b_ms": 30000 + index})
	state.bookmark_loops = many; menu.refresh()
	var unique_targets := {}
	for item in menu._buttons: unique_targets[item.target] = true
	check(unique_targets.size() == menu._buttons.size(), "Five hundred range targets cannot shadow the export action")
	state.bookmark_loops = loops; menu.refresh()
	tap(menu, menu.BookmarkMenu.DOWN)
	check(menu.bookmarks.offset == 5 and menu.bookmarks.loop_offset == 0, "Left paging preserves right position")
	tap(menu, menu.BookmarkMenu.LOOP_DOWN)
	check(menu.bookmarks.offset == 5 and menu.bookmarks.loop_offset == 2, "Right paging preserves left position and clamps")
	var point := origin(menu, menu.BookmarkMenu.LOOP_ROW)
	menu.update_pointer("left_hand", point, -menu.global_basis.z, true)
	menu.stick_scroll(1, 1)
	check(menu.bookmarks.loop_offset == 0 and menu.bookmarks.offset == 5, "Ray hover directs stick scrolling to loops")
	point = origin(menu, menu.BookmarkMenu.ROW)
	menu.update_pointer("left_hand", point, -menu.global_basis.z, true)
	menu.stick_scroll(1, 1)
	check(menu.bookmarks.offset == 0 and menu.bookmarks.loop_offset == 0, "Ray hover directs stick scrolling to bookmarks")
	point = origin(menu, menu.BookmarkMenu.LOOP_ROW)
	menu.press_pointer("left_hand", point, -menu.global_basis.z, true)
	menu.update_pointer("left_hand", point + Vector3(0, 0.14, 0), -menu.global_basis.z, true)
	menu.release_pointer("left_hand", point, -menu.global_basis.z, true)
	check(menu.bookmarks.loop_offset == 2 and menu.bookmarks.offset == 0 and requests.is_empty(), "Dragging range scrolls only right and never starts playback")
	tap(menu, menu.BookmarkMenu.LOOP_EDIT)
	check(menu.bookmarks.editing.id == "loop2" and menu.bookmarks.targets.has(menu.BookmarkMenu.ROW), "Scrolled range edits with left list intact")
	check(menu._labels.any(func(label): return label.text == "← " + menu.I18n.t("Choose end bookmark") and label.horizontal_alignment == HORIZONTAL_ALIGNMENT_LEFT and label.position.x < 0 and is_equal_approx(label.position.y, 0.49)), "Saved-pair editing keeps replacement guidance left-aligned above its editor")
	tap(menu, menu.BookmarkMenu.DOWN); tap(menu, menu.BookmarkMenu.DOWN)
	check(menu.bookmarks.offset == 9 and menu.bookmarks.loop_offset == 2, "Endpoint picker reaches distant bookmarks independently")
	tap(menu, menu.BookmarkMenu.ROW + 4)
	check(menu.bookmarks.editing.b == "13" and state.bookmark_loops[2].b == "5", "Remote choice is staged, not committed")
	tap(menu, menu.BookmarkMenu.SAVE)
	check(requests.size() == 1 and not menu.bookmarks.editing.is_empty(), "Rejected save preserves draft and context")
	# Refresh between press and release must not commit the previous marker/draft.
	point = origin(menu, menu.BookmarkMenu.SAVE)
	menu.press_pointer("left_hand", point, -menu.global_basis.z, true)
	menu.bookmarks.editing.b = "12"; menu.refresh()
	menu.release_pointer("left_hand", point, -menu.global_basis.z, true)
	check(requests.size() == 1, "Changed draft invalidates held save trigger")
	tap(menu, menu.BookmarkMenu.CANCEL_EDIT)
	menu.bookmarks.loop_offset = 0; menu.refresh()
	tap(menu, menu.BookmarkMenu.LOOP_EDIT + 4)
	check(menu.bookmarks.editing.id == "loop4" and menu.bookmarks.targets[menu.BookmarkMenu.LOOP_ROW + 2].id == "loop4", "Editing fifth row keeps that saved pair visible above inline editor")
	tap(menu, menu.BookmarkMenu.CANCEL_EDIT)
	state.bookmarks = []; state.bookmark_loops = []; state.bookmark_undo = true; menu.refresh()
	check(menu.bookmarks.opened and origin(menu, menu.BookmarkMenu.PANEL_UNDO) != Vector3.ZERO, "Deleting final point retains empty manager and undo")
	state.bookmarks = markers; state.bookmark_loops = loops; menu.refresh()
	tap(menu, menu.BookmarkMenu.LOOP_EDIT)
	state.bookmark_loops = []; menu.refresh()
	check(menu.bookmarks.editing.is_empty() and menu.bookmarks.opened, "Externally deleted edited segment cancels draft without leaving page")
	check(menu.bookmarks.targets.values().filter(func(item): return item.kind == "group").all(func(item): return item.end.is_empty()), "External deletion also clears timeline endpoint selection in the same redraw")
	menu.free()
	print("Bookmark manager: %d checks, %d failures" % [checks, failures.size()])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)
