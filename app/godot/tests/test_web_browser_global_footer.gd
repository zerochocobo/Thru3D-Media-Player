extends SceneTree
const Menu := preload("res://scripts/library_menu.gd")
const Fixture := preload("res://tests/test_web_browser_windows.gd")
const Actions := preload("res://scripts/app_actions.gd")
const I18n := preload("res://scripts/i18n.gd")
const Palette := preload("res://scripts/ui_theme.gd")
var checks := 0
var failures: Array[String] = []
var now := 10000

class ScenePlatform extends Fixture.Platform:
	func media_local_browse(_path: String) -> int: return 0

class Host extends "res://scripts/main.gd":
	var eye := Transform3D(Basis.IDENTITY, Vector3(0,1.6,0))
	var hall := false
	var alpha := false
	var calls: Array[String] = []
	func _ready() -> void: pass
	func _head_pose() -> Variant: return eye
	func _cinema_scene_active() -> bool: return hall
	func _session_controls_state() -> Dictionary:
		return {"follow":view_follow.enabled,"follow_enabled":not hall,"passthrough_visible":true,"alpha":alpha,
			"cinema_visible":hall,"cinema_lights":"auto"}
	func _on_session_control(operation: String) -> void:
		calls.append(operation)
		if operation == "follow": view_follow.set_enabled(not view_follow.enabled)
		_refresh_session_controls()
	func _on_app_action(operation: String, _menu: Node3D = null) -> void: calls.append(operation)
	func _on_whisper_haptic(_hand: String) -> void: pass

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)
func button(menu: Node3D, target: int) -> Dictionary:
	for item in menu._buttons:
		if item.target == target: return item
	return {}
func ray(menu: Node3D, target: int) -> Array:
	var item := button(menu,target)
	return [item.node.global_position + menu.global_basis.z * .3, -menu.global_basis.z]
func press(window: Node3D, footer: Node3D, target: int, hand: String = "right_hand", release: bool = true) -> void:
	var input := ray(footer,target)
	check(window.press_pointer(hand,input[0],input[1],true), "Window consumes footer target %d" % target)
	if release: window.release_pointer(hand,input[0],input[1],true)
func reveal(footer: Node3D) -> void:
	footer.near_hands.clear(); footer.entered = -1; footer.last_near = -1
	footer.sync(now)
	var origin: Vector3 = footer.to_global(Vector3(0,0,.3))
	footer.observe_ray("right_hand",origin,-footer.global_basis.z,true,now)
	footer.observe_ray("right_hand",origin,-footer.global_basis.z,true,now+150)
	now += 150
func snapshot(platform: Object, browser: RefCounted, ids: Array, focused: int) -> void:
	platform.browser.windows = []; platform.browser.tab_list = []; platform.browser.focused_window = focused
	for id in ids:
		platform.browser.windows.append({"id":id,"tab_id":id,"url":"https://example.test/"+str(id)})
		platform.browser.tab_list.append({"id":id,"window":id,"url":"https://example.test/"+str(id)})
	browser.next_poll = 0; browser.tick()
	for window in browser.windows.values(): window.set_process(false)
