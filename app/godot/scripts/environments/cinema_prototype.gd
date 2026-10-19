extends Node3D
signal environment_loaded(success: bool)
## Desktop P0 entry. Production player settings, Android playback and default entry stay independent.
const Loader := preload("res://scripts/environments/cinema_loader.gd")
const Feature := preload("res://scripts/environments/cinema_feature.gd")
const Locomotion := preload("res://scripts/environments/cinema_locomotion.gd")
const Surface := preload("res://scripts/media_surface.gd")
const MODEL := "res://environments/grand_cinema/cinema.glb"
const DESCRIPTION := "res://environments/grand_cinema/manifest.json"
var manifest := {}
var stats := {}
var motion := Locomotion.new()
var camera: Camera3D
var environment_root: Node3D
var video_surface: Node3D
var movie: VideoStreamPlayer
var seat_picker: PanelContainer
var status: Label
var mode_button: Button
var seat_button: Button
var play_button: Button
var seat_buttons := {}
var marker: MeshInstance3D
var _pitch := 0.0
var _focused := true
var _paused := false
var _time := 0.0
var _fallback: ShaderMaterial
var _video_path := ""
var _hover_seat := ""
var _hover_floor: Variant = null
var _last_error := ""
var _video_size := Vector2.ZERO
var _was_ui_hovered := false
var _last_ui_state := ""

func _ready() -> void:
	if not Feature.enabled():
		set_process(false); set_process_input(false); set_process_unhandled_input(false)
		get_tree().change_scene_to_file.call_deferred("res://scenes/main.tscn")
		return
	var world := WorldEnvironment.new()
	world.environment = Environment.new()
	world.environment.background_mode = Environment.BG_COLOR
	world.environment.background_color = Color("080d15")
	world.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	world.environment.ambient_light_color = Color("7e94b3")
	world.environment.ambient_light_energy = 0.6
	add_child(world)
	camera = Camera3D.new()
	camera.near = 0.06; camera.far = 120.0; camera.fov = 78.0
	add_child(camera)
	_build_ui()
	_build_marker()
	status.text = "加载影院…"
	call_deferred("_load_initial")

func _load_initial() -> void:
	await get_tree().process_frame
	var model := MODEL
	var description := DESCRIPTION
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--cinema-model="): model = argument.trim_prefix("--cinema-model=")
		if argument.begins_with("--cinema-manifest="): description = argument.trim_prefix("--cinema-manifest=")
		if argument.begins_with("--cinema-video="): _video_path = argument.trim_prefix("--cinema-video=")
	environment_loaded.emit(load_cinema(model, description))

func load_cinema(model_path: String = MODEL, manifest_path: String = DESCRIPTION) -> bool:
	var loaded := Loader.new().load_environment(model_path, manifest_path)
	if loaded.has("error"):
		_last_error = str(loaded.error)
		status.text = _last_error
		return false
	var next_motion := Locomotion.new()
	next_motion.configure(loaded.manifest)
	if next_motion.selected_seat.is_empty():
		loaded.root.free()
		_last_error = "初始座位不可用"; status.text = _last_error
		return false
	if environment_root: environment_root.free()
	environment_root = loaded.root; add_child(environment_root)
	manifest = loaded.manifest; stats = loaded.stats
	_last_error = ""; _last_ui_state = ""
	motion = next_motion
	if video_surface: video_surface.free()
	if movie: movie.free(); movie = null
	_fallback = null; _video_size = Vector2.ZERO
	_build_screen()
	_rebuild_seats()
	_aim_screen()
	_sync_camera()
	_update_ui()
	return true

func _build_screen() -> void:
	var screen: Dictionary = manifest.screen
	var width := float(screen.width)
	var height := float(screen.height)
	video_surface = Surface.new()
	add_child(video_surface)
	video_surface.initialize_surface(preload("res://shaders/video_rvm_pair.gdshader"))
	video_surface.material.set_shader_parameter("alpha_enabled", false)
	video_surface.material.set_shader_parameter("sharpness", 0.0)
	video_surface.material.set_shader_parameter("source_size", Vector2(960, 540))
	var mesh := QuadMesh.new()
	# Preserve source aspect; the remaining tall aperture is a black physical screen.
	mesh.size = Vector2(width, minf(height, width * 9.0 / 16.0))
	video_surface.panel.mesh = mesh
	video_surface.set_flat_world_pose(Transform3D(Basis.IDENTITY, _vector(screen.position) + Vector3(0, 0, 0.035)))
	video_surface.panel.visible = true
	if _video_path.is_empty():
		_video_path = ProjectSettings.globalize_path("res://../../build/output/cinema-prototype/cinema-motion.ogv")
	if FileAccess.file_exists(_video_path):
		movie = VideoStreamPlayer.new()
		movie.visible = false
		movie.volume = 0.0
		var stream := VideoStreamTheora.new(); stream.file = _video_path
		movie.stream = stream
		movie.finished.connect(func(): if not _paused: movie.play())
		add_child(movie)
		movie.play()
		movie.paused = _paused
		video_surface.material.set_shader_parameter("color_texture", movie.get_video_texture())
	else:
		_fallback = ShaderMaterial.new()
		_fallback.shader = preload("res://shaders/cinema_idle.gdshader")
		video_surface.panel.material_override = _fallback

