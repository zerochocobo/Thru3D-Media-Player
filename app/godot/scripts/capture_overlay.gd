extends "res://scripts/ray_menu.gd"
## A separate head-relative surface; it never becomes the active playback menu.
signal stop_requested
signal cancel_requested
const STOP := 1
const CANCEL := 2
var _key := ""
var _time: Label3D
var _progress: MeshInstance3D

static func saving_text(state: Dictionary) -> String:
	if state.get("export_cancelling", false): return I18n.t("Cancelling…")
	var progress := int(state.get("export_progress", -1))
	return I18n.t("Saving…") + (" %d%%" % progress if progress >= 0 else "")

func _ready() -> void:
	super()
	position = Vector3(0.24, 0.20, -1.0)
	set_scene_overlay(true)
	visible = false

func _set_backdrop(size: Vector2, centre: Vector2 = Vector2.ZERO) -> void:
	_backdrop.mesh.size = size
	_backdrop.position = Vector3(centre.x, centre.y, 0)
	_backdrop.material_override.set_shader_parameter("surface_size", size)

static func clock_text(milliseconds: int) -> String:
	var seconds := maxi(0, milliseconds / 1000)
	return "%02d:%02d:%02d" % [seconds / 3600, (seconds / 60) % 60, seconds % 60] if seconds >= 3600 else "%02d:%02d" % [seconds / 60, seconds % 60]

func sync(state: Dictionary) -> void:
	var recording := bool(state.get("recording", false))
	var saving := bool(state.get("clip_busy", false)) or bool(state.get("picture_busy", false))
	var message := str(state.get("notice", ""))
	visible = recording or saving or not message.is_empty()
	if not visible: return
	var cancellable := bool(state.get("export_cancellable", false))
	var cancelling := bool(state.get("export_cancelling", false))
	var key := str([recording, saving, state.get("paused", false), cancellable, cancelling, message, I18n.language])
	if key != _key:
		_key = key
		_clear_layout()
		_backdrop.visible = recording or saving
		_time = null
		_progress = null
		if recording or saving:
			_set_backdrop(Vector2(0.30 if recording else (0.42 if cancellable else 0.32), 0.062), Vector2.ZERO)
			var icon: String = ("pause" if state.get("paused", false) else "record") if recording else ("film_cut" if state.get("clip_busy", false) else "camera")
			_glyph(0, icon, Vector2(-0.175 if cancellable and not recording else -0.105, 0), 0.04, false)
			_buttons.back().node.get_child(1).material_override.albedo_color = Color(1.0, 0.30, 0.28) if recording else ACCENT
			_time = _label("", Vector3(-0.012, 0, 0.004), 17 if recording else 14)
			if recording: _glyph(STOP, "stop", Vector2(0.105, 0), 0.052, true, I18n.t("Stop recording · B"))
			else:
				if cancellable: _glyph(CANCEL, "close", Vector2(0.175, 0), 0.052, not cancelling, I18n.t("Cancel"))
				_decoration(Vector2(0.28, 0.003), Vector2(0, -0.022), Color(ACCENT, 0.18))
				_progress = _decoration(Vector2(0.001, 0.003), Vector2(-0.14, -0.022), ACCENT)
		if not message.is_empty():
			# Keep the full notice inside a comfortable view, above the fixed recording controls.
			var label := _label(message, Vector3(-0.08, 0.06, 0.004), 16)
			label.outline_size = 6
			label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
			label.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
			label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			label.width = 640
		apply_scene_overlay()
	if is_instance_valid(_time): _time.text = clock_text(int(state.get("duration_ms", 0))) if recording else saving_text(state)
	if is_instance_valid(_progress):
		var fraction := clampf(float(state.get("export_progress", -1)) / 100.0, 0, 1)
		_progress.visible = fraction > 0
		_progress.mesh.size.x = maxf(0.001, 0.28 * fraction)
		_progress.position.x = -0.14 + 0.14 * fraction
		_progress.material_override.set_shader_parameter("surface_size", _progress.mesh.size)

func _activate(target: int) -> void:
	if target == STOP: stop_requested.emit()
	elif target == CANCEL: cancel_requested.emit()

func update_pointer(hand: String, origin: Vector3, direction: Vector3, tracked: bool) -> void:
	# Watching a recording must not leave two permanent five-metre rays across the video.
	super(hand, origin, direction, tracked and not pointer_hit(origin, direction).is_empty())
