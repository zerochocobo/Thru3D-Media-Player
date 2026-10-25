extends SceneTree
const Player := preload("res://scripts/player_menu.gd")
const Library := preload("res://scripts/library_menu.gd")
const Depth := preload("res://scripts/playback_menu_depth.gd")
const Mono := preload("res://scripts/mono_menu_capture.gd")
const Composition := preload("res://scripts/menu_composition.gd")
const I18n := preload("res://scripts/i18n.gd")
const PointerTest := preload("res://tests/test_mono_menu_pointer.gd")
var output := ProjectSettings.globalize_path("res://../../build/output/playback-menu-depth")
var checks := 0
var failures: Array[String] = []
var state := {"has_video":true,"geometry":1,"stereo":true,"playing":true,"position_ms":120000,"duration_ms":600000,"title":"VR playback","volume":80,"audio_available":true}
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)
func _initialize() -> void: call_deferred("run")
func frames() -> void:
	for i in 3: await process_frame; await RenderingServer.frame_post_draw
func pixels(view: SubViewport, name: String) -> Image:
	await frames()
	var result := view.get_texture().get_image()
	result.save_png(output.path_join(name + ".png")); return result
func run() -> void:
	DirAccess.make_dir_recursive_absolute(output)
	var view := SubViewport.new(); view.size = Vector2i(1400, 1000); view.own_world_3d = true
	view.render_target_update_mode = SubViewport.UPDATE_ALWAYS; view.transparent_bg = true; root.add_child(view)
	var origin := Node3D.new(); view.add_child(origin)
	var eye := Camera3D.new(); eye.fov = 65; origin.add_child(eye)
	var library := Library.new(); origin.add_child(library); library.set_process(false)
	var display_settings := {}
	library.settings_provider = func(): return display_settings
	library.setting_changed.connect(func(key, value): display_settings[key] = value)
	library.section = Library.Section.SETTINGS; library.tab = Library.DISPLAY_TAB; library.visible = true
	for language in ["zh", "zh_Hant", "ja", "en"]:
		display_settings.clear(); library.scroll = 0
		I18n.use(language); library.refresh()
		check(library.rows[-2].key == Depth.KEY and library.rows.back().key == "stick_seek_overlay", language + " progress switch immediately below depth")
		check(library._labels.any(func(label): return label.text == I18n.t(Depth.TITLE)) or library._buttons.any(func(button): return button.node.get_child_count() > 0 and button.node.get_child(0) is Label3D and button.node.get_child(0).text == I18n.t(Depth.TITLE)), language + " full title fits")
		check(library.text_width(I18n.t(Depth.TITLE), 18) <= 0.43, language + " title does not overlap the choice field")
		await pixels(view, "display-" + language)
		# Other Display fields may precede these final rows; hover visible controls.
		library._set_scroll(library._max_scroll(), false)
		var targets: Array = library.choices.targets.keys().filter(func(id): return library.choices.targets[id].key == Depth.KEY)
		check(targets.size() == 3 and targets.all(func(id): return library.choices.targets[id].kind == "choose"), language + " three direct switches without a select")
		for id in targets:
			var option: Dictionary = Depth.choices().filter(func(item): return item.value == library.choices.targets[id].value)[0]
			check(library._tips[id] == I18n.t(option.hint), language + " depth explanation on option hover")
			library._hover = {"right_hand":id}; library._update_tooltip()
			check(is_instance_valid(library._tooltip) and library._tooltip.visible, language + " tooltip is visible")
			await pixels(view, "display-tip-" + language + "-" + option.value)
		library._hover.clear(); library._update_tooltip()
		library._set_scroll(library._max_scroll(), false)
		await pixels(view, "display-seek-on-" + language)
		var switch_targets: Array = library.choices.targets.keys().filter(func(id): return library.choices.targets[id].key == "stick_seek_overlay")
		check(switch_targets.size() == 2 and switch_targets.map(func(id): return library.choices.targets[id].value) == [false, true], language + " direct Off/On choices match FPS setting")
		if not switch_targets.is_empty():
			library._hover = {"right_hand":switch_targets[0]}; library._update_tooltip()
			await pixels(view, "display-seek-tooltip-" + language)
			library._hover.clear(); library._update_tooltip()
			library._activate(switch_targets[0])
			check(display_settings.get("stick_seek_overlay", true) == false, language + " switch emits off")
			await pixels(view, "display-seek-off-" + language)
	library.hide()
	I18n.use("en")
	var menu := Player.new(); menu.state_provider = func(): return state
	origin.add_child(menu); menu.layout_head_provider = func(): return eye.global_transform
	menu.global_transform = Transform3D(Basis.IDENTITY, Vector3(0, -0.45, -1.4))
	menu.set_layout_viewer(eye.global_transform); menu.toggle()
	var original := menu.global_transform
	await pixels(view, "controls-default")
	menu.global_transform = Depth.place(original, eye.global_transform, Depth.MEDIUM)
	menu.set_layout_viewer(eye.global_transform)
	await pixels(view, "controls-medium")
	menu.global_transform = original; menu.set_layout_viewer(eye.global_transform)
	var composition := Composition.new(); origin.add_child(composition)
	composition.configure(origin, eye, null, [menu, library], false, true); composition.update()
	var bindings: Array = composition.slots.map(func(slot): return slot.layer.layer_viewport)
	var target := {"menu":menu}
	var mono := Mono.new(); origin.add_child(mono)
	mono.configure(eye, composition, func(): return target.menu, false, true)
	mono.update()
	check(not composition.is_processing() and composition.slots.all(func(slot): return slot.layer.quad_size == Composition.HIDDEN_SIZE), "Native layers parked without freeing swapchains")
	await pixels(view, "controls-mono")
	check(mono.raw.get_texture().get_image().get_used_rect().has_area(), "Centre-eye capture contains real menu pixels")
	check(mono.submit.get_texture().get_image().get_used_rect().has_area(), "Native layer reprojection contains menu pixels")
	mono.submit.get_texture().get_image().save_png(output.path_join("mono-native-texture.png"))
	var layer_texture := mono.submit
	var layer_size := mono.submit.size
	# Simulate the runtime's inverse spherical lookup. It must reconstruct the same
	# flat menu, not bend it, flip it, or stretch it when the menu is below eye level.
	mono.set_process(false)
	var reference := await pixels(view, "mono-flat-reference")
	var preview := Shader.new()
	preview.code = Mono.SHADER.code.get_slice("void fragment()", 0) + """
uniform vec4 capture_rect;
uniform vec3 angles;
void fragment() {
    vec2 tangent = (vec2(UV.x, 1.0-UV.y)-0.5)*capture_rect.zw+capture_rect.xy;
    float longitude = atan(tangent.x);
    float latitude = atan(tangent.y/sqrt(1.0+tangent.x*tangent.x));
    vec2 sample_uv = vec2(longitude/angles.x+0.5, (angles.y-latitude)/(angles.y+angles.z));
    vec4 pixel = vec4(0.0);
    if (all(greaterThanEqual(sample_uv, vec2(0.0))) && all(lessThanEqual(sample_uv, vec2(1.0)))) {
        pixel = texture(menu_texture, sample_uv);
    }
    ALBEDO = pixel.rgb; ALPHA = pixel.a;
}
"""
	var preview_material := ShaderMaterial.new(); preview_material.shader = preview
	preview_material.render_priority = 120
	preview_material.set_shader_parameter("menu_texture", mono.submit.get_texture())
	for parameter in ["capture_rect", "angles"]:
		preview_material.set_shader_parameter(parameter, mono.copy.material.get_shader_parameter(parameter))
	var original_material: Material = mono.surface.material_override
	mono.surface.material_override = preview_material
	var reconstructed := await pixels(view, "mono-native-reconstructed")
	var error := 0.0; var samples := 0
	for y in reference.get_height():
		for x in reference.get_width():
			var a := reference.get_pixel(x,y); var b := reconstructed.get_pixel(x,y)
			if a.a < 0.01 and b.a < 0.01: continue
			error += absf(a.r-b.r)+absf(a.g-b.g)+absf(a.b-b.b)+absf(a.a-b.a); samples += 4
	var mean_error := error/maxi(samples,1)
	print("Mono spherical round-trip mean RGBA error: ", mean_error)
	check(samples > 0 and mean_error < 0.02, "Native spherical mapping reconstructs flat content and alpha")
	# Execute the production coverage shader over an opaque scene. Its alpha must
	# leave exactly the capture's coverage for the native layer underneath.
	var backdrop := MeshInstance3D.new(); backdrop.mesh = QuadMesh.new()
	backdrop.mesh.size = Vector2(100,100); origin.add_child(backdrop); backdrop.position.z = -5
	var backdrop_material := StandardMaterial3D.new()
	backdrop_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	backdrop_material.albedo_color = Color(0.3,0.2,0.1); backdrop.material_override = backdrop_material
	mono.surface.hide(); mono.hole.show()
	var masked := await pixels(view, "mono-native-coverage")
	var alpha_error := 0.0; var alpha_samples := 0
	for y in reference.get_height():
		for x in reference.get_width():
			var coverage := reference.get_pixel(x,y).a
			if coverage < 0.01: continue
			alpha_error += absf(masked.get_pixel(x,y).a + coverage - 1.0); alpha_samples += 1
	check(alpha_samples > 0 and alpha_error/maxi(alpha_samples,1) < 0.01, "Native hole preserves fractional alpha over scene content")
	backdrop.queue_free(); mono.hole.hide(); mono.surface.show()
	mono.surface.material_override = original_material; mono.set_process(true)
	# Real ray -> seek capture -> redraw, using the existing logical hit geometry.
	var timeline: Dictionary = {}
	for button in menu._buttons:
		if button.target == menu.SEEK: timeline = button; break
	check(not timeline.is_empty(), "Production timeline found")
	if not timeline.is_empty():
		var start := Vector3(0.25, -0.2, -0.3)
		var end: Vector3 = timeline.node.global_position
		menu.press_pointer("right_hand", start, PointerTest.aim(menu,eye.global_position,start,end), true)
		check(menu.has_pointer_capture(), "Timeline captures the trigger in mono mode")
		menu.update_pointer("right_hand", start, PointerTest.aim(menu,eye.global_position,start,end + menu.global_basis.x * 0.15), true)
		await pixels(view, "mono-seeking")
		check(menu._pointers.right_hand.dot.visible and menu._pointers.right_hand.line.material_override is ShaderMaterial, "Mono reticle and hand-anchored ray stay visible")
		menu.release_pointer("right_hand", start, PointerTest.aim(menu,eye.global_position,start,end), true)
	# The close control is small: pick by its displayed angular position rather
	# than aiming at the hidden finite geometry (which masked the original bug).
	var close_button: Dictionary = menu._buttons.filter(func(button): return button.target == 107)[0]
	var close_start := Vector3(0.25,-0.2,-0.3)
	var close_direction := PointerTest.aim(menu,eye.global_position,close_start,close_button.node.global_position)
	menu.update_pointer("right_hand",close_start,close_direction,true); mono.update()
	check(menu._hover.get("right_hand") == 107,"Rendered mono pointer hovers the visible close control")
	await pixels(view,"mono-close-hover")
	var close_action := {"seen":false}
	menu.action_requested.connect(func(operation): close_action.seen = close_action.seen or operation == "stop")
	menu.press_pointer("right_hand",close_start,close_direction,true)
	check(close_action.seen,"Trigger at the displayed close button emits the close action")
	# Exercise popup creation while the capture owns the menu layers.
	menu.section = 1; menu.refresh(); mono.update()
	await pixels(view, "mono-settings")
	check(menu._popup_surfaces.size() > 0, "Associated settings popup captured")
	check(mono.submit == layer_texture and mono.submit.size == layer_size, "Popup changes preserve the layer viewport and fixed swapchain size")
	# Execute the production zero-parallax vertex expression with the exact Godot
	# multiview projection convention on a desktop renderer (no native XR claim).
	mono.set_process(false); mono.update()
	var shader := Shader.new()
	shader.code = Mono.SHADER.code.replace("uniform sampler2D", "uniform mat4 test_view;\nuniform mat4 test_projection;\nuniform sampler2D").replace("VIEW_MATRIX", "test_view").replace("PROJECTION_MATRIX", "test_projection")
	var material: ShaderMaterial = mono.surface.material_override
	material.shader = shader
	material.set_shader_parameter("test_view", Projection(eye.global_transform.affine_inverse()))
	var left: Image
	for side in [-1.0, 1.0]:
		var eye_pose := Transform3D(Basis.IDENTITY, Vector3(side * 0.032, 0, 0))
		material.set_shader_parameter("test_projection", eye.get_camera_projection() * Projection(eye_pose.affine_inverse()))
		var actual := await pixels(view, "mono-eye-" + ("left" if side < 0 else "right"))
		if side < 0: left = actual
		else: check(left.get_data() == actual.get_data(), "Zero-parallax production shader cancels 64 mm stereo translation pixel for pixel")
	material.shader = Mono.SHADER
	target.menu = null; mono.update()
	check(composition.is_processing() and composition.slots.map(func(slot): return slot.layer.layer_viewport) == bindings, "Exit resumes the same native layer providers")
	check(menu._pointers.right_hand.line.material_override is StandardMaterial3D, "Exit restores original pointer material")
	check(mono.submit.render_target_update_mode == SubViewport.UPDATE_DISABLED and not mono.hole.visible, "Exit stops native capture and removes its coverage mask")
	composition.set_active(false); menu.hide(); library.show()
	await pixels(view, "library-restored")
	mono.stop(); library.hide(); view.queue_free(); await process_frame
	for failure in failures: push_error(failure)
	print("Playback menu depth render: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
