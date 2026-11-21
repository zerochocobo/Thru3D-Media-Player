extends SceneTree
## Run with an isolated user://. Exercises migration and indexing with 10,000 legacy JPEGs.
const Cache := preload("res://scripts/thumbnail_cache.gd")
const References := preload("res://scripts/thumbnail_references.gd")
const Privacy := preload("res://scripts/media_privacy.gd")
const PLAYED := "file:///test/played.mp4"
const REMOTE := "smb://test/media/remote.mp4"
var failures := 0

func _initialize() -> void:
	_run.call_deferred()

func _check(ok: bool, description: String) -> void:
	if ok: return
	failures += 1
	push_error(description)

func _run() -> void:
	if not OS.get_user_data_dir().contains("thumbnail-tests"):
		push_error("Use isolated thumbnail-tests user data")
		quit(1)
		return
	var image := Image.create_empty(320, 180, false, Image.FORMAT_RGB8)
	image.fill(Color.TEAL)
	var jpg := Cache.encode(image)
	DirAccess.make_dir_recursive_absolute(Cache.DIRECTORY)
	var started := Time.get_ticks_msec()
	for index in 10000:
		var file := FileAccess.open(Cache.path_for("file:///test/%d.jpg" % index), FileAccess.WRITE)
		if not file:
			_check(false, "Create legacy cache fixture")
			quit(1)
			return
		file.store_buffer(jpg)
		file.close()
	var write_ms := Time.get_ticks_msec() - started
	var key := "file:///test/9999.jpg"
	started = Time.get_ticks_msec()
	_check(Cache.texture(key) == null, "First lookup does not synchronously load the JPEG")
	while Cache.texture(key) == null and Time.get_ticks_msec() - started < 20000:
		Cache.poll()
		await process_frame
	var cold_ms := Time.get_ticks_msec() - started
	_check(Cache.texture(key) != null and Cache._records.size() == 10000, "All legacy files indexed and cold result applied")
	_check(Cache.usage() == Vector2i(10000, jpg.size() * 10000), "Reported bytes and count match fixtures")

	_check(Cache.store(PLAYED, image) and Cache.store(REMOTE, image), "Store indexed local and remote frames")
	_check(not Cache.store(PLAYED, image, true), "Speculation cannot replace a played frame")
	Cache.protect_keys([PLAYED])
	var large := jpg.duplicate()
	large.resize(512 * 1024)
	for index in 130: _check(Cache.store_encoded("file:///speculative/%d.jpg" % index, large, true), "Store speculative JPEG")
	_check(Cache._speculative_bytes == Cache.SPECULATIVE_BYTES and Cache.has_played_picture(PLAYED), "Speculative quota preserves played frame")
	References.remember_fingerprint("smb-folder", REMOTE, REMOTE, "v1", REMOTE)
	References.remember_cover("smb-folder", "smb://test/media", REMOTE, REMOTE, REMOTE, 1)
	References.remember_fingerprint("local-folder", PLAYED, PLAYED, "v1", PLAYED)
	Privacy.configure(Privacy.LOCAL)
	_check(References.cover("smb-folder").is_empty(), "Local-only mode hides persisted network metadata")
	Privacy.configure(Privacy.NONE)
	References.remember_fingerprint("volatile", PLAYED, PLAYED, "v2", PLAYED)
	_check(not References.fingerprint("volatile", PLAYED).is_empty(), "Opt-out keeps metadata during the session")
	Cache.clear_memory()
	_check(References.fingerprint("volatile", PLAYED).is_empty(), "Transient metadata does not reload")
	Privacy.configure(Privacy.ALL)
	Cache.clear(true)
	_check(not Cache.has(REMOTE) and Cache.has(PLAYED), "Network history cleanup removes network frames while keeping indexed local frames")
	_check(References.cover("smb-folder").is_empty() and not References.fingerprint("local-folder", PLAYED).is_empty(),
		"Network history cleanup removes corresponding references and fingerprints")
	Cache.clear()
	_check(Cache.usage() == Vector2i.ZERO and not FileAccess.file_exists(References.PATH), "Full cleanup removes JPEGs and both indices")
	Cache.finish()
	print("Thumbnail index: 10000 fixtures, write=%dms cold=%dms, %d failures" % [write_ms, cold_ms, failures])
	quit(int(failures > 0))
