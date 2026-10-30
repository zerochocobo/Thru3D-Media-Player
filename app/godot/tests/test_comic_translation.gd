extends SceneTree
const Protocol := preload("res://scripts/comic_translation_protocol.gd")
const Translator := preload("res://scripts/comic_translation.gd")
const Overlay := preload("res://scripts/comic_translation_overlay.gd")
const Menu := preload("res://scripts/photo_menu.gd")
class FakePhoto extends Node3D:
	var panel := MeshInstance3D.new()
	var material := ShaderMaterial.new()
	var _size := Vector2(800, 1000)
	var loading := false
	var _presentation_pending := false
	var inspect := false
	var geometry := 0
	var stereo_sbs := false
	var depth_requested := false
	var depth_strength := 1.0
	var portrait_requested := false
	var spatial_requested := false
	var gallery := {"mode": 0}
	var _transition_active := false
	var _reveal_seconds := 0.0
	func _init() -> void:
		material.shader = preload("res://shaders/photo.gdshader")
		panel.mesh = QuadMesh.new(); panel.material_override = material; add_child(panel)
class FakeTranslator extends Translator:
	var sent := []
	func _send(stage: String, url: String, headers: PackedStringArray, method: HTTPClient.Method, body: String = "") -> void:
		sent.append({"stage": stage, "url": url, "headers": headers, "method": method, "body": body})
class ModePlatform extends RefCounted:
	var speech := true
	var released := false
	var mode := ""
	var language := ""
	var rows := []
	var stops := 0
	var prepares := 0
	var reads := 0
	func narration_supported() -> bool: return true
	func comic_reader_begin(_epoch: int) -> bool: return true
	func comic_reader_configure(_voice: String, value: String) -> bool: language = value; return true
	func comic_reader_translation_mode(value: String, _language: String) -> bool: mode = value; rows.clear(); return true
	func comic_reader_translations(_epoch: int, value: String, json: String) -> bool:
		if value != mode: return false
		rows = JSON.parse_string(json); return true
	func comic_reader_speech_enabled(value: bool) -> void: speech = value
	func comic_reader_clear() -> void: pass
	func comic_reader_stop() -> void: stops += 1
	func comic_reader_prepare(_epoch: int, _page: int, _block: int) -> bool: prepares += 1; return true
	func comic_reader_read(_epoch: int, _page: int, _block: int, _voice: String, _volume: float) -> bool: reads += 1; return true
	func comic_reader_release() -> void: released = true
class HoverPhoto extends FakePhoto:
	var platform := ModePlatform.new()
	var _flat := QuadMesh.new()
	var screen_curve := 0.0
	func _inspect_uv(_origin: Vector3, _direction: Vector3) -> Vector2: return Vector2(.5,.4)
var checks := 0
var failures := []
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message); push_error(message)
func _initialize() -> void: run.call_deferred()
static func block(id: int, text: String, language: String = "ja") -> Dictionary:
	var rows := []
	for y in 120: rows.append([20, 180])
	return {"id":id, "text":text, "language":language, "eligible":true, "hit_rect":[20,20,180,140], "hit_rows":rows}
func response(value: Variant) -> PackedByteArray: return JSON.stringify(value).to_utf8_buffer()
func click(menu: Node3D, key: String, kind: String, value: Variant = null) -> bool:
	for id in menu.choices.targets:
		var item: Dictionary = menu.choices.targets[id]
		if item.get("key") != key or item.get("kind") != kind or (kind == "choose" and item.get("value") != value): continue
		for button: Dictionary in menu._buttons:
			if button.target != id: continue
			var origin: Vector3 = button.node.global_position + Vector3(0,0,1)
			menu.press_pointer("right", origin, Vector3(0,0,-1), true)
			menu.release_pointer("right", origin, Vector3(0,0,-1), true)
			return true
	return false
