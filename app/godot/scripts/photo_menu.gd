extends "res://scripts/player_menu.gd"
## Photo controls share the existing ray-menu surface, glyphs and projection picker, with no
## video timeline. Background audio belongs to the application, independent of the image queue.
const PHOTO_PREVIOUS := 400

func _supports_half_layouts() -> bool:
	return false

const PHOTO_NEXT := 401
const PHOTO_INSPECT := 402
const PHOTO_RESET := 403
const PHOTO_MINUS := 404
const PHOTO_PLUS := 405
const PHOTO_GALLERY := 406
const PHOTO_DEPTH := 407
const PHOTO_STRENGTH := 408
const PHOTO_CURVE := 409
const PHOTO_PAGE_BACK := 410
const PHOTO_PAGE_NEXT := 411
const PHOTO_BACKGROUND := 412
const PHOTO_ADJUST := 413
const PHOTO_ADJUST_BACK := 414
const PHOTO_LAYOUT := 415
const PHOTO_RETURN := 416
const PHOTO_SHUFFLE := 417
const PHOTO_PORTRAIT := 418
const PHOTO_AUDIO := 430
const PHOTO_LAYOUT_BASE := 470
const PHOTO_WALL_ROWS := 490
var _layout_open := false
var _wall_rows_open := false
const Photo := preload("res://scripts/photo_display.gd")
const PHOTO_THUMB := 420
var queue_provider: Callable
var _gallery_open := false
var _gallery_start := 0

func _depth_maximum() -> float:
	return DepthStrength.PHOTO_MAX

func _depth_icon_target() -> int:
	return PHOTO_DEPTH

func _reset_navigation() -> void:
	super._reset_navigation()
	_gallery_open = false
	_layout_open = false
	_wall_rows_open = false

func navigate_back() -> bool:
	if has_pointer_capture() or not choices.opened.is_empty(): return super.navigate_back()
	if _wall_rows_open: _wall_rows_open = false
	elif _layout_open: _layout_open = false
	elif _gallery_open: _gallery_open = false
	else: return super.navigate_back()
	refresh()
	return true

func refresh_values() -> void:
	composition_changed.emit()
	if not visible: return
	var latest: Dictionary = state_provider.call() if state_provider.is_valid() else {}
	if _adjustment == "photo_view":
		var layout_changed: bool = latest.get("geometry", 0) != _state.get("geometry", 0) or latest.get("has_image", false) != _state.get("has_image", false) or latest.get("layout", 0) != _state.get("layout", 0) or (int(latest.get("gallery_focus", -1)) < 0) != (int(_state.get("gallery_focus", -1)) < 0) \
			or latest.get("native_stereo", false) != _state.get("native_stereo", false) or latest.get("loading", false) != _state.get("loading", false) \
			or latest.get("spatial_metadata", {}) != _state.get("spatial_metadata", {})
		_state = latest
		if layout_changed:
			_finish_adjustment()
			_draw()
		else:
			_refresh_adjustments()
			_update_highlights()
		return
	if latest != _state:
		var old_layout := _state.duplicate()
		var new_layout := latest.duplicate()
		for key in ["depth_strength", "depth_requested", "depth_enabled", "depth_error", "stereo_strategy", "stereo_ready", "render_strength", "portrait_enabled", "loading_caption", "audio_storage"]:
			old_layout.erase(key); new_layout.erase(key)
		_state = latest
		if old_layout != new_layout:
			_draw()
		else:
			_refresh_depth()
			_tips[PHOTO_DEPTH] = _depth_tip()
			if is_instance_valid(_status): _status.text = _photo_status()
			for button in _buttons:
				if button.target == PHOTO_STRENGTH:
					button.node.get_child(0).text = I18n.t("3D depth") + "  " + _depth_caption()
			_update_highlights()

func _can_depth() -> bool:
	return _state.get("has_image", false) and not _state.get("loading", false) and int(_state.get("geometry", 0)) == 0 \
		and not _state.get("stereo", false) and _state.get("depth_available", false)

func _bar_action_x(target: int) -> float:
	return {PHOTO_AUDIO:-0.58,PHOTO_LAYOUT:-0.30,PHOTO_RETURN:-0.44,
		107:-0.14,100:0.0,108:0.14,FAVORITE:0.28,PHOTO_SHUFFLE:0.44}.get(target,0.0)

