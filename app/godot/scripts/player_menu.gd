extends "res://scripts/ray_menu.gd"

signal action_requested(operation: String)
signal favorite_requested
var favorite_provider: Callable
var _favorite_notice := ""
var _favorite_notice_until := 0
const FAVORITE := 980
const MUSIC_OPEN := 981
const CAPTURE := 982
const CAPTURE_PICTURE := 983
const CAPTURE_RECORD := 984
const PIP := 998000
const PIP_COUNT := 998010
const PipControls := preload("res://scripts/video_pip_controls.gd")
const PIP_ADD := PipControls.ADD
const PIP_CLOSE := PipControls.CLOSE
var _pip_open := false
var pip_controls := PipControls.new(self)
const DiscPanel := preload("res://scripts/disc_titles_panel.gd")
var disc_titles := DiscPanel.new(self)
var _capture_open := false
var _capture_hover_ms := 0
var _capture_leave_ms := 0
var _capture_time: Label3D
signal recent_requested
signal seek_requested(position_ms: int)
signal cast_requested(action: String)
var cast_state := {}
const CastPanel := preload("res://scripts/cast_panel.gd")
const CastCapabilities := preload("res://scripts/cast_capabilities.gd")

func _cast_allowed(operation: String) -> bool:
	return not _state.has("cast") or CastCapabilities.allows(_state.cast, operation)
signal bookmark_requested(operation: String, marker_id: String, scope: String)
signal bookmark_loop_requested(operation: String, payload: Dictionary, scope: String)
signal bookmark_mode_requested(mode: String, scope: String)
signal volume_requested(volume: float, muted: bool)
signal whisper_requested(level: int, source_uri: String)
signal whisper_haptic(hand: String)
signal subtitle_requested(track_id: int)
signal subtitle_files_requested
signal subtitle_file_requested(filename: String)
signal subtitle_browse_requested
signal depth_strength_requested(strength: float)
signal adjustment_requested(key: String, value: Variant)
signal adjustment_committed
signal depth_strength_committed

const SEEK := 200
const BookmarkMenu := preload("res://scripts/bookmark_menu.gd")
var bookmarks := BookmarkMenu.new(self)
const ChoiceFields := preload("res://scripts/choice_fields.gd")
const SubtitleDepth := preload("res://scripts/subtitle_depth.gd")
const SubtitleStyle := preload("res://scripts/subtitle_style.gd")
const SubtitleTiming := preload("res://scripts/file_subtitle_timing.gd")
const NarrationSettings := preload("res://scripts/narration_settings.gd")
const Listening := preload("res://scripts/live_interpretation.gd")
const AUDIO_CLOSE := 520
const AUDIO_UP := 521
const AUDIO_DOWN := 522
const AUDIO_ROW := 23000
const NARRATION_RETRY := 525
const NARRATION_PREVIEW := 526
const NARRATION_CLONE_START := 527
const NARRATION_VOICES := 528
const SUBTITLE_GENERATE := 529
const SUBTITLE_TASK_CANCEL := 530
const SUBTITLE_TASKS := 531
const ClonePanel := preload("res://scripts/narration_clone_panel.gd")
var clone_panel := ClonePanel.new(self)
const AudioTiming := preload("res://scripts/file_audio_timing.gd")
var _audio_open := false
var _audio_offset := 0
var _audio_ids := {}
var _track_drag := {}
var _narration_busy: MeshInstance3D
var _listening_status: Label3D
var _audio_source := ""
var choices := ChoiceFields.new(self)
signal setting_requested(key: String, value: Variant)
const MODE := 120
const SELECTED := Color(0.16, 0.31, 0.27)
const MODE_PROJECTION := 130
const MODE_STEREO := 140
const MODE_LENS := 150
## Fisheye: the video's own Alpha mask, after the lens angles.
const MODE_PACKED := 158
const VOLUME := 160
## Volume slider over the sound icon: track span (bottom, top) and its x; the lowest steps mute.
const VOLUME_X := -0.5
const VOLUME_SPAN := Vector2(0.1, 0.34)
const VOLUME_MUTE := 3
const WHISPER := 163
const BOOST_HEIGHT := 0.14
const DepthStrength := preload("res://scripts/depth_strength.gd")
const DEPTH := 161
const DEPTH_RESET := 162
const DEPTH_X := 0.32
const DEPTH_SPAN := Vector2(0.2, 0.44)
const LENS_FOVS := [180, 190, 200, 220]
## Timeline width: the slim bar while watching, the full width in the expanded panel.
const BAR_SEEK := 0.82
const SUBTITLE_ROW := 300
const SUBTITLE_UP := 290
const SUBTITLE_DOWN := 291
const SUBTITLE_ROWS := 3
const SUBTITLE_SETTING_PITCH := 0.082
const SUBTITLE_SETTING_HEIGHT := 0.062
const SUBTITLE_POSITION := 292
const SUBTITLE_APPEARANCE := 293
const SUBTITLE_CLOSE := 294
const SUBTITLE_AUTO := 295
const SUBTITLE_FILES := 296
const SUBTITLE_FILES_UP := 297
const SUBTITLE_FILES_DOWN := 298
const SUBTITLE_FILES_RETRY := 299
const SUBTITLE_BROWSE := 289
const SUBTITLE_LISTENING := 22300
const SUBTITLE_NARRATION := 22301
const SUBTITLE_DETAIL_CLOSE := 22302
const SUBTITLE_MAIN_WIDTH := 0.44
const SUBTITLE_DETAIL_WIDTH := 1.10 - SUBTITLE_MAIN_WIDTH
const SUBTITLE_DETAIL_X := (SUBTITLE_MAIN_WIDTH + SUBTITLE_DETAIL_WIDTH) / 2
const SUBTITLE_MAIN_PITCH := 0.067
const SUBTITLE_ENTRY_PITCH := 0.072
const HEADING_SWITCHES := ["listening_enabled", "narration_enabled"]
const SUBTITLE_FILE_ROW := 22000
const PLAYBACK_SETTINGS := 470
const ROTATION_RESET := 471
const SPEED_RESET := 472
const SLIDER_RESET_BASE := 6000
const GRADE_PAGE_RESET := 441
const StereoView := preload("res://scripts/stereo_view.gd")
const VIEWING_EYE := 480
const EYE_SWAP := 483
const ALIGNMENT_RESET := 484
const ALIGNMENT_HORIZONTAL := 485
const ALIGNMENT_VERTICAL := 486
const VR_HORIZONTAL := 610
const VR_VERTICAL := 611
const VR_ZOOM := 612
const VR_RESET := 613
const SPATIAL_DISPARITY := 487
const SPATIAL_FOV := 488
## Settings is a popup above the bar like subtitles: its own tab, tile and close targets keep the
## bar's controls (100+) usable while it is open.
const SCREEN_SETTINGS := 473
const CINEMA_SEAT := 9101
const CINEMA_MOVE := 9102
const CINEMA_HOME := 9103
const CINEMA_LIGHT_AUTO := 9104
const CINEMA_LIGHT_ON := 9105
const CINEMA_LIGHT_OFF := 9106
const CINEMA_LIGHT_CYCLE := 9107
const CINEMA_PICTURE_SIZE := 9108
const SETTINGS_CLOSE := 474
const SCREEN_SET_DEFAULT := 475
const SCREEN_AUTO_DEFAULT := 478
const SCREEN_CINEMA := 476
const SCREEN_CINEMA_OFF := 477
const SCREEN_PRESET := 490
const SCREEN_EYE_LEVEL := 530
const SCREEN_CURVE := 540
const EYE_LEVELS := [1.0 / 3.0, 0.5]
const ScreenPresets := preload("res://scripts/screen_presets.gd")
var _screen_measurement: Label3D
const ERROR_DETAILS := 496
const ERROR_OPEN := 499
const PlaybackErrors := preload("res://scripts/playback_errors.gd")
var _failure_open := false
var _error_details_open := false
var _error_identity := ""
const SETTINGS_TILE := 560
const ALPHA_GROUP := 458
const PORTRAIT_SIZE := 459
## The three Alpha sliders fold under one header, as in the library's video settings; closed each time.
var _alpha_expanded := false
const EYE_BUFFER_NOTE := 7000
const POPUP_WIDTH := 1.10
const POPUP_BOTTOM := 0.285
const WARNING := Color(0.86, 0.74, 0.42, 0.9)
## Grade sliders the compositor layer cannot apply: they move playback to the eye buffers.
const EYE_BUFFER_GRADES := ["gamma", "saturation", "red_gamma", "green_gamma", "blue_gamma"]

## The bar already carries video mode, recenter, volume and subtitles, and Alpha resolution
## lives in the library's Settings: this panel keeps only what neither has.
const TABS := ["Playback", "Settings", "Info"]
const OPERATIONS := [
	["recent", "previous_video", "play", "next_video", "alpha", "projection", "stereo", "stop", "recenter", "mute", "subtitles",
		"audio", "depth"],
	["color_grade", "loop", "seek_mode", "stereo_view"],
	["capabilities"]]
const HEADINGS := ["Color grading", "Playback mode", "Video time positioning", "Stereo viewing"]
const SETTING_ICONS := ["light", "loop", "history", "eyes"]
const Surface := preload("res://scripts/media_surface.gd")
const SeekFeedback := preload("res://scripts/seek_feedback.gd")
## Flat screen curve steps (the video's CURVES) and their names.
const CURVE_NAMES := ["Off", "Slight", "Medium", "Full"]

const Grade := preload("res://scripts/color_grade.gd")
var _adjustment := ""
const SPACE_LOCK := 987101
const BAR_TRANSPARENCY := 987102
const BAR_DONE := 987103
## Wrist watch on/off, beside the lock. Always shown: following the hand-tracking state made it
## flicker and swallowed taps when the bar redrew under the finger.
const WATCH := 987104
var bar_transparency := 14.0

func set_bar_transparency(value: float) -> void:
	bar_transparency = clampf(value, 0, 80) if is_finite(value) else 14.0
	_state["bar_transparency"] = bar_transparency
	if is_instance_valid(_backdrop) and _backdrop.get_meta("control_bar", false):
		_backdrop.material_override.set_shader_parameter("surface_color", Color(PANEL, 1.0 - bar_transparency / 100.0))
	if _adjustment == "bar_transparency": _refresh_adjustments()
	composition_changed.emit()

func _style_control_bar() -> void:
	# A translucent plate belongs in the eye buffer. Capturing it in an underlay
	# and using its alpha again for the projection hole would attenuate it twice.
	# Buttons, labels and popups retain their independent high-resolution captures.
	_backdrop.set_meta("control_bar", true)
	_backdrop.set_meta("menu_eye_buffer", true)
	# Before the compositor coverage pass, so the plate cannot refill
	# glyph holes and dim the high-resolution labels beneath the projection layer.
	_backdrop.material_override.render_priority = 4
	_backdrop.material_override.set_shader_parameter("keep_opacity", true)
	_backdrop.material_override.set_shader_parameter("surface_color", Color(PANEL, 1.0 - bar_transparency / 100.0))
	_glyph(SPACE_LOCK, "lock" if space_locked() else "unlock", Vector2(0.535, 0.10), 0.065, true,
		I18n.t("Unlock spatial position" if space_locked() else "Lock spatial position"))
	_buttons.back().foreground = Color(0.75, 0.78, 0.80) if space_locked() else MUTED
	if _state.get("watch_available", false):
		var watch_on: bool = _state.get("watch_enabled", true)
		_glyph(WATCH, "watch" if watch_on else "watch_off", Vector2(0.465, 0.10), 0.06, true,
			I18n.t("Show a watch on the left wrist in hand tracking") + ": " + I18n.t("On" if watch_on else "Off"))
		_buttons.back().foreground = Color(0.75, 0.78, 0.80) if watch_on else MUTED

func show_bar_appearance() -> void:
	_reset_navigation()
	_adjustment = "bar_transparency"
	visible = true
	refresh()
var _seek_hand := ""
var _seek_start := -1
var _seek_preview := -1
var _grade_page := 0
var _adjust_hand := ""
var _adjust_target := -1
var _adjust_rows := {}
var _preset_buttons := {}
var state_provider: Callable
## 0: the bar alone; 1 and 2: the settings popup (Playback/Screen, Info) above the bar.
var section := 0
var _state: Dictionary = {}
var _status: Label3D
var _panel_status: Label3D
var _info: Label3D
var _refresh_ms := 0
var _title: Label3D
var _elapsed: Label3D
var _duration: Label3D
var _progress: MeshInstance3D
var _thumb: MeshInstance3D
var _seek_origin: MeshInstance3D
var _modes: Dictionary = {} # bar button target -> its mode caption
var _mode_open := false
var _bar_drawn := "" # what decides the bar's buttons (clone voice, projection) when it was drawn
var _settings_drawn := ""
var _lit_modes: Dictionary = {} # video mode tiles lit as current; pressing one again locks the mode
var _volume_open := false
var _volume_hand := "" # the hand dragging the volume slider
var _volume_sent := -1 # last level sent during this press (0 = muted)
var _volume_source := ""
var _volume_breakthrough := false
var _volume_fill: MeshInstance3D
var _volume_knob: MeshInstance3D
var _volume_label: Label3D
var _boost_fill: MeshInstance3D
var _boost_mark: MeshInstance3D
var _depth_open := false
var _depth_hand := ""
var _depth_sent := -1
var _depth_fill: MeshInstance3D
var _depth_knob: MeshInstance3D
var _depth_label: Label3D
const ICON_DOUBLE_CLICK_MS := 350
const MUTE_INK := Color(1.0, 0.45, 0.4)
const MUTE_TINT := Color(0.42, 0.1, 0.1, 0.9)
var _icon_tap := {}
## Comet arc around the bar's 3D icon while depth is requested but not yet running (cold model compile).
var _depth_busy: MeshInstance3D
static var _busy_shader: Shader
var _subtitle_open := false
var _subtitle_detail := ""
## Older callers address the appearance column by its former disclosure flag.
var _subtitle_appearance_open: bool:
	get: return _subtitle_detail == "appearance"
	set(value):
		if value: _subtitle_detail = "appearance"
		elif _subtitle_detail == "appearance": _subtitle_detail = ""
var _subtitle_main_bounds := Rect2()
var _subtitle_panel_bounds := Rect2()
var _subtitle_status_label: Label3D
var _subtitle_group_states := {}
var _subtitle_offset := 0
var _subtitle_scroll := 0.0
var _subtitle_source := ""
var _subtitle_ids: Dictionary = {}
var _subtitle_files_open := false
var _subtitle_files_offset := 0
var _subtitle_file_ids: Dictionary = {}
var expanded_library: Node3D
var _popup_surfaces: Array[Node3D] = []
var _popup_layout_key := ""
var _transport_bounds := Rect2()
const CinemaMenuLayout := preload("res://scripts/environments/cinema_menu_layout.gd")
const CinemaFeature := preload("res://scripts/environments/cinema_feature.gd")
var cinema_world_anchor := false
var _cinema_popup_centres: Dictionary = {}

func set_cinema_world_anchor(enabled: bool) -> void:
	if cinema_world_anchor == enabled: return
	cinema_world_anchor = enabled
	_cinema_popup_centres.clear()
	_popup_layout_key = ""
	if visible: refresh()

func panel_centre() -> Vector3:
	return Vector3(0, -0.025, 0) if _settings_popup() else super()

func _clear_layout() -> void:
	# The tooltip outlives page geometry, even when it was attached to a popup.
	if is_instance_valid(_tooltip) and _tooltip.get_parent() != self: _tooltip.reparent(self, false)
	super()
	for surface in _popup_surfaces: surface.free()
	_popup_surfaces.clear()
	_transport_bounds = Rect2()

## Keep logical control coordinates intact inside an independently oriented surface.
func _draw_popup(draw: Callable) -> void:
	var before := get_children()
	draw.call()
	if (_layout_eye == null and not cinema_world_anchor) or not _settings_popup(): return
	var key := str([draw.get_method(), section, _adjustment])
	if draw.get_method() == "_draw_subtitles" and not clone_panel.opened:
		key += str(_subtitle_panel_bounds.size)
	var changed := key != _popup_layout_key
	_popup_layout_key = key
	if changed: _cinema_popup_centres.clear()
	var surface := Node3D.new()
	add_child(surface)
	for child in get_children():
		if child != surface and child is Node3D and not before.has(child): child.reparent(surface, false)
	if surface.get_child_count() == 0: surface.free(); return
	_popup_surfaces.append(surface)
	surface.set_meta("cinema_popup_key", key)
	if draw.get_method() == "_draw_subtitles" and not clone_panel.opened:
		surface.set_meta("subtitle_anchor_bounds", _subtitle_panel_bounds)
	# Establish the new hierarchy before measuring the bar: new popup nodes are not bar controls.
	if changed: refresh_layout_reference()
	arrange_surfaces()

func _bar_bounds() -> Rect2:
	if _transport_bounds.has_area(): return _transport_bounds
	var nodes: Array = [_backdrop]
	for button in _buttons:
		if button.node.get_parent() == self: nodes.append(button.node)
	for node in _labels + _decorations:
		if node.get_parent() == self: nodes.append(node)
	_transport_bounds = SurfaceLayout.bounds(nodes, self)
	return _transport_bounds

func arrange_surfaces() -> void:
	if _layout_eye == null and not cinema_world_anchor: return
	for surface in _popup_surfaces:
		# Bounds are measured in the unchanged logical coordinate system.
		var rect: Rect2 = surface.get_meta("menu_surface_bounds") if surface.has_meta("menu_surface_bounds") else SurfaceLayout.bounds(surface.get_children(), surface)
		_place_upper_surface(surface, rect)
	if is_instance_valid(expanded_library) and expanded_library.visible and expanded_library.get_parent() == self:
		arrange_library(expanded_library)

func _place_upper_surface(surface: Node3D, rect: Rect2) -> void:
	if rect.size.y <= 0: return
	# Use the whole subtitle plate, excluding raised dropdowns, for centering.
	var anchor_rect: Rect2 = surface.get_meta("subtitle_anchor_bounds", rect)
	if cinema_world_anchor:
		var key := str(surface.get_meta("cinema_popup_key", "library"))
		if not _cinema_popup_centres.has(key):
			var head: Variant = layout_head_provider.call() if layout_head_provider.is_valid() else null
			if space_locked(): head = get_meta("space_head", head)
			if not head is Transform3D: return
			var eye: Vector3 = to_global(_layout_eye) if _layout_eye != null else head.origin
			# Volume and 3D strength sliders keep their own layout, directly above their
			# buttons exactly as outside the cinema; only their surface is separate.
			if "_draw_volume" in key or "_draw_depth" in key:
				_cinema_popup_centres[key] = Transform3D.IDENTITY
			else:
				_cinema_popup_centres[key] = global_transform.affine_inverse() * SurfaceLayout.above(global_transform, eye, panel_centre(), _bar_bounds().end.y, anchor_rect, global_basis * _layout_up)
		# Freeze the layout relative to the bar so unlocked grip movement carries
		# settings/library surfaces with it, including after a redraw.
		surface.transform = _cinema_popup_centres[key]
		surface.set_meta("menu_surface_bounds", rect)
		composition_layout_changed.emit()
		return
	var world := SurfaceLayout.above(global_transform, to_global(_layout_eye), panel_centre(), _bar_bounds().end.y, anchor_rect, global_basis * _layout_up)
	surface.global_transform = world
	surface.set_meta("menu_surface_bounds", rect)
	composition_layout_changed.emit()

func arrange_library(library: Node3D, measured: Variant = null) -> bool:
	if _layout_eye == null and not cinema_world_anchor: return false
	var rect: Rect2 = measured if measured is Rect2 else (library.get_meta("menu_surface_bounds") if library.has_meta("menu_surface_bounds") else library.panel_bounds())
	_place_upper_surface(library, rect)
	return true

func _input_surface(target: int) -> Node3D:
	for button in _buttons:
		if button.target != target: continue
		var node: Node = button.node.get_parent()
		while node != self and node is Node3D:
			if _popup_surfaces.has(node): return node
			node = node.get_parent()
	return self

func _input_point(hit: Dictionary) -> Vector3:
	return _input_surface(int(hit.target)).to_local(to_global(hit.point))

func has_expanded_library() -> bool:
	return is_instance_valid(expanded_library) and expanded_library.get_parent() == self and expanded_library.visible and visible

func _controls_pointer_capture() -> bool:
	return not choices.capture.is_empty() or not bookmarks.capture.is_empty() or not _seek_hand.is_empty() or not _volume_hand.is_empty() \
		or not _depth_hand.is_empty() or not _adjust_hand.is_empty() or not _track_drag.is_empty()

func ray_hit(origin: Vector3, direction: Vector3) -> Dictionary:
	var hit := super(origin, direction)
	if has_expanded_library():
		var browser_hit: Dictionary = expanded_library.ray_hit(origin, direction)
		if not browser_hit.is_empty() and (hit.is_empty() or float(browser_hit.distance) < float(hit.distance)):
			return {"target": NONE, "point": to_local(expanded_library.to_global(browser_hit.point)), "distance": browser_hit.distance, "enabled": false, "library": true}
	return hit

func grab_hit(origin: Vector3, direction: Vector3) -> Dictionary:
	var hit := super(origin, direction)
	if has_expanded_library():
		var browser_hit: Dictionary = expanded_library.grab_hit(origin, direction)
		if not browser_hit.is_empty() and (hit.is_empty() or float(browser_hit.distance) < float(hit.distance)):
			return {"target": NONE, "point": to_local(expanded_library.to_global(browser_hit.point)), "distance": browser_hit.distance, "enabled": false, "library": true}
	return hit

func _pointer_hit_over(origin: Vector3, direction: Vector3, button_hit: Dictionary) -> Dictionary:
	var hit := super(origin, direction, button_hit)
	if has_expanded_library():
		var browser_hit: Dictionary = expanded_library.pointer_hit(origin, direction)
		if not browser_hit.is_empty() and (hit.is_empty() or float(browser_hit.distance) < float(hit.distance)):
			return {"target": NONE, "point": to_local(expanded_library.to_global(browser_hit.point)), "distance": browser_hit.distance, "enabled": false, "library": true}
	return hit

func has_pointer_capture() -> bool:
	return _controls_pointer_capture() or (has_expanded_library() and expanded_library.has_pointer_capture())

## The transport bar has no list navigation; popups and settings keep their own input.
func allows_playback_sticks() -> bool:
	return not _pip_open and allows_pip_input()

## The small PiP picker blocks playback shortcuts, but not rays outside its buttons.
func allows_pip_input() -> bool:
	return visible and section == 0 and _state.get("has_video", false) and _adjustment.is_empty() \
		and choices.opened.is_empty() and not _audio_open and not disc_titles.opened and not _mode_open and not _subtitle_open and not bookmarks.opened and not _failure_open and not has_pointer_capture() and not has_expanded_library()

