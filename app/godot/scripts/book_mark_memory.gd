extends "res://scripts/file_mode_memory.gd"
## A book's bookmarks. Each is a reading position ("chapter/block/character"), which stays true when the
## type size or the page form lays the book out again; PDF pages keep their page number in the same form.
## Kept like other per-file settings: the privacy switch for them gates it, and clearing them clears these.
const MAX_MARKS := 200
const TEXT_LIMIT := 48

func _init(path: String = "user://settings") -> void:
	super(path)

func _bank_path(bank: int) -> String:
	return directory.path_join("book_marks_%d.json" % bank)

func _value_field() -> String: return "book_marks"

## Room for many books' marks; each mark is a position, a chapter name and a few words.
func _max_bytes() -> int: return 1048576

func _limit() -> int: return 256

static func valid_at(at: Variant) -> bool:
	if not at is String or at.length() > 48: return false
	var parts: PackedStringArray = at.split("/")
	if parts.size() != 3: return false
	for part in parts:
		if not part.is_valid_int() or int(part) < 0: return false
	return true

func _valid_value(value: Variant) -> bool:
	if not value is Dictionary or not value.get("marks") is Array or value.marks.size() > MAX_MARKS: return false
	for mark in value.marks:
		if not mark is Dictionary or not valid_at(mark.get("at")): return false
		if not mark.get("chapter", "") is String or not mark.get("text", "") is String: return false
	return true

func _normalize_value(value: Dictionary) -> Dictionary:
	var marks := []
	for mark in value.marks:
		marks.append({"at": str(mark.at), "chapter": str(mark.get("chapter", "")).left(TEXT_LIMIT),
			"text": str(mark.get("text", "")).left(TEXT_LIMIT), "created": int(mark.get("created", 0))})
	return {"marks": marks}

func marks(uri: String) -> Array:
	return lookup(uri).get("marks", [])

## Replaces the book's marks and writes them out; false when this book's settings are not kept.
func store(uri: String, list: Array) -> bool:
	if not remember(uri, {"marks": list}): return false
	return save()
