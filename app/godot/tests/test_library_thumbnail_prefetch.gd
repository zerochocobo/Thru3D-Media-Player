extends SceneTree
const Menu := preload("res://scripts/library_menu.gd")
const Cache := preload("res://scripts/thumbnail_cache.gd")
const Budget := preload("res://scripts/background_resource_budget.gd")
const Privacy := preload("res://scripts/media_privacy.gd")
const Main := preload("res://scripts/main.gd")
const Photo := preload("res://scripts/photo_display.gd")
const Video := preload("res://scripts/mpv_video_display.gd")
const UiTheme := preload("res://scripts/ui_theme.gd")
const FOLDER := "/storage/emulated/0/Library"
var failures := 0

class TestBudget extends Budget:
	func tick(_owner: Node, _delta: float, _enabled: bool) -> void: pass
	func can_start(_bytes: int, _addition: int = 0) -> bool: return true
	func can_continue(_bytes: int, _addition: int = 0) -> bool: return true

class Fixture extends RefCounted:
	var calls: Array[Dictionary] = []
	var cancelled := 0
	var result := {"state": "queued"}
	var payload := PackedByteArray()
	func local_thumbnail_request(raw: String) -> int:
		calls.append(JSON.parse_string(raw))
		result = {"state": "queued"}
		return calls.size()
	func local_thumbnail_state(_id: int) -> String: return JSON.stringify(result)
	func local_thumbnail_take(_id: int) -> PackedByteArray: return payload
	func local_thumbnail_cancel(_id: int) -> void: cancelled += 1

func _initialize() -> void:
	_run.call_deferred()

func _check(ok: bool, message: String) -> void:
	if ok: return
	failures += 1
	push_error(message)

