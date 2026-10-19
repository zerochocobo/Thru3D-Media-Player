extends SceneTree
const Audio := preload("res://scripts/background_audio.gd")
const Home := preload("res://scripts/library_menu.gd")
const Photo := preload("res://scripts/photo_menu.gd")
const Music := preload("res://scripts/music_menu.gd")
const Quick := preload("res://scripts/music_quick_controls.gd")
const Storage := preload("res://scripts/audio_storage_view.gd")
var checks := 0
var failures := 0
class CountedHome extends Home:
	var rebuilds := 0
	func _rebuild_rows() -> void:
		rebuilds += 1; super()
class TestMain extends "res://scripts/main.gd":
	func _place_menu(_menu: Node3D, _recenter: bool = false) -> void: pass
class StoragePlatform extends RefCounted:
	var info := {"used_bytes": 6 * 1024 * 1024 * 1024, "free_bytes": 20 * 1024 * 1024 * 1024, "total_bytes": 128 * 1024 * 1024 * 1024, "max_file_bytes": 512 * 1024 * 1024}
	func background_audio_storage() -> String: return JSON.stringify(info)
	var preview_generation := 0
	var preview_state := {}
	var preview_stops := 0
	var preview_commands: Array = []
	var preview_seeks: Array = []
	func seek_audio_preview(id: int, position: float) -> bool:
		preview_seeks.append([id, position]); return true
	func preview_background_audio(_uri: String) -> int:
		preview_generation += 1; preview_state = {"generation": preview_generation, "state": "loading"}; return preview_generation
	func control_audio_preview(id: int, playing: bool, volume: float) -> bool:
		preview_commands.append([id, playing, volume]); return true
	func audio_preview_status() -> String: return JSON.stringify(preview_state)
	func stop_audio_preview() -> void: preview_stops += 1
func _initialize() -> void: call_deferred("run")
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures += 1; push_error(message)
func control(menu: Node, target: int) -> Dictionary:
	for button in menu._buttons:
		if button.target == target: return button
	return {}
func direction(menu: Node3D, target: int) -> Vector3:
	return control(menu, target).node.global_position.normalized()
func hover(menu: Node3D, target: int, hand: String = "left_hand") -> void:
	menu.update_pointer(hand, Vector3.ZERO, direction(menu, target), true)
