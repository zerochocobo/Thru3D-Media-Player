extends SceneTree

const Menu := preload("res://scripts/library_menu.gd")
const Gallery := preload("res://scripts/media_server_gallery.gd")
var failures: Array[String] = []
var checks := 0

class Platform extends "res://tests/test_media_servers.gd".Platform:
	var starts := 0
	var stops := 0
	var polls := 0
	var current := 0
	var index := 0
	var sample := ""
	var size := Vector2i(2, 2)
	var frames: Array[PackedByteArray] = []
	func media_artwork_start(path: String, edge: int) -> int:
		assert(current == 0)
		sample = path
		starts += 1
		current = starts
		index = 0
		frames.clear()
		var samples := OS.get_environment("THRU_ARTWORK_DECODED")
		if samples != "":
			var prefix := path
			if path == "png": size = Vector2i(320, 180)
			elif edge == 512:
				prefix = "webp-512"
				size = Vector2i(512, 288)
			else: size = Vector2i(640, 360)
			for frame in [0, 16]:
				frames.append(FileAccess.get_file_as_bytes(samples.path_join("%s-%d.rgba" % [prefix, frame])))
		else:
			for color in [Color.RED, Color.BLUE]:
				var image := Image.create_empty(2, 2, false, Image.FORMAT_RGBA8)
				image.fill(color)
				frames.append(image.get_data())
		return current
	func media_artwork_frame(id: int) -> String:
		assert(id == current)
		polls += 1
		return JSON.stringify({"token": index + 1, "width": size.x, "height": size.y})
	func media_artwork_pixels(_id: int, _token: int) -> PackedByteArray: return frames[index]
	func media_artwork_upload(_id: int, _token: int, _handle: int) -> bool: return false
	func media_artwork_stop(id: int) -> void:
		assert(id == current)
		stops += 1
		current = 0

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func _initialize() -> void: call_deferred("_run")

