extends RefCounted
## Debug-only caller: exercise production ray/trigger methods on the real device.
static func tap(menu: Node3D, target: int) -> bool:
	for button in menu._buttons:
		if button.target != target or not button.enabled or not button.node.visible: continue
		var origin: Vector3 = button.node.global_position + button.node.global_basis.z
		var direction: Vector3 = -button.node.global_basis.z
		if not menu.press_pointer("left_hand", origin, direction, true): return false
		menu.release_pointer("left_hand", origin, direction, true)
		return true
	return false

func run(host: Node, step: String, marker_id: String) -> Dictionary:
	var result := {"step": step, "accepted": false, "scope": "Actual production ray-menu software route on Quest; no physical controller injection"}
	if step == "timeline_drag":
		host._show_player_menu()
		var menu: Node3D = host.player_menu
		menu.section = 0; menu.refresh()
		var target_ms := clampi(marker_id.right(16).hex_to_int(), 0, int(menu._state.get("duration_ms", 0)))
		for button in menu._buttons:
			if button.target != menu.SEEK or not button.enabled or not button.node.visible: continue
			var direction: Vector3 = -menu.global_basis.z
			var start: Vector3 = menu.to_global(Vector3(0, button.node.position.y, 1))
			var x: float = -menu.BAR_SEEK * 0.5 + menu.BAR_SEEK * target_ms / maxf(1.0, float(menu._state.duration_ms))
			var end: Vector3 = menu.to_global(Vector3(x, button.node.position.y, 1))
			if menu.press_pointer("left_hand", start, direction, true):
				menu.update_pointer("left_hand", end, direction, true)
				result.preview_ms = menu._seek_preview
				menu.release_pointer("left_hand", end, direction, true)
				result.accepted = true
				result.target_ms = target_ms
			break
	elif step in ["global_speed", "global_exact"]:
		host._show_recent_menu()
		var library: Node3D = host.recent_menu
		library.section = library.Section.SETTINGS; library.tab = library.VIDEO_TAB; library.refresh()
		var mode := "speed" if step == "global_speed" else "exact"
		for target in library.choices.targets:
			var item: Dictionary = library.choices.targets[target]
			if item.get("kind") == "choose" and item.get("key") == "seek_mode" and item.value == mode:
				result.accepted = tap(library, target); break
	elif step in ["bookmark_global", "bookmark_speed", "bookmark_exact", "bookmark_add", "bookmark_seek", "bookmark_delete"]:
		host._show_player_menu()
		var menu: Node3D = host.player_menu
		menu.section = 0; menu.refresh()
		if step == "bookmark_add":
			result.accepted = tap(menu, menu.BookmarkMenu.ADD)
			result.marker = host.video.bookmark_last_added.duplicate(true)
		else:
			menu.bookmarks.opened = true; menu.bookmarks.subset.clear(); menu.bookmarks.offset = 0; menu.refresh()
			if step.begins_with("bookmark_") and step.trim_prefix("bookmark_") in ["global", "speed", "exact"]:
				var mode := step.trim_prefix("bookmark_")
				var target: int = {"global": menu.BookmarkMenu.MODE_GLOBAL, "speed": menu.BookmarkMenu.MODE_SPEED, "exact": menu.BookmarkMenu.MODE_EXACT}[mode]
				result.accepted = tap(menu, target)
			else:
				for target in menu.bookmarks.targets:
					var item: Dictionary = menu.bookmarks.targets[target]
					if item.get("id", "") == marker_id and item.get("kind") == ("seek" if step == "bookmark_seek" else "delete"):
						result.accepted = tap(menu, target); break
	result.global_mode = host.video.seek_mode
	result.bookmark_mode = host.video.bookmark_seek_mode
	result.bookmarks = host.video.bookmarks_snapshot().get("bookmarks", []).duplicate(true)
	return result
