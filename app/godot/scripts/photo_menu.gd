extends "res://scripts/player_menu.gd"
## Photo controls share the existing ray-menu surface, glyphs and projection picker, with no
## video timeline. Background audio belongs to the application, independent of the image queue.
const PHOTO_COMIC := 986060
const PHOTO_COMIC_VOICE := 986061
const PHOTO_COMIC_PREVIEW := 986062
const PHOTO_COMIC_MANAGE := 986064
const PHOTO_TRANSLATION := 986065
const PHOTO_TRANSLATION_RETRY := 986066
const ComicSettings := preload("res://scripts/comic_reading_settings.gd")
const PHOTO_PREVIOUS := 400
signal online_image_requested(item: Dictionary, spherical: bool)
const PHOTO_ONLINE := 985002
const PHOTO_SAVE := 985003
const OnlinePanorama := preload("res://scripts/online_panorama_panel.gd")
var online := OnlinePanorama.new(self)

func _process(delta: float) -> void:
	super._process(delta)
	online.tick(delta)

func _draw() -> void:
	if _adjustment == "bar_transparency": super._draw(); return
	if online.opened:
		_clear_layout(); online.draw(); _finish_surface_layout(); return
	super._draw()

func dismiss() -> void:
	online.hide()
	super.dismiss()

func _exit_tree() -> void:
	online.shutdown()

func has_pointer_capture() -> bool:
	return not online.hand.is_empty() or super.has_pointer_capture()

func press_pointer(hand: String, origin: Vector3, direction: Vector3, tracked: bool) -> bool:
	if online.press(hand,origin,direction,tracked): return true
	return super.press_pointer(hand,origin,direction,tracked)

func update_pointer(hand: String, origin: Vector3, direction: Vector3, tracked: bool) -> void:
	super.update_pointer(hand,origin,direction,tracked)
	online.move(hand,origin,direction,tracked)

func release_pointer(hand: String, origin: Vector3, direction: Vector3, tracked: bool) -> void:
	if online.release(hand,origin,direction,tracked): return
	super.release_pointer(hand,origin,direction,tracked)

func cancel_pointer(hand: String) -> void:
	if online.hand==hand: online.cancel()
	super.cancel_pointer(hand)

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
const PHOTO_GLOBAL_BACKGROUND := 433
const PHOTO_ADJUST := 413
const PHOTO_ADJUST_BACK := 414
const PHOTO_LAYOUT := 415
const PHOTO_RETURN := 416
const PHOTO_SHUFFLE := 417
const PHOTO_PORTRAIT := 418
const PHOTO_SPATIAL := 419
const PHOTO_AUDIO := 430
const PHOTO_STATIC := 432
const PHOTO_LAYOUT_BASE := 470
const PHOTO_SCENERY := 986000
const PHOTO_SCENERY_BASE := 986010
const PHOTO_SCENERY_YAW := 986020
const PHOTO_SCENERY_LIGHT := 986021
const PHOTO_SCENERY_IMPORT := 986022
const PHOTO_SCENERY_BACK := 986023
const PHOTO_MAGAZINE_ORDER := 986050
const SCENERIES := ["belfast", "morning", "dark", "passthrough", "custom", "global_custom"]
const SCENERY_NAMES := ["Belfast sunset", "Morning sky", "Dark background", "Passthrough", "Custom panorama", "Global custom panorama"]
const LAYOUT_ORDER := [0, 4, 1, 2, 3]
const LAYOUT_ICONS := ["image", "photo_sides", "photo_wall", "memory", "magazine"]
var _scenery_open := false
const PHOTO_WALL_ROWS := 490
var _layout_open := false
var _wall_rows_open := false
var _magazine_order_open := false
const Photo := preload("res://scripts/photo_display.gd")
const PHOTO_THUMB := 420
var queue_provider: Callable
var _gallery_open := false
var _gallery_start := 0

func _depth_maximum() -> float:
	return DepthStrength.PHOTO_MAX

func _depth_default() -> float:
	return DepthStrength.PHOTO_DEFAULT

func _depth_span() -> Vector2:
	return DEPTH_SPAN if _state.get("portrait_requested",false) else DEPTH_SPAN-Vector2(.03,.03)

func _depth_icon_target() -> int:
	return PHOTO_DEPTH

func _spatial_mode() -> bool:
	return bool(_state.get("spatial_preferred",false)) and not _state.get("portrait_requested",false)

func _depth_tip() -> String:
	return I18n.t("Spatial stereo" if _spatial_mode() else "Static 3D") if _state.get("native_stereo",false) else super._depth_tip()

func _depth_caption() -> String:
	if _state.get("native_stereo",false): return _depth_tip()
	if _spatial_mode() and _state.get("depth_requested",false): return I18n.t("Spatial view")
	return super._depth_caption()

func _set_depth_at(y: float) -> void:
	if _spatial_mode() or _state.get("native_stereo",false): return
	var span:=_depth_span()
	var fraction:=clampf((y-span.x)/(span.y-span.x),0,1)
	var strength:=DepthStrength.from_fraction(fraction,_depth_maximum())
	var level:=roundi(strength*100)
	if level==_depth_sent: return
	_depth_sent=level; depth_strength_requested.emit(strength); refresh_values()

func _press_quick_icon(hand: String, target: int) -> bool:
	if target==PHOTO_DEPTH and _state.get("native_stereo",false):
		# This entry selects native viewing modes; double-click never converts or disables the pair.
		_icon_tap.clear(); return false
	return super._press_quick_icon(hand,target)

