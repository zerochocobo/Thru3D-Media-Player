extends SceneTree
const Privacy := preload("res://scripts/media_privacy.gd")
const Main := preload("res://scripts/main.gd")
const Video := preload("res://scripts/mpv_video_display.gd")
const Memory := preload("res://scripts/file_mode_memory.gd")
const Recent := preload("res://scripts/recent_files.gd")
const Favorites := preload("res://scripts/favorite_store.gd")
const Library := preload("res://scripts/library_menu.gd")
const Thumbnails := preload("res://scripts/thumbnail_cache.gd")
const LOCAL := "file:///privacy-split/A.mp4"
const NETWORK := "smb://saved-pc/CD2/115/B.mp4"
var failures: Array[String] = []
var checks := 0

class Photo extends Node3D:
	var mode_memory := Memory.new()
	var history_enabled := true

class Vault extends RefCounted:
	func favorites_vault_save(_path: String, _data: String) -> bool: return true

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok: failures.append(label)

func _initialize() -> void: call_deferred("run")

func fresh(memory: RefCounted) -> RefCounted:
	var restored: RefCounted = memory.get_script().new(memory.directory)
	restored.load_saved(); return restored

func stores(main: Node) -> Array:
	return [main.video.mode_memory, main.video.track_memory, main.video.subtitle_timing,
		main.video.audio_timing, main.video.whisper_memory, main.video.narration.memory, main.photo.mode_memory]

func values(main: Node) -> Array:
	var mode := {"geometry": 1, "stereo_sbs": true, "swap_eyes": true, "alpha_requested": false,
		"profile": "320x320", "stereo_horizontal": 2.5, "stereo_vertical": -1.0}
	return [mode, {"audio": {"id": 0}, "subtitle": {"id": 0}}, {"delay_seconds": 1.5},
		{"delay_seconds": 0.5}, {"enabled": true, "boost": 32}, main.video.narration._values(), mode]

func seed_settings(main: Node) -> void:
	var data := values(main); var memories := stores(main)
	for index in memories.size():
		for uri in [LOCAL, NETWORK]:
			check(memories[index].remember(uri, data[index]) and memories[index].save(), "Save independent setting store %d" % index)

func seed_history(main: Node) -> void:
	for network in [false, true]:
		main.recent_menu.browse_memory.remember("browse-network" if network else "browse-local", network, {"index": 8}, main.recent_menu.browse_memory.revision)
	check(main.recent_menu.browse_memory.flush(), "Browser positions use history storage")
	for uri in [LOCAL, NETWORK]:
		check(main.video.recent_files.opened(uri, "Movie", false) and main.video.recent_files.progress(uri, 12345, 60000)
			and main.video.recent_files.save(), "Save recent playback and resume")
		var image := Image.create_empty(2, 2, false, Image.FORMAT_RGB8); image.fill(Color.CORNFLOWER_BLUE)
		check(Thumbnails.store(uri, image) and FileAccess.file_exists(Thumbnails.path_for(uri)) == Privacy.cache_allowed(uri), "History thumbnail follows the disk-cache policy")

func check_settings(main: Node, network_empty: bool = false, all_empty: bool = false) -> void:
	var data := values(main); var memories := stores(main)
	for index in memories.size():
		var saved := fresh(memories[index])
		check(saved.lookup(LOCAL) == ({} if all_empty else data[index]), "Local setting store %d has the intended value after reload" % index)
		check(saved.lookup(NETWORK) == ({} if network_empty or all_empty else data[index]), "Network setting store %d has the intended value after reload" % index)

func clear_with_menu(menu: Node, key: String, scope: String) -> void:
	menu.refresh()
	var row: Dictionary = menu.rows.filter(func(item): return item.get("setting", []) == [key, scope])[0]
	menu._choose(row)
	check(menu._confirm == str([key, scope]), "Each clear action requires its own confirmation")
	menu._choose(row)
	check(menu._confirm.is_empty(), "Confirmed clear action is dispatched")

