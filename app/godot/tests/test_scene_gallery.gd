extends SceneTree
## Scene gallery downloads against the local server tools/scene_library/test_gallery.py runs.
const Gallery := preload("res://scripts/scene_import/scene_gallery.gd")
const Library := preload("res://scripts/scene_import/scene_import_library.gd")
const I18n := preload("res://scripts/i18n.gd")
var checks := 0
var failures := 0

func _initialize() -> void: _run.call_deferred()

func _check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		print("FAIL ", label)

func _settled(gallery: Node, slug: String, seconds: float = 20.0) -> String:
	var deadline := Time.get_ticks_msec() + int(seconds * 1000)
	while Time.get_ticks_msec() < deadline:
		await process_frame
		var state := str(gallery.states.get(slug, {}).get("state", ""))
		if state not in [Gallery.QUEUED, Gallery.LOADING]: return state
	return "timeout"

func _run() -> void:
	var work := OS.get_environment("THRU3D_GALLERY_WORK")
	var port := int(OS.get_environment("THRU3D_GALLERY_PORT"))
	if work.is_empty() or port <= 0:
		print("FAIL run through tools/scene_library/test_gallery.py")
		quit(2)
		return
	var gallery := Gallery.new()
	gallery.directory = work.path_join("downloads-%d" % Time.get_ticks_usec())
	# A site nothing answers at comes first: every download below has to get past it.
	gallery.sites = [["127.0.0.1", 9, false, "/scenes/"], ["127.0.0.1", port, false, "/scenes/"]]
	gallery.connect_ms = 1500
	gallery.retry_wait_ms = 200
	root.add_child(gallery)
	gallery.load_catalog(work.path_join("catalog.json"))
	_check(gallery.rows.map(func(row): return row.slug) == ["whole", "resumed", "spoiled", "slow", "gone"], "Rows that could reach outside the scene folder are left out")
	var configured: Array = gallery.sites
	gallery.sites = []
	for language in ["zh", "en", "ja", "zh_Hant"]:
		I18n.use(language)
		_check(gallery.site_order().is_empty(), "Public catalog has no default origin in %s" % language)
	_check(not gallery.request("whole", "high") and gallery.states.get("whole", {}).get("state") == Gallery.FAILED, "Unconfigured downloads fail before creating a job")
	gallery.settle("whole")
	gallery.sites = configured
	var cards := gallery.snapshot({"whole": "abc"})
	_check(cards.map(func(card): return card.slug) == ["gone", "slow", "spoiled", "resumed", "whole"], "Gallery cards show the last scene added first")
	_check(cards.back().id == "abc" and cards.back().state == "", "A card knows the library entry holding its scene")
	DirAccess.make_dir_recursive_absolute(gallery.directory)

	_check(gallery.request("whole", "high") and not gallery.request("whole", "high"), "A scene is asked for once")
	_check(await _settled(gallery, "whole") == Gallery.READY, "A file comes down whole")
	var whole: Dictionary = gallery.row("whole").tiers.high
	_check(FileAccess.get_sha256(gallery.ready_path("whole")) == whole.sha256, "What arrived is the file the catalogue names")
	gallery.settle("whole")
	_check(not gallery.states.has("whole"), "Once the library has it the gallery stops tracking it")

	# An earlier try left the first third behind.
	var resumed: Dictionary = gallery.row("resumed").tiers.high
	var source := FileAccess.get_file_as_bytes(work.path_join("served/scenes").path_join(resumed.file))
	var partial := FileAccess.open(gallery.directory.path_join(resumed.file + ".partial"), FileAccess.WRITE)
	partial.store_buffer(source.slice(0, 300000))
	partial.close()
	gallery.request("resumed", "high")
	_check(await _settled(gallery, "resumed") == Gallery.READY and FileAccess.get_sha256(gallery.ready_path("resumed")) == resumed.sha256, "A download picks up where it stopped")

	# The part held is not from this file: the checksum catches it and the file is fetched afresh.
	var spoiled: Dictionary = gallery.row("spoiled").tiers.high
	partial = FileAccess.open(gallery.directory.path_join(spoiled.file + ".partial"), FileAccess.WRITE)
	var junk := PackedByteArray()
	junk.resize(300000)
	partial.store_buffer(junk)
	partial.close()
	gallery.request("spoiled", "high")
	_check(await _settled(gallery, "spoiled") == Gallery.READY and FileAccess.get_sha256(gallery.ready_path("spoiled")) == spoiled.sha256, "A resumed file that does not add up is fetched again from the start")

	gallery.request("gone", "high")
	_check(await _settled(gallery, "gone") == Gallery.WITHDRAWN, "A file the server no longer has reads as withdrawn")
	_check(not gallery.request("nonesuch", "high"), "A scene outside the catalogue cannot be asked for")

	# With no site reachable the card says so after a few tries, and what it says is not "withdrawn".
	var working: Array = gallery.sites
	gallery.sites = [["127.0.0.1", 9, false, "/scenes/"]]
	gallery.states.erase("whole")
	gallery.request("whole", "high")
	_check(await _settled(gallery, "whole", 60.0) == Gallery.FAILED and gallery.states.whole.error == "No connection", "No site answering reads as no connection, not as withdrawn")
	gallery.sites = working
	gallery.request("whole", "high")
	_check(await _settled(gallery, "whole") == Gallery.READY, "And the same press works once a site answers")
	gallery.settle("whole")

	# Two asked for together: one waits, and giving either up leaves no trace.
	gallery.request("slow", "high")
	gallery.request("gone", "high")
	_check(gallery.states.slow.state == Gallery.QUEUED and gallery.states.gone.state == Gallery.QUEUED, "Scenes asked for together wait their turn")
	gallery.cancel("gone")
	_check(not gallery.states.has("gone"), "A waiting scene can be given up")
	for frame in 30: await process_frame
	await create_timer(0.4).timeout
	_check(gallery.states.slow.state == Gallery.LOADING and gallery.progress("slow") > 0.0 and gallery.progress("slow") < 1.0, "Progress is reported while a file comes down")
	gallery.cancel("slow")
	_check(await _settled(gallery, "slow") == "", "A download under way can be given up")
	_check(FileAccess.file_exists(gallery.directory.path_join(str(gallery.row("slow").tiers.high.file) + ".partial")), "What had arrived is kept for the next try")
	gallery.request("slow", "high")
	_check(await _settled(gallery, "slow", 40.0) == Gallery.READY, "And the next try finishes it")

	# A finished download is taken into the scene library, which remembers which gallery scene it is.
	var library := Library.new()
	library.directory = work.path_join("library-%d" % Time.get_ticks_usec())
	root.add_child(library)
	var landed := []
	library.added.connect(func(id: String, fresh: bool) -> void: landed.append([id, fresh]))
	var arrived: String = gallery.ready_path("slow")
	_check(library.adopt(arrived, "Slow Scene.glb", "slow") and landed.size() == 1 and landed[0][1], "The library takes a finished download")
	var id := str(landed[0][0]) if not landed.is_empty() else ""
	_check(not FileAccess.file_exists(arrived) and FileAccess.file_exists(library.source_path(id)), "The file moves into the library; no second copy is kept")
	_check(library.origins() == {"slow": id} and library.entries[id].title == "Slow Scene", "Its entry is named for the card and knows the gallery scene it is")
	var reopened := Library.new()
	reopened.directory = library.directory
	root.add_child(reopened)
	reopened.load_catalog()
	_check(reopened.origins() == {"slow": id}, "Which survives a restart")
	library.remove([id])
	_check(library.origins().is_empty(), "Removing the scene from the library puts its card back on offer")

	print("Scene gallery: %d checks, %d failures" % [checks, failures])
	quit(1 if failures > 0 else 0)
