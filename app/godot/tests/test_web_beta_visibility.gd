extends SceneTree
const Menu := preload("res://scripts/library_menu.gd")
const Fixture := preload("res://tests/test_web_browser_panel.gd")
var checks := 0
var failures: Array[String] = []
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)
func _initialize() -> void: run.call_deferred()
func last(platform: Object, id: int) -> Dictionary:
	var commands: Array = platform.browser_commands.filter(func(c): return c.action == "page_beta_visibility" and c.window == id)
	return commands.back() if not commands.is_empty() else {}
func run() -> void:
	var platform := Fixture.Platform.new()
	var state := {"id": 1, "tab_id": 10, "navigation": 3, "url": "https://www.bilibili.com/video/BV1234567890/", "fullscreen": false,
		"bilibili_beta_available": true, "videos": [{"bilibili_ready": true, "selection": "current"}]}
	platform.browser.merge(state, true)
	platform.browser.windows = [state, state.merged({"id": 2, "tab_id": 20}, true)]
	platform.browser.focused_window = 1
	var menu := Menu.new(); root.add_child(menu); menu.attach_platform(platform); menu.toggle()
	menu._activate(Menu.NAV_BASE + Menu.Section.WEB)
	var browser: RefCounted = menu.web_browser
	browser.open(); browser.tick()
	var host: Node = browser.windows[1]
	check(last(platform, 1).get("hidden") == false and last(platform, 2).get("hidden") == false, "Ordinary windows show page Beta")
	var count := platform.browser_commands.size()
	host.sync_page_beta_visibility(); host.refresh()
	check(platform.browser_commands.size() == count, "Unchanged state does not spam Gecko")
	host.set_toolbar_shown(false)
	check(last(platform, 1).hidden and not last(platform, 2).hidden, "Hidden chrome changes only its own window")
	host.set_toolbar_shown(true)
	check(not last(platform, 1).hidden, "Showing chrome restores the page action")
	host.toggle_focus()
	check(last(platform, 1).hidden, "Drawing a region hides the page button")
	host.selection = Rect2(.1, .2, .5, .4); host.finish_selection()
	check(last(platform, 1).hidden, "Focused region stays hidden")
	check(host._buttons.any(func(b): return b.target == browser.BASE + 18 and b.enabled), "Focused mode preserves the toolbar Beta action")
	host.toggle_focus()
	check(not last(platform, 1).hidden, "Leaving region focus restores page Beta")
	browser.focus_regions[10] = Rect2(.1, .2, .5, .4); browser.video_regions[10] = browser.focus_regions[10]; host.refresh()
	check(last(platform, 1).hidden and host.is_video_focused(), "Video focus uses the same presentation gate")
	host.toggle_video_focus()
	check(not last(platform, 1).hidden, "Leaving video focus restores without capture changes")
	state.fullscreen = true; host.sync_fullscreen(state)
	check(last(platform, 1).hidden, "Floating fullscreen hides its page action with chrome")
	state.fullscreen = false; host.sync_fullscreen(state)
	check(not last(platform, 1).hidden, "Exiting fullscreen restores prior visible chrome")
	host.set_toolbar_shown(false); state.fullscreen = true; host.sync_fullscreen(state)
	state.fullscreen = false; host.sync_fullscreen(state)
	check(last(platform, 1).hidden, "Exiting fullscreen does not undo a manually hidden menu")
	host.set_toolbar_shown(true)
	platform.browser.windows[0].navigation = 4; browser.next_poll = 0; browser.tick()
	check(last(platform, 1).navigation == 4, "Navigation gets a fresh scoped command even when visibility is unchanged")
	check(not platform.browser_commands.any(func(c): return c.action in ["network_capture", "pause_tab", "reload"]), "Presentation never sends network-policy, pause or reload commands")
	menu.free(); platform.free()
	print("Web Beta visibility: %d checks, %d failures" % [checks, failures.size()])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)
