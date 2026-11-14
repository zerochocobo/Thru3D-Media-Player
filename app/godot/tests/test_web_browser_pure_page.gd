extends SceneTree
const Menu := preload("res://scripts/library_menu.gd")
const Fixture := preload("res://tests/test_web_browser_panel.gd")
var checks := 0
var failures: Array[String] = []
func check(value: bool, message: String) -> void:
	checks += 1
	if not value: failures.append(message)
func _initialize() -> void: run.call_deferred()
func click_chrome(host: Node3D) -> void:
	var footer: Node3D = host.effect_controls
	footer.sync(1000); footer.visible = true
	var button: Dictionary = footer._buttons.filter(func(b): return b.target==footer.CHROME)[0]
	var ray: Vector3 = button.node.global_position+footer.global_basis.z.normalized()*.3
	var direction: Vector3 = -footer.global_basis.z.normalized()
	check(host.ray_hit(ray,direction).get("target",-1)==footer.CHROME,"Leftmost pure-page icon receives the actual ray")
	host.press_pointer("right",ray,direction,true); host.release_pointer("right",ray,direction,true)
func verify_frameless_resize(host: Node3D) -> void:
	for edge in [host.RESIZE_RIGHT,host.RESIZE_BOTTOM,host.RESIZE]:
		var button: Dictionary = host._buttons.filter(func(b): return b.target==edge)[0]
		var pose: Transform3D = host.global_transform
		var start := Vector3(button.rect.get_center().x,button.rect.get_center().y,.3)
		var moved := start+Vector3(.1,-.08,0)
		var before: Vector2 = host.page_layout().size
		check(host.local_hit(pose*start,-pose.basis.z).get("target")==edge,"Frameless resize target accepts the ray")
		host.update_pointer("left",pose*start,-pose.basis.z,true)
		var shown: Array = host._buttons.filter(func(b): return b.has("hover_marks") and b.hover_marks[0].visible).map(func(b): return b.target)
		check(shown==[edge],"Ray hover shows only the aimed frameless grip")
		check(host.press_pointer("left",pose*start,-pose.basis.z,true) and host.drag.get("kind")==edge,"Frameless resize target starts capture")
		host.update_pointer("left",pose*moved,-pose.basis.z,true); host.release_pointer("left",pose*moved,-pose.basis.z,true)
		var after: Vector2 = host.page_layout().size
		check(host.drag.is_empty() and (after.x>before.x if edge!=host.RESIZE_BOTTOM else is_equal_approx(after.x,before.x)) and (after.y>before.y if edge!=host.RESIZE_RIGHT else is_equal_approx(after.y,before.y)),"Frameless drag resizes the matching page edge")
		check(not host.toolbar_shown and host.chrome_hidden(),"Resizing keeps the frame hidden")