func _draw_bar() -> void:
	_set_backdrop(Vector2(1.16, 0.27), Vector2.ZERO)
	_backdrop.material_override.set_shader_parameter("surface_color", Color(PANEL, 0.86))
	_backdrop.material_override.set_shader_parameter("corner_radius", 0.05)
	_title = _label(_fit_title(str(_state.get("title", "")), "", 0.9, 15), Vector3(0, 0.1, 0.004), 15)
	_title.modulate = MUTED
	var has: bool = _state.get("has_image", false)
	var portrait: bool = _state.get("portrait_requested",false)
	var groups: bool = int(_state.get("layout", 0)) == 2 and int(_state.get("gallery_focus", -1)) < 0
	var swapping: bool = _state.get("gallery_swapping", false)
	_glyph(PHOTO_GALLERY, "images", Vector2(-0.5, 0.025), 0.075, _state.get("count", 0) > 0, I18n.t("Images"))
	_glyph(PHOTO_INSPECT, "zoom", Vector2(-0.39, 0.025), 0.075, has and not portrait, _inspect_tip())
	_glyph(PHOTO_ADJUST, "adjust", Vector2(-0.28, 0.025), 0.075, has, I18n.t("Adjust image"))
	_glyph(PHOTO_PREVIOUS, "previous", Vector2(-0.14, 0.025), 0.085, _state.get("can_previous", false) and not swapping, I18n.t("Previous group" if groups else "Previous image"))
	_label("%d / %d" % [maxi(0, int(_state.get("index", -1)) + 1), int(_state.get("count", 0))], Vector3(0, 0.025, 0.004), 18)
	_glyph(PHOTO_NEXT, "next", Vector2(0.14, 0.025), 0.085, _state.get("can_next", false) and not swapping, I18n.t("Next group" if groups else "Next image"))
	_glyph(PHOTO_PORTRAIT, "alpha", Vector2(0.23, 0.025), 0.075, portrait or _state.get("portrait_available",false), I18n.t("Exit portrait" if portrait else "Portrait passthrough"))
	if int(_state.get("geometry", 0)) == 0:
		_glyph(PHOTO_DEPTH, "depth", Vector2(DEPTH_X, 0.025), 0.075, _can_depth(), _depth_tip())
	_glyph(MODE, "view_mode", Vector2(0.41, 0.025), 0.075, has and not portrait, I18n.t("Image mode"))
	_glyph(11, "settings", Vector2(0.5, 0.025), 0.075, has, I18n.t("Settings"))
	_status = _label(_photo_status(), Vector3(0, -0.075, 0.004), 15)
	_status.modulate = MUTED
	_round(107, "close", Vector2(_bar_action_x(107), 0.215), 0.08, has or _state.get("loading", false), false, I18n.t("Close image"))
	_round(100, "folder", Vector2(_bar_action_x(100), 0.215), 0.08, true, false, I18n.t("Library"))
	_round(108, "recenter", Vector2(_bar_action_x(108), 0.215), 0.08, true, false, I18n.t("Recenter"))
	_draw_favorite(Vector2(_bar_action_x(FAVORITE), 0.215))
	if not music_quick: music_quick = preload("res://scripts/music_quick_controls.gd").new(self, func(): action_requested.emit("music_toggle"))
	music_quick.draw(PHOTO_AUDIO, Vector2(_bar_action_x(PHOTO_AUDIO), 0.215), _state)
	var layout := clampi(int(_state.get("layout", 0)), 0, 3)
	_round(PHOTO_LAYOUT, ["image", "photo_sides", "photo_wall", "memory"][layout], Vector2(_bar_action_x(PHOTO_LAYOUT), 0.215), 0.08, has and not portrait, false, I18n.t("Photo layout"))
	var caption := _label(I18n.t("Portrait passthrough" if portrait else Photo.Gallery.NAMES[layout]), Vector3(_bar_action_x(PHOTO_LAYOUT), 0.15, 0.004), 12)
	caption.modulate = MUTED
	if layout in [2,3] and not portrait and not _depth_open and int(_state.get("gallery_focus", -1)) < 0:
		_round(PHOTO_SHUFFLE, "photo_batch" if layout == 2 else "dice", Vector2(_bar_action_x(PHOTO_SHUFFLE), 0.215), 0.08, has and not swapping, false, I18n.t("Next group" if layout == 2 else "Shuffle memories"))
	if portrait or int(_state.get("gallery_focus", -1)) >= 0:
		_round(PHOTO_RETURN, "up", Vector2(_bar_action_x(PHOTO_RETURN), 0.215), 0.08, true, false, I18n.t("Back"))
	_place_device_status(Vector2(0, -0.175))
	if _layout_open:
		_draw_layouts()
	elif _mode_open:
		_draw_modes()
		for button in _buttons:
			if button.target == MODE_STEREO + 3: button.enabled = bool(button.enabled) and _state.get("depth_available", false)
	elif _gallery_open:
		_draw_gallery()
	elif _depth_open:
		_draw_depth()

