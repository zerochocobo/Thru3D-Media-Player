extends SceneTree
## Common production widgets in normal, selected, disabled, hover and tooltip states.
const Menu := preload("res://scripts/ray_menu.gd")
const Fields := preload("res://scripts/choice_fields.gd")

class Widgets extends "res://scripts/ray_menu.gd":
	var choices := Fields.new(self)
	var SELECTED: Color:
		get:
			if ResourceLoader.exists("res://scripts/ui_theme.gd"): return load("res://scripts/ui_theme.gd").color("selected")
			return Color(0.16, 0.31, 0.27)
	func _draw() -> void:
		_clear_layout(); _set_backdrop(Vector2(1.55, 1.08))
		_label("Interface", Vector3(0, 0.44, 0.006), TEXT_PAGE_TITLE)
		_button(1, "Button", Vector2(-0.43, 0.30), Vector2(0.30, 0.09))
		_button(2, "Play", Vector2(0, 0.30), Vector2(0.30, 0.09), true, "", true)
		_button(3, "Disabled", Vector2(0.43, 0.30), Vector2(0.30, 0.09), false)
		_button(4, "Selected", Vector2(-0.43, 0.15), Vector2(0.30, 0.09))
		_buttons.back().base_color = SELECTED
		_button(5, "Primary off", Vector2(0, 0.15), Vector2(0.30, 0.09), false, "", true)
		_glyph(6, "settings", Vector2(0.43, 0.15), 0.09, true, "Settings")
		_text_button(7, "Text action", Vector2(-0.43, 0), Vector2(0.30, 0.09))
		choices.begin("states")
		choices.field(null, {"key": "menu", "value": "first", "dropdown": true, "choices": [
			{"value": "first", "label": "First choice"}, {"value": "second", "label": "Second choice"}]}, Vector2(0.20, 0), 0.60)
		choices.field(null, {"key": "switch", "value": true, "switch": true, "choices": []}, Vector2(-0.43, -0.14), 0.09)
		choices.field(null, {"key": "slider", "value": 60, "slider": true, "span": Vector3(0, 100, 1), "unit": "%"}, Vector2(0.20, -0.14), 0.60)
		choices.finish(); _update_highlights()

func _initialize() -> void: _run.call_deferred()

func _run() -> void:
	var output := OS.get_environment("UI_THEME_CAPTURE_DIR")
	DirAccess.make_dir_recursive_absolute(output)
	preload("res://scripts/i18n.gd").use("en")
	var viewport := SubViewport.new(); viewport.size = Vector2i(1440, 1200); viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS; root.add_child(viewport)
	var camera := Camera3D.new(); camera.fov = 60; viewport.add_child(camera)
	var menu := Widgets.new(); camera.add_child(menu); menu.toggle()
	for sample in ["normal", "hover", "tooltip", "dropdown"]:
		menu._hover.clear()
		if sample == "hover":
			menu._hover = {"left_hand": 1, "right_hand": 2}; menu._update_highlights()
		elif sample == "tooltip":
			menu._hover = {"right_hand": 6}; menu._update_highlights()
		elif sample == "dropdown":
			menu.choices.opened = "menu"; menu.refresh()
		for frame in 3: await process_frame; await RenderingServer.frame_post_draw
		viewport.get_texture().get_image().save_png(output.path_join(sample + ".png"))
	viewport.free()
	quit()