func _photo_mode_option(target: int, title: String, y: float, selected: bool) -> void:
	_button(target,title,Vector2(DEPTH_X,y),Vector2(.29,.065))
	var button: Dictionary=_buttons.back()
	button.base_color=SELECTED if selected else TILE
	button["photo_mode_selected"]=selected
	var caption: Label3D=button.node.get_child(0)
	caption.horizontal_alignment=HORIZONTAL_ALIGNMENT_LEFT; caption.position.x=-.127
	var ring:=_quad(Vector2(.030,.030),Vector3(.105,0,.004),ACCENT if selected else MUTED,13)
	ring.material_override.set_shader_parameter("corner_radius",.015); button.node.add_child(ring)
	var inside:=_quad(Vector2(.022,.022),Vector3(0,0,.002),button.base_color,14)
	inside.material_override.set_shader_parameter("corner_radius",.011); ring.add_child(inside)
	if selected:
		var dot:=_quad(Vector2(.012,.012),Vector3(0,0,.002),ACCENT,15)
		dot.material_override.set_shader_parameter("corner_radius",.006); inside.add_child(dot)

func _draw_photo_modes(centre: float) -> void:
	var panel:=_quad(Vector2(.32,.21),Vector3(DEPTH_X,centre,.001),Color(PANEL,1),10)
	add_child(panel); _decorations.append(panel); _block_rays(panel,panel.mesh.size)
	_photo_mode_option(PHOTO_SPATIAL,I18n.t("Spatial stereo"),centre+.045,_spatial_mode())
	_photo_mode_option(PHOTO_STATIC,I18n.t("Static 3D"),centre-.045,not _spatial_mode())

func _draw_depth() -> void:
	var native: bool=_state.get("native_stereo",false)
	if not native and _state.get("portrait_requested",false): super._draw_depth(); return
	if not native and not _spatial_mode():
		super._draw_depth()
		var before:=get_children()
		_draw_photo_modes(_depth_span().y+.21)
		_raise_quick_popup(before)
		return
	# Native stereo always keeps its captured depth; spatial relief also has no adjustable rail.
	var before:=get_children()
	_draw_photo_modes(.18)
	_raise_quick_popup(before)

func _reset_navigation() -> void:
	super._reset_navigation()
	_gallery_open = false
	_layout_open = false
	_wall_rows_open = false
	_magazine_order_open = false
	_scenery_open = false

func navigate_back() -> bool:
	if online.back(): return true
	if has_pointer_capture() or not choices.opened.is_empty(): return super.navigate_back()
	if _scenery_open: _scenery_open = false
	elif _magazine_order_open: _magazine_order_open = false
	elif _wall_rows_open: _wall_rows_open = false
	elif _layout_open: _layout_open = false
	elif _gallery_open: _gallery_open = false
	else: return super.navigate_back()
	refresh()
	return true

func refresh_values() -> void:
	if _adjustment == "bar_transparency": super.refresh_values(); return
	composition_changed.emit()
	if not visible: return
	if online.opened: return
	var latest: Dictionary = state_provider.call() if state_provider.is_valid() else {}
	latest["bar_transparency"] = bar_transparency
	if _adjustment in ["comic_voice", "comic_translation"] and has_pointer_capture():
		_state = latest
		if is_instance_valid(_status): _status.text = _fitted_photo_status()
		return
	if _adjustment == "comic_voice" and _comic_preview_busy(latest) != _comic_preview_drawn_busy:
		_state = latest; _draw(); return
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
		# The music clock is not drawn here. Its regular updates must not rebuild
		# photo buttons and clear the ray hover, pointer dot and tooltip.
		for key in ["translation_state", "translation_count", "translation_total", "translation_provider", "comic_state", "comic_speech", "comic_ready_audio", "comic_readable", "comic_candidates", "depth_strength", "depth_requested", "depth_enabled", "depth_error", "stereo_strategy", "stereo_ready", "render_strength", "portrait_enabled", "loading_caption", "audio_storage", "audio_position", "audio_duration"]:
			old_layout.erase(key); new_layout.erase(key)
		_state = latest
		if old_layout != new_layout:
			_draw()
		else:
			_refresh_depth()
			_tips[PHOTO_DEPTH] = _depth_tip()
			if is_instance_valid(_status): _status.text = _fitted_photo_status()
			for button in _buttons:
				if button.target == PHOTO_STRENGTH:
					button.node.get_child(0).text = I18n.t("3D depth") + "  " + _depth_caption()
			_update_highlights()

func _can_depth() -> bool:
	return _state.get("has_image", false) and not _state.get("loading", false) and int(_state.get("geometry", 0)) == 0 \
		and (_state.get("native_stereo",false) or (not _state.get("stereo", false) and _state.get("depth_available", false)))

func _bar_has_return() -> bool:
	return _state.get("portrait_requested", false) or int(_state.get("gallery_focus", -1)) >= 0

func _bar_has_group() -> bool:
	var layout := int(_state.get("layout", 0))
	return layout in [2,3] and not _bar_has_return() and not _depth_open

func _bar_action_x(target: int) -> float:
	var online_x := 0.56 + (0.14 if _bar_has_group() else 0.0)
	return {PHOTO_AUDIO:-0.56 if _bar_has_return() else -0.42,PHOTO_LAYOUT:-0.28,PHOTO_RETURN:-0.42,
		107:-0.14,100:0.0,108:0.14,FAVORITE:0.28,PHOTO_SCENERY:0.42,PHOTO_SHUFFLE:0.56,
		PHOTO_ONLINE:online_x,PHOTO_SAVE:online_x + (0.14 if OnlinePanorama.AVAILABLE else 0.0)}.get(target,0.0)

