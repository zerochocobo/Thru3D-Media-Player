extends SceneTree
const Menu := preload("res://scripts/library_menu.gd")
const Cache := preload("res://scripts/thumbnail_cache.gd")
const Artwork := preload("res://scripts/library_directory_artwork.gd")
const References := preload("res://scripts/thumbnail_references.gd")
const PHOTO := "cloud://test/album/cover.jpg"
const MOVIE := "cloud://test/movies/movie.mp4"
var failures := 0

class CloudFixture extends RefCounted:
	var requests: Array = []
	func media_cloud_page(path: String, offset: int, refresh: bool) -> int:
		requests.append([path, offset, refresh])
		return requests.size() + 100

func _initialize() -> void:
	_run.call_deferred()

func _check(ok: bool, message: String) -> void:
	if ok: return
	failures += 1
	push_error(message)

func _apply(menu: Menu, result: Dictionary, id: int = 20) -> void:
	result.merge({"state": "ready", "path": menu._cloud_path(), "offset": 0, "total": 0, "next_offset": -1, "order": ""})
	menu._request("cloud", id)
	menu._on_media_list(id, JSON.stringify(result))
	for frame in 100:
		if not menu.directory_artwork.busy(): return
		menu.directory_artwork.tick(menu._artwork_scope())
		await process_frame
	_check(false, "Directory comparison finished within the frame bound")

func _run() -> void:
	if not OS.get_user_data_dir().contains("thumbnail-tests"):
		push_error("Use isolated thumbnail-tests user data")
		quit(1)
		return
	Cache.clear()
	await _test_folder_negative()
	var host := CloudFixture.new()
	var menu := Menu.new()
	root.add_child(menu)
	menu.set_process(false)
	menu.platform = host
	menu.section = Menu.Section.CLOUD
	menu._cloud_stack = [{"id": "/test", "title": "Test", "provider": "webdav"}, {"id": "/test/album", "title": "Album", "cloud_id": "album"}]
	var folder := menu._artwork_scope()
	var entry := {"id": "/test/album/cover.jpg", "cloud_id": "cover", "uri": PHOTO,
		"title": "cover.jpg", "kind": "image", "size": 12, "modified": 100, "container": false}
	await _apply(menu, {"freshness": "fresh", "complete": true, "entries": [entry]})
	_check(References.cover(folder).is_empty(), "Entering a remote folder does not create a cover")
	var image := Image.create_empty(320, 180, false, Image.FORMAT_RGB8)
	image.fill(Color.AQUA)
	var row := menu._entry_row(entry)
	menu._choose(row)
	Cache.store(PHOTO, image)
	_check(menu.directory_artwork.observed(PHOTO) and Artwork.texture(folder) != null, "Explicit image yields a reusable directory cover")
	await _apply(menu, {"freshness": "cached", "complete": true, "entries": []})
	_check(Artwork.texture(folder) != null, "Cached absence preserves the existing cover")
	await _apply(menu, {"complete": true, "entries": []})
	_check(Artwork.texture(folder) != null, "Unmarked absence is treated as unknown")
	await _apply(menu, {"freshness": "fresh", "complete": false, "entries": []})
	_check(Artwork.texture(folder) != null, "Absence on a fresh partial page preserves the existing cover")
	menu._refresh_source()
	menu._refresh_source()
	_check(host.requests.size() == 1 and host.requests[0][2], "Two manual refresh clicks share one forced listing request")
	menu._on_media_list(101, JSON.stringify({"state": "error", "path": "/test/album", "offset": 0, "order": ""}))
	_check(Artwork.texture(folder) != null, "Failed refresh preserves the cover and its fingerprint")
	menu._refresh_source()
	await _apply(menu, {"freshness": "fresh", "complete": true, "entries": []}, 102)
	_check(Artwork.texture(folder) == null and not Cache.has(PHOTO), "Complete new listing removes the absent cover and cached image")
	await _apply(menu, {"freshness": "cached", "complete": true, "entries": [entry]})
	_check(Artwork.texture(folder) == null and not menu.directory_artwork.allowed_picture(folder, row.thumb_item),
		"Older cached page cannot restore the detached cover or show its old image")
	var legacy := entry.duplicate()
	legacy.uri = "cloud://test/album/old.mp4"
	legacy.cloud_id = "old"
	legacy.title = "old.mp4"
	legacy.kind = "video"
	Cache.store(legacy.uri, image)
	await _apply(menu, {"freshness": "cached", "entries": [legacy]})
	_check(menu._picture(menu._entry_row(legacy)) != null and References.fingerprint(folder, "old").is_empty(),
		"Unindexed playback screenshot can display on a cached page without creating a fingerprint")

	menu._cloud_stack[1] = {"id": "/test/movies", "title": "Movies", "cloud_id": "movies"}
	var movie := {"id": "/test/movies/movie.mp4", "cloud_id": "movie", "uri": MOVIE, "title": "movie.mp4", "kind": "video", "size": 100}
	await _apply(menu, {"freshness": "fresh", "complete": true, "entries": [movie]})
	var film_folder := menu._artwork_scope()
	menu._choose(menu._entry_row(movie))
	Cache.store(MOVIE, image)
	_check(menu.directory_artwork.observed(MOVIE) and Artwork.texture(film_folder) != null, "Normal playback screenshot can supply its folder cover")
	menu._cloud_stack.resize(1)
	var children: Array = []
	for i in 500:
		children.append({"id": "/test/folder%d" % i, "cloud_id": "folder%d" % i, "title": "Folder %d" % i, "container": true})
	await _apply(menu, {"freshness": "fresh", "complete": true, "entries": children})
	menu.view_mode = "grid"
	menu.show()
	menu.refresh()
	_check(host.requests.size() == 2 and menu._covers.is_empty() and menu._folder_covers.requests == 0, "500 unfamiliar remote folders cause zero extra directory or media requests")
	await _test_declared_cover(menu, image)
	Cache.clear()
	Cache.finish()
	menu.free()
	print("Directory artwork: %d failures" % failures)
	quit(int(failures > 0))

