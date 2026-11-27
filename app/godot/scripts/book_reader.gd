extends Node3D
## Reading mode: a great tome afloat in the air, read with a wand. It owns its pages, position, type
## settings and controls, and shares nothing with the video or photo viewers.

const LeafMotion := preload("res://scripts/book_leaf_motion.gd")
const Model := preload("res://scripts/book_model.gd")
const Bar := preload("res://scripts/book_bar.gd")
const Wand := preload("res://scripts/book_wand.gd")
const I18n := preload("res://scripts/i18n.gd")
const Methods := preload("res://scripts/platform_methods.gd")
const PageLayers := preload("res://scripts/book_page_layers.gd")
const MarkMemory := preload("res://scripts/book_mark_memory.gd")
const Privacy := preload("res://scripts/media_privacy.gd")
const Narration := preload("res://scripts/book_narration.gd")
const Fonts := preload("res://scripts/book_fonts.gd")
## A warm wash over the paragraph being read aloud, with a bar in the margin beside it. Added on top
## of the page (and its sharp layer), so it never dims the words.
const READING_SHADER := """
shader_type spatial;
render_mode unshaded, blend_premul_alpha, cull_disabled, depth_draw_never, depth_test_disabled, shadows_disabled;
uniform vec3 colour : source_color = vec3(1.0, 0.72, 0.30);
uniform float bar = 0.02;
uniform vec2 size = vec2(1.0);
void fragment() {
	vec2 at = UV * size;
	vec2 edge = min(at, size - at);
	float wash = smoothstep(0.0, 0.012, min(edge.x, edge.y)) * 0.07;
	float mark = step(UV.x * size.x, bar) * 0.55;
	ALBEDO = colour * max(wash, mark);
	// Light adds to what is behind it, but must not make the eye buffer opaque: where the eye buffer is
	// cleared over a page or menu layer (or passthrough), additive blending wrote alpha 1 across the
	// whole quad and showed it as a black square. Coverage follows the light itself.
	ALPHA = clamp(max(ALBEDO.r, max(ALBEDO.g, ALBEDO.b)), 0.0, 1.0);
}
"""
const EXTENSIONS := ["epub", "txt", "mobi", "azw3", "azw", "prc"]
## Full-width characters per line, smallest type last.
const COLUMNS := [14, 16, 18, 20, 22, 25, 28, 32]
const DEFAULT_FONT := 3
const PAPERS := [
	{"paper": "#E9E2D0", "ink": "#1D1B18", "faint": "#8A8375", "cover": Color(0.23, 0.17, 0.13)},
	{"paper": "#C9C3B5", "ink": "#1D1B18", "faint": "#7D776B", "cover": Color(0.16, 0.18, 0.20)},
	{"paper": "#F4F1EA", "ink": "#111111", "faint": "#8C8C8C", "cover": Color(0.13, 0.20, 0.17)},
	{"paper": "#23211E", "ink": "#B9B2A4", "faint": "#6B665C", "cover": Color(0.07, 0.07, 0.08), "night": true},
	{"paper": "#C7E3C3", "ink": "#1B2219", "faint": "#6F8069", "cover": Color(0.12, 0.20, 0.14)},
	{"paper": "#0E0E0E", "ink": "#8E897F", "faint": "#55524C", "cover": Color(0.04, 0.04, 0.05), "night": true},
	{"paper": "#17201B", "ink": "#97A89C", "faint": "#56625A", "cover": Color(0.05, 0.08, 0.06), "night": true}]
## The papers as the settings show them, lightest first: day papers, then night ones.
const DAY_PAPERS := [2, 0, 4, 1]
const NIGHT_PAPERS := [3, 6, 5]
## Space between lines (in type sizes), between paragraphs (in lines), and how much of the widest
## text block a line fills (smaller: wider margins at the same type size).
const SPACINGS := [1.4, 1.6, 1.75, 2.0, 2.2]
const DEFAULT_SPACING := 2
const PARAGRAPHS := [0.0, 0.3, 0.7, 1.2]
const DEFAULT_PARAGRAPH := 1
const MEASURES := [1.0, 0.92, 0.84, 0.76]
## Seconds a page stays open while the pages turn by themselves; a spread stays twice as long.
const AUTO_SECONDS := [10, 15, 20, 30, 45, 60, 90]
const DEFAULT_AUTO := 3
## The ways of turning a page, each of which the reader can turn off.
const TURNS := ["swish", "drag", "buttons", "stick", "palm"]
const EDGE := 1024
## Printed pages (PDF) carry their own small type and scans; they are drawn sharper.
const PRINTED_EDGE := 1536
const TURN_SECONDS := LeafMotion.TURN_SECONDS
## The tome is four times a desk folio and hangs well beyond arm's reach, so its type subtends what
## a held book's would while the object itself towers over the reader.
const SCALE := 4.0
const DISTANCE := 4.4
## Steps the reader can set the tome's size and its distance to (factors of the defaults above).
const SIZES := [0.6, 0.75, 0.88, 1.0, 1.15, 1.3, 1.5]
const REACHES := [0.45, 0.6, 0.8, 1.0, 1.25, 1.55]
const DEFAULT_SIZE := 3
const DEFAULT_REACH := 3
## A little below the eyes, where a reader's gaze rests for hours without tiring the neck.
const LIFT := -0.45
const LEAN := 8.0
## Paper brightness steps: a large bright page in a dark scene glares through the lenses.
const LIGHTS := [1.0, 0.9, 0.8, 0.7, 0.6, 0.5, 0.4]
## Warmth takes blue, then some green, out of the page, for long reading at night.
const WARMTHS := [0.0, 0.2, 0.4, 0.6, 0.8, 1.0]
const ARRIVE_SECONDS := 1.4
## A deliberate swish of the wand, in radians per second across the book.
const SWISH := 4.5
const SWISH_REST := 1.0
## A leap of more than a few pages lets blank leaves flutter over first.
const RIFFLE_SECONDS := 0.5
## How fast (leaf widths per second) a carried leaf must be moving when let go to fly on by itself.
const FLICK := 2.0

signal closed
signal library_requested
signal changed
## A small touch in the wand hand: a leaf lifted, landed or a chapter begun.
signal felt(strength: float)
## Search hits for the request [token]: {"query", "hits": [{"at", "chapter", "text", "mark"}], "more"}.
signal found(token: int, result: Dictionary)