func _run() -> void:
	var platform := Platform.new()
	var menu := Menu.new()
	root.add_child(menu)
	menu.attach_platform(platform)
	menu.toggle()
	menu.section = Menu.Section.MEDIA_SERVER
	var browser = menu.server_browser
	var anim = browser.artwork
	browser.view = "home"
	browser.server = {"id": "test", "provider": "emby"}
	browser.capabilities = {"home_layout": "libraries", "artwork": true}
	var libraries := [{"id": "library1", "title": "One"}, {"id": "library2", "title": "Two"}]
	browser.home_data = {"libraries": libraries}
	var poster := ImageTexture.create_from_image(Image.create_empty(4, 4, false, Image.FORMAT_RGBA8))
	for item in libraries:
		browser.textures[browser._request_image_key(browser._image_request(item))] = poster
	menu.refresh()
	var now := Time.get_ticks_msec() + 100
	anim.tick(now)
	var before := platform.next
	var origin: Vector3 = menu.to_global(Vector3(-0.36, 0.015, 1))
	var direction: Vector3 = (menu.to_global(Vector3(-0.36, 0.015, 0)) - origin).normalized()
	menu.update_pointer("right_hand", origin, direction, true)
	check(menu._hover.get("right_hand") == Gallery.LIBRARY, "controller ray focuses the actual library card")
	anim.tick(now)
	anim.tick(now + 249)
	check(platform.next == before and platform.polls == 0, "scanning cards does not request originals")
	anim.tick(now + 250)
	check(platform.requests[platform.next].scene_id == "library1", "only focused library requested")
	platform.answer(platform.next, {"path": "png"})
	anim.tick(now + 260)
	var first: Dictionary = anim.active
	check(first.surface.material_override.get_shader_parameter("picture") == anim._texture and anim._texture != poster, "focused card binds its own animated texture")
	_check_pixels(anim, platform, "APNG first frame")
	platform.index = 1
	anim.tick(now + 300)
	_check_pixels(anim, platform, "APNG later frame")
	check(platform.frames[0] != platform.frames[1], "APNG sample advances")
	menu.refresh()
	anim.tick(now + 310)
	menu._hover["right_hand"] = Gallery.LIBRARY
	menu._update_highlights()
	anim.tick(now + 315)
	check(platform.starts == 1 and anim.active.surface.material_override.get_shader_parameter("picture") == anim._texture, "layout refresh rebinds the same session")
	first = anim.active
	menu._hover["right_hand"] = Gallery.LIBRARY + 1
	menu._update_highlights()
	anim.tick(now + 320)
	check(platform.stops == 1 and first.surface.material_override.get_shader_parameter("picture") == poster, "losing focus restores poster and closes decoder")
	anim.tick(now + 600)
	var late := platform.next
	menu._hover.clear()
	menu._update_highlights()
	anim.tick(now + 610)
	platform.answer(late, {"path": "png"})
	check(late in platform.cancelled and platform.starts == 1, "late response after blur is ignored")
	menu._hover["right_hand"] = Gallery.LIBRARY + 1
	menu._update_highlights()
	anim.tick(now + 620)
	anim.tick(now + 900)
	platform.answer(platform.next, {})
	var queried := platform.next
	menu._hover.clear(); menu._update_highlights(); anim.tick(now + 910)
	menu._hover["right_hand"] = Gallery.LIBRARY + 1
	menu._update_highlights(); anim.tick(now + 920); anim.tick(now + 1200)
	check(platform.next == queried and platform.current == 0, "confirmed still is not fetched or decoded again")
	var polls_before := platform.polls
	var began := Time.get_ticks_usec()
	for i in 10000: anim.tick(now + 1200 + i)
	print("Confirmed still, microseconds/tick: %.2f" % ((Time.get_ticks_usec() - began) / 10000.0))
	check(platform.polls == polls_before and platform.next == queried, "idle stills have zero decoder polls and network requests")
	browser.cancel()
	browser.view = "detail"
	var cover := {"id": "film", "image_type": "Backdrop", "image_index": 0, "image_tag": "v1"}
	browser.detail = {"id": "film", "title": "Film", "backdrops": [cover]}
	browser.backdrop.mode = "static"
	var wanted: Dictionary = browser.backdrop.nodes()[0]
	browser.textures[browser._request_image_key(browser._image_request(wanted))] = poster
	menu._hover.clear()
	menu.refresh()
	anim.tick(now + 1300)
	check(anim.autoplay.is_empty() and platform.current == 0, "explicit Still image preference keeps a static background")
	browser.backdrop.mode = "slideshow"; menu.refresh()
	anim.tick(now + 1310)
	anim.tick(now + 1600)
	check(platform.requests[platform.next].get("image_type") == "Backdrop", "detail requests its background without a pointer")
	platform.answer(platform.next, {"path": "webp"})
	anim.tick(now + 1660)
	check(platform.starts == 2 and browser.backdrop.surface.material_override.get_shader_parameter("picture") == anim._texture, "detail background autoplays")
	_check_pixels(anim, platform, "WebP first frame")
	platform.index = 1
	anim.tick(now + 1700)
	_check_pixels(anim, platform, "WebP later frame")
	check(platform.frames[0] != platform.frames[1], "WebP sample advances")
	var second := cover.duplicate()
	second.image_index = 1
	browser.detail.backdrops = [cover, second]
	menu.refresh()
	var other := ImageTexture.create_from_image(Image.create_empty(8, 8, false, Image.FORMAT_RGBA8))
	browser.textures[browser._request_image_key(browser._image_request({"cover_image": second.merged({"max_width": 1024})}))] = other
	browser.backdrop.elapsed = browser.backdrop.INTERVAL
	browser.backdrop.tick(0.35)
	check(browser.backdrop.surface.material_override.get_shader_parameter("upcoming") == other, "slideshow crossfades to the next poster while current artwork plays")
	browser.backdrop.tick(0.35)
	anim.tick(now + 1730)
	check(platform.current == 0 and browser.backdrop.surface.material_override.get_shader_parameter("picture") == other, "slide change stops previous animation and preserves the new background")
	browser.backdrop.mode = "off"; menu.refresh(); anim.tick(now + 1750)
	check(platform.stops == 2 and anim._texture == null, "background off releases frames")
	_test_detail_artwork(menu, platform, poster)
	menu.free()
	platform.free()
	print("Media server animation checks=%d failures=%d %s" % [checks, failures.size(), failures])
	quit(1 if failures.size() else 0)