func _finish_depth_drag() -> void:
	if not _depth_hand.is_empty():
		_depth_hand = ""
		depth_strength_committed.emit()

func _close_depth_slider() -> void:
	_finish_depth_drag()
	_depth_open = false

## Pop controls above the transport before the owning app hides the transport itself.
func navigate_back() -> bool:
	if _controls_pointer_capture():
		for hand in ["left_hand", "right_hand"]: cancel_pointer(hand)
	elif clone_panel.opened:
		if not choices.opened.is_empty(): choices.reset(); refresh()
		else: clone_panel.back()
	elif not choices.opened.is_empty():
		choices.reset(); refresh()
	elif _audio_open:
		_audio_open = false; refresh()
	elif disc_titles.opened:
		disc_titles.reset(); refresh()
	elif bookmarks.opened:
		bookmarks.reset(); refresh()
	elif not _adjustment.is_empty():
		_finish_adjustment(); _adjustment = ""; refresh()
	elif _subtitle_open and not _subtitle_detail_group().is_empty():
		_set_subtitle_detail(""); refresh()
	elif _subtitle_open and _subtitle_files_open:
		_subtitle_files_open = false; refresh()
	elif _subtitle_open:
		_subtitle_open = false; refresh()
	elif _mode_open:
		_mode_open = false; refresh()
	elif _volume_open:
		_volume_open = false; refresh()
	elif _depth_open:
		_close_depth_slider(); refresh()
	elif _error_details_open:
		_error_details_open = false; refresh()
	elif _failure_open:
		_failure_open = false; refresh()
	elif section != 0:
		_reset_navigation(); refresh()
	else:
		return false
	return true

func dismiss() -> void:
	if clone_panel.opened: clone_panel.close()
	_failure_open = false
	_error_details_open = false
	if has_expanded_library(): expanded_library.dismiss()
	_icon_tap.clear()
	_track_drag.clear()
	choices.reset()
	bookmarks.reset()
	_seek_hand = ""
	_seek_preview = -1
	_finish_adjustment()
	_adjustment = ""
	_alpha_expanded = false
	_subtitle_open = false
	_subtitle_detail = ""
	_subtitle_files_open = false
	disc_titles.reset()
	_close_depth_slider()
	_volume_hand = ""
	super.dismiss()

func _reset_navigation() -> void:
	_pip_open = false
	_audio_open = false; _audio_offset = 0
	disc_titles.reset()
	_failure_open = false
	_error_details_open = false
	_icon_tap.clear()
	choices.reset()
	bookmarks.reset()
	_seek_hand = ""
	_seek_preview = -1
	_finish_adjustment()
	_adjustment = ""
	_alpha_expanded = false
	_subtitle_open = false
	_subtitle_detail = ""
	_subtitle_files_open = false
	_subtitle_offset = 0
	_subtitle_scroll = 0.0
	section = 0
	_mode_open = false
	_volume_open = false
	_volume_hand = ""
	_close_depth_slider()

func refresh() -> void:
	_state = state_provider.call() if state_provider.is_valid() else {}
	_state["bar_transparency"] = bar_transparency
	_draw()

func show_playback_error() -> void:
	visible = true
	_reset_navigation()
	if has_expanded_library(): expanded_library.dismiss()
	_failure_open = true
	refresh()

func refresh_values() -> void:
	composition_changed.emit()
	if not visible:
		return
	_state = state_provider.call() if state_provider.is_valid() else {}
	_state["bar_transparency"] = bar_transparency
	if _adjustment in ["screen", "stereo_view"] and _settings_drawn != _settings_key():
		_finish_adjustment()
		if _adjustment == "stereo_view" and not _enabled("stereo_view"): _adjustment = ""
		refresh()
		return
	# The bar stays under the settings popup: it redraws when its own buttons change.
	if _bar_drawn != _bar_key() and _adjust_hand.is_empty():
		refresh()
		return
	if (section in [1, 2] or _failure_open) and _adjustment.is_empty() and _settings_drawn != _settings_key():
		refresh()
		return
	for button in _buttons:
		if button.target in [SCREEN_SET_DEFAULT, SCREEN_AUTO_DEFAULT]:
			button.base_color = SELECTED if (button.target == SCREEN_SET_DEFAULT) == bool(_state.get("screen_default_locked", false)) else TILE
		if section == 1 and button.target in [SETTINGS_TILE + OPERATIONS[1].find("seek_mode"), SETTINGS_TILE + OPERATIONS[1].find("loop")]: continue
		if button.target == BookmarkMenu.ADD:
			button.enabled = _state.get("bookmark_ready", false) and _seek_hand.is_empty()
			button.node.get_child(1).material_override.albedo_color = button.foreground if button.enabled else MUTED
			continue
		if bookmarks.targets.get(button.target, {}).get("kind", "") == "group":
			# The picker validates each endpoint/group when drawing; retain that result.
			if bookmarks.picker.is_empty(): button.enabled = _state.get("bookmark_seekable", false)
			continue
		if button.target == SEEK:
			button.enabled = _can_seek()
			continue
		var bar := _bar_target(button.target)
		var tile: bool = section != 0 and _adjustment.is_empty() and button.target >= SETTINGS_TILE and button.target < SETTINGS_TILE + OPERATIONS[section].size()
		if not bar and not tile:
			continue
		var operation: String = OPERATIONS[0][button.target - 100] if bar else OPERATIONS[section][button.target - SETTINGS_TILE]
		button.enabled = _enabled(operation)
		var label: Label3D = button.node.get_child(0)
		label.text = "" if bar else _caption(operation)
		if _modes.has(button.target):
			_modes[button.target].text = _caption(operation)
		label.modulate = button.foreground if button.enabled else MUTED * Color(0.7, 0.7, 0.7)
		if bar and button.target in [104, 110, 112]:
			button.node.get_child(1).material_override.albedo_color = button.foreground if button.enabled else MUTED
		if bar and button.target == 102:
			button.node.get_child(1).material_override.albedo_texture = Icons.texture("pause" if _pausable() else "play")
			_tips[102] = I18n.t("Pause" if _pausable() else "Play")
		if bar and button.target == 109:
			button.node.get_child(1).material_override.albedo_texture = Icons.texture(_sound_icon())
			_style_sound(button)
			_tips[109] = _volume_tip()
		if bar and button.target == 112: _tips[112] = _depth_tip()
	if is_instance_valid(_status):
		_status.text = _seek_status()
		_status.visible = not _status.text.is_empty()
		_status.modulate.a = 1.0 if _listening_preparing() else float(_state.get("seek_feedback", {}).get("alpha", 1.0))
	if is_instance_valid(_panel_status):
		_panel_status.text = _status_text()
	if is_instance_valid(_info):
		_info.text = _info_text()
	if is_instance_valid(_title):
		if _title.has_meta("filename_width"):
			var caption := _fit_title(str(_state.get("title", "")), "", float(_title.get_meta("filename_width")), 15)
			if caption != _title.text:
				_title.text = caption
				_back_filename(_title, float(_title.get_meta("filename_width")))
				composition_layout_changed.emit()
		else:
			_title.text = _fit_title(str(_state.get("title", "")) if _state.get("has_video", false) else I18n.t("Your player"), "", 1.14, 23)
	_refresh_progress()
	_refresh_volume()
	_refresh_depth()
	_refresh_adjustments()
	_update_highlights()

func _process(_delta: float) -> void:
	_process_capture_hover()
	if _favorite_notice_until > 0 and Time.get_ticks_msec() >= _favorite_notice_until and not has_pointer_capture():
		_favorite_notice = ""; _favorite_notice_until = 0
		if visible: refresh()
	if visible and Time.get_ticks_msec() >= _refresh_ms:
		_refresh_ms = Time.get_ticks_msec() + 250
		refresh_values()

func _draw() -> void:
	if _volume_source != str(_state.get("source_uri", "")):
		_volume_hand = ""; _volume_breakthrough = false
	_volume_source = str(_state.get("source_uri", ""))
	if not _track_drag.is_empty() and _track_drag.source != str(_state.get("source_uri", "")): _track_drag.clear()
	if _audio_open and (_audio_source != str(_state.get("source_uri", "")) or section != 0 or _subtitle_open or _mode_open or _volume_open):
		_audio_open = false; choices.reset()
	if disc_titles.opened and (section != 0 or _audio_open or _subtitle_open or _mode_open or _volume_open or _pip_open or bookmarks.opened):
		disc_titles.reset()
	_clear_layout()
	if str(_state.get("error", "")).is_empty():
		_failure_open = false; _error_details_open = false
	choices.begin(str([section, _state.get("source_uri", ""), _state.get("bookmark_scope", ""), _state.get("subtitle_timing_key", ""), _state.get("narration_source", -1), _state.get("narration_resolved_language", "")]), Vector2(-0.43, 0.32))
	_info = null
	_title = null
	_progress = null
	_thumb = null
	_seek_origin = null
	_elapsed = null
	_duration = null
	_status = null
	_listening_status = null
	_subtitle_status_label = null
	_subtitle_group_states.clear()
	_panel_status = null
	_modes = {}
	_volume_fill = null
	_volume_knob = null
	_volume_label = null
	_depth_fill = null
	_depth_knob = null
	_depth_label = null
	_depth_busy = null
	_narration_busy = null
	_audio_ids = {}
	_subtitle_ids = {}
	_subtitle_file_ids = {}
	_adjust_rows = {}
	_preset_buttons = {}
	if not _immersive_subtitles():
		if choices.opened == "subtitle_distance": choices.reset()
		if _adjustment == "subtitle_distance":
			_finish_adjustment()
			_adjustment = ""
	if not _settings_popup() and not _adjustment.is_empty():
		_draw_adjustments()
		_finish_surface_layout()
		return
	if not _state.get("has_video", false) or _subtitle_source != str(_state.get("source_uri", "")):
		_subtitle_open = false
		_set_subtitle_detail("")
		_subtitle_offset = 0
		_subtitle_files_open = false; _subtitle_files_offset = 0
	_subtitle_source = str(_state.get("source_uri", ""))
	if not _can_depth(): _close_depth_slider()
	if _failure_open:
		_draw_bar()
		_draw_popup(_draw_failure_panel)
		_finish_surface_layout()
		return
	if not _settings_popup():
		if section == 0: _draw_bar()
		else: _draw_panel()
	else:
		_draw_bar()
		if not _adjustment.is_empty():
			_draw_popup(_draw_adjustments)
		elif section != 0:
			_draw_popup(_draw_panel)
	_finish_surface_layout()

func _finish_surface_layout() -> void:
	if _popup_surfaces.is_empty() and not has_expanded_library():
		_popup_layout_key = ""
		_cinema_popup_centres.clear()
	if cinema_world_anchor:
		for button in _buttons:
			if button.node.get_parent() == self: button["tip_below"] = true
		apply_scene_overlay()
	_update_highlights()

## Video settings open as a popup above the bar; the photo menu (a subclass) still swaps its bar
## for full panels and keeps that layout.
func _settings_popup() -> bool:
	return true

## Slider row geometry: title/value positions, track [left, width], reset position.
func _slider_geometry() -> Dictionary:
	return {"title_x": -0.50, "title_size": TEXT_BODY, "value_x": -0.03, "value_size": TEXT_BODY, "left": SLIDER_LEFT,
		"width": SLIDER_WIDTH, "hit": 0.06, "height": 0.065, "thickness": 0.008, "knob": 0.022, "reset_x": 0.475, "reset_size": 0.05}

## Bar controls (100+) stay active under the settings popup; settings tiles use SETTINGS_TILE.
func _bar_target(target: int) -> bool:
	return target >= 100 and target < 100 + OPERATIONS[0].size()

func _settings_open() -> bool:
	return _failure_open or section != 0 or not _adjustment.is_empty()

## The settings popup's panel above the bar, like the subtitle and video mode popups; returns its top.
func _settings_frame(height: float) -> float:
	var panel := _quad(Vector2(POPUP_WIDTH, height), Vector3(0, POPUP_BOTTOM + height / 2, 0.001), Color(PANEL, 0.96), 10)
	panel.material_override.set_shader_parameter("corner_radius", 0.025)
	add_child(panel); _decorations.append(panel)
	_block_rays(panel, Vector2(POPUP_WIDTH, height))
	return POPUP_BOTTOM + height

## A sub-page header: back to the tabs, title, close.
func _settings_heading(title: String, top: float) -> void:
	_glyph(400, "up", Vector2(-0.47, top - 0.05), 0.055, true, I18n.t("Back"))
	_label(I18n.t(title), Vector3(0, top - 0.05, 0.004), TEXT_TITLE).font = ui_bold_font()
	_glyph(SETTINGS_CLOSE, "close", Vector2(0.47, top - 0.05), 0.055, true, I18n.t("Close"))

## Yellow "!" before an option that leaves the compositor layer; the ray tooltip explains why.
func _eye_buffer_note(target: int, centre: Vector2, parent: Node3D = null, diameter: float = 0.036) -> void:
	if not _state.get("layer_available", false): return
	# A quiet outline, not a filled badge: an invisible hover target carrying a ring and the mark.
	_button(EYE_BUFFER_NOTE + target, "", centre, Vector2.ONE * diameter, false, "", false, parent)
	var note: Dictionary = _buttons.back()
	note["hover_disabled"] = true
	note["radius"] = diameter / 2
	note.base_color = Color(TILE, 0)
	note.node.position.z += 0.003
	note.node.material_override.set_shader_parameter("surface_color", note.base_color)
	note.node.add_child(_ring(diameter, WARNING))
	_tips[note.target] = I18n.t("Leaves the compositor layer: higher GPU load, may drop frames")

static var _ring_shader: Shader

func _ring(diameter: float, tint: Color) -> MeshInstance3D:
	if not _ring_shader:
		_ring_shader = Shader.new()
		_ring_shader.code = """shader_type spatial;
render_mode unshaded, depth_draw_never, cull_disabled;
uniform vec4 tint : source_color;
void fragment() {
	float r = length(UV * 2.0 - 1.0);
	float w = fwidth(r);
	ALBEDO = tint.rgb;
	float ring = smoothstep(0.78 - w, 0.78 + w, r) * (1.0 - smoothstep(0.95 - w, 0.95 + w, r));
	// "!": a bar and a dot drawn here, so the mark stays bold at a few millimetres.
	vec2 p = UV * 2.0 - 1.0;
	float bar = (1.0 - smoothstep(0.11 - w, 0.11 + w, abs(p.x))) * step(-0.52, p.y) * step(p.y, 0.16);
	float point_mark = 1.0 - smoothstep(0.13 - w, 0.13 + w, length(p - vec2(0.0, 0.40)));
	ALPHA = tint.a * max(ring, max(bar, point_mark));
}"""
	var node := MeshInstance3D.new()
	var mesh := QuadMesh.new()
	mesh.size = Vector2.ONE * diameter
	node.mesh = mesh
	node.position = Vector3(0, 0, 0.002)
	var material := ShaderMaterial.new()
	material.shader = _ring_shader
	material.set_shader_parameter("tint", tint)
	material.render_priority = 13
	node.material_override = material
	return node

func _back_filename(label: Label3D, width: float) -> void:
	label.set_meta("filename_width", width)
	# An opaque, close-fitting caption plate keeps fractional glyph coverage inside
	# one HD capture. It avoids both eye-buffer blur and double-alpha glyph holes.
	# Label3D's mesh/AABB is deferred; measure the font now, before the first capture.
	var text_size := label.font.get_string_size(label.text, HORIZONTAL_ALIGNMENT_LEFT, -1, label.font_size) * label.pixel_size
	var size := Vector2(text_size.x + 0.024, maxf(text_size.y + 0.014, 0.036))
	var plate: MeshInstance3D = label.get_meta("filename_plate") if label.has_meta("filename_plate") else null
	if not is_instance_valid(plate):
		plate = _quad(size, Vector3.ZERO, Color(PANEL, 1.0), 11)
		label.add_child(plate); label.set_meta("filename_plate", plate)
	plate.position = Vector3(0, 0, -0.002)
	plate.mesh.size = size
	plate.material_override.set_shader_parameter("surface_size", size)
	plate.material_override.set_shader_parameter("corner_radius", 0.008)
	plate.visible = not label.text.is_empty()

## While watching, laid out like common VR players: a small translucent bar (title, then
## sound and subtitles | previous, play, next | Alpha, 2D -> 3D, video mode, settings, then the timeline),
## round actions floating above it, icons only with their names on hover.
func _draw_bar() -> void:
	CastPanel.draw(self, cast_state, 0.42, false)
	_set_backdrop(Vector2(1.16, 0.34), Vector2(0, -0.025))
	_style_control_bar()
	_backdrop.material_override.set_shader_parameter("corner_radius", 0.05)
	var title_width := 0.84 if _state.get("watch_available", false) else 0.9
	_title = _label(_fit_title(str(_state.get("title", "")) if _state.get("has_video", false) else "", "", title_width, 15), Vector3(0, 0.1, 0.004), 15)
	_back_filename(_title, title_width)
	if not str(_state.get("error", "")).is_empty():
		_title.visible = false
		_button(ERROR_OPEN, I18n.t("Playback failed") + "  ›", Vector2(0, 0.1), Vector2(0.90, 0.055))
		_buttons.back().base_color = Color(TILE, 0.0)
		_buttons.back().foreground = WARNING
		_buttons.back().node.get_child(0).modulate = WARNING
	_title.modulate = MUTED
	var row := 0.025
	_glyph(109, _sound_icon(), Vector2(VOLUME_X, row), 0.075, _enabled("mute"), _volume_tip())
	_style_sound(_buttons.back())
	_glyph(110, "subtitle_voice" if _narration_on() else "subtitle", Vector2(-0.4, row), 0.075, _enabled("subtitles"), I18n.t("Subtitles") + ": " + _subtitle_name() + ("\n" + _narration_status() if _narration_on() else ""))
	_narration_busy = _busy_ring(_buttons.back().node, 0.075)
	_bar_drawn = _bar_key()
	_glyph(111, "voice", Vector2(-0.3, row), 0.075, _enabled("audio"), I18n.t("Audio"))
	if _cast_allowed("previous_video"): _glyph(101, "previous_video", Vector2(-0.13, row), 0.08, _enabled("previous_video"), I18n.t("Previous video"))
	_round(102, "pause" if _pausable() else "play", Vector2(0, row), 0.095, _enabled("play"), true,
		I18n.t("Pause" if _pausable() else "Play"))
	if _cast_allowed("next_video"): _glyph(103, "next_video", Vector2(0.13, row), 0.08, _enabled("next_video"), I18n.t("Next video"))
	var spatial := bool(_state.get("spatial_video", false))
	if spatial: _close_depth_slider()
	_glyph(104, "alpha", Vector2(0.26 if spatial else 0.23, row), 0.075, _enabled("alpha"), I18n.t("AI portrait passthrough"))
	if not spatial:
		_glyph(112, "depth", Vector2(0.32, row), 0.075, _enabled("depth"), _depth_tip())
		_depth_busy = _busy_ring(_buttons.back().node, 0.075)
	_glyph(MODE, "view_mode", Vector2(0.38 if spatial else 0.41, row), 0.075, true, I18n.t("Video mode"))
	_glyph(11, "settings", Vector2(0.5, row), 0.075, true, I18n.t("Settings"))
	_seek_bar(-0.08)
	# Transient seek feedback must leave the bookmark endpoints readable.
	var has_markers: bool = not _state.get("bookmarks", []).is_empty()
	_status = _label(_seek_status(), Vector3(0, -0.044 if has_markers else -0.15, 0.004), 14 if has_markers else 20)
	_status.modulate = ACCENT
	_status.modulate.a = 1.0 if _listening_preparing() else float(_state.get("seek_feedback", {}).get("alpha", 1.0))
	_status.visible = not _status.text.is_empty()
	# Floating actions above the bar.
	_round(PIP, "pip", Vector2(-0.28, 0.215), 0.08, bool(_state.get("has_video", false)) and bool(_state.get("pip_available", true)), int(_state.get("pip_count", 0)) > 0,
		I18n.t("Finish recording to open picture in picture" if not _state.get("pip_available", true) and _state.get("capture", {}).get("recording", false) else "Picture in picture"))
	if _pip_open:
		pip_controls.draw()
	_round(107, "close", Vector2(-0.14, 0.215), 0.08, _enabled("stop"), false, I18n.t("End cast" if _state.has("cast") else ("Close" if clone_panel.opened else "Close video")))
	_round(100, "folder", Vector2(0, 0.215), 0.08, true, false, I18n.t("Library"))
	_round(108, "recenter", Vector2(0.14, 0.215), 0.08, true, false, I18n.t("Recenter"))
	if _cast_allowed("favorite"): _draw_favorite(Vector2(0.28, 0.215))
	disc_titles.draw_button(Vector2(0.56 if _state.get("capture", {}).get("available", false) else 0.42, 0.215))
	_draw_capture_action()
	if _state.get("audio_play_during_video", false):
		if not music_quick: music_quick = preload("res://scripts/music_quick_controls.gd").new(self, func(): action_requested.emit("music_toggle"))
		music_quick.draw(MUSIC_OPEN, Vector2(-0.56 if not _state.get("bookmarks", []).is_empty() else -0.42, 0.215), _state)
	elif music_quick: music_quick.reset()
	_place_device_status(Vector2(0, -0.245))
	if _cast_allowed("bookmarks"): bookmarks.draw()
	_expand_bar_action_hits()
	if _mode_open:
		_draw_popup(_draw_modes)
	if _volume_open:
		if cinema_world_anchor: _draw_popup(_draw_volume)
		else: _draw_volume()
	if _depth_open:
		if cinema_world_anchor: _draw_popup(_draw_depth)
		else: _draw_depth()
	if _subtitle_open:
		_draw_popup(_draw_subtitles)
	if _audio_open:
		_draw_popup(_draw_audio)
	if disc_titles.opened:
		_draw_popup(disc_titles.draw)