var active := false
var platform: Object
var catalog: RefCounted
var settings: ConfigFile
var save_settings: Callable
var head_provider: Callable
var uri := ""
var title := ""
var session := 0
var info := {}
var contents: Array = []
## The open book's bookmarks, in reading order: [{"at", "chapter", "text", "created"}].
var marks: Array = []
var mark_memory := MarkMemory.new()
## Marks kept for this run only, where the book's settings may not be saved.
var _session_marks := {}
var _search_token := 0
var _sections_for: Array = []
var _section_pages := PackedInt32Array()
var _section_titles := PackedStringArray()
var count := 0
## The right-hand page of the open spread, or the only page when reading one at a time.
var page := 0
var font := DEFAULT_FONT
var paper := 0
var single := false
var size_step := DEFAULT_SIZE
var reach_step := DEFAULT_REACH
var _frame := Transform3D.IDENTITY
var light := 0
var warmth := 0
var spacing := DEFAULT_SPACING
var paragraph := DEFAULT_PARAGRAPH
var measure := 0
## The paper last chosen for day and for night, so the switch between them comes back to each.
var day_paper := 0
var night_paper := 3
## Which ways of turning a page are on; a reader who gestures as they read turns the swish off.
var turns := {"swish": true, "drag": true, "buttons": true, "stick": true, "palm": true}
var auto_step := DEFAULT_AUTO
## The pages turn by themselves; this run only, it never starts by itself.
var auto := false
var _auto_elapsed := 0.0
var message := ""
var model := Model.new()
var bar := Bar.new()
var wand := Wand.new()
## Sharp pages on compositor layers while they lie still; main configures it once XR is up.
var layers := PageLayers.new()
var narration := Narration.new(self)
## Downloadable reading fonts, and the one chosen for each language books come in ("" is the system's).
var fonts := Fonts.new()
var font_choices := {}
## The font file the open book was laid out with, and the language it turned out to be written in.
var _laid_font := ""
var _variants := {}
var _reading_mark := MeshInstance3D.new()
## The page and paragraph (logical page pixels [left, top, right, bottom]) being read aloud.
var _reading := {}
var _request := 0
var _textures := {}
var _wanted := {}
## A leaf in the air: {direction, to, amount (0 right .. 1 left), target, commit, held}.
var _turn := {}
var _queued := 0
var _restore := ""
var _memory := {} # uri -> position, for this run when history may not record it
var _note := Label3D.new()
var _spot := MeshInstance3D.new()
var _connected: Object
var _home := Transform3D.IDENTITY
var _placed := false
## Where the reader carried the tome with the grip, in the frame of the last recentre, and the
## distance setting it was carried at; empty until carried, cleared by bringing the book here.
var _carried: Variant = null
var _carried_reach := 1.0
var _arrive := 1.0
var _sweep := LeafMotion.new()
var _held_since := 0
## Blank leaves in the air on the way to a distant page: {direction, phase, to, from}.
var _riffle := {}
var _reading_direction := 1
## The whole book's layout, arrived while a leaf was in the air: swapped in once it lands.
var _pending := []
## Bumped whenever the native side's page numbers change under the same session (a fuller layout swapped
## in): pages drawn or decoded for the old numbering are dropped.
var _generation := 0
## How far the last fuller layout moved the page numbers (new minus old), for the voice to follow.
var layout_shift := 0
## Set by the app while the reader is away (headset off) or another menu is up: automatic turning waits.
var held := false
var _unrecorded := ""
## Seconds spent reading the open book, across openings. A page left untouched for a long while stops
## counting (the reader has gone), unless the book is reading itself aloud or turning its own pages.
var reading_seconds := 0.0
var _seconds := {} # uri -> seconds, for this run when history may not record it
var _active_ms := 0
const IDLE_MS := 5 * 60 * 1000
var _note_until := 0
## When a book that could not be opened puts itself away again (msec), or 0.
var _failed_until := 0
## Whether the wand last pointed at the book (or just beside it); a trigger elsewhere calls the ring.
var pointing := false
const FAILED_SECONDS := 3.0
var _retried := false

## Whether readers are shown books at all. Released: Debug and Release both offer the reading mode.
static func offered() -> bool:
	return true

static func named(path: String, name: String = "") -> bool:
	var extension := name.get_extension().to_lower()
	if extension.is_empty(): extension = preload("res://scripts/media_uri.gd").filename(path).get_extension().to_lower()
	return extension in EXTENSIONS

func _init() -> void:
	add_child(model)
	bar.reader = self
	add_child(bar)
	wand.top_level = true
	add_child(wand)
	add_child(layers)
	add_child(fonts)
	fonts.changed.connect(_on_fonts_changed)
	# Where the wand touches the page: a faint point that never washes out the words under it.
	var spot := QuadMesh.new(); spot.size = Vector2.ONE * 0.09
	_spot.mesh = spot; _spot.material_override = Wand.glow_material(Color(1.0, 0.86, 0.6), 0.16, 12)
	_spot.top_level = true; _spot.visible = false
	add_child(_spot)
	_note.font_size = 30; _note.pixel_size = 0.0007; _note.modulate = Color(0.35, 0.33, 0.30); _note.no_depth_test = true; _note.render_priority = 12
	model.add_child(_note)
	var shape := QuadMesh.new()
	_reading_mark.mesh = shape
	var shader := Shader.new(); shader.code = READING_SHADER
	var material := ShaderMaterial.new(); material.shader = shader; material.render_priority = 12
	_reading_mark.material_override = material
	_reading_mark.visible = false
	model.add_child(_reading_mark)
	visible = false

func _ready() -> void:
	_layout()

func restore_settings(source: ConfigFile) -> void:
	settings = source
	font = clampi(int(source.get_value("book", "font", DEFAULT_FONT)), 0, COLUMNS.size() - 1)
	paper = posmod(int(source.get_value("book", "paper", 0)), PAPERS.size())
	day_paper = posmod(int(source.get_value("book", "paper_day", paper if not night() else 0)), PAPERS.size())
	night_paper = posmod(int(source.get_value("book", "paper_night", paper if night() else 3)), PAPERS.size())
	# One page at a time unless the reader asks for the spread: two pages are wider than the eyes sweep.
	# Saved under a new name: the earlier single-page default was rejected on the headset (2026-11-26).
	single = not bool(source.get_value("book", "spread", true))
	# Brightness had four steps before it had seven: 1.0, 0.86, 0.72 and 0.58.
	var older := [0, 1, 3, 4]
	light = clampi(int(source.get_value("book", "brightness", older[clampi(int(source.get_value("book", "light", 0)), 0, 3)])), 0, LIGHTS.size() - 1)
	warmth = clampi(int(source.get_value("book", "warmth", 0)), 0, WARMTHS.size() - 1)
	spacing = clampi(int(source.get_value("book", "spacing", DEFAULT_SPACING)), 0, SPACINGS.size() - 1)
	paragraph = clampi(int(source.get_value("book", "paragraph", DEFAULT_PARAGRAPH)), 0, PARAGRAPHS.size() - 1)
	measure = clampi(int(source.get_value("book", "measure", 0)), 0, MEASURES.size() - 1)
	for way in TURNS:
		turns[way] = bool(source.get_value("book", "turn_" + way, source.get_value("book", "swish", true) if way == "swish" else true))
	if not turns.values().has(true): turns.buttons = true
	auto_step = clampi(int(source.get_value("book", "auto", DEFAULT_AUTO)), 0, AUTO_SECONDS.size() - 1)
	narration.restore(source)
	font_choices = {}
	for lang in Fonts.LANGUAGES:
		var chosen := str(source.get_value("book", "font_" + lang, ""))
		if not chosen.is_empty(): font_choices[lang] = chosen
	size_step = clampi(int(source.get_value("book", "size", DEFAULT_SIZE)), 0, SIZES.size() - 1)
	reach_step = clampi(int(source.get_value("book", "reach", DEFAULT_REACH)), 0, REACHES.size() - 1)
	_layout()

