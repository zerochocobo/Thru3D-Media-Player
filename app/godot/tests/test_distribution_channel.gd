extends SceneTree
const Channel := preload("res://scripts/distribution_channel.gd")
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
		var enabled: bool = channel == "standard"
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
	ProjectSettings.set_setting(Channel.KEY, original)
	menu.free()
	platform.free()
	print("Distribution channel: %d checks, %d failures" % [checks, failures.size()])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)
