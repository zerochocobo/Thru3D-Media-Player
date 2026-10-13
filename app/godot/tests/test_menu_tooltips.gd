extends SceneTree
const Menu := preload("res://scripts/ray_menu.gd")
var checks := 0
var failures: Array[String] = []
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)
func _initialize() -> void: call_deferred("run")
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
		library._clear_layout(); library.section = section
		library._list = Node3D.new(); library.add_child(library._list); library._decorations.append(library._list)
		library._tile(library.ROW_BASE, {"title": long_name, "icon": "folder"}, Vector2.ZERO)
		library._tile(library.ROW_BASE + 1, {"title": "Short", "icon": "folder"}, Vector2(0.4, 0))
		check(library._tips.get(library.ROW_BASE) == long_name and not library._tips.has(library.ROW_BASE + 1), "Only truncated library tiles receive full-name tips")
		library.update_pointer("right_hand", library.to_global(Vector3(0, 0, 1)), -library.global_basis.z, true)
		check(library._tooltip.visible and library._tooltip.get_child(0).text == long_name, "Production file tile hover shows the complete name")
	library.free()
	menu.queue_free(); await process_frame
	for failure in failures: push_error(failure)
	print("Menu tooltips: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