func _store() -> void:
	if settings == null: return
	settings.set_value("book", "font", font); settings.set_value("book", "paper", paper); settings.set_value("book", "spread", not single)
	settings.set_value("book", "paper_day", day_paper); settings.set_value("book", "paper_night", night_paper)
	settings.set_value("book", "brightness", light); settings.set_value("book", "warmth", warmth)
	settings.set_value("book", "spacing", spacing); settings.set_value("book", "paragraph", paragraph); settings.set_value("book", "measure", measure)
	for way in TURNS: settings.set_value("book", "turn_" + way, turns[way])
	settings.set_value("book", "auto", auto_step)
	narration.store(settings)
	for lang in Fonts.LANGUAGES:
		if font_choices.has(lang): settings.set_value("book", "font_" + lang, font_choices[lang])
		elif settings.has_section_key("book", "font_" + lang): settings.erase_section_key("book", "font_" + lang)
	settings.set_value("book", "size", size_step); settings.set_value("book", "reach", reach_step)
	if save_settings.is_valid(): save_settings.call()

func _layout() -> void:
	var look: Dictionary = PAPERS[paper]
	model.paper = Color(str(look.paper)); model.cover = look.cover; model.single = single; model.light = tint()
	var scale: float = SCALE * float(SIZES[size_step])
	model.scale = Vector3.ONE * scale
	# One page at a time hangs straight ahead; the leaves already read lie off to the left.
	model.position = Vector3(-model.page_size.x * scale * 0.5 if single else 0.0, 0, 0)
	model.rebuild()
	_note.position = Vector3(model.page_size.x * 0.5, 0, 0.004)

## Brightness and warmth as one colour over the pages.
func tint(step: int = -1, warm: int = -1) -> Color:
	var bright: float = LIGHTS[light if step < 0 else step]
	var heat: float = WARMTHS[warmth if warm < 0 else warm]
	return Color(bright, bright * (1.0 - 0.08 * heat), bright * (1.0 - 0.3 * heat))

func night() -> bool: return bool(PAPERS[paper].get("night", false))

## The language the open book is written in, for its fonts: "zh", "zh_hant", "ja" or "en". Before
## the book has said, the language it turned out to be last time it was opened.
func variant() -> String:
	var known := str(info.get("variant", _variants.get(uri, "")))
	return known if known in Fonts.LANGUAGES else ""

func font_choice() -> String: return str(font_choices.get(variant(), ""))

## The chosen font's file once it is here, or "" for the system's.
func font_path() -> String:
	var id := font_choice()
	return fonts.path_of(id) if not id.is_empty() and fonts.installed(id) else ""

## Chooses the font for books in this one's language; one not yet here is fetched first and used
## once it has arrived whole.
func set_font_choice(id: String) -> void:
	var lang := variant()
	if lang.is_empty(): return
	if id.is_empty(): font_choices.erase(lang)
	else:
		font_choices[lang] = id
		if not fonts.installed(id): fonts.fetch(id)
	_store()
	if font_path() != _laid_font: _restyle()
	_refresh_bar()

func remove_font(id: String) -> void:
	fonts.remove(id)
	for lang in font_choices.keys():
		if font_choices[lang] == id: font_choices.erase(lang)
	_store()
	if font_path() != _laid_font: _restyle()
	_refresh_bar()

func _on_fonts_changed() -> void:
	if active and font_path() != _laid_font: _restyle()
	_refresh_bar()

func _refresh_bar() -> void:
	if bar.is_node_ready() and bar.visible: bar.refresh()

func _style() -> String:
	var look: Dictionary = PAPERS[paper]
	_laid_font = font_path()
	return JSON.stringify({"columns": COLUMNS[font], "paper": look.paper, "ink": look.ink, "faint": look.faint, "font": _laid_font,
		"spacing": SPACINGS[spacing], "paragraph": PARAGRAPHS[paragraph], "measure": MEASURES[measure],
		"remaining": I18n.t("%d pages left in chapter"), "at": _restore})

func open(path: String, name: String) -> bool:
	if not Methods.supports(platform, "book_open"): return false
	if active: _remember()
	_unrecorded = ""
	narration.stop()
	_release()
	_retried = false
	if _connected != platform:
		_connected = platform
		platform.connect("book_ready", _on_ready)
		platform.connect("book_page", _on_page)
		if platform.has_signal("book_found"): platform.connect("book_found", _on_found)
	uri = path; title = name; active = true; visible = true
	if bar: bar.forget() # The way back and the search belonged to the last book.
	marks = _load_marks()
	_restore = _saved()
	reading_seconds = _saved_seconds(); _active_ms = Time.get_ticks_msec()
	_begin()
	if not _placed: recenter()
	_arrive = 0.0
	_pose()
	changed.emit()
	return true

func _begin() -> void:
	info = {}; contents = []; count = 0; session = 0; _turn = {}; _queued = 0
	_textures.clear(); _wanted.clear()
	message = "Loading…"
	_pending = []
	_failed_until = 0
	_request = platform.book_open(uri, _style())
	if _request <= 0: _fail("Book could not be opened"); return
	_show()
	_refresh_bar()