func _run() -> void:
	if not OS.get_user_data_dir().contains("thumbnail-tests"):
		push_error("Use isolated thumbnail-tests user data")
		quit(1)
		return
	Cache.clear()
	var menu := Menu.new()
	root.add_child(menu)
	menu.set_process(false)
	menu.platform = Fixture.new()
	var fixture: Fixture = menu.platform
	menu.section = Menu.Section.LOCAL
	menu.view_mode = "grid"
	menu._local_volumes = [{"id": "/storage/emulated/0", "title": "Internal"}]
	menu._local_stack = [{"id": FOLDER, "title": "Library"}]
	menu.show()
	var preload_work = menu.thumbnail_prefetch
	preload_work.budget = TestBudget.new()
	preload_work.configure(true, 300)
	_check(preload_work.limit == 200, "Configured item count is clamped to 200")
	for i in 10000:
		var path := FOLDER + "/%d.jpg" % i
		menu.rows.append({"kind": "image", "title": path.get_file(), "uri": "file://" + path, "size": 10, "modified": 1,
			"thumb_item": {"identity": path, "uri": "file://" + path, "version": "v1", "quality": 20}})
	menu._stick_ms = -1000
	preload_work.tick(0.016)
	_check(fixture.calls.is_empty(), "The first view waits before issuing source work")
	preload_work._view_at -= 1000
	preload_work.tick(0.016)
	_check(fixture.calls.size() == 1 and preload_work.used == 1 and preload_work._visible_choices().size() < 20,
		"A 10,000-entry view admits one worker and only inspects visible cards")
	preload_work.tick(0.016)
	_check(not menu._thumbnail_reading, "An accepted but queued job does not display a reading icon")
	fixture.result = {"state": "reading"}
	preload_work._poll_at = 0
	preload_work.tick(0.016)
	_check(not menu._thumbnail_reading, "Short reads do not display a reading icon")
	preload_work._reading_at -= 301
	preload_work._poll_at = 0
	preload_work.tick(0.016)
	_check(menu._thumbnail_reading, "A running job for the current viewport displays the delayed icon")
	for i in 100:
		menu.scroll = 4.0 + i
		preload_work.tick(0.016)
	_check(fixture.cancelled == 1 and fixture.calls.size() == 1 and not menu._thumbnail_reading,
		"Scrolling hides the icon and keeps the original slot until the worker exits")
	fixture.result = {"state": "cancelled"}
	preload_work._poll_at = 0
	preload_work._view_at -= 1000
	preload_work.tick(0.016)
	_check(fixture.calls.size() == 2 and preload_work.used == 2, "After exit the next visible job starts without refreshing the quota")
	var jpeg := Image.create_empty(320, 180, false, Image.FORMAT_RGB8)
	jpeg.fill(Color.BLUE)
	var target := str(fixture.calls.back().uri)
	fixture.result = {"state": "ready", "uri": target, "size": 10, "modified": 1}
	fixture.payload = Cache.encode(jpeg)
	preload_work._poll_at = 0
	preload_work.tick(0.016)
	for frame in 100:
		if Cache.has(target): break
		await process_frame
		preload_work.tick(0.016)
	_check(Cache.has(target) and not Cache.has_played_picture(target), "Available bytes enter the speculative partition")
	Cache.store(target, jpeg)
	_check(Cache.has_played_picture(target), "Actual media can replace the speculative image")
	preload_work.configure(false, 200)
	var started := fixture.calls.size()
	preload_work.tick(0.016)
	_check(fixture.calls.size() == started and not menu._thumbnail_reading, "Switch off stops active reads and leaves cached pictures")
	preload_work.configure(true, 200)
	preload_work.tick(0.016)
	_check(preload_work.used >= 2, "Re-enabling does not reset the visit")

	# Thumbnail child work shares the same allowance, and the reservation is passed to the worker.
	if preload_work._native_id > 0:
		fixture.result = {"state": "cancelled"}
		preload_work._poll_at = 0
		preload_work.tick(0.016)
	menu.scroll = 0.0
	var child := FOLDER + "/Child + #"
	menu.rows.assign([{"title": "Child", "folder_thumb_scope": child, "modified": 100, "kind": "folder"}])
	preload_work.used = 198
	preload_work.tick(0.016)
	preload_work._view_at -= 1200
	preload_work._poll_at = 0
	preload_work.tick(0.016)
	_check(int(fixture.calls.back().sample_limit) == 1, "Only one child entry can be sampled with two units left")
	var folder_request := str(fixture.calls.back().uri)
	_check(folder_request.ends_with("/Child%20%2B%20%23"), "Reserved filename characters are encoded in the folder request")
	fixture.result = {"state": "ready", "uri": folder_request + "/folder.jpg", "sampled": 1, "size": 10, "modified": 1}
	preload_work._poll_at = 0
	preload_work.tick(0.016)
	_check(preload_work.used == 200, "Folder candidates and inspected child entries share the same allowance")
	for frame in 100:
		if not Cache.References.cover(child).is_empty(): break
		await process_frame
		preload_work.tick(0.016)
	_check(not Cache.References.cover(child).is_empty(), "The sampled child image becomes the immediate folder's cover")
	menu.view_mode = "list"
	started = fixture.calls.size()
	preload_work.tick(0.016)
	_check(fixture.calls.size() == started, "Changing from grid to list does not reset the directory allowance")

	Privacy.configure(Privacy.NONE)
	var private_folder := FOLDER + "/Private"
	var private_path := private_folder + "/private.jpg"
	var private_uri := "file://" + private_path
	menu.view_mode = "grid"
	menu._local_stack[0].id = private_folder
	menu.rows.assign([{"kind": "image", "title": "private.jpg", "uri": private_uri,
		"thumb_item": {"identity": private_path, "uri": private_uri, "version": "v1", "quality": 20}}])
	preload_work.tick(0.016)
	for frame in 100:
		Cache.poll()
		if not Cache.reading(): break
		await process_frame
	preload_work._view_at -= 1000
	preload_work.tick(0.016)
	fixture.result = {"state": "ready", "uri": private_uri}
	preload_work._poll_at = 0
	preload_work.tick(0.016)
	for frame in 100:
		if Cache.has(private_uri): break
		await process_frame
		preload_work.tick(0.016)
	_check(Cache.texture(private_uri) != null and not FileAccess.file_exists(Cache.path_for(private_uri)),
		"Opt-out prefetch uploads from memory without creating a cache file")
	Privacy.configure(Privacy.ALL)
	var sidecars := preload_work.smb_sidecars([
		{"kind": "image", "title": "Movie-poster.JPG", "uri": "smb://nas/share/Movie-poster.JPG", "size": 500},
		{"kind": "image", "title": "Other.jpg", "uri": "smb://nas/share/Other.jpg", "size": 500}])
	_check(preload_work.smb_sidecar(sidecars, "movie.mkv").get("size") == 500, "SMB sees a same-name poster for an MKV")
	_check(preload_work.smb_sidecar(sidecars, "missing.mkv").is_empty(), "Unrelated photos are not used as a video's poster")
	menu.section = Menu.Section.SMB
	menu.view_mode = "list"
	menu._smb_server = "nas"
	menu._smb_path = "share"
	var remote := "smb://nas/share/movie.mkv"
	menu.rows.assign([{"kind": "video", "title": "movie.mkv", "uri": remote, "size": 2000000,
		"thumb_item": {"identity": "movie.mkv", "uri": remote, "version": "remote", "quality": 10}}])
	preload_work.configure(false, 20, true, false)
	preload_work.tick(0.016)
	preload_work._view_at -= 1000
	started = fixture.calls.size()
	preload_work.tick(0.016)
	_check(fixture.calls.size() == started + 1 and fixture.calls.back().get("uri") == remote,
		"SMB can preview a visible list video when internal storage and DLNA are disabled")
	preload_work.configure(false, 20, false, true)
	fixture.result = {"state": "cancelled"}
	preload_work._poll_at = 0
	preload_work.tick(0.016)
	_check(fixture.calls.size() == started + 1, "Turning off SMB does not start another SMB job")
	menu.section = Menu.Section.DLNA
	menu._dlna_server = "server"
	remote = "dlna://server/movie"
	menu.rows.assign([{"kind": "video", "title": "movie.mkv", "uri": remote, "cover": "http://server/cover.jpg",
		"thumbnail_resource": "http://server/movie.mkv",
		"thumb_item": {"identity": "movie", "uri": remote, "version": "remote", "quality": 10}}])
	preload_work._network_last_start -= 2000
	preload_work.tick(0.016)
	preload_work._view_at -= 1000
	preload_work.tick(0.016)
	_check(fixture.calls.size() == started + 1, "A DLNA XML cover prevents remote video probing")
	menu.rows[0].erase("cover")
	preload_work.tick(0.016)
	preload_work._view_at -= 1000
	preload_work.tick(0.016)
	_check(fixture.calls.size() == started + 2 and fixture.calls.back().get("resource") == "http://server/movie.mkv",
		"An enabled DLNA folder can pass the listed resource for a missing video preview")
	fixture.result = {"state": "missing", "diagnostic": {"stage": "video_decode", "reason": "no_frame",
		"codec": "h264", "container": "mpegts", "media_bytes": 131072, "worker_ms": 80,
		"uri": "http://private.example/movies/example.mkv?token=secret"}}
	preload_work._poll_at = 0
	preload_work.tick(0.016)
	var diagnostic: Dictionary = preload_work.diagnostics_snapshot()
	var last: Dictionary = diagnostic.recent.back()
	_check(last.get("source") == "dlna" and last.get("reason") == "no_frame" and last.get("media_bytes") == 131072,
		"Export includes the source, reason and read size of the failed preview")
	_check(not JSON.stringify(diagnostic).contains("private.example") and not JSON.stringify(diagnostic).contains(remote),
		"Export omits native URI fields and media identities")
	var remote_folder := "dlna://server/child%2Fid"
	menu.rows.assign([{"title": "Remote child", "folder_thumb_scope": remote_folder, "child_count": 40}])
	preload_work._network_last_start -= 2000
	preload_work.tick(0.016)
	preload_work._view_at -= 1200
	preload_work.tick(0.016)
	_check(fixture.calls.size() == started + 3 and int(fixture.calls.back().get("sample_limit")) == 8,
		"A DLNA folder without XML art may browse one bounded page of immediate children")
	fixture.result = {"state": "ready", "uri": "dlna://server/thumb", "sampled": 1,
		"entry": {"kind": "video", "id": "thumb", "title": "Folder preview.mkv", "size": 300000}}
	preload_work._poll_at = 0
	preload_work.tick(0.016)
	for frame in 100:
		if not Cache.References.cover(remote_folder).is_empty(): break
		await process_frame
		preload_work.tick(0.016)
	_check(Cache.References.cover(remote_folder).get("picture") == "dlna://server/thumb".sha1_text(),
		"The extracted frame becomes the DLNA folder's cover")
	for i in 30:
		preload_work.record_declared_cover("folder", "http_error", 404, 0, Time.get_ticks_msec())
	_check(preload_work.diagnostics_snapshot().recent.size() == 24, "Diagnostics retain a bounded number of outcomes")
	Privacy.configure(Privacy.NONE)
	_check(preload_work.diagnostics_snapshot().is_empty(), "Private history suppresses the entire preview report")
	Privacy.configure(Privacy.ALL)
	preload_work.clear_diagnostics()
	_check(preload_work.diagnostics_snapshot().recent.is_empty(), "Clearing history drops thumbnail diagnostics")
	await _check_manual_refresh(menu, fixture)
	_check_recovery_and_backoff(menu, fixture)
	await _check_dlna_fallback(menu, fixture)
	_check_settings_rows(menu)
	_check_preview_admission()
	menu.free()
	Cache.clear()
	Cache.finish()
	print("Local thumbnail prefetch: %d failures" % failures)
	quit(int(failures > 0))