func _initialize() -> void: run.call_deferred()
func run() -> void:
	var main := Host.new()
	var platform := Fixture.Platform.new()
	var menu := Menu.new(); root.add_child(menu); menu.attach_platform(platform); menu.toggle(); menu.set_process(false)
	main.recent_menu = menu
	menu.layout_head_provider = main._head_pose
	menu._activate(Menu.NAV_BASE+Menu.Section.WEB)
	var browser: RefCounted = menu.web_browser
	browser.window_created = func(window):
		main._connect_session_controls(window.effect_controls)
		window.effect_controls.app_actions.now_provider = func(): return now
	browser.open("https://example.test/1"); snapshot(platform,browser,[1],1)
	var window: Node3D = browser.windows[1]
	var footer: Node3D = window.effect_controls
	reveal(footer)
	check(footer.visible and footer.device_status.is_visible_in_tree(), "Both rows appear together")
	check(not menu.device_status.visible and window.device_status == null, "No duplicate global footer in hidden library or browser chrome")
	for target in [footer.FOLLOW,footer.TEMP_PASSTHROUGH,footer.SCENERY,Actions.STATUS]:
		check(not button(footer,target).is_empty(), "Shared footer exposes %d" % target)
	check(button(footer,footer.FOLLOW).rect.end.y < button(footer,footer.CHROME).rect.position.y, "Global row stays below browser controls")
	window.depth.error = "Web 3D unavailable"; footer.sync(now)
	check(footer._labels.any(func(label): return label.text == I18n.t(window.depth.error) and label.position.y > .06), "Effect error stays above the compact rows without covering global controls")
	window.depth.error = ""; footer.sync(now)
	# Shared action wiring and current state, through the real window hit router.
	press(window,footer,footer.FOLLOW)
	check(main.view_follow.enabled and button(footer,footer.FOLLOW).base_color == footer.ACCENT, "Follow dispatch updates the shared active state")
	press(window,footer,footer.TEMP_PASSTHROUGH)
	check(main.calls.back() == "temporary_passthrough", "Temporary passthrough uses the shared action")
	main.alpha = true; footer.sync(now)
	var count := main.calls.size(); press(window,footer,footer.TEMP_PASSTHROUGH)
	check(main.calls.size() == count and not button(footer,footer.TEMP_PASSTHROUGH).enabled, "Person passthrough keeps temporary passthrough disabled")
	main.alpha = false; footer.sync(now)
	# Ray crosses the inter-row gap, then the lower edge, without losing controls.
	for point in [Vector3(0,-.08,.3),Vector3(.35,-.14,.3)]:
		now += 1000
		footer.observe_ray("right_hand",footer.to_global(point),-footer.global_basis.z,true,now)
		check(footer.visible, "Continuous two-row reveal corridor keeps controls alive")
	# Status hover and original confirmation state machine work with hand identity/release.
	var input := ray(footer,Actions.STATUS)
	window.update_pointer("right_hand",input[0],input[1],true)
	now += 260; window.update_pointer("right_hand",input[0],input[1],true)
	check(footer.app_actions.expanded, "Hover opens original status popup through the browser")
	press(window,footer,Actions.QUIT,"right_hand",false)
	check(footer.app_actions.armed == "quit_app" and not main.calls.has("quit_app"), "First click only arms exit")
	press(window,footer,Actions.QUIT,"right_hand",false)
	check(not main.calls.has("quit_app"), "Held trigger cannot confirm exit")
	window.release_pointer("right_hand",Vector3.ZERO,Vector3.ZERO,false)
	press(window,footer,Actions.QUIT)
	check(main.calls.count("quit_app") == 1, "Release and second click reach the existing exit handler exactly once")
	footer.app_actions.busy = ""; footer.app_actions.reset()
	press(window,footer,Actions.STATUS); press(window,footer,Actions.RESTART)
	window.cancel_pointer("right_hand")
	check(footer.app_actions.armed.is_empty(), "Tracking cancellation clears confirmation")
	# Different window focus does not move the footer or get stolen by a global action.
	snapshot(platform,browser,[1,2,3,4],4); reveal(footer)
	check(browser.footer_window_id == 1, "Opening/focusing more windows leaves footer on original owner")
	check(browser.windows.values().filter(func(w): return w.effect_controls.global_footer).size() == 1, "Only one of four windows owns global controls")
	press(window,footer,footer.FOLLOW)
	check(browser.focused_window == 4, "Global actions do not steal webpage focus")
	press(window,footer,Actions.STATUS); press(window,footer,Actions.RESTART)
	snapshot(platform,browser,[2,3,4],4)
	check(browser.footer_window_id == 4 and not footer.global_footer and footer.app_actions.armed.is_empty(), "Closing owner transfers to focused live window and cancels old confirmation")
	window = browser.windows[4]; footer = window.effect_controls; reveal(footer)
	check(footer.global_footer and footer.device_status.is_visible_in_tree() and footer.app_actions.armed.is_empty(), "New owner presents clean shared controls")
	snapshot(platform,browser,[2,3],99)
	check(browser.footer_window_id == 2, "Missing focus falls back to a stable remaining window")
	window = browser.windows[2]; footer = window.effect_controls; reveal(footer)
	# Temporary hiding cannot transfer ownership or leave clickable transparent controls.
	var hidden_ray := ray(footer,Actions.STATUS)
	footer.near_hands.clear(); footer.observe_ray("right_hand",Vector3.ZERO,Vector3.ZERO,false,now+1000)
	check(not footer.visible and footer.ray_hit(hidden_ray[0],hidden_ray[1]).is_empty(), "Hidden rows have no ray targets")
	check(browser.footer_window_id == 2, "Automatic hiding does not transfer ownership")
	menu.visible = false; footer.sync(now+1100)
	menu.visible = true; reveal(footer)
	check(browser.footer_window_id == 2 and footer.visible, "Temporary menu hiding preserves owner on return")
	# Homepage, pure page and focused page retain a way to reveal global actions.
	platform.browser.windows[0].url = "about:blank"; browser.next_poll = 0; browser.tick()
	reveal(footer); check(footer.visible, "Homepage permits global controls")
	window.set_toolbar_shown(false); reveal(footer)
	check(footer.visible and footer.device_status.is_visible_in_tree(), "Pure webpage retains shared controls")
	main.hall = true; footer.sync(now)
	check(not button(footer,footer.FOLLOW).enabled and not button(footer,footer.CINEMA_LIGHTS).is_empty(), "Scene capabilities update from the same provider")
	press(window,footer,footer.CINEMA_LIGHTS); press(window,footer,footer.FREE_MOVEMENT)
	check(main.calls.has("cinema_lights_cycle") and main.calls.has("cinema_move_toggle"), "Scene controls use existing shared operations")
	main.hall = false; footer.sync(now)
	check(button(footer,footer.CINEMA_LIGHTS).is_empty() and button(footer,footer.FOLLOW).enabled, "Leaving scene removes conditional controls")
	for screen in [{"position":[0,3,-12],"width":10.0,"height":5.625}, {"position":[2,2,-7],"width":6.0,"height":3.4,"yaw":.2}]:
		browser.cinema_provider = func(): return screen
		window.set_mode("cinema"); window.refresh(); reveal(footer)
		check(footer.global_position.distance_to(main.eye.origin) < 2.2 and footer.global_position.distance_to(window.page_layout().pose.origin) > 4.0, "Cinema/beach effects and global row stay near the viewer, away from the projected screen")
		check(footer.global_footer and not button(footer,Actions.STATUS).is_empty() and button(footer,footer.CHROME).is_empty(), "Projected mode retains shared footer and omits frame-hide button")
		check(footer._buttons.filter(func(b):return b.target>0).size() == 4, "Projected effects row has only focus, person passthrough, 3D and keyboard")
		window._activate(footer.CHROME); window.set_toolbar_shown(false)
		window.sync_fullscreen({"tab_id":2,"navigation":1,"fullscreen":true})
		check(window.toolbar_shown and not window.chrome_hidden(), "Stale hide commands and webpage fullscreen cannot hide projected near menu")
		window.depth.matte = true; window.refresh(); footer.sync(now)
		var menu_ray := ray(window,browser.BASE+2)
		check(window.local_hit(menu_ray[0],menu_ray[1]).get("target") == browser.BASE+2 and not window._buttons.any(func(b):return b.target==window.WEB), "Person passthrough preserves near toolbar input while blocking webpage input")
		window.depth.matte = false; window.refresh()
		var page_pose: Transform3D = window.page_layout().pose
		var controls_pose: Transform3D = footer.global_transform
		window.position.x += .2; window._sync_presentation(); footer.sync(now)
		check(not footer.global_transform.is_equal_approx(controls_pose) and window.page_layout().pose.is_equal_approx(page_pose), "Moving near menu carries both rows without moving projected webpage")
	window.set_mode("floating"); window.refresh(); reveal(footer)
	check(not button(footer,footer.CHROME).is_empty(), "Floating mode restores the optional frame-hide action")
	# Main follow update applies the existing head-offset math to every floating window.
	main.view_follow.set_enabled(true); main._update_view_follow()
	var a: Node3D = browser.windows[2]; var b: Node3D = browser.windows[3]
	var relative: Transform3D = a.global_transform.affine_inverse() * b.global_transform
	var before: Transform3D = a.global_transform; var old_head: Transform3D = main.eye
	main.eye = Transform3D(Basis(Vector3.UP,.45),Vector3(.4,1.8,.2)); main._update_view_follow()
	check(a.global_transform.is_equal_approx(main.eye*old_head.affine_inverse()*before), "Browser actually follows head translation and rotation")
	check((a.global_transform.affine_inverse()*b.global_transform).is_equal_approx(relative), "Following preserves multi-window arrangement")
	a.position += Vector3(.2,.1,0); main._update_view_follow()
	before = a.global_transform; old_head = main.eye; main.eye.origin.x += .3; main._update_view_follow()
	check(a.global_transform.is_equal_approx(main.eye*old_head.affine_inverse()*before), "Explicit window movement recaptures follow offset")
	main.view_follow.set_enabled(false); before = a.global_transform; main.eye.origin.x += .3; main._update_view_follow()
	check(a.global_transform.is_equal_approx(before), "Disabling follow leaves window in place")
	main.view_follow.set_enabled(true); main.hall = true; main._update_view_follow(); main.eye.origin.x += .3; main._update_view_follow()
	check(a.global_transform.is_equal_approx(before), "Physical cinema scene remains anchored")
	# Language/theme redraw uses common footer and preserves ownership.
	for language in ["zh","zh_Hant","en","ja"]:
		I18n.use(language)
		for theme in ["default","pearl"]:
			Palette.use(theme); footer._refresh_theme(); footer.refresh(); reveal(footer)
			check(not button(footer,footer.SCENERY).is_empty() and footer.global_footer, "Shared footer survives %s/%s redraw" % [language,theme])
	Palette.use("default"); I18n.use("en")
	menu.free(); platform.free(); main.free(); await process_frame
	await scene_return()
	print("Browser global footer: %d checks, %d failures" % [checks,failures.size()])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)

