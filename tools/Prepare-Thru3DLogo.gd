extends SceneTree

## Packaging only: keep the transparent master intact and fit it to the boot canvas.
func _initialize() -> void:
	var source := Image.load_from_file(ProjectSettings.globalize_path("res://branding/thru3d-logo-transparent.png"))
	if source == null:
		quit(1)
		return
	source.convert(Image.FORMAT_RGBA8)
	source.resize(320, roundi(320.0 * source.get_height() / source.get_width()), Image.INTERPOLATE_LANCZOS)
	var canvas := Image.create(1280, 720, false, Image.FORMAT_RGBA8)
	canvas.fill(Color.TRANSPARENT)
	canvas.blit_rect(source, Rect2i(Vector2i.ZERO, source.get_size()), (canvas.get_size() - source.get_size()) / 2)
	quit(0 if canvas.save_png("res://branding/thru3d-boot.png") == OK else 1)