func _draw_audio() -> void:
	var tracks: Array = _state.get("audio_options", [])
	_audio_offset = clampi(_audio_offset, 0, maxi(0, tracks.size() - 4))
	var scrolling := tracks.size() > 4
	var height := 0.23 + mini(4, tracks.size()) * 0.075 + (0.06 if scrolling else 0.0)
	var top := POPUP_BOTTOM + height
	var panel := _quad(Vector2(POPUP_WIDTH, height), Vector3(0, POPUP_BOTTOM + height / 2, 0.001), Color(PANEL, 0.96), 10)
	panel.material_override.set_shader_parameter("corner_radius", 0.025)
	add_child(panel); _decorations.append(panel); _block_rays(panel, Vector2(POPUP_WIDTH, height))
	var heading := _label(I18n.t("Audio"), Vector3(-0.48, top - 0.05, 0.004), TEXT_TITLE)
	heading.font = ui_bold_font()
	heading.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	_glyph(AUDIO_CLOSE, "close", Vector2(0.465, top - 0.05), 0.055, true, I18n.t("Close"))
	var y := top - 0.13
	for index in range(_audio_offset, mini(tracks.size(), _audio_offset + 4)):
		var track: Dictionary = tracks[index]
		var target := AUDIO_ROW + index
		_audio_ids[target] = int(track.value)
		var title := I18n.t(str(track.label))
		_button(target, _fit_title(title, "", 0.78, TEXT_BODY), Vector2(0, y), Vector2(0.92, 0.065))
		var button: Dictionary = _buttons.back()
		var label: Label3D = button.node.get_child(0)
		set_label_size(label, TEXT_BODY); label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT; label.position.x = -0.42
		_tips[target] = title
		if int(track.value) == int(_state.get("audio_track_id", -1)):
			button.base_color = SELECTED
			_icon("check", Vector3(0.414, 0, 0.004), 0.029, ACCENT, button.node)
		y -= 0.075
	if scrolling:
		_button(AUDIO_UP, "↑", Vector2(-0.07, y + 0.015), Vector2(0.10, 0.05), _audio_offset > 0)
		_button(AUDIO_DOWN, "↓", Vector2(0.07, y + 0.015), Vector2(0.10, 0.05), _audio_offset + 4 < tracks.size())
		y -= 0.06
	var label := _label(I18n.t("Audio sync"), Vector3(-0.48, y - 0.01, 0.004), TEXT_BODY)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	choices.field(null, AudioTiming.slider_row(float(_state.get("audio_delay", 0.0)), str(_state.get("source_uri", "")), str(_state.get("audio_timing_key", ""))), Vector2(0.14, y - 0.01), 0.64, 0.065)
	choices.bounds = Vector2(POPUP_BOTTOM, top - 0.08)
	choices.finish()

func _scroll_audio(rows: int) -> void:
	var offset := clampi(_audio_offset + rows, 0, maxi(0, _state.get("audio_options", []).size() - 4))
	if offset != _audio_offset: _audio_offset = offset; refresh()

func _narration_status() -> String:
	if not _narration_on(): return ""
	if not str(_state.get("narration_preview_status", "")).is_empty(): return I18n.t(str(_state.narration_preview_status))
	if not str(_state.get("narration_voice_warning", "")).is_empty(): return I18n.t(str(_state.narration_voice_warning))
	var status := I18n.t(NarrationSettings.status_label(str(_state.get("narration_status", "off"))))
	if status.is_empty(): return ""
	if int(_state.get("narration_progress", -1)) >= 0: status += " · %d%%" % int(_state.narration_progress)
	if int(_state.get("narration_missing", 0)) > 0:
		var failed := str(_state.get("narration_miss_reason", "")) in ["generation_limit", "generation_error"]
		status += " · " + I18n.t("Speech generation failed" if failed else "Speech not ready before next subtitle")
	if int(_state.get("narration_delay", 0)) > 0: status += " · " + I18n.t("Delay %d s") % int(_state.narration_delay)
	return status

func _subtitle_tracks() -> Array:
	return _state.get("subtitle_options", [])

func _subtitle_label(track: Dictionary) -> String:
	var title := str(track.get("title", "")).strip_edges()
	if title.is_empty(): title = str(track.get("language", "")).strip_edges()
	if title.is_empty(): title = I18n.t("Subtitles") + " %d" % int(track.id)
	var codec := str(track.get("codec", "")).to_upper().replace("SUBRIP", "SRT").replace("WEBVTT", "VTT").replace("HDMV_PGS_SUBTITLE", "PGS")
	return _fit_title(title.replace("\n", " "), " · " + codec, SUBTITLE_MAIN_WIDTH - 0.16, TEXT_BODY)

func _subtitle_detail_group() -> String:
	return _subtitle_detail

func _set_subtitle_detail(group: String) -> void:
	choices.reset()
	_subtitle_detail = group

func _subtitle_groups() -> Array:
	var groups: Array = []
	if _state.get("listening_available", false):
		groups.append({"group": "listening", "title": "Live captions", "target": SUBTITLE_LISTENING, "enabled": true, "state": bool(_state.get("listening_enabled", false))})
	var listening: bool = _state.get("listening_enabled", false)
	var authored_text := _subtitle_tracks().any(func(track): return int(track.id) == int(_state.get("subtitle_track", 0)) and video_text_subtitle(track))
	if NarrationSettings.FEATURE_ENABLED and (_state.get("narration_available", false) or (listening and authored_text)):
		groups.append({"group": "narration", "title": "Subtitle narration", "target": SUBTITLE_NARRATION, "enabled": bool(_state.get("narration_available", false)) and not listening, "state": _narration_on()})
	# Retain the existing no-subtitle/PGS capability checks; appearance itself is independent of narration.
	if not _state.get("listening_available", false) or _state.get("listening_enabled", false) or not _subtitle_tracks().is_empty():
		groups.append({"group": "appearance", "title": "Subtitle adjustments", "target": SUBTITLE_APPEARANCE, "enabled": true})
	return groups

func _subtitle_controls() -> Array:
	var group := _subtitle_detail_group()
	var listening: bool = _state.get("listening_enabled", false)
	var pgs := not listening and _subtitle_tracks().any(func(track): return int(track.id) == int(_state.get("subtitle_track", 0)) and str(track.get("codec", "")) == "hdmv_pgs_subtitle")
	var rows: Array = []
	if group == "listening": return Listening.rows(_state)
	if group == "narration" and not listening and NarrationSettings.FEATURE_ENABLED and _state.get("narration_available", false):
		var narration_rows := NarrationSettings.rows(_state)
		var language_field: Dictionary = {}
		if _narration_on():
			language_field = narration_rows[1].field
			language_field.hint = "Reading language"
			language_field.display_format = "Read: %s"
		var clone_after := "narration_voice_kind" if _state.get("narration_personal_voices", []).is_empty() else "narration_custom_voice"
		for row in narration_rows:
			if row.field.key == "narration_language": continue
			if row.field.key == "narration_enabled":
				if not language_field.is_empty(): row.language_field = language_field
				row.field["switch"] = true; row.field.hint = "Subtitle narration"
			rows.append(row)
			if row.field.key == clone_after and _state.get("narration_voice_kind", "preset") == "custom" and _state.get("narration_clone_supported", false): rows.append({"clone_actions": true})
		return rows
	if group != "appearance": return rows
	if not _state.get("listening_enabled", false):
		rows.append({"title": "Subtitle sync", "field": SubtitleTiming.slider_row(float(_state.get("subtitle_delay", 0.0)), str(_state.get("source_uri", "")), str(_state.get("subtitle_timing_key", "")))})
	if _immersive_subtitles():
		rows.append({"title": "Subtitle direction", "field": SubtitleDepth.direction_row(int(_state.get("subtitle_direction", 0)))})
		for axis in ["horizontal", "vertical"]:
			var key: String = "subtitle_" + axis + "_position"
			rows.append({"title": "Horizontal position" if axis == "horizontal" else "Vertical position", "field": SubtitleDepth.slider_row(key, float(_state.get(key, 0.0)))})
		rows.append({"title": "Distance", "field": SubtitleDepth.slider_row("subtitle_distance", float(_state.get("subtitle_distance", 5.0)))})
	else:
		rows.append({"title": "Vertical position", "field": {"key": "subtitle_flat_position", "value": _state.get("subtitle_flat_position", 0.0), "slider": true, "span": Vector3(0, 100, 1), "unit": "%", "reset_value": 0.0}})
	rows.append({"title": "Subtitle size", "field": SubtitleStyle.size_row(float(_state.get("subtitle_size", 100.0)))})
	if not pgs:
		rows.append({"title": "Subtitle color style", "field": SubtitleStyle.style_row(_state.get("subtitle_style", SubtitleStyle.DEFAULT))})
		rows.append({"title": "Subtitle display", "field": SubtitleStyle.line_row(_state.get("subtitle_line", 0))})
	var encoding: Dictionary = _state.get("subtitle_encoding_row", {})
	if not listening and not encoding.is_empty(): rows.append({"title": "Subtitle encoding", "field": encoding})
	return rows

func video_text_subtitle(track: Dictionary) -> bool:
	return str(track.get("codec", "")) in ["subrip", "ass", "ssa", "webvtt", "mov_text", "text", "sami", "microdvd", "subviewer", "ttml"]

func _draw_subtitles() -> void:
	if clone_panel.opened:
		clone_panel.draw()
		if clone_panel.opened: return
	var before := get_children()
	var tracks := _subtitle_tracks()
	_subtitle_offset = clampi(_subtitle_offset, 0, maxi(0, tracks.size() - SUBTITLE_ROWS))
	var groups := _subtitle_groups()
	if not _subtitle_detail_group().is_empty() and not groups.any(func(group): return group.group == _subtitle_detail_group() and group.enabled):
		_set_subtitle_detail("")
	var rows := _subtitle_controls()
	var scrolling := tracks.size() > SUBTITLE_ROWS
	var other_subtitles := _has_other_subtitles()
	var files_error: bool = not str(_state.get("subtitle_file_error", "")).is_empty()
	var listening_only := bool(_state.get("listening_available", false)) and tracks.is_empty() and not other_subtitles
	if not other_subtitles and _state.get("subtitle_files_state", "idle") == "ready": _subtitle_files_open = false
	var height := 0.20 + ((0 if listening_only else 1) + mini(tracks.size(), SUBTITLE_ROWS)) * SUBTITLE_MAIN_PITCH + groups.size() * SUBTITLE_ENTRY_PITCH + (0.06 if scrolling else 0.0)
	if other_subtitles: height += _subtitle_files_height()
	elif files_error: height += 0.075
	# Reserve the footer independently of expanded details and transient status text.
	var has_status := groups.any(func(group): return group.has("state"))
	if has_status: height += 0.075
	var detail_height := 0.11
	for row in rows: detail_height += _subtitle_detail_row_height(row)
	if not rows.is_empty(): height = maxf(height, detail_height)
	var top := 0.285 + height
	_subtitle_main_bounds = Rect2(-SUBTITLE_MAIN_WIDTH / 2, 0.285, SUBTITLE_MAIN_WIDTH, height)
	var panel := _quad(Vector2(SUBTITLE_MAIN_WIDTH, height), Vector3(0, 0.285 + height / 2, 0.001), Color(PANEL, 0.96), 10)
	panel.material_override.set_shader_parameter("corner_radius", 0.025)
	panel.material_override.set_shader_parameter("round_right", rows.is_empty())
	add_child(panel); _decorations.append(panel)
	_block_rays(panel, panel.mesh.size)
	var heading := _label(I18n.t("Subtitles"), Vector3(-0.17, top - 0.05, 0.004), TEXT_TITLE)
	heading.font = ui_bold_font()
	heading.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	_glyph(SUBTITLE_CLOSE, "close", Vector2(0.175, top - 0.05), 0.055, true, I18n.t("Close"))
	var browsing: bool = _state.get("subtitle_browse_available", false)
	if browsing: _glyph(SUBTITLE_BROWSE, "folder", Vector2(0.095, top - 0.05), 0.055, str(_state.get("subtitle_file_loading", "")).is_empty(), I18n.t("Browse subtitles"))
	var auto_caption := "Loading subtitle…" if not str(_state.get("subtitle_file_loading", "")).is_empty() else "Loading subtitles…" if _state.get("subtitle_files_state", "idle") == "loading" else "Auto-load subtitles"
	var auto_label := _label(_fit_title(I18n.t(auto_caption), "", 0.23, TEXT_AUX), Vector3(-0.16, top - 0.115, 0.004), TEXT_AUX)
	auto_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	var automatic := bool(_state.get("subtitle_auto_load", true))
	_button(SUBTITLE_AUTO, "", Vector2(0.135, top - 0.115), Vector2(0.09, SUBTITLE_SETTING_HEIGHT))
	var toggle: Dictionary = _buttons.back()
	toggle.base_color = SELECTED if automatic else TILE
	toggle.node.material_override.set_shader_parameter("corner_radius", 0.025)
	var knob := _quad(Vector2(0.032, 0.032), Vector3(0.023 if automatic else -0.023, 0, 0.004), ACCENT if automatic else MUTED, 12)
	knob.material_override.set_shader_parameter("corner_radius", 0.016)
	toggle.node.add_child(knob)
	_tips[SUBTITLE_AUTO] = I18n.t("Auto-load subtitles") + " · " + I18n.t("On" if automatic else "Off")
	var y := top - 0.19
	if not listening_only:
		_subtitle_row(SUBTITLE_ROW, 0, I18n.t("Off"), y)
		y -= SUBTITLE_MAIN_PITCH
	for index in range(_subtitle_offset, mini(tracks.size(), _subtitle_offset + SUBTITLE_ROWS)):
		var track: Dictionary = tracks[index]
		_subtitle_row(SUBTITLE_ROW + index + 1, int(track.id), _subtitle_label(track), y)
		_tips[SUBTITLE_ROW + index + 1] = str(track.get("title", ""))
		y -= SUBTITLE_MAIN_PITCH
	if scrolling:
		_button(SUBTITLE_UP, "↑", Vector2(-0.07, y + 0.01), Vector2(0.10, 0.05), _subtitle_offset > 0)
		_button(SUBTITLE_DOWN, "↓", Vector2(0.07, y + 0.01), Vector2(0.10, 0.05), _subtitle_offset + SUBTITLE_ROWS < tracks.size())
		y -= 0.06
	if other_subtitles: y = _draw_subtitle_files(y - 0.01)
	elif files_error:
		var error := _label(_fit_title(I18n.t(str(_state.get("subtitle_file_error", "Unable to list subtitle files"))), "", 0.28, 16), Vector3(-0.17, y, 0.004), 16)
		error.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		if _state.get("subtitle_files_available", false): _glyph(SUBTITLE_FILES_RETRY, "refresh", Vector2(0.165, y), 0.05, true, I18n.t("Retry"))
		y -= 0.075
	y -= 0.01
	for group in groups:
		var opened: bool = group.group == _subtitle_detail_group()
		_button(int(group.target), _fit_title(I18n.t(group.title), "", 0.25 if group.has("state") else 0.30, TEXT_BODY), Vector2(0, y), Vector2(0.36, SUBTITLE_SETTING_HEIGHT), group.enabled)
		var entry: Dictionary = _buttons.back()
		if opened:
			entry.base_color = SELECTED
		var title: Label3D = entry.node.get_child(0)
		title.position.x = -0.16
		title.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		_icon("next", Vector3(0.157, 0, 0.005), 0.020, ACCENT if opened else MUTED, entry.node)
		if group.has("state"):
			var state_label := _label(I18n.t("On" if group.state else "Off"), Vector3(0.118, 0, 0.005), TEXT_AUX, entry.node)
			state_label.modulate = ACCENT if group.state else MUTED
			_subtitle_group_states[group.group] = state_label
		_tips[int(group.target)] = I18n.t(group.title) + (" · " + I18n.t("On" if group.get("state", false) else "Off") if group.has("state") else "")
		y -= SUBTITLE_ENTRY_PITCH
	if has_status:
		_subtitle_status_label = _label("", Vector3(0, 0.325, 0.004), TEXT_AUX)
		_subtitle_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_subtitle_status_label.width = 0.34 / _subtitle_status_label.pixel_size
		_subtitle_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_update_subtitle_status()
		if str(_state.get("narration_status", "")) in ["model_missing", "model_error", "timeline_error", "speech_error"]:
			_glyph(NARRATION_RETRY, "refresh", Vector2(0.185, 0.325), 0.04, true, I18n.t("Retry"))
	for child in get_children():
		if child is Node3D and not before.has(child): child.set_meta("menu_capture_region", "subtitle_main")
	if not rows.is_empty(): _draw_subtitle_details(rows, top, height)
	else: choices.finish()
	# The left column keeps one position whether or not details are open, so the entry
	# under the ray stays put; the expanded plate is centered over the playback bar.
	var shift := SUBTITLE_DETAIL_WIDTH / 2
	_subtitle_main_bounds.position.x -= shift
	_subtitle_panel_bounds = Rect2(-0.55, 0.285, 1.10, height)
	for child in get_children():
		if child is Node3D and not before.has(child): child.position.x -= shift
	for button in _buttons:
		if not before.has(button.node) and button.node.get_parent() == self: button.rect.position.x -= shift

func _update_subtitle_status() -> void:
	if not is_instance_valid(_subtitle_status_label): return
	var listening: bool = _state.get("listening_enabled", false)
	var status := _listening_status_text() if listening else _narration_status()
	_subtitle_status_label.text = _fit_title(status, "", 0.62, TEXT_AUX)
	_subtitle_status_label.modulate = ACCENT if (_listening_preparing() if listening else (_narration_preparing() or _state.get("narration_preview_busy", false))) else MUTED
	if listening: _listening_status = _subtitle_status_label
	for group in _subtitle_group_states:
		var label: Label3D = _subtitle_group_states[group]
		var on: bool = listening if group == "listening" else _narration_on()
		label.text = I18n.t("On" if on else "Off")
		label.modulate = ACCENT if on else MUTED

func _subtitle_detail_row_height(row: Dictionary) -> float:
	if not row.has("field"): return SUBTITLE_SETTING_PITCH
	# The feature switch sits in the column heading; only its language picker takes a row.
	if row.field.key in HEADING_SWITCHES: return SUBTITLE_SETTING_PITCH if row.has("language_field") else 0.0
	if row.field.key == "narration_hide_subtitles": return SUBTITLE_SETTING_PITCH
	return 0.115

func _draw_subtitle_details(rows: Array, top: float, height: float) -> void:
	var before := get_children()
	var panel := _quad(Vector2(SUBTITLE_DETAIL_WIDTH, height), Vector3(0, top - height / 2, 0.001), Color(PANEL, 0.96), 10)
	panel.material_override.set_shader_parameter("corner_radius", 0.025)
	panel.material_override.set_shader_parameter("round_left", false)
	add_child(panel); _decorations.append(panel); _block_rays(panel, panel.mesh.size)
	var group := _subtitle_detail_group()
	var switched := group in ["listening", "narration"]
	var heading := _label(_fit_title(I18n.t({"listening": "Live captions", "narration": "Subtitle narration", "appearance": "Subtitle adjustments"}[group]), "", 0.40 if switched else 0.50, TEXT_TITLE), Vector3(-0.285, top - 0.05, 0.004), TEXT_TITLE)
	heading.font = ui_bold_font(); heading.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	_glyph(SUBTITLE_DETAIL_CLOSE, "close", Vector2(0.28, top - 0.05), 0.055, true, I18n.t("Close"))
	var y := top - 0.13
	for row in rows:
		var pitch := _subtitle_detail_row_height(row)
		if row.get("clone_actions", false):
			if _state.get("narration_personal_voices", []).is_empty():
				_button(NARRATION_CLONE_START, I18n.t("Start cloning"), Vector2(0, y), Vector2(0.58, SUBTITLE_SETTING_HEIGHT), not str(_state.get("narration_resolved_language", "")).is_empty())
				y -= pitch
				continue
			var width := (0.58 - 0.014) / 2
			_button(NARRATION_CLONE_START, _fit_title(I18n.t("Start cloning"), "", width - 0.02, TEXT_BODY), Vector2(-(width + 0.014) / 2, y), Vector2(width, SUBTITLE_SETTING_HEIGHT), not str(_state.get("narration_resolved_language", "")).is_empty())
			_button(NARRATION_VOICES, _fit_title(I18n.t("My cloned voices"), "", width - 0.02, TEXT_BODY), Vector2((width + 0.014) / 2, y), Vector2(width, SUBTITLE_SETTING_HEIGHT))
			y -= pitch
			continue
		if row.get("subtitle_task", false) or row.get("subtitle_task_status", false):
			if row.get("subtitle_task", false):
				var footer_rows := rows.filter(func(item): return item.get("subtitle_task", false) or item.get("subtitle_task_status", false)).size()
				y = minf(y, top - height + 0.06 + (footer_rows - 1) * SUBTITLE_SETTING_PITCH)
			_draw_subtitle_task(y, row.get("subtitle_task_status", false)); y -= SUBTITLE_SETTING_PITCH; continue
		var field: Dictionary = row.field.duplicate()
		field["width"] = 0.58
		if field.key in HEADING_SWITCHES:
			choices.field(null, field, Vector2(0.185, top - 0.05), 0.09, SUBTITLE_SETTING_HEIGHT)
			if row.has("language_field"):
				var language_field: Dictionary = row.language_field.duplicate()
				language_field["width"] = 0.58
				choices.field(null, language_field, Vector2(0, y), 0.58, SUBTITLE_SETTING_HEIGHT)
			y -= pitch
			continue
		var toggle: bool = row.field.key == "narration_hide_subtitles"
		var title := _label(_fit_title(I18n.t(row.title), "", 0.43 if toggle else 0.58, TEXT_BODY), Vector3(-0.285, y, 0.004), TEXT_BODY)
		title.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		if field.key == "subtitle_delay": field["nudge_sides"] = true
		if toggle:
			choices.field(null, field, Vector2(0.245, y), 0.09, SUBTITLE_SETTING_HEIGHT)
			y -= pitch
			continue
		var voice_row: bool = row.field.key in ["narration_voice", "narration_custom_voice"]
		choices.field(null, field, Vector2(-0.04 if voice_row else 0, y - 0.045), 0.50 if voice_row else 0.58, SUBTITLE_SETTING_HEIGHT)
		if voice_row: _draw_narration_preview(y - 0.045)
		y -= pitch
	choices.bounds = Vector2(top - height, top - 0.08)
	# Build choice popups in the same local coordinates as before, then translate the
	# complete detail area. Sliders and ray captures retain their original control planes.
	choices.finish()
	for child in get_children():
		if child is Node3D and not before.has(child):
			child.position.x += SUBTITLE_DETAIL_X
			child.set_meta("menu_capture_region", "subtitle_detail")
	for button in _buttons:
		if not before.has(button.node) and button.node.get_parent() == self: button.rect.position.x += SUBTITLE_DETAIL_X
	# Same divider treatment as the bookmark/loop panel, within one continuous plate.
	var divider := _decoration(Vector2(0.003, height - 0.08), Vector2(SUBTITLE_MAIN_WIDTH / 2, top - height / 2), Color(MUTED, 0.70))
	divider.set_meta("menu_capture_region", "subtitle_main")
	# The inside edge is square: cover the half-plates' rounded ray-test corners.
	_block_rays(divider, Vector2(0.05, height), 0.0)

