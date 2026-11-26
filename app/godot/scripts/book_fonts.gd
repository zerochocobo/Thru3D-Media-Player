extends "res://scripts/scene_import/scene_gallery.gd"
## Reading fonts the player fetches when a reader picks one: free (SIL Open Font License) fonts for
## each language books come in, kept out of the app so it stays small. The list ships with the app
## (book_fonts/catalog.json, with every file's size and SHA-256); the files come from the same sites
## as the scene library, R2 first and the paid mainland copy only when R2 does not answer, under
## fonts/ instead of scenes/. A font that has arrived whole stays until the reader removes it.

const FONT_CATALOG := "res://book_fonts/catalog.json"
const FONT_FOLDER := "/fonts/"
## The languages a book can be in, as BookPages reports them; Traditional Chinese has its own fonts.
const LANGUAGES := ["zh", "zh_hant", "ja", "en"]
const FONT_PREVIEWS := "res://book_fonts/previews/"
## The sample text shown by each preview; font binaries and publishing infrastructure are supplied separately.
const SAMPLES := {"zh": "春眠不觉晓，处处闻啼鸟", "zh_hant": "春眠不覺曉，處處聞啼鳥",
	"ja": "吾輩は猫である。名前は", "en": "The quick brown fox jumps"}

func _init() -> void:
	directory = "user://book_fonts"

func _ready() -> void:
	load_catalog()

## The scene library's sites, asked for the font folder.
func site_order() -> Array:
	var order: Array = super.site_order()
	if not sites.is_empty(): return order
	return order.map(func(site: Array) -> Array: return [site[0], site[1], site[2], FONT_FOLDER])

func load_catalog(path: String = FONT_CATALOG) -> void:
	rows.clear()
	var file := FileAccess.open(path, FileAccess.READ)
	var parser := JSON.new()
	if file == null or file.get_length() > MAX_CATALOG_BYTES or parser.parse(file.get_as_text()) != OK or not parser.data is Dictionary: return
	var listed: Variant = parser.data.get("fonts")
	if not listed is Array: return
	for item in listed:
		if not item is Dictionary: continue
		var id := str(item.get("id", ""))
		var name := str(item.get("file", ""))
		# The file name is all a server is ever asked for: nothing in it may leave the font folder.
		if id.is_empty() or id != id.validate_filename() or name.is_empty() or name != name.validate_filename() \
			or not name.get_extension().to_lower() in ["otf", "ttf"] or str(item.get("sha256", "")).length() != 64 \
			or int(item.get("bytes", 0)) <= 0 or row(id).size() > 0:
			continue
		var languages: Array = (item.get("languages", []) as Array).filter(func(lang): return lang in LANGUAGES) if item.get("languages") is Array else []
		rows.append({"slug": id, "title": str(item.get("name", id)).left(60), "title_zh": str(item.get("name_zh", "")).left(60),
			"title_zh_hant": str(item.get("name_zh_hant", "")).left(60), "title_ja": str(item.get("name_ja", "")).left(60),
			"languages": languages, "license": str(item.get("license", "")).left(24),
			"tiers": {"all": {"file": name, "bytes": int(item.bytes), "sha256": str(item.sha256).to_lower()}}})

## The fonts offered for a book in [language], in catalogue order.
func fonts_for(language: String) -> Array:
	return rows.filter(func(item: Dictionary) -> bool: return language in item.languages)

## A line set in the font, rendered when it was published; null when there is none.
func preview(id: String) -> Texture2D:
	var path := FONT_PREVIEWS + id + ".png"
	return load(path) as Texture2D if ResourceLoader.exists(path) else null

func file_of(id: String) -> Dictionary:
	var item := row(id)
	return item.tiers.all if not item.is_empty() else {}

## Where an arrived font is kept, whether or not it is there yet.
func path_of(id: String) -> String:
	var tier := file_of(id)
	return ProjectSettings.globalize_path(directory).path_join(str(tier.file)) if not tier.is_empty() else ""

## A font is installed when its whole file is in place; downloads are checked against the catalogue
## as they finish, so the size is enough here (hashing megabytes each time a book opens is not).
func installed(id: String) -> bool:
	var tier := file_of(id)
	var path := path_of(id)
	return not tier.is_empty() and FileAccess.file_exists(path) and FileAccess.get_size(path) == int(tier.bytes)

## Starts bringing a font down; false when it is already here or on its way.
func fetch(id: String) -> bool:
	if installed(id): return false
	return request(id, "all")

func remove(id: String) -> void:
	cancel(id)
	var path := path_of(id)
	if not path.is_empty():
		DirAccess.remove_absolute(path)
		DirAccess.remove_absolute(path + ".partial")
	states.erase(id)
	changed.emit()

## What a row of the font list shows: "installed", "loading" (with progress), "queued", "failed", "withdrawn" or "".
func state_of(id: String) -> String:
	if installed(id): return "installed"
	return str(states.get(id, {}).get("state", ""))

func display_name(id: String, ui_language: String) -> String:
	var item := row(id)
	if item.is_empty(): return id
	var key: String = {"zh": "title_zh", "zh_Hant": "title_zh_hant", "ja": "title_ja"}.get(ui_language, "title")
	var name := str(item.get(key, ""))
	return name if not name.is_empty() else str(item.title)
