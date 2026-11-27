extends RefCounted
## Reads the open book aloud from the page being read: paragraph after paragraph through the shared
## reading voice, turning the leaf when the voice reaches the next page. The pages give their own text;
## nothing is recognised from pixels. Any page the reader turns to by hand is where reading carries on.

const Methods := preload("res://scripts/platform_methods.gd")
const Narration := preload("res://scripts/narration_settings.gd")
## Reading speeds offered, as multiples of the voice's own pace.
const SPEEDS := [0.8, 0.9, 1.0, 1.15, 1.3, 1.5, 1.8]
const DEFAULT_SPEED := 2
const POLL_MS := 100
## Above every other epoch the shared reader is given: photo comics count up from 1.
const EPOCH_BASE := 1 << 40

var reader: Node3D
var on := false
var speed := DEFAULT_SPEED
## The voice per language the books are written in.
var voices := {}
## Logical page being read, and its blocks [{"id", "text", "hit_rect", ...}].
var cursor := -1
var blocks: Array = []
var index := 0
var _epoch := EPOCH_BASE
var _finished := -1
var _poll_at := 0
var _revision := -1
## What the shared voice last reported ("preparing", "speaking", "idle", "error"), for diagnosis.
var speech_state := ""
## The language read from the book's own words: an EPUB's declared language is often wrong.
var _language := ""
var _language_for := 0
## The reader's page after our own turn; any other change is the reader's and reading follows it.
var _expect := -1
var _configured := ""
var _waiting := false
## When the voice last went quiet while a paragraph was due: losing audio focus (a system sound,
## a screenshot) cancels the utterance without finishing it, and the paragraph is read again.
var _quiet_since := 0
const QUIET_RETRY_MS := 2000
var _session := 0
var _layout := 0

func _init(owner: Node3D) -> void:
	reader = owner

func supported() -> bool:
	var platform: Object = reader.platform
	return is_instance_valid(platform) and Methods.supports(platform, "book_reader_begin") and Methods.supports(platform, "book_text") \
		and Methods.supports(platform, "narration_supported") and platform.narration_supported() and not reader.info.get("fixed", false)

func restore(settings: ConfigFile) -> void:
	speed = clampi(int(settings.get_value("book", "speech_speed", DEFAULT_SPEED)), 0, SPEEDS.size() - 1)
	voices = {}
	for lang in Narration.VOICES:
		var saved := str(settings.get_value("book", "voice_" + lang, ""))
		if saved in Narration.VOICES[lang]: voices[lang] = saved

func store(settings: ConfigFile) -> void:
	settings.set_value("book", "speech_speed", speed)
	for lang in voices: settings.set_value("book", "voice_" + lang, voices[lang])

func language() -> String:
	if not _language.is_empty(): return _language
	var lang := str(reader.info.get("language", "zh"))
	return lang if Narration.VOICES.has(lang) else "zh"

## Kana make Japanese; Han characters without them Chinese; otherwise English.
static func detect(text: String) -> String:
	var han := 0; var kana := 0; var latin := 0
	for i in mini(text.length(), 600):
		var code := text.unicode_at(i)
		if (code >= 0x3040 and code <= 0x30FF): kana += 1
		elif code >= 0x4E00 and code <= 0x9FFF: han += 1
		elif (code >= 0x41 and code <= 0x5A) or (code >= 0x61 and code <= 0x7A): latin += 1
	if kana > 3: return "ja"
	if han * 3 > latin: return "zh"
	return "en" if latin > 0 else ""

func voice() -> String:
	var lang := language()
	return str(voices.get(lang, Narration.VOICES[lang][0]))

func set_voice(value: String) -> void:
	if not value in Narration.VOICES[language()]: return
	voices[language()] = value
	_restart_if_on()

func set_speed(value: int) -> void:
	speed = clampi(value, 0, SPEEDS.size() - 1)
	_restart_if_on()

func _restart_if_on() -> void:
	if on: _configured = ""; start(cursor)

func _configure() -> bool:
	var platform: Object = reader.platform
	var identity := "%s/%s/%s" % [voice(), language(), SPEEDS[speed]]
	if identity == _configured: return true
	if Methods.supports(platform, "comic_reader_speech_enabled"): platform.comic_reader_speech_enabled(true)
	if Methods.supports(platform, "comic_reader_speed"): platform.comic_reader_speed(float(SPEEDS[speed]))
	# The language comes from the words themselves; the pages carry the book's declared one.
	if not platform.comic_reader_configure(voice(), language()): return false
	_configured = identity
	return true