func _on_ready(id: int, payload: String) -> void:
	if not active or id != _request: return
	if session == id and (not _turn.is_empty() or not _riffle.is_empty()):
		# The native side already numbers pages the new way: nothing drawn from now on fits the old numbers.
		_pending = [id, payload]; _generation += 1; _wanted.clear(); return
	var parsed: Variant = JSON.parse_string(payload)
	# The chapter on show came first and the rest failed: keep reading it and try the rest once more.
	if session == id and count > 0 and parsed is Dictionary and parsed.get("state") == "error":
		if not _retried: _retried = true; _restyle()
		else: _tell("The rest of the book could not be laid out")
		return
	if not parsed is Dictionary or parsed.get("state") != "ready":
		var code := str(parsed.get("error", "")) if parsed is Dictionary else ""
		_fail({"BOOK_PROTECTED": "DRM-protected books are not supported", "BOOK_CACHE_FULL": "Not enough storage",
			"PDF_PAGE_LIMIT": "This book is too long to open"}.get(code, "Book could not be opened")); return
	# The chapter being read comes first; the whole book follows and replaces it at the same words.
	var swapped := session == id and count > 0
	var was_first := first_page()
	var held_place := ""
	if swapped:
		var places: Array = info.get("at", [])
		if first_page() < places.size(): _restore = str(places[first_page()])
		# The page being read aloud stays in view even when the new numbering pairs the pages the other way.
		if narration.on and narration.cursor >= 0 and narration.cursor < places.size(): held_place = str(places[narration.cursor])
		_turn = {}; _queued = 0; _riffle = {}; model.turn(0.0)
		_textures.clear(); _wanted.clear(); _generation += 1
	info = parsed; session = id; count = int(parsed.get("pages", 0)); contents = parsed.get("contents", [])
	# Chapters keep their page breaks in every layout, so old and new numbers differ by one offset.
	layout_shift = _page_at(_restore) - was_first if swapped else 0
	_variants[uri] = variant()
	# Only now is the book's language known: lay it out again in the font chosen for it.
	if font_path() != _laid_font:
		message = ""; page = _spread(_page_at(_restore)); _restyle(); return
	message = ""
	page = _spread(_page_at(held_place if not held_place.is_empty() else _restore))
	_settle()

## Nothing of the book could be shown: say why, then put it away so the library comes back.
func _fail(words: String) -> void:
	message = words
	_failed_until = Time.get_ticks_msec() + int(FAILED_SECONDS * 1000.0)
	_show(); _refresh_bar()

## Whether the open book failed and is about to close; any button closes it at once.
func failed() -> bool:
	return active and _failed_until > 0

## Reading positions are "chapter/block/character" in the book's own text, so they survive any change
## of type size or page shape.
func _page_at(at: String) -> int:
	var wanted := at.split("/")
	var places: Array = info.get("at", [])
	if wanted.size() != 3: return 0
	var low := 0; var high := places.size() - 1; var result := 0
	while low <= high:
		var middle := (low + high) / 2
		var have: PackedStringArray = str(places[middle]).split("/")
		var order := 0
		for part in 3:
			order = signi(int(have[part]) - int(wanted[part]))
			if order != 0: break
		if order <= 0: result = middle; low = middle + 1
		else: high = middle - 1
	return result

func _spread(index: int) -> int:
	index = clampi(index, 0, maxi(count - 1, 0))
	return index if single else index + (index % 2)

func first_page() -> int:
	return clampi(page if single else maxi(page - 1, 0), 0, maxi(count - 1, 0))

func fraction() -> float:
	return float(first_page()) / maxf(count - 1, 1.0)

func status_text() -> String:
	if not message.is_empty(): return I18n.t(message)
	if count <= 0: return title
	var names: Array = info.get("chapters", [])
	var chapters: Array = info.get("chapter", [])
	var chapter := str(names[int(chapters[first_page()])]) if first_page() < chapters.size() and int(chapters[first_page()]) < names.size() else ""
	return "%s   %d / %d" % [chapter if not chapter.is_empty() else str(info.get("title", title)), first_page() + 1, count]

func chapter_name(index: int) -> String:
	var names: Array = info.get("chapters", [])
	var chapters: Array = info.get("chapter", [])
	var name := str(names[int(chapters[index])]) if index >= 0 and index < chapters.size() and int(chapters[index]) < names.size() else ""
	return name if not name.is_empty() else str(info.get("title", title))

## Chapter and page for the centre of the rune ring.
func status_lines() -> PackedStringArray:
	if not message.is_empty() or count <= 0: return PackedStringArray([status_text()])
	var names: Array = info.get("chapters", [])
	var chapters: Array = info.get("chapter", [])
	var chapter := str(names[int(chapters[first_page()])]) if first_page() < chapters.size() and int(chapters[first_page()]) < names.size() else ""
	return PackedStringArray([chapter if not chapter.is_empty() else str(info.get("title", title)), "%d / %s" % [first_page() + 1, "…" if partial() else str(count)]])

## Only the chapter being read is laid out yet; the rest of the book is still being paginated.
func partial() -> bool:
	return bool(info.get("partial", false))

## Where the rune ring appears: a little way along the wand, turned to face the reader.
func menu_pose() -> Variant:
	var head: Variant = head_provider.call() if head_provider.is_valid() else null
	if not head is Transform3D: return null
	var eye: Vector3 = head.origin
	var out: Vector3 = (wand.tip.global_position - wand.global_basis.z * 1.25 - eye) if wand.visible else -head.basis.z * 1.4
	out = out.normalized() * clampf(out.length(), 1.0, 1.8)
	# Reading one page at a time, the ring leans over the dimmed leaves on the left rather than the text.
	if single: out -= head.basis.x * 0.15
	var up: Vector3 = Vector3.UP if absf(out.normalized().dot(Vector3.UP)) < 0.95 else head.basis.y
	return Transform3D(Basis.looking_at(out.normalized(), up).scaled(Vector3.ONE * 0.85), eye + out)

func _last() -> int:
	return count - 1 if single else (count - 1) + ((count - 1) % 2)

func _step() -> int: return 1 if single else 2

## A short line on the page, gone after a few seconds.
## Only part of the book is laid out yet: say so where the reader tried to go beyond it.
func tell_partial() -> void:
	_tell("Laying out the rest of the book…")

func tell(words: String) -> void: _tell(words)

## Writes the reader's settings out, for changes made outside the setters here (the voice).
func save_reading() -> void: _store()

## Starts or stops reading aloud from the open page.
func set_reading_aloud(value: bool) -> void:
	if value == narration.on: return
	if value:
		auto = false
		narration.start()
	else:
		narration.stop()

## Marks the paragraph being read: [rect] is [left, top, right, bottom] in logical page pixels; an
## empty rect or a negative page clears it.
func show_reading(index: int, rect: Array) -> void:
	_reading = {"page": index, "rect": rect} if index >= 0 and rect.size() == 4 else {}
	_place_reading()

