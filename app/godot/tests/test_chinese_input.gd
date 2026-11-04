extends SceneTree
const Chinese := preload("res://scripts/chinese_input.gd")
const Pinyin := preload("res://scripts/chinese_pinyin.gd")
const Editor := preload("res://scripts/system_text_input.gd")
const Menu := preload("res://scripts/library_menu.gd")
const I18n := preload("res://scripts/i18n.gd")
const Cloud := preload("res://tests/test_cloud_search.gd")
var checks := 0
var failures: Array[String] = []
var state := {"text": "", "submitted": [], "cancelled": []}

func _initialize() -> void: call_deferred("run")
func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok: failures.append(label)

func type_pinyin(ime: RefCounted, value: String) -> void:
	ime.clear()
	for letter in value: ime.type_letter(letter)

func candidate(ime: RefCounted, value: String) -> int:
	for index in ime.candidates.size():
		if ime.candidates[index].text == value: return index
	return -1

func click(target: int) -> void:
	var popup := Chinese.popup
	var buttons: Array = popup._buttons.filter(func(item): return item.target == target)
	check(not buttons.is_empty(), "Ray target exists: %d" % target)
	if buttons.is_empty(): return
	var point: Vector3 = buttons[0].node.global_position
	var direction: Vector3 = -popup.global_basis.z
	check(popup.press_pointer("right_hand", point - direction, direction, true), "Ray consumes key %d" % target)
	popup.release_pointer("right_hand", point - direction, direction, true)

func type_ray(value: String) -> void:
	for letter in value:
		for row in Chinese.Keyboard.LETTERS.size():
			var column: int = Chinese.Keyboard.LETTERS[row].find(letter)
			if column >= 0: click(Chinese.Keyboard.KEY + row * 10 + column); break

func begin(input: RefCounted, value: String = "", limit: int = 128) -> void:
	input.begin("cloud_search", value, limit, func(text): state.text = text,
		func(text): state.submitted.append(text), func(text): state.cancelled.append(text))

