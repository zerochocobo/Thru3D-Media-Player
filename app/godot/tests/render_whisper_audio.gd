extends SceneTree

const Menu := preload("res://scripts/player_menu.gd")
const PhotoMenu := preload("res://scripts/photo_menu.gd")
var state := {"has_video": true, "source_uri": "file:///whisper.mp4", "title": "Whisper",
	"geometry": 1, "stereo": true, "projection": "VR180", "playing": true,
	"audio_available": true, "volume": 37, "muted": false, "audio_whisper": 0,
	"whisper_available": true, "position_ms": 32000, "duration_ms": 180000}
var failures: Array[String] = []
var checks := 0

func _initialize() -> void: call_deferred("run")

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func compact_button(menu: Node, target: int, panel_width: float) -> void:
	var button: Dictionary = menu._buttons.filter(func(b): return b.target == target)[0]
	var label: Label3D = button.node.get_child(0)
	check(button.rect.size.x + 0.02 <= panel_width and button.rect.size.y < 0.08, "Compact enhancement has visible side margins")
	check(menu.text_width(label.text, label.font_size / menu.TEXT_RASTER_SCALE) <= button.rect.size.x - 0.014, "Enhancement text fits with padding")
	check(label.font_size / menu.TEXT_RASTER_SCALE <= 13, "Enhancement caption is smaller")

func snapshot(viewport: SubViewport, path: String) -> void:
	await process_frame
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	check(viewport.get_texture().get_image().save_png(path) == OK, "Save visual")

func run() -> void:
	var output := ProjectSettings.globalize_path("res://../../build/output/video-depth-boost/visuals")
	DirAccess.make_dir_recursive_absolute(output)
	var viewport := SubViewport.new(); viewport.size = Vector2i(1280, 900); viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var camera := Camera3D.new(); camera.fov = 60; viewport.add_child(camera)
	var menu := Menu.new(); menu.state_provider = func(): return state
	camera.add_child(menu); menu.position.y = -0.30; menu.toggle(); menu._volume_open = true
	for language in ["en", "zh", "zh_Hant", "ja"]:
		preload("res://scripts/i18n.gd").use(language)
		for level in [0, 1, 26, 51]:
			state.audio_whisper = level; state.volume = 100 + level - 1 if level > 1 else 37
			state.boost_saved = 35; menu.refresh()
			for target in [Menu.WHISPER, Menu.VOLUME, 109]:
				var found := false
				for button in menu._buttons:
					if button.target != target: continue
					var point: Vector3 = button.node.global_position + menu.global_basis.z * 0.3
					if target == Menu.WHISPER: compact_button(menu, target, 0.1)
					found = int(menu.ray_hit(point, -menu.global_basis.z).get("target", -1)) == target
				check(found, "Raised popup target is reachable: %s/%d/%d" % [language, level, target])
			check(menu._volume_label.text == "%d%%" % int(state.volume), "Actual continuous percentage label")
			check((menu._boost_fill != null) == (level > 0), "Yellow segment exists only when expanded")
			await snapshot(viewport, output.path_join("volume-%s-%d.png" % [language, level]))
	menu._volume_open = false; menu._depth_open = true
	state.geometry = 0; state.stereo = false; state.depth_requested = true; state.depth_strength = 0.5
	menu.depth_strength_requested.connect(func(value): state.depth_strength = value; state.depth_requested = value > 0)
	menu.action_requested.connect(func(action):
		if action == "depth": state.depth_requested = false)
	for language in ["en", "zh", "zh_Hant", "ja"]:
		preload("res://scripts/i18n.gd").use(language)
		for strength in [0.5, 1.0, 1.5, 2.0, 0.0]:
			state.depth_strength = strength; state.depth_requested = strength > 0
			menu._depth_boost = strength > 1.0; menu.refresh()
			compact_button(menu, Menu.DEPTH_BOOST, 0.13)
			for target in [Menu.DEPTH_BOOST, Menu.DEPTH, Menu.DEPTH_OFF]:
				var button: Dictionary = menu._buttons.filter(func(b): return b.target == target)[0]
				var point: Vector3 = button.node.to_global(Vector3(0, 0, 0.3))
				if button.enabled: check(menu.ray_hit(point, -button.node.global_basis.z).get("target", -1) == target, "Video boost/rail/X ray target")
			check(menu._depth_label.text == ("%d%%" % roundi(strength * 100) if strength > 0 else Menu.I18n.t("Off")), "Depth value and Off label")
			check(menu._depth_label.modulate == (Menu.WARNING if strength > 1.0 else Color.WHITE), "Excess depth has the same orange style as sound")
			await snapshot(viewport, output.path_join("depth-%s-%d.png" % [language, roundi(strength * 100)]))
		state.depth_strength = 2.0; state.depth_requested = true; menu.refresh()
		var off: Dictionary = menu._buttons.filter(func(b): return b.target == Menu.DEPTH_OFF)[0]
		check(off.rect.size.x >= 0.075 and off.base_color.a > 0.0 and is_equal_approx(float(off.node.material_override.get_shader_parameter("corner_radius")), off.rect.size.x / 2), "3D Off is a prominent filled round button")
		check(off.node.get_child(1).material_override.albedo_texture == menu.Icons.texture("power"), "3D Off uses power rather than a popup-close X")
		var off_point: Vector3 = off.node.to_global(Vector3(0, 0, 0.3))
		var off_direction: Vector3 = -off.node.global_basis.z
		menu.update_pointer("left", off_point, off_direction, true)
		var off_hover: Color = off.node.material_override.get_shader_parameter("surface_color")
		check(off_hover.r > off_hover.g * 2.0, "Power action stays red on hover instead of looking enabled green")
		check(menu._tooltip.visible and menu._tooltip.get_child(0).text == Menu.I18n.t("Turn off 3D"), "X has the actual translated hover tooltip")
		if language == "zh": check(menu._tooltip.get_child(0).text == "关闭3D", "Chinese tooltip exactly matches the requested wording")
		await snapshot(viewport, output.path_join("depth-%s-tooltip.png" % language))
		menu.press_pointer("left", off_point, off_direction, true)
		menu.release_pointer("left", off_point, off_direction, true)
		check(not state.depth_requested and state.depth_strength == 2.0 and not menu._depth_open and menu._depth_label == null, "X really closes 3D and its rail without losing 200%")
		await snapshot(viewport, output.path_join("depth-%s-closed.png" % language))
		menu._activate(112)
		check(state.depth_requested and state.depth_strength == 2.0 and menu._depth_open, "Single icon click restores boosted 3D and opens its rail")
	menu.free()
	var photo := PhotoMenu.new(); camera.add_child(photo); photo.position.y = -0.30
	state.has_image = true; state.depth_available = true; state.layout = 0; state.count = 1; state.title = "Photo"
	photo.state_provider = func(): return state
	photo.toggle(); photo._depth_open = true
	for strength in [0.5, 1.0, 2.0]:
		state.depth_strength = strength; state.depth_requested = true; photo.refresh()
		check(photo._buttons.all(func(b): return b.target != Menu.DEPTH_BOOST), "Photo has no video enhancement button")
		var fraction: float = {0.5: 0.2, 1.0: 0.4666666667, 2.0: 1.0}[strength]
		check(is_equal_approx(photo._depth_knob.position.y, lerpf(photo._depth_span().x, photo._depth_span().y, fraction)), "Photo retains original track mapping")
		await snapshot(viewport, output.path_join("photo-%d.png" % roundi(strength * 100)))
	photo.free(); viewport.queue_free()
	print("Volume/video boost and photo visuals: %d checks, %d failures" % [checks, failures.size()])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)
