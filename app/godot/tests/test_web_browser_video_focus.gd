extends SceneTree
const Menu := preload("res://scripts/library_menu.gd")
const Fixture := preload("res://tests/test_web_browser_windows.gd")
const Focus := preload("res://scripts/web_browser_focus.gd")
const I18n := preload("res://scripts/i18n.gd")
var checks := 0
var failures: Array[String] = []
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)
func near(a: Rect2, b: Rect2) -> bool:
	return a.position.distance_to(b.position) < .0001 and a.size.distance_to(b.size) < .0001
func _initialize() -> void: run.call_deferred()
func frame(top: bool, screen: Array, videos: Array, view := [0, 0, 1440, 900]) -> Dictionary:
	return {"top": top, "screen": screen, "view": view, "videos": videos}
func run() -> void:
	# Choosing the picture from every frame's report.
	var player := {"rect": [144, 90, 720, 405], "playing": true}
	check(near(Focus.video_region([frame(true, [0, 0], [player])]), Rect2(.1, .1, .5, .45)), "The top page's video becomes its viewport region")
	check(near(Focus.video_region([frame(true, [0, 0], [{"rect": [144, 400, 720, 405], "playing": true}], [0, 300, 1440, 900])]), Rect2(.1, 100.0 / 900, .5, .45)),
		"Visual viewport offsets are taken out of top-page rectangles")
	var embedded := frame(false, [288, 180], [{"rect": [0, 0, 576, 324], "playing": true}])
	check(near(Focus.video_region([frame(true, [0, 0], []), embedded]), Rect2(.2, .2, .4, .36)), "An iframe's video is placed by its screen origin")
	check(near(Focus.video_region([embedded, frame(true, [10, 20], [])]), Rect2((288.0 - 10) / 1440, (180.0 - 20) / 900, .4, .36)), "Frames may reply in any order")
	check(Focus.video_region([embedded]) == Rect2(), "Without the top page's reply an iframe cannot be placed")
	var preview := {"rect": [1100, 700, 300, 169], "playing": true}
	var main := {"rect": [100, 100, 900, 506], "playing": false}
	check(near(Focus.video_region([frame(true, [0, 0], [preview, main])]), Rect2(100.0 / 1440, 100.0 / 900, 900.0 / 1440, 506.0 / 900)), "A much larger paused player beats a small playing preview")
	var second := {"rect": [700, 100, 640, 360], "playing": true}
	check(near(Focus.video_region([frame(true, [0, 0], [main, second])]), Rect2(700.0 / 1440, 100.0 / 900, 640.0 / 1440, .4)), "A comparable playing video beats a paused one")
	check(Focus.video_region([frame(true, [0, 0], [{"rect": [0, 0, 100, 60], "playing": true}])]) == Rect2(), "Thumbnail-sized videos are not focused")
	check(near(Focus.video_region([frame(true, [0, 0], [{"rect": [-100, 600, 1000, 600], "playing": true}])]), Rect2(0, 600.0 / 900, 900.0 / 1440, 300.0 / 900)), "Only the part on screen is focused")
	var hidden_player := {"top": true, "screen": [0, 0], "view": [0, 0, 1440, 900], "videos": [], "fallback": [{"rect": [144, 90, 720, 405], "kind": "video"}]}
	check(near(Focus.video_region([hidden_player]), Rect2(.1, .1, .5, .45)), "A player without a picture is focused when nothing else is shown")
	var embed_frame := {"top": false, "screen": [288, 180], "view": [0, 0, 576, 324], "videos": [], "fallback": [{"rect": [0, 0, 576, 324], "kind": "player"}]}
	check(near(Focus.video_region([frame(true, [0, 0], []), embed_frame]), Rect2(.2, .2, .4, .36)), "An unplayed embed reporting itself is placed like any iframe")
	var result_frame := {"top": true, "screen": [0, 0], "view": [0, 0, 1440, 900], "videos": [], "fallback": [{"rect": [0, 0, 1440, 900], "kind": "embed"}]}
	check(near(Focus.video_region([result_frame, embed_frame]), Rect2(.2, .2, .4, .36)), "A player frame reporting itself beats a larger iframe judged from outside")
	check(near(Focus.video_region([result_frame, hidden_player]), Rect2(.1, .1, .5, .45)), "A hidden video beats an iframe judged from outside")
	check(near(Focus.video_region([result_frame]), Focus.FULL), "An outside-judged iframe is used when it is all there is")
	check(near(Focus.video_region([hidden_player, embedded]), Rect2(.2, .2, .4, .36)), "A shown video anywhere beats fallbacks, even larger ones")
	check(Focus.video_region([{"top": true, "screen": [0, 0], "view": [0, 0, 1440, 900], "videos": [], "fallback": "x"}]) == Rect2(), "Malformed fallbacks find nothing")
	for bad in [[], [{}], [frame(true, [0, 0], [player], [0, 0, 0, 0])], [frame(true, ["x", 0], [player])], [frame(true, [0, 0], [{"rect": [NAN, 0, 10, 10]}])], [{"top": true, "screen": [0, 0], "view": [0, 0, 1440, 900], "videos": "videos"}]]:
		check(Focus.video_region(bad) == Rect2(), "Malformed reports find nothing: " + str(bad))
	# The window's round trip through the native page.
	I18n.use("en")
	var platform := Fixture.Platform.new()
	platform.browser.merge({"tab_id": 1, "navigation": 4, "loading": false, "start_page": false}, true)
	var menu := Menu.new(); root.add_child(menu); menu.attach_platform(platform); menu.toggle()
	menu._activate(Menu.NAV_BASE + Menu.Section.WEB)
	var browser: RefCounted = menu.web_browser
	browser.open(); browser.next_poll = 0; browser.tick()
	var host: Node3D = browser.windows[1]; host.set_process(false)
	var bar: Node3D = host.effect_controls
	var video_button := func() -> Dictionary: return bar._buttons.filter(func(b): return b.target == bar.VIDEO_FOCUS)[0]
	var free_button := func() -> Dictionary: return bar._buttons.filter(func(b): return b.target == bar.FOCUS)[0]
	bar.sync()
	check(video_button.call().rect.get_center().x < free_button.call().rect.get_center().x, "Focus video sits left of focus free region")
	check(bar._tips[bar.FOCUS] == "Focus free region" and bar._tips[bar.VIDEO_FOCUS] == "Focus video", "Both focus buttons name their mode: " + str([bar._tips[bar.FOCUS], bar._tips[bar.VIDEO_FOCUS]]))
	I18n.use("zh"); bar.refresh()
	check(bar._tips[bar.FOCUS] == "聚焦自由区域" and bar._tips[bar.VIDEO_FOCUS] == "聚焦视频", "Chinese names: " + str([bar._tips[bar.FOCUS], bar._tips[bar.VIDEO_FOCUS]]))
	I18n.use("en"); bar.refresh()
	host._activate(bar.VIDEO_FOCUS)
	var sent: Dictionary = platform.commands.back()
	check(sent.action == "locate_video" and int(sent.window) == 1 and int(sent.tab) == 1 and int(sent.navigation) == 4 and int(sent.request) > 0, "Focus video asks the current tab and navigation")
	check(host.locating_video() and not host.is_focused(), "The page stays whole while frames reply")
	bar.sync(); check(video_button.call().base_color == bar.ACCENT, "The video button shows it is working")
	var reply := {"request": int(sent.request), "ports": 2, "frames": [frame(true, [0, 0], [player])]}
	browser.data.video_locate = reply; host.sync_page_state()
	check(host.locating_video(), "One of two frames is not yet the answer")
	reply.frames.append(frame(false, [800, 0], []))
	host.sync_page_state()
	check(not host.locating_video() and host.is_video_focused() and near(host.focus_region(), Rect2(.1, .1, .5, .45)), "All frames replied: the video becomes the focus region")
	bar.sync()
	check(video_button.call().base_color == bar.ACCENT and free_button.call().base_color != bar.ACCENT, "Only the video button is selected")
	check(bar._tips[bar.VIDEO_FOCUS] == "Exit focus", "The video button now leaves focus: " + bar._tips[bar.VIDEO_FOCUS])
	host._activate(bar.FOCUS)
	check(host.selecting and not host.is_focused(), "Free region from a focused video starts a box on the whole page")
	host._activate(bar.VIDEO_FOCUS)
	check(not host.selecting and host.locating_video(), "Focus video cancels a box being drawn")
	var stale: Dictionary = platform.commands.back()
	browser.data.video_locate = {"request": int(stale.request) - 1, "ports": 1, "frames": [frame(true, [0, 0], [player])]}
	host.sync_page_state()
	check(host.locating_video(), "An earlier request's reply is ignored")
	host._video_locate.at -= host.VIDEO_LOCATE_MS
	host.sync_page_state()
	check(not host.locating_video() and not host.is_focused() and host.video_missing(), "No answer in time: nothing is focused and the viewer is told")
	bar.sync()
	check(bar._tips[bar.VIDEO_FOCUS] == "No video found" and bar._labels.any(func(label): return label.text == "No video found"), "The bar says no video was found")
	host._video_missing_until = Time.get_ticks_msec() - 1; host.sync_page_state()
	check(not host.video_missing(), "The notice clears")
	host._activate(bar.VIDEO_FOCUS)
	browser.data.navigation = 5; host.sync_page_state()
	check(not host.locating_video() and not host.is_focused(), "A navigation drops the pending request")
	browser.data.navigation = 4
	browser.focus_regions[1] = Rect2(.2, .2, .3, .3)
	check(host.is_focused() and not host.is_video_focused(), "A drawn region is a free focus")
	host._activate(bar.VIDEO_FOCUS); sent = platform.commands.back()
	browser.data.video_locate = {"request": int(sent.request), "ports": 1, "frames": [frame(true, [0, 0], [player])]}
	host.sync_page_state()
	check(host.is_video_focused(), "Focus video replaces a free region")
	host._activate(bar.VIDEO_FOCUS)
	check(not host.is_focused(), "The video button leaves video focus")
	menu.free(); platform.free(); await process_frame
	print("Browser video focus: %d checks, %d failures" % [checks, failures.size()])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)
