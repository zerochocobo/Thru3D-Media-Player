extends SceneTree

const Menu := preload("res://scripts/player_menu.gd")
const Main := preload("res://scripts/main.gd")
const Video := preload("res://scripts/mpv_video_display.gd")
const Memory := preload("res://scripts/file_mode_memory.gd")
const Catalog := preload("res://scripts/recent_files.gd")
const DiscTitles := preload("res://scripts/disc_titles.gd")
const TitlePanel := preload("res://scripts/disc_titles_panel.gd")
var checks := 0
var failures: Array[String] = []

class RayMain extends "res://scripts/main.gd":
	var test_rays := {}
	func _ray(hand: String) -> Variant: return test_rays.get(hand)
	func _controller_allowed(_hand: String) -> bool: return true
	func _input_focused() -> bool: return true

class Host extends RefCounted:
	var calls: Array = []
	var titles := ""
	var menu_state := {"active": false}
	var overlay := PackedByteArray()
	func mpv_supported() -> bool: return true
	func mpv_disc_menu_state() -> String: return JSON.stringify(menu_state)
	func mpv_disc_menu_overlay(_version: int) -> PackedByteArray: return overlay
	func mpv_disc_menu_input(kind: int, x: int, y: int) -> int:
		calls.append(["menu_input", kind, x, y]); return 1
	func set_mpv_disc_title(playlist: int) -> bool:
		calls.append(["disc", playlist]); return true
	func mpv_disc_titles(_id: int) -> String: return titles
	func open_mpv_video(uri: String, start: int, _stereo: bool, _profile: String, _alpha: bool, _vulkan: bool, _depth: bool = false, _top_bottom: bool = false, _exact: bool = false) -> int:
		calls.append(["open", uri, start]); return 7
	func close_mpv_video(id: int) -> void: calls.append(["close", id])
	func set_mpv_playing(id: int, playing: bool) -> void: calls.append(["play", id, playing])
	func set_mpv_audio(_id: int, track: int, _volume: float, _muted: bool) -> bool:
		calls.append(["audio", track]); return true
	func set_mpv_subtitle(_id: int, track: int) -> bool:
		calls.append(["subtitle", track]); return true

func check(value: bool, message: String) -> void:
	checks += 1
	if not value: failures.append(message)

func report(playing: int) -> String:
	return JSON.stringify({"width": 1920, "height": 1080, "duration_us": 1, "mvc": false, "playlist": playing, "menu": "hdmv", "titles": [
		{"playlist": 52, "duration_ms": 290056, "chapters": 2, "height": 480, "stereo": false, "audio": 5, "subtitles": 5},
		{"playlist": 100, "duration_ms": 5808928, "chapters": 30, "height": 1080, "stereo": false, "audio": 5, "subtitles": 5},
		{"playlist": 201, "duration_ms": 602668, "chapters": 2, "height": 2160, "stereo": false, "audio": 5, "subtitles": 5},
		{"playlist": 202, "duration_ms": 290400, "chapters": 2, "height": 480, "stereo": false, "audio": 5, "subtitles": 5}]})

func click(menu: Node3D, target: int) -> bool:
	for button in menu._buttons:
		if button.target == target:
			var centre: Vector2 = button.rect.get_center()
			var ray := menu.to_global(Vector3(centre.x, centre.y, 1))
			var result: bool = menu.press_pointer("right_hand", ray, -menu.global_basis.z, true)
			menu.release_pointer("right_hand", ray, -menu.global_basis.z, true)
			return result
	return false

func shown(menu: Node3D, target: int) -> bool:
	return menu._buttons.any(func(button): return button.target == target)