func run() -> void:
	var directory := ProjectSettings.globalize_path("res://../../build/output/privacy-memory-split/cases-" + str(Time.get_ticks_usec()))
	DirAccess.make_dir_recursive_absolute(directory)
	for legacy in [true, false]:
		var config := ConfigFile.new(); config.set_value("library", "history", legacy); Privacy.restore(config)
		check(Privacy.mode == (Privacy.ALL if legacy else Privacy.NONE) and Privacy.file_settings == Privacy.ALL,
			"Legacy history boolean never disables per-file memory")
	for history in [Privacy.ALL, Privacy.LOCAL, Privacy.NONE]:
		var config := ConfigFile.new(); config.set_value("privacy", "history", history); Privacy.restore(config)
		check(Privacy.mode == history and Privacy.file_settings == Privacy.ALL, "Legacy privacy policy keeps history and defaults memory independently")
	Privacy.configure(Privacy.ALL); Privacy.configure_file_settings(Privacy.ALL); Privacy.vault = null
	var main := Main.new(); main.settings_path = directory.path_join("settings.cfg")
	var video := Video.new(); main.video = video
	var photo := Photo.new(); main.photo = photo
	for memory in stores(main) + [video.recent_files, video.bookmark_store]: memory.directory = directory.path_join(str(memory.get_instance_id()))
	root.add_child(video); video.set_process(false)
	main.favorites = Favorites.new(directory.path_join("favorites"))
	var menu := Library.new(); main.recent_menu = menu; root.add_child(menu); menu.set_process(false)
	menu.browse_memory.load_file(directory.path_join("browse.cfg"))
	menu.settings_provider = main._library_settings; menu.setting_changed.connect(main._on_setting_changed)
	menu.section = Library.Section.SETTINGS; menu.tab = Library.GENERAL_TAB; menu.collections.privacy_expanded = true
	menu.collections.store = main.favorites; menu.catalog = video.recent_files; menu.refresh()
	check(menu.rows.any(func(row): return row.get("key") == "privacy_mode") and menu.rows.any(func(row): return row.get("key") == "file_settings_memory"),
		"Privacy UI offers independent history and per-file memory controls")
	main._on_setting_changed("privacy_mode", Privacy.NONE)
	check(not video.history_enabled and not photo.history_enabled and Privacy.file_settings == Privacy.ALL, "Stopping history leaves memory enabled")
	seed_settings(main); check_settings(main)
	check(not video.recent_files.opened(NETWORK, "No history", false), "Remembering network settings does not write recent playback")
	var private_image := Image.create_empty(2, 2, false, Image.FORMAT_RGB8)
	Thumbnails.store(NETWORK, private_image)
	check(not FileAccess.file_exists(Thumbnails.path_for(NETWORK)), "History off keeps thumbnails out of disk even while settings are saved")
	main._on_setting_changed("file_settings_memory", Privacy.NONE)
	check(Privacy.mode == Privacy.NONE and video.mode_memory.lookup(LOCAL).is_empty() and not video.mode_memory.remember(LOCAL, values(main)[0]),
		"Disabling memory stops restoring and saving settings independently")
	main._on_setting_changed("privacy_mode", Privacy.ALL)
	check(Privacy.file_settings == Privacy.NONE and video.history_enabled, "Enabling history does not enable settings memory")
	var saved := ConfigFile.new(); check(saved.load(main.settings_path) == OK, "Independent controls persist")
	Privacy.restore(saved); check(Privacy.mode == Privacy.ALL and Privacy.file_settings == Privacy.NONE, "Both controls survive restart independently")
	main._on_setting_changed("file_settings_memory", Privacy.ALL); check_settings(main)
	main._on_setting_changed("history", false)
	check(Privacy.mode == Privacy.NONE and Privacy.file_settings == Privacy.ALL and not Privacy.cache_allowed(NETWORK),
		"Legacy history toggle also stops thumbnail recording without disabling per-file memory")
	main._on_setting_changed("privacy_mode", Privacy.ALL)
	main.settings.set_value("ui", "language", "ja")
	seed_history(main)
	clear_with_menu(menu, "privacy_clear", "network")
	check(menu.browse_memory.lookup("browse-network", true).is_empty() and menu.browse_memory.lookup("browse-local", false).get("index") == 8, "Existing network-history control also clears only network browser positions")
	check(fresh(video.recent_files).resume_position(LOCAL) == 12345 and fresh(video.recent_files).lookup(NETWORK).is_empty(),
		"Network history clear preserves local history")
	check_settings(main)
	seed_history(main)
	clear_with_menu(menu, "privacy_clear", "all")
	check(menu.browse_memory.session.is_empty() and menu.browse_memory.persisted.is_empty(), "Existing all-history control also clears browser positions")
	check(fresh(video.recent_files).entries.is_empty() and not video.recent_files.can_undo(), "History clear removes recent/resume records from both banks and undo")
	check(not FileAccess.file_exists(Thumbnails.path_for(LOCAL)) and not FileAccess.file_exists(Thumbnails.path_for(NETWORK)), "History clear removes thumbnails")
	check_settings(main)
	seed_history(main)
	clear_with_menu(menu, "file_settings_clear", "network"); check_settings(main, true)
	check(fresh(video.recent_files).resume_position(LOCAL) == 12345 and fresh(video.recent_files).resume_position(NETWORK) == 12345,
		"Network settings clear preserves local and network history")
	clear_with_menu(menu, "file_settings_clear", "all"); check_settings(main, true, true)
	check(menu.browse_memory.lookup("browse-network", true).get("index") == 8, "Clearing per-file settings leaves browser history intact")
	check(fresh(video.recent_files).entries.size() == 2 and FileAccess.file_exists(Thumbnails.path_for(NETWORK))
		and main.settings.get_value("ui", "language") == "ja", "Clearing all settings preserves history, thumbnails and global preferences")
	video.local_uri = NETWORK; video.media.begin(77); video._remember_file = true; video.stereo_sbs = true
	video.stereo_horizontal = 2.5; video.stereo_vertical = -1.0
	video._whisper_command = 9; video._whisper_remember = true
	main._on_setting_changed("file_settings_clear", "all")
	video._remember_mode(false)
	check(fresh(video.mode_memory).lookup(NETWORK).is_empty(), "A late first frame cannot restore explicitly cleared settings")
	video._confirm_audio_whisper({"whisper_serial": 9, "whisper_level": 33})
	check(fresh(video.whisper_memory).lookup(NETWORK).is_empty(), "A late native enhancement acknowledgement cannot restore cleared settings")
	video.set_stereo_alignment("stereo_horizontal", 0.75); video.commit_stereo_view()
	check(fresh(video.mode_memory).lookup(NETWORK).get("stereo_horizontal") == 0.75, "A new explicit adjustment can be remembered after clearing")
	video.close_video()
	# PIN-protected private preferences and legacy history must also clear separately.
	main.favorites.platform = Vault.new(); main.favorites.protected = true; Privacy.vault = main.favorites
	for uri in [LOCAL, NETWORK]:
		main.favorites.toggle(uri, "Favorite", "video")
		main.favorites.private_remember(uri, "recent", video.recent_files.lookup(uri))
	seed_settings(main)
	main._on_setting_changed("privacy_clear", "all")
	check(main.favorites.private_lookup(NETWORK, "recent").is_empty(), "History clear removes legacy encrypted history")
	for index in stores(main).size():
		var memory: RefCounted = stores(main)[index]
		check(memory.lookup(NETWORK) == values(main)[index], "History clear preserves protected setting store %d" % index)
	seed_history(main)
	for uri in [LOCAL, NETWORK]: main.favorites.private_remember(uri, "recent", video.recent_files.lookup(uri))
	main._on_setting_changed("file_settings_clear", "network")
	check(main.favorites.contains(LOCAL) and main.favorites.contains(NETWORK)
		and main.favorites.private_lookup(NETWORK, "recent").position_ms == 12345, "Clearing encrypted settings preserves favorite membership and legacy history")
	for memory in stores(main):
		check(memory.lookup(NETWORK).is_empty() and not memory.lookup(LOCAL).is_empty(), "Network clear scopes encrypted preferences by source")
	Privacy.vault = null; Privacy.configure(Privacy.ALL); Privacy.configure_file_settings(Privacy.ALL)
	menu.free(); video.free(); photo.free(); main.free()
	print("Independent privacy memory checks=%d failures=%d" % [checks, failures.size()])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)