func _draw_subtitle_task(y: float, status: bool) -> void:
	var job: Dictionary = _state.get("subtitle_task", {})
	var running: bool = not job.is_empty() and str(job.get("state", "")) not in ["complete", "cancelled", "error"]
	var complete: bool = _state.get("listening_cache_complete", false) or job.get("original_complete", false)
	var translated: bool = _state.get("subtitle_task_mode", "original") == "translated" and not str(_state.get("listening_target", "")).is_empty() and Listening.Protocol.language(str(_state.get("listening_source", "ja"))) != str(_state.get("listening_target", ""))
	if not status:
		var done: bool = complete and (not translated or _state.get("listening_translation_complete", false) or job.get("state") == "complete")
		var caption := ("Generate full-film translation" if complete else "Pre-generate full-film translation") if translated else "Pre-generate full-film original subtitles"
		# The button spans the column up to the list glyph, giving way to cancel while running.
		var right := 0.145 if running else 0.225
		_button(SUBTITLE_GENERATE, _fit_title(I18n.t(caption), "", right + 0.29 - 0.03, TEXT_BODY), Vector2((right - 0.29) / 2, y), Vector2(right + 0.29, SUBTITLE_SETTING_HEIGHT), not running and not done)
		_tips[SUBTITLE_GENERATE] = I18n.t("Transcribe the entire audio track without playing it. Reuses cached subtitles; cancel keeps completed work.")
		if translated: _tips[SUBTITLE_GENERATE] += "\n" + I18n.t("Recognized text is sent to Microsoft")
		if running: _glyph(SUBTITLE_TASK_CANCEL, "close", Vector2(0.185, y), 0.052, true, I18n.t("Cancel"))
		_glyph(SUBTITLE_TASKS, "list", Vector2(0.265, y), 0.052, true, I18n.t("Subtitle pre-generation tasks"))
		return
	var caption := preload("res://scripts/subtitle_tasks.gd").caption(job) if not job.is_empty() else str(_state.get("subtitle_task_notice", ""))
	if complete:
		caption = I18n.t("Full-film original subtitles cached") if _state.get("listening_cache_persistent", job.get("persistent", false)) else I18n.t("Full-film original subtitles ready for this session")
		if translated and (_state.get("listening_translation_complete", false) or job.get("state") == "complete"):
			caption = I18n.t("Full-film translated subtitles cached" if _state.get("listening_cache_persistent", job.get("persistent", false)) else "Full-film translated subtitles ready for this session")
		if translated and job.get("state") == "translating": caption += " · %d/%d" % [int(job.get("translated", 0)), int(job.get("total", 0))]
	var label := _label(_fit_title(caption, "", 0.58, TEXT_AUX), Vector3(0, y + 0.014, 0.004), TEXT_AUX)
	label.modulate = MUTED
	if running:
		var ratio := float(job.get("progress", 0)) / 100.0
		if job.get("state") == "translating": ratio = float(job.get("translated", 0)) / maxf(1, float(job.get("total", 0)))
		var track := _quad(Vector2(0.58, 0.008), Vector3(0, y - 0.018, 0.004), TILE, 12)
		add_child(track); _decorations.append(track)
		if ratio > 0:
			var fill := _quad(Vector2(0.58 * ratio, 0.008), Vector3(-0.29 + 0.29 * ratio, y - 0.018, 0.005), ACCENT, 13)
			add_child(fill); _decorations.append(fill)

func _draw_narration_preview(y: float) -> void:
	var busy := bool(_state.get("narration_preview_busy", false))
	var voice_available: bool = _state.get("narration_voice_kind", "preset") != "custom" or not str(_state.get("narration_custom_voice", "")).is_empty()
	_draw_voice_preview(NARRATION_PREVIEW, y, busy, voice_available and not str(_state.get("narration_resolved_language", "")).is_empty())

func _draw_voice_preview(target: int, y: float, busy: bool, available: bool) -> void:
	_button(target, "", Vector2(0.26, y), Vector2.ONE * SUBTITLE_SETTING_HEIGHT, busy or available, "stop" if busy else "play")
	_tips[target] = I18n.t("Stop preview" if busy else "Preview voice")

func _other_subtitle_files() -> Array:
	var loaded: Array = _subtitle_tracks().map(func(track): return str(track.get("source_file", "")))
	return _state.get("subtitle_files", []).filter(func(filename): return not loaded.has(filename))

func _has_other_subtitles() -> bool:
	return _state.get("subtitle_files_available", false) and _state.get("subtitle_files_state", "idle") == "ready" and not _other_subtitle_files().is_empty()

func _subtitle_files_height() -> float:
	if not _subtitle_files_open: return 0.10
	var count := _other_subtitle_files().size()
	return 0.10 + mini(count, SUBTITLE_ROWS) * 0.075 + (0.06 if count > SUBTITLE_ROWS else 0.0) \
		+ (0.06 if not str(_state.get("subtitle_file_error", "")).is_empty() or not str(_state.get("subtitle_file_loading", "")).is_empty() else 0.0)

func _draw_subtitle_files(y: float) -> float:
	_button(SUBTITLE_FILES, _fit_title(I18n.t("Choose other subtitles"), "", 0.30, TEXT_BODY), Vector2(0, y), Vector2(0.36, 0.075))
	var entry: Dictionary = _buttons.back()
	var heading: Label3D = entry.node.get_child(0)
	heading.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT; heading.position.x = -0.16
	_icon("chevron_down" if _subtitle_files_open else "next", Vector3(0.157, 0, 0.005), 0.020, MUTED, entry.node)
	y -= 0.10
	if not _subtitle_files_open: return y
	var files := _other_subtitle_files()
	_subtitle_files_offset = clampi(_subtitle_files_offset, 0, maxi(0, files.size() - SUBTITLE_ROWS))
	var loading := not str(_state.get("subtitle_file_loading", "")).is_empty()
	for index in range(_subtitle_files_offset, mini(files.size(), _subtitle_files_offset + SUBTITLE_ROWS)):
		var target := SUBTITLE_FILE_ROW + index - _subtitle_files_offset
		var filename: String = files[index]
		_subtitle_file_ids[target] = filename
		_button(target, _fit_title(filename, "", 0.32, 18), Vector2(0, y), Vector2(0.36, 0.065), not loading)
		var label: Label3D = _buttons.back().node.get_child(0)
		set_label_size(label, 18)
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT; label.position.x = -0.16
		_tips[target] = filename
		y -= 0.075
	if files.size() > SUBTITLE_ROWS:
		_button(SUBTITLE_FILES_UP, "↑", Vector2(-0.07, y + 0.015), Vector2(0.10, 0.05), _subtitle_files_offset > 0)
		_button(SUBTITLE_FILES_DOWN, "↓", Vector2(0.07, y + 0.015), Vector2(0.10, 0.05), _subtitle_files_offset + SUBTITLE_ROWS < files.size())
		y -= 0.06
	var error := str(_state.get("subtitle_file_error", ""))
	if loading or not error.is_empty():
		_label(_fit_title(I18n.t("Loading subtitle…" if loading else error), "", 0.34, 16), Vector3(0, y, 0.004), 16)
		y -= 0.06
	return y

func _immersive_subtitles() -> bool:
	return _state.get("has_video", false) and int(_state.get("geometry", 0)) != 0

func _subtitle_row(target: int, id: int, text: String, y: float) -> void:
	_subtitle_ids[target] = id
	_button(target, text, Vector2(0, y), Vector2(0.36, 0.055))
	var button: Dictionary = _buttons.back()
	var label: Label3D = button.node.get_child(0)
	set_label_size(label, TEXT_BODY)
	label.position.x = -0.16
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	if id == int(_state.get("subtitle_track", 0)) and not _state.get("listening_enabled", false):
		button.base_color = SELECTED
		_icon("check", Vector3(0.154, 0, 0.004), 0.029, ACCENT, button.node)

func stick_scroll(y: float, delta: float) -> void:
	if has_expanded_library():
		if not _controls_pointer_capture(): expanded_library.stick_scroll(y, delta)
		return
	if choices.stick_scroll(y, delta): return
	if clone_panel.opened: clone_panel.stick(y, delta); return
	if visible and bookmarks.opened:
		bookmarks.stick_scroll(y, delta)
		return
	if not visible or not (_subtitle_open or _audio_open or disc_titles.opened) or not is_finite(y) or absf(y) < 0.4:
		_subtitle_scroll = 0.0
		return
	_subtitle_scroll -= y * delta * 7.0
	if absf(_subtitle_scroll) >= 1.0:
		if _audio_open: _scroll_audio(int(_subtitle_scroll))
		elif disc_titles.opened: disc_titles.scroll(int(_subtitle_scroll))
		elif _subtitle_files_open: _scroll_subtitle_files(int(_subtitle_scroll))
		else: _scroll_subtitles(int(_subtitle_scroll))
		_subtitle_scroll -= int(_subtitle_scroll)

func stick_scroll_horizontal(x: float, delta: float) -> void:
	if has_expanded_library() and not _controls_pointer_capture():
		expanded_library.stick_scroll_horizontal(x, delta)

func _scroll_subtitles(rows: int) -> void:
	var offset := clampi(_subtitle_offset + rows, 0, maxi(0, _subtitle_tracks().size() - SUBTITLE_ROWS))
	if offset != _subtitle_offset:
		_subtitle_offset = offset
		refresh()

func _scroll_subtitle_files(rows: int) -> void:
	var offset := clampi(_subtitle_files_offset + rows, 0, maxi(0, _other_subtitle_files().size() - SUBTITLE_ROWS))
	if offset != _subtitle_files_offset:
		_subtitle_files_offset = offset; refresh()

func _can_depth() -> bool:
	if not _cast_allowed("depth"): return false
	return _state.get("has_video", false) and not _state.get("spatial_video", false) and int(_state.get("geometry", 0)) == 0 and not _state.get("stereo", false)

func _toggle_depth_slider() -> void:
	if not _can_depth(): return
	if _depth_open:
		_close_depth_slider()
	else:
		_depth_open = true
		_subtitle_open = false
		_mode_open = false
		_volume_open = false
		_volume_hand = ""
	refresh()

func _depth_icon_target() -> int:
	return 112

func _depth_tip() -> String:
	if not _cast_allowed("depth"): return I18n.t("Available for seekable videos")
	return I18n.t("Click to adjust · Double-click to disable 3D" if _state.get("depth_requested", false) else "Click to adjust · Double-click to enable 3D")

func _volume_tip() -> String:
	return I18n.t("Click to adjust · Double-click to unmute" if _state.get("muted", false) else "Click to adjust · Double-click to mute")

func _press_quick_icon(hand: String, target: int) -> bool:
	if target != _depth_icon_target() and target != 109:
		_icon_tap.clear(); return false
	var now := Time.get_ticks_msec()
	var source := str(_state.get("source_uri", ""))
	var double: bool = _icon_tap.get("released", false) and _icon_tap.get("hand") == hand and _icon_tap.get("target") == target \
		and _icon_tap.get("source") == source and now - int(_icon_tap.get("time", 0)) <= ICON_DOUBLE_CLICK_MS
	if not double:
		_icon_tap = {"hand": hand, "target": target, "source": source, "time": now, "released": false}
		return false
	_icon_tap.clear()
	_close_depth_slider(); _volume_open = false
	if target == _depth_icon_target():
		if _state.get("depth_requested", false): action_requested.emit("depth")
		else: depth_strength_requested.emit(DepthStrength.remembered(float(_state.get("depth_strength", _depth_default())), _depth_maximum(), _depth_default()))
		depth_strength_committed.emit()
	else:
		volume_requested.emit(float(_state.get("volume", 100.0)), not _state.get("muted", false))
	refresh()
	return true

func _draw_depth() -> void:
	var before := get_children()
	var span := _depth_span()
	var height := span.y - span.x
	var middle := (span.x + span.y) / 2
	var panel := _quad(Vector2(0.13, height + 0.19), Vector3(DEPTH_X, middle, 0.001), Color(PANEL, 1.0), 10)
	panel.material_override.set_shader_parameter("corner_radius", 0.05)
	add_child(panel)
	_decorations.append(panel)
	_block_rays(panel, panel.mesh.size, 0.05)
	_button(DEPTH, "", Vector2(DEPTH_X, middle), Vector2(0.11, height + 0.04), _can_depth())
	_buttons.back().base_color = Color(TILE, 0.0)
	_decoration(Vector2(0.012, height), Vector2(DEPTH_X, middle), Color(0.3, 0.35, 0.4))
	# Mark whole multiples of the original parallax within this media's range.
	for value in [1.0, 2.0, 3.0]:
		if value > _depth_maximum(): continue
		_decoration(Vector2(0.035, 0.003), Vector2(DEPTH_X, span.x + height * DepthStrength.to_fraction(value, _depth_maximum())), MUTED)
	_depth_fill = _decoration(Vector2(0.012, height), Vector2(DEPTH_X, middle), ACCENT)
	_depth_fill.material_override.render_priority = 13
	_depth_knob = _decoration(Vector2(0.03, 0.03), Vector2(DEPTH_X, span.x), Color.WHITE)
	_depth_knob.material_override.set_shader_parameter("corner_radius", 0.015)
	_depth_knob.material_override.render_priority = 14
	_depth_label = _label("", Vector3(DEPTH_X, span.y + 0.045, 0.004), 16)
	_glyph(DEPTH_RESET, "refresh", Vector2(DEPTH_X, span.x - 0.055), 0.06, false, I18n.t("Reset"))
	_refresh_depth()
	_raise_quick_popup(before)

## Quick sliders cover floating actions in the UI pass and in ray hit testing.
func _raise_quick_popup(before: Array) -> void:
	for child in get_children():
		if child is Node3D and not before.has(child):
			child.position.z += 0.02
			_raise_quick_popup_materials(child)

func _raise_quick_popup_materials(node: Node) -> void:
	if node is MeshInstance3D and node.material_override:
		node.material_override.render_priority += 10
	elif node is Label3D:
		node.render_priority += 10
	for child in node.get_children(): _raise_quick_popup_materials(child)

func _depth_maximum() -> float:
	return DepthStrength.MAX

func _depth_default() -> float:
	return 1.0 if _state.get("portrait_requested", false) else DepthStrength.VIDEO_DEFAULT

func _depth_span() -> Vector2:
	return DEPTH_SPAN

func _depth_caption() -> String:
	return "%d%%" % roundi(DepthStrength.clamp_value(float(_state.get("depth_strength", _depth_default())), _depth_maximum()) * 100) if _state.get("depth_requested", false) else I18n.t("Off")

func _refresh_depth() -> void:
	if not is_instance_valid(_depth_fill): return
	var span := _depth_span()
	var fraction := DepthStrength.to_fraction(float(_state.get("depth_strength", _depth_default())), _depth_maximum()) if _state.get("depth_requested", false) else 0.0
	var height := span.y - span.x
	_depth_fill.visible = fraction > 0
	_depth_fill.mesh.size.y = maxf(0.001, height * fraction)
	_depth_fill.position.y = span.x + height * fraction / 2
	_depth_fill.material_override.set_shader_parameter("surface_size", _depth_fill.mesh.size)
	_depth_knob.position.y = span.x + height * fraction
	_depth_label.text = _depth_caption()
	for button in _buttons:
		if button.target != DEPTH_RESET: continue
		button.enabled = _can_depth() and _state.get("depth_requested", false) and not is_equal_approx(float(_state.get("depth_strength", _depth_default())), _depth_default())
		button.node.get_child(1).material_override.albedo_color = ACCENT if button.enabled else MUTED

func _set_depth_at(y: float) -> void:
	var span := _depth_span()
	var fraction := (y - span.x) / (span.y - span.x)
	var strength := DepthStrength.from_fraction(fraction, _depth_maximum())
	if fraction < 0.02: strength = 0.0 # Small bottom dead zone makes Off easy to reach.
	var level := roundi(strength * 100)
	if level == _depth_sent: return
	_depth_sent = level
	depth_strength_requested.emit(strength)
	refresh_values()

## Volume: a slider rising from the sound icon; the bottom of the track is mute.
func _draw_volume() -> void:
	var before := get_children()
	var available: bool = _state.get("whisper_available", false)
	var enhanced := int(_state.get("audio_whisper", 0)) > 0 and available
	var top := VOLUME_SPAN.y + (BOOST_HEIGHT if enhanced else 0.0)
	var height := top - VOLUME_SPAN.x
	var middle := (VOLUME_SPAN.x + top) / 2
	var cap_y := top + 0.105
	# Leave a small gap above the sound button (row 0.025, diameter 0.075).
	var bottom := VOLUME_SPAN.x - 0.025
	var panel_top := cap_y + 0.055 if available else top + 0.09
	var panel := _quad(Vector2(0.1, panel_top - bottom), Vector3(VOLUME_X, (panel_top + bottom) / 2, 0.001), Color(PANEL, 0.94), 10)
	panel.material_override.set_shader_parameter("corner_radius", 0.05)
	add_child(panel); _decorations.append(panel)
	_block_rays(panel, panel.mesh.size, 0.05)
	_button(VOLUME, "", Vector2(VOLUME_X, middle), Vector2(0.10, height + 0.04), _enabled("mute") and _state.get("volume_writable", true))
	_buttons.back().base_color = Color(TILE, 0.0)
	var normal_height := VOLUME_SPAN.y - VOLUME_SPAN.x
	var normal_mid := (VOLUME_SPAN.y + VOLUME_SPAN.x) / 2
	_decoration(Vector2(0.012, normal_height), Vector2(VOLUME_X, normal_mid), Color(0.3, 0.35, 0.4))
	_volume_fill = _decoration(Vector2(0.012, normal_height), Vector2(VOLUME_X, normal_mid), ACCENT)
	_volume_fill.material_override.render_priority = 13
	_boost_fill = null; _boost_mark = null
	if enhanced:
		_decoration(Vector2(0.012, BOOST_HEIGHT), Vector2(VOLUME_X, VOLUME_SPAN.y + BOOST_HEIGHT / 2), Color(WARNING, 0.35))
		_boost_fill = _decoration(Vector2(0.012, BOOST_HEIGHT), Vector2(VOLUME_X, VOLUME_SPAN.y + BOOST_HEIGHT / 2), WARNING)
		_boost_fill.material_override.render_priority = 13
		_decoration(Vector2(0.08, 0.004), Vector2(VOLUME_X, VOLUME_SPAN.y), Color(0.7, 0.74, 0.78))
		_boost_mark = _decoration(Vector2(0.035, 0.004), Vector2(VOLUME_X, top), Color(WARNING, 0.55))
	_volume_knob = _decoration(Vector2(0.03, 0.03), Vector2(VOLUME_X, VOLUME_SPAN.x), Color.WHITE)
	_volume_knob.material_override.set_shader_parameter("corner_radius", 0.015)
	_volume_knob.material_override.render_priority = 14
	_volume_label = _label("", Vector3(VOLUME_X, top + 0.038, 0.004), 16)
	if available:
		_button(WHISPER, I18n.t("Boost"), Vector2(VOLUME_X, cap_y), Vector2(0.09, 0.085), _state.get("has_video", false) and _state.get("audio_available", false))
		_tips[WHISPER] = I18n.t("Dialogue enhancement")
	_refresh_volume()
	_raise_quick_popup(before)

## Shown level: 0 while muted.
func _volume_level() -> int:
	return 0 if _state.get("muted", false) else roundi(float(_state.get("volume", 100)))

## Silence must be obvious after a restart restores it: a red glyph on a red-tinted disc.
func _style_sound(button: Dictionary) -> void:
	var silent: bool = _volume_level() == 0 and button.enabled
	button.base_color = MUTE_TINT if silent else Color(TILE, 0.0)
	button.node.get_child(1).material_override.albedo_color = MUTE_INK if silent else ((WARNING if int(_state.get("audio_whisper", 0)) > 0 else button.foreground) if button.enabled else MUTED)
	_update_highlights()

func _sound_icon() -> String:
	var level := _volume_level()
	return "mute" if level == 0 else ("volume_low" if level < 50 else "sound")

func _refresh_volume() -> void:
	if not is_instance_valid(_volume_fill): return
	var level := _volume_level()
	var fraction := minf(level / 100.0, 1.0)
	var height := VOLUME_SPAN.y - VOLUME_SPAN.x
	_volume_fill.visible = fraction > 0
	_volume_fill.mesh.size.y = maxf(0.001, height * fraction)
	_volume_fill.position.y = VOLUME_SPAN.x + height * fraction / 2
	_volume_fill.material_override.set_shader_parameter("surface_size", _volume_fill.mesh.size)
	var enhanced := int(_state.get("audio_whisper", 0)) > 0
	var boost := clampf((level - 100.0) / 50.0, 0.0, 1.0) if enhanced else 0.0
	_volume_knob.position.y = VOLUME_SPAN.y + BOOST_HEIGHT * boost if boost > 0 else VOLUME_SPAN.x + height * fraction
	_volume_knob.material_override.set_shader_parameter("surface_color", WARNING if boost > 0 else Color.WHITE)
	_volume_label.text = "%d%%" % level
	_volume_label.modulate = WARNING if boost > 0 else Color.WHITE
	if is_instance_valid(_boost_fill):
		_boost_fill.visible = boost > 0
		_boost_fill.mesh.size.y = maxf(0.001, BOOST_HEIGHT * boost)
		_boost_fill.position.y = VOLUME_SPAN.y + BOOST_HEIGHT * boost / 2
		_boost_fill.material_override.set_shader_parameter("surface_size", _boost_fill.mesh.size)
	if is_instance_valid(_boost_mark):
		var saved := int(_state.get("boost_saved", 0))
		_boost_mark.visible = saved > 0 and boost == 0
		_boost_mark.position.y = VOLUME_SPAN.y + BOOST_HEIGHT * clampf(saved / 50.0, 0.0, 1.0)
	for button in _buttons:
		if button.target != WHISPER: continue
		button.base_color = SELECTED if enhanced else TILE
		button.node.get_child(0).modulate = (WARNING if enhanced else Color.WHITE) if button.enabled else MUTED
		_tips[WHISPER] = I18n.t("Whisper enhancement unavailable" if not str(_state.get("whisper_error", "")).is_empty() else "Dialogue enhancement")
	_update_highlights()

func _set_volume_at(y: float) -> void:
	var enhanced := int(_state.get("audio_whisper", 0)) > 0 and bool(_state.get("whisper_available", false))
	var level := roundi(clampf((y - VOLUME_SPAN.x) / (VOLUME_SPAN.y - VOLUME_SPAN.x), 0.0, 1.0) * 100)
	if enhanced and y > VOLUME_SPAN.y: level = 100 + roundi(clampf((y - VOLUME_SPAN.y) / BOOST_HEIGHT, 0.0, 1.0) * 50)
	if level < VOLUME_MUTE: level = 0
	if level == _volume_sent: return
	_volume_sent = level
	volume_requested.emit(float(level), level == 0)
	if level > 100 and not _volume_breakthrough:
		_volume_breakthrough = true; whisper_haptic.emit(_volume_hand)
	refresh_values()