## The paragraph read aloud on [index], as a rectangle in page UV, or empty.
func _reading_rect(index: int) -> Rect2:
	if _reading.is_empty() or int(_reading.page) != index: return Rect2()
	var rect: Array = _reading.rect
	return Rect2(float(rect[0]) / 1200.0, float(rect[1]) / 1600.0, (float(rect[2]) - float(rect[0])) / 1200.0, (float(rect[3]) - float(rect[1])) / 1600.0)

## The mark in the 3D book, for when pages are not on layers (headsets without them).
func _place_reading() -> void:
	if layers.enabled or _reading.is_empty() or not _turn.is_empty() or not _riffle.is_empty() or count <= 0:
		_reading_mark.visible = false; return
	var index := int(_reading.page)
	var side := 0
	if index == page: side = 1
	elif not single and index == page - 1: side = -1
	if side == 0: _reading_mark.visible = false; return
	var rect: Array = _reading.rect
	var width: float = model.page_size.x
	var height: float = model.page_size.y
	# Logical pages are 1200 x 1600 from the top-left; the right page runs out from the spine at x = 0.
	var left := (0.0 if side > 0 else -width) + float(rect[0]) / 1200.0 * width
	var right := (0.0 if side > 0 else -width) + float(rect[2]) / 1200.0 * width
	var top := height * (0.5 - float(rect[1]) / 1600.0)
	var bottom := height * (0.5 - float(rect[3]) / 1600.0)
	var margin := width * 0.025
	var size := Vector2(right - left + margin * 2.0, top - bottom + margin)
	(_reading_mark.mesh as QuadMesh).size = size
	_reading_mark.position = Vector3((left + right) * 0.5, (top + bottom) * 0.5, 0.004)
	var material: ShaderMaterial = _reading_mark.material_override
	material.set_shader_parameter("size", size)
	material.set_shader_parameter("bar", width * 0.008)
	_reading_mark.visible = true

func _tell(words: String) -> void:
	_note.text = I18n.t(words); _note.visible = true
	_note_until = Time.get_ticks_msec() + 2500

func can_turn(direction: int) -> bool:
	var target := page + direction * _step()
	return count > 0 and target >= 0 and target <= _last()

## Turns one leaf. A second request while a leaf is in the air follows it immediately.
func turn(direction: int) -> bool:
	if not active or count <= 0 or direction == 0: return false
	if not _turn.is_empty():
		_queued = signi(direction); return true
	if partial() and not can_turn(signi(direction)):
		tell_partial(); return false
	return _lift(signi(direction), false)

func _lift(direction: int, held: bool) -> bool:
	if not can_turn(direction): return false
	# A leaf leaves the right side at 0 and lands on the left at 1; turning back runs the other way.
	_turn = {"direction": direction, "to": page + direction * _step(), "amount": 0.0 if direction > 0 else 1.0,
		"target": 1.0 if direction > 0 else 0.0, "commit": true, "held": held}
	_dress_turn()
	wand.cast(true)
	model.sound(randf_range(0.92, 1.12) * (1.25 if _queued != 0 else 1.0))
	felt.emit(0.12)
	_reading_direction = direction
	_auto_elapsed = 0.0
	return true

func go_to(index: int) -> void:
	if count <= 0: return
	_turn = {}; _queued = 0; _riffle = {}; model.turn(0.0); model.riffle(1.0, 1)
	page = _spread(index)
	_settle()

## Opens the book at a distant page: the leaves riffle over and the blocks of pages shift, then it settles.
func leap(index: int) -> void:
	if count <= 0: return
	var to := _spread(index)
	if absi(to - page) <= _step() * 2: go_to(to); return
	_turn = {}; _queued = 0; model.turn(0.0)
	_riffle = {"direction": signi(to - page), "phase": 0.0, "to": to, "from": fraction()}
	_reading_direction = int(_riffle.direction)
	if _reading_direction > 0: model.set_riffle(1, _texture(page), _texture(to - 1))
	else: model.set_riffle(-1, _texture(page - 1), _texture(to))
	model.sound(1.35, 2.0)
	felt.emit(0.2)
	# The pages it falls open at are fetched while the leaves are still in the air.
	if session > 0:
		for wanted in [to, to - 1, to + 1]:
			if wanted < 0 or wanted >= count or _textures.has(wanted) or _wanted.has(wanted): continue
			_wanted[wanted] = true
			platform.book_render(session, wanted, _edge())

func _edge() -> int:
	return PRINTED_EDGE if info.get("fixed", false) else EDGE

func _texture(index: int) -> Texture2D:
	return _textures.get(index) if index >= 0 and index < count else null

func _dress_turn() -> void:
	var step := _step()
	if int(_turn.direction) > 0:
		model.set_leaf(_texture(page), null if single else _texture(page + 1))
		model.set_pages(null if single else _texture(page - 1), _texture(page + step))
	else:
		model.set_leaf(_texture(page - step), null if single else _texture(page - step + 1))
		model.set_pages(null if single else _texture(page - step - 1), _texture(page))

## The page lying on [side] (1 right, -1 left) under a turning leaf, as [_dress_turn] lays it.
func _resting(side: int) -> int:
	var step := _step()
	if int(_turn.direction) > 0: return page + step if side > 0 else page - 1
	return page if side > 0 else page - step - 1

func _show() -> void:
	if _turn.is_empty(): model.set_pages(null if single else _texture(page - 1), _texture(page))
	else: _dress_turn()
	_show_marks()
	_note.text = I18n.t(message) if not message.is_empty() else ""
	_note.visible = not message.is_empty()

func _settle() -> void:
	_active_ms = Time.get_ticks_msec()
	model.progress = fraction()
	model.rebuild()
	_want_window()
	_show()
	_remember()
	_refresh_bar()
	changed.emit()

func _want_window() -> void:
	if session <= 0: return
	var step := _step()
	var keep := {}
	# The open pages first, then the leaf either way, then one more ahead.
	var ahead := step * _reading_direction
	for index in [page, page - 1, page + 1, page + ahead, page + ahead - 1, page + ahead + 1, page - ahead, page - ahead - 1,
			page + ahead * 2, page + ahead * 2 - 1]:
		if single and index != page and absi(index - page) > 3: continue
		if index < 0 or index >= count: continue
		keep[index] = true
		if _textures.has(index) or _wanted.has(index) or not _pending.is_empty(): continue
		_wanted[index] = true
		platform.book_render(session, index, _edge())
	for index in _textures.keys():
		if not keep.has(index): _textures.erase(index)

func _on_page(id: int, index: int, path: String) -> void:
	if id != session or not active or path.is_empty() or not _pending.is_empty():
		if not path.is_empty() and Methods.supports(platform, "book_discard"): platform.book_discard(path)
		if _pending.is_empty(): _wanted.erase(index)
		return
	WorkerThreadPool.add_task(_decode.bind(id, _generation, index, path))

