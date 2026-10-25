extends SceneTree
const Dwell := preload("res://scripts/photo_comic_dwell.gd")
const Reader := preload("res://scripts/photo_comic_reader.gd")
const Menu := preload("res://scripts/photo_menu.gd")
class FakePlatform extends RefCounted:
	var epoch := 0
	var submitted := []
	func narration_supported() -> bool: return true
	func comic_reader_configure(_voice: String, _language: String) -> bool: return true
	func comic_reader_begin(value: int) -> bool: epoch = value; return true
	func comic_reader_clear() -> void: epoch = 0
	func comic_reader_stop() -> void: pass
	func preload_photo(_uri: String) -> int: return 0
	func open_photo(_uri: String) -> int: return 1
	func activate_photo(_id: int) -> bool: return true
	func cancel_photo(_id: int) -> void: pass
	func release_photo(_id: int) -> void: pass
	func comic_reader_page(value: int, page: int, _width: int, _height: int, _rgb: PackedByteArray) -> bool:
		submitted.append([value, page]); return value == epoch
	func comic_reader_status(value: int, _revision: int) -> String:
		return JSON.stringify({"epoch": value, "revision": 1, "state": "recognizing"})
class FakePhoto extends Node3D:
	var platform := FakePlatform.new()
	var geometry := 0
	var stereo_sbs := false
	var panel := Node3D.new()
	var _flat := QuadMesh.new()
	var screen_curve := 0.0
	func _init() -> void: add_child(panel)
class AheadPlatform extends FakePlatform:
	var ahead := []
	func comic_reader_ahead(value: int, page: int, _width: int, _height: int, _rgb: PackedByteArray) -> bool:
		ahead.append([value, page]); return value == epoch
var checks := 0
var failures: Array[String] = []
func check(value: bool, message: String) -> void:
	checks += 1
	if not value: failures.append(message); push_error(message)
func click_field(menu: Node3D, key: String, kind: String, value: Variant = null) -> bool:
	for target in menu.choices.targets:
		var item: Dictionary = menu.choices.targets[target]
		if item.get("key") != key or item.get("kind") != kind or (kind == "choose" and item.get("value") != value): continue
		for button: Dictionary in menu._buttons:
			if button.target != target: continue
			var origin: Vector3 = button.node.global_position + Vector3(0, 0, 1)
			menu.press_pointer("right", origin, Vector3(0, 0, -1), true)
			menu.release_pointer("right", origin, Vector3(0, 0, -1), true)
			return true
	return false
