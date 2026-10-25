extends Label3D
## Head-locked loading feedback when the transport is hidden.

const Ui := preload("res://scripts/ray_menu.gd")
const Fps := preload("res://scripts/fps_overlay.gd")
const UPDATE_SECONDS := 0.2
var source: Callable
var _elapsed := 0.0

func _ready() -> void:
	position = Fps.HUD_POSITION
	pixel_size = 0.0007
	font_size = 24
	outline_size = 6
	horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	no_depth_test = true
	render_priority = 120
	outline_render_priority = 119
	modulate = Color(0.85, 0.89, 0.92, 0.85)
	refresh()

func _process(delta: float) -> void:
	_elapsed += delta
	if _elapsed >= UPDATE_SECONDS: refresh()

func refresh() -> void:
	_elapsed = 0.0
	var sample: Dictionary = source.call() if source.is_valid() else {}
	var caption := str(sample.get("caption", ""))
	visible = not caption.is_empty()
	position.y = Fps.HUD_POSITION.y - (0.035 if sample.get("fps_visible", false) else 0.0)
	if text != caption:
		font = Ui.ui_font()
		text = caption