## Point on the menu plane (local), even off the track, so a drag past either end clamps.
func _plane_point(origin: Vector3, direction: Vector3, target: int = NONE) -> Variant:
	if target in [DEPTH, VOLUME] and not cinema_world_anchor:
		return project_pointer(origin, direction, Transform3D(Basis.IDENTITY, Vector3(0, 0, control_plane(target).origin.z)))
	var surface := _input_surface(target)
	var plane := global_transform.affine_inverse() * surface.global_transform
	if cinema_world_anchor and target in [DEPTH, VOLUME]:
		for button in _buttons:
			if int(button.target) == target:
				var relative: Transform3D = surface.global_transform.affine_inverse() * button.node.global_transform
				plane *= Transform3D(Basis.IDENTITY, Vector3(0, 0, relative.origin.z))
				break
	return project_pointer(origin, direction, plane)

func press_pointer(hand: String, origin: Vector3, direction: Vector3, tracked: bool) -> bool:
	if has_expanded_library() and not _controls_pointer_capture():
		if expanded_library.has_pointer_capture() or (tracked and ray_hit(origin, direction).get("library", false)):
			super.update_pointer(hand, origin, direction, false)
			return expanded_library.press_pointer(hand, origin, direction, tracked)
		var controls_hit := super.ray_hit(origin, direction) if tracked else {}
		# Keep transport and timeline available; opening another popup folds the browser away.
		if not controls_hit.is_empty() and int(controls_hit.target) not in [NONE, 100, 101, 102, 103, 107, 108, SEEK, FOLLOW, TEMP_PASSTHROUGH, SPACE_LOCK, WATCH]:
			expanded_library.dismiss()
	if not _track_drag.is_empty(): return true
	if choices.press(hand, origin, direction, tracked): return true
	if not bookmarks.capture.is_empty(): return true
	for owner in [_adjust_hand, _depth_hand, _volume_hand, _seek_hand]:
		if not owner.is_empty() and owner != hand: return false
	update_pointer(hand, origin, direction, tracked)
	var hit := ray_hit(origin, direction) if tracked else {}
	var clone_row: bool = clone_panel.opened and not hit.is_empty() and clone_panel.actions.get(int(hit.target), {}).get("operation", "") in ["caption", "original", "clone", "save_name", "use", "preview", "rename_name"]
	if not hit.is_empty() and hit.get("enabled", false) and (clone_row or _audio_ids.has(int(hit.target)) or disc_titles.has_row(int(hit.target)) or _subtitle_ids.has(int(hit.target)) or _subtitle_file_ids.has(int(hit.target))):
		var kind := "clone" if clone_row else ("audio" if _audio_ids.has(int(hit.target)) else ("disc" if disc_titles.has_row(int(hit.target)) else ("files" if _subtitle_file_ids.has(int(hit.target)) else "subtitle")))
		_track_drag = {"hand": hand, "target": int(hit.target), "plane": control_plane(int(hit.target)), "point": control_point(hit), "kind": kind,
			"offset": clone_panel.offset if kind == "clone" else (_audio_offset if kind == "audio" else (disc_titles.offset if kind == "disc" else (_subtitle_files_offset if kind == "files" else _subtitle_offset))), "moved": false, "source": str(_state.get("source_uri", ""))}
		return true
	if not hit.is_empty() and hit.get("enabled", false) and _press_quick_icon(hand, int(hit.target)): return true
	if hit.is_empty(): _icon_tap.clear()
	if not hit.is_empty() and bookmarks.press(hand, hit): return true
	if not hit.is_empty() and int(hit.target) == SEEK and _can_seek():
		_seek_hand = hand
		_seek_start = _seek_at(_input_point(hit).x)
		_seek_preview = _seek_start
		return true
	if not hit.is_empty() and _adjust_rows.has(int(hit.target)):
		if not _adjust_hand.is_empty() and _adjust_hand != hand: return false
		_adjust_hand = hand
		_adjust_target = int(hit.target)
		_set_adjustment_at(_input_point(hit).x)
		return true
	if not hit.is_empty() and int(hit.target) == DEPTH:
		if not _depth_hand.is_empty() and _depth_hand != hand: return false
		_depth_hand = hand
		_depth_sent = -1
		_set_depth_at(_input_point(hit).y)
		return true
	if not hit.is_empty() and int(hit.target) == VOLUME:
		# The press sets the level; holding the trigger drags it (update_pointer).
		if not _volume_hand.is_empty() and _volume_hand != hand: return false
		_volume_hand = hand
		_volume_breakthrough = false
		_volume_sent = -1
		_set_volume_at(_input_point(hit).y)
		return true
	return super(hand, origin, direction, tracked)

func cancel_pointer(hand: String) -> void:
	if has_expanded_library(): expanded_library.cancel_pointer(hand)
	if _track_drag.get("hand") == hand: _track_drag.clear()
	if _icon_tap.get("hand") == hand: _icon_tap.clear()
	choices.cancel(hand)
	if bookmarks.capture.get("hand", "") == hand: bookmarks.cancel()
	if hand == _seek_hand:
		_seek_hand = ""
		_seek_preview = -1
	release_pointer(hand, Vector3.ZERO, Vector3.ZERO, false)
	super(hand)

func update_pointer(hand: String, origin: Vector3, direction: Vector3, tracked: bool) -> void:
	var on_library: bool = has_expanded_library() and not _controls_pointer_capture() and (expanded_library.has_pointer_capture() or (tracked and pointer_hit(origin, direction).get("library", false)))
	super(hand, origin, direction, tracked and not on_library)
	pip_controls.update()
	if has_expanded_library(): expanded_library.update_pointer(hand, origin, direction, tracked and on_library)
	if _track_drag.get("hand") == hand:
		if not tracked or not visible or _track_drag.source != str(_state.get("source_uri", "")): _track_drag.clear()
		else:
			var drag_point: Variant = project_pointer(origin, direction, _track_drag.plane)
			if drag_point != null:
				var shift := float(drag_point.y) - float(_track_drag.point.y)
				if absf(shift) > 0.018: _track_drag.moved = true
				if _track_drag.moved:
					var next := int(_track_drag.offset) + roundi(shift / (ClonePanel.ROW_PITCH if _track_drag.kind == "clone" else 0.075))
					if _track_drag.kind == "clone": clone_panel.move(next - clone_panel.offset)
					elif _track_drag.kind == "audio": _scroll_audio(next - _audio_offset)
					elif _track_drag.kind == "disc": disc_titles.scroll(next - disc_titles.offset)
					elif _track_drag.kind == "files": _scroll_subtitle_files(next - _subtitle_files_offset)
					else: _scroll_subtitles(next - _subtitle_offset)
	choices.update(hand, origin, direction, tracked)
	bookmarks.update(hand, origin, direction, tracked)
	if hand == _seek_hand:
		if not tracked or not visible or not _can_seek():
			_seek_hand = ""
			_seek_preview = -1
		else:
			var seek_point: Variant = _plane_point(origin, direction, SEEK)
			if seek_point != null: _seek_preview = _seek_at(float(seek_point.x))
	if hand == _volume_hand and (not visible or not tracked): _volume_hand = ""
	if hand == _adjust_hand:
		if not visible or not tracked:
			_finish_adjustment()
		else:
			var adjust_point: Variant = _plane_point(origin, direction, _adjust_target)
			if adjust_point != null: _set_adjustment_at(float(adjust_point.x))
	if hand == _depth_hand:
		if not visible or not tracked or not _depth_open or not _can_depth():
			_finish_depth_drag()
		else:
			var depth_point: Variant = _plane_point(origin, direction, DEPTH)
			if depth_point != null: _set_depth_at(float(depth_point.y))
	if hand != _volume_hand or not tracked or not _volume_open:
		return
	var point: Variant = _plane_point(origin, direction, VOLUME)
	if point != null:
		_set_volume_at(float(point.y))

func release_pointer(hand: String, _origin: Vector3, _direction: Vector3, _tracked: bool) -> void:
	if _track_drag.get("hand") == hand:
		var request := _track_drag.duplicate()
		_track_drag.clear()
		if _tracked and visible and not request.moved and request.source == str(_state.get("source_uri", "")) and int(ray_hit(_origin, _direction).get("target", NONE)) == request.target: _activate(int(request.target))
		return
	if has_expanded_library() and expanded_library.has_pointer_capture():
		expanded_library.release_pointer(hand, _origin, _direction, _tracked)
		return
	if _icon_tap.get("hand") == hand:
		if _tracked and visible: _icon_tap.released = true
		else: _icon_tap.clear()
	if choices.capture.get("hand", "") == hand:
		choices.release(hand, _origin, _direction, _tracked); return
	bookmarks.release(hand, _origin, _direction, _tracked)
	if hand == _seek_hand:
		var target := _seek_preview
		_seek_hand = ""
		_seek_preview = -1
		if _tracked and visible and _can_seek() and target >= 0: seek_requested.emit(target)
	if hand == _adjust_hand: _finish_adjustment()
	if hand == _depth_hand: _finish_depth_drag()
	if hand == _volume_hand:
		_volume_hand = ""

func _bar_key() -> String:
	return str([_state.get("subtitle_encoding_row", {}), _state.get("audio_play_during_video", false), _state.get("audio_current", ""), _state.get("audio_title", ""), _state.get("audio_paused", true), _state.get("audio_active", false),
		_state.get("narration_voice_kind", "preset"), _state.get("narration_custom_voice", ""), _state.get("narration_personal_voices", []), _state.get("narration_voice_warning", ""), _state.get("narration_preview_status", ""), _state.get("narration_clone_state", {}).get("revision", 0)]) + _base_bar_key()

func _base_bar_key() -> String:
	return str([_state.get("subtitle_task", {}), _state.get("subtitle_task_mode"), _state.get("listening_cache_complete"), _state.get("listening_translation_complete")]) + str([_state.get("listening_available", false), _state.get("listening_enabled", false), _state.get("listening_source", "ja"), _state.get("listening_target", ""), _state.get("listening_lead", 12), _state.get("listening_state", "off")]) + str([_state.get("cast", {}), cast_state]) + str([_state.get("screen_scene_locked", false), _state.get("cinema_lights", "auto")]) + _capture_key() + str([_state.get("pip_slots", []), _state.get("pip_count", 0), _state.get("pip_available", true), int(_state.get("audio_whisper", 0)) > 0, _state.get("volume_writable", true), _state.get("whisper_available", false), _state.get("clone_voice", false), _state.get("geometry", 0), _state.get("has_video", false),
		_state.get("spatial_video", false), _state.get("error", ""),
		_state.get("source_uri", ""), _subtitle_tracks(), _state.get("subtitle_track", 0), bookmarks.key(), _state.get("audio_options", []), _state.get("audio_track_id", -1), _state.get("audio_delay", 0.0), _state.get("audio_timing_key", ""),
		_state.get("subtitle_browse_available", false), _state.get("subtitle_files_available", false), _state.get("subtitle_files_revision", 0), _state.get("subtitle_files_state", "idle"), _state.get("subtitle_file_loading", ""), _state.get("subtitle_file_error", ""), _state.get("subtitle_timing_key", ""),
		_state.get("subtitle_distance", SubtitleDepth.DEFAULT), _state.get("subtitle_position", SubtitleDepth.DEFAULT_POSITION), _state.get("subtitle_horizontal_position", 0.0), _state.get("subtitle_vertical_position", 0.0), _state.get("subtitle_direction", 0), _state.get("subtitle_size", 100), _state.get("subtitle_style", SubtitleStyle.DEFAULT), _state.get("subtitle_line", 0), _state.get("subtitle_flat_position", 0), _state.get("subtitle_auto_load", true), _state.get("subtitle_delay", 0.0),
		_state.get("narration_enabled", false), _state.get("narration_source", -1), _state.get("narration_sources", []), _state.get("narration_language", "auto"), _state.get("narration_resolved_language", ""), _state.get("narration_voice", ""), _state.get("narration_status", "off"), _state.get("narration_preview_busy", false), _state.get("narration_missing", 0), _state.get("narration_timing", "continuous"), _state.get("narration_delay", 0), _state.get("narration_progress", -1), _state.get("narration_profile", ""), _state.get("narration_voice_origin", "default"), _state.get("narration_line", 0), _state.get("narration_hide_subtitles", true), _state.get("narration_miss_reason", ""), _state.get("narration_language_required", false), _state.get("narration_preview_progress", -1)])

func _seek_at(x: float) -> int:
	return roundi(clampf((x + BAR_SEEK / 2) / BAR_SEEK, 0.0, 1.0) * int(_state.get("duration_ms", 0)))

func _supports_half_layouts() -> bool:
	return true

## Video mode: every projection and stereo layout at once, the current ones lit (no cycling).
## Pressing a lit tile again locks that projection and layout for unnamed new files (a lock on
## the corner of both); pressing a locked one again unlocks.
func _draw_modes() -> void:
	_lit_modes = {}
	var half_choices := _supports_half_layouts()
	var fixed := bool(_state.get("spatial_video", false))
	var lock: Dictionary = _state.get("mode_lock", {})
	var locked := {}
	if not fixed and not lock.is_empty():
		locked[MODE_PROJECTION + int(lock.geometry)] = true
		locked[MODE_STEREO + (3 if lock.depth and not half_choices else [0, 1, 4, 5, 6][int(lock.layout)])] = true
	var fisheye := not fixed and int(_state.get("geometry", 0)) == 2
	# The lens row sits under the layouts: the panel rises to clear the floating round buttons.
	var top := 0.61 if fisheye else 0.47
	if half_choices: top = 0.465 if fisheye else 0.365
	# Fisheye adds a row of lens angles under the layouts.
	var height := (0.33 if fisheye else 0.24) if half_choices else (0.5 if fisheye else 0.36)
	var centre_y := (0.44 if fisheye else 0.385) if half_choices else top - (0.07 if fisheye else 0.0)
	if fixed:
		height += 0.08
		centre_y += 0.04
	var panel := _quad(Vector2(1.06, height), Vector3(0, centre_y, 0.001), Color(PANEL, 0.94), 10)
	_pointer_panels.append(panel)
	panel.material_override.set_shader_parameter("corner_radius", 0.04)
	add_child(panel)
	_decorations.append(panel)
	if fixed:
		var badge := _label(I18n.t("Spatial video") + " · MV-HEVC", Vector3(-0.48, top + 0.185, 0.006), 19)
		badge.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		badge.modulate = ACCENT
		var reason := _label(I18n.t("Mode fixed"), Vector3(0.48, top + 0.185, 0.006), 17)
		reason.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		reason.modulate = MUTED
		var reason_width := text_width(reason.text, 17)
		_icon("lock", Vector3(0.48 - reason_width - 0.025, top + 0.185, 0.006), 0.028, MUTED)
	var projection := 0 if fixed else int(_state.get("geometry", 0))
	var names := ["Flat", "180°", "Fisheye", "360°"]
	var icons := ["screen", "dome", "fisheye", "panorama"]
	var projection_order := [0, 1, 3, 2]
	for column in projection_order.size():
		var g: int = projection_order[column]
		_mode_tile(MODE_PROJECTION + g, I18n.t(names[g]), icons[g], Vector2(-0.3 + column * 0.2, top + 0.075), projection == g, not fixed)
	var stereo: bool = fixed or _state.get("stereo", false)
	var depth: bool = _state.get("depth_requested", false)
	var tb: bool = stereo and _state.get("top_bottom", false)
	var half_layout: bool = stereo and _state.get("stereo_half", false)
	var layouts_y := top - (0.04 if half_choices else 0.09)
	_mode_tile(MODE_STEREO, "2D", "screen", Vector2(-0.4, layouts_y), not stereo and not depth, not fixed)
	_mode_tile(MODE_STEREO + 1, I18n.t("Native 3D" if fixed else "3D SBS"), "stereo", Vector2(-0.2, layouts_y), fixed or (stereo and not tb and not half_layout), not fixed)
	_mode_tile(MODE_STEREO + 4, I18n.t("3D TB"), "stacked", Vector2(0.2 if half_choices else 0, layouts_y), not fixed and tb and not half_layout, not fixed)
	if half_choices:
		_mode_tile(MODE_STEREO + 5, I18n.t("Half SBS"), "stereo", Vector2(0, layouts_y), not fixed and stereo and not tb and half_layout, not fixed)
		_mode_tile(MODE_STEREO + 6, I18n.t("Half TB"), "stacked", Vector2(0.4, layouts_y), not fixed and tb and half_layout, not fixed)
	var controls_y := top - (0.15 if half_choices else 0.09)
	# Photos retain their existing controls; video depth is on the bar, eye order in Settings.
	if not half_choices:
		_mode_tile(MODE_STEREO + 3, I18n.t("Auto 3D"), "depth", Vector2(0.2, controls_y), depth, not stereo and projection == 0)
		_mode_tile(MODE_STEREO + 2, _caption("eyes"), "eyes", Vector2(0.4, controls_y), false, stereo)
	if fisheye:
		var lens_y := layouts_y - 0.11 if half_choices else controls_y - 0.145
		var lens_height := 0.06 if half_choices else 0.08
		for i in LENS_FOVS.size():
			_button(MODE_LENS + i, "%d°" % LENS_FOVS[i], Vector2(-0.4 + i * 0.2, lens_y), Vector2(0.18, lens_height))
			if int(_state.get("fisheye_fov", 180)) == LENS_FOVS[i]:
				_buttons.back().base_color = SELECTED
		# The video's own mask (official packed Alpha): independent of the lens angle.
		_button(MODE_PACKED, "", Vector2(0.4, lens_y), Vector2(0.18, lens_height), bool(_state.get("packed_mask_available", false)), "packed_mask")
		_tips[MODE_PACKED] = I18n.t("Use the video's own Alpha mask")
		if _state.get("packed_mask", false):
			_buttons.back().base_color = SELECTED
	for button in _buttons:
		if locked.has(button.target):
			var half: Vector2 = button.rect.size / 2
			_icon("lock", Vector3(half.x - 0.022, half.y - 0.022, 0.005), 0.026, ACCENT, button.node)

func _mode_tile(target: int, text: String, icon: String, centre: Vector2, current: bool, enabled: bool = true) -> void:
	var height := (0.08 if target in [MODE_STEREO + 2, MODE_STEREO + 3] else 0.1) if _supports_half_layouts() else 0.13
	_button(target, text, centre, Vector2(0.18, height), enabled, icon)
	if current:
		_buttons.back().base_color = SELECTED
		if enabled:
			_lit_modes[target] = true
		else:
			_buttons.back()["fixed_current"] = true
			_buttons.back().node.get_child(0).modulate = _buttons.back().foreground
			_buttons.back().node.get_child(1).material_override.albedo_color = ACCENT

## "More": picture, sound and info settings; the arrow returns to the bar.
func _draw_panel() -> void:
	_settings_drawn = _settings_key()
	if section == 2 and not str(_state.get("error", "")).is_empty():
		_draw_failure_panel()
		return
	var operations: Array = OPERATIONS[section]
	var tiles: Array = []
	for index in operations.size():
		var operation: String = operations[index]
		if not _cast_allowed(operation): continue
		if section == 2 and not str(_state.get("error", "")).is_empty(): continue
		if operation == "stereo_view" and not _state.get("stereo", false): continue
		tiles.append(index)
	var tile_rows := ceili(tiles.size() / 2.0)
	var alpha_fps: bool = section == 1 and _enabled("alpha")
	var height := 0.12 + tile_rows * 0.105 + (0.26 + ((0.085 + (0.27 if _alpha_expanded else 0.0)) if alpha_fps else 0.0) if section == 1 else 0.36)
	if alpha_fps and _alpha_expanded and _state.get("portrait_requested", false): height += 0.17
	if alpha_fps and _state.get("portrait_requested", false): height += 0.17
	var top := _settings_frame(height)
	_draw_settings_tabs(top - 0.055)
	var y := top - 0.165
	for shown in tiles.size():
		var index: int = tiles[shown]
		var operation: String = operations[index]
		_button(SETTINGS_TILE + index, _caption(operation), Vector2(-0.26 if shown % 2 == 0 else 0.26,
			y - (shown / 2) * 0.105), Vector2(0.50, 0.09), _enabled(operation))
		if section != 1:
			set_label_size(_buttons.back().node.get_child(0), TEXT_BODY)
			continue
		var node: MeshInstance3D = _buttons.back().node
		var value: Label3D = node.get_child(0)
		set_label_size(value, TEXT_BODY)
		value.position = Vector3(-0.155, -0.017, 0.004)
		value.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		var heading := _label(I18n.t(HEADINGS[index]), Vector3(-0.155, 0.02, 0.004), TEXT_AUX, node)
		heading.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		heading.modulate = MUTED
		_icon(SETTING_ICONS[index], Vector3(-0.205, 0, 0.004), 0.034, MUTED, node)
		var choice: Dictionary = _setting_choices(operation)
		if not choice.is_empty():
			_buttons.back().enabled = false
			value.text = ""
			choices.field(node, choice, Vector2(0.055, -0.017), 0.36, 0.04)
	y -= tile_rows * 0.105 + 0.02
	if section == 1:
		if _cast_allowed("playback_speed"):
			_adjustment_row(453, "playback_speed", "Playback speed", Vector3(0.25, 3.0, 0.05), y)
			_inline_reset(SPEED_RESET, "Restore 1×", "playback_speed", 1.0, y)
			_slider_tick(453, 1.0, "1×", y)
		if alpha_fps:
			y -= 0.085
			_alpha_group_header(y)
		if alpha_fps and _state.get("portrait_requested", false):
			y -= 0.085
			_adjustment_row(457, "portrait_distance", "2D portrait passthrough distance", Vector3(Surface.DISTANCE_LIMITS.x, Surface.DISTANCE_LIMITS.y, 0.1), y)
			y -= 0.085
			_adjustment_row(PORTRAIT_SIZE, "portrait_scale", "2D portrait passthrough size", Vector3(Surface.SCALE_LIMITS.x * 100, Surface.SCALE_LIMITS.y * 100, 5), y)
		if alpha_fps and _alpha_expanded:
			y -= 0.085
			_adjustment_row(454, "alpha_fps", "Alpha passthrough FPS limit", Vector3(10, 40, 1), y)
			_slider_tick(454, 30, "30", y)
			var hint := _label(I18n.t("Headset performance limits keep the cut-out a little behind the picture"), Vector3(-0.50, y - 0.038, 0.004), 12)
			hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
			hint.modulate = MUTED
			y -= 0.015
			y -= 0.085
			_adjustment_row(455, "alpha_feather", "Alpha feather", Vector3(0, 100, 1), y)
			y -= 0.085
			_adjustment_row(456, "alpha_shrink", "Alpha edge shrink", Vector3(0, 100, 1), y)
			if _state.get("portrait_requested", false):
				y -= 0.085
				var anchor := _label(I18n.t("Automatic distance"), Vector3(-0.50, y, 0.004), TEXT_BODY)
				anchor.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
				choices.field(null, {"key": "portrait_auto", "value": _state.get("portrait_auto", false),
					"choices": [{"value": false, "label": "Off"}, {"value": true, "label": "On"}]}, Vector2(0.21, y), 0.46, 0.05)
				y -= 0.085
				var detail := _label(I18n.t("Detailed depth"), Vector3(-0.50, y, 0.004), TEXT_BODY)
				detail.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
				choices.field(null, {"key": "portrait_enhanced", "value": _state.get("portrait_enhanced", false),
					"choices": [{"value": false, "label": "Off"}, {"value": true, "label": "On"}]}, Vector2(0.21, y), 0.46, 0.05)
		y -= 0.085
		var fps := _label(I18n.t("Show FPS"), Vector3(-0.50, y, 0.004), TEXT_BODY)
		fps.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		choices.field(null, {"key": "show_fps", "value": _state.get("show_fps", false),
			"choices": [{"value": false, "label": "Off"}, {"value": true, "label": "On"}]}, Vector2(0.21, y), 0.46, 0.05)
		_refresh_adjustments()
	_panel_status = _label(_status_text(), Vector3(0, POPUP_BOTTOM + 0.03, 0.004), TEXT_AUX)
	_panel_status.modulate = MUTED
	if section == 2:
		_info = _label(_info_text(), Vector3(0, y - 0.14, 0.004), 16)
		_info.width = 900
		_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		if not str(_state.get("error", "")).is_empty():
			set_label_size(_info, 19)
	choices.finish()

