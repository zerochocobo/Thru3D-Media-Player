extends SceneTree
const Library := preload("res://scripts/library_menu.gd")
const Fixture := preload("res://tests/test_archive_comics.gd")
const Privacy := preload("res://scripts/media_privacy.gd")
const Thumbnails := preload("res://scripts/thumbnail_cache.gd")
var checks := 0
var failures: Array[String] = []
var origin := "cloud://__archive-regression__/book.zip"
func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok: failures.append(label); push_error(label)
func _initialize() -> void: run.call_deferred()
func enter(menu: Node, key: String) -> void:
	menu.archives.close()
	menu.archives.open({"uri":origin, "title":"book.zip"})
	var entries := [{"path":"other/1.png","kind":"image","uri":"comic://"+key+"/99"}]
	for i in 40: entries.append({"path":"chapter/%d.png" % i, "kind":"image","uri":"comic://%s/%d" % [key,i]})
	menu.archives.receive(7, JSON.stringify({"state":"ready","session":key,"entries":entries}))
	await process_frame; menu.archives.tick()
func run() -> void:
	var previous_mode := Privacy.mode
	Privacy.configure(Privacy.ALL)
	var menu := Library.new(); var host := Fixture.Host.new(); menu.platform = host; menu.section = Library.Section.CLOUD
	root.add_child(menu); await process_frame
	var path := ProjectSettings.globalize_path("res://../../build/output/comic-directory/browse-memory.cfg")
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	if FileAccess.file_exists(path): DirAccess.remove_absolute(path)
	menu.browse_memory.load_file(path)
	await enter(menu, "first")
	menu._choose(menu.rows[0]); menu._set_scroll(4.25); menu._save_folder_position(); menu.browse_memory.flush()
	var thumbnail_key := str(menu.rows[0].thumbnail_key)
	check(not thumbnail_key.contains("comic://"), "thumbnail identity excludes temporary session")
	var image := Image.create(16,16,false,Image.FORMAT_RGB8); image.fill(Color.CORAL)
	check(Thumbnails.store(thumbnail_key,image) and menu._picture(menu.rows[0]) != null, "ordinary thumbnail cache is visible in archive browser")
	await enter(menu, "second")
	check(menu.archives.directory == "chapter" and is_equal_approx(menu.scroll,4.25), "archive folder and scroll restore across sessions")
	check(str(menu.rows[0].thumbnail_key) == thumbnail_key and menu._picture(menu.rows[0]) != null, "viewed thumbnail survives archive capability replacement")
	check(host.photos.is_empty() and host.cloud_reads == 0, "cached thumbnails and folder restore do not read archive images or cloud directory")
	menu._change_media_filter(2); menu._set_scroll(1.5); menu._save_folder_position()
	menu._change_media_filter(0)
	check(is_equal_approx(menu.scroll,4.25), "all and image filters retain separate archive positions")
	menu._change_media_filter(2)
	check(is_equal_approx(menu.scroll,1.5), "image filter restores its own position")
	menu._save_folder_position(); menu.browse_memory.flush()
	var stored := FileAccess.get_file_as_string(path)
	check(not stored.contains("comic://") and not stored.contains(origin), "browse history stores no session capability or source URL")
	menu.archives.close()
	menu.browse_memory.session.clear(); menu.browse_memory.persisted.clear(); menu.browse_memory.load_file(path)
	await enter(menu,"third")
	# Parent filter is restored to All when leaving the archive.
	check(menu.archives.directory == "chapter" and is_equal_approx(menu.scroll,4.25), "disk history restores directory and position after memory reset")
	menu.clear_browse_history(true); menu.archives.close()
	await enter(menu,"cleared")
	check(menu.archives.directory.is_empty() and is_zero_approx(menu.scroll), "shared clear history removes archive directory and position")
	Privacy.configure(Privacy.LOCAL); menu.browse_memory.policy_changed()
	menu._choose(menu.rows[0]); menu._set_scroll(3.25); menu._save_folder_position(); menu.browse_memory.flush()
	check(menu.browse_memory.persisted.is_empty() and not menu.browse_memory.lookup(menu.archives.position_scope(),true).is_empty(), "local-only policy keeps remote archive browsing in memory")
	Privacy.configure(Privacy.ALL); menu.browse_memory.policy_changed(); menu.browse_memory.flush()
	check(menu.browse_memory.persisted.is_empty(), "privacy change does not backfill previous archive positions")
	menu._set_scroll(3.5); menu._save_folder_position(); menu.browse_memory.flush()
	check(not menu.browse_memory.persisted.is_empty(), "new browsing activity follows enabled history policy")
	menu.restore_directory_position = false
	await enter(menu,"disabled")
	check(menu.archives.directory.is_empty() and is_zero_approx(menu.scroll), "disabled directory restore opens archive at root and top")
	Privacy.configure(Privacy.LOCAL)
	check(not Privacy.cache_allowed(thumbnail_key), "remote archive thumbnails follow local-only policy")
	var local_key := "archive-image://" + "file:///comic.zip".uri_encode() + "/test/page.png"
	check(Privacy.cache_allowed(local_key), "local archive thumbnails follow local-file policy")
	Thumbnails.forget(thumbnail_key); Privacy.configure(previous_mode)
	menu.queue_free(); await process_frame
	print("Archive folder memory: %d checks, %d failures" % [checks,failures.size()])
	quit(0 if failures.is_empty() else 1)
