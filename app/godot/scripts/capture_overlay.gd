extends "res://scripts/ray_menu.gd"
## A separate head-relative surface; it never becomes the active playback menu.
signal stop_requested
const STOP := 1
var _key := ""
var _time: Label3D

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
	var key := str([recording, saving, state.get("paused", false), message, I18n.language])
	if key != _key:
		_key = key
		_clear_layout()
		_backdrop.visible = recording or saving
		_time = null
		if recording or saving:
			_set_backdrop(Vector2(0.30 if recording else 0.32, 0.062), Vector2.ZERO)
			_glyph(0, "pause" if state.get("paused", false) else "record", Vector2(-0.105, 0), 0.04, false)
			_buttons.back().node.get_child(1).material_override.albedo_color = Color(1.0, 0.30, 0.28)
			_time = _label("", Vector3(-0.012, 0, 0.004), 17)
			if recording: _glyph(STOP, "stop", Vector2(0.105, 0), 0.052, true, I18n.t("Stop recording · B"))
		if not message.is_empty():
			var label := _label(message, Vector3(-0.24, -0.10, 0.004), 16)
			label.outline_size = 6
		apply_scene_overlay()
	if is_instance_valid(_time): _time.text = clock_text(int(state.get("duration_ms", 0))) if recording else I18n.t("Saving…")

func _activate(target: int) -> void:
	if target == STOP: stop_requested.emit()

func update_pointer(hand: String, origin: Vector3, direction: Vector3, tracked: bool) -> void:
	# Watching a recording must not leave two permanent five-metre rays across the video.
	super(hand, origin, direction, tracked and not pointer_hit(origin, direction).is_empty())
