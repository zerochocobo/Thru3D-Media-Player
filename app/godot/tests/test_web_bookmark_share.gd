extends SceneTree
const Menu := preload("res://scripts/library_menu.gd")
const Fixture := preload("res://tests/test_web_browser_panel.gd")
const Library := preload("res://scripts/web_browser_library_panel.gd")
const I18n := preload("res://scripts/i18n.gd")
var checks := 0
var failures: Array[String] = []
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)
func _initialize() -> void: call_deferred("run")
func run() -> void:
	var platform := Fixture.Platform.new()
	var menu := Menu.new(); root.add_child(menu); menu.attach_platform(platform); menu.toggle()
	menu._activate(Menu.NAV_BASE + Menu.Section.WEB)
	var browser: RefCounted = menu.web_browser; var panel: RefCounted = browser.library
	browser.choose({"web_browser": "bookmarks"}); browser.tick()
	check(menu._buttons.any(func(b): return b.target == Library.BASE + Library.Action.WIFI), "Wi-Fi entry visible even for empty bookmarks")
	menu._activate(Library.BASE + Library.Action.WIFI)
	check(panel.modal == "wifi" and not panel.require_code, "Pairing optional and off by default")
	var secure: Dictionary = menu._buttons.filter(func(button): return button.target == Library.BASE + Library.Action.SECURE)[0]
	var captions: Array = secure.node.get_children().filter(func(node): return node is Label3D and not node.text.is_empty())
	check(captions.size() == 1 and is_zero_approx(captions[0].position.y) and captions[0].position.x < 0, "Pairing checkbox caption uses one horizontal row")
	check(menu._tips[Library.BASE + Library.Action.SECURE] == I18n.t("Enter the pairing code on your phone or PC to connect."), "Pairing tooltip explains the code")
	check(menu._tips[Library.BASE + Library.Action.START] == I18n.t("When off, anyone on this Wi-Fi can manage bookmarks and history while access is open."), "Service access tooltip belongs to Start")
	menu._activate(Library.BASE + Library.Action.START)
	check(platform.library_commands.back().action == "share_start" and not platform.library_commands.back().require_code, "Start includes explicit unpaired preference")
	platform.library.share = {"active": true, "url": "http://192.168.1.8:8791", "code": "", "requires_code": false, "seconds": 1800}
	platform.library.operation = {"id": 1, "state": "saved"}; browser.saved_poll = 0; browser.tick()
	check(panel.modal == "wifi" and panel.pending == 0, "Start acknowledgement retains connection panel")
	for lang in ["zh", "zh_Hant", "ja", "en"]:
		I18n.use(lang); menu.refresh()
		check(menu.text_snapshot().contains("http://192.168.1.8:8791"), "Root address visible: " + lang)
		check(not menu.text_snapshot().contains(I18n.t("Pairing code") + "  "), "No pairing code for direct connection: " + lang)
		check(menu.text_snapshot().contains(I18n.t("Close remote access")), "Close access localized: " + lang)
	var before: float = menu.scroll; menu.stick_scroll(1, 0.1)
	check(menu.scroll == before, "Connection panel absorbs list scrolling")
	menu._activate(Library.BASE + Library.Action.SECURE)
	check(not panel.require_code, "Cannot silently change security while sharing")
	menu._activate(Library.BASE + Library.Action.CANCEL)
	check(platform.library_commands.size() == 1 and panel.modal.is_empty(), "Back keeps LAN sharing alive")
	menu._activate(Library.BASE + Library.Action.WIFI); menu._activate(Library.BASE + Library.Action.STOP)
	check(platform.library_commands.size() == 1 and panel.modal == "wifi_confirm", "Close requires a second confirmation")
	menu._activate(Library.BASE + Library.Action.CANCEL)
	check(panel.modal == "wifi" and platform.library_commands.size() == 1, "Cancelling close keeps remote access open")
	menu._activate(Library.BASE + Library.Action.STOP); menu._activate(Library.BASE + Library.Action.CONFIRM)
	check(platform.library_commands.back().action == "share_stop", "Explicit stop sent")
	platform.library.share = {"active": false}; platform.library.operation = {"id": 2, "state": "saved"}; browser.saved_poll = 0; browser.tick()
	menu._activate(Library.BASE + Library.Action.SECURE); menu._activate(Library.BASE + Library.Action.START)
	check(platform.library_commands.back().require_code, "Optional secure session requested")
	platform.library.share = {"active": true, "url": "http://192.168.1.8:8791", "code": "ABCD", "requires_code": true, "seconds": 1200}
	platform.library.operation = {"id": 3, "state": "saved"}; browser.saved_poll = 0; browser.tick()
	check(menu.text_snapshot().contains("ABCD"), "Four-letter code shown")
	platform.library.share = {"active": false}; browser.saved_poll = 0; browser.tick()
	check(not menu.text_snapshot().contains("ABCD") and menu.text_snapshot().contains(I18n.t("Start sharing")), "Remote stop/expiry clears stale address and code")
	menu._activate(Library.BASE + Library.Action.CANCEL); browser.choose({"web_browser": "history"}); menu.refresh()
	check(menu._buttons.any(func(b): return b.target == Library.BASE + Library.Action.WIFI), "History also offers LAN management")
	menu._activate(Library.BASE + Library.Action.WIFI)
	check(panel.modal == "wifi" and menu.text_snapshot().contains(I18n.t("Bookmarks & history")), "Shared scope is explicit from history entry")
	menu.free(); platform.free(); await process_frame
	print("Bookmark share: %d checks, %d failures" % [checks, failures.size()])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)
