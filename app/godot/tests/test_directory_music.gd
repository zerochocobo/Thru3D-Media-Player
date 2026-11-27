extends SceneTree
const Menu := preload("res://scripts/library_menu.gd")
const Player := preload("res://scripts/background_audio.gd")
const Music := preload("res://scripts/music_menu.gd")
const Directory := preload("res://scripts/library_directory_music.gd")
var checks := 0
var failures := 0

class Platform extends RefCounted:
	signal background_audio_imported(id: int, payload: String)
	var generation := 0
	var state := {}
	var loads := []
	var imports := []
	func load_background_audio(_path: String, _position: float) -> int: return 0
	func load_directory_audio(uri: String, position: float) -> int:
		loads.append(uri); generation += 1
		state = {"generation": generation, "state": "ready", "position": position, "duration": 140.0}
		return generation
	func stop_background_audio() -> void: pass
	func control_background_audio(_id: int, _playing: bool, _volume: float, _position: float) -> bool: return true
	func background_audio_status() -> String: return JSON.stringify(state)
	func import_background_audio(uri: String, _title: String) -> int:
		imports.append(uri); return imports.size()
	func load_result(id: String) -> void:
		var result := {"state": "ready", "id": id, "path": "/private/" + id + ".flac", "label": id, "decoded": true}
		if id.is_empty(): result = {"state": "error", "error": "Could not download audio"}
		background_audio_imported.emit(imports.size(), JSON.stringify(result))

func _initialize() -> void: call_deferred("run")
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures += 1; push_error(message)

func button(menu: Node, target: int) -> Dictionary:
	for candidate in menu._buttons:
		if candidate.target == target: return candidate
	return {}

func click(menu: Node, target: int) -> void:
	var control := button(menu, target)
	check(not control.is_empty(), "Control exists %d" % target)
	if control.is_empty(): return
	var origin: Vector3 = control.node.global_position + Vector3.BACK
	check(menu.ray_hit(origin, Vector3.FORWARD).get("target") == target, "Ray reaches %d" % target)
	menu.press_pointer("right_hand", origin, Vector3.FORWARD, true)
	menu.release_pointer("right_hand", origin, Vector3.FORWARD, true)