func _check_disc_menu(video: Node3D, host: Host, menu: Node3D, uri: String) -> void:
	host.titles = report(100); video.disc.poll(host, 7, 30000)
	check(video.disc.menu_available(), "An HDMV top menu can be played")
	menu.disc_titles.opened = true; menu.refresh()
	check(menu._buttons.any(func(button): return button.target == TitlePanel.MENU_ROW), "The disc menu leads the title list")
	host.calls.clear()
	check(click(menu, TitlePanel.MENU_ROW) and host.calls.has(["disc", -2]) and video.disc.menu_session and video.disc.extra(),
		"Choosing it reopens the disc in its menu, which keeps the main title's resume position")
	check(not video.open_disc_menu(), "An open menu is not reopened")
	check(not menu.visible, "Entering the disc menu hides the player bar")
	menu.toggle()
	host.titles = report(100); video.disc.poll(host, 7, 31000)
	check(video.disc.titles.size() == 3 and video.disc.main == 100, "The menu session keeps the disc's titles")
	# A 2 x 1 button crop at (10, 1000) of a 1920 x 1080 plane.
	var data := PackedByteArray(); data.resize(24 + 8)
	for i in 6: data.encode_s32(i * 4, [10, 1000, 2, 1, 1920, 1080][i])
	host.overlay = data
	host.menu_state = {"active": true, "version": 4, "width": 1920, "height": 1080, "title": 0, "playlist": 120, "menu": true, "seen": true, "buttons": true}
	check(video.disc_menu.poll(host, 40000) and video.disc_menu.bitmap.x == 10 and video.disc_menu.bitmap.canvas_height == 1080 and video.disc_menu.pixels.size() == 8,
		"The button plane arrives as a positioned cue")
	check(video.disc_menu.plane_point(Vector2(0.5, 0.5)) == Vector2i(960, 540), "Screen UV maps to plane pixels")
	var hovers := func() -> int: return host.calls.filter(func(call): return call[0] == "menu_input" and call[1] == 0).size()
	video.disc_menu.point(host, Vector2(0.2, 0.5), 40900); video.disc_menu.point(host, Vector2(0.21, 0.5), 40950)
	check(hovers.call() == 0, "Sweeping across buttons does not select them")
	video.disc_menu.point(host, Vector2(0.5, 0.5), 41000); video.disc_menu.point(host, Vector2(0.5, 0.5), 41150); video.disc_menu.point(host, Vector2(0.5, 0.5), 41300)
	check(hovers.call() == 1, "A resting ray selects once per position")
	check(video.disc_menu.activate(host, Vector2(0.5, 0.5)) and host.calls.back() == ["menu_input", 1, 960, 540], "The trigger activates the button under the ray")
	host.calls.clear()
	for t in [41400, 41600, 41800]: video.disc_menu.point(host, Vector2(0.505, 0.5), t)
	check(hovers.call() == 0, "After a press the resting ray leaves the focus to the disc (a submenu keeps it)")
	for t in [42000, 42200]: video.disc_menu.point(host, Vector2(0.7, 0.5), t)
	check(hovers.call() == 1, "Pointing resumes once the ray moves away")
	# Through the controller handler: the trigger is a chord modifier, the menu must still get it.
	var whole := PackedByteArray(); whole.resize(24 + 4)
	for i in 6: whole.encode_s32(i * 4, [0, 0, 1, 1, 1920, 1080][i])
	host.overlay = whole
	host.menu_state = {"active": true, "version": 6, "width": 1920, "height": 1080, "title": 0, "playlist": 120, "menu": true, "seen": true, "buttons": true}
	video.disc_menu.poll(host, 40500)
	video.disc_menu.bitmap.width = 1920; video.disc_menu.bitmap.height = 1080 # the whole plane is drawn
	var main: Node = menu.state_provider.get_object()
	video.panel.visible = true # a presented menu frame
	main.test_rays["right_hand"] = [video.panel.to_global(Vector3(0, 0, 1.0)), -video.panel.global_basis.z]
	main.player_menu = null
	host.calls.clear()
	check(main._input_feedback_visible(), "The ray is drawn while a disc menu plays")
	main._on_controller_button("trigger_click", "right_hand")
	check(host.calls.any(func(call): return call[0] == "menu_input" and call[1] == 1), "A trigger press on the screen reaches the disc menu")
	main._on_controller_release("trigger_click", "right_hand") if main.has_method("_on_controller_release") else null
	main.controller_bindings.down["right_hand"].clear()
	host.calls.clear()
	main._on_controller_button("by_button", "right_hand")
	check(host.calls.has(["menu_input", 7, 0, 0]), "B goes back to the disc's top menu")
	main.controller_bindings.down["right_hand"].clear()
	main.player_menu = menu
	check(video.disc_menu.handoff(video.disc.titles, 42000).is_empty(), "The menu itself never hands off")
	host.menu_state = {"active": true, "version": 5, "title": 1, "playlist": 100, "chapter": 3, "chapter_ms": 600000, "menu": false, "seen": true, "buttons": false,
		"audio_index": 1, "subtitle_index": 1}
	video.disc_menu.poll(host, 43000)
	check(video.disc_menu.handoff(video.disc.titles, 43000).is_empty(), "A started title is confirmed before leaving the menu")
	host.calls.clear()
	video.media.playback = {}
	video._poll_disc_menu(43400)
	check(host.calls.has(["disc", 100]) and host.calls.any(func(call): return call[0] == "open" and call[2] == 600000) and not video.disc.menu_session,
		"A menu choice continues in ordinary title playback at its chapter")
	# The title's tracks arrive later; the disc's language choice selects them by PID.
	host.calls.clear()
	video.media.playback = {"details": {"pgs_supported": true, "audio_tracks": [{"id": 1, "stream_index": 1}, {"id": 2, "stream_index": 2}, {"id": 3, "stream_index": 9, "external": true}],
		"subtitle_tracks": [{"id": 1, "stream_index": 3, "codec": "hdmv_pgs_subtitle"}, {"id": 2, "stream_index": 4, "codec": "hdmv_pgs_subtitle"}]}}
	video._apply_disc_tracks()
	check(host.calls.has(["audio", 2]) and host.calls.has(["subtitle", 2]) and video._disc_tracks.is_empty(), "The disc menu's audio and subtitle choices carry into playback")
	host.titles = report(100); video.disc.poll(host, 7, 44000)
	host.menu_state = {"active": false}
	# The toolbar under a disc menu: top menu, continue, from the start, eject.
	var bar := preload("res://scripts/disc_menu_bar.gd").new()
	root.add_child(bar)
	bar.sync(true)
	check(bar._buttons.map(func(button): return button.target) == [1, 2, 3, 4] and bar._tips.size() == 4, "Four icon keys with tooltips")
	video.panel.visible = true
	var head: Vector3 = video.panel.to_global(Vector3(0, 0, 12.0)) # a cinema-like distance
	var edge: Vector3 = video.panel.to_global(Vector3(0, -video._flat.size.y * 0.5, 0))
	bar.place(video.panel, video._flat.size, head)
	check((bar.global_position - head).normalized().y < (edge - head).normalized().y and is_equal_approx(bar.global_basis.get_scale().x, 1.0)
		and head.distance_to(bar.global_position) < 1.2, "The toolbar is seen under the screen, at arm's length and real size")
	for case in [["top_menu", 7], ["restart", 0], ["resume", 1234000]]:
		check(video.open_disc_menu() or video.disc.menu_session, "A disc menu is open for " + case[0])
		host.menu_state = {"active": true, "version": 9, "title": 0, "playlist": 120, "menu": true, "seen": true, "buttons": true}
		video.disc_menu.poll(host, 50000 + case[1])
		host.calls.clear()
		main._on_disc_menu_bar(case[0])
		if case[0] == "top_menu":
			check(host.calls.has(["menu_input", 7, 0, 0]) and video.disc.menu_session, "The menu key returns to the disc's top menu")
		else:
			check(host.calls.has(["disc", 100]) and host.calls.any(func(call): return call[0] == "open" and call[2] == case[1]),
				"%s opens the main title at %d ms" % [case[0], case[1]])
	bar.queue_free()
	host.menu_state = {"active": false}

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	preload("res://scripts/i18n.gd").use("en")
	var ordered := DiscTitles.ordered(JSON.parse_string(report(100)).titles, 100)
	check(ordered.map(func(row): return int(row.playlist)) == [100, 201, 202], "Main title first, then longer titles; a same-length copy is listed once")
	check(DiscTitles.duration_text(5808928) == "1:36:48" and DiscTitles.duration_text(290056) == "4:50", "Durations read as clock times")

	var directory := ProjectSettings.globalize_path("res://../../build/output/disc-titles-host/" + str(Time.get_ticks_usec()))
	DirAccess.make_dir_recursive_absolute(directory)
	var host := Host.new()
	var video := Video.new()
	video.bookmark_store = preload("res://scripts/bookmark_store.gd").new(directory.path_join("bookmarks"))
	video.mode_memory = Memory.new(directory.path_join("modes"))
	video.recent_files = Catalog.new(directory.path_join("recent"))
	root.add_child(video)
	video.set_process(false)
	video.platform = host
	var main := RayMain.new()
	main.settings_path = directory.path_join("settings.cfg")
	main.video = video
	var menu := Menu.new()
	menu.state_provider = main._menu_state
	menu.setting_requested.connect(main._on_player_setting)
	root.add_child(menu)
	menu.set_process(false)
	main.player_menu = menu

	var uri := "cloud://acc/Soylent.iso"
	video.open_local(uri, "Soylent", 0, true)
	check(host.calls.has(["disc", -1]), "A library open plays the disc's default title")
	video.media.state = "playing"
	check(not video.disc.poll(host, 7, 0) and video.disc.titles.is_empty(), "No title list before the preflight reports one")
	host.titles = report(100)
	check(video.disc.poll(host, 7, 1000) and video.disc.main == 100 and video.disc.playing == 100 and not video.disc.extra(), "The preflight's title is the main title")
	check(not video.disc.poll(host, 7, 2000), "One report per open: no repeated polling once known")
	menu.toggle()
	check(video.disc.first_view and shown(menu, TitlePanel.BUTTON) and menu.disc_titles.opened and shown(menu, TitlePanel.ROW + 1), "A disc's first viewing shows the button and opens its list by itself once")
	var labels: Array = menu._buttons.filter(func(button): return button.target == TitlePanel.ROW + 1)[0].node.get_children().filter(func(node): return node is Label3D).map(func(label): return label.text)
	check(labels.has("Extra 1") and labels.has("10:02") and not labels.any(func(text): return "chapter" in text), "Rows name the title and its length only")
	check(not menu.allows_playback_sticks(), "Sticks scroll the open list instead of playback shortcuts")
	check(menu.navigate_back() and not menu.disc_titles.opened, "Back closes the title list")
	menu.refresh()
	check(not menu.disc_titles.opened, "The list does not reopen by itself for the same disc")
	check(click(menu, TitlePanel.BUTTON) and menu.disc_titles.opened, "The button reopens the list")
	host.calls.clear()
	check(click(menu, TitlePanel.ROW + 1) and host.calls.has(["disc", 201]) and host.calls.any(func(call): return call[0] == "open" and call[1] == uri and call[2] == 0),
		"Choosing an extra reopens the same disc on that playlist from its start")
	check(not menu.disc_titles.opened, "Choosing a title closes the list")
	host.titles = report(201)
	check(video.disc.poll(host, 7, 5000) and video.disc.playing == 201 and video.disc.main == 100 and video.disc.extra(), "The extra plays while the main title stays known")
	host.calls.clear()
	video._reopen_at(30000, false)
	check(host.calls.has(["disc", 201]), "An internal reopen stays on the playing extra")
	host.titles = report(201); video.disc.poll(host, 7, 9000)
	video.recent_files.opened(uri, "Soylent", false)
	video.recent_files.progress(uri, 1234000, 5808928)
	video.history_enabled = true
	host.calls.clear()
	check(video.select_disc_title(100) and host.calls.has(["disc", 100]) and host.calls.any(func(call): return call[0] == "open" and call[2] == 1234000),
		"Returning to the main title resumes its saved position")
	check(not video.select_disc_title(999), "Only listed titles can be chosen")
	_check_disc_menu(video, host, menu, uri)
	# A menu that cannot run (BD-J behind an HDMV stub) returns to the main title.
	check(video.open_disc_menu(), "The menu can be opened again")
	host.calls.clear()
	video._on_error(video.media.session_id, JSON.stringify({"code": "MPV_SOURCE_START_FAILED"}))
	await process_frame
	check(host.calls.has(["disc", 100]) and video.media.error.is_empty() and not video.disc.menu_session, "A failed menu reopens the main title without an error")
	host.titles = report(100); video.disc.poll(host, 7, 50000)
	check(not video.disc.menu_available(), "The failed menu is not offered again for this disc")
	menu.disc_titles.opened = true; menu.refresh()
	var java_row: Array = menu._buttons.filter(func(button): return button.target == TitlePanel.MENU_ROW)
	var java_text: Array = java_row[0].node.get_children().filter(func(node): return node is Label3D).map(func(label): return label.text) if not java_row.is_empty() else []
	check(java_row.size() == 1 and not java_row[0].enabled and java_text.has("BD-J menu") and java_text.has("Not supported yet"),
		"Its place names the Java menu, greyed and not clickable")
	host.calls.clear()
	click(menu, TitlePanel.MENU_ROW)
	check(not host.calls.has(["disc", -2]), "The greyed menu row does nothing")
	menu.disc_titles.reset()
	host.calls.clear()
	video.open_local("cloud://acc/Other.mp4", "Other", 0, true)
	menu.refresh()
	video.open_local(uri, "Soylent", 0, true)
	host.titles = report(100); video.disc.poll(host, 7, 20000)
	menu.refresh()
	check(not video.disc.first_view and not menu.disc_titles.opened and shown(menu, TitlePanel.BUTTON), "A disc with a playback record never opens its list by itself")
	host.calls.clear()
	video.open_local("cloud://acc/Other.mp4", "Other", 0, true)
	check(host.calls.has(["disc", -1]) and video.disc.titles.is_empty() and video.disc.main == -1, "Another file forgets the disc and its request")
	menu.refresh()
	check(not shown(menu, TitlePanel.BUTTON), "Media without titles has no disc button")

	menu.queue_free(); main.video = null; main.free(); video.queue_free(); await process_frame
	for failure in failures: push_error(failure)
	print("Disc titles: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
