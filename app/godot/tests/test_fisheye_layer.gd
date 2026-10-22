extends SceneTree
## Fisheye on the equirect picture layer: lens span and remapped picture size.
const VideoLayer := preload("res://scripts/video_layer.gd")
const Display := preload("res://scripts/mpv_video_display.gd")
var failures: Array[String] = []
var checks := 0
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)
func _initialize() -> void:
	var span180 := VideoLayer.fisheye_span(180.0)
	var span190 := VideoLayer.fisheye_span(190.0)
	check(is_equal_approx(span180.x, PI) and is_equal_approx(span180.y, PI), "180 lens spans 180 x 180")
	check(is_equal_approx(span190.x, deg_to_rad(190.0)) and is_equal_approx(span190.y, PI), "190 lens spans 190 across, 180 high (equirect limit)")
	check(is_equal_approx(VideoLayer.fisheye_span(30.0).x, deg_to_rad(90.0)), "Implausible lens widths clamp")
	var source := Vector2i(8000, 4000)
	check(Display.fisheye_picture_size(source, span180, true, false, 16.0) == Vector2i(5760, 2880), "8K side by side 180: 2880 per view at 16 px/degree")
	check(Display.fisheye_picture_size(source, span190, true, false, 16.0) == Vector2i(6080, 2880), "190 lens: wider views, same height")
	check(Display.fisheye_picture_size(Vector2i(4000, 8000), span180, true, true, 16.0) == Vector2i(2880, 5760), "Top-bottom views stack")
	check(Display.fisheye_picture_size(Vector2i(4096, 4096), span180, false, false, 16.0) == Vector2i(2880, 2880), "Mono fisheye: one view")
	check(Display.fisheye_picture_size(Vector2i(3840, 1920), span180, true, false, 16.0) == Vector2i(3840, 1920), "Never denser than the source view")
	var picture := Display.fisheye_picture_size(source, span180, true, false, 12.0)
	check(picture.x % 16 == 0 and picture.y % 16 == 0, "Sizes are multiples of 16")
	print("Fisheye layer: %d checks, %d failures" % [checks, failures.size()])
	for failure in failures: print("FAIL: " + failure)
	quit(1 if failures.size() else 0)
