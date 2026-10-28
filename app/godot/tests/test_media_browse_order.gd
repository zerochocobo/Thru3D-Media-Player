extends SceneTree
const Menu := preload("res://scripts/library_menu.gd")
const Order := preload("res://scripts/library_order.gd")
const Photo := preload("res://scripts/photo_display.gd")
const Compact := preload("res://tests/test_compact_library.gd")
var checks := 0
var failures: Array[String] = []

class Cloud extends RefCounted:
	signal media_list(id: int, payload: String)
	var requests: Array[Dictionary] = []
	func media_cloud_sorted_page(path: String, offset: int, _force: bool, order: String) -> int:
		requests.append({"path":path,"offset":offset,"order":order}); return requests.size()
	func media_photo_directory_page(path: String, offset: int, order: String) -> int:
		return media_cloud_sorted_page(path, offset, false, order)
	func media_photo_directory_cancel(_id: int) -> void: pass
	func media_cloud_cancel(_id: int) -> void: pass
	func respond(entries: Array, next: int = -1) -> void:
		var result: Dictionary = requests.back().duplicate()
		result.merge({"state":"ready","entries":entries,"next_offset":next,"total":144})
		media_list.emit(requests.size(), JSON.stringify(result))

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok: failures.append(label)

func _initialize() -> void: call_deferred("run")

