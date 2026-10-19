extends SceneTree
const Main := preload("res://scripts/main.gd")
const Video := preload("res://scripts/mpv_video_display.gd")
const Menu := preload("res://scripts/player_menu.gd")
const I18n := preload("res://scripts/i18n.gd")
var checks := 0
var failures: Array[String] = []
class Host extends RefCounted:
	var calls: Array = []
	var serial := 100
	func mpv_supported() -> bool: return true
	func open_mpv_video(_uri: String, _start: int, _stereo: bool, _profile: String, _alpha: bool, _vulkan: bool, _depth: bool = false, _top: bool = false, _exact: bool = false) -> int:
		serial += 1; return serial
	func set_mpv_playing(_id: int, _playing: bool) -> void: pass
	func set_mpv_narration(id: int, json: String) -> bool: calls.append([id, JSON.parse_string(json)]); return true
	func close_mpv_video(_id: int) -> void: pass
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)
func button(menu: Node3D, target: int) -> Dictionary:
	for item in menu._buttons:
		if item.target == target: return item
	return {}
func tap(menu: Node3D, target: int) -> void:
	var origin: Vector3 = button(menu, target).node.to_global(Vector3(0, 0, 1))
	menu.press_pointer("left_hand", origin, -menu.global_basis.z, true)
	menu.release_pointer("left_hand", origin, -menu.global_basis.z, true)
func option(menu: Node3D, key: String, value: Variant) -> int:
	for target in menu.choices.targets:
		var item: Dictionary = menu.choices.targets[target]
		if item.kind == "choose" and item.key == key and item.value == value: return target
	return -1
func choose(menu: Node3D, key: String, value: Variant) -> bool:
	var opener := -1
	for target in menu.choices.targets:
		var item: Dictionary = menu.choices.targets[target]
		if item.kind == "open" and item.key == key: opener = target; break
	if opener < 0: return false
	tap(menu, opener)
	var target := option(menu, key, value)
	for index in menu.choices.popup.get("choices", []).size():
		if target >= 0: break
		var previous: int = menu.choices.offset
		menu.choices.offset += 1; menu.refresh()
		if menu.choices.offset == previous: break
		target = option(menu, key, value)
	if target < 0: return false
	tap(menu, target)
	return true