func _initialize() -> void: call_deferred("run")
func run() -> void:
	var preferences := preload("res://scripts/comic_reading_settings.gd").new()
	var config := ConfigFile.new()
	config.set_value("narration", "enabled", true)
	config.set_value("narration", "voice_id", "Ava")
	config.set_value("narration", "volume", 68)
	config.set_value("narration", "duck", 43)
	config.set_value("narration", "language", "en")
	preferences.load_settings(config)
	check(not preferences.enabled and preferences.voice == "Ava" and preferences.volume == 68 and preferences.duck == 43 and preferences.language == "en", "Migrate applicable settings without enabling comic reading")
	preferences.set_option("comic_voice", "Xiaoyu"); preferences.save(config)
	config.set_value("narration", "voice_id", "Mia"); preferences.load_settings(config)
	check(preferences.voice == "Xiaoyu" and config.get_value("narration", "voice_id") == "Mia", "Comic and subtitle preferences remain independent")
	check(not preferences.set_option("comic_volume", NAN), "Reject invalid gain")
	check(not preferences.set_option("comic_language", "invalid"), "Reject unsupported language")
	var saved_id := "custom:12345678-1234-1234-1234-123456789abc"
	preferences.set_option("comic_voice_kind", "custom", [{"id": saved_id}])
	check(preferences.selected_voice() == saved_id, "Switching to cloned voices selects an available voice just like subtitles")
	config.set_value("comic_reading", "enabled", true)
	preferences.enabled = true; preferences.save(config)
	check(preferences.enabled and not config.has_section_key("comic_reading", "enabled"), "Saving global preferences removes legacy switch without disabling this batch")
	var reloaded := preload("res://scripts/comic_reading_settings.gd").new()
	config.set_value("comic_reading", "enabled", true) # Old installation upgrade.
	reloaded.load_settings(config)
	check(not reloaded.enabled and reloaded.selected_voice() == saved_id and reloaded.volume == 68 and reloaded.language == "en", "Restart ignores legacy activation and preserves cloned voice, gain and language globally")
	var dwell := Dwell.new()
	for t in range(0, 600, 50): check(not dwell.update("a", t), "No early trigger")
	check(dwell.update("a", 600), "600 ms fires")
	for t in range(650, 2000, 50): check(not dwell.update("a", t), "Staying does not repeat")
	dwell.update("", 2000); dwell.update("", 2100)
	check(not dwell.update("a", 2150), "Small jitter does not rearm")
	dwell.update("", 2200); dwell.update("", 2500)
	for t in range(2550, 3150, 50): check(not dwell.update("a", t), "Rearmed dwell starts afresh")
	check(dwell.update("a", 3150), "Exit for 300 ms rearms")
	check(not dwell.update("b", 3200) and dwell.switched, "Different bubble requests cancellation")
	dwell.reset(); dwell.update("a", 0)
	check(not dwell.update("a", 1500), "Frame stall cannot complete dwell")
	dwell.reset(); dwell.update("a", 0)
	for t in [100, 200, 300]: dwell.update("a", t)
	dwell.update("", 350); dwell.update("a", 450)
	check(not dwell.update("a", 550), "Tracking gap does not count toward dwell")
	check(not dwell.update("a", 650), "500 accumulated ms is not enough")
	check(dwell.update("a", 750), "Paused dwell resumes")
	var block := {"id": 3, "eligible": true, "hit_rect": [10, 10, 30, 30], "hit_rows": []}
	for y in 20: block.hit_rows.append([12, 28])
	var pages := [{"page": 1, "page_size": [100, 100], "blocks": [block]}]
	var rects := [Rect2(0, 0, 0.4, 1), Rect2(0.4, 0, 0.6, 1)]
	check(Reader.hit(pages, rects, Vector2(0.52, 0.2)).get("key") == "1:3", "Unequal-width spread maps to correct page")
	check(Reader.hit(pages, rects, Vector2(0.465, 0.2)).is_empty(), "Row shape rejects a bounding-box corner")
	check(Reader.hit(pages, rects, Vector2(0.2, 0.2)).is_empty(), "Other page never borrows a bubble")
	block.eligible = false
	check(Reader.hit(pages, rects, Vector2(0.52, 0.2)).is_empty(), "Uncertain text cannot be selected")
	block.eligible = true; pages[0].blocks.append(block.duplicate(true))
	check(Reader.hit(pages, rects, Vector2(0.52, 0.2)).is_empty(), "Overlapping candidates are skipped")
	var source := Image.create(400, 200, false, Image.FORMAT_RGBA8); source.fill(Color.RED)
	source.fill_rect(Rect2i(160, 0, 240, 200), Color.BLUE)
	var prepared := Reader.prepare({"image": source, "rects": rects, "epoch": 8})
	check(prepared.epoch == 8 and prepared.pages.size() == 2, "Preparation preserves page generation")
	check(prepared.pages[0].width == 160 and prepared.pages[1].width == 240, "Split uses actual physical page widths")
	check(prepared.pages[0].rgb[0] == 255 and prepared.pages[1].rgb[2] == 255, "RGB data and physical page order agree")
	var owner := FakePhoto.new(); var reader := Reader.new(owner); reader.enabled = true
	reader.accept({"image": source, "comic_rects": rects}); var old_epoch: int = reader.epoch
	reader.poll(0) # Starts the old page preparation off-thread.
	reader.accept({"image": source, "comic_rects": [Rect2(0, 0, 1, 1)]})
	for attempt in 100:
		await create_timer(0.005).timeout
		reader.poll(attempt * 10 + 1)
		if owner.platform.submitted.size() > 0: break
	check(owner.platform.submitted == [[reader.epoch, 0]] and reader.epoch > old_epoch, "Flip discards the old worker result and submits only the new page")
	var safe := block.duplicate(true); var unsafe := block.duplicate(true); unsafe.eligible = false
	reader.pages = [{"page":0,"page_size":[100,100],"blocks":[safe,unsafe]}]
	reader.draw_guides()
	check(reader.readable_count() == 1 and reader.candidate_count() == 2, "Coverage counts only admit safe bubbles")
	check(reader.guide.visible and reader.guide.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX].size() == 64, "Debug guides draw only the reliable bubble")
	var first_mesh: Mesh = reader.guide.mesh; reader.draw_guides()
	check(first_mesh == reader.guide.mesh, "Unchanged page reuses debug guide geometry")
	reader.dwell.update("a", 0); reader.clear()
	check(reader.pages.is_empty() and reader.dwell.target.is_empty() and owner.platform.epoch == 0, "Clear invalidates OCR and hover state together")
	check(not reader.guide.visible, "Flipping immediately hides old readable regions")
	reader.close(); owner.free()
	# Start turning, then return to the still-displayed image before decoding the
	# next page finishes. The old OCR was cleared when the turn began.
	var restored := preload("res://scripts/photo_display.gd").new()
	root.add_child(restored); restored.set_process(false)
	restored.platform = FakePlatform.new(); restored.auto_depth = false
	restored.queue = [{"uri":"fixture://first"}, {"uri":"fixture://second"}]
	restored.index = 0; restored.pending_index = 1; restored.loading = true
	restored._display_request = 1; restored._request = 2
	restored._texture = ImageTexture.create_from_image(source)
	restored._display_result = {"image":source, "comic_rects":rects}
	restored.comic.enabled = true; restored.comic.state = "idle"
	check(restored._select(0, -1) and not restored.loading, "Reversing an unfinished turn restores the displayed page")
	check(restored.comic.state == "recognizing" and restored.comic.pending.get("image") == source
		and restored.comic.rects == rects, "Restored page restarts OCR with its actual spread geometry")
	restored.comic.preferences.enabled = true; restored.comic.preferences.voice = "Ava"
	restored.comic.translation.enabled = true; restored.comic.translation.target = "en"
	restored.comic.clear()
	check(restored.comic.enabled and restored.comic.translation.enabled, "Page and layout clear retain both switches within a batch")
	var closed_epoch: int = restored.comic.epoch
	restored.close_image(false)
	check(not restored.comic.active() and not restored.comic.preferences.enabled and restored.comic.epoch > closed_epoch
		and restored.comic.pending.is_empty() and restored.comic.translation.state == "off", "Closing an album disables both features and invalidates pending work")
	check(restored.comic.preferences.voice == "Ava" and restored.comic.translation.target == "en", "Closing an album retains global voice and translation preferences")
	var fixture := ProjectSettings.globalize_path("res://../../build/output/comic-settings-test.png")
	DirAccess.make_dir_recursive_absolute(fixture.get_base_dir()); source.save_png(fixture)
	check(restored.open_image(fixture, "Settings test") and not restored.comic.active(), "Reopening an image starts both features off")
	restored.comic.enabled = true; restored.comic.translation.enabled = true
	check(restored.open_image(fixture, "Settings test") and not restored.comic.active(), "Replacing an open batch also requires explicitly enabling both features")
	restored.free()
	DirAccess.remove_absolute(fixture)
	var ahead_photo := preload("res://scripts/photo_display.gd").new()
	root.add_child(ahead_photo); ahead_photo.set_process(false)
	ahead_photo.platform = AheadPlatform.new(); ahead_photo.auto_depth = false
	ahead_photo.queue = [{"uri":"fixture://current"}, {"uri":"fixture://next"}]; ahead_photo.index = 0
	ahead_photo._prefetched[1] = {"id":2,"decoded":true,"stage":"done","result":{"image":source,"comic_rects":rects}}
	var ahead_reader = ahead_photo.comic
	ahead_reader.enabled = true; ahead_reader.state = "ready"
	ahead_reader.pages = [{"page":0,"page_size":[100,100],"blocks":[safe]}]
	ahead_reader.prefetch_next()
	check(ahead_reader.pending.is_empty(), "Current-page audio gets prepared before neighbour OCR")
	ahead_reader.ready_audio = 1; ahead_reader.prefetch_next()
	check(ahead_reader.pending.get("ahead", false) and ahead_reader.pending.rects == rects, "Next spread reuses decoded image and physical page rectangles")
	ahead_reader.pending = {}; ahead_reader.prefetch_next()
	check(ahead_reader.pending.is_empty(), "An unchanged neighbour is submitted only once")
	ahead_reader._ahead_key = ""; ahead_reader.ready_audio = 0
	ahead_reader._ready_at = 1000; ahead_reader.prefetch_next(2600)
	check(ahead_reader.pending.get("ahead", false), "Failed or long foreground audio cannot starve next-page OCR")
	ahead_reader.clear(); ahead_reader.state = "ready"; ahead_reader.prefetch_next(); ahead_reader.poll(0)
	ahead_reader.accept({"image":source})
	for attempt in 100:
		await create_timer(0.005).timeout
		ahead_reader.poll(attempt * 10 + 1)
		if ahead_photo.platform.submitted.size() > 0: break
	check(ahead_photo.platform.ahead.is_empty(), "A turn discards stale next-page pixel preparation")
	check(ahead_photo.platform.submitted == [[ahead_reader.epoch,0]], "Only the newly visible page can replace selectable text")
	ahead_photo.free()
	var menu := Menu.new(); var state := {"comic_supported": true, "comic_enabled": false, "has_image": true, "comic_voice_kind": "preset", "comic_voice": "Xiaoyu", "comic_personal_voices": []}
	menu.state_provider = func(): return state
	root.add_child(menu); menu.set_process(false); menu.visible = true; menu.refresh()
	var entry: Dictionary = menu._buttons.filter(func(button): return button.target == Menu.PHOTO_COMIC_VOICE)[0]
	check(menu._tips[Menu.PHOTO_COMIC_VOICE] == menu.I18n.t("Comic reading (Beta)"), "Comic reading entry identifies the beta")
	check(entry.rect.get_center().is_equal_approx(Vector2(0.5, -0.075)), "Comic entry occupies the bar status row instead of the music toolbar")
	for other: Dictionary in menu._buttons:
		if other.target == Menu.PHOTO_COMIC_VOICE: continue
		check(not entry.rect.intersects(other.rect), "Comic entry does not overlap neighboring controls")
	var emitted := []
	menu.setting_requested.connect(func(key, value): emitted.append([key, value]))
	menu.action_requested.connect(func(action): emitted.append(action))
	menu._activate(Menu.PHOTO_COMIC_VOICE)
	check(menu._adjustment == "comic_voice", "Voice picker opens")
	var fields: Array = menu.choices.targets.values()
	check(fields.any(func(field): return field.get("key") == "comic_voice"), "Shared preset choices are present")
	check(not fields.any(func(field): return field.get("key") == "comic_duck"), "Automatic music ducking does not occupy a comic settings row")
	check(click_field(menu, "comic_voice", "open") and menu.choices.opened == "comic_voice", "Preset dropdown remains open after a real pointer release and redraw")
	check(click_field(menu, "comic_voice", "choose", "Ava") and emitted.back()[0] == "comic_voice" and emitted.back()[1] == "Ava", "Pointer selection emits the chosen preset")
	check(click_field(menu, "comic_language", "open") and menu.choices.opened == "comic_language", "Language dropdown stays open")
	check(click_field(menu, "comic_language", "choose", "ja") and emitted.back() == ["comic_language", "ja"], "Pointer selects Japanese")
	menu.choices.reset(); menu.refresh()
	menu._activate(Menu.PHOTO_COMIC_PREVIEW)
	check(emitted.back() == "comic_preview", "Idle audition icon starts a preview")
	var menu_button: Node = menu._buttons[0].node
	menu.choices.capture = {"hand": "right"}; state.comic_volume = 42; state.comic_speech = "preparing"
	menu.refresh_values()
	check(is_instance_valid(menu_button) and menu._buttons[0].node == menu_button and not menu.choices.capture.is_empty(), "Progress and gain changes cannot destroy slider capture")
	menu.choices.capture = {}
	state.comic_voice_kind = "custom"; state.comic_personal_voices = [{"id": "custom:12345678-1234-1234-1234-123456789abc", "name": "Saved voice"}, {"id": "custom:22345678-1234-1234-1234-123456789abc", "name": "Second voice"}]
	menu.refresh(); fields = menu.choices.targets.values()
	check(fields.any(func(field): return field.get("key") == "comic_custom_voice"), "Saved cloned voice choices are present")
	check(click_field(menu, "comic_custom_voice", "open") and menu.choices.opened == "comic_custom_voice", "Cloned voice dropdown stays open")
	check(click_field(menu, "comic_custom_voice", "choose", state.comic_personal_voices[1].id) and emitted.back() == ["comic_custom_voice", state.comic_personal_voices[1].id], "Pointer selects a saved cloned voice")
	menu._activate(Menu.PHOTO_COMIC_PREVIEW)
	check(emitted.back() == "comic_stop" and menu._tips[Menu.PHOTO_COMIC_PREVIEW] == menu.I18n.t("Stop preview"), "Same audition icon stops a preparing preview")
	state.comic_speech = "idle"; menu.refresh_values()
	check(menu._tips[Menu.PHOTO_COMIC_PREVIEW] == menu.I18n.t("Preview voice"), "Completed preview restores the play icon")
	state.comic_enabled = true; state.comic_state = "ready"; state.comic_readable = 5; state.comic_ready_audio = 5; menu.refresh_values()
	check(menu._photo_status() == menu.I18n.t("Readable dialogues: %d") % 5, "Ready status exposes actual readable coverage")
	state.comic_state = "no_dialogue"; state.comic_candidates = 5; menu.refresh_values()
	check(menu._photo_status() == menu.I18n.t("Dialogue needs verification"), "Detected but rejected text is distinct from no text")
	menu._activate(Menu.PHOTO_ADJUST_BACK)
	check(menu._adjustment.is_empty(), "Voice picker returns to photo menu")
	menu.free()
	print("Comic reader: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
