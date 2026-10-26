extends Node3D
signal visual_changed
## Brand, headset battery and clock in an equal-height footer card. Reads the platform's
## device_status() itself; without one (desktop preview) only the clock shows.

const Menu := preload("res://scripts/ray_menu.gd")
const Icons := preload("res://scripts/menu_icons.gd")
const I18n := preload("res://scripts/i18n.gd")
const Methods := preload("res://scripts/platform_methods.gd")
const HEIGHT := 0.09
const WIDTH := 0.30
const STATUS_Y := -0.021
const BRAND_Y := 0.020
const BRAND_ICON_HEIGHT := 0.032
const GRAY_ICON := preload("res://branding/thru3d-icon-gray.png")
const ICON := 0.036
const FONT_SIZE := 16
const LOW := 20
const LOW_COLOR := Color(1.0, 0.42, 0.38)
const POWER_COLOR := Color(1.0, 0.76, 0.36)
const POLL_MS := 1000

## -> {"level": 0..100 or -1, "charging", "plugged", "clock24"}; tests inject one, otherwise the QuestPlayer singleton.
var status_provider: Callable
## -> {"hour", "minute"}; tests pin the clock.
var clock_provider: Callable = Time.get_time_dict_from_system
## Reserve the footer's information slot so battery/clock changes cannot move controls.
var minimum_width := 0.0
var _status: Dictionary = {}
var _polled_ms := -POLL_MS
var _shown := ""
var _pill: MeshInstance3D
var _battery: MeshInstance3D
var _fill: MeshInstance3D
var _bolt: MeshInstance3D
var _label: Label3D
var _brand_icon: MeshInstance3D
var _wordmark: Label3D
var _domain: Label3D
var _brand_width := 0.0

func _ready() -> void:
	if not status_provider.is_valid() and Engine.has_singleton("QuestPlayer"):
		var plugin := Engine.get_singleton("QuestPlayer")
		if Methods.supports(plugin, "device_status"):
			status_provider = func() -> Dictionary:
				var parsed: Variant = JSON.parse_string(str(plugin.device_status()))
				return parsed if parsed is Dictionary else {}
	_pill = _quad(Vector2(0.2, HEIGHT), Vector3.ZERO, Color(Menu.PANEL, 0.86), 10)
	_pill.material_override.set_shader_parameter("corner_radius", 0.022)
	_brand_icon = _icon("brand", Color.WHITE)
	_wordmark = _brand_label("Thru3D", 18, Color(0.87, 0.92, 0.94))
	_domain = _brand_label(".com", 14, Color(0.66, 0.73, 0.78))
	_battery = _icon("battery", Color(0.93, 0.95, 0.98))
	# Inside of the battery outline (icon units 8.5..15.5 x 5.5..20.5 of 24), filled from the bottom.
	_fill = _quad(Vector2(ICON * 7.0 / 24, ICON * 15.0 / 24), Vector3.ZERO, Color.WHITE, 12)
	_fill.material_override.set_shader_parameter("corner_radius", 0.002)
	_bolt = _icon("bolt", Menu.ACCENT)
	_label = Label3D.new()
	_label.font = Menu.ui_font()
	Menu.set_label_size(_label, FONT_SIZE)
	_label.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	_label.no_depth_test = false
	_label.render_priority = 12
	_label.outline_size = 0
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	add_child(_label)
	refresh(true)

func _process(_delta: float) -> void:
	if is_visible_in_tree():
		refresh()

## Polls the battery once a second; redraws on clock, level or power-state changes.
func refresh(force: bool = false) -> void:
	var now := Time.get_ticks_msec()
	if force or now - _polled_ms >= POLL_MS:
		_polled_ms = now
		_status = status_provider.call() if status_provider.is_valid() else {}
	var level := int(_status.get("level", -1))
	var charging := bool(_status.get("charging", false))
	var plugged := bool(_status.get("plugged", charging))
	var text := ("%d%%   " % level if level >= 0 else "") + clock_text()
	var key := "%s|%d|%s|%s|%s" % [text, level, charging, plugged, I18n.language]
	if key == _shown and not force:
		return
	_shown = key
	_layout_brand()
	_label.font = Menu.ui_font()
	_label.text = text
	var has_battery := level >= 0
	_battery.visible = has_battery
	_fill.visible = has_battery and level > 0
	_bolt.visible = has_battery and (charging or plugged)
	_bolt.material_override.albedo_color = Menu.ACCENT if charging else POWER_COLOR
	var text_width := Menu.text_width(text, FONT_SIZE)
	# Leave room for the larger charging glyph, including space from the battery outline.
	var battery_slot := ICON * 0.5 if has_battery else 0.0
	var bolt_slot := ICON * 0.55 if _bolt.visible else 0.0
	var gap := 0.008 if has_battery else 0.0
	var content := battery_slot + bolt_slot + gap + text_width
	_pill.mesh.size = Vector2(maxf(maxf(WIDTH, minimum_width), maxf(content, _brand_width) + 0.032), HEIGHT)
	_pill.material_override.set_shader_parameter("surface_size", _pill.mesh.size)
	var left := -content / 2
	_battery.position = Vector3(left + battery_slot / 2, STATUS_Y, 0.002)
	_bolt.position = Vector3(left + battery_slot + bolt_slot / 2, STATUS_Y, 0.002)
	var full := ICON * 15.0 / 24
	var height := maxf(0.001, full * clampi(level, 0, 100) / 100.0)
	_fill.mesh.size = Vector2(ICON * 7.0 / 24, height)
	_fill.material_override.set_shader_parameter("surface_size", _fill.mesh.size)
	# Outline interior spans y 5.5..20.5 of 24 (top to bottom); grow upwards from the bottom.
	_fill.position = Vector3(_battery.position.x, STATUS_Y + ICON * (0.5 - 20.5 / 24) + height / 2, 0.003)
	var low := has_battery and level < LOW and not charging
	var foreground := Color(0.93, 0.95, 0.98)
	_fill.material_override.set_shader_parameter("surface_color", Menu.ACCENT if charging else (LOW_COLOR if low else foreground))
	_battery.material_override.albedo_color = Menu.ACCENT if charging else (LOW_COLOR if low else foreground)
	_label.position = Vector3(left + battery_slot + bolt_slot + gap, STATUS_Y, 0.003)
	visual_changed.emit()