func run() -> void:
	var audio := Audio.new(); audio.player = AudioStreamPlayer.new()
	audio.current = "yunhai"; audio._loaded = "yunhai"; audio.paused = false; audio.queue.assign(["yunhai"])
	var platform := StoragePlatform.new(); audio.importer.platform = platform
	var home := CountedHome.new(); root.add_child(home)
	home.background_audio_provider = audio.snapshot; home.visible = true; home.refresh()
	var opened := []; home.music_requested.connect(func(): opened.append(true))
	home.music_toggle_requested.connect(audio.toggle_pause)
	var initial_rows: Array = home.rows.duplicate(true); var rebuilds: int = home.rebuilds
	var icon_position: Vector3 = control(home, Home.MUSIC_OPEN).node.global_position
	hover(home, Home.MUSIC_OPEN)
	check(not home.music_quick.expanded, "Brief crossing keeps the compact icon")
	home.music_quick._entered.left_hand = Time.get_ticks_msec() - Quick.ENTER_MS - 1; hover(home, Home.MUSIC_OPEN)
	check(home.music_quick.expanded and not control(home, Quick.PLAY).is_empty(), "Hover opens the mini transport")
	check(control(home, Home.MUSIC_OPEN).node.global_position.distance_to(icon_position) < 0.02, "Entry remains under the original ray")
	check(home.rebuilds == rebuilds and home.rows == initial_rows, "Hover expansion never rebuilds directory data")
	home.press_pointer("left_hand", Vector3.ZERO, direction(home, Quick.PLAY), true)
	check(audio.paused and opened.is_empty() and home.visible, "Pause works in place without opening management")
	home.refresh_background_audio()
	home.press_pointer("right_hand", Vector3.ZERO, direction(home, Quick.PLAY), true)
	check(not audio.paused and home.rebuilds == rebuilds, "Either hand can resume without reloading directory data")
	hover(home, Quick.PLAY, "left_hand")
	home.music_quick._last_inside = Time.get_ticks_msec() - Quick.LEAVE_MS - 1
	home.update_pointer("right_hand", Vector3.ZERO, Vector3.FORWARD, false)
	check(home.music_quick.expanded, "The other hand leaving cannot fold an occupied transport")
	home.update_pointer("left_hand", Vector3.ZERO, Vector3.FORWARD, false)
	check(not home.music_quick.expanded, "Leaving or losing both rays folds the transport")
	hover(home, Home.MUSIC_OPEN); home.music_quick._entered.left_hand = Time.get_ticks_msec() - Quick.ENTER_MS - 1
	home._drag = {"hand": "right_hand"}
	home.music_quick.update("left_hand", Vector3.ZERO, direction(home, Home.MUSIC_OPEN), true)
	check(not home.music_quick.expanded, "List capture prevents hover expansion")
	home._drag.clear(); hover(home, Home.MUSIC_OPEN)
	check(home.music_quick.expanded, "Hover becomes available after capture ends")
	var open_ray := direction(home, Home.MUSIC_OPEN)
	home.press_pointer("left_hand", Vector3.ZERO, open_ray, true)
	check(opened.size() == 1, "Expand opens management explicitly")
	home.dismiss(); check(not home.music_quick.expanded, "Dismiss resets transient hover state")
	var photo := Photo.new(); root.add_child(photo)
	photo.state_provider = func():
		var state: Dictionary = audio.snapshot(); state.merge({"has_image": true, "count": 3, "index": 0, "title": "Photo"}); return state
	photo.visible = true; photo.refresh_values()
	var ops := []; photo.action_requested.connect(func(op): ops.append(op))
	hover(photo, Photo.PHOTO_AUDIO); photo.music_quick._entered.left_hand = Time.get_ticks_msec() - Quick.ENTER_MS - 1; hover(photo, Photo.PHOTO_AUDIO)
	check(photo.music_quick.expanded, "Photo entry uses the same hover interaction")
	photo.press_pointer("right_hand", Vector3.ZERO, direction(photo, Quick.PLAY), true)
	check(ops == ["music_toggle"] and photo.visible, "Photo pause delegates to the global transport in place")
	var main := TestMain.new(); main.background_audio = audio; main.photo_menu = photo; main.recent_menu = home; main.player_menu = photo
	main._on_photo_action("music_toggle"); check(audio.paused, "Main routes photo transport to the shared music player")
	var music := Music.new(); music.audio = audio; root.add_child(music); main.music_menu = music
	main.photo_active = true; main._on_photo_action("music_open")
	check(music.visible and not music.compact and main._music_return_photo, "Expand enters full management and remembers photo context")
	check(Storage.usage(audio.snapshot()).contains("6.0 GB"), "Usage above 4 GiB is displayed without an aggregate quota")
	check(Storage.file_limit(audio.snapshot()).contains("512 MB"), "512 MiB remains the per-file limit")
	check(Storage.device_space(audio.snapshot()).contains("20.0 GB") and Storage.device_space(audio.snapshot()).contains("128.0 GB"), "Device availability and total capacity are both visible")
	check(music._storage_labels.is_empty(), "Capacity information is tucked away from the main music view")
	var settings_ray := direction(music, Music.SETTINGS)
	music.press_pointer("left_hand", Vector3.ZERO, settings_ray, true)
	music.release_pointer("left_hand", Vector3.ZERO, settings_ray, true)
	check(music.modal == "settings" and music._storage_labels.size() == 3, "Settings exposes usage, device space and per-file limit")
	var labels: Array[Label3D] = music._storage_labels.duplicate()
	platform.info.free_bytes = 19 * 1024 * 1024 * 1024; music.refresh_values()
	check(music._storage_labels == labels and labels[1].text.contains("19.0 GB"), "Storage polling updates text without rebuilding controls")
	music.navigate_back()
	check(music.modal.is_empty() and not music.compact and music._storage_labels.is_empty(), "Back returns to full management without persistent capacity text")
	music._open_modal("add_source"); music.refresh()
	check(music._storage_labels.size() == 3, "Import source dialog shows usage, device space and per-file limit")
	music.dismiss(); home.visible = true; home.begin_audio_import()
	check(home._audio_storage_labels.size() == 3 and control(home, Home.MUSIC_OPEN).is_empty(), "Import browser exposes capacity without another music entry")
	var import_controls: Array = home._buttons.duplicate(); platform.info.free_bytes = 18 * 1024 * 1024 * 1024
	home._audio_storage_refresh = 0; home._process(0)
	check(home._buttons == import_controls and home._audio_storage_labels[1].text.contains("18.0 GB"), "Import capacity refresh preserves selection controls")
	home.dismiss(); home.visible = true; home.refresh()
	check(not home.music_quick.expanded, "Reopening the browser starts compact")
	home.section = Home.Section.LOCAL
	home._local_entries = [{"uri": "file:///first.flac", "title": "First.flac", "kind": "audio"}, {"uri": "cloud://sample/second.dts", "title": "Second.dts", "kind": "audio"}]
	home.audio_preview_requested.connect(audio.preview_audio); home.audio_preview_stopped.connect(audio.stop_preview)
	home.audio_preview_scrubbed.connect(audio.scrub_preview)
	audio.changed.connect(home.refresh_background_audio)
	home.begin_audio_import(); home._choose(home.rows[0])
	var selection: Dictionary = home.audio_selection.duplicate(true)
	var queue: Array = audio.queue.duplicate(); var track: String = audio.current
	audio.paused = false
	var preview_ray := direction(home, Home.AUDIO_PREVIEW_BASE)
	home.press_pointer("left_hand", Vector3.ZERO, preview_ray, true)
	check(audio._preview_token > 0 and audio.blocked() and not audio.paused, "Preview suspends the current player without changing play intent")
	check(home.audio_selection == selection and audio.queue == queue and audio.current == track and audio.library.imports.is_empty(), "Preview neither imports, selects nor changes the playlist")
	var saved := ConfigFile.new(); audio.save_settings(saved)
	check(not saved.encode_to_text().contains("file:///first.flac") and str(saved.get_value("audio_player", "current")) == track, "Preview source is never saved as the listening session")
	platform.preview_state.merge({"state": "ready", "position": 8.0, "duration": 240.0, "seekable": true}, true); audio._process(0.11)
	check(not audio._preview_loading and platform.preview_commands.back()[1], "Ready preview plays through the independent transport")
	var seek: RefCounted = home.audio_preview_seek
	var rail := control(home, -5410)
	check(not rail.is_empty() and rail.enabled and seek.view.total.text == "4:00", "Active preview shows duration and an enabled timeline")
	var rail_ray: Vector3 = rail.node.global_position.normalized()
	var before_seek_rows: int = home.rebuilds
	home.press_pointer("left_hand", Vector3.ZERO, rail_ray, true)
	check(home.has_pointer_capture() and audio._preview_scrubbing and not platform.preview_commands.back()[1], "Timeline captures the ray and pauses preview while dragging")
	check(home._drag.is_empty() and home.audio_selection == selection, "Timeline press neither scrolls nor selects the file")
	var seek_count: int = platform.preview_seeks.size()
	home.release_pointer("right_hand", Vector3.ZERO, rail_ray, true)
	check(home.has_pointer_capture() and platform.preview_seeks.size() == seek_count, "Other hand cannot release or seek an owned timeline")
	home.stick_scroll(1, 1)
	var end_ray: Vector3 = (rail.node.global_transform * Vector3(0.1425, 0, 0)).normalized()
	home.update_pointer("left_hand", Vector3.ZERO, end_ray, true)
	check(absf(float(seek.capture.position) - 180) < 0.001 and seek.view.elapsed.text in ["2:59", "3:00"] and platform.preview_seeks.size() == seek_count, "Drag shows destination without spamming remote seeks")
	audio._process(35)
	check(audio._preview_token > 0, "Holding the timeline does not consume the preview window")
	home.release_pointer("left_hand", Vector3.ZERO, end_ray, true)
	check(not home.has_pointer_capture() and not audio._preview_scrubbing and platform.preview_commands.back()[1], "Release resumes audition and clears capture")
	check(platform.preview_seeks.size() == seek_count + 1 and is_equal_approx(float(platform.preview_seeks.back()[1]), 180), "Release seeks the independent preview to the requested position")
	platform.preview_state.position = 180.1; audio._process(0.11); home._process(0.11)
	check(audio._preview_token > 0 and home.rebuilds == before_seek_rows and audio.current == track and audio.queue == queue, "Seeking beyond 30 seconds keeps audition active without rebuilding or changing the playlist")
	check(home.audio_selection == selection and audio.library.imports.is_empty(), "Scrubbing never imports or changes checkboxes")
	home.press_pointer("left_hand", Vector3.ZERO, rail_ray, true)
	home.update_pointer("left_hand", Vector3.ZERO, rail_ray, false)
	check(not home.has_pointer_capture() and not audio._preview_scrubbing and platform.preview_seeks.size() == seek_count + 1, "Tracking loss cancels the drag without seeking")
	home.press_pointer("right_hand", Vector3.ZERO, rail_ray, true)
	home.release_pointer("right_hand", Vector3.ZERO, rail_ray, true)
	check(is_equal_approx(float(platform.preview_seeks.back()[1]), 120), "Either hand can click the timeline to jump directly")
	home.press_pointer("left_hand", Vector3.ZERO, rail_ray, true)
	home.section = Home.Section.SMB; home._process(0)
	check(audio._preview_token == 0 and not audio.blocked() and not audio.paused, "Leaving the source stops preview and restores prior playback intent")
	seek_count = platform.preview_seeks.size()
	home.release_pointer("left_hand", Vector3.ZERO, end_ray, true)
	check(not home.has_pointer_capture() and platform.preview_seeks.size() == seek_count, "Release after navigation cannot seek a closed stream")
	home.section = Home.Section.LOCAL; home.refresh(); home._activate(Home.AUDIO_PREVIEW_BASE)
	check(not control(home, -5410).enabled and seek.view.total.text == "–:––", "Loading preview shows an inactive rail with unknown duration")
	platform.preview_state.merge({"state": "ready", "position": 0.0, "duration": 0.0, "seekable": false}, true); audio._process(0.11)
	seek_count = platform.preview_seeks.size()
	home.press_pointer("left_hand", Vector3.ZERO, direction(home, -5410), true)
	check(not home.has_pointer_capture() and home.audio_selection == selection and platform.preview_seeks.size() == seek_count, "A nonseekable stream cannot seek or toggle the row through its inactive rail")
	platform.preview_state.duration = 240.0; platform.preview_state.seekable = true; audio._process(0.11); home._process(0.11)
	check(control(home, -5410).enabled, "Late duration and seeking capability enable the timeline")
	rail_ray = direction(home, -5410); home.press_pointer("left_hand", Vector3.ZERO, rail_ray, true)
	var superseded: int = audio._preview_token
	audio.preview_audio("cloud://sample/replacement.flac", "Replacement")
	home.release_pointer("left_hand", Vector3.ZERO, rail_ray, true)
	check(audio._preview_token != superseded and platform.preview_seeks.size() == seek_count and not audio._preview_scrubbing, "Late drag release cannot seek or pause a replacement preview")
	audio.stop_preview()
	home.section = Home.Section.CLOUD; home._activate(Home.AUDIO_PREVIEW_BASE)
	home._cloud_page += 1; home._process(0)
	check(audio._preview_token == 0, "Moving to another cloud page stops preview")
	audio.paused = true; audio.preview_audio("cloud://sample/second.dts", "Second")
	audio.stop_preview(); check(audio.paused, "Previously paused music stays paused after preview")
	audio.preview_audio("cloud://sample/second.dts", "Second"); var token: int = audio._preview_token
	audio.preview_audio("cloud://sample/third.flac", "Third")
	platform.preview_state = {"generation": token, "state": "failed"}; audio._process(0.11)
	check(audio._preview_token != token and audio._preview_title == "Third", "A superseded preview failure cannot stop a newer source")
	platform.preview_state = {"generation": audio._preview_token, "state": "ready", "position": 90.1}; audio._process(0.11); audio._process(30.1)
	check(audio._preview_token == 0 and audio.paused, "Preview automatically releases its stream at 30 seconds")
	audio.preview_audio("file:///first.flac", "First"); audio.preview_audio("file:///first.flac", "First")
	check(audio._preview_token == 0, "Clicking the same preview again stops it")
	audio.paused = false; audio.preview_audio("file:///first.flac", "First")
	platform.preview_state.state = "failed"; audio._process(0.11)
	check(audio._preview_token == 0 and not audio.paused and not audio._preview_error.is_empty(), "Failure restores original intent and reports preview feedback")
	audio.preview_audio("file:///first.flac", "First"); audio.set_context(false, false)
	check(audio._preview_token == 0 and audio.blocked(), "Focus loss cancels preview")
	audio.set_context(false, true); audio.set_context(true, true)
	check(not audio.preview_audio("file:///first.flac", "First"), "Video priority also prevents preview audio")
	audio.set_context(false, true); home.section = Home.Section.LOCAL; home.refresh()
	home._activate(Home.AUDIO_PREVIEW_BASE); home.dismiss()
	check(audio._preview_token == 0, "Closing a loading selection view cancels preview")
	platform.preview_state.state = "ready"; audio._process(0.11)
	check(audio._preview_token == 0 and audio.queue == queue, "Late completion after closing cannot restart audio or mutate the queue")
	home.visible = true; home.begin_audio_import(); home._choose(home.rows[0])
	var batches := []; home.audio_import_selected.connect(func(files): batches.append(files))
	home._activate(Home.AUDIO_PREVIEW_BASE); home._activate(Home.AUDIO_IMPORT_DONE)
	check(audio._preview_token == 0 and batches.size() == 1 and batches[0].size() == 1, "Explicit Add stops preview and imports only checked files")
	main.background_audio = null; main.music_menu = null; main.photo_menu = null; main.recent_menu = null; main.player_menu = null; main.free()
	music.free(); home.free(); photo.free(); audio.player.free(); audio.player = null; audio.importer.free(); audio.free()
	await process_frame
	print("Music quick controls: %d checks, %d failures" % [checks, failures]); quit(1 if failures else 0)
