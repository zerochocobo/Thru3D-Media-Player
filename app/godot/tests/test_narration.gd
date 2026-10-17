extends SceneTree
const Main := preload("res://scripts/main.gd")
const Video := preload("res://scripts/mpv_video_display.gd")
const Menu := preload("res://scripts/player_menu.gd")
const I18n := preload("res://scripts/i18n.gd")
var checks := 0
var failures: Array[String] = []
class Host extends RefCounted:
	var calls: Array = []
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
func _initialize() -> void: call_deferred("_run")
func _run() -> void:
	if "--narration-hidden" in OS.get_cmdline_user_args(): Menu.NarrationSettings.FEATURE_ENABLED = false
	I18n.use("en")
	var host := Host.new(); var video := Video.new(); root.add_child(video);video.set_process(false);video.platform=host
	video.local_uri="file:///narration.mp4";video.media.begin(8);video.media.state="playing"
	video.media.playback={"details":{"subtitle_tracks":[{"id":1,"codec":"subrip","language":"zh-Hans","title":"Chinese"},{"id":2,"codec":"ass","language":"eng","title":"English"},{"id":3,"codec":"subrip","language":"und","title":"Unknown"},{"id":4,"codec":"hdmv_pgs_subtitle","language":"eng","title":"PGS"}]}}
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
	tap(menu,111)
	check(menu._audio_open and not menu.allows_playback_sticks(),"Audio panel blocks stick playback shortcuts")
	check(option(menu,"narration_enabled",true)>=0,"Audio panel offers independent narration toggle")
	tap(menu,option(menu,"narration_enabled",true))
	check(host.calls.back()[0]==8 and host.calls.back()[1].enabled and video.audio_track_id==-1,"Enabling narration preserves original audio track")
	check(video.narration.resolved_language()=="zh" and menu.text_snapshot().contains("Yuewen") and menu.text_snapshot().contains("Junhao"),"Known Chinese subtitles expose female and male presets")
	tap(menu,option(menu,"narration_voice","Junhao"))
	check(video.narration.zh_voice=="Junhao" and video.narration.en_voice=="Ava","Chinese male selection preserves English female default")
	video.narration.set_option("narration_source",2);menu.refresh()
	check(video.narration.resolved_language()=="en" and menu.text_snapshot().contains("Adam"),"Fixed English source works independently from displayed Chinese")
	tap(menu,option(menu,"narration_voice","Adam"))
	check(video.narration.en_voice=="Adam" and video.subtitles.requested_track==1,"English male selection does not switch displayed subtitles")
	video.narration.set_option("narration_source",3);menu.refresh()
	check(video.narration.resolved_language().is_empty() and menu.text_snapshot().contains("Choose language"),"Unknown metadata requires a language instead of English fallback")
	video.narration.set_option("narration_language","zh");menu.refresh()
	check(menu.text_snapshot().contains("Junhao"),"Manual language restores that language's saved voice")
	tap(menu,menu.AUDIO_MORE)
	check(menu.text_snapshot().contains("Narration sync") and menu.text_snapshot().contains("Reading speed"),"More exposes timing, speed and volume")
	var before := host.calls.size();video.narration.apply();check(host.calls.size()==before,"Unchanged configuration is not resent every frame")
	video.narration.set_option("narration_source",-1);video.narration.set_option("narration_language","en")
	check(video.narration.resolved_language()=="en","Manual language overrides displayed Chinese metadata")
	video.subtitles.select(3);video.narration.apply()
	check(video.narration.language=="auto" and video.narration.resolved_language().is_empty(),"Switching followed subtitle source clears the old manual language")
	video.subtitles.select(2);video.narration.apply();menu.refresh();menu.navigate_back();tap(menu,110)
	check(option(menu,"narration_current",false)>=0,"Subtitle panel exposes read-these-subtitles shortcut")
	tap(menu,option(menu,"narration_current",false))
	check(not video.narration.enabled and not host.calls.back()[1].enabled,"Subtitle and audio panel share one narration state")
	menu.navigate_back();tap(menu,111)
	video.narration.reset_source();check(video.narration.source==-1 and video.narration.language=="auto" and video.narration.zh_voice=="Junhao","New video resets source/language while preserving per-language voice")
	video.narration.reset_source(video.local_uri)
	video.narration.set_option("narration_enabled", true)
	video.narration.set_option("narration_source", 2); video.narration.set_option("narration_language", "en")
	video.narration.reset_source(video.local_uri)
	check(video.narration.source == 2 and video.narration.language == "en", "Internal reopen keeps the same video's fixed source and manual language")
	var sent := host.calls.size(); video.narration.apply()
	check(host.calls.size() == sent + 1 and host.calls.back()[1].language == "en", "Internal reopen resends configuration after track metadata is restored")
	var tracks: Array = JSON.parse_string(JSON.stringify(video.media.playback.details.subtitle_tracks))
	video.media.playback.details.subtitle_tracks = tracks; video.narration.apply()
	check(video.narration.language == "en", "Real JSON float track IDs preserve manual language")
	video.media.playback.details.subtitle_tracks = []; video.narration.apply()
	check(video.narration.language == "en", "Transient seek metadata preserves fixed-source language")
	video.media.playback.details.subtitle_tracks = tracks; video.narration.apply()
	check(video.narration.language == "en", "Seek metadata restoration does not clear manual language")
	video.narration.reset_source("file:///another.mp4")
	check(video.narration.source == -1 and video.narration.language == "auto", "Changing actual video resets the temporary narration selection")
	for lang in ["zh","zh_Hant","ja","en"]:
		I18n.use(lang);menu.refresh();check(not button(menu,menu.AUDIO_CLOSE).is_empty(),"Audio panel draws in "+lang)
	_finish(menu, video, main)