func _draw_bar() -> void:
	if _scenery_open:
		_draw_scenery(); return
	if _state.get("archive_mode", false): _gallery_open = false
	_set_backdrop(Vector2(1.16, 0.27), Vector2.ZERO)
	_style_control_bar()
	_backdrop.material_override.set_shader_parameter("corner_radius", 0.05)
	_title = _label(_fit_title(str(_state.get("title", "")), "", 0.9, 15), Vector3(0, 0.1, 0.004), 15)
	_back_filename(_title, 0.9)
	_title.modulate = MUTED
	var has: bool = _state.get("has_image", false) or _state.get("gallery_overview", false)
	var portrait: bool = _state.get("portrait_requested",false)
	var swapping: bool = _state.get("gallery_swapping", false)
	if not _state.get("archive_mode", false): _glyph(PHOTO_GALLERY, "images", Vector2(-0.5, 0.025), 0.075, _state.get("count", 0) > 0, I18n.t("Images"))
	_glyph(PHOTO_INSPECT, "zoom", Vector2(-0.39, 0.025), 0.075, has and not portrait, _inspect_tip())
	_glyph(PHOTO_ADJUST, "adjust", Vector2(-0.28, 0.025), 0.075, has, I18n.t("Adjust image"))
	_glyph(PHOTO_PREVIOUS, "previous", Vector2(-0.14, 0.025), 0.085, _state.get("can_previous", false) and not swapping, I18n.t("Previous image"))
	var start := maxi(0, int(_state.get("index", -1)) + 1)
	var pages := int(_state.get("magazine_pages", 1))
	var counter := "%d–%d / %d" % [start, start + pages - 1, int(_state.get("count", 0))] if pages > 1 and start > 0 else "%d / %d" % [start, int(_state.get("count", 0))]
	_label(counter, Vector3(0, 0.025, 0.004), 16 if pages > 1 else 18)
	_glyph(PHOTO_NEXT, "next", Vector2(0.14, 0.025), 0.085, _state.get("can_next", false) and not swapping, I18n.t("Next image"))
	_glyph(PHOTO_PORTRAIT, "alpha", Vector2(0.23, 0.025), 0.075, portrait or _state.get("portrait_available",false), I18n.t("Exit portrait" if portrait else "Portrait passthrough"))
	if int(_state.get("geometry", 0)) == 0:
		_glyph(PHOTO_DEPTH, "depth", Vector2(DEPTH_X, 0.025), 0.075, _can_depth(), _depth_tip())
	_glyph(MODE, "view_mode", Vector2(0.41, 0.025), 0.075, has and not portrait and int(_state.get("layout", 0)) != 4, I18n.t("Image mode"))
	_glyph(11, "settings", Vector2(0.5, 0.025), 0.075, has, I18n.t("Settings"))
	_status = _label(_fit_title(_photo_status(), "", 0.76, 15), Vector3(-0.11, -0.075, 0.004), 15)
	_status.modulate = MUTED
	_round(PHOTO_TRANSLATION, "translate", Vector2(0.4, -0.075), 0.065, has and _state.get("comic_supported", false), _state.get("translation_enabled", false), I18n.t("Comic translation (Beta)"))
	_round(PHOTO_COMIC_VOICE, "comic_voice", Vector2(0.5, -0.075), 0.065, has and _state.get("comic_supported", false), _state.get("comic_enabled", false), I18n.t("Comic reading (Beta)"))
	var has_selection: bool = has or _state.get("loading", false) or int(_state.get("count", 0)) > 0 or not str(_state.get("error", "")).is_empty()
	_round(107, "close", Vector2(_bar_action_x(107), 0.215), 0.08, has_selection, false, I18n.t("Close image"))
	_round(100, "folder", Vector2(_bar_action_x(100), 0.215), 0.08, true, false, I18n.t("Library"))
	_round(108, "recenter", Vector2(_bar_action_x(108), 0.215), 0.08, true, false, I18n.t("Recenter"))
	if OnlinePanorama.AVAILABLE:
		_round(PHOTO_ONLINE, "globe", Vector2(_bar_action_x(PHOTO_ONLINE), 0.215), 0.08, true, online.opened, I18n.t("Online panoramas"))
	if _state.get("can_save_pictures",false):
		var saving: String=_state.get("pictures_save",{}).get("state","")
		_round(PHOTO_SAVE,"check" if saving=="saved" else "download",Vector2(_bar_action_x(PHOTO_SAVE),0.215),0.08,saving not in ["saving","saved"],saving=="saved",I18n.t("Saved to Pictures" if saving=="saved" else "Save to Pictures"))
	_draw_favorite(Vector2(_bar_action_x(FAVORITE), 0.215))
	_round(PHOTO_SCENERY, "panorama", Vector2(_bar_action_x(PHOTO_SCENERY), 0.215), 0.08, true, _scenery_open, I18n.t("Photo background"))
	if not music_quick: music_quick = preload("res://scripts/music_quick_controls.gd").new(self, func(): action_requested.emit("music_toggle"))
	music_quick.draw(PHOTO_AUDIO, Vector2(_bar_action_x(PHOTO_AUDIO), 0.215), _state)
	var layout := clampi(int(_state.get("layout", 0)), 0, 4)
	_round(PHOTO_LAYOUT, LAYOUT_ICONS[layout], Vector2(_bar_action_x(PHOTO_LAYOUT), 0.215), 0.08, has_selection and not portrait, false, I18n.t("Photo layout"))
	var layout_caption := I18n.t("Portrait passthrough" if portrait else Photo.Gallery.NAMES[layout])
	if layout == 2 and not portrait: layout_caption += " · " + I18n.t(["1 row", "2 rows", "3 rows"][clampi(int(_state.get("wall_rows", 1)), 1, 3) - 1])
	if layout == 4: layout_caption += " · " + I18n.t("Right to left" if _state.get("magazine_rtl", false) else "Left to right")
	var caption := _label(layout_caption, Vector3(_bar_action_x(PHOTO_LAYOUT), 0.15, 0.004), 12)
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
		if int(_state.get("geometry",0))==0 and not _state.get("native_stereo",false) and (_state.get("depth_requested",false) \
			or _state.get("spatial_available",false) or _state.get("spatial_requested",false)):
			var spatial_panel:=_quad(Vector2(1.06,0.105),Vector3(0,0.705,0.001),Color(PANEL,0.94),10)
			_pointer_panels.append(spatial_panel); add_child(spatial_panel); _decorations.append(spatial_panel)
			_button(PHOTO_SPATIAL,I18n.t("Spatial view"),Vector2(0,0.705),Vector2(0.35,0.065),_state.get("spatial_available",false) or _state.get("spatial_requested",false))
			if _spatial_mode(): _buttons.back().base_color=SELECTED
		for button in _buttons:
			if button.target == MODE_STEREO + 3: button.enabled = bool(button.enabled) and _state.get("depth_available", false)
	elif _gallery_open:
		_draw_gallery()
	elif _depth_open:
		_draw_depth()

