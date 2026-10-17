extends SceneTree
const Main := preload("res://scripts/main.gd")
const Video := preload("res://scripts/mpv_video_display.gd")
const Pages := preload("res://scripts/video_queue_pages.gd")
var checks := 0
var failures: Array[String] = []

class ProbeMain extends Main:
	var opened: Array = []
	func _open_queued_video(item: Dictionary, automatic: bool) -> void:
		opened.append([item.uri, automatic])
		video.local_uri = item.uri; video.media.begin(video.media.session_id + 1); video.media.state = "playing"
	func _on_video_playback_failed() -> void: pass

class OpenProbe extends Video:
	var opens: Array = []
	func open_local(uri: String, _title: String, start_ms: int = 0, _restore: bool = true, _alpha: bool = false, _basename: String = "", _metadata: Dictionary = {}) -> bool:
		opens.append([uri, start_ms]); return true
	func open_recent(uri: String, from_start: bool = false, _metadata: Dictionary = {}) -> bool:
		opens.append([uri, from_start]); return true

class Host extends RefCounted:
	signal media_list(id: int, payload: String)
	var requests: Array = []
	var cancelled: Array = []
	func media_cloud_directory_page(path: String, offset: int, force: bool, order: String, cloud_id: String) -> int:
		requests.append({"path": path, "offset": offset, "order": order, "force": force, "cloud_id": cloud_id}); return requests.size()
	func media_cloud_cancel(id: int) -> void: cancelled.append(id)
	func media_server_request(body: String) -> int:
		requests.append(JSON.parse_string(body)); return requests.size()
	func media_server_cancel(id: int) -> void: cancelled.append(id)

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func item(name: String) -> Dictionary:
	return {"uri": "file:///" + name + ".mp4", "title": name, "metadata": {"location": {"type": "local", "path": "/media"}}}

func eof(video: Node3D) -> void:
	video.media.state = "ended"; video.requested_play = true
	video.media.last_pair = {"slot_token": 9, "source_epoch": 7, "frame_id": 179, "pts_us": 5966667, "inference_ran": true}
	video.media.playback = {"eof_source_resolved": true, "eof_pair_post_draw": true, "eof_presented_slot": 9,
		"eof_source_ticket": {"source_epoch": 7, "frame_id": 179, "pts_us": 5966667}}

func cloud_context() -> Dictionary:
	return {"type": "cloud", "path": "/drive/movies", "order": "name_asc", "cloud_id": "stable-folder", "next": 48,
		"from_first": true, "location": {"type": "cloud", "path": "/drive/movies"}}

func cloud_result(host: RefCounted, pager: RefCounted, entries: Array, next: int = -1) -> void:
	var request: Dictionary = host.requests[pager.pending - 1]
	host.media_list.emit(pager.pending, JSON.stringify({"state": "ready", "path": request.path, "order": request.order,
		"offset": request.offset, "entries": entries, "next_offset": next}))

func _initialize() -> void: call_deferred("run")