func run() -> void:
	check(Protocol.normalize("待って！\r\nまだ話は\n終わってない！", "ja") == "待って！まだ話は終わってない！", "Merge visual rows inside Japanese bubble")
	check(Protocol.normalize("Don't\nmove!", "en") == "Don't move!", "English word boundaries survive visual line breaks")
	check(Protocol.normalize("some-\nthing", "en") == "something", "Join English wrapped word")
	check(Protocol.language("zh") == "zh-Hans" and Protocol.language("ja") == "ja" and Protocol.language("unknown") == "auto", "OCR language normalization")
	check(Protocol.cache_key("x", "ja", "en") != Protocol.cache_key("x", "zh-Hans", "en"), "Language participates in cache identity")
	var valid := "⟦T3D0000⟧\n你好\n\n⟦T3D0001⟧\n等等\n\n⟦T3DEND⟧"
	check(Protocol.split_bing(valid, 2) == ["你好", "等等"], "Validated ordered batch aligns translations")
	for bad in [valid.replace("⟦T3D0001⟧", ""), valid.replace("⟦T3D0001⟧", "⟦T3D0000⟧"), valid.replace("⟦T3DEND⟧", ""), "extra" + valid, valid + "extra", valid.replace("等等", ""), valid.replace("等等", "⟦T3D9999⟧等等")]:
		check(Protocol.split_bing(bad, 2).is_empty(), "Malformed batch is never guessed or partially applied")
	check(Protocol.parse_edge([{"translations":[{"text":"你好", "to":"ja"}]}], 1, "zh-Hans").is_empty(), "Reject wrong target language")
	var many := []
	for i in 17: many.append({"source":"ja", "text":"a"})
	var batches := Protocol.batches(many)
	check(batches.size() == 3 and batches[0].size() == 8 and batches[2].size() == 1, "Batch size is bounded")
	var photo := FakePhoto.new(); root.add_child(photo)
	var client := FakeTranslator.new(photo); client.enabled = true; client.target = "zh-Hans"
	var settings := ConfigFile.new()
	settings.set_value("comic_translation", "enabled", true)
	client.source = "ja"; client.text_size = 1.2
	settings.set_value("comic_translation", "show_original", true)
	client.save(settings)
	check(client.enabled and not settings.has_section_key("comic_translation", "enabled"), "Saving translation preferences removes legacy activation without ending the batch")
	settings.set_value("comic_translation", "enabled", true)
	var restored := FakeTranslator.new(photo); restored.load_settings(settings)
	check(not restored.enabled and restored.target == "zh-Hans" and restored.source == "ja" and restored.text_size == 1.2, "Translation starts off but remaining preferences survive restart")
	check(not settings.has_section_key("comic_translation", "show_original") and not restored.option("translation_original",true), "Removed original-display preference is cleared and cannot hide translations")
	restored.close()
	client.source = "auto"; client.text_size = 1.0
	var a := block(0, "待って！\nまだ話は終わってない！")
	var b := block(1, "待って！まだ話は終わってない！")
	var c := block(2, "逃げるな！")
	var rejected := block(3, "uncertain"); rejected.eligible = false
	var pages := [{"page":0, "page_size":[200,200], "blocks":[a,b,c,rejected,block(4,"你好","zh")]}]
	var regions := [Rect2(0,0,1,1)]
	client.observe(pages, regions, 1)
	check(client.entries.size() == 3 and client.jobs.size() == 1 and client.jobs[0].size() == 2, "Deduplicate normalized text; exclude uncertain and same-language bubbles")
	check(client.speech_rows(pages, 1).size() == 1 and client.speech_rows(pages, 1)[0].id == 4, "Only same-language original is speakable while translations are pending")
	client._next_at = 0; Translator.WorkGate.next_at = 0; client.tick(true)
	check(client.sent.size() == 1 and client.sent[0].stage == "session", "Bing initializes only when an uncached batch is needed")
	var html := 'IG:"abc" data-iid="translator.1" params_AbusePreventionHelper=[1792900000123,"anonymous",3600000]'
	client._reply(HTTPRequest.RESULT_SUCCESS, 200, PackedStringArray(["Set-Cookie: session=anonymous; Path=/; Secure"]), html.to_utf8_buffer(), client.generation, "session")
	check(client.sent.back().stage == "bing" and "fromLang=ja" in client.sent.back().body, "OCR source is explicit in Bing request")
	check("key=1792900000123&" in client.sent.back().body, "Page nonce retains integer decimal form after Godot JSON parsing")
	check("T3D0001" in client.sent.back().body and "Cookie: session=anonymous" in client.sent.back().headers, "One marked request covers both unique bubbles with anonymous session")
	client._reply(HTTPRequest.RESULT_SUCCESS, 200, PackedStringArray(), response([{"translations":[{"text":valid,"to":"zh-Hans"}]}]), client.generation, "bing")
	check(client.cache.size() == 2 and client.translated_count() == 3 and client.provider == "Bing", "Deduplicated results fan out to each original bubble")
	check(client.speech_rows(pages, 1).size() == 4 and client.speech_rows(pages, 1)[0].text == "你好", "Speech receives translated text with exact bubble mapping")
	client.overlay.peek([Vector2(.5,.4)])
	check(client.speech_rows(pages, 1)[0].text == "你好", "Visual original peek does not revert spoken translation")
	check(client.speech_rows(pages, 2).is_empty(), "Stale page cannot supply translated speech")
	client.observe(pages, regions, 2)
	check(client.jobs.is_empty() and client.translated_count() == 3, "Revisiting a page reuses memory cache without a request")
	var generation: int = client.generation
	client.reset(); client._reply(HTTPRequest.RESULT_SUCCESS, 200, PackedStringArray(), response([]), generation, "bing")
	check(client.entries.is_empty() and client.current.is_empty(), "Late completion cannot repopulate a flipped page")
	client.cache.clear(); client.observe(pages, regions, 3); client._next_at = 0; Translator.WorkGate.next_at = 0; client.tick(true)
	client._reply(HTTPRequest.RESULT_SUCCESS, 429, PackedStringArray(["Retry-After: 600"]), PackedByteArray(), client.generation, "bing")
	check(client.sent.back().stage == "edge" and JSON.parse_string(client.sent.back().body).size() == 2, "Bing rate limiting falls back once to Edge array batching")
	check(not str(client.sent.back().headers).contains("Cookie") and not str(client.sent.back().headers).contains("Authorization"), "Edge never receives Bing credentials")
	check(int(client._cooldown.Bing) - Time.get_ticks_msec() > 590000, "Provider cooldown respects Retry-After")
	client._reply(HTTPRequest.RESULT_SUCCESS, 200, PackedStringArray(), response([{"translations":[{"text":"第一句","to":"zh-Hans"}]},{"translations":[{"text":"第二句","to":"zh-Hans"}]}]), client.generation, "edge")
	check(client.translated_count() == 3 and client.provider == "Edge", "Fallback preserves batch order and bubble identities")
	client.observe(pages, regions, 4); client.cache.clear(); client.retry(); client.observe(pages, regions, 4)
	client._next_at = 0; Translator.WorkGate.next_at = 0; client.tick(true)
	check(client.sent.back().stage == "edge", "New page does not hammer a cooling Bing endpoint")
	client._reply(HTTPRequest.RESULT_SUCCESS, 503, PackedStringArray(), PackedByteArray(), client.generation, "edge")
	check(client.state == "error" and client.cache.is_empty(), "Both-provider failure leaves original text untouched")
	check(client.speech_rows(pages, 4).size() == 1, "Translation failure never substitutes foreign original speech")
	var calls: int = client.sent.size()
	client._next_at = 0; Translator.WorkGate.next_at = 0; client.tick(true)
	check(client.sent.size() == calls, "Failure does not trigger an automatic retry loop")
	client.option("translation_enabled", false)
	check(client.cache.is_empty() and client._session.is_empty() and client._cookies.is_empty(), "Disabling clears text cache and anonymous session")
	var config := ConfigFile.new(); client.load_settings(config)
	check(not client.enabled, "Network translation is off by default")
	check(client.appearance == "light", "Translation defaults to black text on white")
	var target_codes := {}
	for choice: Dictionary in Protocol.target_choices():
		check(client.option("translation_target",choice.value),"Accept translated target " + str(choice.value))
		target_codes[client.speech_language()] = true
	check(target_codes.size() == 19 and Protocol.target_choices().size() == 20, "Translation covers all 19 narration languages with two Chinese scripts")
	for code in preload("res://scripts/narration_languages.gd").NAMES:
		check(target_codes.has(code), "Translation target matches narration language " + str(code))
	check(Protocol.normalize("Hallo\nWelt", "de") == "Hallo Welt" and Protocol.normalize("안녕\n친구", "ko") == "안녕 친구", "Non-CJK-joined target languages preserve spaces when reflowing")
	var appearance_generation: int = client.generation
	check(client.option("translation_appearance","dark") and client.generation == appearance_generation, "Changing appearance only redraws, without restarting translation")
	client.save(config); client.load_settings(config)
	check(client.appearance == "dark", "Translation appearance is remembered globally")
	check(not client.option("translation_target", "invalid"), "Reject unsupported target")
	var geometry := Overlay.layout({"block":a,"size":Vector2(200,200),"region":Rect2(.4,0,.6,1)},Vector2(1000,1000))
	check(geometry.rect == Rect2(457,95,486,610), "Unequal-width spread covers the full OCR rectangle including its ink boundary")
	var tail := a.duplicate(true)
	for i in 8: tail.hit_rows[i] = [98,102]
	check(not Overlay.layout({"block":tail,"size":Vector2(200,200),"region":Rect2(0,0,1,1)},Vector2(1000,1000)).is_empty(), "Thin white tail does not discard the readable bubble interior")
	var debug_block := block(7, "GO!", "en"); debug_block.verified = false; debug_block.hit_rows = []
	var debug_pages := [{"page":0, "page_size":[200,200], "blocks":[debug_block]}]
	check(not preload("res://scripts/photo_comic_reader.gd").hit(debug_pages, regions, Vector2(.5,.4)).is_empty(), "Debug candidates without verified balloon spans remain selectable")
	check(not Overlay.layout({"block":debug_block,"size":Vector2(200,200),"region":regions[0]},Vector2(1000,1000)).is_empty(), "Debug text rectangles support translation overlays")
	var ink := a.duplicate(true); ink.rect = [0,30,100,90]
	var ink_layout := Overlay.layout({"block":ink,"size":Vector2(200,200),"region":Rect2(.4,0,.6,1)},Vector2(1000,1000))
	check(ink_layout.rect == Rect2(400,145,303,310), "OCR ink rectangle takes precedence over balloon spans and is clipped to its physical page")
	var font := preload("res://scripts/ray_menu.gd").ui_font()
	for specimen in [["If we run away now,\nwe will never be able to face our friends again.", "en", Vector2(120,160)], ["WAIT!", "en", Vector2(600,300)], ["你为什么突然跑开了？我还有话要说！", "zh", Vector2(95,170)], ["ちょっと待って！まだ話は終わっていない！", "ja", Vector2(180,95)], ["A very long translated sentence. ".repeat(60), "en", Vector2(25,20)]]:
		var fit := Overlay.fit_text(specimen[0],font,specimen[2],specimen[1])
		var paragraph: TextParagraph = fit.paragraph
		check(fit.size.x <= specimen[2].x + .01 and fit.size.y <= specimen[2].y + .01, "Complete translated paragraph fits the requested rectangle")
		check(paragraph.get_line_range(paragraph.get_line_count()-1).y == fit.text.length(), "Wrapping retains the end of every translated sentence")
		check(not "\n" in fit.text, "Source/service visual line breaks are reflowed")
		if fit.font_size > 1:
			check(not Overlay.fits(Overlay.paragraph(fit.text,font,fit.font_size+1,specimen[2].x,specimen[1]),specimen[2]), "Automatic font size fills the available space")
	check(Overlay.fit_text("WAIT!",font,Vector2(600,300)).font_size > 48, "Short translations can grow beyond the previous fixed font cap")
	client.close(); photo.free()
	var real_photo := preload("res://scripts/photo_display.gd").new()
	root.add_child(real_photo); real_photo.set_process(false)
	var platform := ModePlatform.new(); real_photo.platform = platform
	var source_image := Image.create(200,200,false,Image.FORMAT_RGB8)
	real_photo._display_result = {"image":source_image}
	real_photo.depth_requested = true; real_photo.auto_depth = true
	var reader = real_photo.comic
	reader.translation.option("translation_enabled",true); reader.refresh_mode()
	check(reader.active() and not reader.enabled and not platform.speech and not reader.pending.is_empty(), "Translation alone starts shared OCR with speech preparation disabled")
	check(real_photo.depth_requested and real_photo.auto_depth, "Starting translation in 3D does not silently switch the picture back to 2D")
	reader.pending = {}; reader.pages = pages; reader.state = "ready"
	var ocr_epoch: int = reader.epoch
	reader.set_enabled(true)
	check(platform.speech and reader.epoch == ocr_epoch and not reader.pages.is_empty(), "Enabling speech reuses translation's OCR without restarting the page")
	reader.translation.observe(pages, regions, reader.epoch); reader.configure(); reader.sync_speech(100)
	check(platform.rows.size() == 1 and reader._speech_ready.has("0:4") and not reader._speech_ready.has("0:0"), "Only published translations arm dwell")
	reader.preferences.language = "ja"
	var stops: int = platform.stops
	reader.translation.option("translation_target", "en"); reader.configure()
	check(platform.stops > stops and reader._speech_ready.is_empty() and platform.language == "en", "Target switch stops old audio, clears readiness and overrides source TTS language")
	reader.translation.observe(pages, regions, reader.epoch)
	reader.translation.cache[Protocol.cache_key(Protocol.normalize(a.text, "ja"), "ja", "en")] = {"text":"Wait!","provider":"Bing"}
	reader.configure(); reader.sync_speech(200)
	check(platform.rows.size() == 2 and platform.rows[0].text == "Wait!", "Cached translation publishes once for each matching bubble")
	reader.translation.option("translation_target", "zh-Hant"); reader.configure()
	check(platform.language == "zh", "Traditional Chinese uses Chinese TTS")
	reader.translation.option("translation_enabled",false); reader.configure()
	check(platform.mode == "original" and platform.language == "ja" and reader.preferences.language == "ja", "Disabling translation restores saved original language")
	reader.translation.option("translation_enabled",true); reader.refresh_mode()
	reader.set_enabled(false)
	check(not platform.speech and reader.active() and reader.epoch == ocr_epoch, "Disabling speech preserves translation and page geometry")
	reader.translation.option("translation_enabled",false); reader.refresh_mode()
	check(not reader.active() and reader.pages.is_empty() and platform.released, "Disabling both features releases shared recognition state")
	real_photo.free()
	var hover := HoverPhoto.new(); root.add_child(hover)
	var hovered := preload("res://scripts/photo_comic_reader.gd").new(hover)
	hovered.translation.close(); hovered.translation = FakeTranslator.new(hover)
	hovered.enabled = true; hovered.epoch = 9; hovered.poll_at = Time.get_ticks_msec() + 60000
	hovered.pages = [{"page":0,"page_size":[200,200],"blocks":[a]}]
	hovered.translation.enabled = true; hovered.translation.observe(hovered.pages, regions, 9)
	var rays := [[Vector3.ZERO, Vector3.FORWARD]]
	hovered.tick(rays, true, "Xiaoyu", 1.0)
	check(hover.platform.reads == 0 and hover.platform.prepares == 0 and hovered.dwell.target.is_empty(), "Hover on pending translation cannot prepare or read original audio")
	hovered.translation.cache[Protocol.cache_key(Protocol.normalize(a.text, "ja"), "ja", "zh-Hans")] = {"text":"等等！","provider":"Bing"}
	hovered._speech_sync_at = 0; hovered.tick(rays, true, "Xiaoyu", 1.0)
	check(hover.platform.prepares == 1 and hover.platform.reads == 0 and hovered.dwell.target == "0:0", "Translation arriving under a held ray starts a fresh dwell")
	hovered.dwell.elapsed = 590; hovered.dwell.last = Time.get_ticks_msec() - 20
	hovered.tick(rays, true, "Xiaoyu", 1.0)
	check(hover.platform.reads == 1 and hover.platform.rows[0].text == "等等！", "Completed dwell reads the published translation exactly once")
	hovered.translation.option("translation_target", "en"); hovered.tick(rays, true, "Xiaoyu", 1.0)
	check(hover.platform.reads == 1 and hovered.dwell.target.is_empty(), "Target change under a held ray waits for new translation instead of replaying stale audio")
	hovered.translation.cache[hovered.translation.entries[0].key] = {"text":"Wait!","provider":"Bing"}
	hovered.translation.overlay.update(hovered.translation.entries,hovered.translation.cache,1.0)
	hovered.set_enabled(false); hovered.tick(rays,true,"Xiaoyu",1.0)
	check(hovered.translation.overlay.hovered.has("0:0") and hover.platform.reads == 1, "Translation-only hover reveals original without reading it")
	hovered.tick([],true,"Xiaoyu",1.0)
	check(hovered.translation.overlay.hovered.is_empty(), "Ray exit restores translated text")
	hovered.tick(rays,true,"Xiaoyu",1.0); hovered.tick(rays,false,"Xiaoyu",1.0)
	check(hovered.translation.overlay.hovered.is_empty(), "Menu/pointer blocking restores translated text")
	hovered.tick(rays,true,"Xiaoyu",1.0); hovered.set_enabled(true); hovered.tick(rays,true,"Xiaoyu",1.0)
	check(hovered.translation.overlay.hovered.is_empty(), "Enabling narration restores the translation under the held ray")
	check(hover.material.get_shader_parameter("comic_overlay_enabled") == true, "Translation draws inside the photo material")
	var sent_before: int = hovered.translation.sent.size()
	var cache_before: Dictionary = hovered.translation.cache.duplicate(true)
	hover.depth_requested = true; hovered.tick(rays,true,"Xiaoyu",1.0)
	check(hover.material.get_shader_parameter("comic_overlay_enabled") == true and hovered.translation.sent.size() == sent_before and hovered.translation.cache == cache_before, "2D to 3D keeps cached translation visible without another network request")
	var item: Dictionary = hovered.translation.overlay.canvas.items[0]
	check(item.mask.size.x > item.cover.size.x, "Stereo cover includes the displaced source ink from both eyes")
	hover.depth_requested = false; hovered.tick([],true,"Xiaoyu",1.0)
	check(item.mask == item.cover and hover.material.get_shader_parameter("comic_overlay_enabled") == true, "Returning to 2D restores normal coverage without toggling translation")
	hover._presentation_pending = true; hovered.tick(rays,true,"Xiaoyu",1.0)
	check(not hover.material.get_shader_parameter("comic_overlay_enabled") and hovered.blocked, "Pending final 3D hides translations and blocks dwell narration")
	hover._presentation_pending = false; hovered.tick([],true,"Xiaoyu",1.0)
	check(hover.material.get_shader_parameter("comic_overlay_enabled") and not hovered.blocked, "Presentation completion restores reading without clearing translations")
	hovered.close(); hover.free()
	var menu := Menu.new(); var ui := {"comic_supported":true,"has_image":true,"translation_enabled":true,"translation_target":"zh-Hans","translation_state":"translating","translation_count":1,"translation_total":3}
	menu.state_provider = func(): return ui
	root.add_child(menu); menu.set_process(false); menu.visible = true; menu.refresh()
	var button: Dictionary = menu._buttons.filter(func(item): return item.target == Menu.PHOTO_TRANSLATION)[0]
	check(menu._tips[Menu.PHOTO_TRANSLATION] == menu.I18n.t("Comic translation"), "Comic translation entry shows its name")
	for other: Dictionary in menu._buttons:
		if other.target != Menu.PHOTO_TRANSLATION: check(not button.rect.intersects(other.rect), "Translation button does not overlap existing controls")
	menu._activate(Menu.PHOTO_TRANSLATION)
	check(menu._adjustment == "comic_translation", "Adjacent translation entry opens panel")
	check(menu.choices.targets.values().any(func(field): return field.get("key") == "translation_target"), "Target language selection exists")
	check(not menu.choices.targets.values().any(func(field): return field.get("key") == "translation_original"), "Original-display switch is removed from translation settings")
	var emitted := []
	menu.setting_requested.connect(func(key,value): emitted.append([key,value]))
	check(click(menu, "translation_target", "open") and menu.choices.opened == "translation_target", "Target dropdown survives pointer release and redraw")
	check(click(menu, "translation_target", "choose", "en") and emitted.back() == ["translation_target","en"], "Controller ray chooses English target")
	check(click(menu,"translation_appearance","open") and click(menu,"translation_appearance","choose","dark") and emitted.back() == ["translation_appearance","dark"], "Controller ray switches translation appearance")
	check(click(menu,"translation_target","open"),"Reopen the expanded target list")
	menu.choices.offset = 14; menu.refresh()
	check(click(menu,"translation_target","choose","tr") and emitted.back() == ["translation_target","tr"],"Last narration language is reachable in the scrollable target list")
	var old_button: Node = menu._buttons[0].node
	ui.translation_count = 2; menu.refresh_values()
	check(is_instance_valid(old_button) and old_button == menu._buttons[0].node, "Network progress does not rebuild captured menu controls")
	menu._activate(Menu.PHOTO_ADJUST_BACK)
	check(menu._adjustment.is_empty(), "Translation settings return to reading controls")
	menu._activate(Menu.PHOTO_COMIC_VOICE)
	check(not menu.choices.targets.values().any(func(field): return field.get("key") == "comic_language"), "Translated speech panel follows target instead of exposing conflicting language picker")
	menu.free()
	print("Comic translation: %d checks, %d failures" % [checks,failures.size()])
	quit(0 if failures.is_empty() else 1)