func _process(delta: float) -> void:
	if manifest.is_empty(): return
	if not _paused: _time += delta
	if _fallback: _fallback.set_shader_parameter("elapsed", _time)
	if movie:
		var texture := movie.get_video_texture()
		var dimensions := Vector2(texture.get_width(), texture.get_height()) if texture else Vector2.ZERO
		if dimensions.x > 0 and dimensions.y > 0 and dimensions != _video_size:
			_video_size = dimensions
			var screen_size := Vector2(float(manifest.screen.width), float(manifest.screen.height))
			var fitted := dimensions * minf(screen_size.x / dimensions.x, screen_size.y / dimensions.y)
			video_surface.panel.mesh.size = fitted
			video_surface.material.set_shader_parameter("source_size", dimensions)
	var axes := Vector2.ZERO
	var turning := 0.0
	var over_ui := get_viewport().gui_get_hovered_control() != null
	if over_ui != _was_ui_hovered:
		motion.suspend(); _was_ui_hovered = over_ui
	if _focused:
		axes = Vector2(float(Input.is_physical_key_pressed(KEY_D)) - float(Input.is_physical_key_pressed(KEY_A)),
			float(Input.is_physical_key_pressed(KEY_S)) - float(Input.is_physical_key_pressed(KEY_W)))
		turning = float(Input.is_physical_key_pressed(KEY_RIGHT)) - float(Input.is_physical_key_pressed(KEY_LEFT))
	if not _focused or seat_picker.visible or over_ui:
		motion.suspend()
	else:
		motion.step(axes, turning, delta)
	_sync_camera()
	_update_hover()
	_update_ui()

func _sync_camera() -> void:
	camera.position = motion.eye_position
	camera.rotation = Vector3(_pitch, motion.yaw, 0)

func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if event.pressed else Input.MOUSE_MODE_VISIBLE
		get_viewport().set_input_as_handled()
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED and not seat_picker.visible:
		motion.yaw -= event.relative.x * 0.003
		_pitch = clampf(_pitch - event.relative.y * 0.003, -1.35, 1.35)
		_sync_camera()
	if event is InputEventKey and event.pressed and not event.echo:
		match event.physical_keycode:
			KEY_ESCAPE:
				Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
				if seat_picker.visible: _toggle_seats()
				else: set_moving(false)
			KEY_M: set_moving(motion.mode == Locomotion.Mode.WATCH)
			KEY_C: _toggle_seats()
			KEY_SPACE: toggle_playback()
			KEY_HOME: choose_seat(str(manifest.get("default_seat", "H12")))

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed and not seat_picker.visible and _focused:
		_update_hover(event.position)
		if motion.mode == Locomotion.Mode.MOVE and _hover_floor is Vector3:
			motion.teleport_floor(_hover_floor)
		elif not _hover_seat.is_empty(): choose_seat(_hover_seat)

func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		_focused = false; motion.suspend(); Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif what == NOTIFICATION_APPLICATION_FOCUS_IN:
		_focused = true; motion.suspend()

func choose_seat(id: String) -> bool:
	if not motion.select_seat(id): return false
	_last_error = ""
	seat_picker.visible = false
	_aim_screen()
	_sync_camera()
	_update_ui()
	return true

func set_moving(enabled: bool) -> bool:
	seat_picker.visible = false
	var accepted := motion.set_moving(enabled)
	_update_ui()
	return accepted

func toggle_playback() -> void:
	_paused = not _paused
	if movie: movie.paused = _paused
	_update_ui()

func _aim_screen() -> void:
	var direction := _vector(manifest.screen.position) - motion.eye_position
	motion.yaw = atan2(-direction.x, -direction.z)
	_pitch = atan2(direction.y, Vector2(direction.x, direction.z).length())