func run() -> void:
	var memory := OS.get_static_memory_usage()
	var started := Time.get_ticks_usec()
	Pinyin.begin_load()
	while Pinyin.keys.is_empty() and not Pinyin.failed:
		Pinyin.poll_lexicon(); await process_frame
	check(not Pinyin.failed and Pinyin.keys.size() > 38000, "Full offline index loads on worker")
	print("Chinese index load_ms=%s static_memory_bytes=%s" % [(Time.get_ticks_usec()-started)/1000.0, OS.get_static_memory_usage()-memory])
	var ime := Pinyin.new()
	for item in [["dianying", "电影"], ["dianshiju", "电视剧"], ["lvzhou", "绿洲"], ["chongqing", "重庆"], ["xiamen", "厦门"], ["nv'er", "女儿"], ["xi'an", "西安"], ["zimu", "字幕"]]:
		type_pinyin(ime, item[0]); check(candidate(ime, item[1]) >= 0, "Candidate: " + item[1])
	check(candidate(ime, "字幕") == 0, "Application vocabulary prioritizes subtitles")
	type_pinyin(ime, "xi'an"); check(candidate(ime, "先") == -1, "Explicit boundary prevents merged syllable")
	type_pinyin(ime, "xingjichuanyue")
	check(candidate(ime, "星级穿越") == -1, "No fabricated sentence candidate")
	check(ime.choose(candidate(ime, "星际")) == "星际" and ime.composing == "chuanyue", "Prefix selection retains unconsumed syllables")
	check(ime.choose(candidate(ime, "穿越")) == "穿越" and ime.composing.is_empty(), "Unlisted title can be entered word by word")
	type_pinyin(ime, "shi"); ime.page_by(1)
	check(ime.page_items().size() == 6 and ime.page == 1, "Homophone paging")
	var selected: String = ime.page_items()[0].text
	check(ime.choose(6) == selected, "Candidate page uses absolute index")
	type_pinyin(ime, "beijing"); ime.backspace(); check(ime.composing == "beijin", "Backspace edits only preedit")
	for quest in [false, true]:
		Chinese.quest = quest
		for language in ["zh", "zh_Hant", "en", "ja", "auto"]:
			I18n.use(language); Chinese.configure(false)
			check(Chinese.available() == (quest and I18n.language == "zh"), "Visibility follows platform and resolved language: " + language)
			check(not Chinese.enabled(), "Default/off never opens custom keyboard")
	Chinese.quest = true; I18n.use("zh"); Chinese.configure(true)
	var host := Node3D.new(); root.add_child(host); host.position.z = -1.5
	var input := Editor.new(host)
	begin(input)
	await process_frame
	check(Chinese.active() and input.custom and not input.editor.virtual_keyboard_enabled, "Chinese selection opens popup without system IME")
	type_ray("dianying")
	check(state.text == "" and state.submitted.is_empty(), "Preedit never submits or changes search")
	click(Chinese.Keyboard.CANDIDATE)
	check(state.text == "电影", "Actual candidate ray inserts Chinese into editor")
	input.editor.select(0, 1); input.editor.caret_column = 1
	type_ray("shi"); click(Chinese.Keyboard.CANDIDATE)
	check(state.text == "是影", "Candidate replaces original editor selection")
	click(12); click(4)
	check(state.text == "是影", "Backspace at beginning does not remove unrelated text")
	input.set_text("cloud_search", "电影🙂")
	click(4); check(state.text == "电影", "Backspace deletes one supplementary Unicode character")
	type_ray("zhong"); click(4)
	check(Chinese.popup.ime.composing == "zhon" and state.text == "电影", "Preedit delete preserves committed text")
	click(1)
	check(Chinese.popup.english and state.text == "电影zhon", "Switch to English preserves typed letters")
	type_ray("a"); click(2); type_ray("b"); click(3); click(Chinese.Keyboard.KEY + 10)
	check(state.text == "电影zhonaB@", "English shift and symbol layouts")
	click(6)
	check(state.submitted == ["电影zhonaB@"] and not input.active() and not Chinese.active(), "Submit once releases editor and popup")
	begin(input, "保留", 3); await process_frame
	type_ray("dianying"); click(Chinese.Keyboard.CANDIDATE)
	check(input.editor.text == "保留" and Chinese.popup.ime.composing == "dianying", "Length limit does not consume an uncommitted candidate")
	Chinese.popup.navigate_back(); check(Chinese.active() and Chinese.popup.ime.composing.is_empty(), "First Back clears composition")
	Chinese.popup.navigate_back(); check(state.cancelled.back() == "保留" and not Chinese.active(), "Second Back closes and preserves draft")
	begin(input, "draft"); await process_frame
	I18n.use("en"); Chinese.configure(Chinese.selected)
	check(not Chinese.active() and not input.active() and Chinese.selected, "Changing language closes input without losing saved opt-in")
	I18n.use("zh"); Chinese.configure(true)
	input.begin("archive_password", "", 20, Callable(), Callable()); await process_frame
	check(input.custom and not input.editor.virtual_keyboard_enabled and Chinese.popup.english, "Archive passwords use the optional keyboard, initially in English")
	input.cancel()
	for context in ["web_browser", "web_home", "web_video", "web_library_url"]:
		input.begin(context, "https://example.com", 4096, Callable(), Callable()); await process_frame
		check(not input.custom and input.editor.virtual_keyboard_enabled and not Chinese.active(), "Address input keeps the system keyboard: " + context)
		input.cancel()
	var platform := Cloud.Platform.new()
	var menu := Menu.new(); root.add_child(menu); menu.attach_platform(platform); menu.toggle()
	menu.section = Menu.Section.SETTINGS; menu.tab = Menu.GENERAL_TAB; menu.refresh()
	var language_index := -1
	var keyboard_index := -1
	for index in menu.rows.size():
		if menu.rows[index].get("key", "") == "language": language_index = index
		if menu.rows[index].get("key", "") == "quest_chinese_keyboard": keyboard_index = index
	check(language_index >= 0 and keyboard_index == language_index + 1, "Setting is directly below language")
	menu._activate(Menu.NAV_BASE + Menu.Section.CLOUD); platform.browse_reply(1)
	menu._choose(menu.rows[0]); platform.browse_reply(2); menu.cloud_search.open(); await process_frame
	var requests: int = platform.requests.size()
	type_ray("dianying"); click(6)
	check(platform.requests.size() == requests and menu.cloud_search.query == "电影", "Enter during composition only selects a word")
	click(6)
	check(platform.requests.size() == requests + 1 and platform.requests.back().query == "电影", "Second Enter performs real cloud search once")
	menu.queue_free(); platform.free(); host.queue_free()
	Chinese.configure(false); Chinese.close(); Chinese.popup.queue_free()
	await process_frame
	print("Chinese input checks=%d failures=%d" % [checks, failures.size()])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)