func _draw_layouts() -> void:
	if _wall_rows_open:
		for rows in range(1, 4):
			_button(PHOTO_WALL_ROWS + rows, I18n.t(["1 row", "2 rows", "3 rows"][rows - 1]), Vector2(-0.29 + (rows - 1) * 0.29, 0.46), Vector2(0.275, 0.13), true, "photo_wall")
			if rows == int(_state.get("wall_rows", 1)):
				_buttons.back().base_color = SELECTED
				_icon("check", Vector3(0.105, 0.040, 0.006), 0.028, ACCENT, _buttons.back().node)
		return
	var icons := ["image", "photo_sides", "photo_wall", "memory"]
	for i in 4:
		_button(PHOTO_LAYOUT_BASE + i, I18n.t(Photo.Gallery.NAMES[i]), Vector2(-0.435 + i * 0.29, 0.46), Vector2(0.275, 0.13), true, icons[i])
		if i == int(_state.get("layout", 0)):
			_buttons.back().base_color = SELECTED
			_icon("check", Vector3(0.105, 0.040, 0.006), 0.028, ACCENT, _buttons.back().node)

## Photo controls keep their full panels in place of the bar.
func _settings_popup() -> bool:
	return false

func _slider_geometry() -> Dictionary:
	return {"title_x": -0.66, "title_size": 20, "value_x": -0.06, "value_size": 18, "left": 0.03, "width": 0.6, "hit": 0.1,
		"height": 0.08, "thickness": 0.009, "knob": 0.025, "reset_x": 0.715, "reset_size": 0.065}

func _adjustment_row(target: int, key: String, title: String, span: Vector3, y: float) -> void:
	super._adjustment_row(target, key, title, span, y)
	# The shared video row defaults to has_video; photo sliders use their own content.
	_adjust_rows[target].button.enabled = int(_state.get("count", 0)) > 0 if key.begins_with("gallery_") else _state.get("has_image", false)

func _adjustment_default(key: String) -> Variant:
	if _adjustment != "photo_view": return super._adjustment_default(key)
	if key == "gallery_distance": return Photo.Gallery.DEFAULT_DISTANCES[clampi(int(_state.get("layout", 0)), 0, 3)]
	return {"screen_distance": Photo.DEFAULT_DISTANCE, "screen_scale": 1.0,
		"gallery_scale": 1.0, "inspect_magnification": Photo.DEFAULT_MAGNIFICATION}.get(key)

