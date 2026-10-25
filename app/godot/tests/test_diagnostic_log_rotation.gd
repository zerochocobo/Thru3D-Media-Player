extends SceneTree
## The event log on the headset stays bounded: one current file under the cap plus one previous
## generation; a legacy oversized file is dropped on the first write instead of kept.
const Log := preload("res://scripts/diagnostic_log.gd")
const Privacy := preload("res://scripts/media_privacy.gd")
const DIR := "user://test_diagnostic_log_rotation"
var failures: Array[String] = []
var checks := 0
func _initialize() -> void:
	Privacy.mode = Privacy.ALL
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(DIR))
	Log.path = DIR + "/events.jsonl"; Log.rotated_path = DIR + "/events.1.jsonl"
	for path in [Log.path, Log.rotated_path]:
		if FileAccess.file_exists(path): DirAccess.remove_absolute(path)
	Log.record("first", {"n": 0})
	expect(FileAccess.file_exists(Log.path) and _lines(Log.path) == 1, "The first event creates the log")
	# Fill past the cap: the next write starts a new file and keeps the full one as the previous generation.
	_fill()
	var full := _size(Log.path)
	Log.record("after_cap", {})
	expect(_size(Log.rotated_path) == full, "The full file becomes the previous generation")
	expect(_lines(Log.path) == 1 and FileAccess.get_file_as_string(Log.path).contains("after_cap"), "Writing continues in a fresh file")
	# A second rotation replaces the previous generation; the total never exceeds two caps.
	_fill()
	Log.record("second_rotation", {})
	expect(_size(Log.path) + _size(Log.rotated_path) <= 2 * Log.MAX_BYTES + 8192, "Two generations stay within twice the cap")
	expect(FileAccess.get_file_as_string(Log.rotated_path).begins_with("{\"details\":{},\"event\":\"after_cap\""), "The previous generation is the last full file")
	# A file written before rotation existed (tens of MB) is dropped, not kept as a generation.
	var legacy := FileAccess.open(Log.path, FileAccess.WRITE)
	legacy.store_buffer(PackedByteArray()); legacy.seek(3 * Log.MAX_BYTES); legacy.store_8(10); legacy.close()
	Log.record("upgrade", {})
	expect(not FileAccess.file_exists(Log.rotated_path) and _lines(Log.path) == 1, "An oversized legacy log is dropped")
	# Privacy modes other than full history still write nothing.
	Privacy.mode = Privacy.LOCAL
	Log.record("private", {})
	expect(_lines(Log.path) == 1, "Reduced history writes no events")
	Privacy.mode = Privacy.ALL
	for path in [Log.path, Log.rotated_path]:
		if FileAccess.file_exists(path): DirAccess.remove_absolute(path)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(DIR))
	print("Diagnostic log rotation: %d checks, %d failures" % [checks, failures.size()])
	for failure in failures: print("FAIL: " + failure)
	quit(1 if failures.size() else 0)
## Appends whole lines up to the cap without printing every event.
func _fill() -> void:
	var file := FileAccess.open(Log.path, FileAccess.READ_WRITE)
	file.seek_end()
	var line := "{\"event\":\"fill\",\"padding\":\"%s\"}" % "x".repeat(65536)
	while file.get_length() < Log.MAX_BYTES: file.store_line(line)
	file.close()
func _size(path: String) -> int:
	var file := FileAccess.open(path, FileAccess.READ)
	return file.get_length() if file else 0
func _lines(path: String) -> int:
	return FileAccess.get_file_as_string(path).strip_edges().split("\n").size() if _size(path) > 0 else 0
func expect(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)
