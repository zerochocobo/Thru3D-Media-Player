extends SceneTree
const Menu := preload("res://scripts/library_menu.gd")
const Fixture := preload("res://tests/test_web_browser_panel.gd")
class Platform extends Fixture.Platform:
	func web_browser_command(value: String) -> void:
		super.web_browser_command(value)
		var command: Dictionary = JSON.parse_string(value)
		if command.action == "capture_video": browser.captured_fullscreen_request = command.request
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
	browser._begin_handoff(true,"chosen-card")
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
	menu.visible=true;menu.section=Menu.Section.WEB
	browser.playback_return=context.duplicate(true)
	browser.restore_playback(true,26000,{"message":"Decoder failed","error":"The video decoder could not be started.","source":"https",
		"failure":{"reason":"decoder_failed","stage":"decoding"}})
	check(platform.browser_commands.back().play and platform.browser_commands.back().selection=="chosen-card",
		"A failed native open restores only the previously playing source")
	# The page it returns to says what failed and can send that failure's log in one tap.
	var report: Dictionary = browser.handoff_error.get("report",{})
	check(browser.handoff_error.get("message")=="Decoder failed" and report.get("trigger")=="web_beta" and report.get("category")=="web"
		and report.get("site")=="weibo.com" and report.get("stage")=="native" and report.get("failure",{}).get("reason")=="decoder_failed"
		and not str(report).contains("chosen-card"),"A native failure is shown on the page with a report naming only the site")
	check(report.get("page")=="https://weibo.com/","The report carries the page it failed on")
	var youtube: Dictionary = browser.failure_page("https://user:pw@www.youtube.com/watch?v=QK2stBG5IYo&pp=sig%3D1&t=40&list=PL_x-1#comments")
	check(youtube=={"site":"www.youtube.com","page":"https://www.youtube.com/watch","page_params":{"v":"QK2stBG5IYo","list":"PL_x-1"}},
		"A page keeps only its public video keys, never sign-in parts, fragments or other query values")
	check(browser.failure_page("https://search.example.com/results?search_query=secret")=={"site":"search.example.com","page":"https://search.example.com/results"},
		"Search words are not sent")
	check(browser.failure_page("https://www.bilibili.com/video/BV1tkrWYoEaH?p=2&id=<x>")=={"site":"www.bilibili.com","page":"https://www.bilibili.com/video/BV1tkrWYoEaH","page_params":{"p":"2"}},
		"A key whose value is not a plain id is left out")
	for own in ["http://192.168.1.5:8096/web/index.html#!/details?id=1&api_key=k","https://media.example.com:8920/web/#/video?api_key=k",
			"http://nas.local/jellyfin/web/","http://myserver/plex","http://[fd00::1]:32400/web/"]:
		check(browser.failure_page(own)=={"site":"private"},"A user's own server is only private: " + own)
	poll(browser)
	var host: Node3D = browser.input_host()
	check(host._buttons.any(func(b): return b.target==browser.FAILURE_LOG and b.enabled),"The failed page offers its log beside the address")
	const BrowserWindow := preload("res://scripts/web_browser_window.gd")
	check(browser.FAILURE_LOG not in [BrowserWindow.MOVE,BrowserWindow.WEB,BrowserWindow.RESIZE,BrowserWindow.RESIZE_RIGHT,BrowserWindow.RESIZE_BOTTOM,BrowserWindow.SELECT],
		"A floating window's drag handles never take the send-log press")
	var quick: Array = []
	menu.setting_changed.connect(func(key,value): if key=="diagnostic_quick": quick.append(value))
	browser.action(browser.FAILURE_LOG)
	check(quick.size()==1 and quick[0].identity==browser.handoff_error.failure_id and quick[0].action=="upload" and quick[0].report==report,
		"One press asks the owner to upload this failure's log")
	menu.diagnostic_quick.merge({"identity":browser.handoff_error.failure_id,"code":"7F2K9QXM"},true)
	poll(browser); browser.action(browser.FAILURE_LOG)
	check(quick.size()==1 and str(browser.input_host()._tips.get(browser.FAILURE_LOG,"")).contains("7F2K9QXM"),"A sent log shows its code and is not sent again")
	menu.diagnostic_quick.clear()
	browser.playback_return=context.duplicate(true);browser.playback_selected("file:///different.mp4")
	check(browser.playback_return.is_empty() and platform.browser_commands.back().action=="release_retained_page",
		"An unrelated native selection releases the old live-page pin and lease")
	keep_peers=true
	menu.visible=true;menu.section=Menu.Section.WEB
	var source := platform.browser.duplicate(true);source.id=1
	var peer := {"id":2,"tab_id":22,"navigation":1,"url":"https://example.com/notes","title":"Notes","playing":false,"videos":[]}
	platform.browser.windows=[source,peer]
	platform.browser.playing=true;platform.browser.videos[0].playing=true
	browser.open();poll(browser);browser._begin_handoff(true,"chosen-card")
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
	await legacy_server_checks()
	print("Web Beta retention: %d checks, %d failures" % [checks,failures.size()])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)