func _initialize() -> void: call_deferred("_run")
func _run() -> void:
	if "--narration-development" in OS.get_cmdline_user_args(): Menu.NarrationSettings.FEATURE_ENABLED = true
	if "--narration-hidden" in OS.get_cmdline_user_args(): Menu.NarrationSettings.FEATURE_ENABLED = false
	I18n.use("en")
	var host := Host.new(); var video := Video.new(); root.add_child(video);video.set_process(false);video.platform=host
	var narration_path := ProjectSettings.globalize_path("res://../../build/output/narration-integration/file-settings-%d" % Time.get_ticks_usec())
	video.narration.memory = video.NarrationSettings.Memory.new(narration_path)
	video.local_uri="file:///narration.mp4";video.media.begin(8);video.media.state="playing"
	video.media.playback={"details":{"subtitle_tracks":[{"id":1,"codec":"subrip","language":"zh-Hans","title":"Chinese"},{"id":2,"codec":"ass","language":"eng","title":"English"},{"id":3,"codec":"subrip","language":"und","title":"External","external":true,"source_file":"narration.srt"},{"id":4,"codec":"hdmv_pgs_subtitle","language":"eng","title":"PGS"}]}}
	var main := Main.new();main.video=video
	main.settings_path=ProjectSettings.globalize_path("res://../../build/output/narration-integration/ui-settings.cfg")
	var menu := Menu.new();main.player_menu=menu;menu.state_provider=main._menu_state;menu.setting_requested.connect(main._on_player_setting)
	root.add_child(menu);menu.toggle();menu.set_process(false)
	if not menu.NarrationSettings.FEATURE_ENABLED:
		_test_hidden(main, video, menu, host)
		_finish(menu, video, main)
		return
	check(not video.narration.enabled,"Narration starts off")
	video.subtitles.select(1)
	for locale in ["en", "zh", "zh_Hant", "ja"]:
		I18n.use(locale)
		video.narration.memory = video.NarrationSettings.Memory.new(narration_path + "-" + locale)
		video.narration.load_settings(ConfigFile.new())
		check(video.narration.selected_profile() == ("zh_female" if locale.begins_with("zh") else "ja_female" if locale == "ja" else "en_female"), "Locale female default: " + locale)
		var expected_language := "zh" if locale.begins_with("zh") else "ja" if locale == "ja" else "en"
		check(video.narration.language == expected_language, "Reading language has a concrete locale default: " + locale)
		var legacy := ConfigFile.new();legacy.set_value("narration","language","auto")
		video.narration.load_settings(legacy)
		check(video.narration.language == expected_language, "Legacy automatic default migrates: " + locale)
		video.narration.set_option("narration_language","auto");video.narration.save(legacy);video.narration.load_settings(legacy)
		check(video.narration.language == "auto", "Explicit follow selection survives reload: " + locale)
	check(video.NarrationSettings.default_profile("fr-FR")=="en_female", "Other UI locales default English female")
	video.narration.memory = video.NarrationSettings.Memory.new(narration_path)
	I18n.use("en");video.narration.load_settings(ConfigFile.new());video.subtitles.select(3)
	tap(menu,111)
	check(menu._audio_open and not menu.allows_playback_sticks(),"Audio panel isolates playback shortcuts")
	check(not menu.text_snapshot().contains("Subtitle narration") and not menu._audio_ids.is_empty(),"Audio panel has a direct list and no narration")
	menu.navigate_back();tap(menu,110)
	check(option(menu,"narration_enabled",true)>=0,"Only subtitle panel offers narration")
	tap(menu,option(menu,"narration_enabled",true))
	check(not menu.text_snapshot().contains("Voice sample") and button(menu,menu.NARRATION_PREVIEW).rect.size.x>0.06 and menu._tips[menu.NARRATION_PREVIEW]=="Preview voice","Voice audition is an icon with a hover hint, without a separate sample row")
	check(host.calls.back()[1].enabled and host.calls.back()[1].source == -1 and host.calls.back()[1].line == 0,"Narration follows displayed subtitles, default all lines")
	check(host.calls.back()[1].language=="en" and not video.narration.snapshot().narration_language_required and button(menu,menu.NARRATION_PREVIEW).enabled,"Untagged external subtitle starts with a usable default and voice preview")
	check(not video.narration.hide_subtitles and not video.narration.hides_display(),"Narration keeps visual subtitles visible by default")
	var line_row: Dictionary = video.NarrationSettings.rows(video.narration.snapshot()).filter(func(row): return row.field.key=="narration_line")[0]
	check(line_row.field.choices.map(func(choice):return choice.value)==[0,1,2],"Only All / First / Second authored line")
	check(video.narration.timing=="interrupt","Next subtitle interrupts unfinished speech")
	check(not video.NarrationSettings.rows(video.narration.snapshot()).any(func(row):return row.field.key=="narration_voice_origin"),"Voice native language is combined into the preset chooser")
	var voice_row: Dictionary = video.NarrationSettings.rows(video.narration.snapshot()).filter(func(row):return row.field.key=="narration_voice")[0]
	check(voice_row.field.choices.size()==12 and voice_row.field.value=="Ava" and voice_row.field.choices[0].label=="Native Chinese · Female 1" and voice_row.field.choices[5].label=="Native English · Female 1" and voice_row.field.choices[11].label=="Native Japanese · Neutral 1","One preset list shows native language, gender and number for all twelve voices")
	check(choose(menu,"narration_voice","Umiri") and video.narration.selected_origin()=="ja" and video.narration.selected_voice()=="Umiri" and video.narration.language=="en","Ray selects a different native language from the scrolled list without changing reading language")
	var preset_values: Dictionary = video.narration._values()
	check(not video.narration.set_option("narration_voice","invalid") and video.narration._values()==preset_values,"Invalid combined preset choice preserves the current voice and origin")
	var enable_targets: Array = menu.choices.targets.keys().filter(func(target):return menu.choices.targets[target].get("key","")=="narration_enabled")
	var enable_target: int = enable_targets[0]
	check(enable_targets.size()==1 and menu.choices.targets[enable_target].value==false and button(menu,enable_target).node.get_child_count()==2 and button(menu,enable_target).node.get_child(0).text.is_empty(),"Narration uses one slider-style toggle that offers the opposite state on release")
	var language_target: int = menu.choices.targets.keys().filter(func(target):return menu.choices.targets[target].get("key","")=="narration_language")[0]
	check(is_equal_approx(button(menu,enable_target).node.position.y,button(menu,language_target).node.position.y),"Narration toggle and target language share one row")
	check(button(menu,language_target).node is MeshInstance3D and button(menu,language_target).node.get_child(0).text.begins_with("Read: English"),"Target language is a visible button with an explicit reading label")
	check(["narration_duck","narration_volume"].all(func(key):return menu.choices.targets.values().any(func(item):return item.get("key","")==key)) and not menu.choices.targets.values().any(func(item):return item.get("key","") in ["narration_offset","narration_hide_subtitles"]),"Narration and original audio levels are directly visible; secondary controls stay hidden")
	check(video.narration.set_option("narration_hide_subtitles",true) and video.narration.hides_display(),"Optional hiding retains narration and selected track")
	video.narration.set_option("narration_hide_subtitles",false)
	video.subtitles.select(1);video.narration.apply();menu.refresh()
	check(video.narration.resolved_language()=="en" and host.calls.back()[1].language=="en","Concrete default starts narration without a language prompt or metadata override")
	var language_rows := video.NarrationSettings.rows(video.narration.snapshot())
	check(language_rows[1].field.key=="narration_language" and language_rows[1].field.choices.size()==20 and language_rows[1].field.choices.back().value=="auto","All nineteen pinned languages are offered with Follow subtitles last")
	var language_book := video.NarrationSettings.Memory.new(narration_path + "-languages")
	for code in video.NarrationSettings.Languages.NAMES:
		check(choose(menu,"narration_language",code) and video.narration.resolved_language()==code and host.calls.back()[1].language==code and video.narration.selected_voice()=="Umiri","Ray selects reading language independently of voice: " + code)
		check(language_book.remember("file:///languages/"+code+".mp4",video.narration._values()),"Per-video memory accepts language: " + code)
	check(language_book.save(),"Expanded language records save successfully")
	var language_reload := video.NarrationSettings.Memory.new(narration_path + "-languages"); language_reload.load_saved()
	for code in video.NarrationSettings.Languages.NAMES:
		check(language_reload.lookup("file:///languages/"+code+".mp4").get("language","")==code,"Per-video language survives reload: " + code)
	var current_values: Dictionary = video.narration._values()
	check(not video.narration.set_option("narration_language","vi") and video.narration._values()==current_values,"Unsupported language does not alter the current selection")
	for alias in video.NarrationSettings.Languages.ALIASES:
		check(video.NarrationSettings.Languages.canonical(alias)==video.NarrationSettings.Languages.ALIASES[alias],"Subtitle language alias: " + alias)
	video.media.playback.details.subtitle_tracks[0].language="fre-FR"
	check(choose(menu,"narration_language","auto") and video.narration.resolved_language()=="fr","Follow subtitles recognizes a regional ISO-639-2 language tag")
	video.media.playback.details.subtitle_tracks[0].language="und"
	check(video.narration.resolved_language().is_empty(),"Unknown subtitle language still requires an explicit selection")
	video.media.playback.details.subtitle_tracks[0].language="zh-Hans"
	menu.refresh()
	check(choose(menu,"narration_language","zh") and video.narration.resolved_language()=="zh" and host.calls.back()[1].language=="zh","Controller ray can open language chooser and select Chinese")
	for profile in video.NarrationSettings.PROFILES:
		check(video.narration.set_option("narration_profile",profile),"Accept profile " + profile)
		var voices := {"zh_female":"Xiaoyu","zh_male":"Zhiming","en_female":"Ava","en_male":"Adam","ja_female":"Mei","ja_male":"Umiri"}
		check(video.narration.snapshot().narration_voice == voices[profile],"Correct preset " + profile)
		check(host.calls.back()[1].language == "zh" and host.calls.back()[1].voice_override == voices[profile],"Voice origin does not override reading language " + profile)
	video.narration.set_option("narration_profile","ja_male")
	check(video.narration.set_option("narration_profile","default") and video.narration.snapshot().narration_profile=="default" and video.narration.resolved_language()=="zh","Default voice is selectable independently of reading language")
	video.narration.set_option("narration_profile","ja_male")
	video.subtitles.select(3);video.narration.apply()
	check(video.narration.resolved_language()=="zh" and video.narration.selected_voice()=="Umiri" and host.calls.back()[1].enabled,"Untagged external subtitles keep the selected reading language and voice")
	menu.refresh()
	check(button(menu,menu.NARRATION_PREVIEW).enabled,"Untagged external subtitles have an enabled voice sample")
	check(choose(menu,"narration_language","auto") and video.narration.resolved_language().is_empty(),"Optional Follow needs metadata on untagged external subtitles")
	check(choose(menu,"narration_language","ja") and host.calls.back()[1].language=="ja","Language chooser stays clickable while Follow has no subtitle language")
	video.subtitles.select(1);video.narration.apply()
	check(video.narration.resolved_language()=="ja" and host.calls.back()[1].language=="ja","Manual language wins over embedded metadata")
	menu.refresh()
	check(choose(menu,"narration_language","auto") and video.narration.resolved_language()=="zh" and host.calls.back()[1].language=="auto","Follow uses the embedded track language when explicitly chosen")
	video.subtitles.select(2);video.narration.apply()
	check(video.narration.resolved_language()=="en","Follow updates for a different embedded language")
	video.narration.set_option("narration_language","ja");video.narration.set_option("narration_source",1)
	check(video.narration.language=="ja" and host.calls.back()[1].language=="ja","Source changes retain the chosen reading language")
	video.narration.set_option("narration_source",-1)
	video.subtitles.select(3);video.narration.apply();video.narration.set_option("narration_language","zh")
	for origin in ["zh", "en", "ja"]:
		check(video.narration.set_option("narration_voice_origin",origin),"Choose native voice language " + origin)
		for voice in video.NarrationSettings.VOICES[origin]:
			check(video.narration.set_option("narration_voice",voice) and host.calls.back()[1].voice_override==voice,"Select preset " + voice)
			check(host.calls.back()[1].language=="zh","Cross-language voice keeps Chinese text language " + voice)
	check(video.NarrationSettings.VOICE_INFO.size()==12,"Twelve selected presets, Adam appears once")
	var obsolete := ConfigFile.new();video.narration.save(obsolete)
	obsolete.set_value("narration","rate",1.3);obsolete.set_value("narration","voice_rates",{"Umiri":1.8})
	video.narration.load_settings(obsolete)
	check(not host.calls.back()[1].has("rate") and not video.narration.snapshot().has("narration_rate"),"Obsolete manual speeds do not reach output or UI state")
	check(not video.narration.set_option("narration_rate",1.3),"Stale manual-speed actions are rejected")
	video.narration.save(obsolete)
	check(not obsolete.has_section_key("narration","rate") and not obsolete.has_section_key("narration","voice_rates"),"Saving removes obsolete speed preferences")
	video.narration.set_option("narration_profile","ja_male");video.narration.set_option("narration_language","ja")
	check(video.narration.set_option("narration_line",2) and host.calls.back()[1].line==2,"Second authored line reaches Android")
	check(not video.narration.set_option("narration_line",3) and not video.narration.set_option("narration_line",-1) and not video.narration.set_option("narration_line",1.5),"Invalid line selections rejected")
	menu.refresh();tap(menu,menu.NARRATION_MORE)
	check(not menu.text_snapshot().contains("Base reading speed") and not menu.text_snapshot().contains("Reading speed") and menu.text_snapshot().contains("Narration sync"),"Advanced narration controls stay in subtitles")
	check(not menu.text_snapshot().contains("Sentence timing") and not menu.text_snapshot().contains("Finish sentences") and menu.choices.targets.values().any(func(item):return item.get("key","")=="narration_hide_subtitles") and not menu.choices.targets.values().any(func(item):return item.get("key","")=="narration_duck"),"Advanced panel keeps secondary controls and omits the main ducking control and long timing note")
	tap(menu,menu.NARRATION_MORE)
	check(not button(menu,menu.NARRATION_PREVIEW).is_empty(),"Subtitle voice has preview")
	var before := host.calls.size();video.narration.apply();check(host.calls.size()==before,"Unchanged configuration is not resent each frame")
	var tracks: Array = video.media.playback.details.subtitle_tracks.duplicate(true)
	video.media.playback.details.subtitle_tracks = [];video.narration.apply()
	check(host.calls.size()==before and video.narration.available(),"Transient seek metadata does not disable narration")
	video.media.playback.details.subtitle_tracks = tracks
	for unsupported in [0,4]:
		video.subtitles.select(unsupported);video.narration.apply();menu.refresh()
		check(not video.narration.available() and not menu._narration_on(),"Off/PGS removes active narration icon")
		check(option(menu,"narration_enabled",true)<0 and button(menu,menu.NARRATION_PREVIEW).is_empty(),"Off/PGS hides switch and voice controls")
		check(not host.calls.back()[1].enabled,"Off/PGS sends runtime disable")
		check(not video.narration.set_option("narration_preview",true),"Off/PGS rejects stale preview actions")
	video.subtitles.select(3);video.narration.apply();menu.refresh()
	check(video.narration.available() and host.calls.back()[1].enabled,"Text subtitle restores remembered narration preference")
	var saved := ConfigFile.new();video.narration.save(saved)
	video.narration.profile="";video.narration.load_settings(saved)
	check(video.narration.selected_profile()=="ja_male" and video.narration.line==2,"Profile and line persist")
	video.narration.reset_source("file:///another.mp4")
	check(video.narration.source==-1 and not video.narration.enabled and video.narration.language=="en" and video.narration.line==0,"A different video starts off with its own default settings")
	video.narration.reset_source(video.local_uri)
	check(video.narration.enabled and video.narration.language=="ja" and video.narration.line==2,"Returning to the original video restores its narration settings")
	for stage in ["verifying", "model_loading", "preparing", "speaking", "model_error"]:
		video.media.playback.narration={"state":stage};menu.refresh()
		check(menu._narration_on(),"Narration glyph active " + stage)
		check(menu._narration_preparing()==(stage in ["verifying","model_loading","preparing"]),"Loading ring distinguishes working/error " + stage)
	tap(menu,option(menu,"narration_enabled",false))
	check(button(menu,menu.NARRATION_PREVIEW).is_empty() and not menu._narration_on(),"Off removes voice audition and restores the narration icon")
	check(menu.choices.targets.values().all(func(item): return not str(item.get("key", "")).begins_with("narration_") or item.key == "narration_enabled"),"Off leaves only the narration switch, including no reading language")
	var off_target: int = menu.choices.targets.keys().filter(func(target): return menu.choices.targets[target].get("key", "") == "narration_enabled")[0]
	check(is_equal_approx(button(menu,off_target).rect.size.x,0.09),"Off keeps the compact switch size after hiding language")
	for locale in ["zh","zh_Hant","ja","en"]:
		I18n.use(locale);menu.refresh();check(not button(menu,menu.SUBTITLE_CLOSE).is_empty(),"Subtitle panel draws " + locale)
	_test_per_video(main, video, host, narration_path + "-scope")
	_finish(menu, video, main)

