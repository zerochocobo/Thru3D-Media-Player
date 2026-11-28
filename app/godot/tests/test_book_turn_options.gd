extends SceneTree
## Reading-mode options from play-testing (2026-11-28): how a leaf goes over and whether it is heard,
## narrower margins, the tome kept above the floor, the voice turning the leaf at the page break, cloned
## voices with an audition, and waving a hand across the book again and again.
const BookReader := preload("res://scripts/book_reader.gd")
const Model := preload("res://scripts/book_model.gd")
const Swipe := preload("res://scripts/memory_swipe.gd")
var checks := 0
var failures: Array[String] = []

## Stands in for the plugin: pages of read-aloud blocks, and a voice that finishes when told to.
class Platform extends Object:
	var pages := {}
	var finished := 0
	var voices_known := ["Xiaoyu", "Yuewen", "Lingyu", "Zhiming", "Junhao", "custom:01234567-89ab-cdef-0123-456789abcdef"]
	var configured := ""
	var spoken: Array = []
	func book_open(_uri: String, _style: String) -> int: return 7
	func book_close(_session: int) -> void: pass
	func book_render(_session: int, _page: int, _edge: int) -> bool: return true
	func book_text(_session: int, page: int) -> String: return JSON.stringify({"blocks": pages.get(page, [])})
	func book_reader_begin(_epoch: int) -> bool: return true
	func book_reader_page(_epoch: int, _slot: int, _session: int, _page: int, _ahead: bool) -> bool: return true
	func book_reader_next(_epoch: int, _slot: int, _id: int) -> bool: return true
	func narration_supported() -> bool: return true
	func comic_reader_configure(voice: String, _language: String) -> bool:
		if not voice in voices_known: return false
		configured = voice; return true
	func comic_reader_speed(_speed: float) -> bool: return true
	func comic_reader_speech_enabled(_on: bool) -> void: pass
	func comic_reader_read(_epoch: int, _slot: int, id: int, voice: String, _volume: float) -> bool:
		spoken.append([id, voice]); return true
	func comic_reader_status(_epoch: int, _revision: int) -> String: return JSON.stringify({"finished": finished, "speech": "speaking", "revision": 1})
	func comic_reader_stop() -> void: pass
	func comic_reader_clear() -> void: pass

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func _initialize() -> void: call_deferred("_run")