func _test_hidden(main: Node, video: Node, menu: Node, host: RefCounted) -> void:
	var previous := ConfigFile.new()
	previous.set_value("narration", "enabled", true)
	previous.set_value("narration", "zh_voice", "Junhao")
	video.narration.load_settings(previous)
	check(not video.narration.enabled and not video.narration.available(), "Previous enabled preference cannot activate the withheld feature")
	check(video.narration.zh_voice == "Junhao", "Withholding does not discard the saved voice preference")
	for key in ["narration_enabled", "narration_current", "narration_preview", "narration_retry"]:
		check(not video.narration.set_option(key, true), "Withheld setting rejected: " + key)
	video.narration.enabled = true
	video.narration.apply()
	check(host.calls.is_empty(), "Even a stale enabled state cannot call the Android narration runtime")
	var stale: Dictionary = main._menu_state()
	check(not stale.narration_available and not stale.narration_enabled, "Menu state suppresses saved or stale narration state")
	stale.merge({"narration_available": true, "narration_enabled": true, "narration_resolved_language": "zh", "narration_status": "model_missing"}, true)
	menu.state_provider = func(): return stale
	tap(menu, 111)
	menu._audio_more = true; menu.refresh()
	check(menu._audio_open and not menu.allows_playback_sticks(), "Original audio panel still isolates playback shortcuts")
	check(menu.NarrationSettings.rows(stale).is_empty(), "Withheld narration contributes no audio rows")
	check(menu.NarrationSettings.status_label("model_missing").is_empty(), "Withheld narration shows no model status")
	for target in [menu.AUDIO_PREVIEW, menu.AUDIO_RETRY, menu.AUDIO_MORE]:
		check(button(menu, target).is_empty(), "No preview, retry or narration details action remains")
	for lang in ["zh", "zh_Hant", "ja", "en"]:
		I18n.use(lang); menu.refresh()
		check(not menu.text_snapshot().contains(I18n.t("Subtitle narration")) and not menu.text_snapshot().contains("Yuewen"), "No narration controls in " + lang)
	menu.navigate_back(); tap(menu, 110)
	check(option(menu, "narration_current", true) < 0 and option(menu, "narration_current", false) < 0, "Subtitle panel has no narration shortcut")
	check(host.calls.is_empty(), "Menu navigation never starts narration")

func _finish(menu: Node, video: Node, main: Node) -> void:
	I18n.use("en");menu.free();video.free();main.free()
	print("Narration UI checks=%d failures=%d" % [checks,failures.size()])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)