func _draw_adjustments() -> void:
	if _adjustment != "photo_view":
		super._draw_adjustments()
		return
	if int(_state.get("layout", 0)) in [2, 3] and int(_state.get("gallery_focus", -1)) < 0:
		_set_backdrop(Vector2(1.55, 0.50))
		_button(PHOTO_ADJUST_BACK, "", Vector2(-0.66, 0.19), Vector2(0.09, 0.065), true, "up")
		_button(CLOSE, "", Vector2(0.66, 0.19), Vector2(0.09, 0.065), true, "close")
		_label(I18n.t(Photo.Gallery.NAMES[int(_state.layout)]), Vector3(0, 0.19, 0.004), 24)
		_adjustment_row(450, "gallery_scale", "Image size", Vector3(Photo.Gallery.SCALE_LIMITS.x, Photo.Gallery.SCALE_LIMITS.y, 0.05), 0.02)
		_adjustment_row(451, "gallery_distance", "Distance", Vector3(Photo.Gallery.DISTANCE_LIMITS.x, Photo.Gallery.DISTANCE_LIMITS.y, 0.1), -0.125)
		_refresh_adjustments(); return
	var spatial: bool = _state.get("has_image", false) and not _state.get("loading", false) and _state.get("native_stereo", false) and _state.get("spatial_metadata", {}).has("horizontal_fov_degrees")
	_set_backdrop(Vector2(1.55, 0.74 if spatial else 0.64), Vector2(0, -0.05 if spatial else 0.0))
	_button(PHOTO_ADJUST_BACK, "", Vector2(-0.66, 0.25), Vector2(0.09, 0.065), true, "up")
	_button(CLOSE, "", Vector2(0.66, 0.25), Vector2(0.09, 0.065), true, "close")
	_label(I18n.t("Adjust image"), Vector3(0, 0.25, 0.004), 24)
	_adjustment_row(450, "screen_distance", "Distance", Vector3(Photo.PHOTO_DISTANCE_LIMITS.x, Photo.PHOTO_DISTANCE_LIMITS.y, 0.1), 0.10)
	_adjustment_row(451, "screen_scale", "Image size", Vector3(Photo.PHOTO_SCALE_LIMITS.x, Photo.PHOTO_SCALE_LIMITS.y, 0.1), -0.045)
	_adjustment_row(452, "inspect_magnification", "Magnification", Vector3(Photo.INSPECT_LIMITS.x, Photo.INSPECT_LIMITS.y, 0.1), -0.19)
	if spatial:
		_button(SPATIAL_FOV, I18n.t("Match spatial photo capture FOV"), Vector2(0, -0.31), Vector2(1.12, 0.06), bool(_state.get("spatial_fov_available", false)))
		set_label_size(_buttons.back().node.get_child(0), 18)
	for target in _adjust_rows:
		var enabled: bool = _state.get("has_image", false) and (target != 452 or not _state.get("portrait_requested",false)) and (target == 452 or int(_state.get("geometry", 0)) == 0)
		for button in _buttons:
			if button.target == target: button.enabled = enabled
		var row: Dictionary = _adjust_rows[target]
		row.label.modulate = Color.WHITE if enabled else MUTED
		row.fill.material_override.set_shader_parameter("surface_color", ACCENT if enabled else MUTED)
		row.knob.material_override.set_shader_parameter("surface_color", Color.WHITE if enabled else MUTED)
	_place_device_status(Vector2(0, -0.485 if spatial else -0.385))
	_refresh_adjustments()

func _refresh_adjustments() -> void:
	if _adjustment != "photo_view":
		super._refresh_adjustments()
		return
	_refresh_spatial_fov()
	for row in _adjust_rows.values():
		var fallback := Photo.DEFAULT_DISTANCE if row.key in ["screen_distance", "gallery_distance"] else (1.0 if row.key == "screen_scale" else Photo.DEFAULT_MAGNIFICATION)
		var value := float(_state.get(row.key, fallback))
		row["value"] = value
		var fraction := clampf((value - row.span.x) / (row.span.y - row.span.x), 0.0, 1.0)
		row.label.text = "%.1f m" % value if row.key in ["screen_distance", "gallery_distance"] else ("%d%%" % roundi(value * 100) if row.key in ["screen_scale", "gallery_scale"] else "%.1f×" % value)
		row.fill.visible = fraction > 0
		row.fill.mesh.size.x = maxf(0.001, fraction * 0.6)
		row.fill.position.x = 0.03 + fraction * 0.3
		row.fill.material_override.set_shader_parameter("surface_size", row.fill.mesh.size)
		row.knob.position.x = 0.03 + fraction * 0.6
	_refresh_slider_resets()

func _draw_panel() -> void:
	_set_backdrop(Vector2(1.16, 0.55))
	_button(10, "", Vector2(-0.48, 0.2), Vector2(0.085, 0.065), true, "up")
	_label(I18n.t("Images"), Vector3(0, 0.2, 0.004), 21)
	_button(PHOTO_STRENGTH, I18n.t("3D depth") + "  " + _depth_caption(), Vector2(-0.26, 0.035), Vector2(0.49, 0.105), _can_depth(), "depth")
	var names := ["Off", "Slight", "Medium", "Full"]
	var curve := [0.0, 0.35, 0.7, 1.0].find(float(_state.get("screen_curve", 0)))
	_button(PHOTO_CURVE, I18n.t("Screen curve") + "  " + I18n.t(names[maxi(0, curve)]), Vector2(0.26, 0.035), Vector2(0.49, 0.105), int(_state.get("geometry", 0)) == 0 and not _state.get("portrait_requested",false), "screen")
	_button(PHOTO_BACKGROUND, I18n.t("Use as background"), Vector2(0, -0.10), Vector2(0.56, 0.08), _state.get("can_background", false), "image")
	_status = _label(_photo_status(), Vector3(0, -0.19, 0.004), 15)
	_status.modulate = MUTED
	_place_device_status(Vector2(0, -0.32))