func _draw_layouts() -> void:
	if _magazine_order_open:
		for direction in 2:
			_button(PHOTO_MAGAZINE_ORDER + direction, I18n.t("Left to right" if direction == 0 else "Right to left"), Vector2((direction - 0.5) * 0.29, 0.46), Vector2(0.275, 0.13), true, "magazine")
			if bool(direction) == bool(_state.get("magazine_rtl", false)):
				_buttons.back().base_color = SELECTED
				_icon("check", Vector3(0.105, 0.040, 0.006), 0.028, ACCENT, _buttons.back().node)
		return
	if _wall_rows_open:
		for rows in range(1, 4):
			_button(PHOTO_WALL_ROWS + rows, I18n.t(["1 row", "2 rows", "3 rows"][rows - 1]), Vector2(-0.29 + (rows - 1) * 0.29, 0.46), Vector2(0.275, 0.13), true, "photo_wall")
			if rows == int(_state.get("wall_rows", 1)):
				_buttons.back().base_color = SELECTED
				_icon("check", Vector3(0.105, 0.040, 0.006), 0.028, ACCENT, _buttons.back().node)
		return
	var order: Array = [0, 4] if _state.get("archive_mode", false) else LAYOUT_ORDER
	for slot in order.size():
		var i: int = order[slot]
		_button(PHOTO_LAYOUT_BASE + i, I18n.t(Photo.Gallery.NAMES[i]), Vector2((slot - (order.size() - 1) * 0.5) * 0.29, 0.46), Vector2(0.275, 0.13), true, LAYOUT_ICONS[i])
		if i == int(_state.get("layout", 0)):
			_buttons.back().base_color = SELECTED
			_icon("check", Vector3(0.105, 0.040, 0.006), 0.028, ACCENT, _buttons.back().node)

func _draw_scenery() -> void:
	var choices := [0, 1, 2, 3]
	if _state.get("photo_background_custom", false): choices.append(4)
	if _state.get("photo_global_custom", false): choices.append(5)
	var rows := ceili(choices.size() / 2.0)
	var bottom := 0.14 - (rows - 1) * 0.13
	var sky: bool = _state.get("photo_background", "belfast") in ["belfast", "morning", "custom"]
	if sky: bottom -= 0.14
	var can_import: bool = _state.get("can_background", false)
	if can_import: bottom -= 0.12
	_set_backdrop(Vector2(1.16, 0.37 - bottom + 0.15), Vector2(0, (0.37 + bottom - 0.15) * 0.5))
	_button(PHOTO_SCENERY_BACK, "", Vector2(-0.49, 0.29), Vector2(0.08, 0.065), true, "up")
	_button(CLOSE, "", Vector2(0.49, 0.29), Vector2(0.08, 0.065), true, "close")
	_label(I18n.t("Photo background"), Vector3(0, 0.29, 0.004), TEXT_PAGE_TITLE).font = ui_bold_font()
	for slot in choices.size():
		var i: int = choices[slot]
		_button(PHOTO_SCENERY_BASE + i, I18n.t(SCENERY_NAMES[i]), Vector2(-0.26 + (slot % 2) * 0.52, 0.14 - (slot / 2) * 0.13), Vector2(0.49, 0.105), i != 5 or not _state.get("photo_background_loading", false))
		if _state.get("photo_background", "belfast") == SCENERIES[i]: _buttons.back().base_color = SELECTED
	var controls_y := 0.14 - (rows - 1) * 0.13 - 0.14
	if sky:
		_button(PHOTO_SCENERY_YAW, I18n.t("Direction") + "  %d°" % int(_state.get("photo_background_yaw", 0)), Vector2(-0.26, controls_y), Vector2(0.49, 0.075))
		_button(PHOTO_SCENERY_LIGHT, I18n.t("Brightness") + "  %d%%" % roundi(float(_state.get("photo_background_brightness", 1.0)) * 100), Vector2(0.26, controls_y), Vector2(0.49, 0.075))
	if can_import:
		_photo_background_button(PHOTO_SCENERY_IMPORT, "Use current panorama", Vector2(0, bottom), Vector2(0.74, 0.075))
	_status = _label(_photo_status(), Vector3(0, bottom - 0.09, 0.004), 15)
	_status.modulate = MUTED
	_place_device_status(Vector2(0, bottom - 0.21))

