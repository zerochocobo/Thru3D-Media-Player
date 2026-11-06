extends SceneTree
const Menu := preload("res://scripts/library_menu.gd")
const Fixture := preload("res://tests/test_web_browser_panel.gd")
var checks := 0
var failures: Array[String] = []
var keep_peers := false
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)
func _initialize() -> void: call_deferred("run")
func poll(browser: RefCounted) -> void:
	browser.next_poll = 0; browser.tick()
func run() -> void:
	var platform := Fixture.Platform.new()
	var menu := Menu.new(); root.add_child(menu); menu.attach_platform(platform); menu.toggle()
	menu._activate(Menu.NAV_BASE + Menu.Section.WEB)
	var browser: RefCounted = menu.web_browser
	platform.browser.merge({"url":"https://weibo.com/", "tab_id":11, "navigation":3, "focused_window":1,
		"weibo_beta_available":true,"pause_confirmed":true,"network_capture_available":false,"network_capture_enabled":false,
		"videos":[{"id":"1","selection":"chosen-card","weibo_ready":true,"playing":true,"time":26.0,"width":1280,"height":720}]},true)
	var chosen: Array = []
	menu.chosen.connect(func(uri, _title):
		chosen.append(uri)
		# Same second close used by main._on_library_chosen, after choose() already
		# called the real LibraryMenu.dismiss().
		if not keep_peers: browser.close(true)
		browser.playback_return.opening = false)
	browser.open(); poll(browser)
	browser._begin_handoff(false,true,"chosen-card")
	platform.browser.playing = false; platform.browser.videos[0].playing = false
	poll(browser)
	check(menu.web_video.pending > 0,"Beta starts resolution after the exact pause acknowledgement")
	platform.web_state={"id":menu.web_video.pending,"state":"ready","uri":"https://weibo.com/123456/POST1","title":"Card"}
	menu.web_video.next_poll=0;menu.web_video.tick();poll(browser)
	check(chosen.size()==1 and not menu.visible and not browser.opened,"Single-window Beta uses the real menu dismissal and native-open close")
	check(not platform.actions.has("hibernate"),"Neither close unloads the original timeline")
	check(browser.playback_return.get("retained",false),"Native return keeps its original leased document")
	var retained: Array = platform.browser_commands.filter(func(c): return c.action=="retain_page")
	check(retained.size()==1 and retained[0].hide and retained[0].pause_token>0 and retained[0].selection=="chosen-card",
		"One scoped retain command hides the page before native playback")
	check(not platform.browser_commands.any(func(c): return c.action=="resume_tab"),"The original pause lease survives player startup")
	var generic_resumes := platform.actions.count("resume")
	browser.restore_playback(false,47000)
	var last: Array = platform.browser_commands.slice(-3)
	check(last.map(func(c):return c.action)==["resume_retained_page","resume_tab","restore_weibo"],
		"Return rebinds the live page, releases the lease, then addresses its original card")
	check(platform.actions.count("resume")==generic_resumes,"Retained return cannot wake a replacement session through generic resume")
	check(last[1].was_playing==false and not last[2].play and last[2].position_ms==47000 and last[2].selection=="chosen-card",
		"Stop returns paused at native progress without resuming neighbouring videos")
	var context := {"tab":11,"window":1,"navigation":3,"origin":"https://weibo.com/","pause_token":9,
		"retained":true,"selection":"chosen-card","was_playing":true,"native_uri":"https://weibo.com/123456/POST1"}
	browser.playback_return=context.duplicate(true);browser.restore_playback(true,26000)
	check(platform.browser_commands.back().play and platform.browser_commands.back().selection=="chosen-card",
		"A failed native open restores only the previously playing source")
	browser.playback_return=context.duplicate(true);browser.playback_selected("file:///different.mp4")
	check(browser.playback_return.is_empty() and platform.browser_commands.back().action=="release_retained_page",
		"An unrelated native selection releases the old live-page pin and lease")
	keep_peers=true
	menu.visible=true;menu.section=Menu.Section.WEB
	var source := platform.browser.duplicate(true);source.id=1
	var peer := {"id":2,"tab_id":22,"navigation":1,"url":"https://example.com/notes","title":"Notes","playing":false,"videos":[]}
	platform.browser.windows=[source,peer]
	platform.browser.playing=true;platform.browser.videos[0].playing=true
	browser.open();poll(browser);browser._begin_handoff(false,true,"chosen-card")
	platform.browser.playing=false;platform.browser.videos[0].playing=false
	source.playing=false;source.pause_token=platform.browser.pause_token;source.pause_confirmed=true
	poll(browser)
	platform.web_state={"id":menu.web_video.pending,"state":"ready","uri":"https://weibo.com/123456/POST1","title":"Card"}
	menu.web_video.next_poll=0;menu.web_video.tick();poll(browser)
	retained=platform.browser_commands.filter(func(c): return c.action=="retain_page")
	check(chosen.size()==2 and menu.visible and browser.active() and not retained.back().hide,
		"Peer-window Beta pins its source without hiding other browsing")
	browser.playback_selected("file:///another.mp4");browser.close()
	check(platform.actions.back()=="hibernate","Ordinary browser close still follows its normal resource policy")
	menu.free();platform.free();await process_frame
	print("Web Beta retention: %d checks, %d failures" % [checks,failures.size()])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)