func run() -> void:
	var menu := Menu.new(); root.add_child(menu); menu.set_process(false)
	menu.section = Menu.Section.LOCAL; menu._local_stack = [{"id":"/order", "title":"Order"}]
	var entries: Array = [{"id":"folder", "title":"Folder", "container":true}]
	for number in [10, 2, 1]:
		for extension in ["png", "mp4"]:
			entries.append({"title":"%d.%s" % [number, extension], "uri":"file:///order/%d.%s" % [number, extension],
				"kind":"image" if extension == "png" else "video", "modified":number, "size":11-number})
	menu._local_entries = entries
	for order in ["name_asc", "name_desc", "modified_desc", "size_desc"]:
		menu.file_actions.orders = {str(Menu.Section.LOCAL):order}; menu.refresh()
		var numbers := [1,2,10] if order in ["name_asc", "size_desc"] else [10,2,1]
		check(menu.rows[0].has("container"), "Folders stay first for " + order)
		check(menu.image_queue().map(func(row): return row.title) == numbers.map(func(n):return "%d.png" % n), "Images inherit the visible sort: " + order)
		check(menu.video_queue().map(func(row): return row.title) == numbers.map(func(n):return "%d.mp4" % n), "Videos inherit the visible sort: " + order)
	menu.file_actions.orders.clear()
	menu._local_entries.clear()
	for number in 80:
		menu._local_entries.append({"title":"%d.png" % number, "uri":"file:///order/%d.png" % number, "kind":"image"})
	menu.view_mode = "grid"; menu.compact = true; menu.refresh(); menu._set_scroll(5.25)
	var current := {"uri":str(menu.rows[19].uri)}
	menu.current_file_provider = func(): return current.uri
	menu.remember_playback_context(); menu.dismiss(); menu.show_playback_files(true)
	check(is_equal_approx(menu.scroll, 5.25), "Returning to an image already in view preserves the exact viewport")
	current.uri = str(menu.rows[51].uri)
	menu.show_playback_files()
	check(menu._current_file_visible() and menu.scroll > 5.25, "Navigating beyond the viewport reveals the current URI")
	var moved_scroll: float = menu.scroll
	menu.dismiss(); menu.show_playback_files(true)
	check(is_equal_approx(menu.scroll, moved_scroll), "A second return preserves the updated playback viewport")
	menu._activate(Menu.FILTER_BASE + 2); menu.remember_playback_context(); menu.dismiss(); menu.show_playback_files(true)
	check(menu.media_filter == 2, "Returning to playback preserves its chosen media filter")
	menu.queue_free(); await process_frame
	var photo := Photo.new(); root.add_child(photo); photo.set_process(false)
	photo.queue.assign([{ "uri":"file:///a.png", "title":"a.png", "kind":"image" },
		{"uri":"file:///b.png", "title":"b.png", "kind":"image"}])
	photo.local_uri = "file:///a.png"; photo.index = 0
	var reversed: Array[Dictionary] = [photo.queue[1],photo.queue[0]]
	photo._directory_result = {"entries":reversed,"complete":true,"error":""}
	photo._replace_directory()
	check(photo.queue[0].uri == "file:///a.png" and not photo.queue_complete, "A changed directory snapshot cannot silently reverse the active album")
	photo.queue_free(); await process_frame
	await flow_cases()
	await cloud_cases()
	for failure in failures: push_error(failure)
	print("Media browse order: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)

func flow_cases() -> void:
	var main := Compact.Harness.new(); root.add_child(main)
	main.settings_path = "user://media-browse-order.cfg"
	var video := Compact.LocationVideo.new(); video.history_enabled = false; main.add_child(video); video.set_process(false); main.video = video
	var photo := Photo.new(); photo.history_enabled = false; main.add_child(photo); photo.set_process(false); main.photo = photo
	var player := Compact.Player.new(); main.add_child(player); player.set_process(false)
	main.video_menu = player; main.player_menu = player; player.state_provider = main._menu_state
	var photo_menu := Compact.PhotoMenu.new(); main.add_child(photo_menu); photo_menu.set_process(false); main.photo_menu = photo_menu
	photo_menu.state_provider = photo.snapshot
	var menu := Menu.new(); main.add_child(menu); menu.set_process(false); main.recent_menu = menu
	main.cast_session.bind(main, null)
	menu.current_file_provider = func():return main._viewer().local_uri
	menu.chosen.connect(main._on_library_chosen); menu.directory_order_changed.connect(main._on_directory_order_changed)
	player.expanded_library = menu; photo_menu.expanded_library = menu
	menu.section = Menu.Section.LOCAL; menu._local_stack = [{"id":"/order","title":"Order"}]
	for i in 80: menu._local_entries.append({"uri":"file:///order/%d.mp4" % i,"title":"%d.mp4" % i})
	menu.view_mode = "list"; menu.visible = true; menu.refresh(); menu._set_scroll(38)
	menu._choose(menu.rows[40]); main._show_recent_menu()
	check(video.local_uri == "file:///order/40.mp4" and menu._current_file_visible(), "Production selection and playback list agree on the selected video")
	menu.file_actions.choose_order("name_desc")
	check(video.local_uri == "file:///order/40.mp4" and main._adjacent_video(1).uri == "file:///order/39.mp4", "Changing sort during playback updates next-video order without reopening the current video")
	main._navigate_video(1); main._show_recent_menu(); main._show_recent_menu()
	check(video.local_uri == "file:///order/39.mp4" and menu._current_file_visible(), "Returning after navigation locates the current video by URI")
	menu._activate(Menu.FILTER_BASE + 1)
	main._close_current_media()
	check(menu.visible and not menu.compact and menu.rows[0].title == "79.mp4" and menu.collections.reveal_uri == "file:///order/39.mp4", "Closing media restores the sorted full browser and highlights the last current file")
	check(menu.media_filter == 1, "Closing playback keeps the source list's explicit filter")
	menu.media_filter = 0
	menu._local_entries = [{"uri":"file:///order/1.png","title":"1.png","kind":"image"},
		{"uri":"file:///order/2.png","title":"2.png","kind":"image"},{"uri":"file:///order/10.png","title":"10.png","kind":"image"}]
	menu.refresh(); photo.queue.assign(menu.image_queue()); photo.index = 1; photo.local_uri = "file:///order/2.png"
	main.photo_active = true; main.player_menu = photo_menu; menu.remember_playback_context(photo.local_uri)
	menu.file_actions.choose_order("name_asc")
	check(photo.index == 1 and photo.local_uri == "file:///order/2.png" and photo.queue[2].title == "10.png", "Changing the active album sort preserves its current URI and applies natural next-image order")
	main.photo_active = false; main.player_menu = player
	var cloud := Cloud.new(); video.platform = cloud; video.local_uri = "cloud://drive/album/2.mp4"; video.media.state = "playing"
	video.source_location = {"type":"cloud","path":"/drive/album"}
	main.video_queue.assign([{"uri":video.local_uri,"title":"2.mp4"}])
	main._start_video_directory({"path":"/drive/album","order":"name_asc"})
	cloud.respond([{"uri":"cloud://drive/album/1.mp4","title":"1.mp4"}], 48)
	cloud.respond([{"uri":video.local_uri,"title":"2.mp4"},{"uri":"cloud://drive/album/3.mp4","title":"3.mp4"}])
	check(main._adjacent_video(-1).uri == "cloud://drive/album/1.mp4" and main._adjacent_video(1).uri == "cloud://drive/album/3.mp4", "Cloud video directory completion supplies both previous and next across the opened page")
	check(main._playback_browser_cursor().offset == 48, "Video return cursor identifies the current file's source page")
	main.free(); await process_frame

func cloud_cases() -> void:
	var cloud := Cloud.new()
	var menu := Menu.new(); root.add_child(menu); menu.set_process(false); menu.attach_platform(cloud)
	menu.section = Menu.Section.CLOUD; menu._cloud_stack = [{"id":"/drive/album","title":"Album"}]
	menu._cloud_offsets.assign([0]); menu._cloud_next = 48; menu._cloud_total = 144
	var first := {"uri":"cloud://drive/album/1.png","title":"1.png","kind":"image"}
	var last := {"uri":"cloud://drive/album/100.png","title":"100.png","kind":"image"}
	menu._cloud_entries = [first]; menu.visible = true; menu.refresh(); menu.remember_playback_context(str(first.uri))
	var directory := Photo.Directory.new(); root.add_child(directory); directory.platform = cloud
	directory.start({"path":"/drive/album","order":"name_asc"})
	cloud.respond([first], 48); cloud.respond([{"title":"Folder","container":true}], 96); cloud.respond([last])
	var cursor: Dictionary = directory.cursor(str(last.uri))
	check(cursor.offset == 96 and cursor.offsets == [0,48,96], "Album cursor retains metadata pages with no matching media")
	menu.current_file_provider = func():return last.uri
	menu.dismiss(); menu.show_playback_files(true, cursor); menu.visible = true
	check(cloud.requests.back().offset == 96, "Returning after cross-page image navigation loads the actual source page")
	cloud.respond([last])
	check(menu._cloud_page == 2 and menu._current_file_visible(), "Async cloud return preserves the current file and page instead of the original selection page")
	var requests := cloud.requests.size()
	menu.dismiss(); menu.show_playback_files(true, cursor)
	check(menu._cloud_page == 2 and cloud.requests.size() == requests, "Repeated return reuses the updated page snapshot")
	directory.free(); menu.free(); await process_frame
