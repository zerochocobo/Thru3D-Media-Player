extends SceneTree
## Actual slider, puzzle and playback surfaces on controlled scene backgrounds.
const Palette := preload("res://scripts/ui_theme.gd")
const Fields := preload("res://scripts/choice_fields.gd")
const Entry := preload("res://scripts/puzzle/puzzle_photo_entry.gd")
const Player := preload("res://scripts/player_menu.gd")
const Seek := preload("res://scripts/seek_overlay.gd")
const Immersive := preload("res://scripts/immersive_adjustment_overlay.gd")
const Audition := preload("res://scripts/audio_preview_seek.gd")
const Providers := preload("res://scripts/provider_icons.gd")
var checks := 0
var failures: Array[String] = []

class Sliders extends "res://scripts/ray_menu.gd":
	var fields := Fields.new(self)
	var audition := Audition.new(self)
	func _place_device_status(_centre: Vector2) -> void: pass
	func _draw() -> void:
		_clear_layout(); _set_backdrop(Vector2(1.55, 1.08))
		_label("Sliders", Vector3(0, 0.42, 0.006), TEXT_PAGE_TITLE)
		fields.begin("readability")
		for index in 2:
			_label("80%" if index == 0 else "20%", Vector3(-0.57, 0.23 - index * 0.22, 0.006), TEXT_BODY)
			fields.field(null, {"key": "filled" if index == 0 else "empty", "value": 80 if index == 0 else 20,
				"slider": true, "midpoint": true, "span": Vector3(0, 100, 1), "unit": "%"}, Vector2(0.12, 0.23 - index * 0.22), 0.94)
		fields.field(null, {"key": "range", "value": Vector2(20, 80), "range_slider": true,
			"span": Vector3(0, 100, 1), "unit": "%"}, Vector2(0.12, -0.21), 0.94)
		fields.finish()
		_button(-900, "Audition", Vector2(0, -0.40), Vector2(1.38, 0.08))
		audition.draw(_buttons.back().node, {"audio_preview_seekable": true, "audio_preview_duration": 100.0, "audio_preview_position": 80.0})
		_update_highlights()
	func provider_grid() -> void:
		_clear_layout(); _set_backdrop(Vector2(1.55, 1.08))
		_label("Accounts", Vector3(0, 0.43, 0.006), TEXT_PAGE_TITLE)
		var index := 0
		for key in Providers.TEXTURES:
			var centre := Vector2(-0.52 + index % 3 * 0.52, 0.25 - index / 3 * 0.20)
			_button(-1000 - index, "", centre, Vector2(0.46, 0.17))
			_icon(key, Vector3(0, 0.025, 0.006), 0.08, UiTheme.color("provider_ink"), _buttons.back().node)
			_label(key.trim_prefix("provider_"), Vector3(0, -0.052, 0.006), TEXT_AUX, _buttons.back().node)
			index += 1
		_update_highlights()

func _initialize() -> void: _run.call_deferred()
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)
func frames() -> void:
	for index in 4: await process_frame; await RenderingServer.frame_post_draw
func capture(view: SubViewport, output: String, name: String) -> Image:
	await frames()
	var picture := view.get_texture().get_image()
	check(picture.save_png(output.path_join(name + ".png")) == OK, "Saved " + name)
	return picture

func marker_pixels(image: Image, camera: Camera3D, marker: MeshInstance3D, parent: Node3D, y: float) -> bool:
	var point := Vector2i(camera.unproject_position(marker.global_position))
	var reference := Vector2i(camera.unproject_position(parent.to_global(Vector3(marker.position.x - 0.045, y, 0.004))))
	var paper := image.get_pixelv(reference)
	var changed := 0
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			var ink := image.get_pixelv(point + Vector2i(dx, dy))
			if maxf(absf(ink.r - paper.r), maxf(absf(ink.g - paper.g), absf(ink.b - paper.b))) > 0.12: changed += 1
	return changed >= 2

