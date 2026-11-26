extends SceneTree
## An upright cover in the 320x180 tile: the source, cropped (default) and whole (the setting) (docs/visuals/cover-fit-20261126.png).
const Thumbnails := preload("res://scripts/thumbnail_cache.gd")
func _initialize() -> void:
	var source := Image.load_from_file(ProjectSettings.globalize_path("res://backgrounds/previews/belfast.jpg"))
	var size := source.get_size()
	var upright := source.get_region(Rect2i(size.x / 2 - size.y / 3, 0, size.y * 2 / 3, size.y))
	var old := upright.duplicate() as Image
	old.convert(Image.FORMAT_RGB8)
	var crop := Vector2i(old.get_width(), roundi(old.get_width() * 9.0 / 16.0))
	old = old.get_region(Rect2i(0, (old.get_height() - crop.y) / 2, crop.x, crop.y)); old.resize(320, 180, Image.INTERPOLATE_BILINEAR)
	Thumbnails.whole = true # the "Whole picture" setting; cropped is the default (the middle picture)
	var fresh := Thumbnails.fit(upright)
	var shown := upright.duplicate() as Image
	shown.convert(Image.FORMAT_RGB8); shown.resize(120, 180, Image.INTERPOLATE_LANCZOS)
	var sheet := Image.create(120 + 320 + 320 + 40, 180, false, Image.FORMAT_RGB8)
	sheet.fill(Color(0.12, 0.12, 0.13))
	sheet.blit_rect(shown, Rect2i(0, 0, 120, 180), Vector2i(0, 0))
	sheet.blit_rect(old, Rect2i(0, 0, 320, 180), Vector2i(140, 0))
	sheet.blit_rect(fresh, Rect2i(0, 0, 320, 180), Vector2i(480, 0))
	sheet.save_png(ProjectSettings.globalize_path("res://../../docs/visuals/cover-fit-20261126.png"))
	print("cover fit preview saved")
	quit(0)
