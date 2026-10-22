extends SceneTree
## The control bar's watch glyph must reach Main, flip the remembered setting and redraw.
const Main := preload("res://scripts/main.gd")
const Menu := preload("res://scripts/player_menu.gd")
var checks := 0
var failures: Array[String] = []

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok: failures.append(label)

func _initialize() -> void:
	call_deferred("_run")

const Icons := preload("res://scripts/menu_icons.gd")

func icon_of(menu: Node) -> String:
	for button in menu._buttons:
		if button.target != Menu.WATCH: continue
		for child in button.node.get_children():
			if child is MeshInstance3D and child.material_override is BaseMaterial3D:
				var texture: Texture2D = child.material_override.albedo_texture
				for key in ["watch", "watch_off"]:
					if texture == Icons.texture(key): return key
		return "?"
	return ""

func _run() -> void:
	var path := "user://watch-toggle-test.cfg"
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	var main := Main.new()
	main.settings_path = path
	var menu := Menu.new()
	menu.state_provider = func() -> Dictionary:
		return {"has_video": true, "title": "clip", "duration_ms": 1000, "position_ms": 0,
			"watch_available": true, "watch_enabled": bool(main.settings.get_value("watch", "enabled", true))}
	root.add_child(menu)
	main.player_menu = menu
	menu.action_requested.connect(main._on_menu_action)
	menu.toggle()
	await process_frame
	var before := icon_of(menu)
	menu._activate(Menu.WATCH)
	await process_frame
	check(main.settings.get_value("watch", "enabled", true) == false, "Tapping the glyph turns the watch off")
	var saved := ConfigFile.new()
	check(saved.load(path) == OK and saved.get_value("watch", "enabled", true) == false, "The choice is saved")
	check(icon_of(menu) != before, "The glyph changes at once: %s -> %s" % [before, icon_of(menu)])
	menu._activate(Menu.WATCH)
	await process_frame
	check(main.settings.get_value("watch", "enabled", false) == true and icon_of(menu) == before, "Tapping again turns it back on")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	menu.free()
	# Photos have no watch: the photo bar offers no glyph and the watch stays off.
	var photo_menu: Node3D = preload("res://scripts/photo_menu.gd").new()
	photo_menu.state_provider = func() -> Dictionary: return {"has_photo": true, "title": "photo"}
	root.add_child(photo_menu)
	photo_menu.toggle()
	await process_frame
	check(not photo_menu._buttons.any(func(button): return button.target == Menu.WATCH), "The photo bar offers no watch")
	photo_menu.free()
	main.free()
	for failure in failures: push_error(failure)
	print("Watch toggle: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