## Photo controls keep their full panels in place of the bar.
func _settings_popup() -> bool:
	if _adjustment == "bar_transparency": return true
	return false

func _slider_geometry() -> Dictionary:
	return {"title_x": -0.66, "title_size": TEXT_BODY, "value_x": -0.06, "value_size": TEXT_BODY, "left": 0.03, "width": 0.6, "hit": 0.1,
		"height": 0.08, "thickness": 0.009, "knob": 0.025, "reset_x": 0.715, "reset_size": 0.065}

func _adjustment_row(target: int, key: String, title: String, span: Vector3, y: float) -> void:
	super._adjustment_row(target, key, title, span, y)
	# The shared video row defaults to has_video; photo sliders use their own content.
	_adjust_rows[target].button.enabled = int(_state.get("count", 0)) > 0 if key.begins_with("gallery_") else _state.get("has_image", false)

func _adjustment_default(key: String) -> Variant:
	if _adjustment != "photo_view": return super._adjustment_default(key)
	if key == "gallery_distance": return Photo.Gallery.DEFAULT_DISTANCES[clampi(int(_state.get("layout", 0)), 0, 4)]
	return {"screen_distance": Photo.DEFAULT_DISTANCE, "screen_scale": 1.0,
		"gallery_scale": 1.0, "inspect_magnification": Photo.DEFAULT_MAGNIFICATION}.get(key)

func _draw_adjustments() -> void:
	if _adjustment == "comic_translation":
		_draw_translation_settings(); return
	if _adjustment == "comic_voice":
		_draw_comic_settings(); return
	if _adjustment != "photo_view":
		super._draw_adjustments()
		return
	if int(_state.get("layout", 0)) in [2, 3] and int(_state.get("gallery_focus", -1)) < 0:
		_set_backdrop(Vector2(1.55, 0.50))
		_button(PHOTO_ADJUST_BACK, "", Vector2(-0.66, 0.19), Vector2(0.09, 0.065), true, "up")
		_button(CLOSE, "", Vector2(0.66, 0.19), Vector2(0.09, 0.065), true, "close")
		_label(I18n.t(Photo.Gallery.NAMES[int(_state.layout)]), Vector3(0, 0.19, 0.004), TEXT_PAGE_TITLE).font = ui_bold_font()
		_adjustment_row(450, "gallery_scale", "Image size", Vector3(Photo.Gallery.SCALE_LIMITS.x, Photo.Gallery.SCALE_LIMITS.y, 0.05), 0.02)
		_adjustment_row(451, "gallery_distance", "Distance", Vector3(Photo.Gallery.DISTANCE_LIMITS.x, Photo.Gallery.DISTANCE_LIMITS.y, 0.1), -0.125)
		_refresh_adjustments(); return
	var spatial: bool = _state.get("has_image", false) and not _state.get("loading", false) and _state.get("native_stereo", false) and _state.get("spatial_metadata", {}).has("horizontal_fov_degrees")
	_set_backdrop(Vector2(1.55, 0.74 if spatial else 0.64), Vector2(0, -0.05 if spatial else 0.0))
	_button(PHOTO_ADJUST_BACK, "", Vector2(-0.66, 0.25), Vector2(0.09, 0.065), true, "up")
	_button(CLOSE, "", Vector2(0.66, 0.25), Vector2(0.09, 0.065), true, "close")
	_label(I18n.t("Adjust image"), Vector3(0, 0.25, 0.004), TEXT_PAGE_TITLE).font = ui_bold_font()
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
	if _adjustment in ["comic_voice", "comic_translation"]: return
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

func _photo_background_button(target: int, caption: String, centre: Vector2, size: Vector2) -> void:
	var applied: bool = _state.get("photo_background_applied", false)
	var busy: bool = _state.get("photo_background_saving", false)
	_button(target, I18n.t("Background set" if applied else ("Saving…" if busy else caption)), centre, size,
		_state.get("can_background", false) and not applied and not busy, "check" if applied else "image")
	if applied: _buttons.back().base_color = SELECTED