func _check_pixels(anim: RefCounted, platform: Platform, label: String) -> void:
	var correct: bool = anim._texture != null and anim._texture.get_size() == Vector2(platform.size)
	if correct and DisplayServer.get_name() != "headless":
		var image: Image = anim._texture.get_image()
		correct = image != null and image.get_data() == platform.frames[platform.index]
	check(correct, label)

func _aim(menu: Node3D, point: Vector2) -> Array[Vector3]:
	var center := menu.to_global(Vector3(point.x, point.y, 0))
	var origin := menu.to_global(Vector3(point.x, point.y, 1))
	var direction := (center - origin).normalized()
	menu.update_pointer("right_hand", origin, direction, true)
	return [origin, direction]

func _bound_image(slot: Dictionary) -> Texture2D:
	var material: Material = slot.surface.material_override
	if material is ShaderMaterial: return material.get_shader_parameter("picture")
	return material.albedo_texture

func _check_frames(anim: RefCounted, platform: Platform, sample: String, label: String) -> void:
	platform.answer(platform.next, {"path": sample})
	var now := Time.get_ticks_msec() + 1
	anim.tick(now)
	_check_pixels(anim, platform, label + " first frame")
	platform.index = 1
	anim.tick(now + 50)
	_check_pixels(anim, platform, label + " later frame")
	check(platform.current > 0 and platform.starts == platform.stops + 1 and _bound_image(anim.active) == anim._texture,
		label + " presents on its own surface with one live decoder")

