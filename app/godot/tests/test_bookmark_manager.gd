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

func _initialize() -> void: run.call_deferred()

func run() -> void:
	var markers: Array = []; var loops: Array = []
	for index in 14: markers.append({"id": str(index), "position_ms": 10000 * (index + 1)})
	for index in 7: loops.append({"id": "loop" + str(index), "a": str(index * 2), "b": str(index * 2 + 1), "a_ms": 10000 * (index * 2 + 1), "b_ms": 10000 * (index * 2 + 2)})
	var state := {"has_video": true, "bookmarks": markers, "bookmark_loops": loops, "bookmark_scope": "manager", "bookmark_ready": true, "bookmark_seekable": true, "duration_ms": 180000}
	var menu := Menu.new(); menu.state_provider = func(): return state
	root.add_child(menu); menu.toggle(); menu.set_process(false)
	var requests: Array = []
	menu.bookmark_loop_requested.connect(func(op, payload, _scope): requests.append([op, payload]))
	tap(menu, menu.BookmarkMenu.LIST)
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
	menu.free()
	print("Bookmark manager: %d checks, %d failures" % [checks, failures.size()])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)
