extends SceneTree
const Store := preload("res://scripts/bookmark_store.gd")
const Menu := preload("res://scripts/player_menu.gd")
const Timeline := preload("res://scripts/timeline_markers.gd")
const Video := preload("res://scripts/mpv_video_display.gd")
var failures: Array[String] = []
var checks := 0
var requests: Array = []

class FailedWrite extends "res://scripts/bookmark_store.gd":
	func _commit(_staged: String, _target: String) -> Error: return ERR_CANT_CREATE

class Host extends RefCounted:
	var targets: Array = []
	func close_mpv_video(_id: int) -> void: pass
	func set_mpv_playing(_id: int, _playing: bool) -> void: pass
	func revise_mpv_video(id: int, _stereo: bool, _alpha: bool, _profile: String, time: int, _depth: bool, _top_bottom: bool, _exact: bool = false) -> int:
		targets.append([id, time]); return 0

func check(ok: bool, text: String) -> void:
	checks += 1
	if not ok: failures.append(text)

func origin(menu: Node3D, target: int) -> Vector3:
	for button in menu._buttons:
		if button.target == target: return menu.to_global(Vector3(button.rect.get_center().x, button.rect.get_center().y, 1))
	return Vector3.ZERO

func tap(menu: Node3D, target: int, hand: String = "left_hand") -> void:
	var start := origin(menu, target)
	menu.press_pointer(hand, start, -menu.global_basis.z, true)
	menu.release_pointer(hand, start, -menu.global_basis.z, true)

func _initialize() -> void:
	call_deferred("_run")

func check_seek_then_bookmark(path: String, times: Array, duration: int) -> void:
	var video := Video.new(); video.bookmark_store = Store.new(path)
	root.add_child(video); video.set_process(false)
	video.platform = Host.new(); video.local_uri = "file:///timeline-fixture.mp4"
	video.media.begin(7); video.media.generation = 3; video.media.state = "paused"
	video.media.playback = {"details": {"seekable": "yes"}}; video.control.observe(0, duration)
	video._bookmark_metadata = {"basename": "timeline-fixture.mp4", "size": 5000}; video._bookmark_resolve()
	var menu := Menu.new()
	menu.state_provider = func(): return video.bookmarks_snapshot().merged({"has_video": true, "duration_ms": video.control.duration_ms, "position_ms": video.control.display_position_ms()})
	menu.seek_requested.connect(video.seek_absolute)
	menu.bookmark_requested.connect(func(operation, id, scope):
		var message: String = video.bookmark_action(operation, id, scope)
		if not message.is_empty(): menu.bookmarks.notify(message))
	root.add_child(menu); menu.toggle(); menu.set_process(false)
	for time in times:
		var x: float = -menu.BAR_SEEK / 2 + menu.BAR_SEEK * float(time) / duration
		var ray: Vector3 = menu.to_global(Vector3(x, -0.08, 1))
		menu.press_pointer("left_hand", ray, -menu.global_basis.z, true)
		menu.release_pointer("left_hand", ray, -menu.global_basis.z, true)
		check(absi(video.control.target_ms - int(time)) <= 1, "Timeline click requests its actual timestamp")
		# Confirm the requested frame, without sleeping between seek/add/next seek.
		video._pending_revision.clear(); video._waiting_first = false
		video.control.take_pending(); video.control.first_frame(int(time))
		video._binding.ticket = {"session_id": 7, "generation": 3, "pts_us": int(time) * 1000, "source_pts_verified": true}
		video.panel.visible = true; menu.refresh_values()
		tap(menu, menu.BookmarkMenu.ADD)
	var markers: Array = video.bookmark_store.list_markers(video._bookmark_media_id)
	check(markers.map(func(item): return item.position_ms) == times, "Rapid seek/add retains every distinct list timestamp")
	var groups: Array = menu._buttons.filter(func(item): return menu.bookmarks.targets.get(item.target, {}).get("kind") == "group")
	check(groups.size() == times.size() and groups.all(func(item): return menu.bookmarks.targets[item.target].ids.size() == 1), "Rapid seek/add leaves visually separated bookmarks at separate positions")
	for group in groups:
		var marker: Dictionary = markers.filter(func(item): return item.id == menu.bookmarks.targets[group.target].ids[0])[0]
		check(is_equal_approx(group.node.position.x, -menu.BAR_SEEK / 2 + menu.BAR_SEEK * float(marker.position_ms) / duration), "Timeline marker stays at its saved timestamp")
		check(menu.ray_hit(origin(menu, int(group.target)), -menu.global_basis.z).get("target") == group.target, "Each separate bookmark retains its own ray hit target")
	tap(menu, menu.BookmarkMenu.LIST)
	check(menu.bookmarks.targets.values().filter(func(item): return item.get("column") == "markers" and item.kind == "seek").size() == times.size(), "List retains the same timestamps shown on the playback bar")
	menu.free(); video._binding.ticket.clear(); video.free()