func _decode(id: int, generation: int, index: int, path: String) -> void:
	var image := Image.load_from_file(path)
	if image != null and not image.is_empty(): image.generate_mipmaps()
	_decoded.call_deferred(id, generation, index, path, image)

func _decoded(id: int, generation: int, index: int, path: String, image: Image) -> void:
	if is_instance_valid(platform) and Methods.supports(platform, "book_discard"): platform.book_discard(path)
	if id != session or generation != _generation or not active: return
	_wanted.erase(index)
	if image == null or image.is_empty(): return
	_textures[index] = ImageTexture.create_from_image(image)
	_show()

func _process(delta: float) -> void:
	_sync_layers()
	if not active: return
	if _failed_until > 0 and Time.get_ticks_msec() > _failed_until:
		close_book(); return
	_count_reading(delta)
	if _note_until > 0 and Time.get_ticks_msec() > _note_until:
		_note_until = 0; _note.visible = not message.is_empty(); _note.text = I18n.t(message) if not message.is_empty() else ""
	if not _pending.is_empty() and _turn.is_empty() and _riffle.is_empty():
		var waiting := _pending; _pending = []
		_on_ready(int(waiting[0]), str(waiting[1]))
	if _arrive < 1.0:
		_arrive = minf(1.0, _arrive + delta / ARRIVE_SECONDS)
		_pose()
	if auto: _auto_tick(delta)
	narration.tick()
	_place_reading()
	if not _riffle.is_empty():
		_riffle.phase = minf(1.0, float(_riffle.phase) + delta / RIFFLE_SECONDS)
		var eased := smoothstep(0.0, 1.0, float(_riffle.phase))
		model.riffle(float(_riffle.phase), int(_riffle.direction))
		model.progress = lerpf(float(_riffle.from), float(_riffle.to) / maxf(count - 1, 1.0), eased)
		model.rebuild()
		if float(_riffle.phase) >= 1.0:
			var to := int(_riffle.to)
			go_to(to)
			model.sound(0.8, -2.0)
			_landed()
		return
	if _turn.is_empty() or _turn.held: return
	var target := float(_turn.target)
	LeafMotion.advance(_turn,delta,_queued != 0)
	model.turn(float(_turn.amount))
	if not is_equal_approx(float(_turn.amount), target): return
	var committed: bool = _turn.commit
	if committed: page = int(_turn.to)
	_turn = {}
	model.turn(0.0)
	wand.cast(false)
	_settle()
	if committed:
		model.sound(randf_range(0.7, 0.8), -6.0)
		_landed()
	if _queued != 0:
		var next := _queued; _queued = 0
		turn(next)

## The leaf has come down. The first page of a chapter greets the reader with a spray of light.
func _landed() -> void:
	felt.emit(0.08)
	var chapters: Array = info.get("chapter", [])
	var shown := first_page() if single else page
	for index in [shown - 1, shown]:
		if index > 0 and index < chapters.size() and int(chapters[index]) != int(chapters[index - 1]):
			model.flare(); felt.emit(0.25); return

## The tome sails in from the distance and swells to its place when a book is opened.
func _pose() -> void:
	var eased := 1.0 - pow(1.0 - _arrive, 3.0)
	global_transform = _home * Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * lerpf(0.12, 1.0, eased)),
		Vector3(0, lerpf(1.6, 0.0, eased), lerpf(-9.0, 0.0, eased)))

## The wand each frame: where it points, and whether its trigger is held. A swish across the book
## turns a leaf; holding the trigger on a page lifts that leaf and carries it with the wand.
func aim(origin: Variant, direction: Variant, pressed: bool, delta: float, free: bool = true, bare: bool = false) -> void:
	if not active or not origin is Vector3 or not direction is Vector3:
		pointing = false
		wand.visible = false; _spot.visible = false
		if not _turn.is_empty() and _turn.held: _drop()
		return
	wand.aim(origin, direction)
	# A bare hand points with its fingers; the wand's tip still gives where along the ray the page is met.
	if bare: wand.visible = false
	var from: Vector3 = wand.tip.global_position
	var hit: Dictionary = model.hit(from, direction)
	_spot.visible = not hit.is_empty() and _turn.is_empty()
	if not hit.is_empty(): _spot.global_transform = Transform3D(global_basis, hit.point + global_basis.z * 0.02)
	var across: Vector3 = global_basis.inverse() * direction
	var yaw := atan2(across.x, -across.z)
	var reach: Dictionary = model.hit(from,direction,1.35)
	pointing = not reach.is_empty()
	_sweep.track(yaw,model.to_local(reach.point).x/model.page_size.x if pointing else null,delta)
	if not _turn.is_empty() and _turn.held:
		if not pressed: _drop(); return
		if not hit.is_empty():
			var x: float = (model.to_local(hit.point)).x
			LeafMotion.carry(_turn,x/model.page_size.x,delta)
			model.turn(float(_turn.amount))
		return
	if not free:
		_spot.visible = false; _sweep.velocity = 0.0; return
	if turns.drag and pressed and _turn.is_empty() and _held_since == 0 and not hit.is_empty():
		_held_since = Time.get_ticks_msec()
		_lift(1 if int(hit.side) > 0 or single else -1, true)
		return
	if not pressed: _held_since = 0
	if turns.swish and _turn.is_empty() and not pressed and pointing:
		var direction_to_turn := _sweep.swish()
		if direction_to_turn: turn(direction_to_turn)

## Letting go: a leaf carried far enough, or simply tapped, finishes its turn; otherwise it falls back.
func _drop() -> void:
	if not LeafMotion.drop(_turn,Time.get_ticks_msec()-_held_since<260):
		model.sound(randf_range(1.0,1.1),-6.0)

func _saved() -> String:
	if _memory.has(uri): return str(_memory[uri])
	return str(catalog.lookup(uri).get("book_at", "")) if catalog and catalog.has_method("lookup") else ""

## The file was renamed: the open book and this run's reading place follow it.
func relocate(old_uri: String, new_uri: String) -> void:
	if _memory.has(old_uri): _memory[new_uri] = _memory[old_uri]; _memory.erase(old_uri)
	if _seconds.has(old_uri): _seconds[new_uri] = _seconds[old_uri]; _seconds.erase(old_uri)
	if uri == old_uri: uri = new_uri

## History was cleared while this book was open: it is not recorded again until it is opened again.
func forget_history(network_only: bool) -> void:
	for key in _memory.keys():
		if not network_only or not Privacy.is_local(str(key)): _memory.erase(key)
	for key in _seconds.keys():
		if not network_only or not Privacy.is_local(str(key)): _seconds.erase(key)
	if active and (not network_only or not Privacy.is_local(uri)): _unrecorded = uri