func _draw_panel() -> void:
	_set_backdrop(Vector2(1.16, 0.71), Vector2(0, -0.08))
	_button(10, "", Vector2(-0.48, 0.2), Vector2(0.085, 0.065), true, "up")
	_label(I18n.t("Images"), Vector3(0, 0.2, 0.004), 21)
	_button(PHOTO_STRENGTH, I18n.t("3D depth") + "  " + _depth_caption(), Vector2(-0.26, 0.035), Vector2(0.49, 0.105), _can_depth(), "depth")
	var names := ["Off", "Slight", "Medium", "Full"]
	var curve := [0.0, 0.35, 0.7, 1.0].find(float(_state.get("screen_curve", 0)))
	_button(PHOTO_CURVE, I18n.t("Screen curve") + "  " + I18n.t(names[maxi(0, curve)]), Vector2(0.26, 0.035), Vector2(0.49, 0.105), int(_state.get("geometry", 0)) == 0 and not _state.get("portrait_requested",false), "screen")
	_photo_background_button(PHOTO_BACKGROUND, "Set photo background", Vector2(-0.26, -0.10), Vector2(0.49, 0.08))
	_button(PHOTO_GLOBAL_BACKGROUND, I18n.t("Set global background"), Vector2(0.26, -0.10), Vector2(0.49, 0.08), _state.get("can_background", false), "image")
	_button(PHOTO_COMIC, I18n.t("Comic reading (Beta)") + "  " + I18n.t("On" if _state.get("comic_enabled", false) else "Off"), Vector2(-0.26, -0.235), Vector2(0.49, 0.08), _state.get("comic_supported", false), "comic_voice")
	_button(PHOTO_COMIC_VOICE, I18n.t("Voice"), Vector2(0.26, -0.235), Vector2(0.49, 0.08), _state.get("comic_supported", false), "comic_voice")
	_status = _label(_photo_status(), Vector3(0, -0.35, 0.004), 15)
	_status.modulate = MUTED
	_place_device_status(Vector2(0, -0.48))

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
	if online.opened:
		online.scroll(amount,delta); return
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
var _comic_preview_drawn_busy := false

func _comic_preview_busy(value: Dictionary) -> bool:
	return value.get("comic_speech", "idle") in ["preparing", "speaking"]

func _draw_comic_settings() -> void:
	_comic_preview_drawn_busy = _comic_preview_busy(_state)
	var rows := ComicSettings.rows(_state)
	var custom: bool = _state.get("comic_voice_kind", "preset") == "custom"
	var has_voice_row: bool = rows.any(func(row): return row.field.key in ["comic_voice", "comic_custom_voice"])
	var count := rows.size() - 1 + (1 if custom else 0)
	var height := 0.24 + count * SUBTITLE_SETTING_PITCH
	var top := height / 2.0
	_set_backdrop(Vector2(1.08, height))
	_button(PHOTO_ADJUST_BACK, "", Vector2(-0.47, top - 0.06), Vector2(0.075, SUBTITLE_SETTING_HEIGHT), true, "up")
	_button(CLOSE, "", Vector2(0.47, top - 0.06), Vector2(0.075, SUBTITLE_SETTING_HEIGHT), true, "close")
	_label(I18n.t("Comic reading (Beta)"), Vector3(0, top - 0.06, 0.004), TEXT_PAGE_TITLE)
	# PlayerMenu already began this choice scope. Beginning a second scope here
	# resets the just-opened dropdown on every redraw (including pointer release).
	choices.bounds = Vector2(-top + 0.045, top - 0.105)
	var y := top - 0.16
	for row: Dictionary in rows:
		if row.field.key == "comic_language": continue
		var label := _label(I18n.t(row.title), Vector3(-0.48, y, 0.004), TEXT_BODY)
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		var voice_row: bool = row.field.key in ["comic_voice", "comic_custom_voice"]
		if row.field.key == "comic_enabled":
			row.field["switch"] = true; row.field.hint = "Comic reading (Beta)"
			choices.field(null, row.field, Vector2(-0.135, y), 0.09, SUBTITLE_SETTING_HEIGHT)
			if _state.get("translation_enabled", false):
				var target: String = {"zh-Hans": "简体中文", "zh-Hant": "繁體中文", "ja": "日本語", "en": "English"}.get(_state.get("translation_target", "zh-Hans"), "")
				_label(I18n.t("Translate to") + " · " + target, Vector3(0.21, y, 0.004), TEXT_BODY)
			else: choices.field(null, rows[1].field, Vector2(0.21, y), 0.50, SUBTITLE_SETTING_HEIGHT)
		else:
			choices.field(null, row.field, Vector2(0.09 if voice_row else 0.14, y), 0.54 if voice_row else 0.64, SUBTITLE_SETTING_HEIGHT)
			if voice_row: _draw_voice_preview(PHOTO_COMIC_PREVIEW, y, _comic_preview_busy(_state), _state.get("comic_supported", false) and (not custom or not str(_state.get("comic_custom_voice", "")).is_empty()))
		y -= SUBTITLE_SETTING_PITCH
		if custom and (voice_row or (not has_voice_row and row.field.key == "comic_voice_kind")):
			_button(PHOTO_COMIC_MANAGE, I18n.t("Manage my voices"), Vector2(0.14, y), Vector2(0.64, SUBTITLE_SETTING_HEIGHT))
			y -= SUBTITLE_SETTING_PITCH
	_status = _label(_fit_title(_photo_status(), "", 0.94, TEXT_AUX), Vector3(0, -top + 0.035, 0.004), TEXT_AUX)
	_status.modulate = MUTED
	choices.finish()

