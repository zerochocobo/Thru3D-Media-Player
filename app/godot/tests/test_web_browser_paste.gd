extends SceneTree
const Menu := preload("res://scripts/library_menu.gd")
const Home := preload("res://scripts/web_video_home.gd")
const Browser := preload("res://scripts/web_browser_panel.gd")
const Fixture := preload("res://tests/test_web_browser_panel.gd")
const I18n := preload("res://scripts/i18n.gd")

class Platform extends Fixture.Platform:
	var clipboard := ""
	var reads := 0
	var navigations: Array = []
	func media_clipboard_text() -> String: reads += 1; return clipboard
	func web_browser_navigate(url: String) -> void:
		navigations.append({"url":url,"window":int(browser.get("focused_window",1))})
		browser.url = url
		for item in browser.get("windows", []):
			if item.id == browser.get("focused_window",1): item.url = url
	func web_browser_command(value: String) -> void:
		super.web_browser_command(value)
		var command: Dictionary = JSON.parse_string(value)
		if command.action == "focus": browser.focused_window = int(command.window)

var failures: Array[String] = []
var checks := 0
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)
func button(host: Node3D, target: int) -> Dictionary:
	var matches: Array = host._buttons.filter(func(item): return item.target == target)
	check(matches.size() == 1, "Exactly one requested input target exists: " + str(target))
	return matches[0] if not matches.is_empty() else {}
func click(host: Node3D, target: int) -> void:
	var item := button(host,target)
	if item.is_empty(): return
	var origin: Vector3 = item.node.to_global(Vector3(0,0,.5))
	var direction: Vector3 = -item.node.global_basis.z
	host.press_pointer("right_hand",origin,direction,true)
	host.release_pointer("right_hand",origin,direction,true)
func row(host: Node3D, ids: Array) -> void:
	var previous: Dictionary = {}
	for id in ids:
		var item := button(host,id)
		if item.is_empty(): continue
		check(item.enabled,"Paste and address controls remain available without polling clipboard")
		if not previous.is_empty():
			check(previous.rect.end.x <= item.rect.position.x,"Address, paste and next action do not overlap")
			check(is_equal_approx(previous.rect.get_center().y,item.rect.get_center().y),"Paste immediately follows address on the same row")
		previous = item

func _initialize() -> void: run.call_deferred()
func run() -> void:
	var menu := Menu.new();root.add_child(menu);menu.set_process(false)
	var platform := Platform.new();menu.attach_platform(platform);menu.toggle()
	menu._activate(Menu.NAV_BASE+Menu.Section.WEB)
	var browser: RefCounted = menu.web_browser
	for language in ["zh","zh_Hant","en","ja"]:
		I18n.use(language);menu.web_video.address="https://existing.test/";menu.refresh()
		row(menu,[Home.BASE,Home.PASTE,Home.BASE+1])
	check(platform.reads==0,"Rendering localized homepage never reads the clipboard")
	platform.clipboard="https://example.test/"+"long-path/".repeat(30)+"?query=中文"
	click(menu,Home.PASTE)
	check(menu.web_video.address==platform.clipboard and menu.web_video.address.length()>128,"Home paste preserves a full long Unicode URL")
	check(platform.navigations.is_empty() and not browser.opened,"Home paste fills the address without navigating")
	platform.clipboard=" \r\n\t ";click(menu,Home.PASTE)
	check(menu.web_video.address.begins_with("https://example.test/"),"Empty clipboard does not erase the home address")
	menu._activate(Home.BASE);platform.clipboard="https://edited-home.test/";click(menu,Home.PASTE)
	check(menu.system_text_input.editor.text==platform.clipboard and menu.web_video.address==platform.clipboard,"Paste replaces an active home editor and its visible draft together")
	menu.system_text_input.cancel();click(menu,Home.BASE+1)
	check(browser.opened and platform.navigations.back().url=="https://edited-home.test/","Home open arrow submits the pasted address")
	browser.next_poll=0;browser.tick()
	platform.browser.merge({"focused_window":1,"tab_id":11,"navigation":2,"windows":[
		{"id":1,"tab_id":11,"navigation":2,"url":"https://first.test/","active":true},
		{"id":2,"tab_id":22,"navigation":3,"url":"https://second.test/","active":true}]},true)
	browser.next_poll=0;browser.tick()
	browser.cinema_provider=func():return {"position":[0,3,-12],"width":10.0,"height":5.625,"yaw":0.0}
	for id in [1,2]:
		var host: Node3D = browser.windows[id];host.set_process(false)
		for mode in ["floating","cinema"]:
			host.set_mode(mode)
			for language in ["zh","zh_Hant","en","ja"]:
				I18n.use(language);host.refresh()
				row(host,[Browser.BASE+3,Browser.PASTE,Browser.BASE+4,Browser.BASE+7])
				check(host._tips[Browser.PASTE]==I18n.t("Paste"),"Paste tooltip follows the UI language")
			host.set_mode("floating")
		var before: int = platform.navigations.size()
		platform.clipboard="https://paste-%d.test/"%id+"segment/".repeat(25)
		click(host,Browser.PASTE)
		check(browser.focused_window==id and menu.system_text_input.active("web_browser"),"Pasting into a window owns that window's address editor")
		check(browser.draft==platform.clipboard and menu.system_text_input.editor.text==platform.clipboard,"Window paste replaces the full address and editable text")
		browser.next_poll=0;browser.tick()
		check(browser.draft==platform.clipboard and platform.navigations.size()==before,"Browser polling cannot overwrite an unsubmitted pasted address or navigate")
		platform.clipboard=" \r\nhttps://fresh.test/%d \t"%id;click(host,Browser.PASTE)
		check(browser.draft=="https://fresh.test/%d"%id,"Each click reads current clipboard content and trims surrounding whitespace")
		platform.clipboard="";click(host,Browser.PASTE)
		check(browser.draft=="https://fresh.test/%d"%id,"Empty clipboard preserves an active window editor")
		menu.system_text_input._submitted(menu.system_text_input.editor.text)
		check(platform.navigations.size()==before+1 and platform.navigations.back()=={"url":"https://fresh.test/%d"%id,"window":id},"Confirming navigates exactly the window where paste was clicked")
		menu.system_text_input.cancel()
	menu.free();platform.free();await process_frame
	for failure in failures:push_error(failure)
	print("Web browser paste: %d checks, %d failures"%[checks,failures.size()])
	quit(0 if failures.is_empty() else 1)