func _draw_gallery() -> void:
	var entries: Array = queue_provider.call() if queue_provider.is_valid() else []
	_gallery_start = clampi(_gallery_start, 0, maxi(0, entries.size() - 5))
	var background := _quad(Vector2(1.16, 0.23), Vector3(0, 0.465, 0.001), PANEL, 10)
	_pointer_panels.append(background)
	add_child(background); _decorations.append(background)
	_round(PHOTO_PAGE_BACK, "previous", Vector2(-0.64, 0.465), 0.075, _gallery_start > 0, false, I18n.t("Previous"))
	_round(PHOTO_PAGE_NEXT, "next", Vector2(0.64, 0.465), 0.075, _gallery_start + 5 < entries.size(), false, I18n.t("Next"))
	for i in mini(5, entries.size() - _gallery_start):
		var entry: Dictionary = entries[_gallery_start + i]
		var x := -0.44 + i * 0.22
		_button(PHOTO_THUMB + i, "", Vector2(x, 0.465), Vector2(0.2, 0.2), true, "image")
		var button: Dictionary = _buttons.back()
		if _gallery_start + i == int(_state.get("index", -1)): button.base_color = SELECTED
		_tips[PHOTO_THUMB + i] = str(entry.get("title", ""))
		var texture := preload("res://scripts/thumbnail_cache.gd").texture(str(entry.uri))
		if texture:
			var image := MeshInstance3D.new()
			var quad := QuadMesh.new(); quad.size = Vector2(0.18, 0.10125)
			image.mesh = quad
			var mat := _material(Color.WHITE, 14)
			mat.albedo_texture = texture
			image.material_override = mat; image.position.z = 0.005
			button.node.add_child(image)
		var caption := _label(_fit_title(str(entry.get("title", "")), "", 0.18, 12), Vector3(0,-0.077,0.008),12,button.node)
		caption.modulate = MUTED

func stick_scroll(amount: float, delta: float) -> void:
	if has_expanded_library():
		if not _controls_pointer_capture(): expanded_library.stick_scroll(amount, delta)
		return
	if choices.stick_scroll(amount, delta): return
	if not _gallery_open or absf(amount) < 0.7: return
	if Time.get_ticks_msec() < _scroll_after: return
	_scroll_after = Time.get_ticks_msec() + 200
	_gallery_start += -1 if amount > 0 else 1
	_draw()

var _scroll_after := 0

