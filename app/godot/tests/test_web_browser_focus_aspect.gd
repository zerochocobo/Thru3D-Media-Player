extends SceneTree
const Menu:=preload("res://scripts/library_menu.gd")
const Fixture:=preload("res://tests/test_web_browser_windows.gd")
const Focus:=preload("res://scripts/web_browser_focus.gd")
var checks:=0
var failures: Array[String]=[]
func _initialize() -> void: run.call_deferred()
func check(ok: bool,message: String) -> void:
	checks+=1
	if not ok:failures.append(message)
func point(page: Dictionary,uv: Vector2,z: float=.6) -> Vector3:
	return page.pose*Vector3((uv.x-.5)*page.size.x,(.5-uv.y)*page.size.y,z)
func run() -> void:
	for start in [Vector2(.2,.2),Vector2(.8,.8),Vector2(.2,.8),Vector2(.8,.2),Vector2(.98,.5),Vector2(.5,.98),Vector2.ZERO,Vector2.ONE,Vector2(0,1),Vector2(1,0)]:
		for end in [Vector2(.3,.7),Vector2(.9,.3),Vector2(.1,.9),Vector2(-.3,.9),Vector2(1.5,1.5),Vector2(.5,0),start+Vector2(.1,0),start+Vector2(0,-.1)]:
			var rect:=Focus.selection(start,end)
			var clamped: Vector2=end.clamp(Vector2.ZERO,Vector2.ONE)
			check(rect.is_equal_approx(Rect2(start.min(clamped),(clamped-start).abs())),"Selection is the free box between the press and the clamped drag point")
			check(Focus.FULL.encloses(rect),"Dragging beyond an edge stops at that edge inside the page")
			for frame in [Vector2(1.44,.9),Vector2(2.4,.65),Vector2(1.44,1.8)]:
				var held:=Focus.selection(start,end,frame)
				check(Focus.FULL.grow(.00001).encloses(held),"A held box stays inside the page")
				check([held.position,Vector2(held.end.x,held.position.y),Vector2(held.position.x,held.end.y),held.end].any(func(c):return c.distance_to(start)<.00001),"A held box stays anchored at the press")
				if held.size.x>.001 and held.size.y>.001:
					var shape: float=held.size.x*frame.x/(held.size.y*frame.y)
					check(shape>=Focus.MIN_ASPECT-.0001 and shape<=Focus.MAX_ASPECT+.0001,"Dragging can never draw an extreme shape")
				if not Focus.valid(rect):continue
				var aspect: float=frame.x/frame.y
				var screen:=Focus.framed(rect,frame,aspect,aspect)
				check(Focus.FULL.encloses(screen),"A screen crop stays inside the page")
				check(screen.grow(.00001).encloses(rect) or screen.size.x>=1.0-.0001 or screen.size.y>=1.0-.0001,"A screen crop keeps the whole drawn box unless the page itself is too small")
				var window:=Focus.framed(rect,frame,Focus.MIN_ASPECT,Focus.MAX_ASPECT)
				var extent: Vector2=window.size*frame
				check(window.grow(.00001).encloses(rect) and extent.x/extent.y>=Focus.MIN_ASPECT-.0001 and extent.x/extent.y<=Focus.MAX_ASPECT+.0001 or window.size.x>=1.0-.0001 or window.size.y>=1.0-.0001,"A window crop keeps the drawn box within the allowed window shapes")
				for low in [false,true]:
					var pixels:=Vector2(preload("res://scripts/web_browser_surface.gd").pixels_for(frame,low))
					if screen.size.x<1.0-.0001 and screen.size.y<1.0-.0001:
						check(Focus.fitted(frame,pixels,screen).is_equal_approx(frame),"A screen crop fills the same frame at either resolution tier")
				var shown:=Focus.focused_size(frame,window)
				check(absf(shown.x/shown.y-extent.x/extent.y)<.0001,"A window takes the crop's visible aspect")
				check(absf(shown.x*shown.y-frame.x*frame.y)<.0001,"A reshaped window keeps the page's area, never shrinking the picture")
	check(not Focus.selection(Vector2(NAN,.2),Vector2(.8,.8)).has_area(),"Invalid rays cannot create a selection")
	check(not Focus.valid(Focus.selection(Vector2(.2,.2),Vector2(.6,.201))),"A flat horizontal drag stays a thin, rejected box instead of flipping")
	var tall:=Focus.selection(Vector2(.4,.1),Vector2(.5,.9))
	check(tall.size.y>tall.size.x*7.9,"Without a frame the box is exactly what was dragged")
	var portrait:=Focus.selection(Vector2(.4,.1),Vector2(.5,.9),Vector2(1.44,.9))
	check(is_equal_approx(portrait.size.x*1.44/(portrait.size.y*.9),Focus.MIN_ASPECT) and is_equal_approx(portrait.size.y,.8) and portrait.position.is_equal_approx(Vector2(.4,.1)),"A tall drag widens away from the press to the narrowest shape")
	var cornered:=Focus.selection(Vector2(.95,.1),Vector2(.99,.9),Vector2(1.44,.9))
	check(cornered.end.x<=1.00001 and is_equal_approx(cornered.size.x*1.44/(cornered.size.y*.9),Focus.MIN_ASPECT) and cornered.size.y<.8,"At the page edge the dragged side shortens instead")
	var banner:=Focus.selection(Vector2(.1,.4),Vector2(.9,.42),Vector2(1.44,.9))
	check(is_equal_approx(banner.size.x*1.44/(banner.size.y*.9),Focus.MAX_ASPECT),"A flat drag deepens to the widest shape")
	var thin:=Focus.framed(tall,Vector2(1.44,.9),Focus.MIN_ASPECT,Focus.MAX_ASPECT)
	check(thin.grow(.00001).encloses(tall) and is_equal_approx(thin.size.x*1.44/(thin.size.y*.9),Focus.MIN_ASPECT) and is_equal_approx(thin.get_center().x,tall.get_center().x),"A sliver widens about its centre to the narrowest window shape")
	var edge:=Focus.framed(Rect2(.95,.1,.05,.8),Vector2(1.44,.9),Focus.MIN_ASPECT,Focus.MAX_ASPECT)
	check(Focus.FULL.grow(.00001).encloses(edge) and edge.end.x<=1.00001 and edge.grow(.00001).encloses(Rect2(.95,.1,.05,.8)),"Widening at the page edge shifts inward instead of leaving the page")
	var platform:=Fixture.Platform.new();platform.browser.merge({"tab_id":1,"navigation":1,"start_page":false,"loading":false},true)
	var menu:=Menu.new();root.add_child(menu);menu.attach_platform(platform);menu.toggle();menu._activate(Menu.NAV_BASE+Menu.Section.WEB)
	var browser: RefCounted=menu.web_browser;browser.open();browser.tick();menu.set_process(false)
	var host: Node3D=browser.windows[1];host.set_process(false)
	browser.cinema_provider=func():return {"position":[0,3,-12],"width":10.0,"height":5.625}
	for cinema in [false,true]:
		for dimensions in [Vector2(1.44,.9),Vector2(2.4,.65),Vector2(1.44,1.8)]:
			host.page_size=dimensions;host.set_mode("cinema" if cinema else "floating");host.refresh()
			for low in [false,true]:
				browser.low_end=low
				for ends in [[Vector2(.2,.15),Vector2(.63,.32)],[Vector2(.8,.8),Vector2(.63,.2)],[Vector2(.03,.96),Vector2(.7,.3)]]:
					if host.is_focused():host.toggle_focus()
					host.toggle_focus()
					var full: Dictionary=host.full_page_layout()
					var direction: Vector3=-full.pose.basis.z
					host.press_pointer("left",point(full,ends[0]),direction,true)
					host.update_pointer("left",point(full,ends[1]),direction,true);host._update_feedback()
					var drawn: Rect2=host.selection
					check(Focus.valid(drawn),"Real pointer drag produces a valid free-box selection")
					check(drawn.is_equal_approx(Focus.selection(ends[0],ends[1],host.page_size)),"Live outline is the held box the pointer drew")
					host.release_pointer("left",point(full,ends[1]),direction,true)
					check(host.focus_region().is_equal_approx(drawn),"Release commits exactly the previewed rectangle")
					var crop: Rect2=host.focus_crop()
					check(crop.grow(.00001).encloses(drawn),"Everything drawn stays visible")
					var focused: Dictionary=host.page_layout()
					var extent: Vector2=crop.size*full.size
					check(absf(focused.size.x/focused.size.y-extent.x/extent.y)<.001,"The shown page has no letterbox: its shape is the crop's")
					if cinema:
						check(focused.size.x<=full.size.x+.0001 and focused.size.y<=full.size.y+.0001 and (is_equal_approx(focused.size.x,full.size.x) or is_equal_approx(focused.size.y,full.size.y)),"The focused page stays within the screen, touching one side")
					else:
						check(absf(focused.size.x*focused.size.y-full.size.x*full.size.y)<.0001,"The focused page keeps the window's area")
						var bar: Rect2=host.toolbar_bounds()
						check(bar.size.x>=host.RECT.size.x+.02-.0001 and bar.size.x>=host.display_rect().size.x+.02-.0001 and absf(bar.get_center().x-host.display_rect().get_center().x)<.0001,"The toolbar stays complete, centred over the focused page")
						var top: Vector3=full.pose*Vector3(0,full.size.y/2,0)
						check((focused.pose*Vector3(0,focused.size.y/2,0)).distance_to(top)<.0001,"A reshaped window hangs centred under the toolbar")
						host._update_feedback()
						check(not host._feedback.get_node("background").visible,"A reshaped window shows no backing margins")
					for uv in [Vector2(.001,.001),Vector2(.3,.7),Vector2(.999,.999)]:
						var ray_uv: Variant=host.page_point(point(focused,uv),-focused.pose.basis.z)
						check(ray_uv!=null and host.source_point(ray_uv).distance_to(crop.position+uv*crop.size)<.00001,"Final visible point and source crop use the same coordinates")
					check(platform.pointers.is_empty(),"Selection never clicks the webpage")
					host.page_size=Vector2(dimensions.x*1.1,dimensions.y*.9);host.refresh()
					check(host.focus_region().is_equal_approx(drawn),"Resizing retains the same selected source region")
					var resized: Vector2=host.page_layout().size;var window: Vector2=host.full_page_layout().size
					if cinema:check(resized.x<=window.x+.0001 and resized.y<=window.y+.0001,"Resized focused page still fits the screen")
					else:check(absf(resized.x*resized.y-window.x*window.y)<.0001,"Resized focused page keeps the resized window's area")
					host.page_size=dimensions;host.refresh()
					host.toggle_focus()
	menu.free();platform.free();await process_frame
	for failure in failures:push_error(failure)
	print("Browser focus aspect: %d checks, %d failures"%[checks,failures.size()])
	quit(0 if failures.is_empty() else 1)