func run() -> void:
	var menu := Menu.new(); root.add_child(menu); menu.visible = true
	menu.section = Menu.Section.CLOUD; menu._cloud_stack = [{"id": "/music", "title": "Music"}]
	var names := ["A.flac", "B.mp3", "Film.mp4", "Photo.png", "Novel.epub", "Film.srt", "Room.glb"]
	for name in names: menu._cloud_entries.append({"title": name, "uri": "cloud:///music/" + name})
	var platform := Platform.new(); var audio := Player.new()
	audio.directory = "user://directory-music-%d" % Time.get_ticks_usec()
	audio.importer.platform = platform; root.add_child(audio); audio.set_process(false)
	menu.directory_song_requested.connect(audio.play_directory_file)
	menu.background_audio_provider = audio.snapshot
	audio.changed.connect(menu.refresh_background_audio)
	var chooser := Music.new(); chooser.audio = audio; root.add_child(chooser)
	menu.directory_playlist_requested.connect(chooser.choose_directory_destination)
	var picked := []
	chooser.destination_selected.connect(func(destination, files): picked.append([destination, files]))
	var reports := []
	audio.directory_import_finished.connect(func(result): reports.append(result))
	audio.directory_import_finished.connect(menu.directory_music.import_finished)
	menu.directory_retry_requested.connect(audio.retry_directory_import)
	menu.view_mode = "list"; menu.refresh()
	check(menu.rows.size() == 7 and button(menu, Directory.MULTI).is_empty(), "Mixed folder shows all files and no bulk control")
	for row in menu.rows:
		if row.kind in ["scene", "subtitle"]:
			check(not row.enabled, "Attachment is visible and disabled")
			menu._choose(row)
	check(menu.visible and audio.current.is_empty(), "Display-only items do not open a viewer")
	check(button(menu, Menu.FILTER_BASE + Menu.MUSIC_FILTER).node.position.x < button(menu, Menu.FILTER_BASE + Menu.BOOK_FILTER).node.position.x, "Music precedes books")
	menu._activate(Menu.FILTER_BASE + Menu.BOOK_FILTER)
	check(menu.rows.size() == 1 and menu.rows[0].kind == "book" and button(menu, Directory.MULTI).is_empty(), "Book filter keeps its own ID")
	menu._activate(Menu.FILTER_BASE + Menu.MUSIC_FILTER)
	check(menu.rows.size() == 2 and not button(menu, Directory.MULTI).is_empty(), "Music filter offers bulk selection")
	var song: Dictionary = menu.rows[0].duplicate()
	click(menu, Menu.ROW_BASE)
	platform.state.position = 35; audio._process(35.0)
	check(audio.snapshot().audio_active and audio.position() == 35 and platform.imports.is_empty() and menu.visible, "Whole-song playback stays in folder after 30 seconds without importing")
	click(menu, Menu.ROW_BASE)
	check(audio.paused and audio.position() == 35, "Same row pauses without restarting")
	click(menu, Menu.ROW_BASE)
	check(not audio.paused and platform.loads.size() == 1, "Resume keeps the decoder")
	for layout in ["list", "grid"]:
		menu.set_view_mode(layout)
		click(menu, Directory.ROW_ADD)
		check(chooser.directory_files.size() == 1 and chooser.directory_files[0].uri == song.uri and platform.loads.size() == 1, "Single add has a separate hit area in " + layout)
		chooser.dismiss()
	var existing := audio.library.create_playlist("Existing")
	click(menu, Directory.ROW_ADD); chooser._activate(Music.ROW)
	check(picked.size() == 1 and picked[0][0] == existing and picked[0][1].size() == 1, "Single source targets the chosen existing playlist")
	picked.clear(); chooser.dismiss()
	click(menu, Directory.MULTI)
	check(menu.directory_music.selecting, "Enter bulk mode")
	click(menu, Menu.ROW_BASE); check(menu.directory_music.selection.size() == 1 and not audio.paused, "Whole card selects without affecting music")
	menu._cloud_next = 2; menu.refresh()
	check(button(menu, Directory.ALL).node.get_child(0).text == menu.I18n.t("Select this page"), "Paged cloud labels page scope")
	click(menu, Directory.ALL); check(menu.directory_music.selection.size() == 2, "Select page collects all songs once")
	menu._cloud_page = 1; menu._cloud_next = -1
	menu._cloud_entries = [{"title": "C.flac", "uri": "cloud:///music/C.flac"}]; menu.refresh()
	click(menu, Menu.ROW_BASE); click(menu, Directory.ADD)
	check(chooser.directory_files.size() == 3, "Selection survives a page turn")
	chooser._activate(Music.NEW_LIST); chooser.name_text = "Road"; chooser._activate(Music.SAVE_NAME)
	check(picked.size() == 1 and picked[0][1].size() == 3, "New playlist is the destination for the whole batch")
	if not picked.is_empty():
		var dest: String = picked[0][0]
		audio.import_tracks(picked[0][1], dest, true)
		platform.load_result("import_a"); await process_frame
		platform.load_result("import_a"); await process_frame
		platform.load_result(""); await process_frame
		check(reports.size() == 1 and reports[0].added == 1 and reports[0].existing == 1 and reports[0].failed == 1, "Batch distinguishes success, duplicate and failure")
		check(audio.library.playlist(dest).tracks == ["import_a"] and audio.snapshot().audio_directory_uri == song.uri, "Import preserves playing source and deduplicates destination")
		if not reports.is_empty():
			click(menu, Directory.RETRY); platform.load_result("import_c"); await process_frame
			check(platform.imports.size() == 4 and audio.library.playlist(dest).tracks == ["import_a", "import_c"], "Retry only the failed source in the chosen playlist")
	chooser.dismiss(); menu.dismiss()
	check(not menu.directory_music.selecting and not audio.paused, "Closing folder ends selection while music continues")
	audio.set_mode("single"); platform.state.state = "ended"; audio._process(0.1)
	check(audio.paused and platform.loads.size() == 1, "Directory track stops at end even in repeat mode")
	# Exercise the desktop decoder and the real content-addressed import with the same source.
	var disk := Player.new()
	disk.directory = ProjectSettings.globalize_path("res://../../build/directory-music/audio-%d" % Time.get_ticks_usec()).simplify_path()
	DirAccess.make_dir_recursive_absolute(disk.directory)
	disk.importer.directory = disk.directory.path_join("imports")
	root.add_child(disk)
	var sample := AudioStreamWAV.new(); sample.mix_rate = 8000
	var pcm := PackedByteArray(); pcm.resize(8000 * 40); sample.data = pcm
	var path := disk.directory.path_join("test.wav")
	check(sample.save_to_wav(path) == OK and disk.play_directory_file(path, "test.wav"), "Local WAV opens directly")
	var until := Time.get_ticks_msec() + 8000
	while disk._thread and Time.get_ticks_msec() < until: await create_timer(0.01).timeout
	check(disk.player.stream != null and disk.duration() > 30 and disk.library.imports.is_empty(), "Actual decoder opens whole file without library copy")
	var saved := disk.library.create_playlist("Local")
	disk.import_tracks([{"uri": path, "title": "test.wav"}, {"uri": path, "title": "test.wav"}], saved, true)
	until = Time.get_ticks_msec() + 8000
	while (disk.importer.busy or not disk.pending_imports.is_empty() or not disk._import_job.is_empty()) and Time.get_ticks_msec() < until: await create_timer(0.01).timeout
	var library := preload("res://scripts/audio_library.gd").new(); library.directory = disk.directory; library.load_library()
	check(library.imports.size() == 1 and library.playlist(saved).tracks.size() == 1 and disk.directory_track.uri == path, "Two imports persist one playable copy and one destination reference")
	disk.free()
	chooser.free(); menu.free(); audio.free()
	print("Directory music: %d checks, %d failures" % [checks, failures]); quit(1 if failures else 0)