func _run() -> void:
	var output := OS.get_environment("UI_THEME_CAPTURE_DIR")
	DirAccess.make_dir_recursive_absolute(output)
	var view := SubViewport.new(); view.size = Vector2i(1600, 1200); view.own_world_3d = true
	view.render_target_update_mode = SubViewport.UPDATE_ALWAYS; root.add_child(view)
	var world := WorldEnvironment.new(); world.environment = Environment.new()
	world.environment.background_mode = Environment.BG_COLOR
	world.environment.background_color = Color("080b10"); view.add_child(world)
	var camera := Camera3D.new(); camera.fov = 60; view.add_child(camera)
	var sliders := Sliders.new(); camera.add_child(sliders); sliders.toggle()
	var puzzle := Entry.new(); camera.add_child(puzzle); puzzle.toggle(); puzzle.position = Vector3(0, -0.69, -1.55)
	var image := await capture(view, output, "markers")
	var audition_thumb: MeshInstance3D = sliders.audition.view.thumb
	check(audition_thumb.material_override.get_shader_parameter("surface_color") == (Palette.color("accent") if Palette.current == Palette.DEFAULT else Palette.color("knob")), "Audition marker preserves classic and uses independent new-theme ink")
	if Palette.current != Palette.DEFAULT:
		check(marker_pixels(image, camera, audition_thumb, audition_thumb.get_parent(), 0), "Rendered audition thumb differs from filled rail")
	for target in sliders.fields.sliders:
		var row: Dictionary = sliders.fields.sliders[target]
		for handle in row.get("handles", []):
			check(marker_pixels(image, camera, handle, handle.get_parent(), handle.position.y), "Rendered range handle differs from its rail")
		if not row.has("knob"): continue
		var knob: MeshInstance3D = row.knob
		check(marker_pixels(image, camera, knob, knob.get_parent(), knob.position.y), "Rendered knob differs from its filled or empty rail")
		for child in knob.get_parent().get_children():
			if child is MeshInstance3D and child.mesh is QuadMesh and child.mesh.size.is_equal_approx(Vector2(0.003, 0.023)):
				check(marker_pixels(image, camera, child, knob.get_parent(), child.position.y), "Rendered midpoint visible with fill below or above it")
	sliders.provider_grid(); puzzle.visible = false
	await capture(view, output, "provider-marks")
	sliders.visible = false
	var seek := Seek.new(); seek.source = func(): return {"phase": "preview", "origin_ms": 1000, "target_ms": 8000,
		"duration_ms": 10000, "delta_ms": 7000, "alpha": 1.0}
	camera.add_child(seek)
	var immersive := Immersive.new(); immersive.source = func(): return [{"key": "view_horizontal", "title": "Horizontal",
		"span": Vector2(-100, 100), "value": 50, "alpha": 1.0}]
	camera.add_child(immersive)
	for backdrop in [Color("080b10"), Color("e3e7ec")]:
		world.environment.background_color = backdrop
		await capture(view, output, "playback-hud-" + ("dark" if backdrop.r < 0.5 else "light"))
		check(seek._colors[0] == Palette.ORIGINAL.seek_panel, "Playback plate retains dark semantic color")
	seek.visible = false; seek.set_process(false); immersive.visible = false; immersive.set_process(false)
	var player := Player.new(); player.state_provider = func(): return {"has_video": true, "title": "Movie",
		"position_ms": 5000, "duration_ms": 10000, "paused": true}
	camera.add_child(player); player.toggle()
	for backdrop in [Color("080b10"), Color("657d87"), Color("e3e7ec")]:
		world.environment.background_color = backdrop
		for opacity in [14.0, 0.0, 50.0]:
			player.set_bar_transparency(opacity)
			await capture(view, output, "transport-" + backdrop.to_html(false) + "-t" + str(int(opacity)))
			var surface: Color = player._backdrop.material_override.get_shader_parameter("surface_color")
			check(is_equal_approx(surface.a, 1.0 - opacity / 100.0), "Theme honors user transparency: " + str(opacity))
	view.free(); await process_frame
	FileAccess.open(output.path_join("readability.json"), FileAccess.WRITE).store_string(JSON.stringify({"theme": Palette.current,
		"checks": checks, "failures": failures, "scope": "Desktop GL; brightness/comfort needs physical headset review"}, "\t"))
	for failure in failures: push_error(failure)
	print("UI theme readability: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
