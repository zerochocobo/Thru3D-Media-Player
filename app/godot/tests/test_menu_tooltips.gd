extends SceneTree
const Menu := preload("res://scripts/ray_menu.gd")
var checks := 0
var failures: Array[String] = []
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)
func _initialize() -> void: call_deferred("run")

func check_name_hover(menu: Node3D, target: int, full_name: String, truncated: bool, context: String) -> void:
	var matches: Array = menu._buttons.filter(func(button): return button.target == target)
	check(matches.size() == 1, context + " has a row target")
	if matches.size() != 1: return
	var node: Node3D = matches[0].node
	menu.update_pointer("right_hand", node.to_global(Vector3(0, 0, 1)), -node.global_basis.z, true)
	if truncated:
		check(menu._tips.get(target) == full_name and menu._tooltip != null and menu._tooltip.visible and menu._tooltip.get_child(0).text == full_name, context + " hover reveals the truncated name")
	else:
		check(not menu._tips.has(target) and (menu._tooltip == null or not menu._tooltip.visible), context + " complete name has no duplicate tooltip")

func run() -> void:
	var menu := Menu.new(); root.add_child(menu); menu.visible = true
	menu._button(10, "", Vector2.ZERO, Vector2(0.15, 0.08), true, "folder")
	menu._button(11, "", Vector2(0.2, 0), Vector2(0.15, 0.08), true, "folder")
	for empty in [null, "", " \t\r\n ", "\u00a0\u3000", "\u200b\ufeff", 0, {}]:
		menu._tips[10] = empty
		menu.update_pointer("right_hand", menu.to_global(Vector3(0, 0, 1)), -menu.global_basis.z, true)
		check(menu._tooltip == null, "Empty metadata never allocates a tooltip: " + str(empty))
	menu._tips[10] = "  A real filename  "
	menu.update_pointer("right_hand", menu.to_global(Vector3(0, 0, 1)), -menu.global_basis.z, true)
	check(menu._tooltip.visible and menu._tooltip.get_child(0).text == "A real filename", "Normal tooltip still shows trimmed text")
	for empty in [null, "", " \t\n", "\u200b\u3000", {}]:
		menu._tips[11] = empty
		menu.update_pointer("right_hand", menu.to_global(Vector3(0.2, 0, 1)), -menu.global_basis.z, true)
		check(not menu._tooltip.visible and menu._tooltip.get_child(0).text.is_empty(), "Empty next item clears old content")
	menu._tips[10] = "Disabled reason"
	menu._buttons[0].enabled = false; menu._buttons[0].hover_disabled = true
	menu.update_pointer("right_hand", menu.to_global(Vector3(0, 0, 1)), -menu.global_basis.z, true)
	check(menu._tooltip.visible, "Meaningful disabled explanation remains available")
	menu._buttons[0].node.visible = false; menu._update_tooltip()
	check(not menu._tooltip.visible, "Clipped row cannot leave a tooltip behind")
	menu._buttons[0].node.visible = true; menu._update_tooltip()
	check(menu._tooltip.visible, "Restored hovered row shows its content")
	menu.dismiss()
	check(not menu._tooltip.visible and menu._tooltip.get_child(0).text.is_empty(), "Dismiss removes the old tooltip")
	menu.visible = true; menu._update_tooltip()
	check(not menu._tooltip.visible, "Reopening without a hover has no black box")
	var long_name := "A very long filename with Chinese 中文 and 日本語 " + "long-name-".repeat(18) + ".mp4"
	menu._buttons[0].enabled = true; menu._tips[10] = long_name
	menu.update_pointer("right_hand", menu.to_global(Vector3(0, 0, 1)), -menu.global_basis.z, true)
	check(menu._tooltip.visible and menu._tooltip.get_child(0).text == long_name and menu._tooltip.mesh.size.x <= 0.901 and menu._tooltip.mesh.size.y > 0.046, "Long names remain complete in a bounded multiline tooltip")
	menu._buttons[0].node.position.y += 0.13
	menu.update_pointer("right_hand", menu.to_global(Vector3(0, 0.13, 1)), -menu.global_basis.z, true)
	check(menu._tooltip.position.y > 0.13, "Tooltip follows the tile's actual scrolled position")
	var library := preload("res://scripts/library_menu.gd").new(); root.add_child(library); library.visible = true
	for section in [library.Section.LOCAL, library.Section.SMB, library.Section.DLNA, library.Section.CLOUD]:
		for layout in ["grid", "list", "compact"]:
			library._clear_layout(); library.section = section; library.compact = layout == "compact"; library.view_mode = "list"
			library.rows.assign([{"title": long_name, "icon": "folder"}, {"title": "Short.mp4", "icon": "video"}])
			if layout == "compact": library._draw_compact_rows()
			else:
				library._list = Node3D.new(); library.add_child(library._list); library._decorations.append(library._list)
				for i in library.rows.size():
					if layout == "grid": library._tile(library.ROW_BASE + i, library.rows[i], Vector2(i * 0.4, 0))
					else: library._media_row_button(library.ROW_BASE + i, library.rows[i], Vector2(0, -i * 0.12))
			check_name_hover(library, library.ROW_BASE, long_name, true, "%s/%s long" % [section, layout])
			check_name_hover(library, library.ROW_BASE + 1, "Short.mp4", false, "%s/%s short" % [section, layout])
	for compact in [false, true]:
		for home_tab in [0, 1]:
			library._clear_layout(); library.section = library.Section.RECENT; library.compact = compact; library.collections.home_tab = home_tab
			library._list = Node3D.new(); library.add_child(library._list); library._decorations.append(library._list)
			for i in 2:
				library._media_row_button(library.ROW_BASE + i, {"title": long_name if i == 0 else "Short.mp4", "uri": "file:///tooltip-%d.mp4" % i}, Vector2(0, -i * 0.12))
			check_name_hover(library, library.ROW_BASE, long_name, true, "Recent/favorites long")
			check_name_hover(library, library.ROW_BASE + 1, "Short.mp4", false, "Recent/favorites short")
	for layout in ["grid", "poster", "list"]:
		library._clear_layout(); library.section = library.Section.MEDIA_SERVER; library.compact = false
		library.server_browser.view = "scenes"; library.server_browser.capabilities = {"artwork": layout != "grid"}
		library._list = Node3D.new(); library.add_child(library._list); library._decorations.append(library._list)
		for i in 2:
			var row := {"title": long_name if i == 0 else "Short.mp4", "scene": {"basename": long_name if i == 0 else "original-name.mp4"}}
			if layout == "list": library.server_browser.media_row(library.ROW_BASE + i, row, Vector2(0, -i * 0.14))
			else: library.server_browser.tile(library.ROW_BASE + i, row, Vector2(i * 0.4, 0))
		check_name_hover(library, library.ROW_BASE, long_name, true, "Media server %s long" % layout)
		check_name_hover(library, library.ROW_BASE + 1, "Short.mp4", false, "Media server %s short" % layout)
	# Wrapping alone does not hide any characters. A complete two-line title needs no tooltip.
	library._clear_layout(); library._list = Node3D.new(); library.add_child(library._list); library._decorations.append(library._list)
	var wrapped_name := "中".repeat(70)
	check(library.server_browser.wrapped_lines(wrapped_name, 1.19, 20).size() == 2, "Fixture uses a complete two-line title")
	library.server_browser.media_row(library.ROW_BASE, {"title": wrapped_name}, Vector2.ZERO)
	check_name_hover(library, library.ROW_BASE, wrapped_name, false, "Media server wrapped title")
	library.free()
	menu.queue_free(); await process_frame
	for failure in failures: push_error(failure)
	print("Menu tooltips: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