func _check_manual_refresh(menu: Menu, fixture: Fixture) -> void:
	var work = menu.thumbnail_prefetch
	menu.section = Menu.Section.LOCAL
	menu.scroll = 0
	menu.media_filter = 0
	menu._stick_ms = -1000
	var folder := FOLDER + "/Refresh"
	var entry := {"id": folder + "/clip.mkv", "title": "clip.mkv", "kind": "video",
		"uri": "file://" + folder + "/clip.mkv", "size": 12345, "modified": 11}
	menu._local_stack = [{"id": folder, "title": "Refresh"}]
	var listing := JSON.stringify({"state": "ready", "freshness": "fresh", "path": folder, "entries": [entry], "complete": true})
	menu._pending[900] = "local"
	menu._on_media_list(900, listing)
	work.configure(true, 20)
	for frame in 100:
		Cache.poll()
		menu.directory_artwork.tick(folder)
		if not Cache.reading() and not menu.directory_artwork.busy(): break
		await process_frame
	work.tick(0.016)
	work._view_at -= 1000
	var before := fixture.calls.size()
	work.tick(0.016)
	_check(fixture.calls.size() == before + 1, "An ordinary directory visit tries a visible MKV: %s" % str(work.diagnostics_snapshot().status))
	fixture.result = {"state": "missing"}
	work._poll_at = 0
	work.tick(0.016)
	for id in [901, 902]:
		menu._manual_refresh_scope = folder
		menu._manual_refresh_id = id
		menu._pending[id] = "local"
		menu._on_media_list(id, listing)
		for frame in 100:
			if not menu.directory_artwork.busy(): break
			menu.directory_artwork.tick(folder)
			await process_frame
		work.tick(0.016)
		work._view_at -= 1000
		work.tick(0.016)
		_check(fixture.calls.size() == before + 2 and work.used == 2,
			"Refresh %d must retain the existing counter and retry only once. Started %d, used %d, status %s" %
			[id, fixture.calls.size() - before, work.used, str(work.diagnostics_snapshot().status)])
		fixture.result = {"state": "missing"}
		work._poll_at = 0
		work.tick(0.016)

