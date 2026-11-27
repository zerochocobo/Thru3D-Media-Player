extends SceneTree

const Menu := preload("res://scripts/library_menu.gd")
const Fixture := preload("res://tests/test_library_menu.gd")
const I18n := preload("res://scripts/i18n.gd")
const PlayerMenu := preload("res://scripts/player_menu.gd")
var failures: Array[String] = []
var checks := 0

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func settle() -> void:
	await process_frame; await process_frame; await process_frame

func _initialize() -> void: _run.call_deferred()

func _run() -> void:
	var menu := Menu.new()
	var platform := Fixture.FakePlatform.new()
	var progress := "user://test-experience-%d.cfg" % Time.get_ticks_usec()
	var config := ConfigFile.new()
	config.set_value("library", "restore_position", true) # Existing install without an experience mark.
	menu.bind_experience_guide(config, progress)
	root.add_child(menu); menu.attach_platform(platform); menu.toggle()
	I18n.use("zh")
	menu._activate(Menu.NAV_BASE + Menu.Section.LOCAL)
	check(menu.rows.front().title == "体验内容", "Folder is available before the device replies")
	await settle()
	check(menu.rows.map(func(row): return row.container.id) == [Menu.Experience.FOLDER, "/storage/emulated/0", "/storage/1234-5678"], "Experience, internal storage and USB retain their order")
	check(menu.rows.front().experience_guide and not FileAccess.file_exists(progress), "Viewing the root alone does not acknowledge the guide")
	var opens: Array = []
	menu.chosen.connect(func(uri, title): opens.append([uri, title]))
	var reads := platform.calls.size()
	menu._activate(Menu.ROW_BASE)
	var saved := ConfigFile.new()
	check(saved.load(progress) == OK and saved.get_value("library", "experience_seen_version", -1) == Menu.Experience.GUIDE_VERSION, "Opening persists the guide revision before media selection")
	check(opens.is_empty() and platform.calls.size() == reads and not menu._local_grant_needed(), "Opening offline requests neither playback nor shared storage")
	check(not menu.file_actions.sortable() and not menu.file_actions.folder(), "The curated folder is read-only")
	var books := {"zh": "tao-zh-hans.epub", "zh_Hant": "tao-zh-hant.epub", "en": "peter-rabbit-en.epub", "ja": "yamanashi-ja.epub"}
	var video_uri: String = menu.rows.front().uri
	for language in books:
		I18n.use(language); menu.refresh()
		check(menu.rows.map(func(row): return row.kind) == ["video", "video", "image", "image", "book"], "Catalog order for " + language)
		check(menu.rows.back().uri.ends_with(books[language]) and menu._header_title().contains(menu.experience.title(language)), "Localized book and breadcrumb for " + language)
		check(menu.rows.front().uri == video_uri and menu.experience.entries(language, false).size() == 4, "Common media identity and retail reader switch for " + language)
		for row in menu.rows:
			var path: String = row.uri.trim_prefix("file://").uri_decode()
			if OS.get_name() == "Windows": path = path.trim_prefix("/")
			check(FileAccess.file_exists(path) and menu._picture(row) != null and row.enabled, "Readable file and cover for " + str(row.title))
	check(menu.video_queue().size() == 2 and menu.image_queue().size() == 2, "Normal video and photo queues include both samples")
	platform.usb_connected = false
	platform.media_list.emit(0, JSON.stringify({"source": "local_storage", "state": "changed", "volumes": platform.storage_volumes()}))
	menu._pending[775] = "local"; menu._on_media_list(775, '{"state":"denied"}')
	await settle()
	check(menu.experience_open() and menu.status.is_empty() and menu.rows.size() == 5 and platform.calls.size() == reads, "USB removal and a late permission denial leave the catalog open")
	menu._activate(Menu.BACK); await settle()
	check(menu.rows.size() == 2 and not menu.rows.front().experience_guide and opens.is_empty(), "Leaving without selecting media suppresses the reminder")
	menu._activate(Menu.ROW_BASE)
	menu._activate(Menu.FILTER_BASE + 1)
	menu._choose(menu.rows.front())
	check(opens.size() == 1 and opens[0][0] == video_uri and menu.take_experience_hint(video_uri).is_empty(), "Ordinary revisit opens the real video without guidance")
	menu.show_playback_files(true)
	check(menu.experience_open() and menu.media_filter == 1 and menu.rows.size() == 2, "Playback return keeps the experience folder and video filter")
	menu._activate(Menu.FILTER_BASE + 2)
	menu._choose(menu.rows.back()); menu.show_playback_files(true)
	check(opens.back()[0].ends_with("greenhouse-after-rain.jpg") and menu.image_queue().size() == 2 and menu.media_filter == 2, "The photo viewer receives the chosen JPEG and its visible album")
	menu.set_compact(false)
	menu._activate(Menu.FILTER_BASE + Menu.BOOK_FILTER)
	menu._choose(menu.rows.front()); menu.toggle()
	check(menu.experience_open() and menu.media_filter == Menu.BOOK_FILTER and menu.rows.size() == 1 and opens.back()[0].ends_with(".epub"), "Closing a book restores the filtered full library")
	menu._go_back(); await settle()
	menu.experience_seen_version = Menu.Experience.GUIDE_VERSION - 1
	menu._activate(Menu.ROW_BASE)
	var portrait: Dictionary = menu.rows[1]
	menu._choose(portrait)
	check(menu.take_experience_hint(portrait.uri) == "portrait_passthrough" and menu.take_experience_hint(portrait.uri).is_empty(), "New revision offers the chosen action once")
	var controls := PlayerMenu.new()
	root.add_child(controls)
	controls.guide_sample(portrait.uri, "portrait_passthrough")
	controls._state = {"source_uri": portrait.uri}
	controls._sample_control(104, "alpha", Vector2.ZERO, 0.075, false, "")
	check(not is_instance_valid(controls._sample_dot), "An unavailable effect gets no cue")
	controls._sample_control(104, "alpha", Vector2.ZERO, 0.075, true, "")
	check(is_instance_valid(controls._sample_dot) and controls._sample_dot.visible, "An available portrait control gets an inline cue")
	controls._consume_sample_control(104)
	check(not controls._sample_dot.visible, "Using the effect consumes the cue")
	var reopened := Menu.new()
	reopened.bind_experience_guide(saved, progress)
	reopened.section = Menu.Section.LOCAL; reopened._rebuild_rows()
	check(not reopened.rows.front().experience_guide, "Restart and language change preserve the acknowledged revision")
	reopened.image_picker_mode = true; reopened._rebuild_rows()
	check(reopened.rows.is_empty(), "The normal image file picker retains its storage-only root")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(progress))
	reopened.free(); controls.queue_free(); menu.queue_free(); await settle(); platform.free()
	for message in failures: push_error(message)
	print("Built-in experience: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