func legacy_server_checks() -> void:
	var origins := ["http://server.test:8096/web/index.html#!/videoosd",
		"http://server.test:8096/jellyfin/web/#/video",
		"http://server.test:32400/web/index.html#!/server/local/details?key=%2Flibrary%2Fmetadata%2F4"]
	for index in origins.size():
		for outcome in ["return", "failure", "replace", "auto"]:
			var platform := Platform.new()
			var menu := Menu.new(); root.add_child(menu); menu.attach_platform(platform); menu.toggle()
			menu._activate(Menu.NAV_BASE + Menu.Section.WEB)
			var browser: RefCounted = menu.web_browser
			var origin: String = origins[index]
			var native_uri := origin.get_slice("#", 0) + ("#thru3d-plex=plex:4:1:0" if index == 2 else "#thru3d-video=21&MediaSourceId=version_2")
			platform.browser = {"url": origin, "tab_id": 11, "navigation": 3, "focused_window": 1,
				"active": true, "playing": true, "native_supported": true,
				"videos": [{"id": "1", "server_media": true, "playing": true, "time": 26.0}]}
			if outcome == "auto":
				platform.browser.merge({"fullscreen_video": true, "fullscreen_request": 1}, true)
				platform.browser.videos[0].merge({"server_play": true, "fullscreen": true}, true)
			var chosen: Array = []
			menu.chosen.connect(func(uri, _title):
				chosen.append(uri)
				browser.close(true) # main's second close after the real menu dismissal
				browser.playback_return.opening = false)
			browser.open(); poll(browser)
			if outcome == "auto":
				check(not browser.handoff and menu.web_video.pending == 0 and chosen.is_empty(),
					"Server playback/fullscreen leaves its website running until an explicit button")
			browser.action(browser.BASE + 6)
			check(not browser.handoff_beta and platform.beta_requests == 0 and menu.web_video.pending > 0,
				"Media-server button keeps the legacy resolver: %d %s" % [index, outcome])
			platform.web_state = {"id": menu.web_video.pending, "state": "ready", "uri": native_uri, "title": "Server movie"}
			menu.web_video.next_poll = 0; menu.web_video.tick(); poll(browser); poll(browser)
			check(chosen.is_empty() and platform.browser_commands.back().action == "pause_tab",
				"Media-server native playback waits for the source pause acknowledgement")
			platform.browser.playing = false; platform.browser.videos[0].playing = false
			poll(browser)
			check(chosen == [native_uri] and not menu.visible and not browser.opened and not platform.actions.has("hibernate"),
				"Both native-open closes preserve the media-server document")
			check(browser.playback_return.get("retained", false) and platform.browser_commands.back().action == "retain_page" and platform.browser_commands.back().hide,
				"Legacy media-server playback suspends and retains its original page")
			check(not platform.browser_commands.any(func(command): return command.action == "resume_tab"),
				"The server's pause lease survives native startup")
			var resumes := platform.actions.count("resume")
			if outcome == "replace":
				browser.playback_selected("file:///other.mp4")
				check(platform.browser_commands.back().action == "release_retained_page" and browser.playback_return.is_empty(),
					"Switching sources releases the media-server document and pause lease")
			else:
				browser.restore_playback(outcome == "failure", 67000)
				var commands: Array = platform.browser_commands.slice(-2)
				var actions := ["resume_retained_page", "resume_tab"]
				check(commands.map(func(command): return command.action) == actions and commands[0].origin == origin and commands[0].tab == 11 and commands[0].navigation == 3,
					"Legacy server return rebinds only the original live document")
				check(not commands[1].was_playing and commands[1].restore_paused == (outcome == "failure"),
					"Ordinary server return stays paused; native failure restores the pre-handoff state")
				check(platform.actions.count("resume") == resumes and browser.playback_return.is_empty(),
					"Server return consumes the context once without waking a replacement session")
			menu.free(); platform.free(); await process_frame