func _check_recovery_and_backoff(menu: Menu, fixture: Fixture) -> void:
	var work = menu.thumbnail_prefetch
	menu.section = Menu.Section.SMB
	menu._smb_server = "recovery-fixture"
	menu._smb_path = "share/a"
	var scope := menu._artwork_scope()
	var remote := "smb://recovery-fixture/share/a/movie.mkv"
	menu.rows.assign([{"kind": "video", "title": "movie.mkv", "uri": remote,
		"thumb_item": {"identity": "movie", "uri": remote, "version": "a"}}])
	work._network_last_start -= 2000
	work.tick(0.016)
	work._view_at -= 1000
	var before := fixture.calls.size()
	work.tick(0.016)
	work.budget.reason = "frame_stall"
	work._poll_at = 0
	work.tick(0.016)
	fixture.result = {"state": "cancelled"}
	work._poll_at = 0
	work.tick(0.016)
	work.budget.reason = "ready"
	work.tick(0.016)
	_check(fixture.calls.size() == before + 1 and work.used == 1, "Frame recovery waits and keeps the first read charged")
	work._recover_at = 0
	work.tick(0.016)
	_check(fixture.calls.size() == before + 1, "An automatic retry honors server request spacing")
	work._network_last_start -= 2000
	var endpoint := str([Menu.Section.SMB, menu._smb_server])
	var full: Array = []
	full.resize(work.NETWORK_PER_MINUTE)
	full.fill(Time.get_ticks_msec())
	var previous: Array = work._network_starts[endpoint]
	work._network_starts[endpoint] = full
	work.tick(0.016)
	_check(fixture.calls.size() == before + 1, "An automatic retry honors the per-minute server limit")
	work._network_starts[endpoint] = previous
	work.tick(0.016)
	_check(fixture.calls.size() == before + 2 and work.used == 2 and work._job.get("retry") == "frame_recovery",
		"A settled visible MKV automatically retries once and counts both reads")
	work.budget.reason = "frame_budget"
	work._poll_at = 0
	work.tick(0.016)
	fixture.result = {"state": "cancelled"}
	work._poll_at = 0
	work.tick(0.016)
	work.budget.reason = "ready"
	work._recover_at = 0
	work._network_last_start -= 2000
	work.tick(0.016)
	_check(fixture.calls.size() == before + 2, "A second frame cancellation cannot loop")
	for i in 3: work._temporary()
	var blocked_until := int(work._backoff_by_scope[scope].until)
	menu._smb_path = "share/b"
	work.tick(0.016)
	work._view_at -= 1000
	work.tick(0.016)
	_check(fixture.calls.size() == before + 3, "Temporary backoff does not spread to another SMB directory")
	fixture.result = {"state": "temporary"}
	work._poll_at = 0
	work.tick(0.016)
	menu._smb_path = "share/a"
	work.tick(0.016)
	work._view_at -= 1000
	work._network_last_start -= 2000
	work.tick(0.016)
	_check(fixture.calls.size() == before + 3 and work._backoff_by_scope[scope].until == blocked_until,
		"The returning directory retains its own backoff")
	work.refreshed(scope)
	work.tick(0.016)
	_check(fixture.calls.size() == before + 4 and work._backoff_by_scope[scope].probe_used,
		"A manual refresh can start one charged read during backoff")
	fixture.result = {"state": "temporary"}
	work._poll_at = 0
	work.tick(0.016)
	work.refreshed(scope)
	work._network_last_start -= 2000
	work.tick(0.016)
	_check(fixture.calls.size() == before + 4, "Repeated refresh cannot keep probing an unavailable directory")