func _toggle_seats() -> void:
	seat_picker.visible = not seat_picker.visible
	motion.suspend()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

func _build_marker() -> void:
	marker = MeshInstance3D.new()
	var ring := TorusMesh.new(); ring.inner_radius = 0.17; ring.outer_radius = 0.23
	marker.mesh = ring
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = Color("62d7c6")
	marker.material_override = material
	marker.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	marker.visible = false
	add_child(marker)

func _update_hover(mouse_position: Vector2 = Vector2(-1, -1)) -> void:
	_hover_seat = ""; _hover_floor = null; marker.visible = false
	if seat_picker.visible or Input.mouse_mode == Input.MOUSE_MODE_CAPTURED: return
	if get_viewport().gui_get_hovered_control() != null: return
	var mouse := get_viewport().get_mouse_position() if mouse_position.x < 0 else mouse_position
	var origin := camera.project_ray_origin(mouse)
	var direction := camera.project_ray_normal(mouse)
	var nearest := 100.0
	var obstruction := 100.0
	for collider in manifest.get("colliders", []):
		var id := str(collider.get("id", ""))
		if motion.mode == Locomotion.Mode.MOVE or not id.begins_with("seat_"):
			var bounds := AABB(_vector(collider.min), _vector(collider.max) - _vector(collider.min))
			var point: Variant = bounds.intersects_ray(origin, direction)
			if point is Vector3: obstruction = minf(obstruction, origin.distance_to(point))
	# Pick the nearest chair silhouette; the map can select seats hidden by other rows.
	if motion.mode == Locomotion.Mode.WATCH:
		for seat in manifest.seats:
			if str(seat.id) == motion.selected_seat: continue
			var eye := _vector(seat.eye_position)
			var hit: Variant = AABB(eye + Vector3(-0.36, -1.1, -0.25), Vector3(0.72, 1.15, 0.72)).intersects_ray(origin, direction)
			if hit is Vector3 and origin.distance_to(hit) < nearest and origin.distance_to(hit) <= obstruction + 0.01:
				nearest = origin.distance_to(hit); _hover_seat = str(seat.id)
				marker.position = eye + Vector3(0, -0.65, 0)
	else:
		for floor_data in manifest.get("walkable", []):
			var minimum := _vector(floor_data.get("min", [0, 0, 0]))
			var maximum := _vector(floor_data.get("max", [0, 0, 0]))
			var height := float(floor_data.get("height", minimum.y))
			if absf(direction.y) < 0.001: continue
			var distance := (height - origin.y) / direction.y
			if distance < 0 or distance >= nearest or distance > obstruction + 0.01: continue
			var point := origin + direction * distance
			if point.x >= minimum.x and point.x <= maximum.x and point.z >= minimum.z and point.z <= maximum.z:
				nearest = distance; _hover_floor = point; marker.position = point + Vector3(0, 0.035, 0)
	marker.visible = not _hover_seat.is_empty() or _hover_floor != null

func _build_ui() -> void:
	var layer := CanvasLayer.new(); add_child(layer)
	var canvas := Control.new(); canvas.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE; layer.add_child(canvas)
	var header := VBoxContainer.new(); header.position = Vector2(30, 24); header.mouse_filter = Control.MOUSE_FILTER_IGNORE
	canvas.add_child(header)
	var title := Label.new(); title.text = "GRAND CINEMA"; title.add_theme_font_size_override("font_size", 24)
	title.add_theme_color_override("font_color", Color("e3e9f3")); header.add_child(title)
	status = Label.new(); status.add_theme_font_size_override("font_size", 14)
	status.add_theme_color_override("font_color", Color("91a6bf")); header.add_child(status)
	var toolbar := PanelContainer.new()
	toolbar.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	toolbar.position = Vector2(-255, -110); toolbar.size = Vector2(510, 60)
	toolbar.add_theme_stylebox_override("panel", _panel_style()); canvas.add_child(toolbar)
	var row := HBoxContainer.new(); row.add_theme_constant_override("separation", 8); toolbar.add_child(row)
	mode_button = _button("自由移动", func(): set_moving(motion.mode == Locomotion.Mode.WATCH)); row.add_child(mode_button)
	seat_button = _button("选座", _toggle_seats); row.add_child(seat_button)
	play_button = _button("暂停", toggle_playback); row.add_child(play_button)
	row.add_child(_button("归位", func(): choose_seat(str(manifest.get("default_seat", "H12")))))
	var hint := Label.new(); hint.text = "右键环顾  ·  WASD 移动  ·  ← → 转向  ·  C 选座  ·  M 行走"
	hint.add_theme_font_size_override("font_size", 13); hint.add_theme_color_override("font_color", Color("94a5bc"))
	hint.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	hint.position = Vector2(-280, -30); hint.size.x = 560; hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.mouse_filter = Control.MOUSE_FILTER_IGNORE; canvas.add_child(hint)
	seat_picker = PanelContainer.new()
	seat_picker.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	seat_picker.position = Vector2(-320, -245); seat_picker.size = Vector2(640, 480)
	seat_picker.grow_horizontal = Control.GROW_DIRECTION_BOTH
	seat_picker.grow_vertical = Control.GROW_DIRECTION_BOTH
	seat_picker.add_theme_stylebox_override("panel", _panel_style()); seat_picker.visible = false
	canvas.add_child(seat_picker)

