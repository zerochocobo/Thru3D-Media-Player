extends RefCounted
## Pure protocol / alignment helpers. No network, settings or media access.
const NarrationLanguages := preload("res://scripts/narration_languages.gd")
static var LANGUAGES: Array = target_choices().map(func(item): return item.value)
const MAX_BATCH := 8
const MAX_CHARACTERS := 3000

static func language(value: String) -> String:
	return {"zh": "zh-Hans", "zh-CN": "zh-Hans", "zh_TW": "zh-Hant", "zh_Hant": "zh-Hant", "zh-TW": "zh-Hant"}.get(value, value) if value in LANGUAGES or value in ["zh", "zh-CN", "zh_TW", "zh_Hant", "zh-TW"] else "auto"

static func target_choices() -> Array:
	var choices := []
	for code in NarrationLanguages.NAMES:
		if code == "zh":
			choices.append({"value":"zh-Hans","label":"简体中文","literal":true})
			choices.append({"value":"zh-Hant","label":"繁體中文","literal":true})
		else: choices.append({"value":code,"label":NarrationLanguages.NAMES[code]})
	return choices

static func normalize(value: String, source: String) -> String:
	var lines := value.replace("\r\n", "\n").replace("\r", "\n").split("\n", false)
	var result := ""
	for line in lines:
		line = line.strip_edges()
		if line.is_empty(): continue
		# Preserve English word boundaries; CJK visual rows/columns have none.
		if not result.is_empty() and source not in ["zh", "zh-Hans", "zh-Hant", "ja"]:
			if result.ends_with("-") and source == "en": result = result.left(-1)
			else: result += " "
		result += line
	return result.strip_edges()

static func cache_key(text: String, source: String, target: String) -> String:
	return JSON.stringify([source, target, text]).sha256_text()

static func marker(index: int) -> String: return "⟦T3D%04d⟧" % index

static func bing_text(batch: Array) -> String:
	var parts := PackedStringArray()
	for i in batch.size(): parts.append(marker(i) + "\n" + str(batch[i].text))
	return "\n\n".join(parts) + "\n\n⟦T3DEND⟧"

static func split_bing(text: String, count: int) -> Array:
	# Exact ordered boundaries, including the terminator, are mandatory. Reject
	# the entire batch if the service changes/drops/repeats a marker; never guess.
	text = text.strip_edges()
	if count < 1 or count > MAX_BATCH or not text.begins_with(marker(0)) or not text.ends_with("⟦T3DEND⟧"): return []
	var matches := RegEx.create_from_string("⟦T3D[^⟧]*⟧").search_all(text)
	if matches.size() != count + 1: return []
	var output := []
	for i in count:
		if matches[i].get_string() != marker(i): return []
		var part := text.substr(matches[i].get_end(), matches[i + 1].get_start() - matches[i].get_end()).strip_edges()
		if part.is_empty() or part.length() > 2000 or "T3D" in part: return []
		output.append(part)
	return output if matches[count].get_string() == "⟦T3DEND⟧" else []

static func translated(data: Variant, target: String) -> String:
	if not data is Dictionary: return ""
	var translations: Variant = data.get("translations")
	if not translations is Array or translations.size() != 1: return ""
	var item: Variant = translations[0]
	if not item is Dictionary or item.get("to") != target or not item.get("text") is String: return ""
	return item.text.strip_edges()

static func parse_edge(data: Variant, count: int, target: String) -> Array:
	if not data is Array or data.size() != count: return []
	var output := []
	for item: Variant in data:
		var text := translated(item, target)
		if text.is_empty() or text.length() > 2000: return []
		output.append(text)
	return output

static func batches(entries: Array) -> Array:
	var groups := {}
	for entry: Dictionary in entries:
		if not groups.has(entry.source): groups[entry.source] = []
		groups[entry.source].append(entry)
	var output := []
	for group: Array in groups.values():
		var batch := []; var characters := 0
		for entry: Dictionary in group:
			var size: int = entry.text.length() + 20
			if batch.size() >= MAX_BATCH or characters + size > MAX_CHARACTERS:
				output.append(batch); batch = []; characters = 0
			batch.append(entry); characters += size
		if not batch.is_empty(): output.append(batch)
	return output