func _activate(target: int) -> void:
	if target == FAVORITE:
		favorite_requested.emit(); refresh_values(); return
	if _activate_footer(target): return
	if _activate_slider_reset(target): return
	if _activate_depth_reset(target): return
	if target == PHOTO_AUDIO:
		action_requested.emit("music_open"); return
	if target > PHOTO_WALL_ROWS and target <= PHOTO_WALL_ROWS + 3:
		_layout_open = false; _wall_rows_open = false
		action_requested.emit("photo_wall_rows_%d" % (target - PHOTO_WALL_ROWS))
		refresh(); return
	if target >= PHOTO_LAYOUT_BASE and target < PHOTO_LAYOUT_BASE + 4:
		if target == PHOTO_LAYOUT_BASE + 2:
			_wall_rows_open = true; refresh(); return
		_layout_open = false
		_wall_rows_open = false
		action_requested.emit("photo_layout_%d" % (target - PHOTO_LAYOUT_BASE))
		refresh(); return
	if target == PHOTO_LAYOUT:
		_wall_rows_open = false
		_layout_open = not _layout_open; _gallery_open = false; _mode_open = false; _close_depth_slider()
		refresh(); return
	if target == PHOTO_PORTRAIT:
		_layout_open = false; _gallery_open = false; _mode_open = false; _close_depth_slider()
		action_requested.emit("photo_portrait"); refresh(); return
	if target == PHOTO_SHUFFLE:
		action_requested.emit("photo_shuffle"); refresh(); return
	if target == PHOTO_RETURN:
		action_requested.emit("photo_return"); refresh(); return
	_layout_open = false
	if _adjustment == "photo_view":
		_finish_adjustment()
		if target == CLOSE:
			dismiss()
			return
		if target == PHOTO_ADJUST_BACK: _adjustment = ""
		elif target == SPATIAL_FOV and _state.get("spatial_fov_available", false): action_requested.emit("spatial_match_fov")
		refresh()
		return
	if target == PHOTO_ADJUST:
		_close_depth_slider()
		_mode_open = false
		_gallery_open = false
		section = 0
		_adjustment = "photo_view"
		refresh()
		return
	if target in [PHOTO_DEPTH, PHOTO_STRENGTH]:
		section = 0
		_gallery_open = false
		_toggle_depth_slider()
		return
	_close_depth_slider()
	match target:
		CLOSE: dismiss()
		100: recent_requested.emit()
		107: action_requested.emit("stop")
		108: action_requested.emit("recenter")
		10, 11: section = target - 10
		MODE: _mode_open = not _mode_open; _gallery_open = false
		PHOTO_PREVIOUS: action_requested.emit("photo_previous")
		PHOTO_NEXT: action_requested.emit("photo_next")
		PHOTO_INSPECT: action_requested.emit("photo_inspect")
		PHOTO_RESET: action_requested.emit("photo_fit")
		PHOTO_CURVE: action_requested.emit("screen_curve")
		PHOTO_PAGE_BACK: _gallery_start -= 5
		PHOTO_PAGE_NEXT: _gallery_start += 5
		PHOTO_BACKGROUND: action_requested.emit("photo_background")
		PHOTO_GALLERY:
			_gallery_open = not _gallery_open; _mode_open = false
			_gallery_start = maxi(0, int(_state.get("index", 0)) - 2)
		_:
			if _lit_modes.has(target): action_requested.emit("lock_mode")
			elif target >= MODE_PROJECTION and target < MODE_PROJECTION + 4: action_requested.emit("projection_%d" % (target - MODE_PROJECTION))
			elif target == MODE_STEREO: action_requested.emit("stereo_2d")
			elif target == MODE_STEREO + 1: action_requested.emit("stereo_sbs")
			elif target == MODE_STEREO + 2: action_requested.emit("eyes")
			elif target == MODE_STEREO + 3: action_requested.emit("depth")
			elif target == MODE_STEREO + 4: action_requested.emit("stereo_tb")
			elif target >= MODE_LENS and target < MODE_LENS + 4: action_requested.emit("fov_%d" % LENS_FOVS[target - MODE_LENS])
			elif target >= PHOTO_THUMB and target < PHOTO_THUMB + 5: action_requested.emit("photo_index_%d" % (_gallery_start + target - PHOTO_THUMB))
	refresh()

func _inspect_tip() -> String:
	return I18n.t("Inspect") + "  %.1f×" % float(_state.get("inspect_magnification", Photo.DEFAULT_MAGNIFICATION))

func _photo_status() -> String:
	if not _favorite_notice.is_empty(): return I18n.t(_favorite_notice)
	if not str(_state.get("loading_caption", "")).is_empty(): return str(_state.loading_caption)
	if not str(_state.get("portrait_error", "")).is_empty(): return I18n.t(str(_state.portrait_error))
	if _state.get("portrait_requested",false):
		if _state.get("portrait_enabled",false) and not is_equal_approx(float(_state.get("render_strength",-1)),float(_state.get("depth_strength",1))): return I18n.t("Preparing 3D")
		return I18n.t("Portrait passthrough" if _state.get("portrait_enabled",false) else "Preparing portrait")
	if _state.get("directory_loading", false): return I18n.t("Loading images")
	if not str(_state.get("directory_error", "")).is_empty(): return I18n.t(str(_state.directory_error))
	if _state.get("loading", false): return I18n.t("Preparing 3D" if _state.get("preparing_depth", false) else "Loading image")
	if not str(_state.get("error", "")).is_empty(): return I18n.t(str(_state.error))
	if not str(_state.get("depth_error", "")).is_empty(): return I18n.t(str(_state.depth_error))
	if _state.get("depth_requested", false): return I18n.t("3D on" if _state.get("depth_enabled", false) else "Preparing 3D")
	return str(_state.get("source_size", ""))

func _update_highlights() -> void:
	if _tips.has(PHOTO_INSPECT): _tips[PHOTO_INSPECT] = _inspect_tip()
	super._update_highlights()
	for button in _buttons:
		if (button.target == PHOTO_INSPECT and _state.get("inspect", false)) or (button.target == PHOTO_DEPTH and _state.get("depth_requested", false)):
			button.node.material_override.set_shader_parameter("surface_color", SELECTED)
		if button.target == PHOTO_PORTRAIT and button.enabled and _state.get("portrait_requested",false) and not _hover.values().has(button.target):
			button.node.material_override.set_shader_parameter("surface_color", Color(0.16, 0.31, 0.27))