func _check_dlna_fallback(menu: Menu, fixture: Fixture) -> void:
	var server := TCPServer.new()
	if server.listen(0, "127.0.0.1") != OK:
		_check(false, "Bind the loopback fallback fixture")
		return
	var work = menu.thumbnail_prefetch
	menu.section = Menu.Section.DLNA
	menu._dlna_server = "fallback-fixture"
	menu._dlna_stack.clear()
	var base := "http://127.0.0.1:%d" % server.get_local_port()
	for kind in ["video", "image", "folder"]:
		var declared := base + "/bad-" + str(kind)
		var original := base + ("/original.jpg" if kind == "image" else "/original.mkv")
		var entry := {"kind": kind, "title": "Sample", "id": kind, "uri": original}
		if kind == "folder": entry.container = true
		entry["thumbnail_uri" if kind == "image" else "cover"] = declared
		menu._dlna_entries = [entry]
		menu.refresh()
		var row := menu._entry_row(entry)
		_check(menu._folder_covers.awaiting_cover(row), "A declared DLNA cover takes priority before its first result")
		menu._folder_covers._last_start -= 2000
		var response := "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
		if kind == "image": response = "HTTP/1.1 200 OK\r\nContent-Length: 4\r\nConnection: close\r\n\r\nbad!"
		var peer: StreamPeerTCP
		var incoming := ""
		var served := 0
		for frame in 300:
			if not peer and server.is_connection_available(): peer = server.take_connection()
			if peer:
				peer.poll()
				incoming += peer.get_utf8_string(peer.get_available_bytes())
				if incoming.contains("\r\n\r\n"):
					peer.put_data(response.to_utf8_buffer())
					peer.disconnect_from_host()
					peer = null
					served += 1
			menu._folder_covers.tick()
			menu._folder_covers._eligible_at = 0
			if not menu._folder_covers.awaiting_cover(row): break
			await process_frame
		_check(served == 1 and not menu._folder_covers.awaiting_cover(row), "A failed XML cover opens the same fallback path as a missing one")
		work._network_last_start -= 2000
		work.tick(0.016)
		work._view_at -= 1200
		var before := fixture.calls.size()
		work.tick(0.016)
		var request: Dictionary = fixture.calls.back()
		_check(fixture.calls.size() == before + 1 and request.kind == kind and (int(request.sample_limit) > 0 if kind == "folder" else request.resource == original),
			"DLNA %s uses the original resource or bounded child sampling after XML fails" % kind)
		fixture.result = {"state": "missing"}
		work._poll_at = 0
		work.tick(0.016)
	server.stop()