func _draw_failure_panel() -> void:
	_settings_drawn = _settings_key()
	var identity := str([_state.get("source_uri", ""), _state.get("error", ""), _state.get("error_report", {})])
	if identity != _error_identity: _error_details_open = false
	_error_identity = identity
	var summary := _info_text()
	var detail := PlaybackErrors.details(_state.get("error_report", {}))
	var button_offset := 0.14 + _error_text_height(summary, 19) + 0.058
	var detail_offset := button_offset + 0.058
	var height := detail_offset + _error_text_height(detail, 14) + 0.055 if _error_details_open else button_offset + 0.093
	var top := _settings_frame(height)
	_label(I18n.t("Playback failed"), Vector3(0, top - 0.055, 0.004), 19)
	_glyph(SETTINGS_CLOSE, "close", Vector2(0.47, top - 0.055), 0.055, true, I18n.t("Close"))
	_info = _label(summary, Vector3(-0.49, top - 0.14, 0.004), 19)
	_info.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	_info.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	_info.width = 0.98 / _info.pixel_size
	_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_button(ERROR_DETAILS, I18n.t("Error details") + ("  ▾" if _error_details_open else "  ▸"), Vector2(0, top - button_offset), Vector2(0.98, 0.065))
	if _error_details_open:
		var info := _label(detail, Vector3(-0.49, top - detail_offset, 0.004), 14)
		info.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		info.vertical_alignment = VERTICAL_ALIGNMENT_TOP
		info.width = 0.98 / info.pixel_size
		info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	choices.finish()

func _error_text_height(text: String, logical_size: int) -> float:
	return ui_font().get_multiline_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, 0.98 / TEXT_PIXEL_SIZE,
		logical_size * TEXT_RASTER_SCALE, -1, TextServer.BREAK_MANDATORY | TextServer.BREAK_WORD_BOUND | TextServer.BREAK_ADAPTIVE).y * TEXT_PIXEL_SIZE

func _alpha_group_header(y: float) -> void:
	_button(ALPHA_GROUP, "", Vector2(0, y), Vector2(1.02, 0.06))
	var node: MeshInstance3D = _buttons.back().node
	var title := _label(I18n.t("AI portrait passthrough (Alpha)"), Vector3(-0.50, 0, 0.004), TEXT_BODY, node)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	_icon("chevron_down" if _alpha_expanded else "next", Vector3(0.475, 0, 0.004), 0.034, MUTED, node)

func _settings_key() -> String:
	return str([_state.get("cast", {})]) + str([_state.get("source_uri", ""), _state.get("has_video", false),
		_state.get("portrait_requested", false), _state.get("portrait_auto", true), _state.get("portrait_enhanced", false),
		_state.get("playback_mode", "single"), _state.get("screen_curve", 0.0), _state.get("seek_mode", "speed"), _state.get("stereo", false), _state.get("geometry", 0),
		_state.get("show_fps", false), _state.get("viewing_eye", 0), _state.get("swap_eyes", false),
		_state.get("spatial_metadata", {}), _state.get("spatial_auto_disparity", true),
		_state.get("screen_cinema", false), _state.get("screen_scene_locked", false), _state.get("cinema_lights", "auto"),
		_state.get("error", ""), _state.get("error_report", {}), _alpha_expanded])

func _setting_choices(operation: String) -> Dictionary:
	if not _enabled(operation): return {}
	match operation:
		"seek_mode":
			return {"key": "seek_mode", "value": _state.get("seek_mode", "speed"), "choices": [
				{"value": "speed", "label": "Speed", "hint": "Faster jumps, less precise"},
				{"value": "exact", "label": "Precise", "hint": "Accurate jumps, may take longer"}]}
		"loop":
			if _state.has("cast"): return {"key": "playback_mode", "value": _state.get("playback_mode", "single"), "choices": [{"value": "single", "label": "Single video"}, {"value": "repeat_one", "label": "Repeat video"}]}
			return {"key": "playback_mode", "value": _state.get("playback_mode", "single"), "choices": [
				{"value": "single", "label": "Single video"}, {"value": "repeat_one", "label": "Repeat video"},
				{"value": "sequence", "label": "Play in order"}, {"value": "repeat_all", "label": "Repeat playlist"}]}
		"screen_curve":
			var values: Array = []
			for i in Surface.CURVES.size(): values.append({"value": Surface.CURVES[i], "label": CURVE_NAMES[i]})
			return {"key": "screen_curve", "value": _state.get("screen_curve", 0.0), "choices": values}
		"audio":
			if not _enabled("audio") or _state.get("audio_options", []).is_empty(): return {}
			return {"key": "audio_track", "value": _state.get("audio_track_id", -1), "choices": _state.get("audio_options", [])}
	return {}

func _ready() -> void:
	super()
	choices.changed.connect(func(key, value):
		if not clone_panel.sample.choose(key, value): setting_requested.emit(key, value))
	choices.previewed.connect(func(key, value): adjustment_requested.emit(key, value))

func _seek_bar(y: float) -> void:
	_button(SEEK, "", Vector2(0, y), Vector2(BAR_SEEK + 0.06, 0.05), _can_seek())
	_buttons.back().base_color = Color(TILE, 0.0) # the track itself is the visible part
	_decoration(Vector2(BAR_SEEK, 0.007), Vector2(0, y), Color(0.3, 0.35, 0.4))
	_progress = _decoration(Vector2(BAR_SEEK, 0.007), Vector2(0, y), ACCENT)
	_thumb = _decoration(Vector2(0.023, 0.023), Vector2(0, y), Color.WHITE)
	_seek_origin = _decoration(Vector2(0.006, 0.021), Vector2(0, y), MUTED)
	_seek_origin.material_override.render_priority = 14
	_progress.material_override.render_priority = 13
	_thumb.material_override.render_priority = 14
	_elapsed = _label("", Vector3(-BAR_SEEK / 2 - 0.035, y, 0.004), 16)
	_elapsed.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_duration = _label("", Vector3(BAR_SEEK / 2 + 0.035, y, 0.004), 16)
	_duration.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	_refresh_progress()

func _can_seek() -> bool:
	if not _cast_allowed("seek"): return false
	return _state.get("has_video", false) and int(_state.get("duration_ms", 0)) > 0

func _refresh_progress() -> void:
	if not is_instance_valid(_progress): return
	var duration := maxi(0, int(_state.get("duration_ms", 0)))
	var feedback: Dictionary = _state.get("seek_feedback", {})
	var position := clampi(_seek_preview if _seek_preview >= 0 else int(feedback.get("target_ms", _state.get("position_ms", 0))), 0, duration)
	var fraction := float(position) / duration if duration > 0 else 0.0
	_progress.visible = fraction > 0
	_progress.mesh.size.x = maxf(0.001, BAR_SEEK * fraction)
	_progress.position.x = -BAR_SEEK / 2 + BAR_SEEK / 2 * fraction
	_progress.material_override.set_shader_parameter("surface_size", _progress.mesh.size)
	_thumb.position.x = -BAR_SEEK / 2 + BAR_SEEK * fraction
	_thumb.visible = _can_seek()
	_elapsed.text = _time(position)
	_duration.text = I18n.t("Live") if _state.has("cast") and duration <= 0 else _time(duration) if duration > 0 else "--:--"
	_seek_origin.visible = not feedback.is_empty() and _seek_preview < 0
	if _seek_origin.visible:
		_seek_origin.position.x = -BAR_SEEK / 2 + BAR_SEEK * clampf(float(feedback.origin_ms) / maxf(1.0, duration), 0.0, 1.0)
		_seek_origin.material_override.set_shader_parameter("surface_color", Color(MUTED, float(feedback.alpha)))

func _seek_status() -> String:
	if not _favorite_notice.is_empty(): return I18n.t(_favorite_notice)
	var feedback: Dictionary = _state.get("seek_feedback", {})
	var caption := str(_state.get("loading_caption", ""))
	if feedback.is_empty(): return caption
	var text := "%s → %s   %s" % [SeekFeedback.time(feedback.origin_ms), SeekFeedback.time(feedback.target_ms), SeekFeedback.offset(feedback.delta_ms)]
	if feedback.phase == "waiting" or (_listening_preparing() and not caption.is_empty()): text += " · " + (caption if not caption.is_empty() else "…")
	return text

func _time(milliseconds: int) -> String:
	var seconds := maxi(0, milliseconds / 1000)
	return "%d:%02d:%02d" % [seconds / 3600, (seconds / 60) % 60, seconds % 60] if seconds >= 3600 else "%02d:%02d" % [seconds / 60, seconds % 60]

func _activate_hit(hit: Dictionary) -> void:
	if int(hit.target) == SEEK:
		if _can_seek():
			var fraction := clampf((float(hit.point.x) + BAR_SEEK / 2) / BAR_SEEK, 0.0, 1.0)
			seek_requested.emit(roundi(fraction * int(_state.duration_ms)))
	else:
		super._activate_hit(hit)

func _activate(target: int) -> void:
	if section == 0 and _subtitle_open and target in [SUBTITLE_GENERATE, SUBTITLE_TASK_CANCEL, SUBTITLE_TASKS]:
		setting_requested.emit("listening_generate" if target == SUBTITLE_GENERATE else ("listening_cancel" if target == SUBTITLE_TASK_CANCEL else "subtitle_tasks_open"), _state.get("subtitle_task", {}).get("id", ""))
		refresh(); return
	var cast_action := CastPanel.action(target)
	if not cast_action.is_empty(): cast_requested.emit(cast_action); return
	if target == PIP:
		if not _state.get("has_video", false) or not _state.get("pip_available", true): return
		var opened := _pip_open
		_reset_navigation(); _pip_open = not opened; refresh(); return
	if target == PIP_ADD:
		var slot := PipControls.next_slot(_state)
		if slot > 0: action_requested.emit("pip_slot_%d" % slot)
		refresh(); return
	if target > PIP_CLOSE and target <= PIP_CLOSE + 3:
		var slot := target - PIP_CLOSE
		if PipControls.active_slots(_state).has(slot): action_requested.emit("pip_slot_%d" % slot)
		refresh(); return
	if target >= PIP_COUNT and target <= PIP_COUNT + 3:
		if target == PIP_COUNT:
			_pip_open = false; action_requested.emit("pip_count_0")
		elif PipControls.active_slots(_state).has(target - PIP_COUNT): action_requested.emit("pip_slot_%d" % (target - PIP_COUNT))
		refresh(); return
	_pip_open = false
	if target == ALPHA_GROUP:
		_alpha_expanded = not _alpha_expanded; refresh(); return
	if target == SPACE_LOCK:
		action_requested.emit("space_lock"); return
	if target == WATCH:
		action_requested.emit("wrist_watch_toggle"); return
	if _adjustment == "bar_transparency" and target in [BAR_DONE, SETTINGS_CLOSE, 400]:
		_finish_adjustment(); _adjustment = ""; adjustment_committed.emit()
		action_requested.emit("bar_appearance_done"); refresh(); return
	if target == CAPTURE:
		if not _state.get("capture", {}).get("available", false): return
		_reset_navigation(); _capture_open = true; _capture_leave_ms = Time.get_ticks_msec(); refresh(); return
	if target in [CAPTURE_PICTURE, CAPTURE_RECORD]:
		action_requested.emit("capture_screenshot" if target == CAPTURE_PICTURE else "capture_record")
		refresh(); return
	if target == MUSIC_OPEN and _state.get("audio_play_during_video", false):
		action_requested.emit("music_open"); return
	if clone_panel.opened:
		if target == 107: clone_panel.close(); return
		if clone_panel.activate(target): return
		if choices.action(target): return
		return
	if _subtitle_open and target in [NARRATION_CLONE_START, NARRATION_VOICES]:
		if not _narration_on() or _state.get("narration_voice_kind", "preset") != "custom" or not _state.get("narration_clone_supported", false): return
		clone_panel.open(target == NARRATION_VOICES); return
	if CinemaFeature.enabled() and _state.get("screen_scene_locked", false):
		if target in [CINEMA_MOVE, CINEMA_HOME]:
			action_requested.emit("cinema_move" if target == CINEMA_MOVE else "cinema_home"); return
		if target in [CINEMA_LIGHT_AUTO, CINEMA_LIGHT_ON, CINEMA_LIGHT_OFF, CINEMA_LIGHT_CYCLE]:
			var modes := ["auto", "on", "off"]
			var index: int = (modes.find(str(_state.get("cinema_lights", "auto"))) + 1) % 3 if target == CINEMA_LIGHT_CYCLE else target - CINEMA_LIGHT_AUTO
			action_requested.emit("cinema_lights_" + modes[index]); return
	if target == WHISPER:
		if not _volume_hand.is_empty() or not _volume_open or not _state.get("has_video", false) or not _state.get("audio_available", false) or not _state.get("whisper_available", false): return
		whisper_requested.emit(0 if int(_state.get("audio_whisper", 0)) > 0 else 1, str(_state.get("source_uri", "")))
		refresh_values()
		return
	if target == FAVORITE:
		favorite_requested.emit(); refresh_values(); return
	if target == ERROR_OPEN and not str(_state.get("error", "")).is_empty():
		show_playback_error()
		return
	if target == SETTINGS_CLOSE and _failure_open:
		_failure_open = false; _error_details_open = false; refresh()
		return
	if target == ERROR_DETAILS and (_failure_open or section == 2) and not str(_state.get("error", "")).is_empty():
		_error_details_open = not _error_details_open
		refresh()
		return
	if _activate_footer(target): return
	if _activate_slider_reset(target): return
	if _activate_depth_reset(target): return
	if _state.get("spatial_video", false) and (target in range(MODE_PROJECTION, MODE_PROJECTION + 4) \
		or target in [MODE_STEREO, MODE_STEREO + 1, MODE_STEREO + 3, MODE_STEREO + 4, MODE_STEREO + 5, MODE_STEREO + 6] \
		or target in range(MODE_LENS, MODE_LENS + LENS_FOVS.size()) or target == MODE_PACKED): return
	if choices.action(target): return
	if target >= EYE_BUFFER_NOTE and target < EYE_BUFFER_NOTE + 1000: return
	bookmarks.reset()
	if _settings_popup() and _settings_open() and (target in [11, SETTINGS_CLOSE] or _bar_target(target) or target == MODE):
		# The bar under the popup: its settings button and close fold settings away; other
		# controls fold it away and act, like the subtitle and video mode popups.
		_finish_adjustment()
		choices.reset()
		section = 0
		_failure_open = false
		_error_details_open = false
		_adjustment = ""
		# Redraw as the bar first: choice fields keyed by section start fresh before the action.
		refresh()
		if target in [11, SETTINGS_CLOSE]:
			return
	if target in [11, 12, PLAYBACK_SETTINGS, SCREEN_SETTINGS]:
		_failure_open = false
		_error_details_open = false
		_finish_adjustment()
		choices.reset()
		_subtitle_open = false; _mode_open = false; _volume_open = false
		_close_depth_slider()
		# The bar's settings button opens Playback, where colour grading leads.
		section = 2 if target == 12 else 1
		_adjustment = "screen" if target == SCREEN_SETTINGS else ""
		refresh()
		return
	if section == 0 and disc_titles.activate(target):
		if disc_titles.opened:
			_audio_open = false; _subtitle_open = false; _mode_open = false; _volume_open = false; _volume_hand = ""
			_close_depth_slider(); choices.reset(); refresh()
		return
	if section == 0 and target == 111:
		if not _enabled("audio"): return
		_audio_open = not _audio_open; _audio_source = str(_state.get("source_uri", "")); choices.reset()
		choices.offset = 0; choices.scroll = 0.0
		_subtitle_open = false; _mode_open = false; _volume_open = false; _volume_hand = ""
		_close_depth_slider()
		refresh()
		return
	if section == 0 and _audio_open:
		if target == AUDIO_CLOSE: _audio_open = false; choices.reset(); refresh(); return
		if target in [AUDIO_UP, AUDIO_DOWN]: _scroll_audio(-4 if target == AUDIO_UP else 4); return
		if _audio_ids.has(target): setting_requested.emit("audio_track", _audio_ids[target]); refresh(); return
	if section == 0 and _subtitle_open and target in [NARRATION_RETRY, NARRATION_PREVIEW]:
		if target == NARRATION_PREVIEW: setting_requested.emit("narration_preview", true)
		else: setting_requested.emit("narration_retry", true)
		refresh(); return
	if target == SPEED_RESET and section == 1 and _adjustment.is_empty():
		adjustment_requested.emit("playback_speed", 1.0)
		adjustment_committed.emit()
		refresh_values()
		return
	if not _adjustment.is_empty():
		_activate_adjustment(target)
		return
	if section == 1 and target >= SETTINGS_TILE and target < SETTINGS_TILE + OPERATIONS[1].size() and OPERATIONS[1][target - SETTINGS_TILE] in ["color_grade", "stereo_view"]:
		if not _enabled(OPERATIONS[1][target - SETTINGS_TILE]): return
		_adjustment = OPERATIONS[1][target - SETTINGS_TILE]
		_grade_page = 0
		refresh()
		return
	if section == 0 and target == 110:
		if not _enabled("subtitles"): return
		_subtitle_open = not _subtitle_open
		_subtitle_detail = ""
		_subtitle_offset = 0
		_subtitle_files_open = false; _subtitle_files_offset = 0
		_subtitle_scroll = 0.0
		_mode_open = false
		_volume_open = false
		_volume_hand = ""
		_close_depth_slider()
		if _subtitle_open and _state.get("subtitle_files_available", false): subtitle_files_requested.emit()
		refresh()
		return
	if section == 0 and _subtitle_open:
		if target == SUBTITLE_BROWSE and _state.get("subtitle_browse_available", false):
			subtitle_browse_requested.emit(); return
		if target == SUBTITLE_CLOSE:
			_subtitle_open = false
			choices.reset()
			refresh()
			return
		if target == SUBTITLE_AUTO:
			setting_requested.emit("subtitle_auto_load", not bool(_state.get("subtitle_auto_load", true)))
			refresh()
			return
		if target in [SUBTITLE_LISTENING, SUBTITLE_NARRATION, SUBTITLE_APPEARANCE, SUBTITLE_DETAIL_CLOSE]:
			var group: String = {SUBTITLE_LISTENING: "listening", SUBTITLE_NARRATION: "narration", SUBTITLE_APPEARANCE: "appearance", SUBTITLE_DETAIL_CLOSE: ""}[target]
			if not group.is_empty() and not _subtitle_groups().any(func(item): return item.group == group and item.enabled): return
			_set_subtitle_detail("" if _subtitle_detail_group() == group else group)
			refresh(); return
		if target == SUBTITLE_FILES:
			if not _has_other_subtitles(): return
			_subtitle_files_open = not _subtitle_files_open
			_set_subtitle_detail("")
			refresh(); return
		if target == SUBTITLE_FILES_RETRY:
			subtitle_files_requested.emit(); refresh(); return
		if target in [SUBTITLE_FILES_UP, SUBTITLE_FILES_DOWN]:
			_scroll_subtitle_files(-SUBTITLE_ROWS if target == SUBTITLE_FILES_UP else SUBTITLE_ROWS); return
		if _subtitle_file_ids.has(target):
			subtitle_file_requested.emit(str(_subtitle_file_ids[target])); refresh(); return
		if target in [SUBTITLE_UP, SUBTITLE_DOWN]:
			_scroll_subtitles(-SUBTITLE_ROWS if target == SUBTITLE_UP else SUBTITLE_ROWS)
			return
		if _subtitle_ids.has(target):
			subtitle_requested.emit(int(_subtitle_ids[target]))
			refresh()
			return
		_subtitle_open = false
		refresh()
	_subtitle_open = false
	if section == 0 and target == 112:
		section = 0
		_toggle_depth_slider()
		return
	_close_depth_slider()
	if target != MODE and target != MODE_PACKED and (target < MODE_PROJECTION or target >= MODE_LENS + LENS_FOVS.size()):
		_mode_open = false
	if target != 109:
		_volume_open = false
	if target == CLOSE:
		dismiss()
	elif section == 0 and target == 109:
		_volume_open = not _volume_open
		refresh()
	elif target == MODE:
		_mode_open = not _mode_open
		refresh()
	elif _lit_modes.has(target):
		action_requested.emit("lock_mode")
		refresh()
	elif target >= MODE_PROJECTION and target < MODE_PROJECTION + 4:
		action_requested.emit("projection_%d" % (target - MODE_PROJECTION))
		refresh()
	elif target == MODE_STEREO or target == MODE_STEREO + 1:
		action_requested.emit("stereo_sbs" if target == MODE_STEREO + 1 else "stereo_2d")
		refresh()
	elif target == MODE_STEREO + 2:
		action_requested.emit("eyes")
		refresh()
	elif target == MODE_STEREO + 4:
		action_requested.emit("stereo_tb")
		refresh()
	elif target == MODE_STEREO + 5 or target == MODE_STEREO + 6:
		action_requested.emit("stereo_half_sbs" if target == MODE_STEREO + 5 else "stereo_half_tb")
		refresh()
	elif target >= MODE_LENS and target < MODE_LENS + LENS_FOVS.size():
		action_requested.emit("fov_%d" % LENS_FOVS[target - MODE_LENS])
		refresh()
	elif target == MODE_PACKED:
		action_requested.emit("packed_mask")
		refresh()
	elif target == MODE_STEREO + 3:
		if not _state.get("stereo", false):
			action_requested.emit("depth")
		refresh()
	elif _bar_target(target) or (section != 0 and target >= SETTINGS_TILE and target < SETTINGS_TILE + OPERATIONS[section].size()):
		var operation: String = OPERATIONS[0][target - 100] if _bar_target(target) else OPERATIONS[section][target - SETTINGS_TILE]
		if not _enabled(operation):
			return
		if operation == "recent":
			recent_requested.emit()
		else:
			action_requested.emit(operation)
			if section == 0 and operation == "stop":
				refresh()
			else:
				refresh_values()