func _remember() -> void:
	if not _unrecorded.is_empty() and uri == _unrecorded: return
	var places: Array = info.get("at", [])
	if count <= 0 or first_page() >= places.size(): return
	var at := str(places[first_page()])
	_memory[uri] = at
	_seconds[uri] = int(reading_seconds)
	if catalog and catalog.has_method("set_book_position"):
		catalog.opened(uri, title, false, "book")
		catalog.set_book_position(uri, at)
		if catalog.has_method("set_book_seconds"): catalog.set_book_seconds(uri, int(reading_seconds))

func _saved_seconds() -> float:
	if _seconds.has(uri): return float(_seconds[uri])
	return float(catalog.lookup(uri).get("book_seconds", 0)) if catalog and catalog.has_method("lookup") else 0.0

## Counts reading time while the book is open, in view and being read.
func _count_reading(delta: float) -> void:
	if count <= 0 or failed() or held or _arrive < 1.0: return
	if narration.on or auto or Time.get_ticks_msec() - _active_ms < IDLE_MS: reading_seconds += delta

## Time spent reading this book, as "2h 5m" or "12m"; empty under a minute.
func reading_time() -> String:
	var minutes := int(reading_seconds) / 60
	if minutes <= 0: return ""
	return I18n.t("%dh %dm") % [minutes / 60, minutes % 60] if minutes >= 60 else I18n.t("%dm") % minutes

func set_font(value: int) -> void:
	value = clampi(value, 0, COLUMNS.size() - 1)
	if value == font: return
	font = value; _store(); _restyle()

func set_paper(value: int) -> void:
	paper = posmod(value, PAPERS.size())
	if night(): night_paper = paper
	else: day_paper = paper
	_store(); _layout(); _restyle()

## Turns one way of turning pages on or off; the last one left stays on, or the book could not be read.
func set_turn(way: String, value: bool) -> bool:
	if not turns.has(way): return false
	if not value and turns[way] and turns.values().count(true) <= 1:
		_tell("Keep at least one way to turn pages"); return false
	turns[way] = value; _store()
	return true

func set_light(value: int) -> void:
	light = clampi(value, 0, LIGHTS.size() - 1); _store(); _layout()

func set_warmth(value: int) -> void:
	warmth = clampi(value, 0, WARMTHS.size() - 1); _store(); _layout()

## Day and night each come back to the paper last chosen for them.
func set_night(value: bool) -> void:
	if value == night(): return
	set_paper(night_paper if value else day_paper)

func set_spacing(value: int) -> void:
	value = clampi(value, 0, SPACINGS.size() - 1)
	if value != spacing: spacing = value; _store(); _restyle()

func set_paragraph(value: int) -> void:
	value = clampi(value, 0, PARAGRAPHS.size() - 1)
	if value != paragraph: paragraph = value; _store(); _restyle()

func set_measure(value: int) -> void:
	value = clampi(value, 0, MEASURES.size() - 1)
	if value != measure: measure = value; _store(); _restyle()

func set_auto_step(value: int) -> void:
	auto_step = clampi(value, 0, AUTO_SECONDS.size() - 1); _auto_elapsed = 0.0; _store()

## Starts or stops the pages turning by themselves. Reading aloud turns them itself, so the two take turns.
func set_auto(value: bool) -> void:
	if value and count <= 0: return
	if value and narration.on: narration.stop()
	auto = value; _auto_elapsed = 0.0
	_tell(I18n.t("Pages turn every %d seconds") % auto_wait() if value else I18n.t("Auto page turn off"))

func auto_wait() -> int: return int(AUTO_SECONDS[auto_step]) * (1 if single else 2)

## Time passes only while the book lies open and still, with the controls put away.
func _auto_tick(delta: float) -> void:
	if narration.on or held: return
	if count <= 0 or bar.visible or not _turn.is_empty() or not _riffle.is_empty() or _arrive < 1.0: return
	_auto_elapsed += delta
	if _auto_elapsed < auto_wait(): return
	_auto_elapsed = 0.0
	if can_turn(1): turn(1)
	elif not partial(): auto = false; _tell("The end of the book")

func set_single(value: bool) -> void:
	if value == single: return
	var at := first_page()
	single = value; _store(); _layout()
	page = _spread(at)
	_turn = {}; _queued = 0; model.turn(0.0)
	_settle()

## New type settings paginate the book again; reading continues at the same words.
func _restyle() -> void:
	if not active: return
	var places: Array = info.get("at", [])
	if count > 0 and first_page() < places.size(): _restore = str(places[first_page()])
	if session > 0 and Methods.supports(platform, "book_close"): platform.book_close(session)
	model.turn(0.0)
	_begin()

## Hangs the tome where the reader is looking: upright for sitting, with the head for lying down.
func recenter() -> void:
	var head: Variant = head_provider.call() if head_provider.is_valid() else null
	if not head is Transform3D: return
	var forward: Vector3 = -head.basis.z
	var frame: Transform3D = head
	if absf(forward.y) < 0.64:
		forward.y = 0.0
		frame = Transform3D(Basis.looking_at(forward.normalized(), Vector3.UP), head.origin)
	# Its face leans down a little towards the reader below.
	_frame = frame
	_placed = true
	_carried = null
	_place()

## Whether the tome can be taken hold of: it has finished arriving and stands where it was placed.
func movable() -> bool:
	return active and visible and _placed and _arrive >= 1.0

## The grip let go of the tome where it now hangs: it stays there, and a later distance setting moves
## it nearer or further along the same line from the reader.
func keep_carried() -> void:
	if not movable(): return
	_carried = _frame.affine_inverse() * global_transform
	_carried_reach = REACHES[reach_step]
	_home = global_transform

## Where the tome hangs in the frame of the last recentre, at the reader's chosen distance; nearer,
## it also sits less far below the eyes so the gaze still meets it at the same angle.
func _place() -> void:
	var reach: float = REACHES[reach_step]
	if _carried is Transform3D:
		var held: Transform3D = _carried
		held.origin *= reach / _carried_reach
		_home = _frame * held
	else:
		_home = _frame * Transform3D(Basis(Vector3.RIGHT, deg_to_rad(LEAN)), Vector3(0, LIFT * reach, -DISTANCE * reach))
	_pose()

func set_size_step(value: int) -> void:
	size_step = clampi(value, 0, SIZES.size() - 1); _store(); _layout()

func set_reach_step(value: int) -> void:
	reach_step = clampi(value, 0, REACHES.size() - 1); _store()
	if _placed: _place()