func _check_settings_rows(menu: Menu) -> void:
	_check(menu._thumbnail_prefetch_rows().size() == 1, "Collapsed preview settings hide the frame protection switch")
	menu._set_general_settings_group("previews", true)
	var rows := menu._thumbnail_prefetch_rows()
	var protection: Dictionary = rows.filter(func(row): return row.get("key") == "library_thumbnail_frame_protection").front()
	_check(protection.value == true and not str(protection.info).is_empty(), "Preview frame protection defaults on and has a tooltip")
	menu.thumbnail_prefetch.configure(true, 20, true, true, false)
	_check(not menu.thumbnail_prefetch.budget.protect_preview_frames, "Preview configuration can disable the frame gate")
	menu.section = Menu.Section.SETTINGS
	menu.tab = Menu.DISPLAY_TAB
	menu.refresh()
	_check(menu.rows[0].get("key") == UiTheme.KEY and menu.rows[1].get("key") == "watch_color", "Display color and watch palettes are immediately visible")

func _check_preview_admission() -> void:
	var budget := Budget.new()
	budget.frame_cadence_only = true
	budget.policy = {"spare_bytes": 128 * Budget.MIB, "work": true}
	for target_hz in [72.0, 90.0]:
		budget.stop()
		budget.policy = {"spare_bytes": 128 * Budget.MIB, "work": true}
		budget.preview_job_active = false
		var nominal := 1000.0 / float(target_hz)
		for n in 120: budget.observe(0.0, 0.0, nominal * 2.0, nominal, nominal * 0.002)
		_check(budget.can_start(64 * Budget.MIB), "Stable half-rate delivery can admit a preview without a GPU timer")
		budget.preview_job_active = true
		for n in 10: budget.observe(0.0, 0.0, nominal * 2.0, nominal, nominal * 0.002)
		_check(budget.can_start(64 * Budget.MIB), "The same slow but stable cadence can finish a read")
		budget.observe(0.0, 0.0, nominal * 4, nominal, nominal * 0.004)
		_check(not budget.can_start(64 * Budget.MIB) and budget.reason == "frame_stall", "A stall relative to the idle cadence still stops previews")
	budget.protect_preview_frames = false
	budget.observe(0.0, 0.0, 100.0, 14.0, 0.1)
	_check(budget.can_start(64 * Budget.MIB) and not budget.can_start(256 * Budget.MIB), "Turning off the frame gate retains the memory gate")
	budget.policy.work = false
	budget.observe(0.0, 0.0, 100.0, 14.0, 0.1)
	_check(not budget.can_start(64 * Budget.MIB), "Turning off the frame gate retains the native resource gate")
	var player := Main.new()
	player.display.preview = true
	player.photo = Photo.new()
	player.video = Video.new()
	player.photo_active = true
	_check(player._library_preview_can_run(), "The photo tab with no open photo leaves previews eligible")
	player.photo.loading = true
	_check(not player._library_preview_can_run(), "Loading a photo takes priority over previews")
	player.photo.loading = false
	player.photo_active = false
	player.video.local_uri = "file:///fixture.mp4"
	player.video.media.state = "playing"
	_check(not player._library_preview_can_run(), "Playing video takes priority over previews")
	player.video.requested_play = false
	player.video.media.state = "paused"
	_check(player._library_preview_can_run(), "A paused and settled video leaves previews eligible")
	player.photo.free()
	player.video.free()
	player.free()
