extends SceneTree
## Auto select finds the picture between black bars.
const Focus := preload("res://scripts/web_browser_focus.gd")
var checks := 0
var failures: Array[String] = []

func check(ok: bool, message: String, detail: Variant = null) -> void:
	checks += 1
	if not ok: failures.append(message + ("" if detail == null else ": " + str(detail)))

func _page(picture: Rect2i) -> Image:
	var image := Image.create(256, 144, false, Image.FORMAT_RGBA8)
	image.fill(Color.BLACK)
	image.fill_rect(picture, Color(0.5, 0.4, 0.3))
	return image

func _uv(pixels: Rect2i) -> Rect2:
	return Rect2(Vector2(pixels.position) / Vector2(320, 180), Vector2(pixels.size) / Vector2(320, 180))

## Five captures of a light page (sidebar, text lines) with a player whose picture changes.
## `film`: the picture inside the player (black bars around it); `partial`: only its middle moves.
func _burst(player: Rect2i, film: Rect2i, partial: bool) -> Array:
	var frames := []
	var random := RandomNumberGenerator.new(); random.seed = 7
	var picture := film if film.size.x > 0 else player
	for index in 5:
		var image := Image.create(320, 180, false, Image.FORMAT_RGBA8)
		image.fill(Color(0.96, 0.96, 0.96))
		image.fill_rect(Rect2i(250, 0, 70, 180), Color(0.9, 0.9, 0.92)) # sidebar
		for line in 6: image.fill_rect(Rect2i(256, 12 + line * 24, 50, 6), Color(0.3, 0.3, 0.3)) # text
		image.fill_rect(player, Color.BLACK)
		image.fill_rect(picture, Color(0.45, 0.5, 0.4))
		var moving := picture.grow(-picture.size.y / 4) if partial else picture
		for block in 220:
			var x := random.randi_range(moving.position.x, moving.end.x - 9)
			var y := random.randi_range(moving.position.y, moving.end.y - 7)
			image.fill_rect(Rect2i(x, y, 8, 6), Color(random.randf(), random.randf(), random.randf()))
		frames.append(image)
	return frames

func _near(a: Rect2, b: Rect2) -> bool:
	return a.position.distance_to(b.position) < 0.01 and a.size.distance_to(b.size) < 0.01

func _initialize() -> void:
	var letterbox := Focus.content_rect(_page(Rect2i(0, 18, 256, 108)))
	check(_near(letterbox, Rect2(0, 0.125, 1, 0.75)), "Letterbox bars are trimmed", letterbox)
	var pillar := Focus.content_rect(_page(Rect2i(32, 0, 192, 144)))
	check(_near(pillar, Rect2(0.125, 0, 0.75, 1)), "Pillarbox bars are trimmed", pillar)
	var window := Focus.content_rect(_page(Rect2i(40, 20, 160, 90)))
	check(_near(window, Rect2(40.0 / 256, 20.0 / 144, 160.0 / 256, 90.0 / 144)), "A picture inside a black page is found", window)
	check(Focus.valid(window), "The result can be focused")
	# A caption on the bottom bar and a dark line inside the picture do not change the box.
	var busy := _page(Rect2i(0, 18, 256, 108))
	busy.fill_rect(Rect2i(60, 134, 120, 4), Color.WHITE)
	busy.fill_rect(Rect2i(0, 70, 256, 2), Color.BLACK)
	var kept := Focus.content_rect(busy)
	check(_near(kept, Rect2(0, 0.125, 1, 0.75)), "Captions on a bar and dark lines are ignored", kept)
	var black := Image.create(256, 144, false, Image.FORMAT_RGBA8); black.fill(Color.BLACK)
	check(not Focus.valid(Focus.content_rect(black)), "A black page gives nothing")
	var full := Image.create(256, 144, false, Image.FORMAT_RGBA8); full.fill(Color.WHITE)
	check(Focus.content_rect(full).is_equal_approx(Rect2(0, 0, 1, 1)), "A page without bars is the whole page")

	# Smart select: a playing picture on an ordinary light page with a sidebar and text.
	var player := Rect2i(40, 30, 200, 112) # in a 320 x 180 capture
	var plain := _burst(player, Rect2i(), false)
	var smart := Focus.smart_rect(plain)
	check(_near(smart, _uv(player)), "The playing picture is found on a light page", smart)
	# The same player showing a film with black bars inside it: the bars are trimmed too.
	var film := Rect2i(40, 44, 200, 84)
	var barred := Focus.smart_rect(_burst(player, film, false))
	check(_near(barred, _uv(film)), "Bars inside the player are trimmed", barred)
	# Only part of the picture moves (a static background): the player's border still wins.
	var partial := Focus.smart_rect(_burst(player, Rect2i(), true))
	check(_near(partial, _uv(player)), "A partly static picture snaps to the player's border", partial)
	# Nothing moves (paused) on a black page: fall back to the black-bar search.
	var paused := Focus.smart_rect([_page(Rect2i(0, 18, 256, 108)), _page(Rect2i(0, 18, 256, 108))])
	check(_near(paused, Rect2(0, 0.125, 1, 0.75)), "A paused letterboxed picture is still found", paused)

	if failures.is_empty(): print("Browser auto select checks passed: %d" % checks)
	else:
		for failure in failures: printerr(failure)
	quit(0 if failures.is_empty() else 1)