func _release() -> void:
	if session > 0 and is_instance_valid(platform) and Methods.supports(platform, "book_close"): platform.book_close(session)
	session = 0; _request = 0; _textures.clear(); _wanted.clear(); _turn = {}; _queued = 0
	model.turn(0.0); model.set_pages(null, null)

func close_book() -> void:
	if not active: return
	_remember()
	_release()
	auto = false
	narration.stop()
	active = false; visible = false; bar.dismiss(); wand.visible = false; _spot.visible = false
	_failed_until = 0; pointing = false
	uri = ""; info = {}; contents = []; count = 0
	closed.emit()

## The open pages go to the compositor while nothing moves them; a riffling or arriving book is drawn
## whole in the eye buffer. While a leaf turns, only its side is: the page lying still on the other
## side stays sharp (it was the whole spread going soft for the turn that read as a blur).
func _sync_layers() -> void:
	if not layers.enabled: return
	var turning: bool = not _turn.is_empty()
	if not active or not visible or count <= 0 or (turning and model.leaf_side == 0) or not _riffle.is_empty() or _arrive < 1.0:
		layers.show_pages([], active and visible and count > 0); return
	var place: Transform3D = model.global_transform
	var scale: float = place.basis.get_scale().x
	var facing := Basis(place.basis.x.normalized(), place.basis.y.normalized(), place.basis.z.normalized())
	var size: Vector2 = model.page_size * scale
	var pages := []
	for side in ([1] if single else [1, -1]):
		# Each side keeps its own layer (an empty entry puts it aside), so a page does not repaint for moving slot.
		var index: int = _resting(side) if turning else (page if side > 0 else page - 1)
		var texture: Texture2D = null if turning and side == model.leaf_side else _texture(index)
		if texture == null: pages.append({}); continue
		# A hair in front of the paper, so the hole wins the depth test over the page it covers.
		var centre: Vector3 = place * Vector3(side * model.page_size.x * 0.5, 0, 0.0015)
		pages.append({"texture": texture, "transform": Transform3D(facing, centre), "size": size, "light": model.light,
			"mark": _reading_rect(index)})
	layers.show_pages(pages, true)

## The reading position a page starts at ("chapter/block/character"), or "" past the pages laid out.
func place_of(index: int) -> String:
	var places: Array = info.get("at", [])
	return str(places[index]) if index >= 0 and index < places.size() else ""

## Where a reading position falls now, or -1 while only part of the book is laid out and it lies beyond.
func locate(at: String) -> int:
	if count <= 0 or not MarkMemory.valid_at(at): return -1
	if partial():
		var chapters: Array = info.get("chapter", [])
		var wanted := int(at.split("/")[0])
		if chapters.is_empty() or wanted < int(chapters[0]) or wanted > int(chapters[chapters.size() - 1]): return -1
	return _page_at(at)

## The contents entry a page falls under (an EPUB file often holds several, or has no title of its own).
func section_name(index: int) -> String:
	if not is_same(_sections_for, contents):
		# Sorted by page once per layout: a long search list asks for every row.
		_sections_for = contents
		var rows := contents.filter(func(row): return int(row.get("page", -1)) >= 0)
		rows.sort_custom(func(a, b): return int(a.page) < int(b.page))
		_section_pages = PackedInt32Array(); _section_titles = PackedStringArray()
		for row in rows: _section_pages.append(int(row.page)); _section_titles.append(str(row.get("title", "")))
	var at := _section_pages.bsearch(index, false) - 1
	var name := _section_titles[at] if at >= 0 else ""
	return name if not name.is_empty() else chapter_name(index)

## The pages open now, left to right.
func open_pages() -> Array:
	if count <= 0: return []
	return [page] if single else [page - 1, page].filter(func(index): return index >= 0 and index < count)

## The bookmark on an open page, or -1.
func mark_here() -> int:
	var open := open_pages()
	for index in marks.size():
		if locate(str(marks[index].at)) in open: return index
	return -1

## Marks the page being read (the left of a spread), or takes the mark away if it has one.
func toggle_mark() -> void:
	if count <= 0: return
	var here := mark_here()
	if here >= 0:
		marks.remove_at(here); _store_marks(); _tell("Bookmark removed")
		model.sound(0.8, -10.0); felt.emit(0.1)
		return
	var places: Array = info.get("at", [])
	var shown := first_page()
	if shown >= places.size(): return
	var at := str(places[shown])
	var words := ""
	if Methods.supports(platform, "book_excerpt"): words = str(platform.book_excerpt(session, at))
	marks.append({"at": at, "chapter": section_name(shown).left(MarkMemory.TEXT_LIMIT), "text": words.left(MarkMemory.TEXT_LIMIT),
		"created": int(Time.get_unix_time_from_system())})
	marks.sort_custom(func(a, b): return _before(str(a.at), str(b.at)))
	if marks.size() > MarkMemory.MAX_MARKS: marks.resize(MarkMemory.MAX_MARKS)
	_store_marks(); _tell("Bookmark added")
	model.sound(1.4, -8.0); felt.emit(0.18)

## After the per-file settings were cleared: forget this run's copies and show what is stored.
func reload_marks() -> void:
	_session_marks.clear()
	marks = mark_memory.marks(uri)
	_show_marks(); _refresh_bar()

func remove_mark(index: int) -> void:
	if index < 0 or index >= marks.size(): return
	marks.remove_at(index); _store_marks()

static func _before(a: String, b: String) -> bool:
	var left := a.split("/"); var right := b.split("/")
	for part in 3:
		if int(left[part]) != int(right[part]): return int(left[part]) < int(right[part])
	return false

func _load_marks() -> Array:
	if _session_marks.has(uri): return _session_marks[uri].duplicate(true)
	return mark_memory.marks(uri)

func _store_marks() -> void:
	_session_marks[uri] = marks.duplicate(true)
	mark_memory.store(uri, marks)
	_show_marks(); _refresh_bar()

func _show_marks() -> void:
	var open := open_pages()
	var left := false; var right := false
	if _turn.is_empty() and _riffle.is_empty():
		for mark in marks:
			var at := locate(str(mark.at))
			if at < 0 or not (at in open): continue
			if at == page: right = true
			else: left = true
	model.set_marked(left, right)

## Searches the book's text; the hits arrive through [signal found] with the returned token, or 0.
func search(query: String) -> int:
	if session <= 0 or query.strip_edges().is_empty() or not Methods.supports(platform, "book_search"): return 0
	_search_token += 1
	return _search_token if platform.book_search(session, query.strip_edges(), _search_token) else 0

func _on_found(id: int, token: int, payload: String) -> void:
	if not active or id != session or token != _search_token: return
	var parsed: Variant = JSON.parse_string(payload)
	if parsed is Dictionary: found.emit(token, parsed)