func _test_detail_artwork(menu: Node3D, platform: Platform, poster: Texture2D) -> void:
	var browser = menu.server_browser
	var anim = browser.artwork
	browser.cancel()
	browser.view = "detail"
	browser.backdrop.mode = "slideshow"
	var primary := {"id": "movie", "image_type": "Primary", "image_tag": "p"}
	var backdrop := {"id": "movie", "image_type": "Backdrop", "image_tag": "bg"}
	var part := {"id": "episode", "part_image": {"id": "episode", "image_type": "Thumb"}, "part_label": "I"}
	var person := {"id": "actor", "name": "Actor", "cover_image": {"id": "actor", "image_type": "Primary"}}
	var stills := [{"id": "movie", "image_type": "Screenshot", "image_index": 3},
		{"id": "movie", "image_type": "Screenshot", "image_index": 4},
		{"id": "movie", "image_type": "Screenshot", "image_index": 5}]
	browser.detail = {"id": "movie", "title": "Film", "cover_image": primary, "backdrops": [backdrop], "actors": [person],
		"parts": [part, {"id": "part2", "part_label": "II", "has_cover": false}], "images": stills}
	for art in [primary, backdrop, part.part_image, person.cover_image] + stills:
		for width in [512, 1024]:
			var node := {"cover_image": art.merged({"max_width": width})}
			browser.textures[browser._request_image_key(browser._image_request(node))] = poster
	menu.refresh()
	var now := Time.get_ticks_msec() + 100
	anim.tick(now); anim.tick(now + 250)
	_check_frames(anim, platform, "webp", "detail background")
	var previous: Dictionary = anim.active
	var roles := [
		[Gallery.POSTER_HOVER, Vector2(-0.335, 0.33), "movie", "png", "main poster"],
		[Gallery.PART, Vector2(0.18, browser.gallery.section_y("parts")), "episode", "webp", "episode"],
		[Gallery.ACTOR, Vector2(-0.37, browser.gallery.section_y("actors")), "actor", "png", "portrait"],
	]
	for role in roles:
		var ray := _aim(menu, role[1])
		check(menu._hover.get("right_hand") == role[0], str(role[4]) + " has a ray target")
		if role[0] == Gallery.POSTER_HOVER:
			check(menu.ray_hit(ray[0], ray[1]).get("target", Menu.NONE) == Menu.NONE, "poster preserves existing trigger behavior")
		now += 400
		var queries := platform.next
		anim.tick(now); anim.tick(now + 249)
		check(platform.next == queries and _bound_image(previous) == poster, "moving focus restores previous artwork and delays requests")
		anim.tick(now + 250)
		check(platform.requests[platform.next].scene_id == role[2], "focus resolves correct " + str(role[4]) + " original")
		_check_frames(anim, platform, role[3], role[4])
		previous = anim.active
	# Refresh clears both ray hits until the next input frame.
	menu.refresh(); anim.tick(now + 270)
	_aim(menu, roles[2][1]); anim.tick(now + 280)
	check(platform.current > 0 and platform.sample == "png" and anim.active.req.scene_id == "actor", "same portrait keeps playing across redraw with an active backdrop")
	menu.cancel_pointer("right_hand"); anim.tick(now + 290); anim.tick(now + 550)
	check(platform.current == 0 and platform.requests[platform.next].image_type == "Backdrop", "leaving artwork resumes only the current backdrop")
	_check_frames(anim, platform, "webp", "restored backdrop")

	browser.gallery.action(browser.ACTION + 55) # Scroll to the image strip.
	var shot := Vector2(-0.28, browser.gallery.section_y("images"))
	var shot_ray := _aim(menu, shot)
	now += 900
	anim.tick(now); anim.tick(now + 250)
	check(menu._hover.get("right_hand") == Gallery.PHOTO and platform.requests[platform.next].image_index == 3, "screenshot card uses its server image index")
	_check_frames(anim, platform, "webp", "screenshot thumbnail")
	menu.press_pointer("right_hand", shot_ray[0], shot_ray[1], true)
	menu.release_pointer("right_hand", shot_ray[0], shot_ray[1], true)
	menu.cancel_pointer("right_hand"); anim.tick(now + 300)
	check(browser.view == "picture" and platform.current == 0 and platform.requests[platform.next].image_index == 3, "opening a screenshot starts the full image without hovering")
	_check_frames(anim, platform, "webp", "open WebP")
	browser.gallery.action(browser.ACTION + 40); anim.tick(now + 330)
	check(platform.current == 0 and platform.requests[platform.next].image_index == 4, "next picture stops the preceding image")
	_check_frames(anim, platform, "png", "open APNG")
	browser.gallery.action(browser.ACTION + 40); anim.tick(now + 340)
	var stale := platform.next
	browser.gallery.action(browser.ACTION + 39); anim.tick(now + 341)
	var current_request := platform.next
	platform.answer(stale, {"path": "webp"})
	check(stale in platform.cancelled and current_request != stale and platform.current == 0,
		"a late large image cannot cover the current picture after paging")
	platform.answer(current_request, {"path": "png"}); anim.tick(now + 342)
	check(anim.active.req.image_index == 4 and platform.sample == "png" and platform.current > 0,
		"paging back presents only the currently selected image")
	browser.gallery.action(browser.ACTION + 40); anim.tick(now + 343)
	platform.answer(platform.next, {}) # Server supplied a single frame.
	var queries := platform.next
	var polls := platform.polls
	var began := Time.get_ticks_usec()
	for i in 10000: anim.tick(now + 350 + i)
	print("Static open artwork, microseconds/tick: %.2f" % ((Time.get_ticks_usec() - began) / 10000.0))
	check(platform.current == 0 and _bound_image(anim.active) == poster and platform.polls == polls and platform.next == queries, "static full image keeps its original texture with no further requests or polls")
	browser.back(); _aim(menu, shot + Vector2(0.86, 0)); anim.tick(now + 400); anim.tick(now + 700)
	check(browser.view == "detail" and anim.active.req.image_index == 5 and platform.next == queries and platform.current == 0, "return to the confirmed static thumbnail reuses the original probe")
	_aim(menu, shot); anim.tick(now + 800); anim.tick(now + 1050)
	var late := platform.next
	browser.back(); platform.answer(late, {"path": "webp"})
	check(late in platform.cancelled and platform.current == 0, "late image response cannot play after navigation")

	# Providers without a gallery have a separate poster layout.
	browser.cancel(); browser.view = "detail"; browser.capabilities = {}
	browser.detail = {"id": "simple", "title": "Film", "has_cover": true}
	browser.textures[browser._request_image_key({"scene_id": "simple"})] = poster
	menu.refresh()
	_aim(menu, Vector2(-0.30, -0.035)); anim.tick(now + 1100); anim.tick(now + 1350)
	check(menu._hover.get("right_hand") == Gallery.POSTER_HOVER and platform.requests[platform.next].scene_id == "simple",
		"simple detail layout uses the same hover-only poster behavior")
	_check_frames(anim, platform, "webp", "simple detail poster")
