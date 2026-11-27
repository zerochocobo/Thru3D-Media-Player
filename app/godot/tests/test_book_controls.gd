extends SceneTree
## Getting out of the reading mode: a book that cannot be opened puts itself away (or at once on a
## button), and the trigger calls the ring when the wand is not on the book.
const Main := preload("res://scripts/main.gd")
const I18n := preload("res://scripts/i18n.gd")
var checks := 0
var failures: Array[String] = []

## Stands in for the plugin: every book opens as request 7, and the test says how it went.
class Platform extends Object:
	signal book_ready(id: int, payload: String)
	signal book_page(id: int, page: int, path: String)
	func book_open(_uri: String, _style: String) -> int: return 7
	func book_close(_session: int) -> void: pass
	func book_render(_session: int, _page: int, _edge: int) -> bool: return true

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func _initialize() -> void: call_deferred("_run")

func _run() -> void:
	var app := Main.new(); app.settings_path = "user://book_controls_%d.cfg" % Time.get_ticks_usec()
	root.add_child(app); app.set_process(false); app.input_visuals.free(); app.input_visuals = null
	var platform := Platform.new()
	app.platform_plugin = platform
	var book: Node3D = app.book

	app._open_book("smb://shelf/novel.epub", "novel.epub")
	check(book.active and not book.failed(), "A book on its way is open and not failed")
	platform.emit_signal("book_ready", 7, JSON.stringify({"state": "error", "error": "BOOK_UNAVAILABLE"}))
	check(book.failed() and book.message == "Book could not be opened", "A book that cannot be read says so")
	book._failed_until = Time.get_ticks_msec() - 1
	book._process(0.016)
	check(not book.active and app.recent_menu.visible, "It puts itself away and the library comes back")

	app._open_book("smb://shelf/novel.epub", "novel.epub")
	platform.emit_signal("book_ready", 7, JSON.stringify({"state": "error", "error": "BOOK_UNAVAILABLE"}))
	app.recent_menu.dismiss()
	check(app._book_button("by_button", "right_hand", true) == "routed.book_close" and not book.active,
		"B closes a book that failed without waiting")
	app._open_book("smb://shelf/novel.epub", "novel.epub")
	platform.emit_signal("book_ready", 7, JSON.stringify({"state": "error", "error": "BOOK_UNAVAILABLE"}))
	app.recent_menu.dismiss()
	check(app._book_button("trigger_click", "right_hand", true) == "routed.book_close" and not book.active,
		"So does the trigger")

	# An open book: the trigger off the book calls the ring and puts it away again; on the book it is the wand's.
	app.recent_menu.dismiss()
	book.active = true; book.visible = true; book.count = 10; book.page = 2
	book.pointing = false
	check(app._book_button("trigger_click", "right_hand", true) == "routed.book_bar" and book.bar.visible,
		"The trigger away from the book calls the ring")
	book.pointing = false
	app._book_button("trigger_click", "right_hand", true)
	check(not book.bar.visible, "Pressed away from the ring and the book again, it puts the ring away")
	book.pointing = true
	check(app._book_button("trigger_click", "right_hand", true) == "routed.book_wand" and not book.bar.visible,
		"On the book the trigger takes hold of the page")
	app._book_trigger.clear()
	book.bar.open(); book.pointing = true
	check(app._book_button("trigger_click", "right_hand", true) == "routed.book_wand" and not book.bar.visible,
		"With the ring up, the trigger on the book puts the ring away and takes the page")
	app._book_trigger.clear()

	# The ring carries the music entry in its leftmost place; turning pages by themselves is not a play button.
	app.recent_menu.dismiss(); book.active = true; book.visible = true; book.count = 10; book.page = 2
	book.bar.open()
	var music: Array = book.bar._buttons.filter(func(button): return int(button.target) == book.bar.MUSIC)
	check(music.size() == 1 and is_equal_approx(music[0].node.position.x, -book.bar.RADIUS) and absf(music[0].node.position.y) < 0.001,
		"The music entry sits leftmost on the ring")
	var lefts: Array = book.bar._buttons.filter(func(button): return int(button.target) != book.bar.MUSIC and button.node.position.x < -book.bar.RADIUS + 0.01)
	check(lefts.is_empty(), "Nothing else shares the leftmost place")
	book.bar.dismiss()

	# Carried with the grip, the tome stays where it was let go; the distance setting then moves it
	# along the same line from the reader, and bringing the book here puts it back in front.
	book._frame = Transform3D.IDENTITY; book._placed = true; book._arrive = 1.0
	book.reach_step = 3
	book.global_transform = Transform3D(Basis(Vector3.UP, 0.6), Vector3(2.0, 0.5, -3.0))
	book.keep_carried()
	book.set_reach_step(3)
	check(book.global_position.is_equal_approx(Vector3(2.0, 0.5, -3.0)), "Let go, the tome stays where it was carried")
	var factor: float = book.REACHES[1] / book.REACHES[3]
	book.set_reach_step(1)
	check(book.global_position.is_equal_approx(Vector3(2.0, 0.5, -3.0) * factor), "Nearer keeps the carried direction")
	book.head_provider = func() -> Variant: return Transform3D(Basis.IDENTITY, Vector3(0, 1.5, 0))
	book.recenter()
	check(book._carried == null and absf(book.global_position.x) < 0.001, "Bringing the book here forgets where it was carried")
	book.head_provider = Callable()

	# A turning leaf covers one side; the page lying still on the other keeps its sharp layer.
	book.single = false; book.page = 3
	book._turn = {"direction": 1}
	check(book._resting(-1) == 2 and book._resting(1) == 5, "Turning forward, the left page stays and the next right lies under the leaf")
	book._turn = {"direction": -1}
	check(book._resting(-1) == 0 and book._resting(1) == 3, "Turning back, the right page stays and the earlier left lies under the leaf")
	book._turn = {}

	# The library opened from the ring: B and the menu key both come back to the book with its ring up.
	book.bar.dismiss(); book.library_requested.emit()
	check(app.recent_menu.visible, "The ring's library entry brings the library up")
	app._navigate_back()
	check(not app.recent_menu.visible and book.bar.visible and book.active, "B from the library returns to the book")
	book.bar.dismiss(); book.library_requested.emit()
	app._toggle_player_menu()
	check(not app.recent_menu.visible and not app.player_menu.visible and book.bar.visible,
		"The menu key from the library returns to the book, not to empty player controls")
	book.bar.dismiss()
	book.bar.open(); book.bar._activate(book.bar.LIBRARY)
	check(app.recent_menu.visible and not book.bar.visible, "The ring's library entry puts the ring away behind the library")
	app._navigate_back(); book.bar.dismiss()
	check(not app.recent_menu.visible, "And B comes back from it")

	# Pages drawn for the numbering a fuller layout replaced are dropped, not shown under new numbers.
	book.session = 7; book.active = true
	var picture := Image.create(4, 4, false, Image.FORMAT_RGB8)
	book._textures.clear()
	book._decoded(7, book._generation - 1, 6, "", picture)
	check(not book._textures.has(6), "A page decoded for the old numbering is dropped")
	book._decoded(7, book._generation, 6, "", picture)
	check(book._textures.has(6), "A page decoded for the current numbering is kept")
	book._pending = [7, "{}"]
	book._textures.clear(); book._wanted.clear()
	book._settle()
	check(book._wanted.is_empty(), "While a new layout waits for a turn to finish, no page is asked for")
	book._pending = []

	# The way back is a reading position: it survives renumbering and goes with the book it belongs to.
	book.info = {"at": ["0/0/0", "0/5/0", "1/0/0", "1/4/0", "2/0/0", "2/3/0", "3/0/0", "3/2/0", "4/0/0", "4/1/0"]}
	book.count = 10; book.page = 1
	book.bar.leap(8)
	check(book.bar.return_at == "0/0/0", "A long leap keeps the place it left as a reading position")
	book.bar.query = "night"; book.bar._hits = [{"at": "1/0/0"}]
	app._open_book("smb://shelf/other.epub", "other.epub")
	check(book.bar.return_at.is_empty() and book.bar.query.is_empty() and book.bar._hits.is_empty(),
		"Another book starts without the last one's way back or search")

	# Errors say what went wrong.
	platform.emit_signal("book_ready", 7, JSON.stringify({"state": "error", "error": "BOOK_CACHE_FULL"}))
	check(book.message == "Not enough storage", "A full cache says storage ran out")
	app._open_book("smb://shelf/other.epub", "other.epub")
	platform.emit_signal("book_ready", 7, JSON.stringify({"state": "error", "error": "PDF_PAGE_LIMIT"}))
	check(book.message == "This book is too long to open", "A book past the page limit says it is too long")
	app.recent_menu.dismiss()

	# Cleared history stays cleared while the book is open; a rename carries the open book along.
	book.active = true; book._failed_until = 0; book.uri = "file:///books/a.epub"
	book.info = {"at": ["0/0/0", "0/5/0"]}; book.count = 2; book.page = 1
	book._memory.clear()
	book.forget_history(false)
	book._remember()
	check(not book._memory.has("file:///books/a.epub"), "After history is cleared, turning pages does not record the book again")
	book.relocate("file:///books/a.epub", "file:///books/b.epub")
	check(book.uri == "file:///books/b.epub", "A renamed book follows its new name")

	# Pages do not turn by themselves while the reader is away or another menu is up.
	book.auto = true; book.held = true; book.page = 1; book.count = 10; book._arrive = 1.0
	book._auto_tick(1000.0)
	check(book.page == 1, "Automatic turning waits while held")
	book.auto = false; book.held = false

	# Reading time: counted while the book is read, not while it lies untouched or the reader is away.
	book.reading_seconds = 0.0; book._active_ms = Time.get_ticks_msec(); book._failed_until = 0
	book._count_reading(90.0)
	check(is_equal_approx(book.reading_seconds, 90.0), "Time on an open page counts as reading")
	book.held = true; book._count_reading(90.0); book.held = false
	check(is_equal_approx(book.reading_seconds, 90.0), "Time with the headset off does not")
	book._active_ms = Time.get_ticks_msec() - book.IDLE_MS - 1000
	book._count_reading(90.0)
	check(is_equal_approx(book.reading_seconds, 90.0), "Nor does a page left untouched for a long while")
	book.narration.on = true; book._count_reading(30.0); book.narration.on = false
	check(is_equal_approx(book.reading_seconds, 120.0), "Listening to it read aloud does")
	book.reading_seconds = 3900.0
	check(book.reading_time() == I18n.t("%dh %dm") % [1, 5], "Reading time reads as hours and minutes")
	book.reading_seconds = 30.0
	check(book.reading_time().is_empty(), "Under a minute shows nothing")

	# The ring's star keeps the open book in the app's favourites, as a book (a store of the test's own).
	var store := preload("res://scripts/favorite_store.gd").new("user://book_controls_favorites_%d" % Time.get_ticks_usec())
	app.favorites = store; app.recent_menu.collections.store = store
	book.uri = "file:///books/tome.epub"; book.title = "tome.epub"; book.active = true
	if app.favorites.contains(book.uri): app.favorites.remove(book.uri)
	book.bar.open(); book.bar._activate(book.bar.FAVORITE)
	check(app.favorites.contains(book.uri) and str(app.favorites.lookup(book.uri).get("kind", "")) == "book",
		"The ring's star adds the book to the favourites as a book")
	check(book.bar._buttons.any(func(button): return int(button.target) == book.bar.FAVORITE and button.get("lit", false)) or app._favorite_state().selected,
		"The star shows the book is a favourite")
	book.bar._activate(book.bar.FAVORITE)
	check(not app.favorites.contains(book.uri), "Pressed again, it takes the book out")
	book.bar.dismiss()

	# The ring's Scene rune puts the ring away and calls up the scene panel; the way back after a
	# leap sits in the middle of the ring, clear of the runes.
	book.bar.open()
	check(book.bar._buttons.any(func(button): return int(button.target) == book.bar.SCENE), "The ring has a Scene rune")
	book.bar._activate(book.bar.SCENE)
	check(not book.bar.visible and app.scenery_menu.visible, "The Scene rune opens the scene panel")
	app.scenery.close(); app.scenery_menu.visible = false
	book.bar.return_at = "x"; book.bar.open()
	check(not book.bar._buttons.any(func(button): return int(button.target) == book.bar.RETURN), "No way back before a leap that can be found")
	book.bar.dismiss(); book.bar.return_at = ""

	# Carried sideways round the reader again and again, the tome stays upright and keeps its lean.
	var Move := preload("res://scripts/interface_move.gd")
	var follow := preload("res://scripts/view_follow.gd").new()
	var head := Transform3D(Basis.IDENTITY, Vector3(0, 1.6, 0))
	book.global_transform = Transform3D(Basis(Vector3.RIGHT, deg_to_rad(-25)), Vector3(0, 1.35, -0.55))
	var lean: float = book.global_transform.basis.z.normalized().y
	for carry in 6:
		var start: Transform3D = book.global_transform
		var grip := Move.ray_pose(Vector3(0.2, 1.3, -0.25) if carry == 0 else head.origin + (start.origin - head.origin) * 0.4, start.origin - head.origin)
		var move := Move.new()
		check(move.begin("right_hand", "grip_click", grip, [app._book_move_target()], start.origin, head), "The grip takes hold of the tome")
		for step in 12:
			var pose := grip
			pose.basis = Basis(Vector3.UP, -0.06 * (step + 1)) * Basis(Vector3.RIGHT, 0.02 * (step + 1)) * grip.basis
			move.update(pose, head, follow)
	var basis: Basis = book.global_transform.basis.orthonormalized()
	check(absf(basis.x.y) < 0.001 and basis.y.y > 0.5, "A sideways carry never banks the tome (roll %.3f)" % basis.x.y)

	# The favourites list books and songs under their own filters.
	app.favorites.toggle("smb://nas/music/song.flac", "song.flac", "audio", {})
	app.favorites.toggle("file:///books/tome.epub", "tome.epub", "book", {})
	app.favorites.toggle("folder://smb/films", "films", "folder", {})
	app._show_recent_menu(); var library: Node = app.recent_menu
	library.section = library.Section.RECENT; library.collections.switch_tab(1)
	library._change_media_filter(library.MUSIC_FILTER); library.refresh()
	var listed: Array = library.rows.map(func(row): return str(row.get("uri", "")))
	check(listed == ["smb://nas/music/song.flac"], "The Music filter lists the favourite songs")
	check(library._buttons.any(func(button): return int(button.target) == library.FILTER_BASE + library.MUSIC_FILTER), "The favourites offer a Music filter")
	var played := []
	library.directory_song_requested.connect(func(uri, _title): played.append(uri))
	library._choose(library.rows[0])
	check(played == ["smb://nas/music/song.flac"], "A favourite song plays as music")
	library._change_media_filter(library.BOOK_FILTER); library.refresh()
	listed = library.rows.map(func(row): return str(row.get("uri", "")))
	check(listed == ["file:///books/tome.epub"], "The Books filter lists the favourite books")
	app.favorites.remove("smb://nas/music/song.flac"); app.favorites.remove("file:///books/tome.epub"); app.favorites.remove("folder://smb/films")
	library._change_media_filter(0); library.collections.switch_tab(0); library.dismiss()

	# The full music player's star keeps a song playing from a folder; the library's own tracks have none.
	var player: Node = app.music_menu
	app.background_audio.directory_track = {"id": "directory_x", "uri": "smb://nas/music/tune.flac", "label": "tune.flac"}
	player._state = {"audio_current": "directory_x", "audio_title": "tune.flac"}
	check(player.favorite_uri() == "smb://nas/music/tune.flac", "A song from a folder can be kept")
	player._activate(player.FAVORITE)
	check(app.favorites.contains("smb://nas/music/tune.flac") and str(app.favorites.lookup("smb://nas/music/tune.flac").get("kind", "")) == "audio",
		"The player's star adds the song to the favourites as music")
	player._state = {"audio_current": "directory_x", "audio_title": "tune.flac"} # The press redraws from the real (idle) player.
	player._activate(player.FAVORITE)
	check(not app.favorites.contains("smb://nas/music/tune.flac"), "Pressed again, it takes the song out")
	app.background_audio.directory_track = {}
	player._state = {"audio_current": "builtin_calm", "audio_title": "Calm"}
	check(player.favorite_uri().is_empty(), "A library track offers no star")
	book.close_book()

	app.queue_free(); await process_frame
	platform.free()
	for failure in failures: push_error(failure)
	print("Book controls: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
