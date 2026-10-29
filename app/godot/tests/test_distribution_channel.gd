extends SceneTree
const Channel := preload("res://scripts/distribution_channel.gd")
const Sites := preload("res://scripts/web_video_sites.gd")
const Home := preload("res://scripts/web_video_home.gd")
const I18n := preload("res://scripts/i18n.gd")
const Menu := preload("res://scripts/library_menu.gd")
const Fixture := preload("res://tests/test_web_browser_panel.gd")
var checks := 0
var failures: Array[String] = []

func check(value: bool, message: String) -> void:
	checks += 1
	if not value: failures.append(message)

func _initialize() -> void: call_deferred("_run")

func _run() -> void:
	var original: Variant = ProjectSettings.get_setting(Channel.KEY)
	var platform := Fixture.Platform.new()
	var menu := Menu.new()
	root.add_child(menu)
	menu.attach_platform(platform)
	for channel in ["standard", "pico_cn_store", "unknown"]:
		ProjectSettings.set_setting(Channel.KEY, channel)
		menu.section = Menu.Section.RECENT
		menu.visible = true
		menu.refresh()
		var enabled: bool = channel in ["standard", "pico_cn_store"]
		var args := OS.get_cmdline_user_args()
		if not args.is_empty():
			DirAccess.make_dir_recursive_absolute(args[0])
			check(ProjectSettings.save_custom(args[0].path_join(channel + ".binary")) == OK, "Save actual engine channel configuration")
		check(Channel.current() == channel, "Channel comes from packaged settings")
		check(menu._buttons.any(func(button): return button.target == Menu.NAV_BASE + Menu.Section.WEB) == enabled, "Browser navigation respects channel")
		check(menu.web_browser.supported() == enabled, "Browser support respects channel")
		menu._activate(Menu.NAV_BASE + Menu.Section.WEB)
		check((menu.section == Menu.Section.WEB) == enabled, "Direct navigation cannot reopen the hidden section")
		menu.web_browser.open("https://example.com")
		check(menu.web_browser.opened == enabled, "Direct open respects channel")
		menu.web_browser.close()
		menu.section = Menu.Section.WEB
		menu.refresh()
		check((menu.section == Menu.Section.WEB) == enabled, "Restored stale section respects channel")
		if not enabled:
			check(not menu.web_browser.action(menu.web_browser.BASE), "Stale browser action is ignored")
		check(menu._buttons.any(func(button): return button.target == Menu.NAV_BASE + Menu.Section.CLOUD), "Account sources remain available")

	ProjectSettings.set_setting(Channel.KEY, "pico_cn_store")
	menu.web_browser.close(); menu.section = Menu.Section.WEB
	for language in ["zh", "en", "ja", "zh_Hant", "ko"]:
		I18n.use(language); menu.web_video.home.expanded = true; menu.refresh()
		check(Sites.ordered_indexes(language) == [0, 2, 3, 4, 5, 17, 18], "China channel only includes explicit Chinese featured sites in " + language)
		var cards := menu._buttons.filter(func(button): return button.target >= Home.SITE_BASE and button.target < Home.SITE_BASE + Sites.FEATURED.size())
		check(cards.size() == 7, "China channel includes iQIYI and Douyin browser entries")
		check(not menu._buttons.any(func(button): return button.target == Home.BASE + 7), "Filtered catalog has no foreign or empty second page")
		for index in Sites.FEATURED.size():
			if index in [0, 2, 3, 4, 5, 17, 18]: continue
			menu.web_video.home.action(Home.SITE_BASE + index)
			check(not menu.web_browser.opened, "Stale foreign site target cannot open " + Sites.FEATURED[index].name)
		menu.web_video.home.site_page = 99; menu.refresh()
		check(menu.web_video.home.site_page == 0, "China featured pagination is bounded")
	menu.web_video.home.action(Home.SITE_BASE)
	check(menu.web_browser.opened and platform.browser.url == "https://www.bilibili.com/", "China featured card still opens its Chinese website")
	menu.web_browser.close()
	menu.web_video.home.action(Home.SITE_BASE + 17)
	check(menu.web_browser.opened and platform.browser.url == "https://www.iqiyi.com/", "iQIYI card opens the Chinese service")
	menu.web_browser.close()
	ProjectSettings.set_setting(Channel.KEY, "standard"); I18n.use("en"); menu.refresh()
	check(Sites.ordered_indexes("en").size() == 19, "Standard catalog includes iQIYI and Douyin")
	I18n.use("zh")
	ProjectSettings.set_setting(Channel.KEY, original)
	menu.free()
	platform.free()
	print("Distribution channel: %d checks, %d failures" % [checks, failures.size()])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)