func _rebuild_seats() -> void:
	for child in seat_picker.get_children(): child.free()
	seat_buttons.clear()
	var box := VBoxContainer.new(); box.add_theme_constant_override("separation", 8); seat_picker.add_child(box)
	var heading := HBoxContainer.new(); box.add_child(heading)
	var title := Label.new(); title.text = "选择座位"; title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.add_theme_font_size_override("font_size", 19); heading.add_child(title)
	heading.add_child(_button("×", _toggle_seats))
	var screen := ColorRect.new(); screen.color = Color("a1c6d0"); screen.custom_minimum_size = Vector2(570, 4); box.add_child(screen)
	var rows := {}
	for seat in manifest.seats:
		var row_key := str(seat.id).left(1)
		if not rows.has(row_key):
			var row := HBoxContainer.new(); row.add_theme_constant_override("separation", 4)
			var label := Label.new(); label.text = row_key; label.custom_minimum_size.x = 20; row.add_child(label)
			box.add_child(row); rows[row_key] = row
		var button := Button.new()
		button.text = ""; button.custom_minimum_size = Vector2(22, 22)
		button.tooltip_text = str(seat.get("label", seat.id)); button.focus_mode = Control.FOCUS_NONE
		button.add_theme_stylebox_override("normal", _seat_style(Color("3e5068")))
		button.add_theme_stylebox_override("hover", _seat_style(Color("7b9fb6")))
		button.add_theme_stylebox_override("pressed", _seat_style(Color("60d3c0")))
		button.pressed.connect(choose_seat.bind(str(seat.id)))
		rows[row_key].add_child(button); seat_buttons[str(seat.id)] = button

func _update_ui() -> void:
	if manifest.is_empty(): return
	var state := "%s/%s/%s/%s" % [motion.mode, motion.selected_seat, _paused, _last_error]
	if state == _last_ui_state: return
	_last_ui_state = state
	var place := motion.selected_seat if motion.mode == Locomotion.Mode.WATCH else "漫游"
	status.text = _last_error if not _last_error.is_empty() else "%s  ·  %.0f m  ·  %d 席" % [place, manifest.screen.width, manifest.seats.size()]
	mode_button.text = "结束移动" if motion.mode == Locomotion.Mode.MOVE else "自由移动"
	play_button.text = "播放" if _paused else "暂停"
	for id in seat_buttons:
		var button: Button = seat_buttons[id]
		button.add_theme_stylebox_override("normal", _seat_style(Color("60d3c0") if id == motion.selected_seat else Color("3e5068")))

func _seat_style(color: Color) -> StyleBoxFlat:
	var style := StyleBoxFlat.new(); style.bg_color = color
	style.set_corner_radius_all(5)
	return style

func _button(text: String, action: Callable) -> Button:
	var button := Button.new(); button.text = text; button.custom_minimum_size = Vector2(112, 38)
	button.focus_mode = Control.FOCUS_NONE; button.add_theme_font_size_override("font_size", 16)
	button.pressed.connect(action)
	return button

func _panel_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new(); style.bg_color = Color(0.035, 0.055, 0.085, 0.96)
	style.set_corner_radius_all(14); style.set_content_margin_all(16)
	style.border_color = Color("26394e"); style.set_border_width_all(1)
	return style

static func _vector(value: Variant) -> Vector3:
	if value is Vector3: return value
	return Vector3(float(value[0]), float(value[1]), float(value[2])) if value is Array and value.size() >= 3 else Vector3.ZERO