func _run() -> void:
	var settings := ConfigFile.new()
	var book: Node3D = BookReader.new()
	root.add_child(book)
	var platform := Platform.new()
	book.platform = platform

	# Margins: a narrower step came in front; an older save keeps the margin it had.
	settings.set_value("book", "measure", 0)
	book.restore_settings(settings)
	check(book.measure == 1 and is_equal_approx(book.MEASURES[book.measure], 1.0), "An older save keeps its widest-text margin")
	book.set_measure(0); book._store()
	check(int(settings.get_value("book", "margins", -1)) == 0 and book.MEASURES[0] > 1.0, "The new narrowest margin runs the text wider")
	book.restore_settings(settings)
	check(book.measure == 0, "And is read back as it was saved")

	# The paper is silent when its sound is off, and the setting is kept.
	book.set_page_sound(false)
	check(book.model.quiet and settings.get_value("book", "turn_sound", true) == false, "The page turn sound turns off")
	book.set_page_sound(true)
	check(not book.model.quiet, "And on again")

	# A low turn never stands the leaf up towards the reader.
	book.model.page_size = Vector2(0.42, 0.56)
	var tallest := func(style: int) -> float:
		book.model.turn_style = style
		var high := 0.0
		for point in book.model._bend(0.5): high = maxf(high, point.y)
		return high
	var curl: float = tallest.call(Model.CURL)
	var low: float = tallest.call(Model.LOW)
	check(curl > 0.3 and low < curl * 0.25, "A low turn rises a fraction of a curl (%.3f against %.3f)" % [low, curl])

	# Without the animation, a page asked for is there on the next frame.
	book.active = true; book.session = 7; book.count = 20; book.single = true; book.page = 4; book._arrive = 1.0
	book.set_turn_style(Model.INSTANT)
	check(int(settings.get_value("book", "turn_style", -1)) == Model.INSTANT, "The turn animation is kept")
	book.turn(1); book._process(0.016)
	check(book.page == 5 and book._turn.is_empty(), "With no animation the page changes at once")
	book.leap(15); book._process(0.016)
	check(book.page == 15 and book._riffle.is_empty(), "And a leap far ahead opens there at once")
	book.set_turn_style(Model.CURL)
	book.turn(1); book._process(0.016)
	check(book.page == 15 and not book._turn.is_empty(), "With the curl the leaf takes its time")
	book._turn = {}; book.model.turn(0.0)

	# Where it would hang reaches into the floor: nearer and smaller together, above the floor.
	book.size_step = book.DEFAULT_SIZE; book.reach_step = book.DEFAULT_REACH; book._carried = null
	var eye := 1.15
	book.head_provider = func() -> Variant: return Transform3D(Basis.IDENTITY, Vector3(0, eye, 0))
	book.floor_provider = func() -> Variant: return 0.0
	book.recenter()
	var bottom: float = (book._home * Vector3(0, -(book.model.page_size.y * 0.5 + 0.02) * book.model.scale.x, 0)).y
	check(book.fit < 1.0 and bottom >= book.FLOOR_CLEARANCE - 0.01, "Seated in a low room the tome stays above the floor (bottom %.2f, fit %.2f)" % [bottom, book.fit])
	var angle: float = book.model.scale.x / book._home.origin.distance_to(Vector3(0, eye, 0))
	book.floor_provider = func() -> Variant: return -10.0
	book.recenter()
	var full_angle: float = book.model.scale.x / book._home.origin.distance_to(Vector3(0, eye, 0))

	# The tome's middle lies on the reader's line of sight, its face square to it, level or looking down.
	for pitch in [0.0, -0.25, 0.2]:
		var head := Transform3D(Basis(Vector3.RIGHT, pitch), Vector3(0, 1.6, 0))
		book.head_provider = func() -> Variant: return head
		book.recenter()
		var to_book: Vector3 = (book._home.origin - head.origin).normalized()
		check(to_book.dot(-head.basis.z) > 0.9999, "The page's middle is where the eyes look (pitch %.2f)" % pitch)
		check(book._home.basis.z.normalized().dot(-to_book) > 0.9999, "The page faces the eyes squarely (pitch %.2f)" % pitch)
		check(absf(book._home.basis.x.normalized().y) < 0.0001, "The tome does not roll (pitch %.2f)" % pitch)
	book.head_provider = func() -> Variant: return Transform3D(Basis.IDENTITY, Vector3(0, eye, 0))
	check(is_equal_approx(book.fit, 1.0) and absf(angle - full_angle) < full_angle * 0.01, "It looks just as large as it would have hung")
	book.floor_provider = Callable()

	# The voice turns the leaf when it reaches the words carried onto the next page.
	book.set_turn_style(Model.INSTANT)
	book.go_to(2)
	platform.pages = {2: [{"id": 0, "text": "第一段。", "eligible": true}, {"id": 1, "text": "第二段前半", "eligible": true},
		{"id": 2, "text": "后半在下一页。", "eligible": true, "next": true}], 3: [{"id": 0, "text": "第三段。", "eligible": true}]}
	var narration: RefCounted = book.narration
	narration.start()
	check(narration.on and narration.cursor == 2, "Reading starts on the open page")
	for paragraph in 2:
		platform.finished += 1; narration._poll_at = 0; narration.tick()
	check(narration.index == 2 and book.page == 2, "Before the carried words, the page stays")
	book._process(0.016)
	check(book.page == 3, "As the voice reaches the carried words, the leaf turns")
	platform.finished += 1; narration._poll_at = 0; narration.tick(); book._process(0.016)
	check(narration.cursor == 3 and narration.index == 0 and book.page == 3, "Reading goes on with the next page, without a second turn")
	narration.stop()

	# Cloned voices are offered beside the presets, and an audition reads one paragraph and stops.
	var mine := "custom:01234567-89ab-cdef-0123-456789abcdef"
	narration.personal_voices = func() -> Array: return [{"id": mine, "name": "My voice"}, {"id": "../bad", "name": "x"}]
	check(narration.cloned().size() == 1, "Only well-formed cloned voices are offered")
	narration.set_voice(mine)
	check(narration.voice() == mine, "A cloned voice can be chosen for the book")
	book.go_to(2); platform.spoken.clear()
	check(narration.preview() and narration.audition and platform.configured == mine, "The audition speaks in the chosen voice")
	platform.finished += 1; narration._poll_at = 0; narration.tick()
	check(not narration.on and not narration.audition and platform.spoken.size() == 1, "It reads one paragraph and stops")
	narration.store(settings); narration.restore(settings)
	check(narration.voice() == mine, "The cloned voice is remembered")
	platform.voices_known.erase(mine)
	narration._configured = ""
	check(narration.start() and platform.configured == "Xiaoyu", "A cloned voice since deleted falls back to a preset")
	narration.stop()

	# The ring's read page lists them, with the audition beside the switch.
	book.bar.section = "read"; book.bar.open("settings")
	var targets: Array = book.bar._buttons.map(func(button): return int(button.target))
	check(book.bar.PREVIEW in targets and book.bar.CLONE_BASE in targets, "The read page offers the audition and the cloned voice")
	book.bar.section = "turn"; book.bar.refresh()
	targets = book.bar._buttons.map(func(button): return int(button.target))
	check(book.bar.SOUND_SWITCH in targets, "The turn page has the sound switch")
	book.bar.section = "book"; book.bar.refresh()
	targets = book.bar._buttons.map(func(button): return int(button.target))
	check(book.bar.STYLE_BASE in targets and book.bar.STYLE_BASE + 2 in targets, "The book page offers the three animations")
	book.bar._activate(book.bar.STYLE_BASE + 1)
	check(book.turn_style == Model.LOW, "Choosing one sets it")
	book.bar.dismiss()

	# Waving back and forth turns a page every time one way; the way back never turns one.
	var swipe: RefCounted = Swipe.new().for_book()
	var head := Transform3D(Basis.IDENTITY, Vector3(0, 1.6, 0))
	var turned: Array = []
	var x := 0.15
	var dt := 1.0 / 72.0
	for stroke in 6:
		var going_left := stroke % 2 == 0
		for i in 22:
			x += (-1.0 if going_left else 1.0) * 0.3 / 22.0
			var inputs := {"right_hand": {"source": "hand", "palm": {"tracked": true, "eligible": true, "position": Vector3(x, 1.3, -0.4), "pinched": i % 5 == 0}}}
			for action in swipe.update(inputs, true, false, head, 1.0, dt): turned.append(int(action.direction))
	check(turned == [1, 1, 1], "Three sweeps across and back turn three pages forward (%s)" % str(turned))
	# A brief loss of tracking in the middle of a fast sweep does not spoil it.
	swipe = Swipe.new().for_book(); turned.clear(); x = 0.15
	for i in 30:
		x -= 0.3 / 22.0
		var lost := i >= 8 and i < 20
		var inputs := {"right_hand": {"source": "hand", "palm": {"tracked": not lost, "eligible": true, "position": Vector3(x, 1.3, -0.4)}}}
		for action in swipe.update(inputs, true, false, head, 1.0, dt): turned.append(int(action.direction))
	check(turned == [1], "A sweep survives a short tracking gap (%s)" % str(turned))
	# The photo wall keeps its own stricter tuning.
	var wall := Swipe.new()
	check(is_equal_approx(wall.TRAVEL, 0.18) and wall.PINCH_SPOILS and not wall.REARM_ON_RETURN, "The photo wall's waves are unchanged")

	# More papers, the ids of the settings' controls apart, and earlier choices keep their paper.
	check(book.PAPERS.size() == 12 and book.DAY_PAPERS.size() == 7 and book.NIGHT_PAPERS.size() == 5, "Twelve papers, seven by day and five by night")
	check(book.DAY_PAPERS.all(func(i): return not book.PAPERS[i].get("night", false)) and book.NIGHT_PAPERS.all(func(i): return book.PAPERS[i].get("night", false)),
		"Each row holds its own kind of paper")
	check(book.bar.LIGHT_BASE >= book.bar.PAPER_BASE + book.PAPERS.size(), "Paper and brightness controls do not share ids")
	check(Color(book.PAPERS[3].paper) == Color("#23211E"), "The papers chosen before keep their numbers")
	book.bar.section = "look"; book.bar.open("settings")
	targets = book.bar._buttons.map(func(button): return int(button.target))
	check(book.bar.PAPER_BASE + 11 in targets and book.bar.PICTURE_SWITCH in targets and book.bar.PICTURE_CHOOSE in targets and book.bar.LIGHT_BASE + 6 in targets,
		"The looks page shows every paper, the picture and brightness")
	book.bar._activate(book.bar.PAPER_BASE + 10)
	check(book.paper == 10 and book.night(), "A new night paper is chosen by its swatch")
	book.bar.dismiss()

	# The picture: grey, the page's shape, its tones spread, its detail kept.
	var Picture := preload("res://scripts/book_paper_picture.gd")
	var photo := Image.create(640, 360, false, Image.FORMAT_RGB8)
	for row in 360:
		for column in 640: photo.set_pixel(column, row, Color(0.35 + 0.3 * float(row) / 360, 0.45, 0.5))
	var texture: Image = Picture.texture_from(photo)
	check(texture.get_size() == Picture.SIZE and texture.get_format() == Image.FORMAT_L8, "The picture becomes a grey page-shaped texture")
	var left := texture.get_pixel(Picture.SIZE.x / 2, 10).r; var right := texture.get_pixel(Picture.SIZE.x / 2, Picture.SIZE.y - 10).r
	check(left < 0.25 and right > 0.75, "A low-contrast photograph is stretched across the tones (%.2f to %.2f)" % [left, right])
	var stripes := Image.create(900, 1200, false, Image.FORMAT_RGB8)
	for row in 1200:
		for column in 900: stripes.set_pixel(column, row, Color.WHITE if (column / 12) % 2 == 0 else Color.BLACK)
	var kept: Image = Picture.texture_from(stripes)
	var light := kept.get_pixel(4, 400).r; var dark := kept.get_pixel(12, 400).r
	check(light - dark > 0.6, "Fine detail of the picture survives, so it can still be recognised (%.2f vs %.2f)" % [light, dark])
	# The platform's copy of the chosen picture has no extension: it is still read, as JPEG and PNG.
	var copy := OS.get_user_data_dir().path_join("paper_picture_source_test")
	for codec in ["jpg", "png"]:
		var bytes: PackedByteArray = photo.save_jpg_to_buffer() if codec == "jpg" else photo.save_png_to_buffer()
		var file := FileAccess.open(copy, FileAccess.WRITE); file.store_buffer(bytes); file.close()
		if Picture.present(): DirAccess.remove_absolute(ProjectSettings.globalize_path(Picture.PATH))
		check(Picture._make({"path": copy}) and Picture.present(), "A chosen %s picture with no file extension becomes the paper" % codec)
	var junk := FileAccess.open(copy, FileAccess.WRITE); junk.store_buffer("not a picture at all, just words".to_utf8_buffer()); junk.close()
	check(not Picture._make({"path": copy}), "A file that is no picture is refused")
	DirAccess.remove_absolute(copy)
	var wanted := [0]
	book.picture_wanted.connect(func(): wanted[0] += 1)
	if Picture.present(): DirAccess.remove_absolute(ProjectSettings.globalize_path(Picture.PATH))
	book.set_picture(true)
	check(wanted[0] == 1 and not book.picture, "Without a picture yet, turning it on asks for one")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(Picture.PATH.get_base_dir()))
	texture.save_png(Picture.PATH)
	book._on_picture(true)
	var style: Dictionary = JSON.parse_string(book._style())
	check(book.picture and str(style.picture) == ProjectSettings.globalize_path(Picture.PATH) and float(style.picture_strength) > 0.0,
		"Once made, the pages are asked to print it")
	book.set_picture(false)
	check(str(JSON.parse_string(book._style()).picture).is_empty() and settings.get_value("book", "paper_picture", true) == false, "Turned off, plain paper again")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(Picture.PATH))

	book.close_book()
	platform.free()
	print("Book turn options: %d checks, %d failures" % [checks, failures.size()])
	for failure in failures: printerr("FAIL: " + failure)
	quit(1 if not failures.is_empty() else 0)
