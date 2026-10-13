extends SceneTree
const Menu := preload("res://scripts/player_menu.gd")
const PhotoMenu := preload("res://scripts/photo_menu.gd")
const I18n := preload("res://scripts/i18n.gd")
const Grade := preload("res://scripts/color_grade.gd")
var checks := 0
var failures: Array[String] = []
var output := ProjectSettings.globalize_path("res://../../build/output/slider-reset/previews")
var viewport: SubViewport
var menu: Node3D
var camera: Camera3D
var state := {"has_video": true, "has_image": true, "title": "旅行 · Travel", "count": 12, "geometry": 0,
	"source_uri": "file:///fixture.mp4", "duration_ms": 120000, "position_ms": 60000, "stereo": true,
	"viewing_eye": 0, "stereo_horizontal": 2.5, "stereo_vertical": -1.0,
	"screen_distance": 4.5, "screen_scale": 150.0, "screen_rotation": 15.0,
	"subtitle_position": 15.0, "subtitle_distance": 1.5, "subtitle_size": 150.0,
	"playback_speed": 1.5, "alpha_fps": 35.0, "playing": true,
	"depth_requested": true, "depth_available": true, "depth_strength": 1.8,
	"layout": 0, "gallery_focus": -1, "gallery_scale": 1.5, "gallery_distance": 6.0, "inspect_magnification": 6.0}
func _initialize() -> void: call_deferred("run")
func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok: failures.append(label)
func snapshot(name: String) -> void:
	for frame in 2: await process_frame; await RenderingServer.frame_post_draw
	if menu._adjustment == "color_grade":
		check(menu._preset_buttons.size() == 4 and not menu._preset_buttons.has("Daylight"), name + ": exactly four presets")
	for button in menu._buttons:
		if menu._adjustment == "color_grade" and button.target >= 410 and button.target < 410 + Grade.PRESETS.size():
			var caption: Label3D = button.node.get_child(0)
			check(menu.text_width(caption.text, caption.font_size / menu.TEXT_RASTER_SCALE) < button.rect.size.x - 0.025, name + ": preset caption fits")
			var point: Vector3 = button.node.to_global(Vector3(0, 0, 1))
			check(menu.ray_hit(point, -button.node.global_basis.z).get("target") == button.target, name + ": preset ray target")
		if menu._adjustment == "color_grade" and button.target in [440, Menu.GRADE_PAGE_RESET]:
			var label: Label3D = button.node.get_child(0)
			check(menu.text_width(label.text, label.font_size / menu.TEXT_RASTER_SCALE) < button.rect.size.x - 0.025, name + ": page/whole reset caption fits")
		var reset: bool = button.has("reset_slider") or button.target == Menu.DEPTH_RESET or menu.choices.targets.get(button.target, {}).get("kind", "") == "reset"
		if not reset: continue
		var origin: Vector3 = button.node.to_global(Vector3(0, 0, 1))
		check(not button.enabled or menu.ray_hit(origin, -button.node.global_basis.z).get("target") == button.target, name + ": reset is reachable without touching another slider")
		if button.has("reset_slider"):
			var point: Vector3 = menu.to_local(button.node.global_position)
			check(absf(point.x) + button.rect.size.x * 0.5 < menu._backdrop.mesh.size.x * 0.5, name + ": reset stays inside panel")
		check(menu._tips.get(button.target) == I18n.t("Reset"), name + ": reset tooltip is translated")
	for slider in menu.choices.sliders.values():
		check(menu.text_width(slider.label.text, 18) <= 0.125, name + ": subtitle/FPS value fits beside the reset icon")
	check(viewport.get_texture().get_image().save_png(output.path_join(name + ".png")) == OK, "Save " + name)
func make_menu(photo: bool = false) -> void:
	if menu: menu.free()
	menu = PhotoMenu.new() if photo else Menu.new(); viewport.add_child(menu)
	menu.set_process(false); menu.state_provider = func(): return state.duplicate(true)
	menu.visible = true; menu.position = Vector3(0, 0, -1.4)
func run() -> void:
	DirAccess.make_dir_recursive_absolute(output)
	viewport = SubViewport.new(); viewport.size = Vector2i(1500, 1100); viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS; root.add_child(viewport)
	camera = Camera3D.new(); camera.fov = 60; viewport.add_child(camera)
	var values := Grade.DEFAULTS.duplicate()
	for key in values:
		var span := Grade.limits(key); values[key] = Grade.clean(key, lerpf(span.x, span.y, 0.25))
	state.grade_values = values; state.color_grade = {"preset": "Custom"}
	for language in ["en", "zh", "zh_Hant", "ja"]:
		I18n.use(language); make_menu()
		menu.section = 1; menu._adjustment = "color_grade"
		for page in 3:
			menu._grade_page = page; menu.refresh(); await snapshot("color-%s-%d" % [language, page])
		menu._adjustment = "stereo_view"; menu.refresh(); await snapshot("stereo-" + language)
		menu._adjustment = ""; menu.section = 0; state.geometry = 1
		menu.refresh(); menu._activate(110); menu._activate(Menu.SUBTITLE_APPEARANCE)
		check(menu.choices.sliders.size() == 3, "Subtitle appearance actually shows all three slider fields")
		await snapshot("subtitles-" + language)
		state.geometry = 0
	I18n.use("zh"); make_menu(); menu.section = 1; menu._adjustment = "screen"
	menu.refresh(); await snapshot("video-screen-zh")
	menu._adjustment = ""; menu.refresh(); await snapshot("playback-zh")
	state.stereo = false; menu.section = 0; menu._depth_open = true; menu.refresh(); await snapshot("video-depth-zh")
	make_menu(true); state.screen_scale = 2.0; menu._adjustment = "photo_view"; menu.refresh(); await snapshot("photo-zh")
	state.layout = 2; menu.refresh(); await snapshot("wall-zh")
	state.layout = 3; menu.refresh(); await snapshot("random-zh")
	state.layout = 0; menu._adjustment = ""; menu._depth_open = true; menu.refresh(); await snapshot("photo-depth-zh")
	menu.free(); viewport.queue_free(); await process_frame
	print("Slider reset previews checks=%d failures=%d" % [checks, failures.size()])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)