func _text_track(video: Node) -> void:
	video.media.playback={"details":{"subtitle_tracks":[{"id":1,"codec":"subrip","language":"und","external":true,"source_file":"movie.srt"}]}}
	video.subtitles.select(1);video.narration.apply()

func _test_per_video(main: Node, video: Node, host: RefCounted, directory: String) -> void:
	const A := "file:///narration-scope/a.mp4"
	const B := "smb://narration-scope/share/b.mkv"
	video.close_video()
	video.narration.memory=video.NarrationSettings.Memory.new(directory)
	main.settings=ConfigFile.new();main.settings.set_value("narration","enabled",true)
	video.narration.load_settings(main.settings)
	check(not video.narration.enabled,"Legacy global On cannot automatically narrate another video")
	check(video.open_local(A,"A") and not video.narration.enabled,"New A starts with narration off")
	_text_track(video)
	for choice in [["enabled",true],["language","ja"],["voice_origin","ja"],["voice","Umiri"],["line",2],["hide_subtitles",true],["duck",45.0],["volume",80.0],["offset",0.4]]:
		main._on_player_setting("narration_"+choice[0],choice[1])
	var a: Dictionary=video.narration.memory.lookup(A)
	check(a.enabled and a.language=="ja" and a.voice_id=="Umiri" and a.line==2 and a.hide_subtitles and a.offset==0.4,"A stores its complete independent narration configuration")
	check(not main.settings.has_section_key("narration","enabled") and main.settings.get_value("narration","language")=="en","Saving A removes global On and does not replace defaults with A's language")
	check(video.open_local(B,"B") and not video.narration.enabled and video.narration.language=="en" and video.narration.line==0 and not video.narration.hide_subtitles and video.narration.offset==0,"Opening B does not inherit A's narration or adjustments")
	_text_track(video)
	check(host.calls.filter(func(call):return call[0]==video.media.session_id).all(func(call):return not call[1].enabled),"Native narration remains disabled for unconfigured B")
	main._on_player_setting("narration_offset",{"value":1.8,"source_uri":A})
	check(video.narration.offset==0 and video.narration.memory.lookup(B).is_empty(),"A delayed slider release from A cannot change or save B")
	main._on_playback_adjustment("narration_volume",{"value":5,"source_uri":A})
	check(video.narration.volume==100,"A delayed slider preview cannot change B's narration volume")
	check(video.narration.set_option("narration_duck",{"value":55.0,"source_uri":B}) and video.narration.duck==55,"The current video's scoped slider remains adjustable")
	main._on_player_setting("narration_enabled",true);main._on_player_setting("narration_language","zh")
	main._on_player_setting("narration_voice_origin","zh");main._on_player_setting("narration_voice","Junhao")
	main._on_player_setting("narration_enabled",false)
	check(video.open_local(A,"A") and video.narration.enabled and video.narration.language=="ja" and video.narration.selected_voice()=="Umiri" and video.narration.line==2 and video.narration.hide_subtitles and is_equal_approx(video.narration.offset,0.4),"Reopening A restores all A settings")
	_text_track(video)
	check(host.calls.back()[1].enabled and host.calls.back()[1].language=="ja" and host.calls.back()[1].voice_override=="Umiri","A restores the corresponding native narration configuration")
	video.close_video()
	check(not video.narration.enabled,"Closing playback clears the active narration On state")
	var memory=video.NarrationSettings.Memory.new(directory);memory.load_saved();video.narration.memory=memory
	video.narration.load_settings(main.settings)
	check(video.open_local(B,"B") and not video.narration.enabled and video.narration.language=="zh" and video.narration.selected_voice()=="Junhao","Explicit Off and B's chosen voice survive a store reload")
	check(video.open_local(A,"A") and video.narration.enabled and video.narration.selected_voice()=="Umiri","A's On and voice survive a store reload independently")
	check(not memory.remember("http://127.0.0.1:12345/session",a),"Temporary proxy URLs cannot become persisted video identities")
	var usb := "usb://session-a/movie.mkv"
	var stable := "usb://stable/"+"a".repeat(64)+"/movie.mkv"
	check(memory.register_usb_identity(usb,stable) and memory.remember(usb,a) and memory.save(),"USB narration saves against a stable file identity")
	var usb_reload=video.NarrationSettings.Memory.new(directory);usb_reload.load_saved()
	usb_reload.register_usb_identity("usb://session-b/movie.mkv",stable)
	check(usb_reload.lookup("usb://session-b/movie.mkv").get("voice_id")=="Umiri","USB narration survives a new connection URI")
	var renamed := "file:///narration-scope/a-renamed.mp4"
	check(memory.relocate(A,renamed) and memory.save() and memory.lookup(A).is_empty() and memory.lookup(renamed).enabled,"Renaming retains only the renamed video's narration")
	var text := FileAccess.get_file_as_string(directory.path_join("file_narration_0.json"))
	check(not text.contains(A) and not text.contains(B),"Narration records contain hashed file identities")
	check(memory.purge_keys(memory.entries.keys()) and memory.entries.is_empty(),"Privacy clearing can remove both narration banks")
	var cleared=video.NarrationSettings.Memory.new(directory);cleared.load_saved()
	check(cleared.entries.is_empty(),"Cleared narration cannot recover from the older bank")
	video.close_video()

func _test_hidden(main: Node, video: Node, menu: Node, host: RefCounted) -> void:
	var previous := ConfigFile.new();previous.set_value("narration", "enabled", true)
	video.narration.load_settings(previous)
	check(not video.narration.enabled and not video.narration.available(), "Saved state cannot enable ordinary builds")
	for key in ["narration_enabled", "narration_profile", "narration_preview", "narration_retry"]:
		check(not video.narration.set_option(key, true), "Withheld setting rejected " + key)
	video.narration.enabled=true;video.narration.apply()
	check(host.calls.is_empty(), "Withheld runtime never called")
	var stale: Dictionary = main._menu_state();stale.merge({"narration_available":true,"narration_enabled":true},true)
	menu.state_provider=func():return stale
	for target in [111,110]:
		tap(menu,target)
		check(not menu.text_snapshot().contains("Subtitle narration") and button(menu,menu.NARRATION_PREVIEW).is_empty(),"Withheld menus have no narration")
		menu.navigate_back()

func _finish(menu: Node, video: Node, main: Node) -> void:
	I18n.use("en");menu.free();video.free();main.free()
	print("Narration UI checks=%d failures=%d" % [checks,failures.size()])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)