## Only the compact floating row gets extra ray tolerance; meshes stay unchanged.
## Expanded music controls and panel controls keep their own tighter spacing.
## The 0.14 centre pitch leaves a 0.04 dead zone between these 0.10 hit areas.
func _expand_bar_action_hits() -> void:
	for button in _buttons:
		var node: Node3D = button.node
		if node.get_parent() != self or not is_equal_approx(node.position.y, 0.215): continue
		if not button.rect.size.is_equal_approx(Vector2(0.08, 0.08)): continue
		button.rect = Rect2(button.rect.get_center() - Vector2(0.05, 0.05), Vector2(0.10, 0.10))

func _draw_favorite(position: Vector2) -> void:
	if not favorite_provider.is_valid(): return
	var favorite: Dictionary = favorite_provider.call()
	_round(FAVORITE, "lock" if favorite.get("locked", false) else ("star_filled" if favorite.get("selected", false) else "star"), position, 0.08,
		favorite.get("enabled", false), favorite.get("selected", false), I18n.t("Unlock favorites" if favorite.get("locked", false) else ("Remove favorite" if favorite.get("selected", false) else "Add favorite")))

func _capture_key() -> String:
	var value: Dictionary = _state.get("capture", {})
	return str([value.get("available", false), value.get("ready", false), value.get("recording", false), value.get("paused", false), value.get("picture_busy", false), value.get("clip_busy", false), value.get("pip", false), _capture_open])

func _capture_popup_allowed() -> bool:
	return not _pip_open and section == 0 and _adjustment.is_empty() and not _mode_open and not _subtitle_open and not _audio_open and not disc_titles.opened and not _volume_open and not _depth_open and not bookmarks.opened and not _failure_open

func _process_capture_hover() -> void:
	if not visible: return
	var value: Dictionary = _state.get("capture", {})
	if not value.get("available", false): _capture_open = false; return
	var now := Time.get_ticks_msec()
	var hovered := _hover.values().any(func(target): return target in [CAPTURE, CAPTURE_PICTURE, CAPTURE_RECORD])
	if hovered:
		_capture_leave_ms = now
		if _capture_hover_ms == 0: _capture_hover_ms = now
	else: _capture_hover_ms = 0
	var opened: bool = _capture_popup_allowed() and (value.get("recording", false) or (hovered and now - _capture_hover_ms >= 150) or (_capture_open and now - _capture_leave_ms < 500))
	if opened != _capture_open:
		_capture_open = opened; refresh()
	if is_instance_valid(_capture_time):
		_capture_time.text = preload("res://scripts/capture_overlay.gd").clock_text(int(value.get("duration_ms", 0))) if value.get("recording", false) else (I18n.t("Saving…") if value.get("clip_busy", false) else "")

func _draw_capture_action() -> void:
	_capture_time = null
	var value: Dictionary = _state.get("capture", {})
	if not value.get("available", false): return
	var recording := bool(value.get("recording", false))
	_round(CAPTURE, "camera_recording" if recording else "camera", Vector2(0.42, 0.215), 0.08, true, recording)
	if recording: _buttons.back().node.get_child(1).material_override.albedo_color = Color(1.0, 0.30, 0.28)
	if not _capture_popup_allowed() or not (_capture_open or recording): return
	var panel := _quad(Vector2(0.25, 0.17), Vector3(0.42, 0.36, 0.001), Color(PANEL, 0.98), 10)
	add_child(panel); _decorations.append(panel); _block_rays(panel, Vector2(0.25, 0.17))
	_glyph(CAPTURE_PICTURE, "camera", Vector2(0.36, 0.33), 0.075, value.get("ready", false) and not value.get("picture_busy", false), I18n.t("Take screenshot"))
	var record_hint := "Record with picture in picture · up to 4K/30 · B to stop" if value.get("pip", false) else "Record source clip · B to stop"
	_glyph(CAPTURE_RECORD, "stop" if recording else "record", Vector2(0.48, 0.33), 0.075, recording or (value.get("ready", false) and not value.get("clip_busy", false)), I18n.t("Stop recording · B" if recording else record_hint))
	_buttons.back().node.get_child(1).material_override.albedo_color = Color(1.0, 0.30, 0.28)
	_capture_time = _label(preload("res://scripts/capture_overlay.gd").clock_text(int(value.get("duration_ms", 0))) if recording else "", Vector3(0.42, 0.41, 0.008), 16)

func show_favorite_feedback(message: String) -> void:
	_favorite_notice = message; _favorite_notice_until = Time.get_ticks_msec() + 2500
	if is_instance_valid(_status): _status.text = I18n.t(message); _status.visible = true

func _update_highlights() -> void:
	super._update_highlights()
	for button in _buttons:
		if button.get("fixed_current", false):
			button.node.material_override.set_shader_parameter("surface_color", SELECTED)
	if _depth_busy:
		_depth_busy.visible = _depth_preparing()
	if _narration_busy: _narration_busy.visible = _narration_preparing() or _listening_preparing()
	_update_subtitle_status()
	for button in _buttons:
		if button.target == 110:
			var active: bool = button.enabled and (int(_state.get("subtitle_track", 0)) != 0 or _state.get("listening_enabled", false))
			button.node.get_child(1).material_override.albedo_color = (WARNING if str(_state.get("narration_status", "")) in ["model_missing", "model_error", "timeline_error", "speech_error", "line_missing"] else ACCENT) if _narration_on() or active else (button.foreground if button.enabled else MUTED)
			if active and not _hover.values().has(button.target):
				button.node.material_override.set_shader_parameter("surface_color", SELECTED)
		if button.target == 10 + section and not _hover.values().has(button.target):
			button.node.material_override.set_shader_parameter("surface_color", Color(0.16, 0.31, 0.27))
		if button.enabled and not _hover.values().has(button.target) and button.target == 104 and _state.get("alpha_requested", false):
			button.node.material_override.set_shader_parameter("surface_color", Color(0.16, 0.31, 0.27))
		if button.enabled and not _hover.values().has(button.target) and button.target == 112 and _state.get("depth_requested", false):
			button.node.material_override.set_shader_parameter("surface_color", Color(0.16, 0.31, 0.27))
		if button.target == 111:
			button.node.get_child(1).material_override.albedo_color = ACCENT if _audio_open else (button.foreground if button.enabled else MUTED)
			if button.enabled and not _hover.values().has(button.target) and _audio_open:
				button.node.material_override.set_shader_parameter("surface_color", SELECTED)

func _narration_on() -> bool:
	return NarrationSettings.FEATURE_ENABLED and _state.get("narration_enabled", false)

func _narration_preparing() -> bool:
	return _narration_on() and str(_state.get("narration_status", "off")) in ["loading", "verifying", "model_loading", "preparing", "preview_buffering", "subtitle_loading"]

func _listening_preparing() -> bool:
	return _state.get("listening_enabled", false) and str(_state.get("listening_state", "off")) in ["preparing", "catching_up"]

func _listening_status_text() -> String:
	var caption := str(_state.get("listening_caption", ""))
	return caption if not caption.is_empty() else I18n.t(Listening.status_label(str(_state.get("listening_state", "off"))))

func _depth_preparing() -> bool:
	return _enabled("depth") and _state.get("depth_requested", false) 		and not _state.get("depth_enabled", false) and str(_state.get("depth_error", "")).is_empty()

## Rotating arc over a round icon; animated by the shader clock, so it costs no per-frame script.
func _busy_ring(parent: Node3D, diameter: float) -> MeshInstance3D:
	if not _busy_shader:
		_busy_shader = Shader.new()
		_busy_shader.code = """shader_type spatial;
render_mode unshaded, depth_draw_never, cull_disabled;
uniform vec4 tint : source_color;
void fragment() {
	vec2 p = UV * 2.0 - 1.0;
	float r = length(p);
	float lag = mod(atan(p.y, p.x) + TIME * 5.0, 6.2831853);
	float ring = smoothstep(0.78, 0.83, r) * (1.0 - smoothstep(0.93, 0.98, r));
	ALBEDO = tint.rgb;
	ALPHA = tint.a * ring * clamp(1.0 - lag / 4.2, 0.0, 1.0);
}"""
	var node := MeshInstance3D.new()
	var mesh := QuadMesh.new()
	mesh.size = Vector2.ONE * diameter * 1.15
	node.mesh = mesh
	node.position = Vector3(0, 0, 0.005)
	var material := ShaderMaterial.new()
	material.shader = _busy_shader
	material.set_shader_parameter("tint", ACCENT)
	material.render_priority = 13
	node.material_override = material
	node.visible = false
	parent.add_child(node)
	return node

func _enabled(operation: String) -> bool:
	if not _cast_allowed(operation): return false
	var has_video: bool = _state.get("has_video", false)
	match operation:
		"play", "loop", "stop": return has_video
		"previous_video", "next_video": return has_video and _state.get("has_" + operation, false)
		# The video's own mask replaces live passthrough matting: one passthrough control at a time.
		"alpha": return has_video and not _state.get("packed_mask", false) and (_state.get("spatial_video", false) or int(_state.get("geometry", 0)) in [1, 2] or (int(_state.get("geometry", 0)) == 0 and not _state.get("stereo", false)))
		"eyes", "stereo_view": return has_video and _state.get("stereo", false)
		"volume_down", "volume_up": return has_video and _state.get("audio_available", false) and _state.get("volume_writable", true)
		"mute": return has_video and _state.get("audio_available", false)
		"audio": return has_video
		"clone_voice": return has_video and _state.get("clone_voice", false)
		"depth": return has_video and not _state.get("spatial_video", false) and int(_state.get("geometry", 0)) == 0 and not _state.get("stereo", false)
		"depth_strength": return _can_depth()
		"subtitles": return has_video
		"capabilities": return _state.get("capabilities_available", false)
		"screen_curve", "screen_distance": return has_video and int(_state.get("geometry", 0)) == 0
		"subtitle_distance": return _immersive_subtitles()
	return true

func _pausable() -> bool:
	return _state.get("playing", false) and _state.get("playback_state", "") != "ended"

func _caption(operation: String) -> String:
	return I18n.t(_caption_text(operation))

## English caption; [_caption] shows it in the current language.
func _caption_text(operation: String) -> String:
	match operation:
		"open_file": return "Open"
		"recent": return "Library"
		"play": return "Pause" if _pausable() else "Play"
		# Live AI matting, unlike the video's own mask in the fisheye panel.
		"alpha": return "AI portrait passthrough"
		"previous_video": return "Previous video"
		"next_video": return "Next video"
		"loop": return {"single": "Single video", "repeat_one": "Repeat video", "sequence": "Play in order", "repeat_all": "Repeat playlist"}.get(_state.get("playback_mode", "single"), "Single video")
		"seek_mode": return "Precise" if _state.get("seek_mode", "speed") == "exact" else "Speed"
		"stop": return "Close video"
		"stereo": return ("TB" if _state.get("top_bottom", false) else "SBS") if _state.get("stereo", false) else "2D"
		"stereo_view": return StereoView.MODES[clampi(int(_state.get("viewing_eye", 0)), 0, 2)]
		"eyes":
			if _state.get("top_bottom", false): return "B / T" if _state.get("swap_eyes", false) else "T / B"
			return "R / L" if _state.get("swap_eyes", false) else "L / R"
		"projection": return str(_state.get("projection", "Flat"))
		"quality": return str(_state.get("profile", "320x320"))
		"recenter": return "Recenter"
		"volume_down": return "-10%"
		"volume_up": return "+10%"
		"mute": return "Unmute" if _state.get("muted", false) else "Mute"
		"audio": return str(_state.get("audio_track", "Auto"))
		"clone_voice": return "Dubbing"
		"depth_strength": return _depth_caption()
		"subtitles": return "Subtitles"
		"capabilities": return "Refresh device info"
		"subtitle_distance": return "%.1f m · %+.0f°" % [float(_state.get("subtitle_distance", 5.0)), float(_state.get("subtitle_position", SubtitleDepth.DEFAULT_POSITION))]
		"screen_distance": return "%.1f m" % float(_state.get("screen_distance", Surface.SCREEN_DISTANCE))
		"color_grade": return str(_state.get("color_grade", {}).get("preset", "Original"))
		"screen_curve": return CURVE_NAMES[clampi(roundi(float(_state.get("screen_curve", 0.0)) / 0.35), 0, 3)]
	return operation

func _status_text() -> String:
	if not str(_state.get("error", "")).is_empty():
		return I18n.t("Playback failed")
	if not str(_state.get("loading_caption", "")).is_empty(): return str(_state.loading_caption)
	if not _state.get("has_video", false): return I18n.t("No video selected")
	if section == 1:
		if not str(_state.get("portrait_depth_status", "")).is_empty(): return str(_state.portrait_depth_status)
		return "%d%% · %s · %s %s" % [int(_state.get("volume", 100)), I18n.t("Muted" if _state.get("muted", false) else "Sound on"),
			I18n.t("Subtitles"), _subtitle_name()]
	if _state.get("alpha_requested", false): return I18n.t("Alpha on" if _state.get("alpha_enabled", false) else "Preparing Alpha")
	if _state.get("depth_requested", false):
		if not str(_state.get("depth_error", "")).is_empty(): return I18n.t("3D unavailable")
		return I18n.t("3D on" if _state.get("depth_enabled", false) else "Preparing 3D")
	return I18n.t(str(_state.get("playback_state", "Ready")).capitalize())

func _subtitle_name() -> String:
	if _state.get("listening_enabled", false): return I18n.t("Live captions")
	return I18n.t("Off") if int(_state.get("subtitle_track", 0)) == 0 else I18n.t("On")

func _info_text() -> String:
	var failure := str(_state.get("error", ""))
	if not failure.is_empty():
		return _fit_title(str(_state.get("title", "")), "") + "\n\n" + failure
	var lines := PackedStringArray()
	lines.append(_fit_title(str(_state.get("title", I18n.t("No video selected"))), ""))
	lines.append(I18n.t("Source: %s | %s") % [str(_state.get("source_size", I18n.t("Unknown"))), I18n.t(str(_state.get("codec", "Unknown codec")))])
	lines.append(I18n.t("Time: %.1f / %.1f seconds") % [float(_state.get("position_ms", 0)) / 1000, float(_state.get("duration_ms", 0)) / 1000])
	lines.append(I18n.t("Subtitles: %s") % _subtitle_name())
	lines.append(I18n.t("XR: %s") % I18n.t(str(_state.get("xr_state", "Unavailable"))))
	if not str(_state.get("portrait_depth_status", "")).is_empty(): lines.append(str(_state.portrait_depth_status))
	if _state.get("depth_requested", false) and not str(_state.get("depth_error", "")).is_empty():
		lines.append(I18n.t("3D unavailable") + ": " + str(_state.depth_error))
	var error := str(_state.get("error", ""))
	if not error.is_empty():
		lines.append(_fit_title(error.replace("\n", " "), ""))
	for index in lines.size():
		lines[index] = _fit_title(lines[index], "")
	return "\n".join(lines)

func _finish_adjustment() -> void:
	if _adjust_hand.is_empty(): return
	_adjust_hand = ""
	_adjust_target = -1
	adjustment_committed.emit()

## Playback first: colour grading is the first thing settings shows.
func _draw_settings_tabs(y: float) -> void:
	var tabs := [{"id": PLAYBACK_SETTINGS, "text": "Playback"}, {"id": SCREEN_SETTINGS, "text": "Screen"}, {"id": 12, "text": "Info"}]
	for index in tabs.size():
		var tab: Dictionary = tabs[index]
		_button(tab.id, I18n.t(tab.text), Vector2(-0.31 + index * 0.27, y), Vector2(0.25, 0.058))
		set_label_size(_buttons.back().node.get_child(0), 18)
		if (tab.id == SCREEN_SETTINGS and _adjustment == "screen") or (tab.id == PLAYBACK_SETTINGS and section == 1 and _adjustment.is_empty()) or (tab.id == 12 and section == 2):
			_buttons.back().base_color = SELECTED
	_glyph(SETTINGS_CLOSE, "close", Vector2(0.47, y), 0.055, true, I18n.t("Close"))

func _slider_tick(target: int, value: float, label: String, y: float) -> void:
	var row: Dictionary = _adjust_rows[target]
	var x: float = row.left + inverse_lerp(row.span.x, row.span.y, value) * row.width
	_decoration(Vector2(0.003, 0.02), Vector2(x, y), Color.WHITE)
	_label(label, Vector3(x, y + 0.03, 0.004), 11)

func _draw_screen_settings() -> void:
	_settings_drawn = _settings_key()
	if _state.get("has_video", false) and int(_state.get("geometry", 0)) != 0:
		_draw_immersive_settings()
		return
	if CinemaFeature.enabled() and _state.get("screen_scene_locked", false):
		var top := _settings_frame(0.58)
		_draw_settings_tabs(top - 0.055)
		_label(I18n.t("Grand cinema"), Vector3(0, top - 0.16, 0.004), 20)
		for index in 2:
			var target: int = [CINEMA_MOVE, CINEMA_HOME][index]
			_button(target, I18n.t(["Free movement", "Return to start"][index]), Vector2(-.22 + index * .44, top - .25), Vector2(.40, .06))
			set_label_size(_buttons.back().node.get_child(0), TEXT_BODY)
			if target == CINEMA_MOVE: _tips[target] = I18n.t("Hold the right stick forward to aim, release to move. Red targets are blocked.")
		for index in 3:
			var mode: String = ["auto", "on", "off"][index]
			_button(CINEMA_LIGHT_AUTO + index, I18n.t(["Auto lights", "Lights on", "Lights off"][index]), Vector2(-.34 + index * .34, top - .35), Vector2(.31, .06))
			set_label_size(_buttons.back().node.get_child(0), TEXT_BODY)
			_buttons.back().base_color = SELECTED if _state.get("cinema_lights", "auto") == mode else TILE
		# The fixed cinema screen keeps its wall; only the picture inside it scales.
		_adjustment_row(CINEMA_PICTURE_SIZE, "cinema_picture_size", "Picture size", Vector3(40, 100, 5), top - .46)
		choices.finish()
		refresh_values()
		return
	var flat: bool = _state.get("has_video", false) and int(_state.get("geometry", 0)) == 0
	var spatial_fov: bool = flat and _state.get("spatial_video", false) and _state.get("spatial_metadata", {}).has("horizontal_fov_degrees")
	var cinema: bool = flat and _state.get("screen_cinema", false)
	var top := _settings_frame(0.24 + (0.465 if flat else 0.0) + (0.10 if cinema else 0.0) + (0.08 if spatial_fov else 0.0))
	_draw_settings_tabs(top - 0.055)
	var y := top - 0.16
	if flat:
		var cinema_title := _label(I18n.t("Cinema screen"), Vector3(-0.50, y, 0.004), TEXT_BODY)
		cinema_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		for option in [{"target": SCREEN_CINEMA_OFF, "label": "Off", "value": false}, {"target": SCREEN_CINEMA, "label": "On", "value": true}]:
			_button(option.target, I18n.t(option.label), Vector2(0.16 + (0.1685 if option.value else -0.1685), y), Vector2(0.323, 0.055))
			set_label_size(_buttons.back().node.get_child(0), TEXT_BODY)
			_buttons.back().base_color = SELECTED if cinema == option.value else TILE
			_tips[option.target] = I18n.t("Keeps the screen upright, like in a cinema. Resizing keeps its bottom edge in place; pushing or pulling changes only its distance. A ground grid appears only while resizing or moving it nearer or farther. Turn off to position the screen freely.")
		y -= 0.08
		if cinema:
			for index in ScreenPresets.ITEMS.size():
				var preset: Dictionary = ScreenPresets.ITEMS[index]
				_button(SCREEN_PRESET + index, I18n.t(preset.title) + "\n" + preset.detail, Vector2(-0.375 + index * 0.25, y), Vector2(0.235, 0.085))
				set_label_size(_buttons.back().node.get_child(0), TEXT_AUX)
				_tips[SCREEN_PRESET + index] = I18n.t("Apply size, distance and upright placement while preserving video proportions. Choose Lock current settings to make recenter restore this setup.")
			y -= 0.11
			var height_title := _label(I18n.t("Eye level"), Vector3(-0.50, y, 0.004), TEXT_BODY)
			height_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
			for index in EYE_LEVELS.size():
				_button(SCREEN_EYE_LEVEL + index, I18n.t(["Cinema view", "Centered"][index]), Vector2(0.16 + (-0.1685 if index == 0 else 0.1685), y), Vector2(0.323, 0.05))
				set_label_size(_buttons.back().node.get_child(0), TEXT_BODY)
				_tips[SCREEN_EYE_LEVEL + index] = I18n.t("Cinema view places your eyes about one-third up the screen; Centered aligns them with its center. You can also hold Grip and drag to adjust the height.")
			y -= 0.08
		_adjustment_row(450, "screen_distance", "Screen distance", Vector3(Surface.DISTANCE_LIMITS.x, Surface.DISTANCE_LIMITS.y, 0.1), y)
		y -= 0.09
		_adjustment_row(451, "screen_scale", "Screen size", Vector3(Surface.SCALE_LIMITS.x * 100, Surface.SCALE_LIMITS.y * 100, 5), y)
		_screen_measurement = _label("", Vector3(0.16, y - 0.038, 0.004), TEXT_AUX)
		_screen_measurement.modulate = MUTED
		y -= 0.035
		y -= 0.075
		for option in [{"target": SCREEN_AUTO_DEFAULT, "label": "Use latest adjustments", "locked": false}, {"target": SCREEN_SET_DEFAULT, "label": "Lock current settings", "locked": true}]:
			_button(option.target, I18n.t(option.label), Vector2(0.16 + (0.1685 if option.locked else -0.1685), y), Vector2(0.323, 0.055))
			set_label_size(_buttons.back().node.get_child(0), TEXT_BODY)
			_buttons.back().base_color = SELECTED if bool(_state.get("screen_default_locked", false)) == option.locked else TILE
		_tips[SCREEN_AUTO_DEFAULT] = I18n.t("Do not lock a default. Each adjustment becomes the latest setting. Controller recenter and player Center keep that size, distance and viewing height. This also removes any previously locked settings.")
		_tips[SCREEN_SET_DEFAULT] = I18n.t("Lock the current size, distance, cinema mode and viewing height. Controller recenter and player Center restore them after temporary adjustments. Click again to replace the locked settings with the current ones.")
		y -= 0.005
		y -= 0.09
		var title := _label(I18n.t("Screen curve"), Vector3(-0.50, y, 0.004), TEXT_BODY)
		title.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		for index in Surface.CURVES.size():
			_button(SCREEN_CURVE + index, I18n.t(CURVE_NAMES[index]), Vector2(-0.092 + index * 0.168, y), Vector2(0.156, 0.05))
			set_label_size(_buttons.back().node.get_child(0), TEXT_BODY)
			_buttons.back().base_color = SELECTED if is_equal_approx(float(_state.get("screen_curve", 0.0)), Surface.CURVES[index]) else TILE
		y -= 0.09
	if not cinema:
		_adjustment_row(452, "screen_rotation", "Screen rotation", Vector3(-90, 90, 1), y)
		_slider_tick(452, 0, "0°", y)
		_inline_reset(ROTATION_RESET, "Straighten", "screen_rotation", 0.0, y)
	else: y += 0.09
	if spatial_fov:
		_button(SPATIAL_FOV, I18n.t("Match spatial video capture FOV"), Vector2(0, y - 0.09), Vector2(0.86, 0.055), bool(_state.get("spatial_fov_available", false)))
		set_label_size(_buttons.back().node.get_child(0), TEXT_BODY)
	_refresh_adjustments()
	choices.finish()