func _draw_translation_settings() -> void:
	var source_languages := [{"value": "zh-Hans", "label": "简体中文"}, {"value": "zh-Hant", "label": "繁體中文"},
		{"value": "ja", "label": "日本語"}, {"value": "en", "label": "English"}]
	var languages := preload("res://scripts/comic_translation_protocol.gd").target_choices()
	var sources := [{"value": "auto", "label": "From OCR"}] + source_languages
	var rows := [
		{"title": "Online translation", "field": {"key": "translation_enabled", "switch": true, "value": _state.get("translation_enabled", false), "choices": [{"value": false, "label": "Off"}, {"value": true, "label": "On"}]}},
		{"title": "Translate to", "field": {"key": "translation_target", "value": _state.get("translation_target", "zh-Hans"), "choices": languages}},
		{"title": "Source language", "field": {"key": "translation_source", "value": _state.get("translation_source", "auto"), "choices": sources}},
		{"title": "Text size", "field": {"key": "translation_size", "value": _state.get("translation_size", 1.0), "choices": [{"value": 0.85, "label": "Small"}, {"value": 1.0, "label": "Standard"}, {"value": 1.2, "label": "Large"}]}},
		{"title": "Translation style", "field": {"key": "translation_appearance", "value": _state.get("translation_appearance", "light"), "dropdown":true, "choices":[{"value":"light","label":"Black on white"},{"value":"dark","label":"White on black"}]}}]
	var height := 0.32 + rows.size() * SUBTITLE_SETTING_PITCH
	var top := height / 2.0
	_set_backdrop(Vector2(1.08, height))
	_button(PHOTO_ADJUST_BACK, "", Vector2(-0.47, top - 0.06), Vector2(0.075, SUBTITLE_SETTING_HEIGHT), true, "up")
	_button(CLOSE, "", Vector2(0.47, top - 0.06), Vector2(0.075, SUBTITLE_SETTING_HEIGHT), true, "close")
	_label(I18n.t("Comic translation (Beta)"), Vector3(0, top - 0.06, 0.004), TEXT_PAGE_TITLE)
	choices.bounds = Vector2(-top + 0.12, top - 0.105)
	var y := top - 0.16
	for row: Dictionary in rows:
		var label := _label(I18n.t(row.title), Vector3(-0.48, y, 0.004), TEXT_BODY)
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		var toggle: bool = row.field.get("switch", false)
		choices.field(null, row.field, Vector2(0.40 if toggle else 0.15, y), 0.09 if toggle else 0.64, SUBTITLE_SETTING_HEIGHT)
		y -= SUBTITLE_SETTING_PITCH
	_status = _label(_fit_title(_translation_status(), "", 0.78, TEXT_AUX), Vector3(-0.06, -top + 0.09, 0.004), TEXT_AUX)
	_status.modulate = MUTED
	_button(PHOTO_TRANSLATION_RETRY, "", Vector2(0.46, -top + 0.09), Vector2(0.065, 0.065), _state.get("translation_enabled", false), "restart")
	_tips[PHOTO_TRANSLATION_RETRY] = I18n.t("Retry translation")
	var notice := _label(I18n.t("Recognized text is sent to Microsoft"), Vector3(0, -top + 0.035, 0.004), TEXT_AUX)
	notice.modulate = MUTED
	choices.finish()

func _translation_status() -> String:
	if not _state.get("translation_enabled", false): return I18n.t("Off")
	var status: String = _state.get("translation_state", "waiting")
	var count := int(_state.get("translation_count", 0))
	var total := int(_state.get("translation_total", 0))
	if status == "translating": return I18n.t("Translating… %d/%d") % [count, total]
	if status == "error": return I18n.t("Translation unavailable · original shown")
	if status == "partial": return I18n.t("Translated %d/%d · retry available") % [count, total]
	if status == "ready": return I18n.t("Translated dialogues: %d") % count
	return I18n.t({"recognizing": "Reading page…", "no_dialogue": "No stable dialogue", "unsupported": "Flat images only", "unavailable": "Comic reading unavailable", "ready": "No translation needed"}.get(str(_state.get("comic_state", "")), "Reading page…"))

func _activate(target: int) -> void:
	if target == PHOTO_TRANSLATION: _adjustment = "comic_translation"; refresh(); return
	if target == PHOTO_TRANSLATION_RETRY: action_requested.emit("translation_retry"); return
	if target == PHOTO_COMIC: action_requested.emit("comic_toggle"); return
	if target == PHOTO_COMIC_VOICE: _adjustment = "comic_voice"; refresh(); return
	if target == PHOTO_COMIC_PREVIEW: action_requested.emit("comic_stop" if _comic_preview_busy(_state) else "comic_preview"); return
	if target == PHOTO_COMIC_MANAGE: action_requested.emit("comic_voices"); return
	if _adjustment in ["comic_voice", "comic_translation"] and target == PHOTO_ADJUST_BACK:
		choices.reset(); _adjustment = ""; refresh(); return
	if target == PHOTO_SCENERY_BACK:
		_scenery_open = false; refresh(); return
	if target == PHOTO_SCENERY_IMPORT:
		action_requested.emit("photo_scenery_import"); refresh(); return
	if target == PHOTO_SCENERY:
		_scenery_open = not _scenery_open
		_layout_open = false; _gallery_open = false; _mode_open = false; _wall_rows_open = false; _close_depth_slider()
		_magazine_order_open = false
		refresh(); return
	if target >= PHOTO_SCENERY_BASE and target < PHOTO_SCENERY_BASE + SCENERIES.size():
		action_requested.emit("photo_scenery_" + SCENERIES[target - PHOTO_SCENERY_BASE]); refresh(); return
	if target in [PHOTO_SCENERY_YAW, PHOTO_SCENERY_LIGHT]:
		action_requested.emit("photo_scenery_yaw" if target == PHOTO_SCENERY_YAW else "photo_scenery_brightness"); refresh(); return
	_scenery_open = false
	if _state.get("archive_mode", false) and (target in [PHOTO_GALLERY, PHOTO_SHUFFLE] or target in [PHOTO_LAYOUT_BASE + 1, PHOTO_LAYOUT_BASE + 2, PHOTO_LAYOUT_BASE + 3]): return
	if target == SPACE_LOCK or _adjustment == "bar_transparency": super._activate(target); return
	if target==PHOTO_STATIC:
		action_requested.emit("photo_static"); refresh()
		return
	if target==PHOTO_SPATIAL:
		var operation:="photo_spatial_on" if _depth_open else "photo_spatial"
		_mode_open=false; action_requested.emit(operation); refresh(); return
	if target==PHOTO_ONLINE: action_requested.emit("online_panoramas"); return
	if online.activate(target): return
	if target==PHOTO_SAVE: action_requested.emit("save_pictures"); refresh_values(); return
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
	if target in [PHOTO_MAGAZINE_ORDER, PHOTO_MAGAZINE_ORDER + 1]:
		_layout_open = false; _magazine_order_open = false
		action_requested.emit("photo_magazine_ltr" if target == PHOTO_MAGAZINE_ORDER else "photo_magazine_rtl")
		refresh(); return
	if target >= PHOTO_LAYOUT_BASE and target < PHOTO_LAYOUT_BASE + 5:
		_magazine_order_open = target == PHOTO_LAYOUT_BASE + 4
		if _magazine_order_open:
			_wall_rows_open = false; refresh(); return
		if target == PHOTO_LAYOUT_BASE + 2:
			_wall_rows_open = true; refresh(); return
		_layout_open = false
		_wall_rows_open = false
		action_requested.emit("photo_layout_%d" % (target - PHOTO_LAYOUT_BASE))
		refresh(); return
	if target == PHOTO_LAYOUT:
		_magazine_order_open = false
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
		PHOTO_GLOBAL_BACKGROUND: action_requested.emit("global_background")
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

