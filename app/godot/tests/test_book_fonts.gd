extends SceneTree
## Reading fonts: the shipped catalogue, the sites they come from (the scene library's, under
## fonts/), when a font counts as installed, and the reader laying a book out in the chosen font
## for its language. With BOOK_FONTS_LIVE=1, the smallest font is also fetched from the real sites
## and checked against the catalogue.
const Fonts := preload("res://scripts/book_fonts.gd")
const Reader := preload("res://scripts/book_reader.gd")
var checks := 0
var failures: Array[String] = []

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func _initialize() -> void: call_deferred("_run")

func _run() -> void:
	var fonts := Fonts.new()
	fonts.directory = "user://book_fonts_test_%d" % Time.get_ticks_usec()
	root.add_child(fonts)
	check(fonts.rows.size() == 8, "The catalogue lists eight fonts")
	for lang in Fonts.LANGUAGES:
		check(fonts.fonts_for(lang).size() == 2, "Two fonts are offered for books in " + lang)
	check(fonts.site_order().is_empty(), "Public export has no default font service origins")
	fonts.sites = [["127.0.0.1", 1, false, "/fonts/"]]
	for site in fonts.site_order():
		check(str(site[3]) == "/fonts/", "Configured sites use the font folder")
	fonts.sites = []
	var id := "atkinson-hyperlegible"
	check(not fonts.installed(id) and fonts.state_of(id) == "", "A font not yet fetched is on offer")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(fonts.directory))
	var file := FileAccess.open(fonts.path_of(id), FileAccess.WRITE); file.store_buffer(PackedByteArray([1, 2, 3])); file = null
	check(not fonts.installed(id), "A file of the wrong size is not an installed font")
	fonts.remove(id)
	check(not FileAccess.file_exists(fonts.path_of(id)), "Removing a font deletes its file")
	check(fonts.display_name("noto-serif-sc", "zh") == "思源宋体" and fonts.display_name("noto-serif-sc", "en") == "Noto Serif SC",
		"Font names follow the interface language")

	# The reader: a Chinese book asks for the font chosen for Chinese, once it is installed.
	var reader := Reader.new()
	reader.fonts.free()
	reader.fonts = fonts
	reader.uri = "file:///book.epub"; reader.info = {"variant": "zh"}
	reader.font_choices = {"zh": "noto-serif-sc"}
	check(reader.font_path() == "", "A chosen font still on its way leaves the system font in use")
	var sc: Dictionary = fonts.file_of("noto-serif-sc")
	file = FileAccess.open(fonts.path_of("noto-serif-sc"), FileAccess.WRITE)
	file.store_buffer(PackedByteArray()); file.seek(int(sc.bytes) - 1); file.store_8(0); file = null
	check(reader.font_path() == fonts.path_of("noto-serif-sc"), "Once whole, the chosen font is the one laid out")
	var style: Dictionary = JSON.parse_string(reader._style())
	check(str(style.get("font", "")) == fonts.path_of("noto-serif-sc"), "The layout is asked for the font's file")
	reader.info = {"variant": "en"}
	check(reader.font_path() == "", "Books in another language keep their own choice (none: the system's)")
	reader.queue_free()

	if OS.get_environment("BOOK_FONTS_LIVE") == "1":
		var live := Fonts.new(); live.directory = fonts.directory + "_live"
		root.add_child(live)
		check(live.fetch(id), "The smallest font starts downloading")
		var deadline := Time.get_ticks_msec() + 120000
		while live.state_of(id) not in ["installed", "failed", "withdrawn"] and Time.get_ticks_msec() < deadline:
			await process_frame
		check(live.state_of(id) == "installed", "The font arrives whole from the real sites: " + live.state_of(id) + " " + str(live.states.get(id, {})))
		if live.installed(id): check(FileAccess.get_sha256(live.path_of(id)) == str(live.file_of(id).sha256), "It matches the catalogue's checksum")
		live.remove(id); live.queue_free()
	fonts.remove("noto-serif-sc")
	fonts.queue_free()
	await process_frame
	for failure in failures: push_error(failure)
	print("Book fonts: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
