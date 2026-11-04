extends SceneTree
const Menu := preload("res://scripts/library_menu.gd")
const Video := preload("res://scripts/mpv_video_display.gd")
const Recent := preload("res://scripts/recent_files.gd")
const Compact := preload("res://tests/test_compact_library.gd")
const Fixture := preload("res://tests/test_media_servers.gd")
const Browser := preload("res://scripts/media_server_browser.gd")
const Gallery := preload("res://scripts/media_server_gallery.gd")
var checks := 0
var failures: Array[String] = []

class Platform extends Fixture.Platform:
	var reports: Array = []
	func media_server_playback(raw: String) -> void: reports.append(JSON.parse_string(raw))
	func close_mpv_video(_id: int) -> void: pass
	func set_mpv_playing(_id: int, _playing: bool) -> void: pass

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)
func _initialize() -> void: call_deferred("run")
func run() -> void:
	preload("res://scripts/i18n.gd").use("en")
	for page in ["home", "detail"]:
		for placement in ["hidden", "visible", "attached"]:
			await return_case(placement, page)
	await version_cases()
	for failure in failures: push_error(failure)
	print("Media server resume return: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)

func return_case(placement: String, page: String) -> void:
	var label := page + "/" + placement
	var main := Compact.Harness.new(); root.add_child(main)
	var platform := Platform.new()
	var video := Video.new(); main.add_child(video); video.set_process(false); main.video = video; video.platform = platform
	var path := "user://server-resume-%s-%s-%d" % [page, placement, Time.get_ticks_usec()]
	video.recent_files = Recent.new(path)
	var photo := Compact.Photo.new(); main.add_child(photo); main.photo = photo; photo.set_process(false)
	var player := Compact.Player.new(); main.add_child(player); player.set_process(false)
	main.video_menu = player; main.player_menu = player; player.state_provider = main._menu_state
	var menu := Menu.new(); main.add_child(menu); menu.set_process(false); menu.attach_platform(platform); main.recent_menu = menu
	main.cast_session.bind(main, null)
	menu.catalog = video.recent_files; menu.current_file_provider = func(): return video.local_uri
	player.expanded_library = menu
	var uri := "medialib://profile/scene/film"
	video.local_uri = uri; video.display_name = "Resume film"; video._remember_file = true
	video.media.begin(7); video.media.state = "playing"; video.media.generation = 3; video.media.frame_counter = 1
	video.media.last_pair = {"session_id": 7, "generation": 3, "source_pts_verified": true, "pts_us": 60000000}
	video.panel.visible = true; video.control.duration_ms = 600000
	video._record_history(true); video.server_playback.begin(uri); video.server_playback.poll(video, true)
	menu.section = Menu.Section.MEDIA_SERVER
	var b: RefCounted = menu.server_browser
	b.server = {"id": "profile", "name": "Jellyfin", "provider": "jellyfin"}; b.view = "home"
	b.capabilities = {"home_layout": "libraries", "artwork": true, "navigation": []}
	b.home_data = {"libraries": [], "recent_opened": [{"id": "film", "uri": uri, "title": "Resume film", "duration_ms": 600000, "position_ms": 60000}]}
	if page == "detail":
		b.detail = {"id": "film", "uri": uri, "title": "Resume film", "duration_ms": 600000, "position_ms": 60000}
		b.entries = [b.detail.duplicate(true)]; b.view = "detail"
	menu.visible = true; menu.refresh(); menu.remember_playback_context(uri)
	if placement == "hidden": menu.visible = false
	if placement == "attached": menu.reparent(player, false)
	# The displayed seek landing is confirmed, but the next five-second disk save is not due.
	video.control.seek_absolute(123000); video.control.take_pending(); video.control.first_frame(120000)
	video.media.last_pair.pts_us = 120000000; video.server_playback.seek_serial += 1
	video._history_save_ms = Time.get_ticks_msec() + 5000
	video._record_history(); video.server_playback.poll(video, true)
	main._close_current_media()
	check(video.recent_files.resume_position(uri) == 120000, label + ": close checkpoints the confirmed seek landing")
	var reloaded := Recent.new(path); reloaded.load_saved()
	check(reloaded.resume_position(uri) == 120000, label + ": final progress is persisted")
	if page == "home":
		var recent_rows: Array = menu.rows.filter(func(row): return row.has("recent_opened"))
		check(recent_rows.size() == 1 and int(recent_rows[0].scene.position_ms) == 120000, label + ": homepage row displays the final position on return")
	else:
		check(b.gallery.playback_node().position_ms == 120000, label + ": restored detail resumes at the current local position")
	check(b.home_recent_entries().size() == 1 and int(b.home_recent_entries()[0].position_ms) == 120000, label + ": live homepage data has the final position")
	check(platform.reports.size() >= 3 and platform.reports[-2].position_ms == 120000 and platform.reports[-1].action == "stop", label + ": confirmed position precedes the final server stop")
	if page == "home":
		b.gallery.action(Gallery.RECENT)
		check(platform.requests[platform.next].recent_position_ms == 120000, label + ": recent card opens detail with the latest position")
		platform.answer(platform.next, {"detail": {"id": "film", "uri": uri, "title": "Resume film", "duration_ms": 600000, "position_ms": 60000}})
	b.gallery.action(Browser.ACTION + 30)
	check(b.selection.get("uri", "") == uri and b.selection.get("start_ms", 0) == 120000, label + ": pressing Play resumes from the new landing")
	menu.visible = false; main.queue_free(); await process_frame
	platform.free()

func version_cases() -> void:
	var menu := Menu.new(); root.add_child(menu); menu.set_process(false)
	var catalog := Recent.new("user://server-resume-versions-%d" % Time.get_ticks_usec())
	menu.catalog = catalog; menu.section = Menu.Section.MEDIA_SERVER; menu.visible = true
	var b: RefCounted = menu.server_browser
	b.server = {"id": "profile", "provider": "jellyfin"}; b.view = "detail"; b.capabilities = {"artwork": true}
	var base := "medialib://profile/scene/film"
	var a := base + "?source=a"; var second := base + "?source=b"
	catalog.opened(a, "Cut A", false); catalog.progress(a, 45000, 600000)
	catalog.opened(second, "Cut B", false); catalog.progress(second, 600000, 600000, true)
	b.detail = {"id": "film", "uri": base, "title": "Film", "position_ms": 60000, "versions": [
		{"uri": a, "source_id": "a", "default_version": true, "position_ms": 1000},
		{"uri": second, "source_id": "b", "position_ms": 2000}]}
	b.gallery.selected_versions.film = "b"
	check(b.gallery.playback_node().position_ms == 0, "A completed version stays at zero despite stale cached progress")
	b.gallery.action(Browser.ACTION + 30)
	check(b.selection.uri == second and b.selection.start_ms == 0, "Completed selected cut replays from the start")
	b.gallery.selected_versions.film = "a"
	check(b.gallery.playback_node().position_ms == 45000, "Changing cuts reads that cut's independent latest progress")
	catalog.progress(a, 12000, 600000)
	check(b.gallery.playback_node().position_ms == 12000, "A backward seek can replace a larger cached position")
	b.gallery.action(Browser.ACTION + 30)
	check(b.selection.uri == a and b.selection.start_ms == 12000, "Reopening uses the new backward landing without switching versions")
	check(b.detail.position_ms == 60000 and b.detail.versions[0].position_ms == 1000, "Overlay does not rewrite cached server metadata")
	menu.free(); await process_frame