func scene_return() -> void:
	var directory := ProjectSettings.globalize_path("res://../../build/output/browser-global-footer/scene-%d" % OS.get_process_id())
	DirAccess.make_dir_recursive_absolute(directory)
	var config := ConfigFile.new(); config.set_value("appearance","background","dark"); config.set_value("ui","language","en")
	config.save(directory.path_join("settings.cfg"))
	var main := preload("res://scripts/main.gd").new(); main.settings_path = directory.path_join("settings.cfg")
	root.add_child(main); main.set_process(false); main.report_timer.stop()
	main._show_full_library()
	var menu: Node3D = main.recent_menu; menu.set_process(false)
	var platform := ScenePlatform.new(); menu.attach_platform(platform)
	menu._activate(Menu.NAV_BASE+Menu.Section.WEB)
	var browser: RefCounted = menu.web_browser
	browser.open("https://example.test/retained"); snapshot(platform,browser,[1,2],2)
	var window: Node3D = browser.windows[1]; var footer: Node3D = window.effect_controls
	var pose: Transform3D = window.global_transform
	for picker in [false,true]:
		if not picker: browser.action(browser.BASE+6)
		reveal(footer); press(window,footer,footer.SCENERY)
		check(main.scenery_menu.visible and browser.scene_suspended and browser.opened and not window.visible, "Actual Scene action hides browser UI while keeping its session")
		check(not browser.handoff and menu.web_video.pending == 0, "Scene opening cancels any pending native handoff")
		browser.tick()
		check(browser.opened and not platform.actions.has("hibernate"), "Hidden-menu polling cannot hibernate the original page")
		if picker:
			main.scenery.use_native_dialogs = false; main.scenery._begin_import()
			check(menu.background_picker_mode and not browser.active(), "Scene image picker owns input without exposing browser underneath")
			browser.tick(); menu.dismiss()
			check(main.scenery_menu.visible and browser.opened and not platform.actions.has("hibernate"), "Cancelling image picker retains browser and returns to scene menu")
		main.scenery_menu.dismiss()
		check(browser.active() and not browser.scene_suspended and window.visible and browser.windows[2].visible, "Closing scene menu restores both original windows")
		check(browser.windows[1] == window and browser.footer_window_id == 1 and browser.focused_window == 2, "Scene return preserves window identity, footer owner and webpage focus")
		check(window.global_transform.is_equal_approx(pose) and not platform.actions.has("reload"), "Scene return keeps window placement and never reloads the page")
	main.free(); platform.free(); await process_frame