func _fitted_photo_status() -> String:
	if _adjustment == "comic_translation": return _fit_title(_translation_status(), "", 0.78, TEXT_AUX)
	if _adjustment == "comic_voice": return _fit_title(_photo_status(), "", 0.94, TEXT_AUX)
	if section == 0 and _adjustment.is_empty() and not _scenery_open: return _fit_title(_photo_status(), "", 0.76, 15)
	return _photo_status()

func _photo_status() -> String:
	if _adjustment == "comic_translation" or (_adjustment != "comic_voice" and _state.get("translation_enabled", false)):
		return _translation_status()
	if _adjustment == "comic_voice" or _state.get("comic_enabled", false):
		if _state.get("comic_speech") == "preparing": return I18n.t("Preparing speech…")
		if _state.get("comic_speech") == "speaking": return I18n.t("Reading dialogue…")
		if _state.get("comic_speech") == "error": return I18n.t("Unable to read dialogue")
	if _scenery_open or section == 1:
		if _state.get("photo_background_loading", false): return I18n.t("Loading…")
		if not str(_state.get("photo_background_error", "")).is_empty(): return I18n.t(str(_state.photo_background_error))
		if _scenery_open: return ""
	if _state.get("comic_enabled", false):
		if _state.get("comic_state") == "ready" and int(_state.get("comic_ready_audio", 0)) == 0: return I18n.t("Preparing speech…")
		if _state.get("comic_state") == "ready": return I18n.t("Readable dialogues: %d") % int(_state.get("comic_readable", 0))
		if _state.get("comic_state") == "no_dialogue" and int(_state.get("comic_candidates", 0)) > 0: return I18n.t("Dialogue needs verification")
		var comic_caption: String = {"recognizing": "Reading page…", "ready": "Point to read", "unavailable": "Comic reading unavailable", "unsupported": "Flat images only", "no_dialogue": "No stable dialogue", "speech_error": "Unable to read dialogue"}.get(str(_state.get("comic_state", "")), "")
		if not comic_caption.is_empty(): return I18n.t(comic_caption)
	if not str(_state.get("spatial_error","")).is_empty(): return I18n.t(str(_state.spatial_error))
	if _state.get("spatial_requested",false): return I18n.t("Spatial view" if _state.get("spatial_ready",false) else "Preparing spatial view")
	if not _favorite_notice.is_empty(): return I18n.t(_favorite_notice)
	var saved: Dictionary=_state.get("pictures_save",{})
	if saved.get("state")=="saving": return I18n.t("Saving original image")
	if saved.get("state")=="error": return I18n.t("Could not save image")
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
	if not str(_state.get("panorama_detail_error", "")).is_empty(): return I18n.t(str(_state.panorama_detail_error))
	if _state.get("native_stereo",false): return I18n.t("Static 3D")
	if _state.get("depth_requested", false): return I18n.t("3D on" if _state.get("depth_enabled", false) else "Preparing 3D")
	return str(_state.get("source_size", ""))

func _update_highlights() -> void:
	if _tips.has(PHOTO_INSPECT): _tips[PHOTO_INSPECT] = _inspect_tip()
	super._update_highlights()
	for button in _buttons:
		if (button.target == PHOTO_INSPECT and _state.get("inspect", false)) or (button.target == PHOTO_DEPTH and (_state.get("depth_requested", false) or _state.get("native_stereo",false))):
			button.node.material_override.set_shader_parameter("surface_color", SELECTED)
		if button.target == PHOTO_PORTRAIT and button.enabled and _state.get("portrait_requested",false) and not _hover.values().has(button.target):
			button.node.material_override.set_shader_parameter("surface_color", Color(0.16, 0.31, 0.27))