func run() -> void:
	var menu := Menu.new(); root.add_child(menu)
	var platform := Fixture.Platform.new(); menu.attach_platform(platform); menu.toggle()
	menu._activate(Menu.NAV_BASE+Menu.Section.WEB); menu.set_process(false)
	var browser: RefCounted = menu.web_browser; browser.open("https://example.com/page"); browser.tick()
	var host: Node3D = browser.windows[1]; host.set_process(false)
	var footer: Node3D = host.effect_controls
	var native_surface: Node3D = host.surface
	var initial_actions: Array = platform.actions.duplicate()
	var initial_commands: Array = platform.browser_commands.duplicate()
	for cinema in [false]: # Projected screens keep their near menu; covered by global-footer tests.
		browser.cinema_provider = func(): return {"position":[0,3,-12],"width":10.,"height":5.625}
		host.set_mode("cinema" if cinema else "floating"); host.refresh()
		var layout: Dictionary = host.page_layout(); var size: Vector2 = host.page_size
		click_chrome(host); host._update_feedback()
		check(not host.toolbar_shown and host.chrome_hidden() and not host.page_input_blocked(),"Pure page hides chrome while allowing webpage input")
		var resize_targets := [host.RESIZE,host.RESIZE_RIGHT,host.RESIZE_BOTTOM]
		check(host._buttons[0].target==host.WEB and host._buttons.all(func(b): return b.target==host.WEB or b.target in resize_targets),"Pure page keeps the webpage tile and resize targets, without toolbar controls")
		check(resize_targets.all(func(t): return host._buttons.any(func(b): return b.target==t)),"Right, bottom and corner resize stay available without the frame")
		check(resize_targets.all(func(t): return host._buttons.any(func(b): return b.target==t and not b.get("hover_marks", []).is_empty() and b.hover_marks.all(func(m): return not m.visible))),"Frameless grip marks stay hidden until the ray reaches them")
		verify_frameless_resize(host)
		layout = host.page_layout(); size = host.page_size
		check(not host._backdrop.visible and host._decorations.is_empty(),"Top bar, side and bottom borders are all absent")
		check(host._ray_blockers.is_empty(),"Invisible chrome cannot capture a page ray or drag")
		check(not host._progress.visible and not host._feedback.get_node("background").visible,"Pure page adds no loading strip or crop backing")
		check(host.page_layout()==layout and host.page_size==size and host.surface==native_surface,"Toggle retains the exact webpage layout and native Surface")
		var uv := Vector2(.31,.28)
		var ray: Vector3 = layout.pose*Vector3((uv.x-.5)*layout.size.x,(.5-uv.y)*layout.size.y,.4)
		var direction: Vector3 = -layout.pose.basis.z
		host.press_pointer("left",ray,direction,true); host.release_pointer("left",ray,direction,true)
		check(platform.pointers.back()[0]=="up" and Vector2(platform.pointers.back()[1],platform.pointers.back()[2]).distance_to(uv)<.001,"Pure-page trigger reaches the same source coordinates")
		host.stick_scroll(1,.1)
		check(platform.pointers.back()[0]=="scroll","Pure-page stick scrolling reaches the webpage")
		host.toggle_focus(); check(host.selecting,"Region selection stays available in pure page")
		host.selection=Rect2(.2,.2,.4,.4); host._update_feedback()
		check(host._feedback.get_node("selection4").is_visible_in_tree(),"Selection still displays its functional outline without restoring chrome")
		host.toggle_focus(); check(not host.selecting,"Selection cancels while chrome stays hidden")
		footer.near_hands.clear(); footer.last_near=1000
		footer.observe_ray("right",ray,direction,false,2000)
		check(not footer.visible,"The pure-page controls retain their normal idle hide policy")
		var icon: Dictionary = footer._buttons.filter(func(b): return b.target==footer.CHROME)[0]
		var icon_ray: Vector3 = icon.node.global_position+footer.global_basis.z.normalized()*.3
		footer.observe_ray("right",icon_ray,-footer.global_basis.z.normalized(),true,2100)
		footer.observe_ray("right",icon_ray,-footer.global_basis.z.normalized(),true,2230)
		check(footer.visible,"A ray at the new far-left icon wakes the hidden row")
		click_chrome(host)
		check(host.toolbar_shown and not host.chrome_hidden() and host._buttons.size()>1,"Same icon restores toolbar and borders")
		check(host.page_layout()==layout and host.page_size==size,"Restoring chrome preserves page pose and dimensions")
	check(platform.actions==initial_actions and platform.browser_commands==initial_commands,"Pure-page toggles do not navigate, reload, resize or deactivate the Gecko session")
	host._activate(footer.CHROME); host._activate(footer.MATTE)
	check(host.page_input_blocked() and host._buttons.is_empty(),"Person passthrough keeps its existing interaction isolation")
	host._activate(footer.MATTE)
	check(not host.toolbar_shown and host.chrome_hidden() and host._buttons.size()>1,"Leaving person passthrough preserves the user's pure-page choice")
	# A page becoming the start page must not strand the user without an exit icon.
	platform.browser.url="about:blank"; browser.next_poll=0; browser.tick()
	footer.observe_ray("right",footer.to_global(Vector3(-.3,0,.3)),-footer.global_basis.z.normalized(),true,3000)
	footer.observe_ray("right",footer.to_global(Vector3(-.3,0,.3)),-footer.global_basis.z.normalized(),true,3130)
	check(footer.visible,"A pure start page still offers the frame-restore control")
	menu.free(); platform.free(); await process_frame
	print("Browser pure page: %d checks, %d failures"%[checks,failures.size()])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)