func _test_folder_negative() -> void:
	var artwork := Artwork.new()
	var parent := "/storage/emulated/0/fixture"
	var child := parent + "/folder"
	var identity := Artwork.folder_identity(child)
	var until := int(Time.get_unix_time_from_system()) + 600
	var location := {"type": "local", "path": parent}
	References.remember_fingerprint(parent, identity, "file://" + child, "100", "", until)
	var listing := {"freshness": "fresh", "complete": true,
		"entries": [{"id": child, "title": "folder", "container": true, "modified": 100}]}
	artwork.accept(location, listing)
	await _finish_comparison(artwork, parent)
	_check(References.fingerprint(parent, identity).get("failed_until") == until, "A complete fresh listing preserves a present child's negative cache")
	listing.entries[0].modified = 101
	artwork.accept(location, listing)
	await _finish_comparison(artwork, parent)
	_check(References.fingerprint(parent, identity).is_empty(), "A changed child version invalidates the negative cache")
	References.remember_fingerprint(parent, identity, "file://" + child, "101", "", until)
	listing.entries.clear()
	artwork.accept(location, listing)
	await _finish_comparison(artwork, parent)
	_check(References.fingerprint(parent, identity).is_empty(), "A complete listing invalidates a deleted child's negative cache")

func _finish_comparison(artwork: Artwork, folder: String) -> void:
	var deadline := Time.get_ticks_msec() + 5000
	while Time.get_ticks_msec() < deadline:
		Cache.poll()
		if artwork.tick(folder): return
		await process_frame
	_check(false, "Folder fingerprints finished comparing")

func _test_declared_cover(menu: Menu, image: Image) -> void:
	var server := TCPServer.new()
	if server.listen(0, "127.0.0.1") != OK:
		_check(false, "Bind the loopback DLNA image fixture")
		return
	menu.section = Menu.Section.DLNA
	menu._dlna_server = "fixture"
	menu._dlna_entries = [
		{"id": "declared", "title": "Declared", "container": true, "cover": "http://127.0.0.1:%d/art.png" % server.get_local_port()},
		{"id": "ordinary", "title": "Ordinary", "container": true},
	]
	menu.refresh()
	var png := image.save_png_to_buffer()
	var response := ("HTTP/1.1 200 OK\r\nContent-Type: image/png\r\nContent-Length: %d\r\nConnection: close\r\n\r\n" % png.size()).to_utf8_buffer()
	response.append_array(png)
	var peer: StreamPeerTCP
	var incoming := ""
	var served := 0
	var shown: Texture2D
	for frame in 300:
		if not peer and server.is_connection_available(): peer = server.take_connection()
		if peer:
			peer.poll()
			if peer.get_available_bytes() > 0:
				incoming += peer.get_utf8_string(peer.get_available_bytes())
			if incoming.contains("\r\n\r\n"):
				_check(incoming.begins_with("GET /art.png "), "Only the declared artwork URL is requested")
				peer.put_data(response)
				peer.disconnect_from_host()
				peer = null
				incoming = ""
				served += 1
		menu._folder_covers.tick()
		Cache.poll()
		shown = menu._picture(menu.rows[0])
		if shown: break
		await process_frame
	_check(shown != null and served == 1 and menu._folder_covers.requests == 1 and menu._pending.is_empty(),
		"Declared thumbnail uses one small image GET and zero extra Browse requests")
	_check(menu._picture(menu.rows[1]) == null, "DLNA folder without declared artwork stays an icon")
	server.stop()