func _run() -> void:
	preload("res://scripts/i18n.gd").use("en")
	var path := ProjectSettings.globalize_path("res://../../build/output/bookmarks-host/" + str(Time.get_ticks_usec()))
	check_seek_then_bookmark(path + "-reported-device-records", [128712, 202411, 268685], 1094719)
	check_seek_then_bookmark(path + "-four-eight-minutes", [240000, 480000], 2400000)
	var store := Store.new(path)
	var uri := "smb://server/old/movie.mp4"
	var id := store.resolve(uri, "movie.mp4", 5000000)
	check(store.list_markers(id).is_empty() and not DirAccess.dir_exists_absolute(path), "Opening a movie performs no storage mutation")
	var a := store.add(uri, "movie.mp4", 5000000, 10000)
	var b := store.add(uri, "movie.mp4", 5000000, 30000)
	check(not a.is_empty() and not b.is_empty(), "Add two timestamps")
	check(a.keys().size() == 3 and not a.has("rating") and not a.has("title"), "User marker contains only ID, time and creation date")
	var moved := "cloud://account/new/movie.mp4"
	check(store.resolve(moved, "movie.mp4", 5000000) == id, "Matching real name and byte length survives directory and source changes")
	check(store.resolve(moved, "movie.mp4", -1) != id, "Unknown byte size never cross-matches")
	check(store.resolve(moved, "movie.mp4", 5000001) != id, "Same name with different size stays separate")
	check(store.resolve(uri, "movie.mp4", 5000001) != id, "Changed file at same path does not inherit old bookmarks")
	check(store.resolve(moved, "Movie.mp4", 5000000) != id, "Case-sensitive basename is preserved")
	var duplicate := store.add(moved, "movie.mp4", 5000000, 10900)
	check(duplicate.id == a.id and store.list_markers(id).size() == 2, "Repeated nearby add highlights original point and binds moved URI")
	var loaded := Store.new(path)
	check(loaded.resolve(moved) == id and loaded.list_markers(id) == store.list_markers(id), "Restart retains markers and newly bound alias")
	check(store.remove(id, a.id) and store.can_undo(), "Delete commits and offers undo")
	check(Store.new(path).list_markers(id).size() == 1, "Delete is persisted before normal shutdown")
	check(store.restore() and store.list_markers(id)[0] == a and not store.can_undo(), "Undo restores original ID and date and sorted position")
	store.remove(id, b.id)
	store.add("file:///other.mp4", "other.mp4", 50, 0)
	check(store.restore() and store.list_markers(id).size() == 2, "Undo after switching movie restores the original movie")
	store.remove(id, a.id); store.undo.until = Time.get_ticks_msec() - 1
	check(not store.can_undo() and not store.restore(), "Undo expires")
	check(store.add(uri, "movie.mp4", 5000000, -1).is_empty(), "Negative position is rejected")
	var failed := FailedWrite.new(path)
	var before := failed.list_markers(id)
	check(not failed.remove(id, b.id) and failed.list_markers(id) == before and not failed.can_undo(), "Failed delete preserves memory and creates no undo")
	check(failed.add(uri, "movie.mp4", 5000000, 60000).is_empty() and failed.list_markers(id) == before, "Failed add preserves memory")
	var damaged_path := path.path_join("damage")
	var damaged := Store.new(damaged_path)
	damaged.add(uri, "movie.mp4", 5000000, 10000)
	damaged.add(uri, "movie.mp4", 5000000, 30000)
	var corrupt := FileAccess.open(damaged._path(id, 0), FileAccess.WRITE)
	corrupt.store_string("broken"); corrupt.close()
	check(Store.new(damaged_path).list_markers(id).size() == 1, "Corrupt latest generation falls back to previous bank")
	var future := FileAccess.open(damaged._path(id, 0), FileAccess.WRITE)
	future.store_string(JSON.stringify({"schema_version": Store.VERSION + 1})); future.close()
	var protected := Store.new(damaged_path)
	check(protected.add(uri, "movie.mp4", 5000000, 50000).is_empty() and protected.list_markers(id).size() == 1, "Future schema cannot be overwritten")
	for index in 34: store.add("file:///%d.mp4" % index, "%d.mp4" % index, index + 1, 10000)
	check(Store.new(path).records.size() == 36, "Bookmarks survive beyond 32 history entries without eviction")
	var limit_store := Store.new(path.path_join("limit"))
	var limit_id := limit_store.resolve(uri, "movie.mp4", 5000000)
	var limit_record := {"id": limit_id, "aliases": [Store.Memory.key_for(uri)], "fingerprint": Store.fingerprint("movie.mp4", 5000000), "markers": []}
	for index in Store.MAX_MARKERS:
		limit_record.markers.append({"id": "%032x" % (index + 1), "position_ms": index * 2000, "created_at_ms": 1})
	check(limit_store._save(limit_record) and limit_store.add(uri, "movie.mp4", 5000000, 1100000).is_empty() and limit_store.last_error == "Bookmark limit reached", "500 point limit rejects additions without eviction")

	var marks := [{"id": "a", "position_ms": 0}, {"id": "b", "position_ms": 10000}, {"id": "c", "position_ms": 1000000}, {"id": "outside", "position_ms": 7200000}]
	var clusters := Timeline.groups(marks, 7200000, 0.82)
	check(clusters.size() == 2 and clusters[0].markers.size() == 2, "Dense timestamps cluster by visible distance and EOS is excluded")
	var dense: Array = []
	for index in 500: dense.append({"id": str(index), "position_ms": index * 14000})
	check(Timeline.groups(dense, 7200000, 0.82).size() <= 19, "500 markers produce bounded, non-overlapping 44 mm targets")
	check(Timeline.groups([{"position_ms": 0}, {"position_ms": 44100}], 820000, 0.82).size() == 2, "Non-overlapping bookmark targets stay separate")
	check(Timeline.groups([{"position_ms": 0}, {"position_ms": 43900}], 820000, 0.82).size() == 1, "Overlapping bookmark targets still group")

	var menu := Menu.new()
	var state := {"has_video": true, "duration_ms": 7200000, "position_ms": 30000,
		"bookmark_scope": "movieA", "bookmark_ready": true, "bookmark_seekable": true,
		"bookmarks": marks.slice(0, 3), "bookmark_revision": 1}
	menu.state_provider = func(): return state
	menu.bookmark_requested.connect(func(operation, marker_id, scope): requests.append([operation, marker_id, scope]))
	root.add_child(menu); menu.toggle(); menu.set_process(false)
	var start := origin(menu, menu.BookmarkMenu.ADD)
	menu.press_pointer("left_hand", start, -menu.global_basis.z, true)
	check(requests.is_empty(), "Bookmark press captures without acting")
	menu.release_pointer("right_hand", start, -menu.global_basis.z, true)
	check(requests.is_empty(), "Other hand cannot release owner action")
	menu.release_pointer("left_hand", start, -menu.global_basis.z, true)
	check(requests == [["add", "", "movieA"]], "Release commits one scoped add")
	start = origin(menu, menu.BookmarkMenu.ADD)
	menu.press_pointer("left_hand", start, -menu.global_basis.z, true)
	menu.update_pointer("left_hand", start, -menu.global_basis.z, false)
	menu.release_pointer("left_hand", start, -menu.global_basis.z, true)
	check(requests.size() == 1, "Lost tracking cancels add")
	menu.press_pointer("left_hand", start, -menu.global_basis.z, true)
	state.bookmark_scope = "movieB"; menu.refresh()
	menu.release_pointer("left_hand", start, -menu.global_basis.z, true)
	check(requests.size() == 1, "Switching movies cancels held actions")
	state.bookmark_scope = "movieA"; menu.refresh()
	tap(menu, menu.BookmarkMenu.GROUP)
	check(requests.size() == 1 and menu.bookmarks.opened and menu.bookmarks.subset.size() == 2, "Cluster expands choice list without seeking")
	tap(menu, menu.BookmarkMenu.ROW)
	check(requests.back() == ["seek", "a", "movieA"], "Timestamp row seeks stable marker ID")
	start = origin(menu, menu.BookmarkMenu.DELETE_ROW)
	menu.press_pointer("left_hand", start, -menu.global_basis.z, true)
	menu.update_pointer("left_hand", start + Vector3(0, 0.05, 0), -menu.global_basis.z, true)
	menu.release_pointer("left_hand", start, -menu.global_basis.z, true)
	check(requests.size() == 2, "Dragging from row actions scrolls/cancels without submitting")
	tap(menu, menu.BookmarkMenu.DELETE_ROW)
	check(requests.back() == ["delete", "a", "movieA"], "Inline delete emits delete alone")
	var previous_count := requests.size()
	start = origin(menu, menu.BookmarkMenu.ADD)
	menu.press_pointer("left_hand", start, -menu.global_basis.z, true)
	menu.release_pointer("left_hand", start + Vector3(0.022, 0, 0), -menu.global_basis.z, true)
	check(requests.size() == previous_count, "Release movement cancels click even without an intermediate pointer update")
	tap(menu, menu.BookmarkMenu.GROUP + 1)
	check(requests.back() == ["seek", "c", "movieA"], "Single anchor requests seek without opening a cluster")
	var count := requests.size()
	state.bookmarks = dense; menu.bookmarks.subset.clear(); menu.refresh()
	menu.stick_scroll(-1, 1)
	check(menu.bookmarks.offset > 0 and requests.size() == count, "Stick only scrolls the bookmark list")
	start = origin(menu, menu.BookmarkMenu.ROW)
	menu.press_pointer("left_hand", start, -menu.global_basis.z, true)
	menu.dismiss(); menu.release_pointer("left_hand", start, -menu.global_basis.z, true)
	check(requests.size() == count, "Closing menu cancels pointer capture")
	menu.toggle(); state.bookmark_ready = false; menu.refresh()
	tap(menu, menu.BookmarkMenu.ADD)
	check(requests.size() == count, "Frozen/invalid time disables add")
	var seek_hit := menu.ray_hit(origin(menu, Menu.SEEK), -menu.global_basis.z)
	check(seek_hit.get("target") == Menu.SEEK, "Bookmark lane does not intercept slider")
	menu.free()

	var video := Video.new()
	video.bookmark_store = Store.new(path.path_join("video"))
	root.add_child(video); video.set_process(false)
	video.media.begin(7); video.media.generation = 3
	video.media.state = "paused"; video.media.playback = {"details": {"seekable": "yes", "partially_seekable": "no"}}
	video.control.duration_ms = 60000; video.local_uri = uri; video.panel.visible = true
	video._bookmark_metadata = {"basename": "movie.mp4", "size": 5000000}; video._bookmark_resolve()
	video._binding.ticket = {"session_id": 7, "generation": 3, "pts_us": 12345000, "source_pts_verified": true}
	check(video.bookmark_snapshot().position_ms == 12345, "Capture uses displayed source frame, not UI clock")
	check(video.bookmark_action("add", "", video.bookmark_scope()) == "Bookmark added" and video.bookmark_store.list_markers(video._bookmark_media_id)[0].position_ms == 12345, "Controller commits actual source timestamp")
	video.control.seek_absolute(40000)
	check(video.bookmark_snapshot().is_empty() and video.bookmark_action("add", "", video.bookmark_scope()).is_empty(), "Pending seek target cannot be bookmarked")
	video.control.reject(); video._binding.ticket.generation = 2
	check(video.bookmark_snapshot().is_empty(), "Stale processing generation is rejected")
	video._binding.ticket.generation = 3
	video._binding.ticket.frozen_frame_id = 1
	check(video.bookmark_snapshot().is_empty(), "Frozen source frame cannot become a bookmark")
	video._binding.ticket.erase("frozen_frame_id")
	video.media.state = "ended"
	check(video.bookmark_seekable(), "Bookmark jumps remain available at EOF")
	video.media.playback.details.partially_seekable = "yes"
	check(not video.bookmark_seekable(), "Partially seekable source disables bookmark jumps")
	check(video.bookmark_action("delete", "a", "stale scope").is_empty(), "Controller independently rejects stale UI scope")
	video.media.playback.details.partially_seekable = "no"
	var bridge := Host.new(); video.platform = bridge; video.requested_play = false
	video.bookmark_action("seek", str(video.bookmark_last_added.id), video.bookmark_scope())
	check(bridge.targets == [[7, 12345]] and video.control.target_ms == 12345 and not video.requested_play, "Stored marker reaches actual revision chain and preserves pause intent")
	video._binding.ticket.clear(); video.free()
	print("Bookmark checks=%d failures=%d" % [checks, failures.size()])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)
