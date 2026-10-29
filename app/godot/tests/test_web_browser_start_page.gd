extends SceneTree
const Menu := preload("res://scripts/library_menu.gd")
const Fixture := preload("res://tests/test_web_browser_panel.gd")
const Sites := preload("res://scripts/web_video_sites.gd")
const I18n := preload("res://scripts/i18n.gd")
var checks := 0
var failures: Array[String] = []
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)
func _initialize() -> void: call_deferred("run")
func run() -> void:
	var channel: Variant = ProjectSettings.get_setting(Sites.Channel.KEY)
	var platform := Fixture.Platform.new()
	platform.browser.merge({"url": "about:blank", "tab_id": 1, "focused_window": 1, "windows": [{"id": 1, "tab_id": 1, "url": "about:blank"}, {"id": 2, "tab_id": 2, "url": "about:blank"}], "tab_list": [{"id": 1, "window": 1, "url": "about:blank"}, {"id": 2, "window": 2, "url": "about:blank"}]}, true)
	for id in 14: platform.library.bookmarks.append({"title": "Emby 收藏 " + str(id), "url": "http://192.168.31.185:8096/web/index.html#!/" + str(id)})
	var menu := Menu.new(); root.add_child(menu); menu.attach_platform(platform); menu.toggle()
	menu._activate(Menu.NAV_BASE + Menu.Section.WEB)
	var browser: RefCounted = menu.web_browser
	browser.open(); browser.tick()
	var home: RefCounted = browser.start_page
	for id in [1, 2]:
		var host: Node3D = browser.windows[id]
		check(home.active(id) and home.links[id].size() == 12, "Every blank window shows six featured sites and six saved bookmarks")
		check(not host._buttons.any(func(button): return button.target == browser.WEB), "Start page replaces the blank native hit surface")
		for button in host._buttons.filter(func(item): return item.target >= home.BASE + 10 and item.target < home.BASE + 22):
			check(host.page_rect().encloses(button.rect), "Start-page cards fit within their own window")
	browser.windows[2]._activate(home.BASE + 3)
	check(home.pages[2].bookmarks == 1 and home.pages[1].bookmarks == 0, "Bookmark pagination belongs to each window independently")
	browser.windows[2]._activate(home.BASE + 16)
	check(platform.browser.url == "http://192.168.31.185:8096/web/index.html#!/6" and browser.focused_window == 2, "A bookmark opens its exact LAN URL and route in the chosen new window")
	check(platform.browser.windows[0].url == "about:blank", "Choosing a bookmark does not navigate the peer window")
	ProjectSettings.set_setting(Sites.Channel.KEY, "pico_cn_store")
	for language in ["zh", "en", "ja"]:
		I18n.use(language); browser.refresh_windows()
		var allowed: Array = Sites.ordered_indexes(language).map(func(index): return Sites.FEATURED[index].url)
		for page in [0, 1]:
			home.pages[2].sites = page; browser.refresh_windows()
			for target in home.links[2]:
				if target < home.BASE + 16: check(home.links[2][target] in allowed, "China-channel start page cannot expose a foreign featured site in " + language)
	platform.browser.windows[1].url = "https://example.com/loaded"
	platform.browser.focused_window = 2; platform.browser.tab_id = 2
	browser.next_poll = 0; browser.tick()
	check(not home.active(2) and browser.windows[2]._buttons.any(func(button): return button.target == browser.WEB), "Navigating away restores the real webpage surface and input")
	var before: String = platform.browser.url
	browser.action(home.BASE + 16)
	check(platform.browser.url == before, "A stale start-page target cannot navigate an already-loaded page")
	ProjectSettings.set_setting(Sites.Channel.KEY, channel)
	menu.free(); platform.free(); await process_frame
	print("Browser start page: %d checks, %d failures" % [checks, failures.size()])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)