func run() -> void:
	preload("res://scripts/i18n.gd").use("en")
	var video := Video.new(); video.history_enabled = false; video.media.begin(7); video.local_uri = item("a").uri
	var main := ProbeMain.new(); main.video = video; main.settings_path = "user://video-modes-regression.cfg"
	main.video_queue.assign([item("a"), item("b"), item("c")])
	var notifications: Array = []
	video.playback_completed.connect(func(): notifications.append(video.media.session_id))
	video.playback_completed.connect(main._on_video_completed)
	eof(video); video.media.playback.eof_pair_post_draw = false; video._process_playback_end()
	check(notifications.is_empty(), "Decoded EOF cannot advance before the final frame was drawn")
	video.media.playback.eof_pair_post_draw = true; video.requested_play = false; video._process_playback_end()
	check(notifications.is_empty(), "Paused EOF cannot advance")
	video.requested_play = true; video.control.seek_absolute(0); video._process_playback_end()
	check(notifications.is_empty(), "An outstanding seek wins over EOF")
	video.control.reject(); video.media.error = "failed"; video._process_playback_end()
	check(notifications.is_empty(), "A failed source cannot be treated as a completed video")
	video.media.error = ""; video._process_playback_end(); video._process_playback_end()
	check(notifications.size() == 1, "One EOF emits only one completion event across repeated frames")
	await process_frame
	check(main.opened.is_empty(), "Single video mode keeps the last frame")
	for mode in Main.PLAYBACK_MODES:
		main._set_playback_mode(mode)
		check(main.playback_mode == mode and video.loop_enabled == (mode == "repeat_one"), "Each mode persists with only repeat-one enabling the source loop: " + mode)
		var stored := ConfigFile.new(); stored.load(main.settings_path)
		check(stored.get_value("video", "playback_mode") == mode, "Stored playback mode matches the selected mode: " + mode)
	main._set_playback_mode("bad")
	check(main.playback_mode == "repeat_all", "Invalid mode leaves the current selection intact")
	for mode in ["sequence", "repeat_all"]:
		main._set_playback_mode(mode); main.opened.clear(); video.local_uri = item("a").uri; video._completed_end = ""; eof(video)
		video._process_playback_end(); await process_frame
		check(main.opened == [[item("b").uri, true]], "Natural completion opens exactly the next video from the start: " + mode)
		video.local_uri = item("c").uri; eof(video); main.opened.clear()
		main._advance_completed_video(video.local_uri, video.media.session_id, video.control.sequence)
		check(main.opened == ([[item("a").uri, true]] if mode == "repeat_all" else []), "End-of-list behavior matches the mode: " + mode)
	main._set_playback_mode("sequence"); video.local_uri = item("a").uri; eof(video); main.opened.clear()
	main._advance_completed_video(video.local_uri, video.media.session_id - 1, video.control.sequence)
	main._advance_completed_video(video.local_uri, video.media.session_id, video.control.sequence + 1)
	check(main.opened.is_empty(), "Deferred EOF work from a replaced session or seek is ignored")
	main._grab = {"hand": "right_hand"}
	main._advance_completed_video(video.local_uri, video.media.session_id, video.control.sequence)
	check(main.opened.is_empty() and not main._pending_video_end.is_empty(), "Automatic advancement waits while a picture or interface is captured")
	main._grab.clear(); video.control.seek_absolute(2000)
	main._advance_completed_video(video.local_uri, video.media.session_id, video.control.sequence - 1)
	check(main.opened.is_empty() and main._pending_video_end.is_empty(), "A seek submitted on release cancels the deferred EOF transition")
	video.control.reject()
	main._grab = {"hand": "right_hand"}; main._advance_completed_video(video.local_uri, video.media.session_id, video.control.sequence)
	main._grab.clear(); main._advance_completed_video(video.local_uri, video.media.session_id, video.control.sequence)
	check(main.opened == [[item("b").uri, true]], "Releasing a capture without seeking lets the completed list advance once")
	main.opened.clear(); video.local_uri = item("a").uri
	video.requested_play = false; main._navigate_video(1)
	check(main.opened == [[item("b").uri, false]], "Manual next remains available while paused and retains resume behavior")
	main._set_playback_mode("repeat_all"); main.video_queue.assign([item("a")]); video.local_uri = item("a").uri; eof(video); main.opened.clear()
	main._advance_completed_video(video.local_uri, video.media.session_id, video.control.sequence)
	check(main.opened == [[item("a").uri, true]], "A one-entry repeat list restarts that entry")
	main.video_queue.clear(); main.opened.clear(); eof(video)
	main._advance_completed_video(video.local_uri, video.media.session_id, video.control.sequence)
	check(main.opened.is_empty(), "Empty or unrelated queues cannot start playback")
	var opener := OpenProbe.new(); opener.platform = RefCounted.new()
	opener.recent_files.directory = "user://video-mode-recent"; opener.recent_files.entries = {Video.ModeMemory.key_for(item("a").uri): {"uri": item("a").uri, "title": "a", "position_ms": 9000}}
	opener.open_library(item("a").uri, "a", {}, true); opener.open_library(item("a").uri, "a")
	check(opener.opens == [[item("a").uri, true], [item("a").uri, false]], "Automatic versus manual opens preserve the from-start flag through history")
	opener.open_library("medialib://s/scene/a", "a", {"start_ms": 8000}, true)
	check(opener.opens.back()[1] == 0, "Automatic server playback ignores saved start offsets")
	opener.free()
	pages(main, video)
	main.video_queue_pages.dispose(); main.free(); video.free()
	for failure in failures: push_error(failure)
	print("Video playback modes: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)

func pages(main: Node3D, video: Node3D) -> void:
	var host := Host.new(); var pager: RefCounted = main.video_queue_pages
	var library := preload("res://scripts/library_menu.gd").new()
	library.section = library.Section.CLOUD; library._cloud_stack = [{"id": "/drive/movies", "title": "Movies", "cloud_id": "stable-folder"}]
	library._cloud_entries = [{"uri": item("a").uri}]; library._cloud_next = 48; library._cloud_page = 0
	pager.platform = host; pager.capture(library, item("a").uri)
	library._cloud_stack = [{"id": "/other", "title": "Other"}]; library._cloud_next = 96
	check(pager.context.path == "/drive/movies" and pager.context.next == 48 and pager.context.cloud_id == "stable-folder" and host.requests.is_empty(), "Capturing playback freezes the folder without reading ahead or following later browser navigation")
	library.free()
	pager.platform = host; pager.context = cloud_context()
	pager.completed.connect(main._on_video_queue_page); pager.failed.connect(main._on_video_queue_failed)
	main.playback_mode = "sequence"; main.video_queue.assign([item("a")]); video.local_uri = item("a").uri; eof(video); main.opened.clear()
	main._advance_video_queue(true)
	check(host.requests.size() == 1 and host.requests[0].offset == 48 and host.requests[0].cloud_id == "stable-folder", "Page end requests only the next offset with the frozen folder identity")
	check(main._playback_status_sample().caption.contains("next"), "Pending pagination has a concise loading status")
	cloud_result(host, pager, [{"container": true, "title": "folder"}, {"uri": "file:///photo.jpg", "title": "photo.jpg"}], 96)
	check(host.requests.size() == 2 and host.requests.back().offset == 96 and main.opened.is_empty(), "Pages with no video are traversed lazily without opening images or folders")
	cloud_result(host, pager, [{"uri": item("b").uri, "title": "b.mp4"}], -1)
	check(main.opened == [[item("b").uri, true]] and main.video_queue.size() == 2 and main.video_queue.back().metadata.location.path == "/drive/movies", "Next page appends once and opens the first new video with its source context")
	main.playback_mode = "repeat_all"; pager.context = cloud_context(); pager.context.next = -1; pager.context.from_first = false
	main.opened.clear(); eof(video); main._advance_video_queue(true)
	check(host.requests.back().offset == 0, "A list started on a later cloud page wraps to the actual first page")
	cloud_result(host, pager, [{"uri": item("c").uri, "title": "c.mp4"}], 48)
	check(main.opened == [[item("c").uri, true]] and main.video_queue.size() == 1 and pager.context.from_first, "Wrap replaces the partial queue and continues from the first page")
	pager.context.from_first = false; main.opened.clear(); eof(video); main._advance_video_queue(true)
	cloud_result(host, pager, [], -1)
	check(host.requests.back().offset == 0 and main.opened.is_empty(), "An empty trailing page still wraps a partial cloud queue to the directory start")
	cloud_result(host, pager, [{"uri": item("a").uri, "title": "a.mp4"}], 48)
	check(main.opened == [[item("a").uri, true]], "Empty trailing pages cannot trap playback in the original partial page")
	main.opened.clear(); eof(video); main._advance_video_queue(true)
	var retired: int = pager.pending
	video.requested_play = false; main._cancel_video_queue_wait()
	host.media_list.emit(retired, '{"state":"ready","entries":[]}')
	check(main.opened.is_empty() and host.cancelled.has(retired), "Cancellation prevents a late page response from reopening video")
	video.requested_play = true; pager.context = cloud_context(); main._advance_video_queue(true)
	video.requested_play = false
	cloud_result(host, pager, [{"uri": item("a").uri, "title": "a.mp4"}])
	check(main.opened.is_empty() and pager.context.next == 48, "Pausing during a page read discards the result without skipping that page later")
	pager.completed.disconnect(main._on_video_queue_page); pager.failed.disconnect(main._on_video_queue_failed)
	pager.context = cloud_context(); var errors: Array = []; pager.failed.connect(func(message): errors.append(message))
	pager.start(); cloud_result(host, pager, [], 48)
	check(errors.size() == 1 and pager.pending == 0, "A non-advancing cloud cursor fails once instead of looping")
	pager.start(); host.media_list.emit(pager.pending, '{"state":"ready","path":"/other","offset":48,"entries":[]}')
	check(errors.size() == 2, "A response from another folder is rejected")
	pager.start(); pager._deadline = 0; pager.poll(); pager.poll()
	check(errors.size() == 3 and pager.pending == 0, "A stalled request times out once")
	pager.context = {"type": "server", "server_id": "server-a", "query": {"page": 2, "parent_id": "folder-a", "sort": "title", "direction": "ASC"}, "next": 3, "from_first": true, "location": {"type": "server", "server_id": "server-a"}}
	var delivered: Array = []; pager.completed.connect(func(items, restart): delivered.append([items, restart]))
	pager.start()
	var expected: Dictionary = host.requests.back()
	check(expected.page == 3 and expected.parent_id == "folder-a" and expected.sort == "title" and expected.direction == "ASC", "Server continuation keeps the frozen filter and sort")
	host.media_list.emit(pager.pending, JSON.stringify({"state": "ready", "server_id": "server-a", "generation": expected.generation, "entries": [{"uri": "medialib://server-a/scene/next", "id": "next", "title": "next"}], "total": 97}))
	check(delivered.size() == 1 and delivered[0][0][0].metadata.location.item_id == "next" and not pager.has_more(), "Server page preserves scene identity and recognizes the end")