func _draw_adjustments() -> void:
	if _adjustment == "bar_transparency":
		var top := _settings_frame(0.27)
		_label(I18n.t("Control bar transparency"), Vector3(0, top - 0.05, 0.004), TEXT_TITLE)
		_adjustment_row(BAR_TRANSPARENCY, "bar_transparency", "Transparency", Vector3(0, 80, 1), top - 0.125)
		_button(BAR_DONE, I18n.t("Done"), Vector2(0, top - 0.215), Vector2(0.24, 0.055))
		_refresh_adjustments()
		return
	if _adjustment == "screen":
		_draw_screen_settings()
		return
	if _adjustment == "stereo_view":
		_draw_stereo_view()
		return
	if _adjustment != "color_grade": return
	var keys: Array = Grade.PAGES[_grade_page]
	var top := _settings_frame(0.30 + keys.size() * 0.075 + 0.09)
	_settings_heading("Color grading", top)
	var preset_width := 1.0 / Grade.PRESETS.size()
	for i in Grade.PRESETS.size():
		_button(410 + i, I18n.t(Grade.PRESETS[i]), Vector2(-0.5 + (i + 0.5) * preset_width, top - 0.125), Vector2(preset_width - 0.02, 0.058))
		set_label_size(_buttons.back().node.get_child(0), TEXT_BODY)
		_preset_buttons[Grade.PRESETS[i]] = _buttons.back()
	for i in 3:
		_button(430 + i, I18n.t(["Basic", "RGB gain", "RGB gamma / offset"][i]), Vector2(-0.335 + i * 0.335, top - 0.195), Vector2(0.32, 0.05))
		set_label_size(_buttons.back().node.get_child(0), TEXT_BODY)
		if i == _grade_page: _buttons.back().base_color = SELECTED
	for i in keys.size():
		_adjustment_row(450 + i, keys[i], Grade.NAMES[keys[i]], Grade.limits(keys[i]), top - 0.275 - i * 0.075)
	var bottom := top - 0.275 - keys.size() * 0.075 - 0.005
	_button(GRADE_PAGE_RESET, I18n.t("Reset page"), Vector2(-0.2, bottom), Vector2(0.36, 0.055), _grade_page_needs_reset())
	set_label_size(_buttons.back().node.get_child(0), TEXT_BODY)
	_button(440, I18n.t("Reset custom"), Vector2(0.2, bottom), Vector2(0.36, 0.055))
	set_label_size(_buttons.back().node.get_child(0), TEXT_BODY)
	_refresh_adjustments()

func _draw_immersive_settings() -> void:
	var stereo: bool = _state.get("stereo", false)
	var top := _settings_frame(0.72 if stereo else 0.63)
	_draw_settings_tabs(top - 0.055)
	var y := top - 0.16
	for row in [[VR_HORIZONTAL, "view_horizontal", "Horizontal position"], [VR_VERTICAL, "view_vertical", "Vertical position"], [VR_ZOOM, "view_zoom", "Depth / zoom"]]:
		var span := Surface.ImmersiveAdjustments.limits(row[1]) * 100.0
		_adjustment_row(row[0], row[1], row[2], Vector3(span.x, span.y, 0.1), y)
		_slider_tick(row[0], 0.0, "0", y)
		y -= 0.09
	if stereo:
		_adjustment_row(ALIGNMENT_HORIZONTAL, "stereo_horizontal", "Stereo horizontal alignment", StereoView.HORIZONTAL, y)
		_horizontal_alignment_ticks(y)
		_adjust_rows[ALIGNMENT_HORIZONTAL].button.enabled = int(_state.get("viewing_eye", 0)) == 0
		y -= 0.09
	_adjustment_row(452, "screen_rotation", "Screen rotation", Vector3(-90, 90, 1), y)
	_slider_tick(452, 0.0, "0°", y)
	_inline_reset(ROTATION_RESET, "Straighten", "screen_rotation", 0.0, y)
	_button(VR_RESET, I18n.t("Reset VR adjustments"), Vector2(0, y - 0.10), Vector2(0.48, 0.055))
	set_label_size(_buttons.back().node.get_child(0), TEXT_BODY)
	_refresh_adjustments()
	choices.finish()

func _horizontal_alignment_ticks(y: float) -> void:
	for value in [StereoView.HORIZONTAL.x, 0.0, StereoView.HORIZONTAL.y]:
		_slider_tick(ALIGNMENT_HORIZONTAL, value, "%+.0f%%" % value if value != 0.0 else "0", y)

func _draw_stereo_view() -> void:
	_settings_drawn = _settings_key()
	var mode := int(_state.get("viewing_eye", 0))
	var spatial: bool = _state.get("spatial_video", false) and _state.get("spatial_metadata", {}).has("horizontal_disparity")
	var top := _settings_frame((0.70 if spatial else 0.62) if mode == 0 else 0.40)
	_settings_heading("Stereo viewing", top)
	for i in StereoView.MODES.size():
		_button(VIEWING_EYE + i, I18n.t(StereoView.MODES[i]), Vector2(-0.335 + i * 0.335, top - 0.13), Vector2(0.32, 0.065), _enabled("stereo_view"))
		set_label_size(_buttons.back().node.get_child(0), 18)
		if mode == i: _buttons.back().base_color = SELECTED
	_button(EYE_SWAP, I18n.t("Swap eyes") + "  " + _caption("eyes"), Vector2(0, top - 0.215), Vector2(0.52, 0.06), _enabled("eyes"), "eyes")
	if mode == 0:
		var title := _label(I18n.t("Stereo alignment"), Vector3(-0.50, top - 0.29, 0.004), TEXT_BODY)
		title.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		title.modulate = MUTED
		_adjustment_row(ALIGNMENT_HORIZONTAL, "stereo_horizontal", "Horizontal alignment", StereoView.HORIZONTAL, top - 0.36)
		_horizontal_alignment_ticks(top - 0.36)
		_adjustment_row(ALIGNMENT_VERTICAL, "stereo_vertical", "Vertical alignment", StereoView.VERTICAL, top - 0.45)
		_slider_tick(ALIGNMENT_VERTICAL, 0.0, "0", top - 0.45)
		_button(ALIGNMENT_RESET, I18n.t("Reset alignment"), Vector2(0, top - 0.545), Vector2(0.36, 0.055), _enabled("stereo_view"))
		set_label_size(_buttons.back().node.get_child(0), TEXT_BODY)
		if spatial:
			var enabled: bool = _state.get("spatial_auto_disparity", true)
			_button(SPATIAL_DISPARITY, I18n.t("Source disparity") + "  " + I18n.t("On" if enabled else "Off"), Vector2(0, top - 0.625), Vector2(0.56, 0.055))
			set_label_size(_buttons.back().node.get_child(0), TEXT_BODY)
			if enabled: _buttons.back().base_color = SELECTED
	else:
		var hint := _label(I18n.t("Same view in both eyes"), Vector3(0, top - 0.31, 0.004), TEXT_AUX)
		hint.modulate = MUTED
	_refresh_adjustments()

## Slider track in the settings popup: from SLIDER_LEFT, SLIDER_WIDTH wide.
const SLIDER_LEFT := 0.02
const SLIDER_WIDTH := 0.40

func _adjustment_row(target: int, key: String, title: String, span: Vector3, y: float) -> void:
	var g := _slider_geometry()
	var heading := _label(I18n.t(title), Vector3(g.title_x, y, 0.004), g.title_size)
	heading.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	if key in ["portrait_distance", "portrait_scale"] or title == "Stereo horizontal alignment":
		heading.width = 0.34 / heading.pixel_size
		heading.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	if _leaves_layer(key):
		_eye_buffer_note(target, Vector2(g.title_x + text_width(heading.text, g.title_size) + 0.026, y), null, 0.034)
	var value := _label("", Vector3(g.value_x, y, 0.004), g.value_size)
	value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	var left: float = g.left
	var width: float = g.width
	var centre := left + width / 2
	_button(target, "", Vector2(centre, y), Vector2(width + g.hit, g.height))
	_buttons.back().enabled = key == "bar_transparency" or _state.get("has_video", false)
	_buttons.back().base_color = Color(TILE, 0)
	_decoration(Vector2(width, g.thickness), Vector2(centre, y), MUTED)
	var fill := _decoration(Vector2(width, g.thickness), Vector2(centre, y), ACCENT)
	fill.material_override.render_priority = 13
	var knob := _decoration(Vector2.ONE * g.knob, Vector2(left, y), Color.WHITE)
	knob.material_override.render_priority = 14
	_adjust_rows[target] = {"key": key, "span": span, "label": value, "fill": fill, "knob": knob, "button": _buttons.back(),
		"left": left, "width": width}
	var default_value: Variant = _adjustment_default(key)
	# Rotation and speed already have named reset buttons; keep those familiar labels.
	if default_value != null and key not in ["screen_rotation", "playback_speed"]:
		_glyph(SLIDER_RESET_BASE + target, "refresh", Vector2(g.reset_x, y), g.reset_size, false, I18n.t("Reset"))
		var reset: Dictionary = _buttons.back()
		reset["reset_slider"] = target
		reset["reset_value"] = float(default_value)
		_adjust_rows[target]["reset"] = reset

## A grade value the compositor layer cannot carry: gamma and saturation, or any grade when the
## runtime lacks colour scale/bias.
func _leaves_layer(key: String) -> bool:
	if not Grade.DEFAULTS.has(key): return false
	return key in EYE_BUFFER_GRADES or not _state.get("grade_on_layer", true)

func _adjustment_default(key: String) -> Variant:
	if key == "bar_transparency": return 14.0
	if Grade.DEFAULTS.has(key): return Grade.DEFAULTS[key]
	return {"screen_distance": Surface.SCREEN_DISTANCE, "screen_scale": 100.0, "cinema_picture_size": 100.0,
		"view_horizontal": 0.0, "view_vertical": 0.0, "view_zoom": 0.0,
		"screen_rotation": 0.0, "playback_speed": 1.0, "alpha_fps": 30.0, "alpha_feather": 100.0, "alpha_shrink": 40.0,
		"stereo_horizontal": 0.0, "stereo_vertical": 0.0}.get(key)

func _activate_slider_reset(target: int) -> bool:
	for button in _buttons:
		if button.target != target or not button.has("reset_slider"): continue
		if button.enabled and _adjust_rows.has(button.reset_slider):
			_finish_adjustment()
			adjustment_requested.emit(str(_adjust_rows[button.reset_slider].key), button.reset_value)
			adjustment_committed.emit()
			refresh_values()
		return true
	return false

func _activate_depth_reset(target: int) -> bool:
	if target != DEPTH_RESET: return false
	refresh_values()
	if _can_depth() and _state.get("depth_requested", false) and _buttons.any(func(button): return button.target == target and button.enabled):
		depth_strength_requested.emit(_depth_default())
		depth_strength_committed.emit()
		refresh_values()
	return true

func _grade_page_needs_reset() -> bool:
	var values: Dictionary = _state.get("grade_values", Grade.DEFAULTS)
	return _state.get("has_video", false) and Grade.PAGES[_grade_page].any(func(key): return not is_equal_approx(float(values.get(key, Grade.DEFAULTS[key])), Grade.DEFAULTS[key]))

func _refresh_slider_resets() -> void:
	for row in _adjust_rows.values():
		if not row.has("reset"): continue
		var button: Dictionary = row.reset
		button.enabled = row.button.enabled and not is_equal_approx(float(row.get("value", button.reset_value)), button.reset_value)
		button.node.get_child(1).material_override.albedo_color = ACCENT if button.enabled else MUTED

func _inline_reset(target: int, title: String, key: String, default_value: float, y: float) -> void:
	_button(target, "", Vector2(-0.19, y), Vector2(0.17, 0.05))
	var button: Dictionary = _buttons.back()
	button["reset_key"] = key
	button["reset_value"] = default_value
	button["reset_caption"] = _fit_title(I18n.t(title), "", 0.15, TEXT_BODY)
	set_label_size(button.node.get_child(0), TEXT_BODY)
	_tips[target] = I18n.t(title)

func _refresh_spatial_fov() -> void:
	for button in _buttons:
		if button.target == SPATIAL_FOV:
			button.enabled = bool(_state.get("spatial_fov_available", false))
			button.node.get_child(0).modulate = button.foreground if button.enabled else MUTED

func _refresh_adjustments() -> void:
	_refresh_spatial_fov()
	if is_instance_valid(_screen_measurement):
		var size: Vector2 = _state.get("screen_dimensions", Vector2.ZERO)
		_screen_measurement.text = "%.2f × %.2f m" % [size.x, size.y] if size.x > 0 and size.y > 0 else ""
	for button in _buttons:
		if button.target >= SCREEN_PRESET and button.target < SCREEN_PRESET + ScreenPresets.ITEMS.size():
			button.base_color = SELECTED if _state.get("screen_preset", "") == ScreenPresets.ITEMS[button.target - SCREEN_PRESET].id else TILE
		if button.target >= SCREEN_EYE_LEVEL and button.target < SCREEN_EYE_LEVEL + EYE_LEVELS.size():
			button.base_color = SELECTED if is_equal_approx(float(_state.get("screen_eye_level", 0.5)), EYE_LEVELS[button.target - SCREEN_EYE_LEVEL]) else TILE
	var values: Dictionary = _state.get("grade_values", Grade.DEFAULTS)
	for row in _adjust_rows.values():
		var distance: bool = row.key in ["subtitle_distance", "screen_distance", "portrait_distance"]
		var position: bool = row.key == "subtitle_position"
		var defaults := {"screen_scale": 100.0, "cinema_picture_size": 100.0, "screen_rotation": 0.0, "playback_speed": 1.0, "alpha_fps": 30.0, "alpha_feather": 100.0, "alpha_shrink": 40.0, "stereo_horizontal": 0.0, "stereo_vertical": 0.0}
		defaults["bar_transparency"] = 14.0
		for key in Surface.ImmersiveAdjustments.KEYS: defaults[key] = 0.0
		defaults["portrait_scale"] = 100.0
		var value := float(_state.get(row.key, defaults[row.key])) if defaults.has(row.key) else (float(_state.get(row.key, 5.0 if row.key == "subtitle_distance" else Surface.SCREEN_DISTANCE)) if distance else (float(_state.get(row.key, SubtitleDepth.DEFAULT_POSITION)) if position else float(values.get(row.key, Grade.DEFAULTS[row.key]))))
		row["value"] = value
		var fraction := clampf((value - row.span.x) / (row.span.y - row.span.x), 0, 1)
		if row.key == "subtitle_distance": fraction = SubtitleDepth.slider_fraction(value)
		if _adjustment == "screen" and row.key in ["screen_distance", "screen_scale"]: fraction = ScreenPresets.slider_fraction(value, row.span)
		if row.key in ["portrait_distance", "portrait_scale"]: fraction = ScreenPresets.slider_fraction(value, row.span)
		row.label.text = "%.1f m" % value if distance else ("%+.0f°" % value if position else ("%d K" % value if row.key == "temperature" else ("%+.2f EV" % value if row.key == "exposure" else "%.3f" % value)))
		if row.key == "screen_distance" and value < 10: row.label.text = "%.2f m" % value
		if row.key == "portrait_distance" and value < 10: row.label.text = "%.2f m" % value
		if row.key in ["screen_scale", "cinema_picture_size", "portrait_scale"]: row.label.text = "%d%%" % roundi(value)
		elif row.key == "screen_rotation": row.label.text = "%+.0f°" % value if value != 0 else "0°"
		elif row.key == "playback_speed": row.label.text = "%.2f×" % value
		elif row.key == "alpha_fps": row.label.text = "%d FPS" % roundi(value)
		elif row.key in ["alpha_feather", "alpha_shrink", "bar_transparency"]: row.label.text = "%d%%" % roundi(value)
		elif row.key in ["stereo_horizontal", "stereo_vertical"]: row.label.text = "%+.2f%%" % value if value != 0 else "0.00%"
		elif row.key in Surface.ImmersiveAdjustments.KEYS: row.label.text = "%+.1f%%" % value if value != 0 else "0.0%"
		row.fill.visible = fraction > 0
		row.fill.mesh.size.x = maxf(0.001, fraction * row.width)
		row.fill.position.x = row.left + fraction * row.width / 2
		row.fill.material_override.set_shader_parameter("surface_size", row.fill.mesh.size)
		row.knob.position.x = row.left + fraction * row.width
	_refresh_slider_resets()
	var selected := str(_state.get("color_grade", {}).get("preset", "Original"))
	for name in _preset_buttons:
		_preset_buttons[name].base_color = SELECTED if name == selected else TILE
	for button in _buttons:
		if button.target == GRADE_PAGE_RESET:
			button.enabled = _grade_page_needs_reset()
			button.node.get_child(0).modulate = button.foreground if button.enabled else MUTED
		if not button.has("reset_key"): continue
		var shown: bool = (button.reset_key == "bar_transparency" or _state.get("has_video", false)) and not is_equal_approx(float(_state.get(button.reset_key, button.reset_value)), button.reset_value)
		button.enabled = shown
		button.node.visible = shown
		button.node.get_child(0).text = button.reset_caption if shown else ""

func _set_adjustment_at(x: float) -> void:
	if not _adjust_rows.has(_adjust_target): return
	var row: Dictionary = _adjust_rows[_adjust_target]
	var value := clampf(snappedf(lerpf(row.span.x, row.span.y, clampf((x - row.left) / row.width, 0, 1)), row.span.z), row.span.x, row.span.y)
	if row.key == "subtitle_distance": value = SubtitleDepth.slider_distance((x - row.left) / row.width)
	if _adjustment == "screen" and row.key in ["screen_distance", "screen_scale"]: value = ScreenPresets.slider_value((x - row.left) / row.width, row.span)
	if row.key in ["portrait_distance", "portrait_scale"]: value = ScreenPresets.slider_value((x - row.left) / row.width, row.span)
	if row.key == "screen_rotation" and absf(value) <= 1: value = 0.0
	if row.key == "playback_speed" and absf(value - 1.0) < 0.03: value = 1.0
	adjustment_requested.emit(row.key, value)
	refresh_values()

func _activate_adjustment(target: int) -> void:
	_finish_adjustment()
	if target == CLOSE:
		dismiss()
		return
	if target == 400:
		_adjustment = ""
	elif _adjustment == "screen" and target == VR_RESET:
		adjustment_requested.emit("immersive_reset", true)
		adjustment_committed.emit()
	elif _adjustment == "stereo_view" and _enabled("stereo_view"):
		if target >= VIEWING_EYE and target <= VIEWING_EYE + 2:
			setting_requested.emit("viewing_eye", target - VIEWING_EYE)
		elif target == EYE_SWAP:
			action_requested.emit("eyes")
		elif target == ALIGNMENT_RESET:
			adjustment_requested.emit("stereo_reset", true)
		elif target == SPATIAL_DISPARITY and _state.get("spatial_video", false):
			setting_requested.emit("spatial_auto_disparity", not _state.get("spatial_auto_disparity", true))
	elif _adjustment == "screen" and target >= SCREEN_CURVE and target < SCREEN_CURVE + Surface.CURVES.size() and _enabled("screen_curve"):
		setting_requested.emit("screen_curve", Surface.CURVES[target - SCREEN_CURVE])
	elif _adjustment == "screen" and target >= SCREEN_PRESET and target < SCREEN_PRESET + ScreenPresets.ITEMS.size() and _state.get("screen_cinema", false) and _state.get("has_video", false) and int(_state.get("geometry", 0)) == 0:
		adjustment_requested.emit("screen_preset", ScreenPresets.ITEMS[target - SCREEN_PRESET].id)
	elif _adjustment == "screen" and target >= SCREEN_EYE_LEVEL and target < SCREEN_EYE_LEVEL + EYE_LEVELS.size() and _state.get("screen_cinema", false):
		adjustment_requested.emit("screen_eye_level", EYE_LEVELS[target - SCREEN_EYE_LEVEL])
	elif _adjustment == "screen" and target in [SCREEN_CINEMA, SCREEN_CINEMA_OFF] and _state.get("has_video", false) and int(_state.get("geometry", 0)) == 0:
		if (target == SCREEN_CINEMA) != bool(_state.get("screen_cinema", false)):
			adjustment_requested.emit("screen_cinema", target == SCREEN_CINEMA)
	elif _adjustment == "screen" and target in [SCREEN_SET_DEFAULT, SCREEN_AUTO_DEFAULT] and _state.get("has_video", false) and int(_state.get("geometry", 0)) == 0:
		adjustment_requested.emit("screen_set_default", target == SCREEN_SET_DEFAULT)
	elif _adjustment == "screen" and target == SPATIAL_FOV and _state.get("spatial_fov_available", false):
		setting_requested.emit("spatial_match_fov", true)
	elif _adjustment == "screen" and target == ROTATION_RESET:
		adjustment_requested.emit("screen_rotation", 0.0)
		adjustment_committed.emit()
	elif _adjustment == "color_grade":
		if target >= 410 and target < 410 + Grade.PRESETS.size():
			adjustment_requested.emit("grade_preset", Grade.PRESETS[target - 410])
			adjustment_committed.emit()
		elif target >= 430 and target < 433:
			_grade_page = target - 430
		elif target == 440:
			adjustment_requested.emit("grade_reset", true)
			adjustment_committed.emit()
		elif target == GRADE_PAGE_RESET and _grade_page_needs_reset():
			adjustment_requested.emit("grade_reset_page", _grade_page)
			adjustment_committed.emit()
	refresh()
