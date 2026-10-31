extends SceneTree
const Menu := preload("res://scripts/library_menu.gd")
const Fixture := preload("res://tests/test_web_browser_panel.gd")
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
	menu.web_browser.open("https://www.bilibili.com/video/BV1234567890/")
	var browser: RefCounted = menu.web_browser
	browser.cinema_provider = func(): return {"position":[0,3,-12], "width":10.0, "height":5.625}
	for language in ["en", "zh", "zh_Hant", "ja"]:
		I18n.use(language)
		for beta in [false, true]:
			for count in [1, 4]:
				platform.browser.tab_list = []
				for id in count: platform.browser.tab_list.append({"id":id+1,"window":1,"title":"A long tab title 哔哩哔哩","url":platform.browser.url})
				platform.browser.bilibili_beta_available = beta
				platform.browser.videos[0].bilibili_ready = beta
				platform.browser.network_capture_available = not beta
				browser.next_poll=0; browser.tick()
				var host: Node3D = browser.windows[1]
				for mode in ["floating", "cinema"]:
					for editing in [false,true]:
						platform.browser.editing = editing; browser.next_poll=0; browser.tick()
						host.set_mode(mode); host.refresh(); host._process(0)
						var buttons: Array = host._buttons.filter(func(b): return b.target != browser.WEB and b.target not in [host.RESIZE,host.RESIZE_RIGHT,host.RESIZE_BOTTOM])
						if count == 1:
							check(buttons.filter(func(b): return b.target == browser.BASE + 200)[0].rect.size.x >= 1.0, "Single tab title fills the header instead of keeping four-tab width")
						var actions: Array = buttons.filter(func(b): return is_equal_approx(b.rect.get_center().y,host.PLAY_Y))
						actions.sort_custom(func(a,b): return a.rect.position.x < b.rect.position.x)
						for index in range(1,actions.size()):
							check(absf(actions[index].rect.position.x-actions[index-1].rect.end.x-0.008)<0.0001, "No phantom tool slot or oversized gap separates the playback controls")
						for button in buttons:
							check(button.rect.size.x >= 0.1199 and button.rect.size.y >= 0.1199, "Every toolbar action has at least a 12 cm target: %s" % button.target)
							check(not button.rect.intersects(host.RECT), "Toolbar targets stay outside webpage input")
							for peer in buttons:
								if peer.target > button.target: check(not button.rect.intersects(peer.rect), "Toolbar hit targets cannot overlap: %s/%s" % [button.target,peer.target])
							for offset in [Vector2.ZERO,Vector2(-0.35,0),Vector2(0.35,0),Vector2(0,-0.35),Vector2(0,0.35)]:
								var point: Vector2 = button.rect.size * offset
								var origin: Vector3 = button.node.global_transform * Vector3(point.x,point.y,0.2)
								var hit: Dictionary = host.local_hit(origin,-host.global_basis.z.normalized())
								check(int(hit.get("target",-1)) == button.target, "Ray reaches expanded target and never neighboring actions: %s" % button.target)
	var host: Node3D = browser.windows[1]
	platform.browser.editing = false; browser.next_poll = 0; browser.tick()
	for mode in ["floating", "cinema"]:
		host.set_mode(mode); host.refresh()
		check(host.toolbar_shown, "Browser chrome stays visible without a controller ray")
		for button in host._buttons:
			check(button.node.visible, "Title, navigation and playback actions stay visible: %s" % button.target)
		platform.browser.videos[0].bilibili_ready = false; browser.next_poll = 0; browser.tick()
		var beta_button: Dictionary = host._buttons.filter(func(b): return b.target == browser.BASE + 18)[0]
		check(beta_button.node.visible and not beta_button.enabled, "Unready Beta remains visible alongside page controls")
		platform.browser.videos[0].bilibili_ready = true; browser.next_poll = 0; browser.tick()
		check(host._buttons.filter(func(b): return b.target == browser.BASE + 18)[0].enabled, "Readiness recovery enables Beta in the permanent toolbar")

	menu.free(); platform.free(); await process_frame
	print("Browser toolbar: %d checks, %d failures" % [checks,failures.size()])
	for failure in failures.slice(0,20): push_error(failure)
	quit(0 if failures.is_empty() else 1)