## Starts reading at [page] (the first open page by default).
## [paragraph] picks up partway down the page (the one being spoken when the pages were renumbered).
func start(page: int = -1, paragraph: int = 0) -> bool:
	if not supported() or reader.count <= 0 or reader.session <= 0:
		reader.tell("Read aloud is not available for this book"); return false
	stop(false)
	if _language_for != reader.session:
		# Sampled once per opened book, from the pages where reading begins.
		_language_for = reader.session
		var first: int = reader.first_page() if page < 0 else page
		var sample := ""
		for at in range(first, mini(first + 3, reader.count)):
			for row in _rows(at): sample += str(row.get("text", ""))
		_language = detect(sample)
	if not _configure():
		reader.tell("Read aloud is not available for this book"); return false
	_epoch += 1
	if not reader.platform.book_reader_begin(_epoch):
		reader.tell("Read aloud is not available for this book"); return false
	on = true; _session = reader.session; _layout = reader.count; _revision = -1
	# Utterances finish counting from here; the voice's count runs on across books.
	var status: Variant = JSON.parse_string(str(reader.platform.comic_reader_status(_epoch, -1)))
	_finished = int(status.get("finished", 0)) if status is Dictionary else 0
	_expect = reader.page
	_load(reader.first_page() if page < 0 else page, paragraph)
	return true

func stop(release: bool = true) -> void:
	var was := on
	on = false; cursor = -1; blocks = []; index = 0; _waiting = false
	reader.show_reading(-1, [])
	var platform: Object = reader.platform
	if was and is_instance_valid(platform) and Methods.supports(platform, "comic_reader_stop"): platform.comic_reader_stop()
	if release and was and is_instance_valid(platform) and Methods.supports(platform, "comic_reader_clear"): platform.comic_reader_clear()

func _rows(page: int) -> Array:
	if page < 0 or page >= reader.count: return []
	var parsed: Variant = JSON.parse_string(str(reader.platform.book_text(reader.session, page)))
	if not parsed is Dictionary: return []
	return (parsed.get("blocks", []) as Array).filter(func(row): return row is Dictionary and row.get("eligible", false))

## Hands the page being read and the one after it to the voice, then reads its first paragraph.
func _load(page: int, paragraph: int = 0) -> void:
	cursor = page
	blocks = _rows(page)
	index = clampi(paragraph, 0, maxi(blocks.size() - 1, 0))
	var platform: Object = reader.platform
	platform.book_reader_page(_epoch, 0, reader.session, page, false)
	if page + 1 < reader.count: platform.book_reader_page(_epoch, 1, reader.session, page + 1, false)
	_speak()

func _speak() -> void:
	if index >= blocks.size(): _next_page(); return
	var row: Dictionary = blocks[index]
	if not reader.platform.comic_reader_read(_epoch, 0, int(row.id), voice(), 1.0):
		stop(); reader.tell("Read aloud could not start"); return
	_waiting = true; _quiet_since = 0
	# The next utterance is synthesised while this one plays.
	if index + 1 < blocks.size(): reader.platform.book_reader_next(_epoch, 0, int(blocks[index + 1].id))
	elif cursor + 1 < reader.count:
		var ahead := _rows(cursor + 1)
		if not ahead.is_empty(): reader.platform.book_reader_next(_epoch, 1, int(ahead[0].id))
	reader.show_reading(cursor, row.get("hit_rect", []))

func _next_page() -> void:
	var next := cursor + 1
	if next >= reader.count:
		if reader.partial(): reader.tell_partial()
		else: reader.tell("The end of the book")
		stop(); return
	# The voice has reached a page that is not open: turn the leaf, and read on as it falls.
	if not next in reader.open_pages():
		if not reader.turn(1): stop(); return
		_expect = reader.page + reader._step() if reader._turn.is_empty() else int(reader._turn.get("to", reader.page))
	_load(next)

func tick() -> void:
	if not on: return
	if not reader.active or reader.session != _session: stop(); return
	# A fuller layout replaced the first chapter's: the same words have new page numbers. Read on from
	# the paragraph being spoken, now on its renumbered page. (Checked first: the renumbering moves the
	# open page too, which is not a turn by hand.)
	if reader.count != _layout:
		_layout = reader.count
		var at := index
		start(clampi(cursor + reader.layout_shift, 0, reader.count - 1), at)
		return
	# The reader turned or leapt by hand: read on from where they are now.
	if reader._turn.is_empty() and reader._riffle.is_empty() and reader.page != _expect:
		_expect = reader.page
		if not cursor in reader.open_pages(): start(); return
	var now := Time.get_ticks_msec()
	if now < _poll_at: return
	_poll_at = now + POLL_MS
	# Passing the revision already seen keeps the page blocks out of every poll.
	var status: Variant = JSON.parse_string(str(reader.platform.comic_reader_status(_epoch, _revision)))
	if not status is Dictionary: return
	_revision = int(status.get("revision", _revision))
	speech_state = str(status.get("speech", ""))
	var finished := int(status.get("finished", 0))
	if str(status.get("speech", "")) == "error":
		stop(); reader.tell("Read aloud could not start"); return
	if _waiting and finished > _finished:
		_finished = finished; _waiting = false
		index += 1
		_speak()
		return
	if _waiting and speech_state == "idle":
		if _quiet_since == 0: _quiet_since = now
		elif now - _quiet_since > QUIET_RETRY_MS: _finished = finished; _speak()
	else:
		_quiet_since = 0