func _brand_label(text: String, size: int, color: Color) -> Label3D:
	var label := Label3D.new()
	label.text = text; Menu.set_label_size(label, size)
	label.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	label.no_depth_test = false; label.render_priority = 12; label.outline_size = 0
	label.modulate = color; add_child(label)
	return label

func _layout_brand() -> void:
	_wordmark.font = Menu.ui_bold_font(); _domain.font = Menu.ui_font()
	var main_width := _wordmark.font.get_string_size(_wordmark.text, HORIZONTAL_ALIGNMENT_LEFT, -1, _wordmark.font_size).x * _wordmark.pixel_size
	var domain_width := _domain.font.get_string_size(_domain.text, HORIZONTAL_ALIGNMENT_LEFT, -1, _domain.font_size).x * _domain.pixel_size
	var icon_width: float = _brand_icon.mesh.size.x
	_brand_width = icon_width + 0.008 + main_width + domain_width
	var left := -_brand_width * 0.5
	_brand_icon.position = Vector3(left + icon_width * 0.5, BRAND_Y, 0.004)
	_wordmark.position = Vector3(left + icon_width + 0.008 + main_width * 0.5, BRAND_Y, 0.004)
	var main_baseline := (_wordmark.font.get_ascent(_wordmark.font_size) - _wordmark.font.get_descent(_wordmark.font_size)) * _wordmark.pixel_size * 0.5
	var domain_baseline := (_domain.font.get_ascent(_domain.font_size) - _domain.font.get_descent(_domain.font_size)) * _domain.pixel_size * 0.5
	_domain.position = Vector3(left + icon_width + 0.008 + main_width + domain_width * 0.5, BRAND_Y + domain_baseline - main_baseline, 0.004)

func clock_text() -> String:
	var now: Dictionary = clock_provider.call()
	var hour := int(now.get("hour", 0))
	var minute := int(now.get("minute", 0))
	if bool(_status.get("clock24", true)):
		return "%02d:%02d" % [hour, minute]
	var half := I18n.t("AM" if hour < 12 else "PM")
	var twelve := 12 if hour % 12 == 0 else hour % 12
	return "%s %d:%02d" % [half, twelve, minute] if I18n.language == "zh" else "%d:%02d %s" % [twelve, minute, half]

func text_snapshot() -> String:
	return _label.text

func _icon(key: String, color: Color) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	var mesh := QuadMesh.new()
	mesh.size = Vector2.ONE * ICON
	node.mesh = mesh
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	material.render_priority = 12
	material.albedo_color = color
	material.albedo_texture = GRAY_ICON if key == "brand" else Icons.texture(key)
	if key == "brand": mesh.size = Vector2(BRAND_ICON_HEIGHT * GRAY_ICON.get_width() / GRAY_ICON.get_height(), BRAND_ICON_HEIGHT)
	# Preserve the opaque amber/green core of the tiny solid power mark. Thin outline
	# icons use mip filtering; blending mip levels here can wash out the status colour.
	if key == "bolt": material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR
	node.material_override = material
	add_child(node)
	return node

func _quad(size: Vector2, location: Vector3, color: Color, priority: int) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	var mesh := QuadMesh.new()
	mesh.size = size
	node.mesh = mesh
	node.position = location
	var surface := ShaderMaterial.new()
	surface.shader = Menu.SURFACE
	surface.render_priority = priority
	surface.set_shader_parameter("surface_color", color)
	surface.set_shader_parameter("surface_size", size)
	node.material_override = surface
	add_child(node)
	return node
