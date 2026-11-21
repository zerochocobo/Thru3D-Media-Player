extends SceneTree

const Cache := preload("res://scripts/thumbnail_cache.gd")
const References := preload("res://scripts/thumbnail_references.gd")
const LOCAL := "file:///fixture/local.mp4"
const REMOTE := "smb://fixture/share/remote.mp4"
const SCOPE := "fixture"
var failures := 0

func _initialize() -> void:
	_run.call_deferred()

func _check(ok: bool, message: String) -> void:
	if ok: return
	failures += 1
	push_error(message)

func _wait_for_load() -> void:
	var deadline := Time.get_ticks_msec() + 8000
	while not References.ready() and Time.get_ticks_msec() < deadline:
		References.poll()
		await process_frame
	_check(References.ready(), "Cold reference load completed")

func _wait_for_clear() -> void:
	var deadline := Time.get_ticks_msec() + 8000
	while Cache.clearing() and Time.get_ticks_msec() < deadline:
		Cache.poll()
		await process_frame
	_check(not Cache.clearing(), "Cleanup completed")

func _run() -> void:
	if not OS.get_user_data_dir().contains("thumbnail-tests"):
		push_error("Use isolated thumbnail-tests user data")
		quit(1)
		return
	var prefix := SCOPE.sha1_text() + ":"
	var local_key := prefix + LOCAL.sha1_text()
	var local := {"version": "v1".sha1_text(), "picture": LOCAL.sha1_text(), "failed_until": 0, "quality": 10, "local": true}
	var entries := {local_key: local}
	for index in range(1, References.MAX_FINGERPRINTS - 1):
		var uri := "smb://fixture/%d" % index
		entries[prefix + uri.sha1_text()] = {"version": "v1".sha1_text(), "picture": uri.sha1_text(), "failed_until": 0, "quality": 10, "local": false}
	var covers := {}
	for index in References.MAX_COVERS:
		covers[str(index).sha1_text()] = {"identity": LOCAL.sha1_text(), "picture": LOCAL.sha1_text(), "quality": 10, "modified": 0, "local": true}
	DirAccess.make_dir_recursive_absolute(Cache.DIRECTORY)
	var fixture := FileAccess.open(References.PATH, FileAccess.WRITE)
	fixture.store_var({"entries": entries, "covers": covers})
	var fixture_bytes := fixture.get_position()
	fixture.close()
	_check(References.fingerprint(SCOPE, LOCAL).is_empty() and not References._loaded and References._load_task >= 0,
		"First lookup starts loading without waiting for the disk index")
	await _wait_for_load()
	_check(References._entries.keys().front() == local_key, "Loaded index retains on-disk LRU order")
	var started := Time.get_ticks_usec()
	for index in 1000:
		_check(References.fingerprint(SCOPE, LOCAL) == local and not References.cover("0").is_empty(), "Warm lookup returns the indexed entry and cover")
	var lookup_us := Time.get_ticks_usec() - started
	_check(References._entries.keys().back() == local_key, "Warm lookup moved the entry in memory")
	_check(References._save_at == 0 and References._save_task < 0, "Warm lookups did not schedule a full rewrite")

	var image := Image.create_empty(320, 180, false, Image.FORMAT_RGB8)
	Cache.store(LOCAL, image)
	Cache.store(REMOTE, image)
	var name := Cache.path_for(LOCAL).get_file()
	var old_picture: Dictionary = Cache._records[name]
	old_picture.local = false
	old_picture.used = 0
	Cache._index_save_at = 0
	Cache._touch(name)
	_check(Cache._index_save_at == 0 and Cache._index_touched and old_picture.used == 0,
		"Image access updates LRU without changing the writer's record or scheduling another save")
	References.remember_fingerprint(SCOPE, REMOTE, REMOTE, "v1", REMOTE)
	References._start_save()
	Cache.clear_in_background(true, [LOCAL])
	_check(Cache.clearing() and References.cover("0").is_empty() and FileAccess.file_exists(Cache.path_for(REMOTE)),
		"Clear revokes access before either background job can publish")
	await _wait_for_clear()
	_check(Cache.has(LOCAL) and not FileAccess.file_exists(Cache.path_for(REMOTE)), "Network clear deletes only remote or unknown pictures")
	var saved := FileAccess.open(References.PATH, FileAccess.READ)
	var data: Dictionary = saved.get_var()
	saved.close()
	_check(data.entries.size() == 1 and data.entries.has(local_key),
		"A stale save cannot republish the remote records after the network clear")
	Cache.clear_in_background(true)
	Cache.poll()
	Cache.clear_in_background()
	await _wait_for_clear()
	_check(Cache.usage() == Vector2i.ZERO and not FileAccess.file_exists(References.PATH), "A full clear requested during a network clear includes local data")
	Cache.finish()
	print("Thumbnail reference I/O: %d bytes, 2000 lookups in %.3f ms, %d failures" % [fixture_bytes, lookup_us / 1000.0, failures])
	quit(int(failures > 0))
