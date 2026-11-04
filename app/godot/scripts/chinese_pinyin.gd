extends RefCounted
## Candidate/explicit-boundary semantics adapted from ChinaWander/pinyin_ime.gd.
## Compact Rime index replaces the mixed lexicon and its per-entry Dictionaries.
static var keys := PackedStringArray()
static var offsets := PackedInt32Array()
static var blocks := PackedByteArray()
static var loader: Thread
static var failed := false
const PAGE_SIZE := 6
const MAX_CANDIDATES := 256
var composing := ""
var candidates: Array[Dictionary] = []
var page := 0

static func load_lexicon() -> bool:
	if not keys.is_empty(): return true
	return _adopt(loader.wait_to_finish() if loader != null else _read_index())

static func begin_load() -> void:
	if not keys.is_empty() or loader != null or failed: return
	loader = Thread.new()
	if loader.start(_read_index) != OK: loader = null; failed = true

static func poll_lexicon() -> void:
	if loader != null and not loader.is_alive(): _adopt(loader.wait_to_finish())

static func _adopt(data: Dictionary) -> bool:
	loader = null
	failed = data.is_empty()
	if failed: return false
	keys = data["keys"]; offsets = data.offsets; blocks = data.blocks
	return true

static func _read_index() -> Dictionary:
	var next_keys := FileAccess.get_file_as_string("res://input/pinyin.keys").split("\n", false)
	var next_offsets := FileAccess.get_file_as_bytes("res://input/pinyin.offsets").to_int32_array()
	var next_blocks := FileAccess.get_file_as_bytes("res://input/pinyin.words")
	if next_keys.is_empty() or next_offsets.size() != next_keys.size() + 1 or next_offsets[0] != 0 or next_offsets[-1] != next_blocks.size(): return {}
	for i in next_keys.size():
		if next_offsets[i] >= next_offsets[i + 1] or (i > 0 and next_keys[i - 1] >= next_keys[i]): return {}
	return {"keys": next_keys, "offsets": next_offsets, "blocks": next_blocks}

func clear() -> void:
	composing = ""; candidates.clear(); page = 0

func type_letter(letter: String) -> void:
	letter = letter.to_lower().replace("ü", "v")
	if composing.length() >= 48: return
	if letter == "'":
		if composing.is_empty() or composing.ends_with("'"): return
	elif letter.length() != 1 or letter < "a" or letter > "z": return
	composing += letter; refresh()

func backspace() -> void:
	composing = composing.left(-1); refresh()

func refresh() -> void:
	page = 0; candidates.clear()
	if composing.is_empty() or not load_lexicon(): return
	var compact := composing.replace("'", "")
	var seen := {}
	# Prefer exact words, then selectable prefixes; never invent a low-quality sentence.
	for count in range(compact.length(), 0, -1):
		var key := compact.left(count)
		var index := keys.bsearch(key)
		if index >= keys.size() or keys[index] != key: continue
		var rows := blocks.slice(offsets[index], offsets[index + 1]).get_string_from_utf8().split("\n", false)
		for row in rows:
			var entry := row.split("\t")
			if entry.size() != 2 or seen.has(entry[1]) or not _boundaries_match(entry[0], count): continue
			seen[entry[1]] = true
			candidates.append({"text": entry[1], "consume": count})
			if candidates.size() >= MAX_CANDIDATES: return

func _boundaries_match(reading: String, count: int) -> bool:
	var position := 0
	var allowed: Array[int] = []
	for letter in reading:
		if letter == "'": allowed.append(position)
		else: position += 1
	position = 0
	for letter in composing:
		if letter == "'":
			if position < count and position not in allowed: return false
		else: position += 1
	return true

func choose(index: int) -> String:
	if index < 0 or index >= candidates.size(): return ""
	var candidate := candidates[index]
	var remaining := int(candidate.consume)
	var raw_count := 0
	for letter in composing:
		if remaining <= 0: break
		raw_count += 1
		if letter != "'": remaining -= 1
	composing = composing.substr(raw_count).trim_prefix("'"); refresh()
	return candidate.text

func page_by(delta: int) -> void:
	page = clampi(page + delta, 0, maxi(0, (candidates.size() - 1) / PAGE_SIZE))

func page_items() -> Array[Dictionary]:
	return candidates.slice(page * PAGE_SIZE, (page + 1) * PAGE_SIZE)
