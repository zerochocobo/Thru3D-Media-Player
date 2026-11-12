extends RefCounted
## Browser preferences are independent of per-file player settings.
const Strength := preload("res://scripts/depth_strength.gd")
const Position := preload("res://scripts/depth_position.gd")
var enabled := false
var matte := false
var strength := Strength.VIDEO_DEFAULT
var position := 0.0
var render_mode := "stretch"
var auto_3d_hidden := false
## Passthrough relighting from the page (shared by every window). Not saved: like person
## passthrough (matte) it is off whenever the app opens.
var relight := false
var state := ""
var error := ""
var config_path := "user://browser_depth.cfg"

func load_preferences() -> void:
	var config := ConfigFile.new()
	if config.load(config_path) != OK: return
	auto_3d_hidden = bool(config.get_value("depth", "auto_3d_hidden", false))
	var stored: Variant = config.get_value("depth", "strength", strength)
	if stored is float or stored is int: strength = Strength.remembered(float(stored), Strength.VIDEO_MAX, Strength.VIDEO_DEFAULT)
	position = Position.normalize(config.get_value("depth", "position", position))
	var mode: Variant = config.get_value("depth", "render_mode", render_mode)
	if mode in ["stretch", "fill"]: render_mode = mode

func change(key: String, value: Variant) -> void:
	if key == "strength": strength = Strength.clamp_value(float(value), Strength.VIDEO_MAX)
	elif key == "position": position = Position.normalize(value)
	elif key == "render_mode" and value in ["stretch", "fill"]: render_mode = value
	elif key == "matte": matte = bool(value)
	elif key == "auto_3d_hidden": auto_3d_hidden = bool(value)
	elif key == "relight": relight = bool(value)
	var config := ConfigFile.new()
	config.set_value("depth", "strength", strength)
	config.set_value("depth", "position", position)
	config.set_value("depth", "render_mode", render_mode)
	config.set_value("depth", "auto_3d_hidden", auto_3d_hidden)
	config.save(config_path)

func rows() -> Array:
	return [{"key": "strength", "value": strength * 100.0, "slider": true,
		"span": Vector3(0, 200, 1), "unit": "%", "decimals": 0, "reset_value": 50.0}, Position.row(position, "position"),
		{"key": "render_mode", "value": render_mode, "choices": [{"value": "stretch", "label": "Stretch edges"}, {"value": "fill", "label": "Fill gaps"}]},
		{"key": "matte", "value": matte, "choices": [{"value": false, "label": "Off"}, {"value": true, "label": "On"}]}]
