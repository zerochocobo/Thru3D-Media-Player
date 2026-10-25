class_name DiagnosticLog extends RefCounted

const EVENT_PATH := "user://diagnostics/events.jsonl"
## The previous generation; together the log stays within 2 * MAX_BYTES on the headset.
const ROTATED_PATH := "user://diagnostics/events.1.jsonl"
const MAX_BYTES := 4 * 1024 * 1024
## Tests redirect the log; the directory is created once per run.
static var path := EVENT_PATH
static var rotated_path := ROTATED_PATH
static var _dir_ready := ""

static func record(event: String, details: Dictionary = {}) -> void:
	var privacy := preload("res://scripts/media_privacy.gd")
	if privacy.mode != privacy.ALL or (privacy.vault != null and privacy.vault.protected): return
	var entry := {
		"schema_version": 1,
		"event": event,
		"monotonic_us": Time.get_ticks_usec(),
		"unix_seconds": Time.get_unix_time_from_system(),
		"details": details,
	}
	var line := JSON.stringify(entry)
	print("[VP_EVENT] ", line)
	if _dir_ready != path:
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path.get_base_dir()))
		_dir_ready = path
	var file := FileAccess.open(path, FileAccess.READ_WRITE) if FileAccess.file_exists(path) else null
	if file and file.get_length() >= MAX_BYTES:
		var size := file.get_length()
		file.close(); file = null
		_rotate(size)
	if not file: file = FileAccess.open(path, FileAccess.WRITE)
	if file:
		file.seek_end()
		file.store_line(line)

## Keeps one previous generation. A file far over the cap (written before rotation existed) is
## dropped instead of kept, so an upgrade does not leave tens of MB behind.
static func _rotate(size: int) -> void:
	if FileAccess.file_exists(rotated_path): DirAccess.remove_absolute(rotated_path)
	if size > 2 * MAX_BYTES or DirAccess.rename_absolute(path, rotated_path) != OK:
		DirAccess.remove_absolute(path)
